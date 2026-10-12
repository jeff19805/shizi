import CoreGraphics
import CoreText
import Foundation
@testable import OCRCore

/// 测试用图都在这里现画，不存图片文件。
enum Fixtures {
	static func canvas(_ width: Int, _ height: Int) -> CGContext {
		let ctx = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		return ctx
	}

	static func ctLine(_ s: String, size: CGFloat) -> CTLine {
		let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
		let attrs: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font,
			NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
		]
		return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
	}

	/// 横排若干行。`left`、`top` 是第一行左上角离图左上角的像素。
	static func draw(_ lines: [String], size: CGFloat, in ctx: CGContext, left: CGFloat, top: CGFloat) {
		for (i, s) in lines.enumerated() {
			ctx.textPosition = CGPoint(x: left, y: CGFloat(ctx.height) - top - size * 1.6 * CGFloat(i) - size)
			CTLineDraw(ctLine(s, size: size), ctx)
		}
	}

	static func text(_ lines: [String], size: CGFloat = 28, width: Int = 900, height: Int = 220, left: CGFloat = 30, top: CGFloat = 30) -> CGImage {
		let ctx = canvas(width, height)
		draw(lines, size: size, in: ctx, left: left, top: top)
		return ctx.makeImage()!
	}

	/// 竖排：每列从上往下一个字一个字摆正，列从右往左。
	static func vertical(_ columns: [String], size: CGFloat = 48) -> CGImage {
		let rows = columns.map(\.count).max() ?? 0
		let width = Int(size * 1.9 * CGFloat(columns.count) + size * 2), height = Int(size * 1.2 * CGFloat(rows) + size * 2)
		let ctx = canvas(width, height)
		for (c, col) in columns.enumerated() {
			let x = CGFloat(width) - size * 1.5 - size * 1.9 * CGFloat(c)
			for (r, ch) in col.enumerated() {
				ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - size - size * 1.2 * CGFloat(r) - size)
				CTLineDraw(ctLine(String(ch), size: size), ctx)
			}
		}
		return ctx.makeImage()!
	}

	static func pdf(_ lines: [String], size: CGFloat = 20) -> URL {
		pdf(pages: [lines], size: size)
	}

	/// 多页 PDF，每页若干行。
	static func pdf(pages: [[String]], size: CGFloat = 20) -> URL {
		let url = tempURL("pdf")
		var box = CGRect(x: 0, y: 0, width: 595, height: 842)
		let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
		for lines in pages {
			ctx.beginPDFPage(nil)
			ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
			for (i, s) in lines.enumerated() {
				ctx.textPosition = CGPoint(x: 50, y: 780 - size * 1.8 * CGFloat(i))
				CTLineDraw(ctLine(s, size: size), ctx)
			}
			ctx.endPDFPage()
		}
		ctx.closePDF()
		return url
	}

	/// 拍歪的纸：深灰底上一张转了 `degrees` 度的白纸，纸上几行字。
	static func tiltedPaper(_ lines: [String], degrees: CGFloat = 8) -> CGImage {
		let ctx = canvas(1400, 1000)
		ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
		ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 1000))
		ctx.translateBy(x: 700, y: 500)
		ctx.rotate(by: degrees * .pi / 180)
		ctx.setFillColor(CGColor(gray: 1, alpha: 1))
		ctx.fill(CGRect(x: -450, y: -320, width: 900, height: 640))
		ctx.setFillColor(CGColor(gray: 0, alpha: 1))
		for (i, s) in lines.enumerated() {
			ctx.textPosition = CGPoint(x: -400, y: 220 - CGFloat(i) * 70)
			CTLineDraw(ctLine(s, size: 34), ctx)
		}
		return ctx.makeImage()!
	}

	static func tempURL(_ ext: String) -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("shizi-test-\(UUID().uuidString).\(ext)")
	}

	static func save(_ image: CGImage) -> String {
		let url = tempURL("png")
		try! pngData(image)!.write(to: url)
		return url.path
	}

	static func compact(_ s: String) -> String { s.filter { !$0.isWhitespace } }

	/// 造一行假结果：按「字是正的」那个坐标系给出四角，再整体绕图中心转 `degrees`（画面上顺时针为正）。
	static func line(_ text: String, x: Double, y: Double, w: Double, h: Double, degrees: Double = 0, conf: Double = 1) -> OCRLine {
		let corners = [NPoint(x: x, y: y), NPoint(x: x + w, y: y), NPoint(x: x + w, y: y + h), NPoint(x: x, y: y + h)]
		let a = degrees * .pi / 180
		let quad = corners.map { p -> NPoint in
			let dx = p.x - 0.5, dy = p.y - 0.5
			return NPoint(x: 0.5 + dx * cos(a) - dy * sin(a), y: 0.5 + dx * sin(a) + dy * cos(a))
		}
		let xs = quad.map(\.x), ys = quad.map(\.y)
		let box = NRect(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
		return OCRLine(text: text, confidence: conf, box: box, quad: quad)
	}
}
