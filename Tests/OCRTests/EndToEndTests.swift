import CoreGraphics
import Foundation
import Testing
@testable import OCRCore

let engine = OCREngine(config: OCRConfig())

func ocr(_ image: CGImage, _ configure: (inout OCROptions) -> Void = { _ in }) throws -> PageResult {
	var o = OCROptions()
	configure(&o)
	return try engine.run(path: Fixtures.save(image), options: o).pages[0]
}

@Test func 中英混排两行() throws {
	let p = try ocr(Fixtures.text(["苹果自带的文字识别能做到哪一步", "Vision runs locally 2026"]))
	#expect(p.mode == .lines)
	let t = Fixtures.compact(p.text)
	#expect(t.contains("苹果自带的文字识别能做到哪一步") && t.contains("Visionrunslocally2026"))
	#expect(p.lines.allSatisfy { $0.box.x >= 0 && $0.box.maxX <= 1 })
}

@Test func 倒着的图顺序不反() throws {
	let image = rotate(Fixtures.text(["第一行在最上面", "第二行在中间", "第三行在最下面"], height: 260), degrees: 180)!
	let rows = try ocr(image).text.split(separator: "\n").map { Fixtures.compact(String($0)) }
	#expect(rows == ["第一行在最上面", "第二行在中间", "第三行在最下面"])
}

@Test func 大图里的小字会切块() throws {
	let lines = ["大图里的一段小字第一行用来测切块", "第二行同样很小但要认出来"]
	let ctx = Fixtures.canvas(3000, 2000)
	Fixtures.draw(lines, size: 12, in: ctx, left: 1300, top: 950)
	let p = try ocr(ctx.makeImage()!)
	#expect(p.steps["tiles"] as? String == "3x2")
	#expect(bagRecall(of: lines.joined(), in: p.text) >= 0.9, "只认出：\(p.text)")
}

@Test func 竖排走认文档() throws {
	guard OCREngine.documentModeAvailable else { return }
	let p = try ocr(Fixtures.vertical(["床前明月光", "疑是地上霜"]))
	#expect(p.mode == .document)
	#expect(Fixtures.compact(p.text).contains("床前明月光"))
	#expect(Fixtures.compact(p.text).contains("疑是地上霜"))
}

@Test func 只认一块且坐标仍相对整图() throws {
	let ctx = Fixtures.canvas(1200, 400)
	Fixtures.draw(["左边这段不要"], size: 30, in: ctx, left: 40, top: 150)
	Fixtures.draw(["右边这段才要"], size: 30, in: ctx, left: 760, top: 150)
	let p = try ocr(ctx.makeImage()!) { $0.region = NRect(x: 0.5, y: 0, w: 0.5, h: 1) }
	#expect(Fixtures.compact(p.text) == "右边这段才要")
	#expect(p.lines.allSatisfy { $0.box.x >= 0.5 })
}

@Test func PDF按页认() throws {
	let url = Fixtures.pdf(["这是PDF第一页的正文", "Page one body text"])
	let r = try engine.run(path: url.path, options: OCROptions())
	#expect(r.totalPages == 1)
	#expect(Fixtures.compact(r.pages[0].text).contains("这是PDF第一页的正文"))
	var o = OCROptions()
	o.pages = [3]
	#expect(throws: OCRError.self) { try engine.run(path: url.path, options: o) }
}

@Test func 认不了的文件说清楚() {
	#expect(throws: OCRError.self) { try engine.run(path: "/nonexistent/a.png", options: OCROptions()) }
	let junk = Fixtures.tempURL("png")
	try? Data("不是图片".utf8).write(to: junk)
	#expect(throws: OCRError.self) { try engine.run(path: junk.path, options: OCROptions()) }
}

@Test func 结果排版() throws {
	let p = try ocr(Fixtures.text(["排版测试"]))
	var withSuspect = p
	if !withSuspect.lines.isEmpty { withSuspect.lines[0].suspect = Suspect(reason: .plugin, probability: 0.8) }
	withSuspect.notes = ["一条说明"]
	let text = renderText([withSuspect], totalPages: 3)
	#expect(text.contains("【第 1 页】") && text.contains("【可能认错的行】") && text.contains("约 80%") && text.contains("一条说明"))
	#expect(text.contains("文件一共 3 页"))
	let json = resultJSON([p], totalPages: 1)
	#expect((json["pages"] as? [[String: Any]])?.first?["mode"] as? String == "lines")
}

@Test func 转过的大图小字先转正再切块() throws {
	let lines = ["第一行转过角度的大图小字需要先转正再切块认", "第二行同样很小而且很长横跨好几个方块", "第三行用来确认顺序和拼接都没有问题"]
	let ctx = Fixtures.canvas(3000, 2000)
	Fixtures.draw(lines, size: 14, in: ctx, left: 300, top: 900)
	let image = rotate(ctx.makeImage()!, degrees: 10)!
	let p = try ocr(image)
	#expect(p.steps["tiles"] != nil && p.steps["deskewDegrees"] != nil, "步骤：\(p.steps)")
	#expect(bagRecall(of: lines.joined(), in: p.text) >= 0.9, "只认出：\(p.text)")
	#expect(p.lines.allSatisfy { $0.box.x >= -0.01 && $0.box.maxX <= 1.01 && $0.box.y >= -0.01 && $0.box.maxY <= 1.01 })
}
