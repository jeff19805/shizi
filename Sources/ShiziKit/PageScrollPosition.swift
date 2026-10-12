import AppKit
import SwiftUI

/// 只负责中栏的滚动位置。滚轮、触控板和惯性仍由 SwiftUI 的 ScrollView 管。
/// macOS 14 没有 onScrollGeometryChange，读它底下的原生滚动视图，避免按「正中间是哪页」猜首尾。
struct PageScrollPosition: NSViewRepresentable {
	let doc: DocumentModel
	let layout: PageLayout
	let navigation: Int
	let visiblePages: (ClosedRange<Int>) -> Void

	func makeNSView(context: Context) -> PageScrollProbe { PageScrollProbe() }

	func updateNSView(_ view: PageScrollProbe, context: Context) {
		view.update(doc: doc, layout: layout, navigation: navigation)
		view.visiblePages = visiblePages
	}
}

@MainActor
final class PageScrollProbe: NSView {
	var visiblePages: ((ClosedRange<Int>) -> Void)?
	override var isFlipped: Bool { true }
	// 背景只量位置，不挡原图上的点选和框选。
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
	private weak var scrollView: NSScrollView?
	private var observation: NSObjectProtocol?
	private var doc: DocumentModel?
	private var pageLayout: PageLayout?
	private var navigation: Int?
	private var pendingPage: Int?
	private var previousTop: CGFloat?
	private var previousViewport: CGSize?
	private var scheduled = false
	private var positioning = false

	deinit {
		if let observation { NotificationCenter.default.removeObserver(observation) }
	}

	func update(doc: DocumentModel, layout: PageLayout, navigation: Int) {
		// 新打开、切回来、窗口变大变小、识别后拉正改变页面大小：重新对齐当前页。
		// 普通出图和文字更新不挪位置，用户正在读哪一段就还留在哪。
		if self.doc !== doc || pageLayout != layout || self.navigation != navigation {
			pendingPage = doc.page
		}
		self.doc = doc
		pageLayout = layout
		self.navigation = navigation
		schedule()
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		schedule()
	}

	override func layout() {
		super.layout()
		schedule()
	}

	private func schedule() {
		guard !scheduled, !positioning else { return }
		scheduled = true
		// 等这一轮 SwiftUI 排版结束再读位置、改当前页，不能在 updateNSView 里回写观察状态。
		// 只合并同一轮通知，不按固定时间屏蔽：用户跳完马上滚，下一次位移就能跟上。
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.scheduled = false
			self.refresh()
		}
	}

	private func refresh() {
		guard let doc, let layout = pageLayout, let scroll = enclosingScrollView, window != nil else { return }
		if scrollView !== scroll {
			if let observation { NotificationCenter.default.removeObserver(observation) }
			scrollView = scroll
			scroll.contentView.postsBoundsChangedNotifications = true
			observation = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
			) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
		}
		// 内容还没排到最终高度时，不能拿旧尺寸跳页；下一次 layout 会再来。
		guard bounds.height > 0, abs(bounds.height - layout.contentHeight) < 1 else { return }
		let clip = scroll.contentView
		let insets = scroll.contentInsets
		var usable = clip.bounds
		usable.origin.y += insets.top
		usable.size.height -= insets.top + insets.bottom
		guard usable.height > 0 else { return }
		let visible = convert(usable, from: clip)
		// AppKit 的窗口大小通知可能早于 SwiftUI 重新排版；这次是缩放，不拿它当用户滚动换页。
		if previousViewport != visible.size { pendingPage = pendingPage ?? doc.page }
		previousViewport = visible.size
		if let page = pendingPage {
			pendingPage = nil
			let target = layout.offset(for: page, visibleHeight: visible.height)
			var proposed = clip.bounds
			proposed.origin.y += target - visible.minY
			positioning = true
			clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
			scroll.reflectScrolledClipView(clip)
			positioning = false
			let top = convert(clip.bounds, from: clip).minY + insets.top
			previousTop = top
			visiblePages?(layout.visiblePages(in: CGRect(x: 0, y: top, width: visible.width, height: visible.height)))
			return
		}
		visiblePages?(layout.visiblePages(in: visible))
		defer { previousTop = visible.minY }
		// 点原图选行、缩略图换高清图都不应抢走选中的页；只有位置真的变了才跟着滚动选页。
		guard let previousTop, abs(visible.minY - previousTop) > 0.01,
			let page = layout.currentPage(at: visible.minY, visibleHeight: visible.height) else { return }
		doc.selectPage(page)
	}
}
