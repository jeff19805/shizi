import CoreGraphics
import DataDetection
import Foundation
import Vision

public struct DocParagraph: Sendable {
	public var text: String
	var coreLength: Int { text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count }
	public var box: NRect
	/// 系统给的轮廓（贴着文字走的多边形）；斜着的段落外接框会互相重叠，判断哪行归哪段要用它。
	public var region: [NPoint] = []
}

public struct DocCell: Sendable {
	public var rows: ClosedRange<Int>
	public var columns: ClosedRange<Int>
	public var text: String
	public var box: NRect
	public var region: [NPoint] = []
}

public struct DocTable: Sendable {
	public var cells: [DocCell]
	public var box: NRect

	/// 铺成网格：合并的格子只在左上那格放字，其余留空（系统认不出合并，常常直接给成空格）。
	public var grid: [[String]] {
		let rowCount = (cells.map(\.rows.upperBound).max() ?? -1) + 1
		let colCount = (cells.map(\.columns.upperBound).max() ?? -1) + 1
		var g = Array(repeating: Array(repeating: "", count: colCount), count: rowCount)
		for c in cells where c.rows.lowerBound < rowCount && c.columns.lowerBound < colCount {
			g[c.rows.lowerBound][c.columns.lowerBound] = c.text
		}
		return g
	}

	public var markdown: String {
		let g = grid
		guard let header = g.first else { return "" }
		func row(_ r: [String]) -> String {
			"| " + r.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
		}
		return ([row(header), "| " + Array(repeating: "---", count: header.count).joined(separator: " | ") + " |"] + g.dropFirst().map(row))
			.joined(separator: "\n")
	}
}

public struct DocListItem: Sendable {
	public var marker: String
	public var text: String
}

public struct DocResult: Sendable {
	public var title: String?
	public var paragraphs: [DocParagraph]
	public var lines: [OCRLine]
	public var tables: [DocTable]
	public var lists: [[DocListItem]]
	public var barcodes: [String]
	/// 系统从文字里挑出来的日期、邮箱、电话、网址、航班、地址等。
	public var data: [[String: String]]
	/// 合并后没归进任何格子、段落的逐行结果（多是公章、签名、手写），放在正文最后单列。
	public var extras: [OCRLine] = []
	/// 逐行认出的字里，归进了格子、段落的比例（只算字母、数字、汉字）。
	public var claimed: Double = 1

	/// 按系统给的阅读顺序拼文字；表格换成 Markdown 放在它第一次出现的位置，格子里的字不再逐段重复。
	public var text: String {
		var out: [String] = []
		var emitted = Set<Int>()
		for p in paragraphs {
			if let t = tables.firstIndex(where: { $0.box.contains(p.box.center) }) {
				if emitted.insert(t).inserted { out.append(tables[t].markdown) }
				continue
			}
			out.append(p.text)
		}
		for (i, t) in tables.enumerated() where !emitted.contains(i) { out.append(t.markdown) }
		if !extras.isEmpty {
			out.append(Texts.text("（以下是没归进版面的零散字，多半是公章、签名或手写）"))
			out += extras.map(\.text)
		}
		return out.joined(separator: "\n")
	}
}

/// 认文档时最小认多高的字（占图高的比例）。系统默认 1/32：扫描件上认文档的字明显变差、表格认不全，像是先把图缩小了再认。
/// 改成 1/64：复印机扫的表格页上，丢了的表格能找回来，顺序不对的行也明显少了；设成 0 反而又会丢表格。
/// 别的扫描件和验收用的测试图都没变差。
let documentMinimumTextHeight: Float = 1.0 / 64

/// 认文档（macOS 26 起才有，只有 Swift 接口）：段落、表格、列表、竖排都在这里。
@available(macOS 26.0, *)
public func recognizeDocument(_ image: CGImage, languages: [String]?, correction: Bool) throws -> DocResult {
	var req = RecognizeDocumentsRequest()
	if let langs = languages, !langs.isEmpty {
		req.textRecognitionOptions.recognitionLanguages = langs.map { Locale.Language(identifier: $0) }
	} else {
		req.textRecognitionOptions.automaticallyDetectLanguage = true
	}
	req.textRecognitionOptions.useLanguageCorrection = correction
	req.textRecognitionOptions.minimumTextHeightFraction = documentMinimumTextHeight
	req.barcodeDetectionOptions.enabled = true
	let request = req
	let observations = try runBlocking { try await request.perform(on: image) }
	guard let doc = observations.first?.document else {
		return DocResult(title: nil, paragraphs: [], lines: [], tables: [], lists: [], barcodes: [], data: [])
	}
	func box(_ r: NormalizedRect) -> NRect { NRect(visionRect: r.cgRect) }
	func outline(_ r: NormalizedRegion) -> [NPoint] { r.points.map { NPoint(visionPoint: $0.cgPoint) } }
	let lines = doc.text.lines.compactMap { obs -> OCRLine? in
		guard let best = obs.topCandidates(1).first, !best.string.isEmpty else { return nil }
		let quad = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { NPoint(visionPoint: $0.cgPoint) }
		return OCRLine(text: best.string, confidence: Double(best.confidence), box: box(obs.boundingBox), quad: quad)
	}
	return DocResult(
		title: doc.title?.transcript,
		paragraphs: doc.paragraphs.map {
			DocParagraph(text: $0.transcript, box: box($0.boundingRegion.boundingBox), region: outline($0.boundingRegion))
		},
		lines: lines,
		tables: doc.tables.map { t in
			DocTable(
				cells: t.rows.flatMap { $0 }.map {
					DocCell(
						rows: $0.rowRange, columns: $0.columnRange, text: $0.content.text.transcript,
						box: box($0.content.boundingRegion.boundingBox), region: outline($0.content.boundingRegion))
				},
				box: box(t.boundingRegion.boundingBox))
		},
		lists: doc.lists.map { $0.items.map { DocListItem(marker: $0.markerString.trimmingCharacters(in: .whitespaces), text: $0.itemString) } },
		barcodes: doc.barcodes.compactMap(\.payloadString),
		data: doc.text.detectedData.map { describe($0.match.details) })
}

@available(macOS 26.0, *)
func describe(_ d: DataDetector.Match.SemanticDetails) -> [String: String] {
	switch d {
	case .link(let v): return ["type": "link", "value": v.url.absoluteString]
	case .emailAddress(let v): return ["type": "email", "value": v.emailAddress]
	case .phoneNumber(let v): return ["type": "phone", "value": v.phoneNumber]
	case .postalAddress(let v): return ["type": "address", "value": v.fullAddress]
	case .calendarEvent(let v): return ["type": "date", "value": v.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
	case .moneyAmount(let v): return ["type": "money", "value": "\(v.amount) \(v.currency.identifier)"]
	case .flightNumber(let v): return ["type": "flight", "value": "\(v.airlineCode)\(v.flightNumber)"]
	default: return ["type": "other", "value": String(describing: d)]
	}
}

/// 认文档只有异步接口；整条流水线是同步的（一次只认一张，系统内部本来就排队），在这里等它做完。
func runBlocking<T>(_ op: @escaping () async throws -> T) throws -> T {
	let done = DispatchSemaphore(value: 0)
	var result: Result<T, Error>?
	Task.detached {
		do { result = .success(try await op()) } catch { result = .failure(error) }
		done.signal()
	}
	done.wait()
	return try result!.get()
}

/// 认文档给结构、逐行给字。
///
/// 扫描件上认文档的字明显更差（复印机扫的表格上，形近的字常认错，整列的序号也会丢），
/// 同一页逐行识别的字基本都对，只是表格顺序乱。所以每个格子、每一段的字，换成中心落在它范围里的逐行结果；
/// 两边至少一半的字对得上才换（防串格），原来是空的格子直接补上；对不上就留认文档自己的字。
/// 落在某个格子、段落里的行都算那块版面的（换没换字都算）；哪块都不在的才单列在最后。
func fuse(_ doc: DocResult, lines: [OCRLine], width: Int, height: Int) -> DocResult {
	guard !lines.isEmpty else { return doc }
	var used = Array(repeating: false, count: lines.count)
	var out = doc

	/// 返回落在这块里的行（按阅读顺序）和要换上的字；两边对不上时字是 nil，行照样算这块的。
	func claim(_ box: NRect, _ region: [NPoint], against original: String, cell: Bool) -> (text: String?, picked: [Int]) {
		let inside: (NPoint) -> Bool = region.count >= 3 ? { polygonContains(region, $0) } : { box.contains($0) }
		let idx = lines.indices.filter { !used[$0] && inside(lines[$0].box.center) }
		guard !idx.isEmpty else { return (nil, []) }
		let subset = idx.map { lines[$0] }
		let rowIdx = readingRows(subset, width: width, height: height)
		let rows = rowIdx.map { $0.map { subset[$0].text }.joined(separator: " ") }
		let text = cell ? rows.joined(separator: " ") : joinWrapped(rows)
		let picked = rowIdx.flatMap { $0.map { idx[$0] } }
		picked.forEach { used[$0] = true }
		// 两个方向都要对得上一半：只看一边，斜着的段落会把别段的行一起认领走（歪着的两栏文章，两栏的行会搅在一起）。
		let agrees = original.isEmpty || (bagRecall(of: original, in: text) >= 0.5 && bagRecall(of: text, in: original) >= 0.5)
		return (agrees ? text : nil, picked)
	}

	var cellLines: [[Int]] = Array(repeating: [], count: doc.tables.count)
	for (ti, table) in doc.tables.enumerated() {
		let order = table.cells.indices.sorted { (table.cells[$0].rows.lowerBound, table.cells[$0].columns.lowerBound) < (table.cells[$1].rows.lowerBound, table.cells[$1].columns.lowerBound) }
		for ci in order {
			let c = table.cells[ci]
			let hit = claim(c.box, c.region, against: c.text, cell: true)
			if let t = hit.text { out.tables[ti].cells[ci].text = t }
			cellLines[ti] += hit.picked
		}
	}
	var emitted = Set<Int>()
	var orderedLines: [OCRLine] = []
	var repeated = IndexSet()
	let compact = { (s: String) in String(s.filter { !$0.isWhitespace }) }
	for (pi, p) in doc.paragraphs.enumerated() {
		if let ti = doc.tables.firstIndex(where: { $0.box.contains(p.box.center) }) {
			if emitted.insert(ti).inserted { orderedLines += cellLines[ti].map { lines[$0] } }
			continue
		}
		let hit = claim(p.box, p.region, against: p.text, cell: false)
		// 认文档有时把一行里的一截单独当成一段（界面截图上，一行开头的几个字会多出来单独一段）：
		// 这段字已经在盖住它的那一行里了，不再单列，也不算「只有认文档认出」。
		if hit.picked.isEmpty, p.coreLength > 0, p.box.area > 0,
			lines.contains(where: { $0.box.overlapArea(p.box) >= 0.6 * p.box.area && compact($0.text).contains(compact(p.text)) })
		{
			repeated.insert(pi)
			continue
		}
		if let t = hit.text { out.paragraphs[pi].text = t }
		orderedLines += hit.picked.map { lines[$0] }
		// 逐行识别在这段里什么都没认出：留认文档自己的字，把它那几行也放进清单、标成可疑，好让人（或插件）复核。
		if hit.picked.isEmpty, p.coreLength > 0 {
			let inside: (NPoint) -> Bool = p.region.count >= 3 ? { polygonContains(p.region, $0) } : { p.box.contains($0) }
			orderedLines += doc.lines.filter { inside($0.box.center) }.map {
				var l = $0
				l.suspect = Suspect(reason: .documentOnly, probability: nil)
				return l
			}
		}
	}
	out.paragraphs = out.paragraphs.enumerated().filter { !repeated.contains($0.offset) }.map(\.element)
	for ti in doc.tables.indices where !emitted.contains(ti) { orderedLines += cellLines[ti].map { lines[$0] } }
	let rest = lines.indices.filter { !used[$0] }
	let restRows = readingRows(rest.map { lines[$0] }, width: width, height: height).flatMap { $0.map { rest[$0] } }
	out.extras = restRows.map { lines[$0] }
	out.lines = orderedLines + out.extras
	let total = lines.reduce(0) { $0 + $1.coreLength }
	let inLayout = lines.indices.filter { used[$0] }.reduce(0) { $0 + lines[$1].coreLength }
	out.claimed = total == 0 ? 1 : Double(inLayout) / Double(total)
	return out
}

/// 一段里折行的几行接起来：只有两边都是西文字母或数字时才补空格（中文折行不该多出空格）。
func joinWrapped(_ rows: [String]) -> String {
	var out = ""
	for r in rows {
		if let a = out.last, let b = r.first, a.isASCII, b.isASCII, a.isLetter || a.isNumber, b.isLetter || b.isNumber { out += " " }
		out += r
	}
	return out
}
