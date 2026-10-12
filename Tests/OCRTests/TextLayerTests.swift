import CoreGraphics
import CoreImage
import CoreText
import Foundation
import PDFKit
import Testing
@testable import OCRCore
@testable import ShiziKit

/// 现画一页 PDF 的内容：可见的字、隐形的字（像扫描仪加的 OCR 层）、一张图（放在页面的哪块，PDF 页面坐标）。
struct FakePage {
	var visible: [String] = []
	var hidden: [String] = []
	var picture: (image: CGImage, rect: CGRect)?
}

/// A4（595 × 842）的 PDF，字从上往下一行一行排，`rotate` 是页面自带的旋转（顺时针）。
func makePDF(_ pages: [FakePage], rotate: Int = 0, size: CGFloat = 20) -> URL {
	let url = Fixtures.tempURL("pdf")
	var box = CGRect(x: 0, y: 0, width: 595, height: 842)
	let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
	for page in pages {
		ctx.beginPDFPage(nil)
		if let p = page.picture { ctx.draw(p.image, in: p.rect) }
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		for (mode, lines) in [(CGTextDrawingMode.fill, page.visible), (.invisible, page.hidden)] {
			ctx.setTextDrawingMode(mode)
			for (i, s) in lines.enumerated() {
				ctx.textPosition = CGPoint(x: 60, y: 760 - size * 2 * CGFloat(i))
				CTLineDraw(Fixtures.ctLine(s, size: size), ctx)
			}
		}
		ctx.endPDFPage()
	}
	ctx.closePDF()
	guard rotate != 0, let doc = PDFDocument(url: url) else { return url }
	for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotate }
	let rotated = Fixtures.tempURL("pdf")
	doc.write(to: rotated)
	return rotated
}

/// 一张画着字的图（当扫描件、插图用）。
func picture(_ lines: [String], width: Int = 1240, height: Int = 1754, size: CGFloat = 40) -> CGImage {
	Fixtures.text(lines, size: size, width: width, height: height, left: 100, top: 160)
}

func firstPage(_ url: URL, _ configure: (inout OCROptions) -> Void = { _ in }) throws -> PageResult {
	var o = OCROptions()
	configure(&o)
	return try engine.runPage(try PageSource(path: url.path), page: 1, options: o)
}

func iou(_ a: NRect, _ b: NRect) -> Double {
	let inter = a.overlapArea(b)
	return inter / (a.area + b.area - inter)
}

@Test func 数字页直接用文字层() throws {
	let url = makePDF([FakePage(visible: ["数字页第一行的字", "Second line 2026"])])
	let p = try firstPage(url)
	#expect(p.textLayer && p.text == "数字页第一行的字\nSecond line 2026")
	#expect((p.steps["textLayer"] as? [String: Any])?["used"] as? Bool == true)
	#expect(p.lines.allSatisfy { $0.confidence == 1 && $0.suspect == nil })
	// 框的位置跟认图认出来的一样（左上原点、相对渲染出来的图）。
	let ocr = try firstPage(url) { $0.textLayer = false }
	#expect(!ocr.textLayer && p.width == ocr.width && p.height == ocr.height)
	for line in p.lines {
		let match = ocr.lines.max { iou($0.box, line.box) < iou($1.box, line.box) }
		#expect(match.map { iou($0.box, line.box) } ?? 0 > 0.5, "「\(line.text)」的框对不上")
	}
	#expect(pageJSON(p)["source"] as? String == "textLayer" && pageJSON(ocr)["source"] == nil)
}

@Test func 转过的页框也对() throws {
	let url = makePDF([FakePage(visible: ["转了九十度的一页", "第二行也在"])], rotate: 90)
	let p = try firstPage(url)
	let ocr = try firstPage(url) { $0.textLayer = false }
	#expect(p.textLayer && p.width > p.height, "转 90° 后渲染出来是横的")
	for line in p.lines {
		let match = ocr.lines.max { iou($0.box, line.box) < iou($1.box, line.box) }
		#expect(match.map { iou($0.box, line.box) } ?? 0 > 0.4, "「\(line.text)」的框对不上：\(line.box.array) / \(ocr.lines.map(\.box.array))")
	}
}

@Test func 扫描页照常认图() throws {
	let scan = picture(["扫描件上的一行字", "第二行也是图"])
	let p = try firstPage(makePDF([FakePage(picture: (scan, CGRect(x: 0, y: 0, width: 595, height: 842)))]))
	#expect(!p.textLayer && (p.steps["textLayer"] as? [String: Any])?["reason"] as? String == "no-text")
	#expect(Fixtures.compact(p.text).contains("扫描件上的一行字") && p.notes.isEmpty, "扫描件最常见，不用另外说明")
}

@Test func 扫描件上别人加的隐形字不用() throws {
	let scan = picture(["扫描件上真正的字"])
	let p = try firstPage(makePDF([FakePage(hidden: ["别的软件认错的字"], picture: (scan, CGRect(x: 0, y: 0, width: 595, height: 842)))]))
	#expect(!p.textLayer && (p.steps["textLayer"] as? [String: Any])?["reason"] as? String == "hidden-text")
	#expect(Fixtures.compact(p.text).contains("扫描件上真正的字") && !p.text.contains("认错"))
	#expect(p.notes.contains { $0.contains("隐形文字层") })
}

@Test func 可见字上又叠了隐形字不用() throws {
	let p = try firstPage(makePDF([FakePage(visible: ["被人又跑过一遍的数字页"], hidden: ["被人又跑过一遍的数字页"])]))
	#expect(!p.textLayer && (p.steps["textLayer"] as? [String: Any])?["reason"] as? String == "doubled")
	#expect(Fixtures.compact(p.text) == "被人又跑过一遍的数字页", "字不能重复两份：\(p.text)")
}

@Test func 以图为主的页整页认图() throws {
	let chart = picture(["流程图里的字"], width: 1000, height: 800)
	let p = try firstPage(makePDF([FakePage(visible: ["图的标题"], picture: (chart, CGRect(x: 0, y: 0, width: 595, height: 600)))]))
	#expect(!p.textLayer && (p.steps["textLayer"] as? [String: Any])?["reason"] as? String == "mostly-image")
}

@Test func 数字页里的图另外认() throws {
	let chart = picture(["插图里写着的字"], width: 900, height: 300, size: 48)
	let url = makePDF([FakePage(visible: ["正文第一行", "正文第二行"], picture: (chart, CGRect(x: 60, y: 300, width: 450, height: 150)))])
	let p = try firstPage(url)
	#expect(p.textLayer && (p.steps["textLayer"] as? [String: Any])?["pictures"] as? Int == 1)
	let texts = p.lines.map { Fixtures.compact($0.text) }
	#expect(texts.prefix(2) == ["正文第一行", "正文第二行"] && texts.contains("插图里写着的字"), "\(texts)")
	// 只认一块：区域外的行不要，坐标仍相对整页。
	let top = try firstPage(url) { $0.region = NRect(x: 0, y: 0, w: 1, h: 0.2) }
	#expect(top.lines.map { Fixtures.compact($0.text) } == ["正文第一行", "正文第二行"])
}

@Test func 关掉文字层或者认文档时照常认图() throws {
	let url = makePDF([FakePage(visible: ["关掉文字层也认得出"])])
	#expect(try !firstPage(url) { $0.textLayer = false }.textLayer)
	if OCREngine.documentModeAvailable { #expect(try !firstPage(url) { $0.mode = .document }.textLayer, "认文档要表格结构，文字层没有") }
}

@Test func 这一页画了什么() {
	let scan = PageInk(visibleText: 0, hiddenText: 0, images: [(CGRect(x: 0, y: 0, width: 595, height: 842), "a")])
	#expect(textLayerSkip(scan, coverage: 1) == .noText)
	#expect(textLayerSkip(PageInk(visibleText: 0, hiddenText: 30), coverage: 1) == .hiddenOnly)
	#expect(textLayerSkip(PageInk(visibleText: 30, hiddenText: 30), coverage: 0) == .doubled)
	#expect(textLayerSkip(PageInk(visibleText: 30, hiddenText: 3), coverage: 0) == nil, "零星几处隐形字（艺术字之类）照样用")
	#expect(textLayerSkip(PageInk(visibleText: 30, hiddenText: 0), coverage: 0.6) == .mostlyImage)
	#expect(textLayerSkip(PageInk(visibleText: 30, hiddenText: 0), coverage: 0.075) == nil, "页眉一张标志图照样用文字层")
	#expect(abs(imageCoverage([CGRect(x: 0, y: 0, width: 595, height: 421), CGRect(x: 0, y: 0, width: 595, height: 421)], in: CGRect(x: 0, y: 0, width: 595, height: 842)) - 0.5) < 0.02, "叠着的不重复算")
	#expect(badCharacterRatio("正常的字") == 0 && badCharacterRatio("\u{E001}\u{E002}ab") == 0.5)
}

@Test func 同一行拆成几段的拼回来() {
	func frag(_ order: Int, _ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, h: CGFloat = 12) -> TextFragment {
		TextFragment(order: order, text: text, rect: CGRect(x: x, y: y, width: w, height: h))
	}
	let merged = mergeFragments([
		// 浏览器导出的 PDF：同一行中英文、标点分开画。
		frag(0, "把 macOS 自带的文字识别做成一个 MCP 服务", 87, 700, 260),
		frag(40, "：读图片（PNG、JPEG、", 348, 700, 150),
		// 同一行、隔得远的两格：各算各的。
		frag(80, "BoD", 140, 650, 20),
		frag(90, "• Aprueba o rechaza la emisión", 224, 650, 200),
		// 西文两段之间有空当：补一个空格。
		frag(120, "Hello", 60, 600, 30),
		frag(130, "world", 96, 600, 30),
		// 位置是对的、却排在最后的一段：回到它那一行。
		frag(150, "阶段每张图", 63, 560, 60),
		frag(170, "出来的最好认法", 87, 540, 120),
		frag(200, "挑", 123, 560, 12),
		// 找不到位置的段：字照顺序留着。
		TextFragment(order: 210, text: "{", rect: nil),
	])
	#expect(merged.map(\.text) == [
		"把 macOS 自带的文字识别做成一个 MCP 服务：读图片（PNG、JPEG、", "BoD", "• Aprueba o rechaza la emisión", "Hello world", "阶段每张图挑", "出来的最好认法", "{",
	])
	#expect(merged.last?.rect == nil)
}

@Test func 识别详情说清文字层用没用() {
	var page = reportPage(steps: ["textLayer": ["used": true, "lines": 12, "pictures": 1]])
	page.textLayer = true
	let report = RecognitionReport(result: page, options: OCROptions(), configured: [], isPhoto: false)
	#expect(report.items.first?.value == "PDF 自带的文字（没有 OCR）")
	#expect(report.items.contains { $0.label == "文字层" && $0.value == "用了；页上 1 张图里的字另外认的" })
	#expect(!report.items.contains { $0.label == "语言" }, "没认字就不说按什么语言认")
	let hidden = RecognitionReport(result: reportPage(steps: ["textLayer": ["used": false, "reason": "hidden-text"]]), options: OCROptions(), configured: [], isPhoto: false)
	#expect(hidden.items.contains { $0.label == "文字层" && $0.value.contains("隐形文字层") })
	#expect(RecognitionReport(result: reportPage(steps: [:]), options: OCROptions(), configured: [], isPhoto: false).items.allSatisfy { $0.label != "文字层" }, "图片不说文字层")
}

@MainActor @Test func 拾字在文字层的页上框选直接取字() async throws {
	let url = makePDF([FakePage(visible: ["上面一行要框进来", "下面一行不要"])])
	let doc = try DocumentModel(url: url, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	doc.start()
	await waitFor { !doc.isRunning }
	#expect(doc.results[1]?.textLayer == true)
	let top = try #require(doc.results[1]?.lines.first?.box)
	var picked: String?
	doc.recognize(region: NRect(x: 0, y: 0, w: 1, h: top.maxY + 0.005)) { picked = try? $0.get() }
	#expect(picked == "上面一行要框进来", "框选在文字层的页上不用等识别，马上给")
	// 只框住半行：只给框里的字。
	doc.recognize(region: NRect(x: 0, y: top.y - 0.005, w: top.x + top.w * 0.45, h: top.h + 0.01)) { picked = try? $0.get() }
	#expect(picked == "上面一行", "框住半行：\(String(describing: picked))")
}

/// 把字描成图形画上去（没有文字层，看着跟字一样），用来造「文字层跟页面上的字对不上」的 PDF。
func drawOutlines(_ s: String, size: CGFloat, at origin: CGPoint, in ctx: CGContext) {
	let line = Fixtures.ctLine(s, size: size)
	for run in CTLineGetGlyphRuns(line) as! [CTRun] {
		let attributes = CTRunGetAttributes(run) as NSDictionary
		let font = attributes[kCTFontAttributeName as String] as! CTFont
		let count = CTRunGetGlyphCount(run)
		var glyphs = [CGGlyph](repeating: 0, count: count)
		var positions = [CGPoint](repeating: .zero, count: count)
		CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
		CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
		for (g, p) in zip(glyphs, positions) {
			guard let path = CTFontCreatePathForGlyph(font, g, nil) else { continue }
			ctx.saveGState()
			ctx.translateBy(x: origin.x + p.x, y: origin.y + p.y)
			ctx.addPath(path)
			ctx.fillPath()
			ctx.restoreGState()
		}
	}
}

/// 一页「文字层跟页面对不上」的 PDF：文字层的字是黑的、看得见的模式，却被白块盖住，页面上印着的是描出来的另一些字。
/// 像字体编码错位的 PDF：取出来是像样的字、却不是页面上的字，乱码比例看不出来。`white`：文字层改用白字（不盖白块）。
func drawMismatch(_ ctx: CGContext, white: Bool = false) {
	for i in 0..<5 {
		let y = 760 - 40 * CGFloat(i)
		ctx.setFillColor(white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		ctx.textPosition = CGPoint(x: 60, y: y)
		CTLineDraw(Fixtures.ctLine("文字层里取出来的字第\(i)行跟页面不一样", size: 20), ctx)
		if !white {
			ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
			ctx.fill(CGRect(x: 50, y: y - 8, width: 500, height: 32))
		}
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawOutlines("页面上真正印着的是另外的内容第\(i)行", size: 20, at: CGPoint(x: 60, y: y), in: ctx)
	}
}

/// 一页一页画的 PDF：`draw` 拿到画布和第几页（从 0 起）。
func drawnPDF(pages: Int, _ draw: (CGContext, Int) -> Void) -> URL {
	let url = Fixtures.tempURL("pdf")
	var box = CGRect(x: 0, y: 0, width: 595, height: 842)
	let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
	for i in 0..<pages {
		ctx.beginPDFPage(nil)
		draw(ctx, i)
		ctx.endPDFPage()
	}
	ctx.closePDF()
	return url
}

func runAll(_ url: URL, _ configure: (inout OCROptions) -> Void = { _ in }) throws -> [PageResult] {
	var o = OCROptions()
	configure(&o)
	let source = try PageSource(path: url.path)
	var results: [PageResult] = []
	try engine.run(source, pages: Array(1...source.totalPages), options: o) { page in
		results.append(page)
		return true
	}
	return results
}

func reason(_ p: PageResult) -> String? { (p.steps["textLayer"] as? [String: Any])?["reason"] as? String }

@Test func 抽查对不上整份改回认图() throws {
	let url = drawnPDF(pages: 2) { ctx, _ in drawMismatch(ctx) }
	let results = try runAll(url)
	#expect(results.allSatisfy { !$0.textLayer && reason($0) == "failed-check" })
	#expect(Fixtures.compact(results[0].text).contains("页面上真正印着的是另外的内容"), "认的是页面上的字：\(results[0].text)")
	#expect(results[0].notes.contains { $0.contains("对不上") })
}

@Test func 字多的数字页抽查对得上() throws {
	let lines = (1...6).map { "数字页上的第\($0)行正文，字够多才抽查得了" }
	let url = makePDF([FakePage(visible: lines), FakePage(visible: lines)])
	let memory = RunMemory()
	let source = try PageSource(path: url.path)
	let first = try engine.runPage(source, page: 1, options: OCROptions(), memory: memory)
	let second = try engine.runPage(source, page: 2, options: OCROptions(), memory: memory)
	func checked(_ p: PageResult) -> String? { (p.steps["textLayer"] as? [String: Any])?["checked"] as? String }
	#expect(first.textLayer && checked(first) == "new-fonts", "第一页抽查过、对得上")
	#expect(second.textLayer && checked(second) == nil, "第二页用的字体查过了，不再查")
}

@Test func 第一页对得上第二页的错字层也查得出来() throws {
	// 拼起来的 PDF：第一页是正常的数字页（抽查过），第二页垫着一层白字（跟第一页一样的字、一样的字体），页面上印的是描出来的另一些字。
	// 只查第一页的话，第二页的错字层会混过去；白底上画了白字的页要再查。
	let layer = (0..<5).map { "文字层里取出来的字第\($0)行跟页面不一样" }
	let url = drawnPDF(pages: 2) { ctx, i in
		if i == 0 {
			ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
			for (k, s) in layer.enumerated() {
				ctx.textPosition = CGPoint(x: 60, y: 760 - 40 * CGFloat(k))
				CTLineDraw(Fixtures.ctLine(s, size: 20), ctx)
			}
		} else {
			drawMismatch(ctx, white: true)
		}
	}
	let results = try runAll(url)
	#expect(results[0].textLayer)
	#expect(!results[1].textLayer && reason(results[1]) == "failed-check", "第二页：\(String(describing: results[1].steps["textLayer"]))")
	#expect(Fixtures.compact(results[1].text).contains("页面上真正印着的是另外的内容"), "认的是页面上的字：\(results[1].text)")
}

@Test func 红底白字的页不用再抽查() throws {
	// 表头是红底白字（有的表格就是这样印的）：看得见的白字，字体也查过了，不用再花时间抽查。
	let lines = (1...6).map { "数字页上的第\($0)行正文，字够多才抽查得了" }
	let url = drawnPDF(pages: 2) { ctx, i in
		if i == 1 {
			ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
			ctx.fill(CGRect(x: 50, y: 790, width: 300, height: 34))
			ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
			ctx.textPosition = CGPoint(x: 60, y: 800)
			CTLineDraw(Fixtures.ctLine("数字页上的第1行正文", size: 20), ctx)
		}
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		for (k, s) in lines.enumerated() {
			ctx.textPosition = CGPoint(x: 60, y: 740 - 40 * CGFloat(k))
			CTLineDraw(Fixtures.ctLine(s, size: 20), ctx)
		}
	}
	let results = try runAll(url)
	#expect(results.allSatisfy { $0.textLayer })
	#expect((results[1].steps["textLayer"] as? [String: Any])?["checked"] as? Bool == false, "第二页：\(String(describing: results[1].steps["textLayer"]))")
}

@Test func 资源写在上级页面树里也看得见图() throws {
	// PDF 规范允许页面的资源（图片、字体）写在上级的页面树节点里。不往上找就看不见图：扫描页被当成数字页，正文整片丢掉。
	// 两份 PDF 内容一模一样，只是资源写的地方不一样，结果要一样。
	let scan = Fixtures.text(["SCANNED RECEIPT 12345", "IMPORTANT BODY 67890"], size: 32, width: 600, height: 500, left: 30, top: 150)
	let explicit = rawPDF(resourcesOnParent: false, picture: scan), inherited = rawPDF(resourcesOnParent: true, picture: scan)
	let inheritedPage = try #require(try PageSource(path: inherited.path).pdfPage(1))
	#expect(scanInk(inheritedPage).images.count == 1)
	let a = try firstPage(explicit), b = try firstPage(inherited)
	#expect(Fixtures.compact(b.text).contains("SCANNEDRECEIPT12345"), "资源在上级时：\(b.text)")
	#expect(a.text == b.text && a.textLayer == b.textLayer)
}

/// 手写一份一页的 PDF：上面一行数字字（标准字体 Helvetica），下面一张大图；资源写在页面里还是上级页面树节点里。
func rawPDF(resourcesOnParent: Bool, picture: CGImage) -> URL {
	let ctx = Fixtures.canvas(picture.width, picture.height)
	ctx.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
	let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
	var rgb = Data()
	for y in 0..<picture.height {
		for x in 0..<picture.width {
			let k = y * ctx.bytesPerRow + 4 * x
			rgb.append(contentsOf: [bytes[k], bytes[k + 1], bytes[k + 2]])
		}
	}
	func text(_ s: String) -> Data { Data(s.utf8) }
	func stream(_ body: Data, _ keys: String = "") -> Data {
		var d = text("<< \(keys) /Length \(body.count) >>\nstream\n")
		d.append(body)
		d.append(text("\nendstream"))
		return d
	}
	let resources = "/Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >>"
	let objects = [
		text("<< /Type /Catalog /Pages 2 0 R >>"),
		text("<< /Type /Pages /Kids [3 0 R] /Count 1 \(resourcesOnParent ? resources : "") >>"),
		text("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R \(resourcesOnParent ? "" : resources) >>"),
		stream(text("BT /F1 20 Tf 60 780 Td (DIGITAL TITLE) Tj ET\nq 550 0 0 600 20 30 cm /Im1 Do Q")),
		text("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
		stream(rgb, "/Type /XObject /Subtype /Image /Width \(picture.width) /Height \(picture.height) /ColorSpace /DeviceRGB /BitsPerComponent 8"),
	]
	var data = text("%PDF-1.4\n")
	var offsets: [Int] = []
	for (i, o) in objects.enumerated() {
		offsets.append(data.count)
		data.append(text("\(i + 1) 0 obj\n"))
		data.append(o)
		data.append(text("\nendobj\n"))
	}
	let start = data.count
	data.append(text("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"))
	for n in offsets { data.append(text(String(format: "%010d 00000 n \n", n))) }
	data.append(text("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"))
	let url = Fixtures.tempURL("pdf")
	try! data.write(to: url)
	return url
}

@Test func 同一张图上压着不同的字不串页() throws {
	// 两页在同一位置用同一张图（白底），图上各压着矢量描出来的不同的字。认过的图片区按「图片对象 + 位置」复用的话，
	// 第二页会拿到第一页的字；要连画出来的样子一起比。
	let blank = Fixtures.canvas(400, 200).makeImage()!
	let url = drawnPDF(pages: 2) { ctx, i in
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		ctx.textPosition = CGPoint(x: 60, y: 780)
		CTLineDraw(Fixtures.ctLine("正文标题 Digital heading", size: 20), ctx)
		ctx.draw(blank, in: CGRect(x: 60, y: 400, width: 400, height: 200))
		drawOutlines(i == 0 ? "ALPHA 12345" : "BRAVO 67890", size: 36, at: CGPoint(x: 100, y: 480), in: ctx)
	}
	let results = try runAll(url)
	#expect(results.allSatisfy { $0.textLayer })
	#expect(Fixtures.compact(results[0].text).contains("ALPHA12345"))
	#expect(Fixtures.compact(results[1].text).contains("BRAVO67890") && !results[1].text.contains("ALPHA"), "第二页：\(results[1].text)")
}

/// PDF 第 1 页上某段字在渲染图上的位置（0–1、左上原点），上下各放宽一点。
func wordBox(_ url: URL, _ word: String) throws -> NRect {
	let page = try #require(PDFDocument(url: url)?.page(at: 0))
	let range = ((page.string ?? "") as NSString).range(of: word)
	let r = try #require(page.selection(for: range)?.bounds(for: page))
	let b = boundingBox(displayedQuad(r, crop: page.bounds(for: .cropBox), rotation: page.rotation))
	return NRect(x: b.x + 0.002, y: b.y - 0.01, w: b.w - 0.004, h: b.h + 0.02)
}

@Test func 框住半行只取框里的字() throws {
	let url = makePDF([FakePage(visible: ["LEFT MIDDLE RIGHT", "第二行不要"])])
	for word in ["LEFT", "MIDDLE"] {
		let region = try wordBox(url, word)
		let p = try firstPage(url) { $0.region = region }
		#expect(p.textLayer && p.text == word, "框住「\(word)」：\(p.text)")
		#expect(p.lines.allSatisfy { $0.box.x >= 0 && $0.box.maxX <= 1 })
	}
}

@Test func 裁剪框切过一行时只留框里那截() throws {
	let full = makePDF([FakePage(visible: ["LEFT MIDDLE RIGHT"])])
	let doc = try #require(PDFDocument(url: full))
	let page = try #require(doc.page(at: 0))
	// 裁剪框的左边切在「MIDDLE」中间。
	let middle = try #require(page.selection(for: ((page.string ?? "") as NSString).range(of: "MIDDLE"))?.bounds(for: page))
	page.setBounds(CGRect(x: middle.midX, y: 0, width: 400, height: 842), for: .cropBox)
	let url = Fixtures.tempURL("pdf")
	doc.write(to: url)
	let p = try firstPage(url)
	#expect(p.textLayer && !p.text.contains("LEFT") && p.text.contains("RIGHT"), "裁剪后：\(p.text)")
	#expect(p.lines.allSatisfy { l in l.quad.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) } }, "坐标出了 0–1：\(p.lines.map(\.box))")
}

/// 一个二维码的格子（true 是黑格）。
func qrModules(_ text: String) throws -> [[Bool]] {
	let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
	filter.setValue(Data(text.utf8), forKey: "inputMessage")
	let ci = try #require(filter.outputImage)
	let image = try #require(CIContext().createCGImage(ci, from: ci.extent))
	let ctx = Fixtures.canvas(image.width, image.height)
	ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
	let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
	return (0..<image.height).map { y in (0..<image.width).map { x in bytes[y * ctx.bytesPerRow + 4 * x] < 128 } }
}

@Test func 文字层的页上矢量画的二维码也找得到() throws {
	// 二维码用一个个黑方块画出来（没有图片）：只在有大图时才找码，就会漏。
	let modules = try qrModules("review-qr-123")
	let url = drawnPDF(pages: 1) { ctx, _ in
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		ctx.textPosition = CGPoint(x: 60, y: 780)
		CTLineDraw(Fixtures.ctLine("带二维码的数字页 Digital page", size: 20), ctx)
		let cell: CGFloat = 4
		for (y, row) in modules.enumerated() {
			for (x, dark) in row.enumerated() where dark {
				ctx.fill(CGRect(x: 60 + CGFloat(x) * cell, y: 600 - CGFloat(y) * cell, width: cell, height: cell))
			}
		}
	}
	let p = try firstPage(url)
	#expect(p.textLayer && p.barcodes == ["review-qr-123"], "找到 \(p.barcodes)")
}
