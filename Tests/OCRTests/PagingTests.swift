import CoreGraphics
import Foundation
import Testing
@testable import OCRCore

/// 不用真去认的一页结果，测回复怎么放。
func fakePage(_ n: Int, _ text: String) -> PageResult {
	PageResult(
		page: n, width: 100, height: 100, mode: .lines, lines: [], text: text, cleanText: text, document: nil,
		barcodes: [], notes: [], coordinateSpace: "original", rectifiedImage: nil, steps: [:])
}

@Test func 页码写成区间() {
	#expect(pageRanges([1, 2, 3, 5, 7, 8]) == "1-3,5,7-8")
	#expect(pageRanges([10]) == "10")
	#expect(pageRanges([]) == "")
}

@Test func 回复放不下就在整页处停并写明接着认哪几页() {
	var reply = ModelReply(totalPages: 30, maxBytes: 3000)
	let body = String(repeating: "密排的中文正文", count: 40)
	var added: [Int] = []
	for n in 1...20 {
		guard reply.add(fakePage(n, body)) else { break }
		added.append(n)
	}
	#expect(reply.full)
	#expect(!added.isEmpty && added.count < 20 && added == reply.pages)
	let text = reply.text(remaining: Array((added.count + 1)...30))
	#expect(text.utf8.count <= 3000, "超了上限：\(text.utf8.count) 字节")
	#expect(text.hasSuffix("没给的接着用 pages=\"\(added.count + 1)-30\"；要整份全文可以用 ocr_to_file 写成文件】"), "末尾提示不对：\(text.suffix(150))")
	#expect(text.hasPrefix("【第 1 页】") && text.contains("一次回复最多约"))
}

@Test func 没超大小但超了页数也写明() {
	var reply = ModelReply(totalPages: 32)
	for n in 1...20 {
		let fits = reply.add(fakePage(n, "第 \(n) 页"))
		#expect(fits)
	}
	let text = reply.text(remaining: Array(21...32))
	#expect(!reply.full)
	#expect(text.contains("这次给了第 1-20 页（一次最多认 20 页）") && text.contains("pages=\"21-32\""))
}

@Test func 都放得下就不加提示() {
	var reply = ModelReply(totalPages: 2)
	let first = reply.add(fakePage(1, "一")), second = reply.add(fakePage(2, "二"))
	#expect(first && second)
	#expect(reply.text(remaining: []) == "【第 1 页】\n一\n\n【第 2 页】\n二")
}

@Test func 一页就超上限时截一部分并说明() {
	var reply = ModelReply(totalPages: 1, maxBytes: 2000)
	let lines = (1...200).map { "第 \($0) 行字" }.joined(separator: "\n")
	let fits = reply.add(fakePage(1, lines))
	#expect(!fits)
	let text = reply.text(remaining: [])
	#expect(text.utf8.count <= 2000)
	#expect(text.hasPrefix("第 1 行字") && text.contains("这张图的字太多") && text.contains("region"))
	#expect(reply.pages == [1])
}

@Test func 多页文件第一页就超上限时两句提示都有() {
	var reply = ModelReply(totalPages: 10, maxBytes: 2000)
	let lines = (1...200).map { "第 \($0) 行字" }.joined(separator: "\n")
	let fits = reply.add(fakePage(7, lines))
	#expect(!fits)
	let text = reply.text(remaining: Array(8...10))
	#expect(text.utf8.count <= 2000)
	#expect(text.hasPrefix("【第 7 页】") && text.contains("第 7 页的字太多") && text.contains("region"))
	#expect(text.hasSuffix("这次给了第 7 页（一次回复最多约 1 KB，再多放不下）；文件一共 10 页，没给的接着用 pages=\"8-10\"；要整份全文可以用 ocr_to_file 写成文件】"), "\(text.suffix(150))")
}

@Test func 行数也有上限() {
	// 灵犀还按行截：超过 2000 行的也会被截掉。
	var reply = ModelReply(totalPages: 5, maxBytes: 1_000_000, maxLines: 100)
	let page = Array(repeating: "短", count: 40).joined(separator: "\n")
	var n = 0
	while reply.add(fakePage(n + 1, page)) { n += 1 }
	#expect(n == 2, "每页 41 行，两页加中间的空行 83 行，第 3 页就超了")
	#expect(countLines(reply.text(remaining: [3, 4, 5])) <= 100)
}

@Test func PDF一页一页认可以中途停() throws {
	let url = Fixtures.pdf(pages: [["第一页的正文内容"], ["第二页的正文内容"], ["第三页的正文内容"]])
	let source = try PageSource(path: url.path)
	#expect(source.totalPages == 3)
	var seen: [Int] = []
	try engine.run(source, pages: try source.select(nil, limit: nil), options: OCROptions()) { p in
		seen.append(p.page)
		#expect(Fixtures.compact(p.text).contains(["第一页", "第二页", "第三页"][p.page - 1]))
		return p.page < 2
	}
	#expect(seen == [1, 2])
	#expect(source.wanted([2, 9, 3]) == [2, 3])
	#expect(try source.select(nil, limit: 2) == [1, 2])
	#expect(throws: OCRError.self) { try source.select([7], limit: 20) }
}

@Test func 内存里的图片和PDF数据也能认() throws {
	let png = try #require(pngData(Fixtures.text(["粘贴进来的一张截图"])))
	let source = try PageSource(data: png)
	#expect(source.totalPages == 1 && source.wanted([5]) == [1])
	var text = ""
	try engine.run(source, pages: [1], options: OCROptions()) {
		text = $0.text
		return true
	}
	#expect(Fixtures.compact(text).contains("粘贴进来的一张截图"))
	let pdf = try Data(contentsOf: Fixtures.pdf(pages: [["一"], ["二"]]))
	#expect(try PageSource(data: pdf).totalPages == 2)
	#expect(throws: OCRError.self) { try PageSource(data: Data("不是图片".utf8)) }
}

@Test func 拉正过的页带上拉正后的图() throws {
	let p = try ocr(Fixtures.tiltedPaper(["拍歪的一张纸上写着几行字", "第二行也要认出来", "第三行在最下面"])) { $0.rectify = .on }
	#expect(p.coordinateSpace == "rectified", "没拉正：\(p.notes)")
	let image = try #require(p.rectifiedImage)
	#expect(image.width == p.width && image.height == p.height)
	#expect(Fixtures.compact(p.text).contains("第二行也要认出来"))
	#expect(try ocr(Fixtures.text(["平放的图不拉正"])).rectifiedImage == nil)
}

@Test func 小数照最短的写法写() {
	#expect(jsonString([1, true, 0.0652, 2.0, "x"] as [Any]) == "[1,true,0.0652,2,\"x\"]")
	#expect(jsonString(["a": [0.1234, 3] as [Any]]) == "{\"a\":[0.1234,3]}")
	#expect(jsonString(["p": 0.065199999999999994]) == "{\"p\":0.0652}")
}

@Test func 正的行不写四角歪的倒的才写() {
	#expect(lineJSON(Fixtures.line("正的", x: 0.1, y: 0.1, w: 0.3, h: 0.05))["quad"] == nil)
	#expect(lineJSON(Fixtures.line("歪的", x: 0.1, y: 0.1, w: 0.3, h: 0.05, degrees: 10))["quad"] != nil)
	// 倒着的字外框还是横平竖直的，但「左上」在图的右下：要写 quad，不然看不出是倒的。
	#expect(lineJSON(Fixtures.line("倒的", x: 0.1, y: 0.1, w: 0.3, h: 0.05, degrees: 180))["quad"] != nil)
}

@Test func full的JSON算在上限里() throws {
	var reply = ModelReply(totalPages: 3, maxBytes: 3000, withJSON: true)
	var n = 0
	while n < 3, reply.add(fakePage(n + 1, String(repeating: "字", count: 200))) { n += 1 }
	let content = reply.content(remaining: Array((n + 1)...3))
	#expect(n >= 1 && n < 3 && content.count == 2)
	#expect(content.joined(separator: "\n\n").utf8.count <= 3000)
	let json = try #require(try JSONSerialization.jsonObject(with: Data(content[1].utf8)) as? [String: Any])
	#expect((json["pages"] as? [[String: Any]])?.compactMap { $0["page"] as? Int } == reply.pages)
	#expect(json["totalPages"] as? Int == 3)
}

@Test func 连JSON放不下时只给字() {
	var reply = ModelReply(totalPages: 1, maxBytes: 1800, withJSON: true)
	let fits = reply.add(fakePage(1, String(repeating: "字", count: 300)))
	#expect(!fits && reply.jsonDropped && reply.pages == [1])
	let content = reply.content(remaining: [])
	#expect(content.count == 1 && content[0].contains("ocr_to_file"))
}
