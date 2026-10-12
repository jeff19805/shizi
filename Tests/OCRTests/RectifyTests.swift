import CoreGraphics
import Testing
import Vision
@testable import OCRCore

@Test func 塌掉的四边形算坏的() throws {
	guard #available(macOS 14.0, *) else { return }
	// 表格歪得厉害（比如歪 45°）时，系统找到的四边形会塌掉：左上、右上几乎重合。
	let bad = VNRectangleObservation(
		requestRevision: VNDetectRectanglesRequestRevision1, topLeft: CGPoint(x: 0.4375, y: 0.7266), topRight: CGPoint(x: 0.4444, y: 0.7227),
		bottomRight: CGPoint(x: 0.6736, y: 0.4844), bottomLeft: CGPoint(x: 0.2986, y: 0.1328))
	let good = VNRectangleObservation(
		requestRevision: VNDetectRectanglesRequestRevision1, topLeft: CGPoint(x: 0.1, y: 0.9), topRight: CGPoint(x: 0.9, y: 0.85),
		bottomRight: CGPoint(x: 0.85, y: 0.1), bottomLeft: CGPoint(x: 0.15, y: 0.15))
	#expect(!Rectify.sane(bad, width: 1146, height: 1146))
	#expect(Rectify.sane(good, width: 1000, height: 1000))
}

@Test func 歪了几度() {
	let flat = [NPoint(x: 0.1, y: 0.1), NPoint(x: 0.9, y: 0.1), NPoint(x: 0.9, y: 0.9), NPoint(x: 0.1, y: 0.9)]
	#expect(Rectify.skewDegrees(flat, width: 1000, height: 1000) < 0.01)
	let a = 10.0 * .pi / 180
	let tilted = flat.map { p in
		NPoint(x: 0.5 + (p.x - 0.5) * cos(a) - (p.y - 0.5) * sin(a), y: 0.5 + (p.x - 0.5) * sin(a) + (p.y - 0.5) * cos(a))
	}
	#expect(abs(Rectify.skewDegrees(tilted, width: 1000, height: 1000) - 10) < 0.01)
}

@Test func 字在纸里的比例() {
	let quad = [NPoint(x: 0, y: 0), NPoint(x: 0.5, y: 0), NPoint(x: 0.5, y: 1), NPoint(x: 0, y: 1)]
	let lines = [Fixtures.line("左", x: 0.1, y: 0.1, w: 0.1, h: 0.05), Fixtures.line("右", x: 0.7, y: 0.1, w: 0.1, h: 0.05)]
	#expect(Rectify.fractionInside(quad, lines) == 0.5)
}

@Test func 贴着图边的四边形不算一张纸() {
	// 复印机扫的 A4 上找到的梯形：上边贴着图片上框。
	let scan = [NPoint(x: 0.0347, y: 0.0039), NPoint(x: 1, y: 0.0039), NPoint(x: 0.8542, y: 0.7109), NPoint(x: 0.0694, y: 0.7031)]
	let photo = [NPoint(x: 0.2569, y: 0.4063), NPoint(x: 0.7361, y: 0.4063), NPoint(x: 0.8056, y: 0.6211), NPoint(x: 0.2014, y: 0.6211)]
	#expect(Rectify.touchesBorder(scan))
	#expect(!Rectify.touchesBorder(photo))
}
