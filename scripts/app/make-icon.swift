// 画拾字的图标（先当占位，等定）：浅色圆角方底，正中一个「拾」，四角取景框。
// 用法：swift scripts/app/make-icon.swift <输出的 .iconset 文件夹>，再用 iconutil 打成 .icns（build-app.sh 里做）。
// 图标用代码画，仓库里不放图片文件。
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> CGImage {
	let s = CGFloat(size)
	let ctx = CGContext(
		data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	ctx.scaleBy(x: s / 1024, y: s / 1024)
	// 照 macOS 图标的格子：主体 824×824 居中，圆角 185，带一点投影。
	let body = CGRect(x: 100, y: 100, width: 824, height: 824)
	let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
	ctx.addPath(shape)
	ctx.setFillColor(CGColor(gray: 1, alpha: 1))
	ctx.fillPath()
	ctx.restoreGState()
	ctx.saveGState()
	ctx.addPath(shape)
	ctx.clip()
	let gradient = CGGradient(
		colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1)] as CFArray,
		locations: [0, 1])!
	ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
	ctx.restoreGState()
	ctx.addPath(shape)
	ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
	ctx.setLineWidth(3)
	ctx.strokePath()

	// 四角取景框（系统蓝）。
	ctx.setStrokeColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))
	ctx.setLineWidth(34)
	ctx.setLineCap(.round)
	ctx.setLineJoin(.round)
	let frame = CGRect(x: 262, y: 262, width: 500, height: 500), arm: CGFloat = 112
	for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0), (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
		ctx.move(to: CGPoint(x: x, y: y + dy * arm))
		ctx.addLine(to: CGPoint(x: x, y: y))
		ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
	}
	ctx.strokePath()

	// 正中的「拾」。
	let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 330, nil)
	let attrs: [NSAttributedString.Key: Any] = [
		NSAttributedString.Key(kCTFontAttributeName as String): font,
		NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
	]
	let line = CTLineCreateWithAttributedString(NSAttributedString(string: "拾", attributes: attrs))
	let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
	ctx.textPosition = CGPoint(x: 512 - bounds.midX, y: 512 - bounds.midY)
	CTLineDraw(line, ctx)
	return ctx.makeImage()!
}

// iconset 要的几种尺寸：16、32、128、256、512，各有 @2x。
for base in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
		let rep = NSBitmapImageRep(cgImage: draw(base * scale))
		try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
	}
}
