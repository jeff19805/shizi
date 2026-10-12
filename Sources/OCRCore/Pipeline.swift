import CoreGraphics
import Foundation

public enum OCRMode: String, Sendable {
	case auto, lines, document
}

public enum Switch: String, Sendable {
	case auto, on, off
}

public struct OCROptions: Sendable {
	public var mode: OCRMode = .auto
	/// 指定语言（中日韩的会排到最前，见 `cjkFirst`）；nil = 照 `languagePreference`。
	public var languages: [String]?
	/// 没指定语言时怎么认；nil = 照配置文件（拾字设置里的「识别语言」），没配就是自动判断。
	public var languagePreference: LanguagePreference?
	/// 只认图里这一块（左上原点、0–1）。结果坐标仍相对整张原图。
	public var region: NRect?
	public var rectify: Switch = .auto
	/// 大图小字切块细认。
	public var tiles: Switch = .auto
	/// 找二维码 / 条码。默认开：常驻进程里每张只多花一点时间（第一次要加载，慢一些）。认文档模式本来就会找。
	public var barcodes = true
	public var usePlugins = true
	/// PDF 页码（从 1 开始）；nil = 从头起最多 20 页。
	public var pages: [Int]?
	public var correction = true
	/// PDF 里有文字时直接用（见 TextLayer.swift）；关掉就跟以前一样全部 OCR。
	public var textLayer = true

	public init() {}
}

public struct PageResult {
	public var page: Int
	/// 坐标所相对的那张图的像素尺寸（拉正过就是拉正后的图）。
	public var width: Int
	public var height: Int
	/// 最后用的是逐行还是认文档。
	public var mode: OCRMode
	/// 阅读顺序。
	public var lines: [OCRLine]
	/// 给只看文字的模型的：分栏页面每段开头带〔中间〕〔左侧〕这类位置标记。
	public var text: String
	/// 跟 text 同样的顺序，但不带位置标记：给人看、导出用（人看得到原图，标记是多余的字）。
	public var cleanText: String
	public var document: DocResult?
	public var barcodes: [String]
	public var notes: [String]
	/// "original"：相对原图（给了 region 也换算回原图）；"rectified"：相对拉正后的图，换算不回原图。
	public var coordinateSpace: String
	/// 拉正过的页才有：坐标相对的就是这张图，界面要在它上面画框。
	public var rectifiedImage: CGImage?
	/// 这一页走了哪些步骤、插件信号、耗时，方便排查。
	public var steps: [String: Any]
	/// 字是 PDF 自带的文字层（没有 OCR；图片区另外认的照样在 lines 里）。
	public var textLayer = false
	/// 文字层的页上另外认了的图片区（0–1、左上原点）。框选框到这些地方要认图，别处直接按框取文字层的字。
	public var pictureBoxes: [NRect] = []

	public init(
		page: Int, width: Int, height: Int, mode: OCRMode, lines: [OCRLine], text: String, cleanText: String, document: DocResult?,
		barcodes: [String], notes: [String], coordinateSpace: String, rectifiedImage: CGImage?, steps: [String: Any]
	) {
		self.page = page
		self.width = width
		self.height = height
		self.mode = mode
		self.lines = lines
		self.text = text
		self.cleanText = cleanText
		self.document = document
		self.barcodes = barcodes
		self.notes = notes
		self.coordinateSpace = coordinateSpace
		self.rectifiedImage = rectifiedImage
		self.steps = steps
	}
}

public final class OCREngine {
	public let host: PluginHost
	public let configPath: String?
	public let configProblem: String?
	/// 没指定语言时怎么认（配置文件里的；调用时 `OCROptions.languagePreference` 可以换）。
	public let languagePreference: LanguagePreference

	public init(config: OCRConfig = OCRConfig(), configPath: String? = nil, configProblem: String? = nil,
		environment: [String: String] = ProcessInfo.processInfo.environment)
	{
		host = PluginHost(config: config, environment: environment)
		self.configPath = configPath
		self.configProblem = configProblem
		languagePreference = config.languagePreference
	}

	/// 按默认位置读配置（文件不存在 = 没有插件）。
	public static func fromDefaultConfig(environment: [String: String] = ProcessInfo.processInfo.environment) -> OCREngine {
		let path = OCRConfig.defaultPath(environment)
		let (config, problem) = OCRConfig.load(path: path)
		return OCREngine(config: config, configPath: path, configProblem: problem, environment: environment)
	}

	public static var documentModeAvailable: Bool {
		if #available(macOS 26.0, *) { return true }
		return false
	}

	/// 认图片或 PDF：`options.pages` 指定的页（没指定就从头起），最多 `ImageLimits.maxPages` 页，全部认完一起返回。
	public func run(path: String, options: OCROptions) throws -> (pages: [PageResult], totalPages: Int) {
		let source = try PageSource(path: path)
		var pages: [PageResult] = []
		try run(source, pages: try source.select(options.pages, limit: ImageLimits.maxPages), options: options) {
			pages.append($0)
			return true
		}
		return (pages, source.totalPages)
	}

	/// 一页一页地认，每认完一页回调一次；回调返回 false 就不再往下认（取消了，或者结果已经够多）。
	/// 每页的图认完就放掉：几百页的 PDF 内存也不会跟着页数涨。
	public func run(_ source: PageSource, pages: [Int], options: OCROptions, onPage: (PageResult) throws -> Bool) throws {
		let memory = RunMemory()
		for n in pages {
			// 识别和画图会留下一批等「自动释放」的临时对象，循环里不及时清，页数一多照样越积越多。
			let goOn = try autoreleasepool { try onPage(try runPage(source, page: n, options: options, memory: memory)) }
			if !goOn { return }
		}
	}

	/// `memory`：一份文件（或一批照片）一页页认时传同一个，中文优先时记住上一页是不是西文；单认一张不用传。
	public func runPage(_ original: CGImage, page: Int, options: OCROptions, memory: RunMemory? = nil) throws -> PageResult {
		let started = Date()
		var notes: [String] = []
		var steps: [String: Any] = [:]
		if let p = configProblem { notes.append(p) }
		var image = original
		if let region = options.region {
			guard let cropped = crop(original, region), cropped.width > 0, cropped.height > 0 else {
				throw OCRError.badArgument("region 裁出来是空的")
			}
			image = cropped
		}
		var lineOptions = LineOptions(correction: options.correction)
		if let langs = options.languages, !langs.isEmpty {
			lineOptions.languages = cjkFirst(langs)
			if lineOptions.languages != langs { notes.append("指定的语言里中日韩的排到了最前：系统只用第一个语言的模型，英文放前面时汉字全认错") }
		}
		let preference = lineOptions.languages == nil ? options.languagePreference ?? languagePreference : .auto
		let auto = options.mode == .auto
		let docAvailable = Self.documentModeAvailable

		// 1. 插件看图，跟第一遍识别同时进行（插件看一次图比识别一遍还慢，排在后面就得干等）。
		//    图直接给数据（base64 的 PNG，长边 1600：判定服务自己还会再缩，传大了白占带宽），不写临时文件。
		let routePlugins = options.usePlugins && auto ? host.plugins(for: "route") : []
		var pending: [(PluginConfig, PendingCall)] = []
		let routeStarted = Date()
		if !routePlugins.isEmpty, let png = pngData(downscaled(image, longSide: 1600)) {
			let input: [String: Any] = ["image": ["data": png.base64EncodedString(), "width": image.width, "height": image.height]]
			pending = routePlugins.map { ($0, host.start($0, hook: "route", input: input)) }
		}

		// 2. 第一遍：整图逐行。中文优先时先按中文认，西文页、中文认不了的页改回自动判断（见 chineseFirstPass）。
		var lines: [OCRLine]
		if preference == .chineseFirst {
			let first = try chineseFirstPass(image, correction: options.correction, memory: memory)
			lines = first.lines
			lineOptions = first.options
			steps["languages"] = first.pass.rawValue
			steps["languageCheck"] = first.check
		} else {
			lines = try recognizeLines(image, options: lineOptions)[0]
		}
		// 按中文认的结果，英文、代码里的标点改回半角（中文模型爱认成全角），认重了的一截去掉；后面每一遍按中文认的也一样。
		let halfWidth = lineOptions.languages?.first?.lowercased().hasPrefix("zh") == true
		func tidy(_ ls: [OCRLine]) -> [OCRLine] {
			halfWidth ? droppingContainedDuplicates(ls.map { $0.halfWidthPunctuation() }, width: image.width, height: image.height) : ls
		}
		lines = tidy(lines)

		// 3. 收插件信号：同一项取各插件里最大的。每个插件说了什么、等了多久也记下（界面的「识别详情」要给人看插件做了什么）。
		var signals: [String: Double] = [:]
		var routeLog: [[String: Any]] = []
		for (plugin, call) in pending {
			var entry: [String: Any] = ["name": plugin.name]
			switch call.wait() {
			case .success(let out):
				var mine: [String: Double] = [:]
				for (k, v) in (out["signals"] as? [String: Any]) ?? [:] {
					if let d = (v as? NSNumber)?.doubleValue {
						signals[k] = max(signals[k] ?? 0, d)
						mine[k] = round4(d)
					}
				}
				entry["signals"] = mine
			case .failure(let f):
				notes.append("\(f)，这一步按代码规则处理")
				entry["failed"] = f.message
			}
			entry["ms"] = Int(Date().timeIntervalSince(routeStarted) * 1000)
			routeLog.append(entry)
		}
		if !signals.isEmpty { steps["signals"] = signals.mapValues(round4) }
		if !routeLog.isEmpty { steps["route"] = routeLog }
		func signal(_ key: String) -> Bool { (signals[key] ?? 0) >= 0.5 }

		// 4. 要不要认文档：一个字没认出（多半是竖排）、插件说有表格 / 分栏 / 竖排、或代码看版面像多栏，任何一条成立就认。
		//    插件信号不能顶替代码判断：插件对歪着的两栏文章也可能给不到 0.5，光听它顺序就乱了；代码判断误报（界面截图）只多花一点时间。
		func wantsDocument(_ ls: [OCRLine], _ img: CGImage) -> Bool {
			guard docAvailable else { return false }
			switch options.mode {
			case .document: return true
			case .lines: return false
			case .auto:
				if ls.isEmpty || signal("table") || signal("columns") || signal("vertical") { return true }
				return looksMultiColumn(readingRows(ls, width: img.width, height: img.height))
			}
		}
		var wantDoc = wantsDocument(lines, image)

		// 5. 拉正。拉正会裁掉纸外面的东西，所以只在「纸明显歪了、四边形没贴着图边、九成五的字都在纸里」时才拉：
		//    没插件时还要「要认文档」，有插件时它说是拍的照片也行（它常把扫描件当成照片，全靠前两条挡住）。调用方要求拉正就照做。
		var coordinateSpace = "original"
		let photo = signal("photo")
		if options.rectify == .on || (options.rectify == .auto && (photo || wantDoc)) {
			if let (obs, kind) = Rectify.findQuad(image) {
				let quad = Rectify.corners(obs)
				let skew = Rectify.skewDegrees(quad, width: image.width, height: image.height)
				let inside = Rectify.fractionInside(quad, lines)
				let framed = !Rectify.touchesBorder(quad)
				let allowed = options.rectify == .on
					|| (framed && inside >= 0.95 && ((photo && skew > 1) || (wantDoc && skew > 3)))
				if allowed, let fixed = Rectify.apply(image, obs, kind: kind) {
					image = fixed.image
					coordinateSpace = "rectified"
					steps["rectified"] = ["kind": kind, "skewDegrees": round4(skew), "quad": quad.map(\.array)]
					notes.append("先把纸拉正再认；结果里的坐标相对拉正后的图")
					lines = tidy(try recognizeLines(image, options: lineOptions)[0])
					wantDoc = wantsDocument(lines, image)
				}
			} else if options.rectify == .on {
				notes.append("没找到纸边，没有拉正")
			}
		}

		// 6. 字太小：大图切块细认，小图放大一倍再认（紧裁的小字放大后认得准得多；只有放大后明显更好才换）。
		let big = image.pixelCount > internalPixelBudget
		let glyph = effectiveGlyphHeight(lines, width: image.width, height: image.height)
		if let g = glyph { steps["glyphPixels"] = round4(g) }
		// 门槛留足余量：估出来比门槛再矮几个像素，大图上就已经认不准；高清屏的界面截图字不算小，估出来在门槛之上，不用切块。
		let tinyByCode = lines.isEmpty || (glyph ?? 0) < 18
		if options.tiles == .on || (options.tiles == .auto && big && (tinyByCode || signal("tiny"))) {
			// 斜着的长行会跨过方块的上下接缝、被当成「切到的行」整批丢掉（歪着的满幅长行会丢掉一大半）：
			// 第一遍估得出倾斜角就先转正再切，认完把坐标换算回原图。
			let theta = dominantAngle(lines, width: image.width, height: image.height) * 180 / .pi
			let tiled: [OCRLine]
			let grid: String
			if lines.count >= 3, abs(theta) > 2, let upright = rotate(image, degrees: theta) {
				let t = try Tiles.recognize(upright, options: lineOptions)
				let back = RotationMap(degrees: theta, width: Double(image.width), height: Double(image.height))
				tiled = t.lines.map(back.toOriginal)
				grid = t.grid
				steps["deskewDegrees"] = round4(-theta)
			} else {
				let t = try Tiles.recognize(image, options: lineOptions)
				tiled = t.lines
				grid = t.grid
			}
			lines = Tiles.mergeWithFullPass(tiles: tidy(tiled), full: lines)
			steps["tiles"] = grid
			// 认文档对小字比逐行差得多，只有竖排非它不可。
			if auto && wantDoc && !signal("vertical") && !lines.isEmpty {
				wantDoc = false
				notes.append("字很小，切成 \(grid) 块细认；没走认文档，表格、分栏的结构没有保留")
			}
		} else if options.tiles == .auto && !big && (glyph ?? 0) < 14, let up = upscale(image, 2) {
			let upLines = tidy(try recognizeLines(up, options: lineOptions)[0])
			if quality(upLines) > quality(lines) * 1.1 {
				lines = upLines
				steps["upscaled"] = 2
			}
		}

		// 7. 表格线：逐行的阅读顺序按线围成的格子排（见 Rules.swift）。只在有并排着不止一段字的页上找：
		//    一栏的字有没有线顺序都一样，不白花找线的工夫。
		var rules: [RuleLine] = []
		if lines.count >= 3, readingRows(lines, width: image.width, height: image.height).contains(where: { $0.count >= 2 }),
			let unit = lineUnit(lines, width: image.width, height: image.height)
		{
			let rulesStarted = Date()
			let theta = dominantAngle(lines, width: image.width, height: image.height)
			rules = findRules(image, unit: unit, sideways: abs(sin(theta)) > abs(cos(theta)))
			steps["rules"] = ["found": rules.count, "ms": Int(Date().timeIntervalSince(rulesStarted) * 1000)]
		}
		var lineLayout: ReadingLayout?
		func layout() -> ReadingLayout {
			if let l = lineLayout { return l }
			let l = readingLayout(lines, width: image.width, height: image.height, rules: rules)
			lineLayout = l
			return l
		}

		// 8. 认文档，跟逐行结果合并（认文档给版面、逐行给字，见 fuse）。逐行认出的字有八成以上归得进它找到的格子、段落，
		//    才用它的版面；归不进的单列在最后。不能拿认文档「自己认出的字」去比：扫描件上它的字差，
		//    认出的字比逐行少，但版面是对的。
		var document: DocResult?
		var mode = OCRMode.lines
		if wantDoc, #available(macOS 26.0, *) {
			// 认文档跟逐行用同一套语言：中文优先定下来按中文认的页，认文档也按中文认。
			var doc = try recognizeDocument(image, languages: lineOptions.languages, correction: options.correction)
			if halfWidth { doc = doc.halfWidthPunctuation() }
			let fused = fuse(doc, lines: lines, width: image.width, height: image.height)
			let cover = bagRecall(of: lines.map(\.text).joined(), in: doc.lines.map(\.text).joined())
			steps["documentClaimed"] = round4(fused.claimed)
			steps["documentCoverage"] = round4(cover)
			// 还要么它自己认出了九成的字、要么找到了表格：没找到表格又漏字的页，它常把表格的每一列当成一段，
			// 整列整列地输出，不如逐行。插件说有表格（没说分栏）它却没找到表格，也按这个处理
			// （这种页它会把表头打乱）；两栏文章插件会报分栏，不受影响。
			let tableMissed = doc.tables.isEmpty && signal("table") && !signal("columns")
			let ruledForm = ruledFormInsteadOfDocument(doc, layout(), lineCount: lines.count)
			let layoutUseful = (cover >= 0.9 || !doc.tables.isEmpty) && !tableMissed && !ruledForm
			if options.mode == .document || lines.isEmpty || (fused.claimed >= 0.8 && layoutUseful) {
				document = fused
				mode = .document
				if options.mode == .document && fused.claimed < 0.8 {
					notes.append("逐行认出的字只有 \(Int(fused.claimed * 100))% 归进了认文档找到的版面，其余列在最后；可以用 mode=lines 对比")
				}
			} else if ruledForm {
				notes.append("认文档没找到表格，页上却画着表格线：用的是逐行结果，按线围成的格子一排排读")
			} else {
				notes.append("认文档找到的版面只装得下逐行结果的 \(Int(fused.claimed * 100))%，改用逐行结果；表格、分栏的结构没有保留")
			}
		}

		// 9. 条码、阅读顺序。认文档的顺序系统已经排好。
		var barcodes = document?.barcodes ?? []
		if document == nil && options.barcodes { barcodes = detectBarcodes(image) }
		var ordered: [OCRLine]
		let text: String, cleanText: String
		if let doc = document {
			ordered = doc.lines
			text = doc.text
			cleanText = doc.text
		} else {
			let layout = layout()
			ordered = layout.order.map { lines[$0] }
			text = joinLayout(layout, lines)
			cleanText = joinLayout(layout, lines, markers: false)
			if layout.position.contains(where: { $0 != nil }) {
				notes.append("〔中间〕〔左侧〕这类标记不是认出来的字，是它下面那段字的大致位置（相对整张图；指定了区域时相对那块区域）；分成几栏时才标")
			}
		}

		// 找了线的页记下：用上了几条、几行在格子里、几行跟别的行同在一格（排查顺序问题用）。
		if let l = lineLayout, var r = steps["rules"] as? [String: Any] {
			r["kept"] = l.rules
			r["enclosed"] = l.enclosed
			r["grouped"] = l.grouped
			steps["rules"] = r
		}

		// 10. 标可疑行（只标不删）。表格里的格子不标：短格子可信度普遍偏低（单个数字常是 0.3），内容已经在上面的表格里。
		let tableBoxes = document?.tables.map(\.box) ?? []
		markSuspects(&ordered, skip: { l in tableBoxes.contains { $0.contains(l.box.center) } }, usePlugins: options.usePlugins, notes: &notes, steps: &steps)

		if signal("curved") {
			notes.append("图里可能有沿圆圈或弧线排列的字（印章之类），这部分系统认不准；可以把那块裁出来单独处理")
		}
		if ordered.isEmpty && barcodes.isEmpty { notes.append("没认出字") }

		// 11. 给了 region 时坐标换算回整张原图。
		var width = image.width, height = image.height
		if coordinateSpace == "original" {
			width = original.width
			height = original.height
			if let region = options.region {
				ordered = ordered.map { $0.mapped(into: region) }
				document = document?.mapped(into: region)
			}
		}
		steps["mode"] = mode.rawValue
		steps["ms"] = Int(Date().timeIntervalSince(started) * 1000)
		return PageResult(
			page: page, width: width, height: height, mode: mode, lines: ordered, text: text, cleanText: cleanText, document: document,
			barcodes: barcodes, notes: notes, coordinateSpace: coordinateSpace, rectifiedImage: coordinateSpace == "rectified" ? image : nil,
			steps: steps)
	}

	/// 系统可信度最低那档（0.3）的行算可疑：坏行几乎都落在这一档，但也会误报一些好行。
	/// 有判定插件时，长一点的可疑行交给它复核；一两个字的短行没上下文，它判断不了，只按可信度标。
	func markSuspects(_ lines: inout [OCRLine], skip: (OCRLine) -> Bool, usePlugins: Bool, notes: inout [String], steps: inout [String: Any]) {
		// 只有认文档认出的行（合并时已标好）跟低可信度的行一样算可疑，有插件时一起复核。
		let low = lines.indices.filter { (lines[$0].confidence <= 0.31 || lines[$0].suspect?.reason == .documentOnly) && !skip(lines[$0]) }
		let candidates = low.filter { lines[$0].coreLength > 3 }
		var reviewed: [Int: Double] = [:]
		// 配了复核的插件时，记下这一页有几行要复核：没有的话界面好说「用不着复核」，不让人以为插件没起作用。
		if usePlugins && !host.plugins(for: "review").isEmpty { steps["reviewCandidates"] = candidates.count }
		let reviewers = usePlugins && !candidates.isEmpty ? host.plugins(for: "review") : []
		var reviewLog: [[String: Any]] = []
		for p in reviewers {
			let input: [String: Any] = [
				"lines": lines.enumerated().map { ["id": $0.offset, "text": $0.element.text, "confidence": round4($0.element.confidence)] },
				"candidates": candidates,
			]
			let started = Date()
			var entry: [String: Any] = ["name": p.name]
			switch host.call(p, hook: "review", input: input) {
			case .success(let out):
				var mine = 0, flagged = 0
				for (k, v) in (out["suspects"] as? [String: Any]) ?? [:] {
					if let i = Int(k), let d = (v as? NSNumber)?.doubleValue {
						reviewed[i] = max(reviewed[i] ?? 0, d)
						mine += 1
						if d >= 0.5 { flagged += 1 }
					}
				}
				entry["reviewed"] = mine
				entry["flagged"] = flagged
			case .failure(let f):
				notes.append("\(f)，可疑行只按系统可信度标")
				entry["failed"] = f.message
			}
			entry["ms"] = Int(Date().timeIntervalSince(started) * 1000)
			reviewLog.append(entry)
		}
		if !reviewers.isEmpty {
			steps["reviewed"] = reviewed.count
			steps["review"] = reviewLog
			// 第几行（按最后的阅读顺序）→ 插件认为认错的概率：逐行里标出哪些行插件看过。
			steps["reviewedLines"] = Dictionary(uniqueKeysWithValues: reviewed.map { (String($0.key), round4($0.value)) })
		}
		for i in low {
			if let p = reviewed[i] {
				lines[i].suspect = p >= 0.5 ? Suspect(reason: .plugin, probability: round4(p)) : nil
			} else if lines[i].suspect == nil {
				lines[i].suspect = Suspect(reason: .lowConfidence, probability: nil)
			}
		}
	}
}

/// 认文档没找到表格，逐行的行却有一半以上装在画了线的格子里、还有格子里不止一行：这页其实是画了线的表格，
/// 认文档会按段落一栏栏地出，标签全出完才出内容（几个标签并成一段，放在内容后面），
/// 按格子一排排读逐行结果更好。格子都只有一行时按格子排跟一行行排一样，没有拿得准的好处，照旧听认文档的。
/// 一半：页上只有一张小表、其余是段落和列表时，照旧用认文档（它会把折行的段落拼好）；该改走逐行的表格页，格子里的行一般远不止一半。
/// 不用三成：六行的小表加十四行正文就够三成了，这种页还是该听认文档的。
func ruledFormInsteadOfDocument(_ doc: DocResult, _ layout: ReadingLayout, lineCount: Int) -> Bool {
	doc.tables.isEmpty && layout.grouped > 0 && layout.enclosed * 2 >= lineCount
}

/// 认出来的字乘可信度的总和，用来比「放大前后哪次认得好」。
func quality(_ lines: [OCRLine]) -> Double {
	lines.reduce(0) { $0 + $1.confidence * Double($1.coreLength) }
}

func coreCharacters(_ s: String) -> [Character] {
	s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// a 里的字（只算字母、数字、汉字，不管顺序）有多大比例也出现在 b 里。
public func bagRecall(of a: String, in b: String) -> Double {
	let ca = coreCharacters(a)
	guard !ca.isEmpty else { return 1 }
	var pool: [Character: Int] = [:]
	for ch in coreCharacters(b) { pool[ch, default: 0] += 1 }
	var hit = 0
	for ch in ca {
		if let n = pool[ch], n > 0 {
			hit += 1
			pool[ch] = n - 1
		}
	}
	return Double(hit) / Double(ca.count)
}

extension DocResult {
	func mapped(into region: NRect) -> DocResult {
		var d = self
		d.lines = lines.map { $0.mapped(into: region) }
		d.paragraphs = paragraphs.map { DocParagraph(text: $0.text, box: $0.box.mapped(into: region), region: $0.region.map { $0.mapped(into: region) }) }
		d.tables = tables.map { t in
			DocTable(
				cells: t.cells.map {
					DocCell(rows: $0.rows, columns: $0.columns, text: $0.text, box: $0.box.mapped(into: region), region: $0.region.map { $0.mapped(into: region) })
				}, box: t.box.mapped(into: region))
		}
		return d
	}
}
