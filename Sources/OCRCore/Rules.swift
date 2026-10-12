import CoreGraphics
import Foundation

// 表格线：阅读顺序靠它分格子。
//
// 光看行框分不清「一格里折成三行」和「三排各一行」：扫描的表格上，一格里折成三行的长名称，跟旁边同样折成三行的标签
// 一行对一行，几何上跟三排单行的格子一模一样。并成一格，收据、紧排的键值表就被出成一整列一整列；
// 不并，这种表格就照旧把左右几格的第二行拼成一行。人是看纸上的线分的，所以这里找线，四面都有线围着的行才算在同一格里。

/// 图上画的一条直线（表格线、填空的下划线）：两个端点，0–1、左上原点。
public struct RuleLine: Equatable, Sendable {
	public var from: NPoint
	public var to: NPoint

	public init(from: NPoint, to: NPoint) {
		self.from = from
		self.to = to
	}
}

/// 找线前图的长边最多这么多像素（再大先缩小）：表格线 1–3 像素粗，缩到这么大还在，省时间也省内存。
let ruleLongSide = 3000

/// 找图上横、竖的长直线。`unit`：这张图上一行字有多高（像素，各行高度的中位数），门槛都按它算。
/// `sideways`：字是竖着走的（整页转了 90° 左右），图上的横线是版面上的竖线，长短门槛跟着对调。
///
/// 墨：红、绿、蓝三个通道都比背景（亮度直方图的峰）暗 60 以上，只要黑线：红色公章、蓝色签字的笔画不算。
/// 逐行找墨的连续段（容 2 像素的断口），上下 3 行以内、左右接得上的段连成一条：扫描件多少有点歪，一条直线在像素上是一级级的台阶。
/// 留下够长又不厚的：版面上的横线至少 4 个字高、宽的 5%（字的横笔画容易连成线，门槛严些）；竖线至少 2.5 个字高、高的 3%
/// （表格里只有一格高的竖线也要找到，这种线常常不到 4 个字高）；平均厚度不过 0.4 个字高（填色块、粗字不算）。
/// 横竖要按版面分，不能按图分：转了 90° 的页，一格高的短竖线在图上是横的，按图上横线的门槛会被丢掉，格子围不起来。
/// 字的笔画偶尔也会连成够长的「线」，调用方按行框再筛一遍（见 `uprightRules`）。
/// 找一整页很快（发布版），比识别一遍快得多。
func findRules(_ image: CGImage, unit: Double, sideways: Bool = false) -> [RuleLine] {
	let source = max(image.width, image.height) > ruleLongSide ? downscaledQuickly(image, longSide: ruleLongSide) : image
	let w = source.width, h = source.height
	guard w > 0, h > 0, unit > 0,
		let ctx = CGContext(
			data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { return [] }
	// 透明的地方当白纸（截图常带透明边）：不先铺白，透明像素读出来是黑的。
	ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
	ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
	ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
	guard let raw = ctx.data else { return [] }
	let data = raw.assumingMemoryBound(to: UInt8.self)
	let rowBytes = ctx.bytesPerRow

	var histogram = [Int](repeating: 0, count: 256)
	for y in 0..<h {
		let row = data + y * rowBytes
		for x in 0..<w {
			let p = row + 4 * x
			histogram[(Int(p[0]) * 299 + Int(p[1]) * 587 + Int(p[2]) * 114) / 1000] += 1
		}
	}
	let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
	let limit = UInt8(clamping: background - 60)
	guard limit > 0 else { return [] }
	var ink = [Bool](repeating: false, count: w * h)
	for y in 0..<h {
		let row = data + y * rowBytes
		for x in 0..<w {
			let p = row + 4 * x
			ink[y * w + x] = p[0] < limit && p[1] < limit && p[2] < limit
		}
	}

	let u = unit * Double(w) / Double(image.width)
	let strict = { (length: Int) in max(4 * u, 0.05 * Double(length)) }, loose = { (length: Int) in max(2.5 * u, 0.03 * Double(length)) }
	let across = runs(ink, width: w, height: h, horizontal: true, minLength: sideways ? loose(w) : strict(w), maxThickness: 0.4 * u)
	let down = runs(ink, width: w, height: h, horizontal: false, minLength: sideways ? strict(h) : loose(h), maxThickness: 0.4 * u)
	let W = Double(w), H = Double(h)
	return across.map { RuleLine(from: NPoint(x: $0.start / W, y: $0.startAt / H), to: NPoint(x: $0.end / W, y: $0.endAt / H)) }
		+ down.map { RuleLine(from: NPoint(x: $0.startAt / W, y: $0.start / H), to: NPoint(x: $0.endAt / W, y: $0.end / H)) }
}

/// 一个方向上的长线：沿线方向从 start 到 end，两头各在垂直方向的哪个位置（歪的线两头不一样高）。
private struct Run {
	var start: Double
	var end: Double
	var startAt: Double
	var endAt: Double
}

private func runs(_ ink: [Bool], width w: Int, height h: Int, horizontal: Bool, minLength: Double, maxThickness: Double) -> [Run] {
	// 沿线方向叫「段内」（i），垂直方向叫「第几行」（o）；横线按行扫，竖线按列扫。
	let (outer, inner) = horizontal ? (h, w) : (w, h)
	var pieces: [(o: Int, s: Int, e: Int, n: Int)] = []
	var rowStart = [Int](repeating: 0, count: outer + 1)
	ink.withUnsafeBufferPointer { m in
		for o in 0..<outer {
			rowStart[o] = pieces.count
			var i = 0
			while i < inner {
				if !(horizontal ? m[o * w + i] : m[i * w + o]) {
					i += 1
					continue
				}
				let s = i
				var last = i, n = 0
				while i < inner {
					if horizontal ? m[o * w + i] : m[i * w + o] {
						last = i
						n += 1
					} else if i - last > 2 {
						break
					}
					i += 1
				}
				if last - s + 1 >= 12 { pieces.append((o, s, last, n)) }
			}
		}
	}
	rowStart[outer] = pieces.count
	// 上下 3 行以内、左右相接（缝不过 3 像素）的段连成一条。
	var parent = Array(pieces.indices)
	func find(_ x: Int) -> Int {
		var x = x
		while parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	for (k, p) in pieces.enumerated() {
		for o in max(0, p.o - 3)..<p.o {
			for q in rowStart[o]..<rowStart[o + 1] where pieces[q].s <= p.e + 3 && pieces[q].e >= p.s - 3 {
				parent[find(k)] = find(q)
			}
		}
	}
	var lines: [Int: (s: Int, sAt: Int, e: Int, eAt: Int, n: Int)] = [:]
	for (k, p) in pieces.enumerated() {
		let r = find(k)
		guard var l = lines[r] else {
			lines[r] = (p.s, p.o, p.e, p.o, p.n)
			continue
		}
		if p.s < l.s { (l.s, l.sAt) = (p.s, p.o) }
		if p.e > l.e { (l.e, l.eAt) = (p.e, p.o) }
		l.n += p.n
		lines[r] = l
	}
	return lines.values
		.filter { Double($0.e - $0.s + 1) >= minLength && Double($0.n) / Double($0.e - $0.s + 1) <= maxThickness }
		.sorted { ($0.sAt, $0.s) < ($1.sAt, $1.s) }
		.map { Run(start: Double($0.s), end: Double($0.e + 1), startAt: Double($0.sAt) + 0.5, endAt: Double($0.eAt) + 0.5) }
}
