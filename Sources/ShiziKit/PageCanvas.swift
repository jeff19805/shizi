import AppKit
import OCRCore
import SwiftUI

/// 原图那一栏：所有页上下接成一长条（照「预览」默认的连续滚动），鼠标、触控板都跟着手走、带惯性。
/// 页码栏、右边的字跟着可见的页换；滚到头、尾时一定是第一、最后一页。
struct PageScroller: View {
	let doc: DocumentModel
	@State private var visiblePages = 1...1

	var body: some View {
		GeometryReader { geo in
			let layout = PageLayout(sizes: (1...doc.totalPages).map(doc.pageSize), viewport: geo.size)
			ScrollView(.vertical) {
				// 混排的长短页不能交给 LazyVStack 估高度：尚未出现的页会按已出现的页猜，
				// 页一多，总高就猜偏了，远跳就落不准。位置用 PDF 的尺寸
				// 预先算好；只建可见页及前后各一页，仍然不把整份 PDF 的高清图塞进内存。
				ZStack(alignment: .topLeading) {
					ForEach(Array(visiblePages), id: \.self) { n in
						PageCanvas(doc: doc, n: n, fit: layout.fit(n), activate: doc.selectPage)
							.frame(width: geo.size.width, height: layout.height(n))
							.offset(y: layout.top(n))
					}
				}
				.frame(width: geo.size.width, height: layout.contentHeight, alignment: .topLeading)
				.background(PageScrollPosition(doc: doc, layout: layout, navigation: doc.pageNavigation) { pages in
					if visiblePages != pages { visiblePages = pages }
				})
			}
			.scrollBounceBehavior(.basedOnSize)
		}
		.background(Color(nsColor: .windowBackgroundColor))
	}
}

/// 连续滚动时每页占多大：一页放一屏（四周留 16，整页看得见，跟原来一页一页看时一样大），小图不放大。
/// 每格高是图高加 16（上下各 8），整条上下再各留 8：页与页之间、最上面一页离顶都是 16。
/// 先按页面大小排好（打开时就知道每页多大），图后画：跳得再远位置也是准的，图到了也不挤动别的页。
struct PageLayout: Equatable {
	static let gap: CGFloat = 16
	let sizes: [CGSize]
	let viewport: CGSize
	/// 每页中心在长卷里的位置；一次排好，滚动时不重新遍历 PDF 或画图。
	let centers: [CGFloat]
	let heights: [CGFloat]
	let contentHeight: CGFloat

	init(sizes: [CGSize], viewport: CGSize) {
		self.sizes = sizes
		self.viewport = viewport
		heights = sizes.map { fitted($0, in: viewport).height + Self.gap }
		let total = heights.reduce(Self.gap, +)
		contentHeight = max(total, viewport.height)
		var top = Self.gap / 2 + max(0, (viewport.height - total) / 2)
		centers = heights.map { height in
			defer { top += height }
			return top + height / 2
		}
	}

	/// 第 n 页（从 1 起）的图在它那一格里的位置。
	func fit(_ n: Int) -> CGRect {
		let size = fitted(sizes[n - 1], in: viewport).size
		return CGRect(x: (viewport.width - size.width) / 2, y: Self.gap / 2, width: size.width, height: size.height)
	}

	func height(_ n: Int) -> CGFloat { heights[n - 1] }
	func top(_ n: Int) -> CGFloat { centers[n - 1] - heights[n - 1] / 2 }

	/// 多留前后各一页，缓慢滚动时下页已经画好。快速远跳只画新位置附近的页。
	func visiblePages(in rect: CGRect) -> ClosedRange<Int> {
		let first = centers.indices.first { centers[$0] + heights[$0] / 2 >= rect.minY } ?? max(0, sizes.count - 1)
		let last = centers.indices.last { centers[$0] - heights[$0] / 2 <= rect.maxY } ?? first
		return max(1, first)...min(sizes.count, last + 2)
	}

	/// 中段照视口中心判断；首尾几个短页对不到中心，就在这一小段里平稳过渡到第一页、末页中心。
	/// 不能把补偿摊到整份文件：页多的混排文件，点靠后的一页，它会挤到视口底下，大半画面反而是前一页。
	func currentPage(at offset: CGFloat, visibleHeight: CGFloat) -> Int? {
		let travel = contentHeight - visibleHeight
		// 不到 1 点的溢出当作像素取整，不让原本放得下的文件自动换页。
		guard travel > 1, let first = centers.first, let last = centers.last else { return nil }
		let y = min(max(offset, 0), travel)
		var focus = first + y / travel * (last - first)
		if let (start, end) = centeredSpan(visibleHeight) {
			let leading = start - visibleHeight / 2, trailing = end - visibleHeight / 2
			if y < leading {
				focus = first + y / leading * (start - first)
			} else if y > trailing {
				focus = end + (y - trailing) / (travel - trailing) * (last - end)
			} else {
				focus = y + visibleHeight / 2
			}
		}
		// 找判断位置落在哪一页，不能只找最近的中心：长短页混排时，短页已经滚出画面，
		// 它的中心却可能仍比长页的中心近，右栏就会滞留在看不见的那页。
		return (centers.indices.first { focus < centers[$0] + heights[$0] / 2 } ?? centers.count - 1) + 1
	}

	/// 跳页和滚动用同一套位置，跳完后轻轻一滚不会突然换成隔壁页；整个文件放得下时不滚。
	func offset(for n: Int, visibleHeight: CGFloat) -> CGFloat {
		guard centers.indices.contains(n - 1), let first = centers.first, let last = centers.last, last > first else { return 0 }
		let travel = max(0, contentHeight - visibleHeight), center = centers[n - 1]
		guard let (start, end) = centeredSpan(visibleHeight) else { return travel * (center - first) / (last - first) }
		let leading = start - visibleHeight / 2, trailing = end - visibleHeight / 2
		if center < start { return leading * (center - first) / (start - first) }
		if center > end { return trailing + (travel - trailing) * (center - end) / (last - end) }
		return center - visibleHeight / 2
	}

	/// 找实际能居中的页。严格排除恰在滚动边界的中心，给前后的短页留下可滚到的距离。
	/// 若整份文件只比视口长一点、没有一页能居中，才把全程分给首尾。
	private func centeredSpan(_ visibleHeight: CGFloat) -> (CGFloat, CGFloat)? {
		guard let start = centers.first(where: { $0 > visibleHeight / 2 }),
			let end = centers.last(where: { $0 < contentHeight - visibleHeight / 2 }), start <= end else { return nil }
		return (start, end)
	}
}

/// 原图那一栏的一页：图上叠着认出的每一行的框，平时细灰线，可能认错的琥珀虚线，选中的那一行强调色描边加淡底。
/// 框能关（工具栏、菜单「显示 › 显示识别框」）：关了只画选中的那一行，在逐行里点一行还看得到它在哪。
/// 点一下选中那一行；按住拖一个框，可以只认框里那一块（框选识别）。点到、拖到的这一页成了当前页。
struct PageCanvas: View {
	@Bindable var doc: DocumentModel
	let n: Int
	/// 图在这一格里的位置和大小（排版时按页面大小算好的）。
	let fit: CGRect
	/// 点到、拖到这一页时叫：设成当前页。
	let activate: (Int) -> Void
	@AppStorage(ViewOptions.showBoxes) private var showBoxes = true
	@State private var dragging: CGRect?
	/// 拖完留下的框（这一格里的坐标），等着点「识别框里的字」。
	@State private var region: CGRect?
	/// 拖完时图的位置：认的时候按它换算，中间窗口变了大小也对得上。
	@State private var regionFit: CGRect = .zero
	@State private var regionWorking = false
	@State private var regionResult: RegionResult?

	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: .topLeading) {
				page
					.frame(width: fit.width, height: fit.height)
					.overlay(Rectangle().strokeBorder(.separator))
					.offset(x: fit.minX, y: fit.minY)
				Canvas { ctx, _ in drawBoxes(&ctx) }
					.allowsHitTesting(false)
				if let rect = dragging ?? region {
					RoundedRectangle(cornerRadius: 6)
						.fill(Color.accentColor.opacity(0.08))
						.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
						.frame(width: rect.width, height: rect.height)
						.offset(x: rect.minX, y: rect.minY)
						.allowsHitTesting(false)
				}
				if let rect = region, dragging == nil {
					regionBar
						.offset(x: rect.minX, y: rect.maxY + 8 > geo.size.height - 44 ? max(rect.minY - 44, 0) : rect.maxY + 8)
				}
			}
			.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
			.contentShape(Rectangle())
			.gesture(dragGesture)
			.popover(item: $regionResult, attachmentAnchor: .rect(.rect(region ?? .zero)), arrowEdge: .bottom) { RegionPopover(result: $0) }
		}
		.onAppear { doc.pageAppeared(n) }
		.onDisappear { doc.pageDisappeared(n) }
		.onExitCommand { region = nil }
		.onChange(of: doc.page) { _, current in
			guard current != n else { return }
			region = nil
			regionResult = nil
		}
	}

	/// 这一页的图。还没画好时先拿页码栏的缩略图顶着（放到跟画好的一样大，换上清楚的那张时不跳）；缩略图也还没有，就是一张白纸加个小转圈。
	@ViewBuilder var page: some View {
		if let image = doc.pageImages[n] ?? doc.thumbnails[n] {
			Image(decorative: image, scale: 1)
				.resizable()
				.interpolation(.high)
		} else {
			Color.white.overlay(ProgressView().controlSize(.small))
		}
	}

	var lines: [OCRLine] { doc.results[n]?.lines ?? [] }

	/// 选中的那一行：只在当前页上。
	var selected: Int? { doc.page == n ? doc.selectedLine : nil }

	// MARK: 画框

	func drawBoxes(_ ctx: inout GraphicsContext) {
		for (i, line) in lines.enumerated() {
			guard showBoxes || i == selected else { continue }
			let path = Path { p in p.addLines(line.quad.map { point($0, fit) }); p.closeSubpath() }
			if i == selected {
				ctx.fill(path, with: .color(Color.accentColor.opacity(0.18)))
				ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
			} else if line.suspect != nil {
				ctx.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
			} else {
				ctx.stroke(path, with: .color(.gray.opacity(0.45)), lineWidth: 1)
			}
		}
	}

	func point(_ p: NPoint, _ fit: CGRect) -> CGPoint {
		CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
	}

	/// 点到的那一行：点落在几个框里时取最小的那个。
	func line(at location: CGPoint) -> Int? {
		lines.indices
			.filter { inside(location, lines[$0].quad.map { point($0, fit) }) }
			.min { lines[$0].box.area < lines[$1].box.area }
	}

	// MARK: 点和拖

	var dragGesture: some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { v in
				guard hypot(v.translation.width, v.translation.height) >= 4 else { return }
				if dragging == nil { activate(n) }
				regionResult = nil
				dragging = CGRect(from: v.startLocation, to: v.location).intersection(fit)
			}
			.onEnded { v in
				defer { dragging = nil }
				if hypot(v.translation.width, v.translation.height) < 4 {
					region = nil
					activate(n)
					doc.selectedLine = line(at: v.location)
					return
				}
				let r = CGRect(from: v.startLocation, to: v.location).intersection(fit)
				region = r.width >= 8 && r.height >= 8 ? r : nil
				regionFit = fit
			}
	}

	var regionBar: some View {
		HStack(spacing: 8) {
			Button {
				runRegion()
			} label: {
				if regionWorking {
					ProgressView().controlSize(.small)
				} else {
					Text("识别框里的字")
				}
			}
			.buttonStyle(.borderedProminent)
			.disabled(regionWorking)
			Button("取消") { region = nil }
		}
		.controlSize(.small)
		.padding(6)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.shadow(color: .black.opacity(0.15), radius: 6, y: 2)
	}

	func runRegion() {
		guard let r = region, regionFit.width > 0 else { return }
		let fit = regionFit
		let normalized = NRect(
			x: (r.minX - fit.minX) / fit.width, y: (r.minY - fit.minY) / fit.height, w: r.width / fit.width, h: r.height / fit.height
		).clamped()
		regionWorking = true
		doc.recognize(region: normalized, onPage: n) { result in
			regionWorking = false
			switch result {
			case .success(let text): regionResult = RegionResult(text: text, problem: nil)
			case .failure(let error): regionResult = RegionResult(text: "", problem: "\(error)")
			}
		}
	}
}

struct RegionResult: Identifiable {
	let id = UUID()
	var text: String
	var problem: String?
}

struct RegionPopover: View {
	let result: RegionResult

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("框里认出的字").font(.headline)
			if let problem = result.problem {
				Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
			} else if result.text.isEmpty {
				Text("这一块没认出字").foregroundStyle(.secondary)
			} else {
				ScrollView {
					Text(result.text)
						.lineSpacing(4)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(maxHeight: 240)
			}
			HStack {
				Spacer()
				Button("复制") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(result.text, forType: .string)
				}
				.disabled(result.text.isEmpty)
			}
		}
		.padding(12)
		.frame(width: 320)
	}
}

/// 图按比例放进区域、四周留 16，最多放到一个像素一个点（小图不放大糊掉）。
func fitted(_ image: CGSize, in area: CGSize, padding: CGFloat = 16) -> CGRect {
	let w = max(area.width - padding * 2, 1), h = max(area.height - padding * 2, 1)
	let scale = min(w / max(image.width, 1), h / max(image.height, 1), 1)
	let size = CGSize(width: image.width * scale, height: image.height * scale)
	return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
}

/// 点在不在多边形里（射线法）。
func inside(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
	guard polygon.count >= 3 else { return false }
	var result = false
	var j = polygon.count - 1
	for i in polygon.indices {
		let a = polygon[i], b = polygon[j]
		if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
		j = i
	}
	return result
}

extension CGRect {
	init(from a: CGPoint, to b: CGPoint) {
		self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
	}
}
