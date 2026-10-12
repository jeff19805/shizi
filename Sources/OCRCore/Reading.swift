import Foundation

/// 每行的走向角（像素空间、y 向下，弧度）。
func lineAngle(_ l: OCRLine, width: Int, height: Int) -> Double {
	let tl = l.quad[0], tr = l.quad[1]
	return atan2((tr.y - tl.y) * Double(height), (tr.x - tl.x) * Double(width))
}

/// 整体走向：按字数加权取中位数。短词常不带角度（四角是水平的），所以按字数加权让长句说了算。
public func dominantAngle(_ lines: [OCRLine], width: Int, height: Int) -> Double {
	let items = lines.filter { $0.text.count >= 2 }.map { (angle: lineAngle($0, width: width, height: height), weight: Double($0.text.count)) }
		.sorted { $0.angle < $1.angle }
	guard !items.isEmpty else { return 0 }
	let total = items.reduce(0) { $0 + $1.weight }
	var acc = 0.0
	for it in items {
		acc += it.weight
		if acc >= total / 2 { return it.angle }
	}
	return items[items.count - 1].angle
}

/// 转到「字是正的」那个坐标系里的框（像素）：x 沿字的走向，y 向下。
struct UprightBox {
	var index: Int
	var x: Double
	var y: Double
	var w: Double
	var h: Double
	var cy: Double { y + h / 2 }
}

/// 「字是正的」那个坐标系：按整体走向把图转正，像素为单位。行框、表格线都用同一个转法转进来。
struct UprightFrame {
	let c: Double
	let s: Double
	let W: Double
	let H: Double

	init(_ lines: [OCRLine], width: Int, height: Int) {
		let theta = dominantAngle(lines, width: width, height: height)
		c = cos(-theta)
		s = sin(-theta)
		W = Double(width)
		H = Double(height)
	}

	func point(_ p: NPoint) -> (x: Double, y: Double) {
		let x = p.x * W, y = p.y * H
		return (x * c - y * s, x * s + y * c)
	}
}

func uprightBoxes(_ lines: [OCRLine], width: Int, height: Int) -> [UprightBox] {
	uprightBoxes(lines, frame: UprightFrame(lines, width: width, height: height))
}

func uprightBoxes(_ lines: [OCRLine], frame: UprightFrame) -> [UprightBox] {
	lines.enumerated().map { i, l in
		let pts = l.quad.map(frame.point)
		let xs = pts.map(\.x), ys = pts.map(\.y)
		let x0 = xs.min()!, y0 = ys.min()!
		return UprightBox(index: i, x: x0, y: y0, w: xs.max()! - x0, h: ys.max()! - y0)
	}
}

/// 一行字大约多高（像素，转正后各行高度的中位数）。没有行时返回 nil。
func lineUnit(_ lines: [OCRLine], width: Int, height: Int) -> Double? {
	let heights = uprightBoxes(lines, width: width, height: height).map(\.h).sorted()
	return heights.isEmpty ? nil : heights[heights.count / 2]
}

/// 按字的走向排成阅读顺序：分成一行一行（纵向重叠一半以上算同一行），行内从左到右。
/// 不能按图片的上下排——倒着的图会整个反过来。返回每一行里的原下标。
public func readingRows(_ lines: [OCRLine], width: Int, height: Int) -> [[Int]] {
	rows(of: uprightBoxes(lines, width: width, height: height))
}

func rows(of boxes: [UprightBox]) -> [[Int]] {
	var rows: [(cy: Double, h: Double, items: [UprightBox])] = []
	for b in boxes.sorted(by: { $0.y < $1.y }) {
		if let k = rows.firstIndex(where: { abs($0.cy - b.cy) < min($0.h, b.h) * 0.5 }) {
			rows[k].items.append(b)
		} else {
			rows.append((b.cy, b.h, [b]))
		}
	}
	return rows.sorted { $0.cy < $1.cy }.map { $0.items.sorted { $0.x < $1.x }.map(\.index) }
}

/// 排好的行拼成文字。同一行里离得远的（表格的格、两栏）用两个空格隔开。
public func joinRows(_ rows: [[Int]], _ lines: [OCRLine]) -> String {
	rows.map { row in row.map { lines[$0].text }.joined(separator: "  ") }.joined(separator: "\n")
}

/// 逐行模式的版面：按留白切成一块一块（左右栏、上下段），每块里再一行一行排（画了表格线的，按线围成的格子排，见 `cellRows`）。
public struct ReadingLayout {
	/// 每块里的行（行里是原下标），按阅读顺序。
	public var blocks: [[[Int]]]
	/// 这块跟前一块之间要不要空一行：不同的栏之间、隔得很远的段之间要空。
	public var breakBefore: [Bool]
	/// 页面切出了左右几栏时，每段（空行隔开的一段）开头标上它在页面上的大致位置，如「中间」「左侧」「右上」。
	/// 只给文字的模型看不出哪块是盖在页面中间的弹窗；单栏文档不标。
	public var position: [String?] = []
	/// 四面都有表格线围着的行有几行。认文档没找到表格时拿它判断：这页其实是画了线的表格（见 ruledFormInsteadOfDocument）。
	public var enclosed = 0
	/// 其中跟别的行同在一格（一格里不止一行）的有几行：只有这种格子，按格子排才跟一行行排不一样。
	public var grouped = 0
	/// 用上的表格线有几条（压在字中间的笔画、删除线已经筛掉）。
	public var rules = 0

	public var order: [Int] { blocks.flatMap { $0.flatMap { $0 } } }
}

/// 界面截图里左栏、正文、弹窗各排各的，整页一起按行分组会把同一高度的几栏字拼进一行
/// （左栏的字跟弹窗的字拼成一行，只看文字的模型据此就认错了哪块是弹窗）。
/// 做法：一层层找最宽的空白——横着贯穿这块区域的空白把上下切开，竖着贯穿的空白把左右切开。
/// 左右切之前看两边的行对不对得上：对得上（表格、「标签：值」表单，一行对一行）就不切，免得把表格一列一列拆开；
/// 各排各的（侧栏和正文）才切。
/// `rules`：图上的表格线（`findRules`）。四面有线围着的行算一格：切块时同一格的行不分开、栏缝里是格子的墙也不切，
/// 块里按格子一排排排（见 `cellRows`）。
public func readingLayout(_ lines: [OCRLine], width: Int, height: Int, rules: [RuleLine] = []) -> ReadingLayout {
	guard !lines.isEmpty else { return ReadingLayout(blocks: [], breakBefore: []) }
	let frame = UprightFrame(lines, width: width, height: height)
	let all = uprightBoxes(lines, frame: frame)
	let heights = all.map(\.h).sorted()
	let unit = max(heights[heights.count / 2], 1)
	let ruled = uprightRules(rules, frame: frame, boxes: all)
	var walls: [Int: Walls] = [:]
	for b in all { walls[b.index] = enclosure(b, ruled, unit: unit) }
	for (_, boxes) in Dictionary(grouping: all.filter { walls[$0.index] != nil }, by: { walls[$0.index]! }) where holdsColumns(boxes) {
		for b in boxes { walls[b.index] = nil }
	}
	let parts = cutBlocks(all, rules: ruled, walls: walls)
	var layout = ReadingLayout(
		blocks: parts.map { cellRows(of: $0.boxes, rules: ruled, walls: walls) }, breakBefore: parts.map(\.breakBefore))
	layout.rules = ruled.count
	var cells: [Walls: Int] = [:]
	for w in walls.values { cells[w, default: 0] += 1 }
	layout.enclosed = cells.values.reduce(0, +)
	layout.grouped = cells.values.filter { $0 >= 2 }.reduce(0, +)
	layout.position = Array(repeating: nil, count: parts.count)
	guard parts.contains(where: \.column) else { return layout }
	// 位置相对全部文字的范围算，不按图片边框：图边上有大片空白时，按边框算会把内容都挤进一两格。
	// 不分块、或者分块不标位置，看不了图的模型会把底部提示条当成弹窗；标了位置，它才认得出盖在「中间」的那块。
	let x0 = all.map(\.x).min()!, x1 = all.map { $0.x + $0.w }.max()!, y0 = all.map(\.y).min()!, y1 = all.map { $0.y + $0.h }.max()!
	var start = 0
	while start < parts.count {
		var end = start + 1
		while end < parts.count && !parts[end].breakBefore { end += 1 }
		let section = parts[start..<end].flatMap(\.boxes)
		let cx = ((section.map(\.x).min()! + section.map { $0.x + $0.w }.max()!) / 2 - x0) / max(x1 - x0, 1)
		let cy = ((section.map(\.y).min()! + section.map { $0.y + $0.h }.max()!) / 2 - y0) / max(y1 - y0, 1)
		layout.position[start] = placeName(cx, cy)
		start = end
	}
	return layout
}

/// 页面九宫格的叫法。
func placeName(_ cx: Double, _ cy: Double) -> String {
	let col = cx < 1.0 / 3 ? 0 : cx > 2.0 / 3 ? 2 : 1
	let row = cy < 1.0 / 3 ? 0 : cy > 2.0 / 3 ? 2 : 1
	return [
		[Texts.text("左上"), Texts.text("上方"), Texts.text("右上")],
		[Texts.text("左侧"), Texts.text("中间"), Texts.text("右侧")],
		[Texts.text("左下"), Texts.text("下方"), Texts.text("右下")],
	][row][col]
}

/// `markers`：分栏页面每段开头写不写〔中间〕这类位置标记。给只看文字的模型要写；给人看、导出不写。
public func joinLayout(_ layout: ReadingLayout, _ lines: [OCRLine], markers: Bool = true) -> String {
	var out = ""
	for (i, block) in layout.blocks.enumerated() {
		if i > 0 { out += layout.breakBefore[i] ? "\n\n" : "\n" }
		if markers, i < layout.position.count, let place = layout.position[i] { out += "〔\(place)〕\n" }
		out += joinRows(block, lines)
	}
	return out
}

struct Gap {
	var start: Double
	var end: Double
	var size: Double { end - start }
	var middle: Double { (start + end) / 2 }
}

/// 投影上的空白：把各个框在一个方向上的跨度并起来，并完剩下的缝。
func projectionGaps(_ spans: [(Double, Double)]) -> [Gap] {
	let sorted = spans.sorted { $0.0 < $1.0 }
	guard var reach = sorted.first?.1 else { return [] }
	var gaps: [Gap] = []
	for span in sorted.dropFirst() {
		if span.0 > reach { gaps.append(Gap(start: reach, end: span.0)) }
		reach = max(reach, span.1)
	}
	return gaps
}

/// 一列里上下挨着（缝不到半行高、左右有重叠）的行并成一组：表格里折成两行的格子、文章里的一段。
func stackGroups(_ boxes: [UprightBox], unit: Double) -> [(top: Double, bottom: Double)] {
	var groups: [(top: Double, bottom: Double, x0: Double, x1: Double)] = []
	for b in boxes.sorted(by: { $0.y < $1.y }) {
		if let k = groups.lastIndex(where: { b.y - $0.bottom < 0.5 * unit && b.x < $0.x1 && b.x + b.w > $0.x0 }) {
			groups[k].bottom = max(groups[k].bottom, b.y + b.h)
			groups[k].x0 = min(groups[k].x0, b.x)
			groups[k].x1 = max(groups[k].x1, b.x + b.w)
		} else {
			groups.append((b.y, b.y + b.h, b.x, b.x + b.w))
		}
	}
	return groups.map { ($0.top, $0.bottom) }
}

/// 竖缝两边紧挨着的两列是不是一行对一行（表格、「标签：值」表单）：组数少的那边，六成以上的组
/// 在另一边找得到中心差不到 0.3 行高的组。只比紧挨着的两列——拿一列去跟整个另一边比，
/// 另一边字一密，几乎每行都能碰巧对上（界面截图上，最左一排图标的文字会跟旁边侧栏的列表搅在一起）；
/// 先把折行并成组——表格里折成两行的格子，中心跟旁边居中的格子是对齐的。
func columnsAligned(_ a: [UprightBox], _ b: [UprightBox], unit: Double) -> Bool {
	let ga = stackGroups(a, unit: unit), gb = stackGroups(b, unit: unit)
	let (small, other) = ga.count <= gb.count ? (ga, gb) : (gb, ga)
	guard !small.isEmpty else { return false }
	let center = { (g: (top: Double, bottom: Double)) in (g.top + g.bottom) / 2 }
	let hits = small.filter { s in other.contains { abs(center(s) - center($0)) < 0.3 * unit } }.count
	return Double(hits) >= 0.6 * Double(small.count)
}

/// `walls`：每行四面围着它的表格线（见 `enclosure`），没被围住的不在里面。
func cutBlocks(_ boxes: [UprightBox], rules: [UprightRule] = [], walls: [Int: Walls] = [:], depth: Int = 0)
	-> [(boxes: [UprightBox], breakBefore: Bool, column: Bool)]
{
	guard boxes.count > 1, depth < 32 else { return [(boxes, false, false)] }
	let heights = boxes.map(\.h).sorted()
	let unit = max(heights[heights.count / 2], 1)
	// 上下切：空白至少 0.8 行高（段与段之间）；左右切：至少 1.5 行高（比字与字、格与格之间宽）。
	let minRowGap = 0.8 * unit, minColumnGap = 1.5 * unit
	var bestRow: Gap?
	// 画了表格线时，同一格里的行不分到两块里（见 splitsCell、cellWall）。
	for g in projectionGaps(boxes.map { ($0.y, $0.y + $0.h) }) where g.size >= minRowGap {
		if splitsCell(g, vertical: false, boxes: boxes, walls: walls) { continue }
		if bestRow == nil || g.size > bestRow!.size { bestRow = g }
	}
	var bestColumn: Gap?
	let columnGaps = projectionGaps(boxes.map { ($0.x, $0.x + $0.w) })
	for (i, g) in columnGaps.enumerated() where g.size >= minColumnGap && (bestColumn == nil || g.size > bestColumn!.size) {
		if splitsCell(g, vertical: true, boxes: boxes, walls: walls) || cellWall(in: g, rules: rules, boxes: boxes, walls: walls) { continue }
		// 紧挨着这条缝的两列：左边到上一条缝为止，右边到下一条缝为止。
		let leftEdge = i > 0 ? columnGaps[i - 1].middle : -Double.infinity
		let rightEdge = i + 1 < columnGaps.count ? columnGaps[i + 1].middle : Double.infinity
		let left = boxes.filter { $0.x + $0.w <= g.middle && $0.x >= leftEdge }
		let right = boxes.filter { $0.x >= g.middle && $0.x + $0.w <= rightEdge }
		if !columnsAligned(left, right, unit: unit) { bestColumn = g }
	}
	// 先切哪一刀：竖缝优先。两栏条目交错排着时，到处是比一行高一点的横向小空当，按缝宽挑会横着一刀刀
	// 切成小条、两栏的字交替出来（界面截图上最左一排图标的文字跟侧栏的列表就会这样）；只有隔了三行以上的
	// 横向空白（真正的分区）才排在竖缝前面。
	let best: (vertical: Bool, gap: Gap)?
	if let row = bestRow, row.size >= 3 * unit, bestColumn == nil || row.size / minRowGap >= bestColumn!.size / minColumnGap {
		best = (false, row)
	} else if let column = bestColumn {
		best = (true, column)
	} else if let row = bestRow {
		best = (false, row)
	} else {
		best = nil
	}
	guard let cut = best else { return [(boxes, false, false)] }
	let first = cut.vertical ? boxes.filter { $0.x + $0.w / 2 < cut.gap.middle } : boxes.filter { $0.cy < cut.gap.middle }
	let second = cut.vertical ? boxes.filter { $0.x + $0.w / 2 >= cut.gap.middle } : boxes.filter { $0.cy >= cut.gap.middle }
	guard !first.isEmpty, !second.isEmpty else { return [(boxes, false, false)] }
	var tail = cutBlocks(second, rules: rules, walls: walls, depth: depth + 1)
	// 不同的栏之间、隔了三行以上的段之间空一行；表格行与行、段内这种近的只换行。
	tail[0].breakBefore = cut.vertical || cut.gap.size >= 3 * unit
	tail[0].column = cut.vertical
	return cutBlocks(first, rules: rules, walls: walls, depth: depth + 1) + tail
}

/// 转正以后的一条表格线：横线在 y = at 处、x 从 start 到 end；竖线反过来。
struct UprightRule {
	var horizontal: Bool
	var at: Double
	var start: Double
	var end: Double
}

/// 线转进「字是正的」坐标系，转完再分横竖：转了 90° 横放扫描的页，图上的竖线是版面上的横线。
/// 大半截压在字中间的「线」不要：几个字的笔画连成的（「一一」）、删除线。表格线在字和字之间，顶多碰到字的边。
func uprightRules(_ rules: [RuleLine], frame: UprightFrame, boxes: [UprightBox]) -> [UprightRule] {
	rules.compactMap { r in
		let a = frame.point(r.from), b = frame.point(r.to)
		let horizontal = abs(b.x - a.x) >= abs(b.y - a.y)
		let rule = horizontal
			? UprightRule(horizontal: true, at: (a.y + b.y) / 2, start: min(a.x, b.x), end: max(a.x, b.x))
			: UprightRule(horizontal: false, at: (a.x + b.x) / 2, start: min(a.y, b.y), end: max(a.y, b.y))
		var covered = 0.0
		for box in boxes {
			let (lo, hi) = horizontal ? (box.x, box.x + box.w) : (box.y, box.y + box.h)
			let (side0, side1) = horizontal ? (box.y, box.y + box.h) : (box.x, box.x + box.w)
			let margin = 0.15 * (side1 - side0)
			guard rule.at > side0 + margin, rule.at < side1 - margin else { continue }
			covered += max(0, min(hi, rule.end) - max(lo, rule.start))
		}
		return covered > 0.5 * (rule.end - rule.start) ? nil : rule
	}
}

/// 围住一行的四条表格线（下标）。四条一样的行在同一格里。
struct Walls: Hashable {
	var top: Int
	var bottom: Int
	var left: Int
	var right: Int
}

/// 行框四周最近的线：上、下找盖得住框中心 x 的横线，左、右找盖得住框中心 y 的竖线（两头各容半个字高）。
/// 四面都有才算在一个格子里；缺一面就不算（没画线的页、表格外面的字）。
func enclosure(_ b: UprightBox, _ rules: [UprightRule], unit: Double) -> Walls? {
	let cx = b.x + b.w / 2, cy = b.cy
	var top: Int?, bottom: Int?, left: Int?, right: Int?
	for (k, r) in rules.enumerated() {
		let along = r.horizontal ? cx : cy
		guard r.start - 0.5 * unit <= along, along <= r.end + 0.5 * unit else { continue }
		let center = r.horizontal ? cy : cx
		if r.at < center {
			if r.horizontal, top.map({ rules[$0].at < r.at }) ?? true { top = k }
			if !r.horizontal, left.map({ rules[$0].at < r.at }) ?? true { left = k }
		} else if r.at > center {
			if r.horizontal, bottom.map({ rules[$0].at > r.at }) ?? true { bottom = k }
			if !r.horizontal, right.map({ rules[$0].at > r.at }) ?? true { right = k }
		}
	}
	guard let t = top, let d = bottom, let l = left, let r = right else { return nil }
	return Walls(top: t, bottom: d, left: l, right: r)
}

/// 一格里的字自己就能左右切成两栏、两边各有三行以上：那是装着版面的框（两栏文字外面套着框、证书和试卷的页框），不是表格的格子。
/// 当成格子的话框里一刀都不能切，两栏会一行行交错；放开它，照没画线时切块。
/// 少了不算：格子里的字跟旁边公章的零散字也切得开，两行标签挨着两个值的格子按留白也会被切开，那都还是一格、一行行排更好。
func holdsColumns(_ boxes: [UprightBox]) -> Bool {
	guard boxes.count >= 6 else { return false }
	var before = 0
	for part in cutBlocks(boxes) {
		if part.column && before >= 3 && boxes.count - before >= 3 { return true }
		before += part.boxes.count
	}
	return false
}

/// 这一刀会不会把同一格里的行分到两边（`vertical`：竖着切、按 x 分；不然横着切、按 y 分，跟 `cutBlocks` 分的方法一样）。
/// 同一格的行要留在一块里，才能一格一格地出：不然扫描的表格页上，内容格里公章的零散字会被当成单独一栏切出去。
func splitsCell(_ g: Gap, vertical: Bool, boxes: [UprightBox], walls: [Int: Walls]) -> Bool {
	guard !walls.isEmpty else { return false }
	var side: [Walls: Bool] = [:]
	for b in boxes {
		guard let w = walls[b.index] else { continue }
		let first = vertical ? b.x + b.w / 2 < g.middle : b.cy < g.middle
		if let s = side[w], s != first { return true }
		side[w] = first
	}
	return false
}

/// 竖缝里的一条竖线，左边有行的右墙是它、右边有行的左墙是它：缝两边是同一张表里相邻的格子，不在这里左右切开，
/// 交给 `cellRows` 按格子一排排排（格子里的行本来就各出各的，两栏文章外面套着框也是一栏一格）。
/// 扫描的表格页上，标签栏和内容栏本来一行对一行，可是内容栏里公章、签名的零散字会把对齐搅乱，按留白切成左右两块，标签全出完才出内容。
/// 没画线、或者线没把两边的字围住（两栏文章栏缝里一条竖线、外面没框），照旧按留白切。
func cellWall(in g: Gap, rules: [UprightRule], boxes: [UprightBox], walls: [Int: Walls]) -> Bool {
	guard !walls.isEmpty else { return false }
	for (k, v) in rules.enumerated() where !v.horizontal && v.at >= g.start && v.at <= g.end {
		if boxes.contains(where: { walls[$0.index]?.right == k }) && boxes.contains(where: { walls[$0.index]?.left == k }) { return true }
	}
	return false
}

/// 一个格子：四面有线围着的几行，或者没被围住的单独一行。
/// 范围：上下按围住它的两条横线（同一排的格子字有高有低，也算同一条带），左右按字（外面套着大框时，
/// 框里并排的几块字左右各占各的；比如并排的几个签名块都被最外面的框围着，按框算左右分不开、两块的字会一行行交错）。
/// 单独的行按它自己的框。
struct Cell {
	var boxes: [UprightBox]
	var x0: Double
	var x1: Double
	var y0: Double
	var y1: Double
}

/// 块里按格子排。四面同样四条线围着的行算一格；先按上下有没有缝切成一条条带，带里再按左右切成几格，一层层往里切。
/// 一条带里的格子都只有一行时还拼成一行（跟以前一样，「标签  内容」在同一行）；有格子折成几行时一格一格地出，格里从上往下，
/// 不再按高度把左右几格的第二行拼到一起（拼了的话，几格的字交错着出，哪一格都读不通）。
/// 没有围住两行以上的格子就跟以前一样一行行排：没画线的收据、正文、截图都不变。
func cellRows(of boxes: [UprightBox], rules: [UprightRule], walls: [Int: Walls]) -> [[Int]] {
	guard boxes.count > 1, !walls.isEmpty else { return rows(of: boxes) }
	var cells: [Cell] = []
	var slot: [Walls: Int] = [:]
	for b in boxes {
		guard let e = walls[b.index] else {
			cells.append(Cell(boxes: [b], x0: b.x, x1: b.x + b.w, y0: b.y, y1: b.y + b.h))
			continue
		}
		if let k = slot[e] {
			cells[k].boxes.append(b)
			cells[k].x0 = min(cells[k].x0, b.x)
			cells[k].x1 = max(cells[k].x1, b.x + b.w)
		} else {
			slot[e] = cells.count
			cells.append(Cell(boxes: [b], x0: b.x, x1: b.x + b.w, y0: rules[e.top].at, y1: rules[e.bottom].at))
		}
	}
	guard slot.values.contains(where: { cells[$0].boxes.count >= 2 }) else { return rows(of: boxes) }
	return orderCells(cells)
}

func orderCells(_ cells: [Cell]) -> [[Int]] {
	let all = cells.flatMap(\.boxes)
	guard cells.count > 1 else { return rows(of: all) }
	let bands = splitCells(cells, vertical: false)
	if bands.count > 1 { return bands.flatMap(orderCells) }
	let columns = splitCells(cells, vertical: true)
	// 两个方向都切不开（格子互相压着）：照旧一行行排。
	guard columns.count > 1 else { return rows(of: all) }
	let parts = columns.map(orderCells)
	return parts.allSatisfy { $0.count == 1 } ? rows(of: all) : parts.flatMap { $0 }
}

/// 按格子的范围切开：上下（或左右）不重叠就分开，按位置排。共用一条线的两格算分开（容 1 像素）。
func splitCells(_ cells: [Cell], vertical: Bool) -> [[Cell]] {
	let span = { (c: Cell) in vertical ? (c.x0, c.x1) : (c.y0, c.y1) }
	var groups: [(end: Double, cells: [Cell])] = []
	for c in cells.sorted(by: { span($0).0 < span($1).0 }) {
		let (lo, hi) = span(c)
		if let last = groups.last, lo < last.end - 1 {
			groups[groups.count - 1].end = max(last.end, hi)
			groups[groups.count - 1].cells.append(c)
		} else {
			groups.append((hi, [c]))
		}
	}
	return groups.map(\.cells)
}

/// 系统识别前会把整张图缩到大约这么多像素（是个估计：按缩完以后字矮到多少开始认不准反推出来的）。
public let internalPixelBudget = 2.5e6

/// 缩完以后字大约还剩多少像素高（各行高度的中位数）。没有行时返回 nil。
public func effectiveGlyphHeight(_ lines: [OCRLine], width: Int, height: Int) -> Double? {
	let boxes = uprightBoxes(lines, width: width, height: height).map(\.h).sorted()
	guard !boxes.isEmpty else { return nil }
	let factor = min(1, (internalPixelBudget / (Double(width) * Double(height))).squareRoot())
	return boxes[boxes.count / 2] * factor
}

/// 只靠代码判断「版面像有多栏或表格」：至少 3 行，且三成以上的行里并排着不止一段字。
/// 界面截图（左边栏 + 正文）也会算进来——认文档对界面截图没副作用，只是多花一点时间。
public func looksMultiColumn(_ rows: [[Int]]) -> Bool {
	guard rows.count >= 3 else { return false }
	return Double(rows.filter { $0.count >= 2 }.count) >= 0.3 * Double(rows.count)
}
