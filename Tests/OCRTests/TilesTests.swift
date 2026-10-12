import Foundation
import Testing
@testable import OCRCore

@Test func 切块铺满整图且相邻块有足够重叠() {
	let g = Tiles.grid(width: 3000, height: 2000)
	#expect(g.cols == 3 && g.rows == 2)
	#expect(g.tiles.first!.rect.x == 0 && g.tiles.last!.rect.maxX == 1 && g.tiles.last!.rect.maxY == 1)
	let a = g.tiles[0].rect, b = g.tiles[1].rect
	#expect((a.maxX - b.x) * 3000 >= Tiles.minOverlapPixels)
	let below = g.tiles[3].rect
	#expect((a.maxY - below.y) * 2000 >= Tiles.minOverlapPixels)
}

/// 3000×2000 切 3×2：第 0 块右边到 0.3533，第 1 块左边从 0.3133 开始，接缝中线 0.3333。
func piece(_ text: String, firstCenter: Double, step: Double = 0.01, y: Double = 0.2) -> OCRLine {
	var l = Fixtures.line(text, x: firstCenter - step / 2, y: y, w: step * Double(text.count), h: 0.01)
	l.charCenters = (0..<text.count).map { firstCenter + step * Double($0) }
	return l
}

@Test func 接缝处切开的长行拼回去() {
	let g = Tiles.grid(width: 3000, height: 2000)
	// 原句「我们今天去公园散步吧好」逐字间隔 0.01：左块认到「…散步」，右块从「去」认起。
	var left = piece("我们今天去公园散步", firstCenter: 0.275)
	left.box.w = 0.3533 - left.box.x
	let right = piece("去公园散步吧好", firstCenter: 0.315)
	var perTile = Array(repeating: [OCRLine](), count: g.tiles.count)
	perTile[0] = [left]
	perTile[1] = [right]
	let merged = Tiles.merge(perTile, tiles: g.tiles, rows: g.rows, cols: g.cols, width: 3000, height: 2000)
	#expect(merged.map(\.text) == ["我们今天去公园散步吧好"])
}

@Test func 接口处多出来的空格去掉() {
	let g = Tiles.grid(width: 3000, height: 2000)
	var left = piece("编号2026年", firstCenter: 0.275)
	left.text = "编号202 "
	left.charCenters = [0.275, 0.285, 0.295, 0.305, 0.315, 0.33]
	left.box.w = 0.3533 - left.box.x
	var right = piece(" 6年都对", firstCenter: 0.32)
	right.charCenters = [0.336, 0.34, 0.35, 0.36, 0.37]
	var perTile = Array(repeating: [OCRLine](), count: g.tiles.count)
	perTile[0] = [left]
	perTile[1] = [right]
	let merged = Tiles.merge(perTile, tiles: g.tiles, rows: g.rows, cols: g.cols, width: 3000, height: 2000)
	#expect(merged.map(\.text) == ["编号2026年都对"])
}

@Test func 被上下接缝切到的行丢掉() {
	let g = Tiles.grid(width: 3000, height: 2000)
	let bottomOfFirstRow = g.tiles[0].rect.maxY
	let cut = Fixtures.line("被切到的行", x: 0.05, y: bottomOfFirstRow - 0.004, w: 0.1, h: 0.004)
	let whole = Fixtures.line("完整的行", x: 0.05, y: 0.2, w: 0.1, h: 0.01)
	var perTile = Array(repeating: [OCRLine](), count: g.tiles.count)
	perTile[0] = [cut, whole]
	let merged = Tiles.merge(perTile, tiles: g.tiles, rows: g.rows, cols: g.cols, width: 3000, height: 2000)
	#expect(merged.map(\.text) == ["完整的行"])
}

@Test func 重叠区认两遍只留一份() {
	let a = Fixtures.line("重复的一行", x: 0.32, y: 0.3, w: 0.02, h: 0.01, conf: 0.5)
	let b = Fixtures.line("重复的一行", x: 0.3201, y: 0.3, w: 0.02, h: 0.01, conf: 1)
	let kept = dedupe([a, b])
	#expect(kept.count == 1 && kept[0].confidence == 1)
}

@Test func 整图那一遍里切块没覆盖到的大字补回来() {
	let big = Fixtures.line("大标题", x: 0.1, y: 0.05, w: 0.5, h: 0.1)
	let small = Fixtures.line("小字", x: 0.1, y: 0.5, w: 0.05, h: 0.01)
	let garbled = Fixtures.line("小子", x: 0.1, y: 0.5, w: 0.05, h: 0.01)
	let out = Tiles.mergeWithFullPass(tiles: [small], full: [big, garbled])
	#expect(out.map(\.text) == ["小字", "大标题"])
}

@Test func 转正后的坐标能换算回原图() {
	let map = RotationMap(degrees: 10, width: 300, height: 200)
	let e = map.extent
	for p in [NPoint(x: 0.1, y: 0.2), NPoint(x: 0.9, y: 0.75), NPoint(x: 0.5, y: 0.5)] {
		// 原图上的点先按 rotate() 的做法转过去，再换算回来，应该回到原处。
		let x = p.x * 300, y = 200 - p.y * 200
		let a = 10.0 * .pi / 180
		let rx = x * cos(a) - y * sin(a), ry = x * sin(a) + y * cos(a)
		let inRotated = NPoint(x: (rx - Double(e.minX)) / Double(e.width), y: (Double(e.maxY) - ry) / Double(e.height))
		let back = map.toOriginal(inRotated)
		#expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
	}
}
