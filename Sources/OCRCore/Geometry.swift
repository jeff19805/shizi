import CoreGraphics
import Foundation

/// 0–1 归一化的点，左上角为原点。
public struct NPoint: Equatable, Sendable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}

	/// 系统识别接口给的点是左下角为原点，进来时翻一次。
	public init(visionPoint p: CGPoint) {
		self.init(x: Double(p.x), y: 1 - Double(p.y))
	}

	/// 相对子区域的点换算成相对整图。
	public func mapped(into region: NRect) -> NPoint {
		NPoint(x: region.x + x * region.w, y: region.y + y * region.h)
	}

	public var array: [Double] { [round4(x), round4(y)] }
}

/// 0–1 归一化的矩形，左上角为原点（系统接口原生是左下角为原点，进出时各翻一次）。
public struct NRect: Equatable, Sendable {
	public var x: Double
	public var y: Double
	public var w: Double
	public var h: Double

	public init(x: Double, y: Double, w: Double, h: Double) {
		self.x = x
		self.y = y
		self.w = w
		self.h = h
	}

	public static let full = NRect(x: 0, y: 0, w: 1, h: 1)

	/// 系统的左下原点矩形 → 左上原点。
	public init(visionRect r: CGRect) {
		self.init(x: Double(r.minX), y: 1 - Double(r.maxY), w: Double(r.width), h: Double(r.height))
	}

	/// 左上原点 → 系统要的左下原点。
	public var visionRect: CGRect { CGRect(x: x, y: 1 - y - h, width: w, height: h) }

	public var maxX: Double { x + w }
	public var maxY: Double { y + h }
	public var area: Double { max(0, w) * max(0, h) }
	public var center: NPoint { NPoint(x: x + w / 2, y: y + h / 2) }

	public func overlapArea(_ o: NRect) -> Double {
		let ix = min(maxX, o.maxX) - max(x, o.x)
		let iy = min(maxY, o.maxY) - max(y, o.y)
		return ix > 0 && iy > 0 ? ix * iy : 0
	}

	public func union(_ o: NRect) -> NRect {
		let x0 = min(x, o.x), y0 = min(y, o.y)
		return NRect(x: x0, y: y0, w: max(maxX, o.maxX) - x0, h: max(maxY, o.maxY) - y0)
	}

	public func contains(_ p: NPoint) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }

	public func clamped() -> NRect {
		let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
		return NRect(x: x0, y: y0, w: min(max(maxX, 0), 1) - x0, h: min(max(maxY, 0), 1) - y0)
	}

	/// 相对子区域的矩形换算成相对整图。
	public func mapped(into region: NRect) -> NRect {
		NRect(x: region.x + x * region.w, y: region.y + y * region.h, w: w * region.w, h: h * region.h)
	}

	public var array: [Double] { [round4(x), round4(y), round4(w), round4(h)] }
}

func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

/// 任意多边形（系统给的轮廓）里有没有这个点：射线法。
public func polygonContains(_ poly: [NPoint], _ p: NPoint) -> Bool {
	guard poly.count >= 3 else { return false }
	var inside = false
	var j = poly.count - 1
	for i in poly.indices {
		let a = poly[i], b = poly[j]
		if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
		j = i
	}
	return inside
}

/// 凸四边形里有没有这个点（四个点按顺时针或逆时针排好都行）。
public func quadContains(_ quad: [NPoint], _ p: NPoint) -> Bool {
	guard quad.count == 4 else { return false }
	var sign = 0.0
	for i in 0..<4 {
		let a = quad[i], b = quad[(i + 1) % 4]
		let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if cross == 0 { continue }
		if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
	}
	return true
}
