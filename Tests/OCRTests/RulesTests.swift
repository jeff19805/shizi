import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OCRCore

// 表格线和按格子排的阅读顺序（Rules.swift、Reading.swift 的 cellRows）。

/// 0–1 坐标里的一条线；`degrees` 跟 `Fixtures.line` 一样绕图中心转（画面上顺时针为正）。
func rule(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, degrees: Double = 0) -> RuleLine {
	let a = degrees * .pi / 180
	func turn(_ x: Double, _ y: Double) -> NPoint {
		let dx = x - 0.5, dy = y - 0.5
		return NPoint(x: 0.5 + dx * cos(a) - dy * sin(a), y: 0.5 + dx * sin(a) + dy * cos(a))
	}
	return RuleLine(from: turn(x0, y0), to: turn(x1, y1))
}

/// 照一张扫描的验收表上那一排摆：六格，「工程名称」「王小明」各一行，别的格子折成两三行，格子都上下居中。
/// 1000×1000 的图，行高 0.03；格子的上下线在 0.19、0.33，竖线在格子之间。
func ruledRow(degrees: Double = 0) -> (lines: [OCRLine], rules: [RuleLine]) {
	func at(_ text: String, _ x: Double, _ y: Double, _ w: Double) -> OCRLine { row(text, x: x, y: y, w: w, degrees: degrees) }
	let lines = [
		at("工程名称", 0.03, 0.24, 0.12),
		at("某某高速穿越", 0.19, 0.20, 0.16), at("500千伏某某线", 0.19, 0.24, 0.16), at("电力迁改工程", 0.19, 0.28, 0.16),
		at("施工", 0.39, 0.22, 0.06), at("单位", 0.39, 0.26, 0.06),
		at("某某路桥建设", 0.49, 0.22, 0.16), at("集团有限公司", 0.49, 0.26, 0.16),
		at("施工", 0.69, 0.20, 0.08), at("负责", 0.69, 0.24, 0.08), at("人", 0.69, 0.28, 0.08),
		at("王小明", 0.82, 0.24, 0.10),
	]
	let rules = [rule(0.02, 0.19, 0.98, 0.19, degrees: degrees), rule(0.02, 0.33, 0.98, 0.33, degrees: degrees)]
		+ [0.02, 0.17, 0.37, 0.47, 0.67, 0.80, 0.98].map { rule($0, 0.19, $0, 0.33, degrees: degrees) }
	return (lines, rules)
}

func ruledText(_ lines: [OCRLine], _ rules: [RuleLine], markers: Bool = true) -> String {
	joinLayout(readingLayout(lines, width: 1000, height: 1000, rules: rules), lines, markers: markers)
}

@Test func 画了线的表格一格一格地出() {
	let (lines, rules) = ruledRow()
	let text = ruledText(lines.shuffled(), rules)
	#expect(text == "工程名称\n某某高速穿越\n500千伏某某线\n电力迁改工程\n施工\n单位\n某某路桥建设\n集团有限公司\n施工\n负责\n人\n王小明", "按格子排错了：\n\(text)")
	let layout = readingLayout(lines, width: 1000, height: 1000, rules: rules)
	#expect(layout.enclosed == 12 && layout.grouped == 10 && layout.rules == 9)
}

@Test func 同样的字不画线还是一行行出() {
	// 光看行框，三行的格子挨着三行的格子跟三排单行格子一模一样：没有线就照以前一行行排（这正是要靠线分开的那种歧义）。
	let (lines, _) = ruledRow()
	let text = ruledText(lines, [])
	#expect(text == "某某高速穿越  施工\n施工  某某路桥建设\n工程名称  500千伏某某线  负责  王小明\n单位  集团有限公司\n电力迁改工程  人", "没线时跟以前不一样了：\n\(text)")
}

@Test func 两条横线夹着左右对齐的几行没有竖线时顺序不变() {
	// 收据：上下各一条分隔线，左边品名、右边价钱一行对一行。没有竖线就不算格子，不能出成一整列品名再一整列价钱。
	let items = [("拿铁", "¥32.00"), ("美式", "¥28.00"), ("可颂", "¥18.00"), ("合计", "¥78.00")]
	let lines = items.enumerated().flatMap { i, p in
		[row(p.0, x: 0.1, y: 0.2 + 0.04 * Double(i), w: 0.2), row(p.1, x: 0.7, y: 0.2 + 0.04 * Double(i), w: 0.2)]
	}
	let rules = [rule(0.05, 0.18, 0.95, 0.18), rule(0.05, 0.37, 0.95, 0.37)]
	#expect(ruledText(lines.shuffled(), rules) == "拿铁  ¥32.00\n美式  ¥28.00\n可颂  ¥18.00\n合计  ¥78.00")
}

@Test func 转90度的画线表格跟正放的一样() {
	// 横放扫描的页：图上的竖线是版面上的横线，转进字是正的坐标系以后再分横竖。
	let upright = ruledRow(), turned = ruledRow(degrees: 90)
	#expect(ruledText(turned.lines.shuffled(), turned.rules) == ruledText(upright.lines, upright.rules))
}

@Test func 两栏文字顶上一条横线仍按栏读() {
	let left = ["左栏第一行", "左栏第二行", "左栏第三行"].enumerated().map { row($1, x: 0.05, y: 0.2 + 0.05 * Double($0), w: 0.4) }
	let right = ["右栏第一行", "右栏第二行"].enumerated().map { row($1, x: 0.55, y: 0.23 + 0.07 * Double($0), w: 0.4) }
	let lines = left + right
	let rules = [rule(0.05, 0.15, 0.95, 0.15)]
	#expect(ruledText(lines, rules) == ruledText(lines, []))
	#expect(ruledText(lines, rules, markers: false) == "左栏第一行\n左栏第二行\n左栏第三行\n\n右栏第一行\n右栏第二行")
}

@Test func 两栏文字外面套着整页的框还按栏读() {
	// 证书、试卷、带边框的表单：四周一个大框。框横竖都比字的范围一半还大，是页框不是格子，跟没框时一样切块。
	let left = ["左栏第一行", "左栏第二行", "左栏第三行"].enumerated().map { row($1, x: 0.08, y: 0.2 + 0.05 * Double($0), w: 0.37) }
	let right = ["右栏第一行", "右栏第二行", "右栏第三行"].enumerated().map { row($1, x: 0.55, y: 0.23 + 0.06 * Double($0), w: 0.37) }
	let lines = left + right
	let frame = [rule(0.03, 0.1, 0.97, 0.1), rule(0.03, 0.9, 0.97, 0.9), rule(0.03, 0.1, 0.03, 0.9), rule(0.97, 0.1, 0.97, 0.9)]
	#expect(ruledText(lines, frame) == ruledText(lines, []))
	#expect(readingLayout(lines, width: 1000, height: 1000, rules: frame).enclosed == 0)
	// 框里再一条通栏横线把上下分开：上下两半各自横着够宽、竖着不到一半，算两格；格子里面照样按栏读。
	let below = [row("下面左栏", x: 0.08, y: 0.6, w: 0.37), row("下面右栏", x: 0.55, y: 0.63, w: 0.37)]
	let split = frame + [rule(0.03, 0.5, 0.97, 0.5)]
	let text = Fixtures.compact(ruledText(lines + below, split, markers: false))
	#expect(text == "左栏第一行左栏第二行左栏第三行右栏第一行右栏第二行右栏第三行下面左栏下面右栏", "顺序：\(text)")
}

@Test func 一格里三行标签挨着三个值还按行出() {
	// 一个格子里左边三行标签、右边三个值，一行对一行：按留白切不开（两边对得上），还是一格，一行行出，不能先出完标签再出值。
	let pairs = [("合同编号：", "HT-2026-001"), ("签订日期：", "2026年10月9日"), ("合同金额：", "¥1,280,000.00")]
	let lines = pairs.enumerated().flatMap { i, p in
		[row(p.0, x: 0.1, y: 0.2 + 0.05 * Double(i), w: 0.2), row(p.1, x: 0.5, y: 0.2 + 0.05 * Double(i), w: 0.3)]
	}
	let rules = [rule(0.05, 0.15, 0.95, 0.15), rule(0.05, 0.4, 0.95, 0.4), rule(0.05, 0.15, 0.05, 0.4), rule(0.95, 0.15, 0.95, 0.4)]
	#expect(readingLayout(lines, width: 1000, height: 1000, rules: rules).grouped == 6, "该算一格")
	#expect(ruledText(lines.shuffled(), rules) == "合同编号：  HT-2026-001\n签订日期：  2026年10月9日\n合同金额：  ¥1,280,000.00")
	// 行距再紧一点（上下几乎挨着）也一样。
	let tight = pairs.enumerated().flatMap { i, p in
		[row(p.0, x: 0.1, y: 0.2 + 0.034 * Double(i), w: 0.2), row(p.1, x: 0.5, y: 0.2 + 0.034 * Double(i), w: 0.3)]
	}
	#expect(ruledText(tight.shuffled(), rules) == "合同编号：  HT-2026-001\n签订日期：  2026年10月9日\n合同金额：  ¥1,280,000.00")
}

@Test func 表格线穿过栏缝时不左右切开() {
	// 标签栏和内容栏一行对一行，可是内容栏里有公章、签名的零散字把对齐搅乱：按留白会左右切成两块，标签全出完才出内容。
	// 栏缝里有竖线、横线跨过它，就是同一张表，不切。
	let labels = ["项目开工条件", "申请开竣工日期", "项目单位审核意见", "项目单位审核人"].enumerated().map {
		row($1, x: 0.05, y: 0.12 + 0.1 * Double($0), w: 0.25)
	}
	let values = [row("人、材、机都已进场", x: 0.4, y: 0.12, w: 0.4), row("2019年9月16日至", x: 0.4, y: 0.22, w: 0.3),
		row("懐まる", x: 0.75, y: 0.27, w: 0.1), row("鲜礁", x: 0.55, y: 0.36, w: 0.08), row("日期：2019.11.10", x: 0.4, y: 0.42, w: 0.3)]
	let lines = labels + values
	#expect(ruledText(lines, []).contains("\n\n"), "这个例子没线时本来就会左右切开")
	let rules = [0.1, 0.2, 0.3, 0.4, 0.5].map { rule(0.02, $0, 0.98, $0) } + [0.02, 0.35, 0.98].map { rule($0, 0.1, $0, 0.5) }
	let text = ruledText(lines, rules)
	#expect(!text.contains("\n\n"), "表格被左右切开了：\n\(text)")
	let order = ["项目开工条件", "人、材、机都已进场", "申请开竣工日期", "2019年9月16日至", "项目单位审核意见", "项目单位审核人", "日期：2019.11.10"]
	#expect(order.map { text.range(of: $0)!.lowerBound } == order.map { text.range(of: $0)!.lowerBound }.sorted(), "顺序不对：\n\(text)")
}

@Test func 外面套着大框时框里并排的几块各出各的() {
	// 照一张带签名栏的西文表单摆：整张表单外面一个大框，上面是表单的字，底下两排签名块左右并排，各自上面一条签名线。
	// 签名块的格子左右都是大框（按框算左右分不开），所以格子的左右按字算；不然两块的字会一行行交错。
	func block(_ x: Double, _ y: Double, _ texts: [String]) -> [OCRLine] {
		texts.enumerated().map { row($1, x: x, y: y + 0.035 * Double($0), w: 0.3) }
	}
	let header = [row("ORDEN DE CAMBIO", x: 0.3, y: 0.12, w: 0.4), row("Motivo de la Orden de Cambio:", x: 0.08, y: 0.2, w: 0.5)]
	let lines = header
		+ block(0.08, 0.62, ["[Nombre A]", "Jefe de Proyecto", "[Mandante]"]) + block(0.6, 0.62, ["[Nombre B]", "Jefe de Obra", "[Contratista]"])
		+ block(0.08, 0.77, ["[Nombre C]", "Apoderado", "[Mandante S.A.]"]) + block(0.6, 0.77, ["[Nombre D]", "Apoderada", "[Contratista S.A.]"])
	let rules = [rule(0.05, 0.1, 0.95, 0.1), rule(0.05, 0.9, 0.95, 0.9), rule(0.05, 0.1, 0.05, 0.9), rule(0.95, 0.1, 0.95, 0.9),
		rule(0.08, 0.61, 0.4, 0.61), rule(0.6, 0.61, 0.92, 0.61), rule(0.08, 0.76, 0.4, 0.76), rule(0.6, 0.76, 0.92, 0.76)]
	let text = ruledText(lines, rules, markers: false)
	#expect(text.hasSuffix("""
		[Nombre A]
		Jefe de Proyecto
		[Mandante]
		[Nombre B]
		Jefe de Obra
		[Contratista]
		[Nombre C]
		Apoderado
		[Mandante S.A.]
		[Nombre D]
		Apoderada
		[Contratista S.A.]
		"""), "签名块：\n\(text)")
}

@Test func 认文档没找到表格而页上画着线时改用逐行() {
	let (lines, rules) = ruledRow()
	let layout = readingLayout(lines, width: 1000, height: 1000, rules: rules)
	let empty = DocResult(title: nil, paragraphs: [], lines: [], tables: [], lists: [], barcodes: [], data: [])
	#expect(ruledFormInsteadOfDocument(empty, layout, lineCount: lines.count))
	// 它找到了表格：用它的表格（Markdown）。
	var withTable = empty
	withTable.tables = [DocTable(cells: [], box: NRect(x: 0, y: 0, w: 1, h: 1))]
	#expect(!ruledFormInsteadOfDocument(withTable, layout, lineCount: lines.count))
	// 格子都只有一行：按格子排跟一行行排一样，照旧听认文档的。
	let single = readingLayout([lines[0], lines[11]], width: 1000, height: 1000, rules: rules)
	#expect(single.enclosed == 2 && single.grouped == 0 && !ruledFormInsteadOfDocument(empty, single, lineCount: 2))
	// 画了线的格子只装着一小部分行（页上一张小表）：不算。六行小表加十四行正文（三成）也不算，正文留给认文档拼段落。
	#expect(!ruledFormInsteadOfDocument(empty, layout, lineCount: 50))
	#expect(!ruledFormInsteadOfDocument(empty, layout, lineCount: 40), "12 行在格子里、共 40 行：三成")
	#expect(ruledFormInsteadOfDocument(empty, layout, lineCount: 24), "一半")
}

// MARK: - 找线

/// 画一张 3 排 3 列、黑线 2 像素的表，格子里写字；`degrees` 把整张纸转一下（扫描件的歪斜）。
func gridImage(degrees: CGFloat = 0, stamp: Bool = false) -> CGImage {
	let ctx = Fixtures.canvas(1400, 1000)
	ctx.translateBy(x: 700, y: 500)
	ctx.rotate(by: degrees * .pi / 180)
	ctx.translateBy(x: -700, y: -500)
	ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
	ctx.setLineWidth(2)
	for y in [200.0, 400, 600, 800] {
		ctx.move(to: CGPoint(x: 150, y: y))
		ctx.addLine(to: CGPoint(x: 1250, y: y))
	}
	for x in [150.0, 500, 900, 1250] {
		ctx.move(to: CGPoint(x: x, y: 200))
		ctx.addLine(to: CGPoint(x: x, y: 800))
	}
	ctx.strokePath()
	for (r, top) in [230.0, 430, 630].enumerated() {
		for (c, left) in [180.0, 530, 930].enumerated() {
			ctx.textPosition = CGPoint(x: left, y: 1000 - top - 28)
			CTLineDraw(Fixtures.ctLine("第\(r)排第\(c)格的字", size: 28), ctx)
		}
	}
	if stamp {
		// 红色公章：一个红圈压在表上，圈里一道红杠。印泥是透的（正片叠底），压着的黑线还是黑的；只要黑线，红的不该算进来。
		ctx.setBlendMode(.multiply)
		ctx.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
		ctx.setLineWidth(8)
		ctx.strokeEllipse(in: CGRect(x: 800, y: 350, width: 320, height: 320))
		ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
		ctx.fill(CGRect(x: 840, y: 505, width: 240, height: 10))
	}
	return ctx.makeImage()!
}

func countRules(_ rules: [RuleLine], width: Double = 1400, height: Double = 1000) -> (horizontal: Int, vertical: Int) {
	let h = rules.filter { abs($0.to.x - $0.from.x) * width >= abs($0.to.y - $0.from.y) * height }.count
	return (h, rules.count - h)
}

@Test func 找得到表格的横线竖线() {
	let rules = findRules(gridImage(), unit: 32)
	let n = countRules(rules)
	#expect(n.horizontal == 4 && n.vertical == 4, "找到 \(n)")
	// 位置对：最上面那条横线在图高 0.2 处、从 x 0.107 到 0.893。
	let top = rules.filter { abs($0.to.x - $0.from.x) > 0.5 }.min { $0.from.y < $1.from.y }!
	#expect(abs(top.from.y - 0.2) < 0.005 && abs(min(top.from.x, top.to.x) - 150.0 / 1400) < 0.005)
}

@Test func 红色公章不算线() {
	let n = countRules(findRules(gridImage(stamp: true), unit: 32))
	#expect(n.horizontal == 4 && n.vertical == 4, "找到 \(n)")
}

@Test func 歪了一度的扫描件也找得到线() {
	let n = countRules(findRules(gridImage(degrees: 1), unit: 32))
	#expect(n.horizontal == 4 && n.vertical == 4, "找到 \(n)")
}

/// 一排两格的表：左格、右格各两行字，格子高 100 像素，大约 3 个字高：够竖线的门槛（2.5 个字高），不够横线的（4 个字高）。
/// `text` = false 只画线。
func shortWallTable(text: Bool = true) -> CGImage {
	let ctx = Fixtures.canvas(1000, 170)
	ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
	ctx.setLineWidth(2)
	for y in [30.0, 130] {
		ctx.move(to: CGPoint(x: 40, y: 170 - y))
		ctx.addLine(to: CGPoint(x: 960, y: 170 - y))
	}
	for x in [40.0, 500, 960] {
		ctx.move(to: CGPoint(x: x, y: 170 - 30))
		ctx.addLine(to: CGPoint(x: x, y: 170 - 130))
	}
	ctx.strokePath()
	if text {
		for (s, x, top) in [("左格第一行", 80.0, 36.0), ("左格第二行", 80, 86), ("右格第一行", 540, 36), ("右格第二行", 540, 86)] {
			ctx.textPosition = CGPoint(x: x, y: 170 - top - 30)
			CTLineDraw(Fixtures.ctLine(s, size: 30), ctx)
		}
	}
	return ctx.makeImage()!
}

@Test func 转了90度的页一格高的短竖线也找得到() throws {
	// 版面上的竖线门槛松（一格高的也要），横线门槛严（字的笔画会连成线）。页转了 90°，短竖线在图上是横的，
	// 要按版面分横竖，不然被横线的门槛丢掉、格子围不起来。
	let upright = shortWallTable(text: false)
	let turned = try #require(rotate(upright, degrees: 90))
	let n = countRules(findRules(upright, unit: 36), width: 1000, height: 170)
	#expect(n.horizontal == 2 && n.vertical == 3, "正放：\(n)")
	let m = countRules(findRules(turned, unit: 36, sideways: true), width: Double(turned.width), height: Double(turned.height))
	#expect(m.horizontal == 3 && m.vertical == 2, "转 90°：\(m)")
	// 端到端：转 90° 的整页认出来，还是一格一格地出。
	let p = try ocr(try #require(rotate(shortWallTable(), degrees: 90))) { $0.languages = ["zh-Hans"] }
	#expect(Fixtures.compact(p.text) == "左格第一行左格第二行右格第一行右格第二行", "顺序：\(p.text)")
}

@Test func 字的笔画连成的线按行框筛掉() throws {
	// 满屏 13 像素的小字：几个字的横笔画挨得近，会连成够长的「线」，都压在字中间，筛掉以后一条不剩。
	let texts = ["本机识别不需要联网也不收费", "表格要用文档模式才分得清", "阅读顺序需要按位置重新排", "切块以后每块里的字相对变大"]
	let ctx = Fixtures.canvas(1200, 400)
	for c in 0..<3 { Fixtures.draw(texts, size: 13, in: ctx, left: 40 + 400 * CGFloat(c), top: 40) }
	let image = ctx.makeImage()!
	let lines = try recognizeLines(image, options: LineOptions(correction: true))[0]
	let unit = try #require(lineUnit(lines, width: image.width, height: image.height))
	let frame = UprightFrame(lines, width: image.width, height: image.height)
	let kept = uprightRules(findRules(image, unit: unit), frame: frame, boxes: uprightBoxes(lines, frame: frame))
	#expect(kept.isEmpty, "留下了 \(kept)")
}

@Test func 画线表格里折行的格子认完按格子出() throws {
	// 端到端：真的画一排表格、真的认，看出来的顺序。左边「工程名称」一行，中间一格折成三行，右边「施工 / 单位」两行。
	let ctx = Fixtures.canvas(1300, 420)
	ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
	ctx.setLineWidth(2)
	for y in [60.0, 360] {
		ctx.move(to: CGPoint(x: 40, y: y))
		ctx.addLine(to: CGPoint(x: 1260, y: y))
	}
	for x in [40.0, 280, 760, 960, 1260] {
		ctx.move(to: CGPoint(x: x, y: 60))
		ctx.addLine(to: CGPoint(x: x, y: 360))
	}
	ctx.strokePath()
	func put(_ s: String, _ x: CGFloat, _ top: CGFloat) {
		ctx.textPosition = CGPoint(x: x, y: 420 - top - 36)
		CTLineDraw(Fixtures.ctLine(s, size: 36), ctx)
	}
	// 格子里的字离竖线留够空：挨得太近系统会把相邻两格认成一行（这一步还没按线切开，见方案）。
	put("工程名称", 70, 190)
	put("某某高速穿越", 400, 110)
	put("500千伏某某线", 400, 190)
	put("电力迁改工程", 400, 270)
	put("施工", 820, 150)
	put("单位", 820, 230)
	put("王小明", 1060, 190)
	let p = try ocr(ctx.makeImage()!) { $0.languages = ["zh-Hans"] }
	let text = Fixtures.compact(p.text)
	#expect(text == "工程名称某某高速穿越500千伏某某线电力迁改工程施工单位王小明", "顺序：\(p.text)")
	let found = (p.steps["rules"] as? [String: Any])?["kept"] as? Int
	#expect(found == 7, "用上的线：\(String(describing: p.steps["rules"]))")
}
