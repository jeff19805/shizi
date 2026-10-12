import AppKit
import Foundation
import Testing
@testable import OCRCore
@testable import ShiziKit

@Test func 整页里的表格画成真的表() {
	let blocks = textBlocks("前言一句\n| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n| a\\|b | 4 |\n结尾")
	#expect(blocks.count == 3)
	guard blocks.count == 3, case .text(let head) = blocks[0], case .table(let rows) = blocks[1], case .text(let tail) = blocks[2] else {
		Issue.record("切法不对：\(blocks)")
		return
	}
	#expect(head == "前言一句" && tail == "结尾")
	#expect(rows == [["名称", "数量"], ["苹果", "3"], ["a|b", "4"]], "分隔行不要，格子里的 \\| 是竖线")
}

@Test func 给人看的导出不带标记和可疑清单() {
	var p1 = fakePage(1, "〔左侧〕\n第一页")
	p1.cleanText = "第一页"
	p1.lines = [OCRLine(text: "第一页", confidence: 0.3, box: NRect(x: 0, y: 0, w: 0.1, h: 0.1), quad: [], suspect: Suspect(reason: .lowConfidence, probability: nil))]
	var p2 = fakePage(2, "第二页")
	p2.barcodes = ["https://example.com"]
	let md = exportMarkdown([p1, p2], title: "报告.pdf", totalPages: 2)
	#expect(md == "# 报告.pdf\n\n## 第 1 页\n\n第一页\n\n## 第 2 页\n\n第二页\n\n二维码 / 条码：\n- https://example.com\n")
	#expect(exportPlainText([p1, p2], totalPages: 2) == "第 1 页\n第一页\n\n第 2 页\n第二页\nhttps://example.com\n")
	#expect(exportPlainText([fakePage(1, "只有一张图")], totalPages: 1) == "只有一张图\n")
}

/// 等主线程上的回调跑完（拾字的识别结果是回到主线程再放进去的）。
@MainActor
func waitFor(_ seconds: Double = 30, _ done: () -> Bool) async {
	let deadline = Date().addingTimeInterval(seconds)
	while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
}

@MainActor @Test func 拾字一页页认能在页与页之间停下() async throws {
	// 扫描页（只有图）：有文字层的页几毫秒一页，来不及在中间停。
	let full = CGRect(x: 0, y: 0, width: 595, height: 842)
	let pdf = makePDF(["第一页的正文内容", "第二页的正文内容", "第三页的正文内容", "第四页的正文内容"].map { FakePage(picture: (picture([$0]), full)) })
	let doc = try DocumentModel(url: pdf, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	#expect(doc.totalPages == 4 && doc.isPDF)
	doc.start()
	await waitFor { doc.finishedCount >= 1 }
	doc.stop()
	await waitFor { !doc.isRunning }
	#expect(doc.state == .stopped)
	#expect(doc.finishedCount >= 1 && doc.finishedCount < 4, "停了还认完了全部 \(doc.finishedCount) 页")
	let first = doc.results[1]?.cleanText ?? ""
	#expect(Fixtures.compact(first).contains("第一页的正文内容"))
	doc.start()
	await waitFor { !doc.isRunning }
	#expect(doc.state == .done && doc.results.count == 4)
	#expect(doc.plainText.contains("第 4 页"))
}

@MainActor @Test func 拾字框选识别只认框里的() async throws {
	let ctx = Fixtures.canvas(1200, 400)
	Fixtures.draw(["左边这段不要"], size: 30, in: ctx, left: 40, top: 150)
	Fixtures.draw(["右边这段才要"], size: 30, in: ctx, left: 760, top: 150)
	let url = URL(fileURLWithPath: Fixtures.save(ctx.makeImage()!))
	let doc = try DocumentModel(url: url, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	var text: String?
	doc.recognize(region: NRect(x: 0.55, y: 0, w: 0.45, h: 1)) { text = try? $0.get() }
	await waitFor { text != nil }
	#expect(Fixtures.compact(text ?? "") == "右边这段才要")
}

@MainActor @Test func 拾字粘贴截图就开始认() async throws {
	let board = NSPasteboard(name: NSPasteboard.Name("拾字测试-\(UUID().uuidString)"))
	defer { board.releaseGlobally() }
	board.clearContents()
	board.setData(pngData(Fixtures.text(["粘贴进来的截图"])), forType: .png)
	let workspace = Workspace(recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	#expect(workspace.paste(from: board))
	let doc = try #require(workspace.selected)
	#expect(doc.name.hasPrefix("粘贴的截图"))
	await waitFor { !doc.isRunning }
	let pasted = doc.results[1]?.cleanText ?? ""
	#expect(Fixtures.compact(pasted).contains("粘贴进来的截图"))
	board.clearContents()
	#expect(!workspace.paste(from: board), "剪贴板里没图就不新开")
}

@Test func 不画图就知道每页画出来多大() throws {
	// 竖的、横的 PDF 页，大图（要缩）、小图（不放大）：跟真画出来的一样大，拾字先按它排版。
	let pdf = Fixtures.pdf(pages: [["竖的一页"], ["第二页"]])
	let source = try PageSource(path: pdf.path)
	for (n, longSide) in [(1, 3000), (2, 240)] {
		let image = try source.image(page: n, longSide: longSide)
		#expect(source.pixelSize(page: n, longSide: longSide) == CGSize(width: image.width, height: image.height))
	}
	let wide = Fixtures.text(["横的一张大图"], width: 4000, height: 1200)
	let small = Fixtures.text(["小图"], width: 300, height: 120)
	for picture in [wide, small] {
		let source = PageSource(image: picture)
		let image = try source.image(page: 1, longSide: 3000)
		#expect(source.pixelSize(page: 1, longSide: 3000) == CGSize(width: image.width, height: image.height))
	}
	#expect(PageSource(image: small).pixelSize(page: 1, longSide: 3000) == CGSize(width: 300, height: 120), "小图不放大")
}

@Test func 连续滚动一页放一屏() {
	let a4 = CGSize(width: 2121, height: 3000)
	let layout = PageLayout(sizes: [a4, a4, CGSize(width: 300, height: 120)], viewport: CGSize(width: 600, height: 700))
	// 竖的 A4 照高放：上下各留 16，跟原来一页一页看时一样大；格子比这一栏矮 16，页与页之间空 16。
	#expect(abs(layout.fit(1).height - (700 - 32)) < 0.001)
	#expect(abs(layout.height(1) - (700 - 16)) < 0.001)
	#expect(abs(layout.fit(1).midX - 300) < 0.001 && layout.fit(1).minY == 8, "左右居中、离格子顶 8")
	// 小图不放大。
	#expect(layout.fit(3).size == CGSize(width: 300, height: 120))
	#expect(abs(layout.height(3) - (120 + 16)) < 0.001)
}

@MainActor @Test func 拾字原图那一栏只留露着的页和最近收起的两页() async throws {
	let pdf = Fixtures.pdf(pages: (1...6).map { ["第 \($0) 页"] })
	let doc = try DocumentModel(url: pdf, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	#expect(doc.pageSize(1) == CGSize(width: 2120, height: 3000), "A4（595 × 842）照长边 3000 算")
	// 第 1、2 页露出来：图画好、缩略图也画了（顶着还没画好的页）。
	doc.pageAppeared(1)
	doc.pageAppeared(2)
	await waitFor { doc.pageImages[1] != nil && doc.pageImages[2] != nil }
	#expect(doc.thumbnails[1] != nil && doc.thumbnails[2] != nil)
	// SwiftUI 重建列表时，同一页的新格子先露出来、旧格子后收起来：还露着一格，图不能放。
	doc.pageAppeared(1)
	doc.pageDisappeared(1)
	#expect(doc.pageImages[1] != nil)
	// 一路往下滚：1、2 收起来，3、4、5 露出来又收起来。收起来的只留最近两页。
	for n in 3...5 {
		doc.pageAppeared(n)
		await waitFor { doc.pageImages[n] != nil }
	}
	for n in 1...5 { doc.pageDisappeared(n) }
	#expect(Set(doc.pageImages.keys) == [4, 5], "留着的是 \(doc.pageImages.keys.sorted())")
	// 露出来又马上收起来、还没轮到画的页，不画了。
	doc.pageAppeared(6)
	doc.pageDisappeared(6)
	try await Task.sleep(for: .milliseconds(500))
	#expect(doc.pageImages[6] == nil)
	// 换当前页时那一页的图先画上（菜单、测试里不靠原图那一栏露出来）。
	doc.show(page: 6)
	await waitFor { doc.pageImage != nil }
	let want = try PageSource(path: pdf.path).image(page: 6, longSide: 3000)
	#expect(doc.pageImage?.dataProvider?.data as Data? == want.dataProvider?.data as Data?, "显示的是第 6 页")
}
