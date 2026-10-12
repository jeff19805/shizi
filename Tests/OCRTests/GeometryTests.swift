import CoreGraphics
import Testing
@testable import OCRCore

@Test func 系统坐标进出各翻一次() {
	let r = NRect(visionRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
	#expect(abs(r.y - 0.4) < 1e-9)
	#expect(r.visionRect.minY.isApprox(0.2))
	#expect(abs(NPoint(visionPoint: CGPoint(x: 0.25, y: 0.9)).y - 0.1) < 1e-9)
}

@Test func 区域内坐标换算回整图() {
	let region = NRect(x: 0.5, y: 0.25, w: 0.5, h: 0.5)
	let r = NRect(x: 0.2, y: 0.4, w: 0.2, h: 0.2).mapped(into: region)
	#expect(abs(r.x - 0.6) < 1e-9 && abs(r.y - 0.45) < 1e-9 && abs(r.w - 0.1) < 1e-9 && abs(r.h - 0.1) < 1e-9)
}

@Test func 点在不在四边形里() {
	let q = [NPoint(x: 0.1, y: 0.1), NPoint(x: 0.9, y: 0.2), NPoint(x: 0.8, y: 0.9), NPoint(x: 0.2, y: 0.8)]
	#expect(quadContains(q, NPoint(x: 0.5, y: 0.5)))
	#expect(!quadContains(q, NPoint(x: 0.05, y: 0.5)))
}

@Test func 四个方向都按字的走向排顺序() {
	for degrees in [0.0, 90, 180, 270, 30] {
		let lines = (0..<3).map { Fixtures.line("第\($0)行文字内容", x: 0.2, y: 0.3 + 0.12 * Double($0), w: 0.6, h: 0.06, degrees: degrees) }
		let shuffled = [lines[2], lines[0], lines[1]]
		let rows = readingRows(shuffled, width: 1000, height: 1000)
		#expect(rows.map { shuffled[$0[0]].text } == ["第0行文字内容", "第1行文字内容", "第2行文字内容"], "转 \(degrees)° 时顺序不对")
	}
}

@Test func 整体走向听长句的() {
	var lines = (0..<5).map { Fixtures.line("名称", x: 0.1 + 0.15 * Double($0), y: 0.1, w: 0.05, h: 0.03) }
	lines.append(Fixtures.line("这是一句很长很长的句子用来定方向", x: 0.1, y: 0.5, w: 0.8, h: 0.04, degrees: 30))
	let deg = dominantAngle(lines, width: 1000, height: 1000) * 180 / .pi
	#expect(abs(deg - 30) < 1, "得到 \(deg)°")
}

@Test func 字高按系统缩图折算() {
	let lines = [Fixtures.line("一行", x: 0.1, y: 0.1, w: 0.2, h: 0.01)]
	// 3000×2000 = 600 万像素，系统约缩到 250 万：20 像素高的行折算后约 12.9。
	let g = effectiveGlyphHeight(lines, width: 3000, height: 2000)!
	#expect(abs(g - 20 * (2.5 / 6).squareRoot()) < 0.2)
}

@Test func 多栏判断() {
	#expect(looksMultiColumn([[0, 1], [2, 3], [4]]))
	#expect(!looksMultiColumn([[0], [1], [2], [3, 4]]))
	#expect(!looksMultiColumn([[0, 1], [2, 3]]))
}

extension CGFloat {
	func isApprox(_ v: Double) -> Bool { abs(Double(self) - v) < 1e-9 }
}
