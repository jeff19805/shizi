import Foundation
import OCRCore

enum Tools {
	static let names: Set<String> = ["ocr_image", "ocr_to_file", "photos_search", "ocr_status"]

	static let ocrImageDescription = """
		用 macOS 自带的文字识别读图片（PNG、JPEG、HEIC、TIFF 等）或 PDF 里的字，全在本机、不联网。
		自动处理：任意角度的旋转（倒着的也行）；大图里的小字（自动切块细认，接缝处切开的长行会拼回去）；表格、多栏、竖排（macOS 26 起走「认文档」，表格输出成 Markdown）；手机照片的方向标记。
		装了判定插件时还会：先看图决定怎么认、自动拉正拍歪的纸、复核可疑的行。没装插件时只在要认文档且纸明显歪了时才拉正，拍歪的照片可以传 rectify=on。
		认不了或认不准：表情符号（直接丢）、公式里的上下标、字高不到约 8 像素的字、印章那种沿弧线排的字、真手写（没测过）。
		PDF 里有文字（Word、浏览器导出的）时直接用它的字，一字不差、快得多，插图另外认；扫描件、扫描件上别的软件加的隐形文字层照常认图。
		可能认错的行会在结果末尾单独列出，正文里原样保留、没有删。
		一次回复有大小上限：多页 PDF 放不下时只给前几页，末尾写明没给的页接着用什么 pages 参数；要整份全文用 ocr_to_file。
		"""

	static let ocrToFileDescription = """
		跟 ocr_image 一样认图片或 PDF，但整份认完写成文件，回复里只给文件路径、页数、字数、用时和每页开头一句。
		适合页数多、要全文的文档：一次最多 100 页（认图时不带插件约 0.8 秒一页，带插件约 1.6 秒；PDF 自带文字的页几十毫秒一页），多的末尾写明接着用什么 pages。
		文件里每页的写法跟 ocr_image 的回复一样；detail=full 时另写一份同名的 .json。
		默认写到 ~/Library/Caches/shizi/results/（下次往那里写的时候，顺手清掉 7 天前的），要留着就用 outputPath 指定；不会覆盖已有的文件。
		"""

	static let photosSearchDescription = """
		在「拾字」认过的照片里按字找照片（照片图库里的截屏、拍的文件、票据这些）：回文件名、拍摄时间和字里那一段。
		只搜拾字认过的照片，不碰照片图库本身；没认过的照片搜不到，要先在拾字里打开「照片」认一下。
		"""

	/// 两个认字工具共用的参数。
	static var ocrProperties: [String: Any] {
		[
			"path": ["type": "string", "description": "图片或 PDF 的路径，可以用 ~"],
			"pages": ["type": "string", "description": "PDF 页码，如 \"1-3,5\"；默认从头起"],
			"mode": [
				"type": "string", "enum": ["auto", "lines", "document"],
				"description": "auto（默认）自动选；lines 逐行识别；document 认文档（段落、表格、列表、竖排，要 macOS 26）",
			],
			"languages": [
				"type": "array", "items": ["type": "string"],
				"description":
					"不给：照拾字设置里的「识别语言」（默认自动判断）。[\"chinese-first\"]：中文优先，汉字夹在字母、数字、算式里也认得准，整页几乎没有汉字或中文认不了的字时自动改回自动判断；[\"auto\"]：系统一行一行自己判断（中文行里字母数字多时汉字可能认成乱码）；[\"zh-Hans\", \"en-US\"]、[\"ja-JP\"] 这样：指定语言，只用第一个语言的模型（中日韩的会排到最前）",
			],
			"region": [
				"type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
				"description": "只认图里这一块：[左, 上, 宽, 高]，0–1，左上角为原点；结果坐标仍相对整张图",
			],
			"rectify": ["type": "string", "enum": ["auto", "on", "off"], "description": "拉正拍歪的纸；默认 auto"],
			"tiles": ["type": "string", "enum": ["auto", "on", "off"], "description": "大图小字切块细认；默认 auto"],
			"barcodes": ["type": "boolean", "description": "找不找二维码 / 条码，默认找"],
			"detail": [
				"type": "string", "enum": ["text", "full"],
				"description": "text（默认）只给文字；full 另附一块 JSON：每行位置、可信度、表格格子等（没有 quad 的行是正的，四角就是 box 的四角）",
			],
			"plugins": ["type": "boolean", "description": "这次调不调判定插件，默认调（没配就没有）"],
			"textLayer": [
				"type": "boolean",
				"description":
					"PDF 里有文字时直接用，默认 true：Word、浏览器导出的 PDF 一字不差、快得多，里面的图片另外认；扫描件、别的软件加的隐形文字层、乱码的照样认图。false 就全部认图（mode=document 时也不用）",
			],
		]
	}

	static var definitions: [[String: Any]] {
		var toFile = ocrProperties
		toFile["outputPath"] = [
			"type": "string",
			"description": "写到哪：以 .md 结尾的绝对路径（可以用 ~），或者一个已有的文件夹（在里面按「源文件名-时间」起名）；不给就写到缓存文件夹",
		]
		return [
			[
				"name": "ocr_image",
				"title": "认图片或 PDF 里的字",
				"description": ocrImageDescription,
				"inputSchema": ["type": "object", "properties": ocrProperties, "required": ["path"], "additionalProperties": false],
				"annotations": ["readOnlyHint": true, "openWorldHint": false],
			],
			[
				"name": "ocr_to_file",
				"title": "认图片或 PDF 里的字，整份写成文件",
				"description": ocrToFileDescription,
				"inputSchema": ["type": "object", "properties": toFile, "required": ["path"], "additionalProperties": false],
				// 会新建文件，但不改、不删已有的文件。
				"annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
			],
			[
				"name": "photos_search",
				"title": "按字找照片",
				"description": photosSearchDescription,
				"inputSchema": [
					"type": "object",
					"properties": [
						"query": ["type": "string", "description": "要找的字，比如「发票」「Wi-Fi 密码」；照片里认出的字包含它就算"],
						"limit": ["type": "integer", "description": "最多回几张，默认 20，最多 50"],
					],
					"required": ["query"], "additionalProperties": false,
				],
				"annotations": ["readOnlyHint": true, "openWorldHint": false],
			],
			[
				"name": "ocr_status",
				"title": "文字识别能力与插件状况",
				"description": "说明这台机器的系统版本、能不能认文档（表格、多栏、竖排）、支持哪些语言，以及配置了哪些判定插件、连不连得上。",
				"inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
				"annotations": ["readOnlyHint": true, "openWorldHint": false],
			],
		]
	}

	/// `progress(认完几页, 这次一共要认几页)`：客户端要了进度时，每认完一页报一次。
	static func call(
		_ engine: OCREngine, name: String, arguments: [String: Any], maxReplyBytes: Int = ModelReply.defaultMaxBytes,
		progress: ((Int, Int) -> Void)? = nil
	) -> [String: Any] {
		switch name {
		case "ocr_status":
			return text(statusText(engine))
		case "photos_search":
			do {
				return text(try photosSearch(arguments, index: photoIndexPath))
			} catch {
				return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
			}
		default:
			do {
				let request = try ocrRequest(arguments, toFile: name == "ocr_to_file")
				if name == "ocr_to_file" { return try toFile(engine, request, progress: progress) }
				return try inline(engine, request, maxReplyBytes: maxReplyBytes, progress: progress)
			} catch {
				return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
			}
		}
	}

	/// ocr_image：一页一页认、一页一页往回复里放；放不下了就不再往下认，省得白认。
	/// detail=full 的 JSON 是第二块文字，不放 structuredContent：灵犀只看文字块，Claude Code 有 structuredContent 时只看它、
	/// 把文字块全扔掉，两块文字是两边看到同样东西的唯一写法。
	static func inline(_ engine: OCREngine, _ r: OCRRequest, maxReplyBytes: Int, progress: ((Int, Int) -> Void)?) throws -> [String: Any] {
		let source = try PageSource(path: r.path)
		let todo = try source.select(r.options.pages, limit: ImageLimits.maxPages)
		var model = ModelReply(totalPages: source.totalPages, maxBytes: maxReplyBytes, withJSON: r.full)
		var done = 0
		try engine.run(source, pages: todo, options: r.options) { page in
			done += 1
			progress?(done, todo.count)
			return model.add(page)
		}
		let remaining = source.wanted(r.options.pages).filter { !model.pages.contains($0) }
		return ["content": model.content(remaining: remaining).map { ["type": "text", "text": $0] }]
	}

	/// ocr_to_file：整份认完，一页一页写进文件，回复只给摘要。
	static func toFile(_ engine: OCREngine, _ r: OCRRequest, progress: ((Int, Int) -> Void)?) throws -> [String: Any] {
		let source = try PageSource(path: r.path)
		let todo = try source.select(r.options.pages, limit: FileOutput.maxPages)
		let url = try FileOutput.target(r.outputPath, source: r.path, pages: todo, totalPages: source.totalPages)
		let stamp = DateFormatter()
		stamp.locale = Locale(identifier: "en_US_POSIX")
		stamp.dateFormat = "yyyy-MM-dd HH:mm"
		let sourcePath = expandPath(r.path)
		let header = """
			# \((sourcePath as NSString).lastPathComponent) 认出的字

			来源：\(sourcePath)　第 \(pageRanges(todo)) 页（共 \(source.totalPages) 页）　拾字 \(OCRVersion.current)　\(stamp.string(from: Date()))
			"""
		let file = try ResultFile(markdownURL: url, withJSON: r.full, header: header, totalPages: source.totalPages)
		let started = Date()
		do {
			try engine.run(source, pages: todo, options: r.options) { page in
				try file.add(page)
				progress?(file.pages.count, todo.count)
				return true
			}
			try file.finish()
		} catch {
			try? file.finish()
			throw OCRError.recognition("认到一半出错（\(error)）；已经写下的 \(file.pages.count) 页在 \(url.path)")
		}
		let remaining = source.wanted(r.options.pages).filter { !file.pages.contains($0) }
		return text(FileOutput.summary(file, totalPages: source.totalPages, remaining: remaining, seconds: Date().timeIntervalSince(started)))
	}

	/// 拾字的照片库在哪（测试里换成临时的）。
	nonisolated(unsafe) static var photoIndexPath = PhotoIndex.defaultPath

	/// 在拾字认过的照片里按字找。回复末尾一定写上一共认过几张：模型没别的办法知道搜的范围。
	static func photosSearch(_ a: [String: Any], index path: String) throws -> String {
		if let extra = a.keys.first(where: { !["query", "limit"].contains($0) }) { throw ArgumentError.invalid("不认识的参数 \(extra)") }
		guard let query = (a["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
			throw ArgumentError.invalid("要给 query：要找的字")
		}
		let limit = min(max((a["limit"] as? NSNumber)?.intValue ?? 20, 1), 50)
		guard FileManager.default.fileExists(atPath: path), let index = try? PhotoIndex(path: path, readOnly: true) else {
			return "拾字还没认过照片：在拾字里打开「照片」，选一个相簿点「识别」以后才搜得到。"
		}
		let stats = index.stats()
		let hits = index.search(query, limit: limit)
		let day = DateFormatter()
		day.locale = Locale(identifier: "en_US_POSIX")
		day.dateFormat = "yyyy-MM-dd HH:mm"
		var lines: [String] = []
		if hits.isEmpty {
			lines.append("拾字认过的照片里，没有字里带「\(query)」的。")
		} else {
			lines.append("拾字认过的照片里，字里带「\(query)」的\(hits.count == limit ? "至少" : "有") \(hits.count) 张（新拍的在前）：")
			for (i, r) in hits.enumerated() {
				let when = r.taken.map { day.string(from: $0) } ?? "拍摄时间不详"
				lines.append("\(i + 1). \(r.name ?? "（没有文件名）")　\(when)　\(PhotoIndex.snippet(r.text, around: query))")
			}
		}
		let newest = stats.newest.map { "，最近一次 \(day.string(from: $0))" } ?? ""
		var trailer = "【拾字认过 \(stats.count - stats.inCloud - stats.failed) 张照片（\(stats.withText) 张有字）\(newest)；没认过的照片搜不到"
		let pending = [stats.inCloud > 0 ? "\(stats.inCloud) 张原图在 iCloud 上" : nil, stats.failed > 0 ? "\(stats.failed) 张出错" : nil]
			.compactMap { $0 }
		if !pending.isEmpty { trailer += "，另有 " + pending.joined(separator: "、") + "，还没认" }
		lines.append("")
		lines.append(trailer + "】")
		return lines.joined(separator: "\n")
	}

	static func text(_ s: String) -> [String: Any] {
		["content": [["type": "text", "text": s]]]
	}

	struct OCRRequest {
		var options: OCROptions
		var path: String
		var full: Bool
		var outputPath: String?
	}

	static func ocrRequest(_ a: [String: Any], toFile: Bool) throws -> OCRRequest {
		var known: Set<String> = ["path", "pages", "mode", "languages", "region", "rectify", "tiles", "barcodes", "detail", "plugins", "textLayer"]
		if toFile { known.insert("outputPath") }
		if let extra = a.keys.first(where: { !known.contains($0) }) { throw ArgumentError.invalid("不认识的参数 \(extra)") }
		guard let path = a["path"] as? String, !path.isEmpty else { throw ArgumentError.invalid("要给 path：图片或 PDF 的路径") }
		var o = OCROptions()
		if let p = a["pages"] {
			if let s = p as? String {
				o.pages = try parsePages(s)
			} else if let n = (p as? NSNumber)?.intValue {
				o.pages = [n]
			} else {
				throw ArgumentError.invalid("pages 写法是 \"1-3,5\"")
			}
		}
		o.mode = try parseEnum(a["mode"] as? String, "mode", default: .auto)
		if let l = a["languages"] {
			let list: [String]
			if let items = l as? [String] {
				list = items
			} else if let s = l as? String {
				list = s.split(separator: ",").map(String.init)
			} else {
				throw ArgumentError.invalid("languages 要一个字符串数组，如 [\"chinese-first\"]、[\"zh-Hans\", \"en-US\"]")
			}
			(o.languages, o.languagePreference) = parseLanguages(list)
		}
		if let r = a["region"] {
			guard let list = r as? [Any] else { throw ArgumentError.invalid("region 要四个数：[左, 上, 宽, 高]") }
			o.region = try parseRegion(list.compactMap { ($0 as? NSNumber)?.doubleValue })
		}
		o.rectify = try parseEnum(a["rectify"] as? String, "rectify", default: .auto)
		o.tiles = try parseEnum(a["tiles"] as? String, "tiles", default: .auto)
		o.barcodes = (a["barcodes"] as? Bool) ?? true
		o.usePlugins = (a["plugins"] as? Bool) ?? true
		o.textLayer = (a["textLayer"] as? Bool) ?? true
		let detail = a["detail"] as? String ?? "text"
		guard detail == "text" || detail == "full" else { throw ArgumentError.invalid("detail 只能是 text 或 full") }
		if a["outputPath"] != nil && !(a["outputPath"] is String) { throw ArgumentError.invalid("outputPath 要一个路径字符串") }
		return OCRRequest(options: o, path: path, full: detail == "full", outputPath: a["outputPath"] as? String)
	}
}
