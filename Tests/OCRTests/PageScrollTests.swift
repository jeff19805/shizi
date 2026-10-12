import AppKit
import CoreText
import SwiftUI
import Testing
@testable import OCRCore
@testable import ShiziKit

@Test func 中栏横竖混排首尾和跳页用同一个位置() {
	let wide = CGSize(width: 3000, height: 1200), tall = CGSize(width: 2120, height: 3000)
	for sizes in [Array(repeating: wide, count: 8), Array(repeating: tall, count: 32), [wide, tall, wide, tall, wide]] {
		let layout = PageLayout(sizes: sizes, viewport: CGSize(width: 420, height: 700))
		let travel = layout.contentHeight - 700
		#expect(layout.currentPage(at: -50, visibleHeight: 700) == 1, "顶部回弹还是第一页")
		#expect(layout.currentPage(at: 1, visibleHeight: 700) == 1, "轻轻一滚不跳过第一页")
		#expect(layout.currentPage(at: travel + 50, visibleHeight: 700) == sizes.count, "底部回弹还是最后一页")
		var visited = Set<Int>()
		var previous = 1
		for offset in stride(from: CGFloat(0), through: travel, by: 1) {
			let page = layout.currentPage(at: offset, visibleHeight: 700)!
			#expect(page >= previous, "一直向下滚，页码不能倒退")
			#expect(layout.top(page) < offset + 700 && layout.top(page) + layout.height(page) > offset, "文字对应的页仍在视口里")
			visited.insert(page)
			previous = page
		}
		#expect(visited == Set(1...sizes.count), "中间的页也都能滚到")
		for n in 1...sizes.count {
			let offset = layout.offset(for: n, visibleHeight: 700)
			#expect(layout.currentPage(at: offset + 1, visibleHeight: 700) == n, "跳完第 \(n) 页轻轻一滚，页码不变")
			#expect(layout.centers[n - 1] >= offset && layout.centers[n - 1] <= offset + 700, "当前页真的在可见区域")
		}
	}
	let short = PageLayout(sizes: [CGSize(width: 100, height: 50), CGSize(width: 100, height: 50)], viewport: CGSize(width: 420, height: 700))
	#expect(short.currentPage(at: 0, visibleHeight: 700) == nil, "全放得下时保留人点的那一页")
	let mixed = PageLayout(sizes: (1...32).map { $0.isMultiple(of: 2) ? wide : tall }, viewport: CGSize(width: 420, height: 700))
	#expect(abs(mixed.centers[29] - mixed.offset(for: 30, visibleHeight: 700) - 350) < 1, "第 30 页能居中，就应居中，不受末页补偿影响")
}

/// 用真正的 DocumentView 和原生滚动容器验联动；直接改容器位置，不合成鼠标事件。
/// 屏幕外没有显示刷新，滚轮动画走不动，但容器的位置、SwiftUI 更新和异步出图都能验。
@MainActor @Test func 中栏实际滚到底同步末页且不会反向跳动() async throws {
	let doc = try scrollDocument(Array(repeating: CGSize(width: 842, height: 595), count: 8))
	let window = ScrollTestWindow(doc: doc)
	defer { window.orderOut(nil) }
	let scroll = try await window.pageScroll()
	let clip = scroll.contentView
	#expect(doc.page == 1)
	// 工具栏占位时，原生容器的起点是负数；不能拿坐标 0 冒充滚到顶。
	move(scroll, to: clip.bounds.minY + 1)
	try await Task.sleep(for: .milliseconds(60))
	#expect(doc.page == 1, "刚离开顶部仍是第一页")
	move(scroll, to: 350)
	try await Task.sleep(for: .milliseconds(80))
	#expect(abs(clip.bounds.minY - 350) < 1 && doc.pageNavigation == 0, "滚动同步页码不能反过来吸附到页中心")
	// 认字、出图和滚动同时发生；缩略图换高清图不能把刚滚到的页拉回去。
	doc.start()
	move(scroll, to: 100_000)
	await waitFor(5) { doc.page == 8 }
	#expect(doc.page == 8, "只滚到末尾，没调用 show(page:) 来帮忙")
	let bottom = clip.bounds.minY
	await waitFor { !doc.isRunning && doc.pageImages[8] != nil }
	#expect(doc.results[doc.page]?.cleanText.contains("8") == true, "当前页的文字是最后一页")
	#expect(abs(clip.bounds.minY - bottom) < 1 && doc.page == 8, "异步结果回来不改滚动位置")
	// 点眼前的上一页选行，只换右边的字和框，不把原图挪走；再点它的页码才主动定位。
	doc.selectPage(7)
	doc.selectedLine = 0
	try await Task.sleep(for: .milliseconds(60))
	#expect(doc.page == 7 && doc.selectedLine == 0 && abs(clip.bounds.minY - bottom) < 1)
	doc.show(page: 7)
	await waitFor(3) { clip.bounds.minY < bottom - 10 }
	#expect(doc.page == 7 && clip.bounds.minY < bottom - 10, "即便页码没变，也响应主动定位")
	move(scroll, to: -100_000)
	await waitFor(3) { doc.page == 1 }
	#expect(doc.page == 1)
	// 连续跳两次，只响应最后一次；之后马上继续滚，不能有旧版 0.3 秒的失联窗口。
	doc.show(page: 3)
	doc.show(page: 8)
	await waitFor(3) { abs(clip.bounds.minY - bottom) < 1 }
	#expect(doc.page == 8 && abs(clip.bounds.minY - bottom) < 1)
	move(scroll, to: -100_000)
	await waitFor(0.2) { doc.page == 1 }
	#expect(doc.page == 1, "跳完立即滚到顶，文字跟上")
}

@MainActor @Test func 中栏连续跳页不积存从没显示过的高清图() async throws {
	let doc = try scrollDocument(Array(repeating: CGSize(width: 842, height: 595), count: 12))
	for n in 1...12 { doc.show(page: n) }
	await waitFor { doc.pageImage != nil }
	#expect(doc.pageImages.keys.sorted() == [12], "没来得及显示的中间页不白画")
	for n in stride(from: 11, through: 1, by: -1) {
		doc.show(page: n)
		await waitFor { doc.pageImage != nil }
		#expect(doc.pageImages.count <= 3, "当前页以外，只留最近看过的两页")
	}
}

@MainActor @Test func 中栏混排远跳缩放和重建后仍对应当前页() async throws {
	let sizes = (1...32).map { $0.isMultiple(of: 2) ? CGSize(width: 842, height: 300) : CGSize(width: 595, height: 842) }
	let doc = try scrollDocument(sizes)
	let window = ScrollTestWindow(doc: doc)
	defer { window.orderOut(nil) }
	var scroll = try await window.pageScroll()
	doc.show(page: 30)
	await waitFor(5) { doc.pageImages[30] != nil && scroll.contentView.bounds.minY > 5_000 }
	#expect(doc.page == 30 && scroll.contentView.bounds.minY > 5_000, "尚未画过的远页也能跳到：位置 \(scroll.contentView.bounds)，全文 \(scroll.documentView?.bounds ?? .zero)，已出图 \(doc.pageImages.keys.sorted())")
	move(scroll, to: scroll.contentView.bounds.minY + 1)
	try await Task.sleep(for: .milliseconds(80))
	#expect(doc.page == 30, "远跳后轻轻一滚不换成相邻页")
	for size in [CGSize(width: 900, height: 580), CGSize(width: 1200, height: 580), CGSize(width: 1000, height: 760)] {
		window.setContentSize(size)
		try await Task.sleep(for: .milliseconds(200))
		move(scroll, to: scroll.contentView.bounds.minY + 1)
		try await Task.sleep(for: .milliseconds(80))
		#expect(doc.page == 30, "缩放成 \(size) 后当前页仍在原图那一栏里")
	}
	// 切换文件后回来会重建这一栏；重建时不能先拿顶部位置把保存的当前页改成 1。
	window.contentView = NSHostingView(rootView: DocumentView(doc: doc))
	scroll = try await window.pageScroll()
	await waitFor(3) { scroll.contentView.bounds.minY > 5_000 }
	move(scroll, to: scroll.contentView.bounds.minY + 1)
	try await Task.sleep(for: .milliseconds(80))
	#expect(doc.page == 30, "切回文件还在第 30 页")
	move(scroll, to: 100_000)
	await waitFor(3) { doc.page == 32 }
	#expect(doc.page == 32)
	#expect(doc.pageImages.count < 12, "32 页不能全留高清图：现在留了 \(doc.pageImages.count) 页")
}

@MainActor
private final class ScrollTestWindow: NSWindow {
	init(doc: DocumentModel) {
		_ = NSApplication.shared
		super.init(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 760),
			styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
		isReleasedWhenClosed = false
		let host = NSHostingView(rootView: DocumentView(doc: doc))
		host.sceneBridgingOptions = [.toolbars, .title]
		contentView = host
		orderFrontRegardless()
	}

	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

	func pageScroll() async throws -> NSScrollView {
		var found: NSScrollView?
		await waitFor(3) {
			self.contentView?.layoutSubtreeIfNeeded()
			found = descendants(self.contentView!).compactMap { $0 as? NSScrollView }.first {
				$0.bounds.width > 200 && ($0.documentView?.bounds.height ?? 0) > $0.bounds.height + 1
			}
			return found != nil
		}
		// 给初次布局后排队的定位回调一次机会；不等画图。
		try await Task.sleep(for: .milliseconds(80))
		return try #require(found, "原图的滚动容器应该已经排好")
	}
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
	[view] + view.subviews.flatMap(descendants)
}

@MainActor
private func move(_ scroll: NSScrollView, to y: CGFloat) {
	var bounds = scroll.contentView.bounds
	bounds.origin.y = y
	scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
	scroll.reflectScrolledClipView(scroll.contentView)
}

@MainActor
private func scrollDocument(_ sizes: [CGSize]) throws -> DocumentModel {
	let url = Fixtures.tempURL("pdf")
	var box = CGRect(origin: .zero, size: sizes[0])
	let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
	for (index, size) in sizes.enumerated() {
		var page = CGRect(origin: .zero, size: size)
		let data = Data(bytes: &page, count: MemoryLayout<CGRect>.size)
		pdf.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
		pdf.setFillColor(CGColor(gray: 0, alpha: 1))
		pdf.textPosition = CGPoint(x: 80, y: size.height / 2)
		CTLineDraw(Fixtures.ctLine("第 \(index + 1) 页的识别文字", size: 32), pdf)
		pdf.endPDFPage()
	}
	pdf.closePDF()
	return try DocumentModel(url: url, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
}
