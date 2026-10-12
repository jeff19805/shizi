import Foundation

/// 给模型看的文字：正文按阅读顺序；表格是 Markdown；末尾列出二维码、可能认错的行、说明。
public func renderText(_ pages: [PageResult], totalPages: Int, maxSuspects: Int = 30) -> String {
	var parts = pages.map { renderPage($0, multi: totalPages > 1, maxSuspects: maxSuspects) }
	if totalPages > pages.count {
		parts.append("【只认了 \(pages.count) 页，文件一共 \(totalPages) 页；要别的页用 pages 参数】")
	}
	return parts.joined(separator: "\n\n")
}

/// 一页给模型看的文字。多页的文件开头标【第 N 页】。
public func renderPage(_ p: PageResult, multi: Bool, maxSuspects: Int = 30) -> String {
	var block: [String] = []
	if multi { block.append("【第 \(p.page) 页】") }
	block.append(p.text.isEmpty ? "（没认出字）" : p.text)
	if !p.barcodes.isEmpty {
		block.append("\n【二维码 / 条码】\n" + p.barcodes.joined(separator: "\n"))
	}
	let suspects = p.lines.filter { $0.suspect != nil }
	if !suspects.isEmpty {
		var list = suspects.prefix(maxSuspects).map { l -> String in
			switch l.suspect!.reason {
			case .plugin: return "- \(l.text)　（判定插件：认错的可能约 \(Int((l.suspect!.probability ?? 0) * 100))%）"
			case .lowConfidence: return "- \(l.text)　（系统可信度低）"
			case .documentOnly: return "- \(l.text)　（只有认文档认出，多半是公章或签名）"
			}
		}
		if suspects.count > maxSuspects { list.append("- 还有 \(suspects.count - maxSuspects) 行，略") }
		block.append("\n【可能认错的行】（原样留在上面，没有删）\n" + list.joined(separator: "\n"))
	}
	if !p.notes.isEmpty {
		block.append("\n【说明】\n" + p.notes.map { "- \($0)" }.joined(separator: "\n"))
	}
	return block.joined(separator: "\n")
}

/// 给模型的回复有大小上限：一页一页往里放，放不下就在整页处停，末尾写明接着认哪几页。
/// 灵犀只给模型看工具结果的前 50 KB（UTF-8）或 2000 行，多的直接截掉：多页的密排中文很容易超过，
/// 后面的字连同末尾「要别的页用 pages 参数」的提示一起没了。所以上限留出余量，提示写在上限以内。
/// （Claude Code 的线是 5 万字符，中文约 15 万字节，比这宽得多。）
public struct ModelReply {
	public static let defaultMaxBytes = 45 * 1024
	public static let defaultMaxLines = 1800
	/// 给末尾提示留的地方。
	static let reserveBytes = 800
	static let reserveLines = 8

	public let totalPages: Int
	public let maxBytes: Int
	public let maxLines: Int
	/// 另附一块 JSON（detail=full）。灵犀把几块文字用空行接起来再截，所以 JSON 跟文字一起算在上限里。
	public let withJSON: Bool
	/// 已经放进去的页码。
	public private(set) var pages: [Int] = []
	/// 满了：有一页没放下。
	public private(set) var full = false
	/// 第一页单独就超了上限，只放进去了前面几行。
	public private(set) var cut: (page: Int, shown: Int, total: Int)?
	/// 第一页的字放得下，连 JSON 就放不下了：只给了字。
	public private(set) var jsonDropped = false
	var blocks: [String] = []
	var pageJSONs: [String] = []
	var bytes = 0
	var lines = 0

	public init(totalPages: Int, maxBytes: Int = defaultMaxBytes, maxLines: Int = defaultMaxLines, withJSON: Bool = false) {
		self.totalPages = totalPages
		self.maxBytes = maxBytes
		self.maxLines = maxLines
		self.withJSON = withJSON
	}

	/// JSON 块的外壳 `{"totalPages":N,"pages":[]}`，加上它和文字块之间的空行。
	var jsonShell: Int { "{\"totalPages\":\(totalPages),\"pages\":[]}".utf8.count + 2 }

	/// 放一页。放得下返回 true；放不下返回 false，后面的页也就不用再认了。
	/// 一页都还没放时，这页先不带 JSON 放，还放不下就按行截一部分，免得回复是空的。
	public mutating func add(_ page: PageResult) -> Bool {
		let block = renderPage(page, multi: totalPages > 1)
		let json = withJSON ? jsonString(pageJSON(page)) : ""
		let roomBytes = maxBytes - Self.reserveBytes, roomLines = maxLines - Self.reserveLines
		let first = blocks.isEmpty
		// 页和页之间空一行：多 2 个字节、1 行；JSON 里页和页之间一个逗号。JSON 整块是一行，前面空一行。
		var addBytes = block.utf8.count + (first ? 0 : 2)
		var addLines = countLines(block) + (first ? 0 : 1)
		if withJSON {
			addBytes += json.utf8.count + (first ? jsonShell : 1)
			addLines += first ? 2 : 0
		}
		if bytes + addBytes <= roomBytes && lines + addLines <= roomLines {
			blocks.append(block)
			if withJSON { pageJSONs.append(json) }
			bytes += addBytes
			lines += addLines
			pages.append(page.page)
			return true
		}
		full = true
		guard first else { return false }
		jsonDropped = withJSON
		pages = [page.page]
		if block.utf8.count <= roomBytes && countLines(block) <= roomLines {
			blocks = [block]
			return false
		}
		let all = block.components(separatedBy: "\n")
		var kept: [String] = []
		var used = 0
		for line in all {
			let size = line.utf8.count + (kept.isEmpty ? 0 : 1)
			if used + size > roomBytes || kept.count + 1 > roomLines { break }
			kept.append(line)
			used += size
		}
		if kept.isEmpty, let first = all.first { kept = [utf8Prefix(first, bytes: roomBytes)] }
		blocks = [kept.joined(separator: "\n")]
		cut = (page.page, kept.count, all.count)
		return false
	}

	/// 拼成回复的几块文字：先是给模型看的字，detail=full 时再加一块 JSON。`remaining`：这次要认、但没放进来的页码，按顺序。
	public func content(remaining: [Int]) -> [String] {
		var parts = blocks
		if let cut {
			parts.append("【\(totalPages > 1 ? "第 \(cut.page) 页" : "这张图")的字太多，一次回复放不下，只给了前 \(cut.shown) 行（共 \(cut.total) 行）；可以用 region 参数把它分成几块认】")
		}
		if jsonDropped {
			parts.append("【连同 JSON 一次回复放不下，这次只给了字；要每行位置这些完整结果，用 ocr_to_file 写成文件】")
		}
		if !remaining.isEmpty {
			let why = full ? "一次回复最多约 \(maxBytes / 1024) KB，再多放不下" : "一次最多认 \(ImageLimits.maxPages) 页"
			parts.append("【这次给了第 \(pageRanges(pages)) 页（\(why)）；文件一共 \(totalPages) 页，没给的接着用 pages=\"\(shortRanges(remaining))\"；要整份全文可以用 ocr_to_file 写成文件】")
		}
		var out = [parts.joined(separator: "\n\n")]
		if withJSON && !pageJSONs.isEmpty {
			out.append("{\"totalPages\":\(totalPages),\"pages\":[" + pageJSONs.joined(separator: ",") + "]}")
		}
		return out
	}

	/// 客户端最后看到的样子：几块文字用空行接起来（灵犀就是这么接的）。
	public func text(remaining: [Int]) -> String {
		content(remaining: remaining).joined(separator: "\n\n")
	}
}

/// 页码区间，太长时截到约 200 字节，末尾写「…」。
public func shortRanges(_ pages: [Int]) -> String {
	let s = pageRanges(pages)
	guard s.utf8.count > 200 else { return s }
	return utf8Prefix(s, bytes: 200).split(separator: ",").dropLast().joined(separator: ",") + ",…"
}

/// [1, 2, 3, 5, 7, 8] → "1-3,5,7-8"
public func pageRanges(_ pages: [Int]) -> String {
	var parts: [String] = []
	var i = 0
	while i < pages.count {
		var j = i
		while j + 1 < pages.count && pages[j + 1] == pages[j] + 1 { j += 1 }
		parts.append(j > i ? "\(pages[i])-\(pages[j])" : "\(pages[i])")
		i = j + 1
	}
	return parts.joined(separator: ",")
}

func countLines(_ s: String) -> Int {
	s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
}

/// 按 UTF-8 字节截字符串，不切坏字。
func utf8Prefix(_ s: String, bytes: Int) -> String {
	var out = ""
	var used = 0
	for ch in s {
		let n = String(ch).utf8.count
		if used + n > bytes { break }
		out.append(ch)
		used += n
	}
	return out
}

/// 完整的结构化结果（命令行 --json、MCP 的 detail=full）。
public func resultJSON(_ pages: [PageResult], totalPages: Int) -> [String: Any] {
	["totalPages": totalPages, "pages": pages.map(pageJSON)]
}

public func pageJSON(_ p: PageResult) -> [String: Any] {
	var d: [String: Any] = [
		"page": p.page, "width": p.width, "height": p.height, "mode": p.mode.rawValue,
		"coordinateSpace": p.coordinateSpace, "text": p.text,
		"lines": p.lines.map(lineJSON), "barcodes": p.barcodes, "notes": p.notes, "steps": p.steps,
	]
	if p.textLayer { d["source"] = "textLayer" }
	if let doc = p.document {
		if let t = doc.title { d["title"] = t }
		d["paragraphs"] = doc.paragraphs.map { ["text": $0.text, "box": $0.box.array] }
		d["tables"] = doc.tables.map { t -> [String: Any] in
			[
				"rows": t.grid, "box": t.box.array,
				"cells": t.cells.map { ["row": [$0.rows.lowerBound, $0.rows.upperBound], "col": [$0.columns.lowerBound, $0.columns.upperBound], "text": $0.text] },
			]
		}
		d["lists"] = doc.lists.map { $0.map { ["marker": $0.marker, "text": $0.text] } }
		d["data"] = doc.data
	}
	return d
}

/// 正的行四个角就是 box 的四个角，不再写 quad（正的行很常见，扫描件上也不少，每行省 8 个数）；
/// 斜着、倒着的行才写，quad 的顺序跟着字的走向，倒着的字「左上」在图的右下。
func lineJSON(_ l: OCRLine) -> [String: Any] {
	var d: [String: Any] = ["text": l.text, "confidence": round4(l.confidence), "box": l.box.array]
	if !l.upright { d["quad"] = l.quad.map(\.array) }
	if let s = l.suspect {
		var m: [String: Any] = ["reason": s.reason.rawValue]
		if let p = s.probability { m["probability"] = p }
		d["suspect"] = m
	}
	return d
}

extension OCRLine {
	/// 字是正的、没歪：按字的走向排的四个角，正好是 box 的左上、右上、右下、左下。
	var upright: Bool {
		let b = box
		let corners = [NPoint(x: b.x, y: b.y), NPoint(x: b.maxX, y: b.y), NPoint(x: b.maxX, y: b.maxY), NPoint(x: b.x, y: b.maxY)]
		return quad.count == 4 && zip(quad, corners).allSatisfy { abs($0.x - $1.x) < 1e-4 && abs($0.y - $1.y) < 1e-4 }
	}
}

public func jsonString(_ obj: Any, pretty: Bool = false) -> String {
	var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
	if pretty { opts.insert(.prettyPrinted) }
	guard let data = try? JSONSerialization.data(withJSONObject: shortNumbers(obj), options: opts) else { return "{}" }
	return String(data: data, encoding: .utf8) ?? "{}"
}

/// 小数照最短的写法写：JSONSerialization 写 Double 一律 17 位有效数字，0.0652 写成 0.065199999999999994，
/// JSON 因此白白长出一大截。换成 Decimal 就照字面写。只认真正的 Double：整数、真假值原样不动。
func shortNumbers(_ v: Any) -> Any {
	if type(of: v) == Double.self, let d = v as? Double, d.isFinite, let short = Decimal(string: "\(d)") { return short }
	if let list = v as? [Any] { return list.map(shortNumbers) }
	if let map = v as? [String: Any] { return map.mapValues(shortNumbers) }
	return v
}
