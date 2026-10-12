import Testing
@testable import OCRCore

func cell(_ text: String, row: Int, col: Int, _ box: NRect) -> DocCell {
	DocCell(rows: row...row, columns: col...col, text: text, box: box)
}

func doc(paragraphs: [DocParagraph], tables: [DocTable] = [], lines: [OCRLine] = []) -> DocResult {
	DocResult(title: nil, paragraphs: paragraphs, lines: lines, tables: tables, lists: [], barcodes: [], data: [])
}

@Test func 表格格子换成逐行的字() {
	// 扫描件上，认文档把「数量」认成了「雞量」、序号格子整列丢失；逐行结果是对的。
	let a = NRect(x: 0.1, y: 0.1, w: 0.2, h: 0.05), b = NRect(x: 0.3, y: 0.1, w: 0.2, h: 0.05), c = NRect(x: 0.1, y: 0.15, w: 0.2, h: 0.05)
	let table = DocTable(cells: [cell("雞量", row: 0, col: 0, a), cell("挖士方", row: 0, col: 1, b), cell("", row: 1, col: 0, c)], box: NRect(x: 0.1, y: 0.1, w: 0.4, h: 0.1))
	let p = DocParagraph(text: "雞量", box: a)
	let lines = [
		Fixtures.line("数量", x: 0.12, y: 0.11, w: 0.1, h: 0.03),
		Fixtures.line("挖土方", x: 0.32, y: 0.11, w: 0.1, h: 0.03),
		Fixtures.line("1", x: 0.12, y: 0.16, w: 0.02, h: 0.03),
	]
	let out = fuse(doc(paragraphs: [p], tables: [table]), lines: lines, width: 1000, height: 1000)
	#expect(out.tables[0].grid == [["数量", "挖土方"], ["1", ""]])
	#expect(out.claimed == 1 && out.extras.isEmpty)
}

@Test func 两边对不上就留认文档自己的字() {
	let box = NRect(x: 0.1, y: 0.1, w: 0.5, h: 0.05)
	let p = DocParagraph(text: "认文档认出的这一段", box: box)
	let stray = Fixtures.line("完全不同的另一句话", x: 0.12, y: 0.11, w: 0.3, h: 0.03)
	let out = fuse(doc(paragraphs: [p]), lines: [stray], width: 1000, height: 1000)
	#expect(out.paragraphs[0].text == "认文档认出的这一段")
	#expect(out.extras.isEmpty, "落在段落里的行算这段的，不再列进零散字")
}

@Test func 哪块都不在的行单列在最后() {
	let p = DocParagraph(text: "正文一句", box: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.05))
	let lines = [Fixtures.line("正文一句", x: 0.12, y: 0.11, w: 0.2, h: 0.03), Fixtures.line("公章上的乱码", x: 0.6, y: 0.8, w: 0.2, h: 0.03)]
	let out = fuse(doc(paragraphs: [p]), lines: lines, width: 1000, height: 1000)
	#expect(out.extras.map(\.text) == ["公章上的乱码"])
	#expect(out.text.hasSuffix("（以下是没归进版面的零散字，多半是公章、签名或手写）\n公章上的乱码"))
	#expect(out.claimed > 0.3 && out.claimed < 0.5)
}

@Test func 只有认文档认出的段落标成可疑() {
	let p = DocParagraph(text: "留亚瞿婚", box: NRect(x: 0.6, y: 0.6, w: 0.2, h: 0.05))
	let q = DocParagraph(text: "正文一句", box: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.05))
	let docLine = Fixtures.line("留亚瞿婚", x: 0.62, y: 0.61, w: 0.1, h: 0.03)
	let out = fuse(doc(paragraphs: [q, p], lines: [docLine]), lines: [Fixtures.line("正文一句", x: 0.12, y: 0.11, w: 0.2, h: 0.03)], width: 1000, height: 1000)
	#expect(out.lines.map(\.text) == ["正文一句", "留亚瞿婚"])
	#expect(out.lines[1].suspect?.reason == .documentOnly)
}

@Test func 斜着的段落按轮廓分行() {
	// 两段斜着的字外接框大面积重叠，按框分会串段；按轮廓（贴着字走的多边形）分才对。
	let upper = [NPoint(x: 0.1, y: 0.3), NPoint(x: 0.6, y: 0.1), NPoint(x: 0.62, y: 0.15), NPoint(x: 0.12, y: 0.35)]
	let lower = [NPoint(x: 0.1, y: 0.5), NPoint(x: 0.6, y: 0.3), NPoint(x: 0.62, y: 0.35), NPoint(x: 0.12, y: 0.55)]
	let bigBox = NRect(x: 0.1, y: 0.1, w: 0.52, h: 0.45)
	let p1 = DocParagraph(text: "上面一段话", box: bigBox, region: upper)
	let p2 = DocParagraph(text: "下面一段话", box: bigBox, region: lower)
	let l1 = Fixtures.line("上面一段话", x: 0.33, y: 0.21, w: 0.04, h: 0.02)
	let l2 = Fixtures.line("下面一段话", x: 0.33, y: 0.41, w: 0.04, h: 0.02)
	let out = fuse(doc(paragraphs: [p1, p2]), lines: [l2, l1], width: 1000, height: 1000)
	#expect(out.paragraphs.map(\.text) == ["上面一段话", "下面一段话"])
	#expect(polygonContains(upper, l1.box.center) && !polygonContains(upper, l2.box.center))
}

@Test func 中文折行不多加空格() {
	#expect(joinWrapped(["新建#46-#51区", "段角钢塔基础"]) == "新建#46-#51区段角钢塔基础")
	#expect(joinWrapped(["The quick brown", "fox jumps"]) == "The quick brown fox jumps")
}

@Test func 认文档单独当成一段的一截不再列一遍() {
	// 界面截图上：认文档把一行字开头的几个字单独当成一段，结果里同一段字出现两遍。
	let short = DocParagraph(text: "只在项目", box: NRect(x: 0.32, y: 0.45, w: 0.04, h: 0.02))
	let long = DocParagraph(text: "只在项目「lingxi-core」", box: NRect(x: 0.32, y: 0.45, w: 0.1, h: 0.02))
	let line = Fixtures.line("只在项目「lingxi-core」", x: 0.324, y: 0.456, w: 0.097, h: 0.017)
	let docLine = Fixtures.line("只在项目", x: 0.323, y: 0.455, w: 0.041, h: 0.019)
	let out = fuse(doc(paragraphs: [short, long], lines: [docLine]), lines: [line], width: 1000, height: 1000)
	#expect(out.paragraphs.map(\.text) == ["只在项目「lingxi-core」"])
	#expect(out.lines.map(\.text) == ["只在项目「lingxi-core」"], "也不当成只有认文档认出的行")
}
