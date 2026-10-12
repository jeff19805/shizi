import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 找到纸（或最大的矩形，比如表格外框）并拉正。
public struct Rectified {
	public var image: CGImage
	/// "document"：系统找纸边找到的；"rectangle"：找纸边给的形状坏了，换矩形检测找到的。
	public var kind: String
	/// 找到的四个角（左上原点、相对原图），顺序是左上、右上、右下、左下。
	public var quad: [NPoint]
}

public enum Rectify {
	/// 找纸边偶尔给出塌掉的四边形（两个角几乎重合，歪得厉害的表格上会碰到，拉出来只剩一根细条）：
	/// 最短边不到最长边两成就算坏的。
	static func sane(_ q: VNRectangleObservation, width: Int, height: Int) -> Bool {
		let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
		let sides = (0..<4).map { i in hypot(pts[i].x - pts[(i + 1) % 4].x, pts[i].y - pts[(i + 1) % 4].y) }
		return sides.min()! > 0.2 * sides.max()!
	}

	/// 找四边形：先用找纸边，形状坏了再用矩形检测。都没有就 nil。
	public static func findQuad(_ image: CGImage) -> (observation: VNRectangleObservation, kind: String)? {
		let seg = VNDetectDocumentSegmentationRequest()
		let rect = VNDetectRectanglesRequest()
		rect.maximumObservations = 1
		rect.minimumSize = 0.2
		rect.minimumAspectRatio = 0.1
		rect.quadratureTolerance = 45
		try? VNImageRequestHandler(cgImage: image, options: [:]).perform([seg, rect])
		if let q = seg.results?.first, sane(q, width: image.width, height: image.height) { return (q, "document") }
		if let q = rect.results?.first, sane(q, width: image.width, height: image.height) { return (q, "rectangle") }
		return nil
	}

	public static func apply(_ image: CGImage, _ q: VNRectangleObservation, kind: String) -> Rectified? {
		let W = CGFloat(image.width), H = CGFloat(image.height)
		guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
		f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
		// 透视纠正用的是图像像素坐标（左下原点），跟识别接口的归一化坐标同向，直接乘宽高。
		f.setValue(CIVector(x: q.topLeft.x * W, y: q.topLeft.y * H), forKey: "inputTopLeft")
		f.setValue(CIVector(x: q.topRight.x * W, y: q.topRight.y * H), forKey: "inputTopRight")
		f.setValue(CIVector(x: q.bottomRight.x * W, y: q.bottomRight.y * H), forKey: "inputBottomRight")
		f.setValue(CIVector(x: q.bottomLeft.x * W, y: q.bottomLeft.y * H), forKey: "inputBottomLeft")
		guard let out = f.outputImage, let fixed = flatten(out), fixed.width > 8, fixed.height > 8 else { return nil }
		return Rectified(image: fixed, kind: kind, quad: corners(q))
	}

	static func corners(_ q: VNRectangleObservation) -> [NPoint] {
		[q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map { NPoint(visionPoint: $0) }
	}

	/// 四边形的边离水平 / 竖直最多偏了几度（像素空间）。拉正只在明显歪了或有透视时才有意义。
	public static func skewDegrees(_ quad: [NPoint], width: Int, height: Int) -> Double {
		let W = Double(width), H = Double(height)
		var worst = 0.0
		for i in 0..<4 {
			let a = quad[i], b = quad[(i + 1) % 4]
			let ang = abs(atan2((b.y - a.y) * H, (b.x - a.x) * W) * 180 / .pi).truncatingRemainder(dividingBy: 90)
			worst = max(worst, min(ang, 90 - ang))
		}
		return worst
	}

	/// 有两个角贴着图片边框：不是「放在背景上的一张纸」，多半是平放扫描时把表格或正文块当成了纸
	/// （复印机扫的 A4 上常找到贴着上边框的梯形，拉正等于把表格拉变形、把下面一大截裁掉）。
	public static func touchesBorder(_ quad: [NPoint]) -> Bool {
		quad.filter { $0.x < 0.015 || $0.x > 0.985 || $0.y < 0.015 || $0.y > 0.985 }.count >= 2
	}

	/// 已认出的行里，中心落在四边形里的比例。拉正会裁掉四边形以外的东西，大部分字都在里面才敢拉。
	public static func fractionInside(_ quad: [NPoint], _ lines: [OCRLine]) -> Double {
		guard !lines.isEmpty else { return 0 }
		return Double(lines.filter { quadContains(quad, $0.box.center) }.count) / Double(lines.count)
	}
}
