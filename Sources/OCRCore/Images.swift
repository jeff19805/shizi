import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum OCRError: Error, CustomStringConvertible {
	case notFound(String)
	case unreadable(String)
	case badArgument(String)
	case recognition(String)

	public var description: String {
		switch self {
		case .notFound(let p): return "找不到文件：\(p)"
		case .unreadable(let p): return "读不了这个文件（不是图片或 PDF，或者文件坏了）：\(p)"
		case .badArgument(let m): return "参数不对：\(m)"
		case .recognition(let m): return "识别失败：\(m)"
		}
	}
}

public enum ImageLimits {
	/// PDF 一次最多认这么多页。
	public static let maxPages = 20
	/// PDF 按长边这么多像素渲染：A4 约 210 dpi，正文字高约 30 像素，不会一律触发横带细认。
	public static let pdfLongSide = 2500.0
}

let ciContext = CIContext()

public func expandPath(_ path: String) -> String {
	(path as NSString).expandingTildeInPath
}

/// 要认的图片或 PDF：图片只有一页；PDF 认到哪页才渲染哪页，认完就放掉。
/// 原来先把要认的页全部渲染出来再认，峰值内存跟着页数一路涨，
/// 几百页的文件扛不住。
/// 建好以后只读不改，可以交给别的线程用；但同一个对象别在两条线程上同时画 PDF（拾字给认字、给界面各开一个）。
public final class PageSource: @unchecked Sendable {
	/// 一共几页（图片是 1）。
	public let totalPages: Int
	let pdf: CGPDFDocument?
	let picture: CGImage?
	/// 出错时说是哪个文件。
	let name: String
	/// 用 PDFKit 再开一份同样的 PDF，取文字层用（用到才开，开过的留着）。
	private let openKit: (() -> PDFDocument?)?
	private var kit: PDFDocument??
	private let kitLock = NSLock()

	/// 读图片或 PDF 文件，路径可以用 ~。
	public convenience init(path rawPath: String) throws {
		let path = expandPath(rawPath)
		guard FileManager.default.fileExists(atPath: path) else { throw OCRError.notFound(path) }
		let url = URL(fileURLWithPath: path)
		// 先看文件头是不是 %PDF：拿图片去开 PDF，系统会往错误输出打一行无关的报错。
		if isPDF(path), let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages > 0 {
			self.init(pdf: pdf, name: path, openKit: { PDFDocument(url: url) })
			return
		}
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0, let image = orientedImage(src) else {
			throw OCRError.unreadable(path)
		}
		self.init(image: image, name: path)
	}

	/// 内存里的图片或 PDF 数据（界面里粘贴的、从照片图库取来的），不用先存成文件。带方向标记的照片按标记转正。
	public convenience init(data: Data, name: String = "图片数据") throws {
		if data.starts(with: Data("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
			pdf.numberOfPages > 0
		{
			self.init(pdf: pdf, name: name, openKit: { PDFDocument(data: data) })
			return
		}
		guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0, let image = orientedImage(src) else {
			throw OCRError.unreadable(name)
		}
		self.init(image: image, name: name)
	}

	/// 已经在内存里的一张图。
	public init(image: CGImage, name: String = "图片") {
		picture = image
		pdf = nil
		totalPages = 1
		self.name = name
		openKit = nil
	}

	init(pdf: CGPDFDocument, name: String, openKit: (() -> PDFDocument?)? = nil) {
		self.pdf = pdf
		picture = nil
		totalPages = pdf.numberOfPages
		self.name = name
		self.openKit = openKit
	}

	/// PDF 的第 n 页（从 1 开始）；图片是 nil。
	func pdfPage(_ n: Int) -> CGPDFPage? { pdf?.page(at: n) }

	/// PDFKit 打开的第 n 页（取文字层用）；图片、PDFKit 打不开的是 nil。
	/// 文字层页上框出一块里的字（PDFKit 按框选字，跟在阅读器里拖选一样），一行一项；不是 PDF 给 nil。
	/// PDFKit 不保证多线程安全：同一个 PageSource 的这个方法只在一个线程上调（拾字在主线程上用显示那份）。
	public func textLayerText(page n: Int, in region: NRect) -> String? {
		guard let page = kitPage(n) else { return nil }
		return textLayerLines(page, in: region).map(\.text).joined(separator: "\n")
	}

	func kitPage(_ n: Int) -> PDFPage? {
		let doc: PDFDocument? = kitLock.withLock {
			if kit == nil { kit = .some(openKit?()) }
			return kit ?? nil
		}
		return doc?.page(at: n - 1)
	}

	/// 要认的全部页码：`requested` 从 1 开始，nil 表示整份；超出范围的去掉。图片只有第 1 页。
	public func wanted(_ requested: [Int]?) -> [Int] {
		guard pdf != nil else { return [1] }
		return (requested ?? Array(1...totalPages)).filter { $0 >= 1 && $0 <= totalPages }
	}

	/// 这次认哪几页：在 `wanted` 里从头取，最多 `limit` 页（nil 不限）。一页都不剩就报错。
	public func select(_ requested: [Int]?, limit: Int?) throws -> [Int] {
		let all = wanted(requested)
		guard !all.isEmpty else { throw OCRError.badArgument("PDF 一共 \(totalPages) 页，给的页码都不在范围里") }
		return limit.map { Array(all.prefix($0)) } ?? all
	}

	/// 第 n 页（从 1 开始）的图。PDF 每次现渲染。
	public func image(page n: Int) throws -> CGImage {
		if let picture { return picture }
		guard let page = pdf?.page(at: n), let image = renderPDFPage(page, longSide: ImageLimits.pdfLongSide) else {
			throw OCRError.unreadable("\(name) 第 \(n) 页")
		}
		return image
	}

	/// 给人看的图：长边不超过 `longSide`（界面显示、缩略图用）。PDF 直接按这个大小画，比画大了再缩快。
	public func image(page n: Int, longSide: Int) throws -> CGImage {
		if let picture { return downscaledQuickly(picture, longSide: longSide) }
		guard let page = pdf?.page(at: n), let image = renderPDFPage(page, longSide: Double(longSide)) else {
			throw OCRError.unreadable("\(name) 第 \(n) 页")
		}
		return image
	}

	/// 第 n 页照 `image(page:longSide:)` 画出来有多大（像素），不真画：拾字连续滚动时先拿它排出每页占多高，图后画。
	/// 算法跟 `downscaledQuickly`、`renderPDFPage` 一样（测试里比过）；读不了的页给 0。
	public func pixelSize(page n: Int, longSide: Int) -> CGSize {
		if let picture {
			let long = max(picture.width, picture.height)
			guard long > longSide else { return CGSize(width: picture.width, height: picture.height) }
			let scale = Double(longSide) / Double(long)
			return CGSize(
				width: max(1, (Double(picture.width) * scale).rounded()), height: max(1, (Double(picture.height) * scale).rounded()))
		}
		guard let page = pdf?.page(at: n) else { return .zero }
		let box = page.getBoxRect(.cropBox)
		guard box.width > 0, box.height > 0 else { return .zero }
		let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
		let scale = Double(longSide) / Double(max(box.width, box.height))
		let w = (Double(box.width) * scale).rounded(), h = (Double(box.height) * scale).rounded()
		return rotation == 90 || rotation == 270 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
	}
}

/// 按长边缩小（不放大），用系统的插值直接画，比 Lanczos 快得多；只给人看，不拿去认字。
public func downscaledQuickly(_ image: CGImage, longSide: Int) -> CGImage {
	let long = max(image.width, image.height)
	guard long > longSide else { return image }
	let scale = Double(longSide) / Double(long)
	let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
	guard
		let ctx = CGContext(
			data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { return image }
	ctx.interpolationQuality = .high
	ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
	return ctx.makeImage() ?? image
}

func isPDF(_ path: String) -> Bool {
	guard let h = FileHandle(forReadingAtPath: path) else { return false }
	defer { try? h.close() }
	return (try? h.read(upToCount: 5)) == Data("%PDF-".utf8)
}

/// 手机照片常带「拍的时候横着拿」的方向标记，像素本身是躺着的；按标记转正，坐标才跟人看到的一致。
func orientedImage(_ src: CGImageSource) -> CGImage? {
	let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
	let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
	if orientation == 1 { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
	let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
	let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
	let opts: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceCreateThumbnailWithTransform: true,
		kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
	]
	return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

/// 按长边像素渲染一页 PDF，白底，照页面自带的旋转摆正。
func renderPDFPage(_ page: CGPDFPage, longSide: Double) -> CGImage? {
	let box = page.getBoxRect(.cropBox)
	guard box.width > 0, box.height > 0 else { return nil }
	let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
	let scale = longSide / Double(max(box.width, box.height))
	let w = Double(box.width) * scale, h = Double(box.height) * scale
	let (outW, outH) = rotation == 90 || rotation == 270 ? (h, w) : (w, h)
	guard
		let ctx = CGContext(
			data: nil, width: Int(outW.rounded()), height: Int(outH.rounded()), bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { return nil }
	ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
	ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
	// 后写的变换先作用在点上：先挪原点、再缩放、再按页面旋转（顺时针为正）摆进画布。
	switch rotation {
	case 90:
		ctx.translateBy(x: 0, y: w)
		ctx.rotate(by: -.pi / 2)
	case 180:
		ctx.translateBy(x: w, y: h)
		ctx.rotate(by: .pi)
	case 270:
		ctx.translateBy(x: h, y: 0)
		ctx.rotate(by: .pi / 2)
	default:
		break
	}
	ctx.scaleBy(x: scale, y: scale)
	ctx.translateBy(x: -box.minX, y: -box.minY)
	ctx.drawPDFPage(page)
	return ctx.makeImage()
}

/// 透明处铺白底，画成一张普通位图。
func flatten(_ ci: CIImage) -> CGImage? {
	let bg = CIImage(color: CIColor.white).cropped(to: ci.extent)
	let out = ci.composited(over: bg)
	return ciContext.createCGImage(out, from: out.extent.integral)
}

/// 正角度 = 画面上逆时针转。
public func rotate(_ image: CGImage, degrees: Double) -> CGImage? {
	flatten(CIImage(cgImage: image).transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180)))
}

/// 把 `rotate(image, degrees:)` 转出来的图上的点换算回原图（左上原点、0–1）。
struct RotationMap {
	let degrees: Double
	let width: Double
	let height: Double
	/// 转完以后的外接框（Core Image 坐标，左下原点、y 向上），跟 rotate() 实际画出来的范围一致。
	var extent: CGRect {
		CGRect(x: 0, y: 0, width: width, height: height).applying(CGAffineTransform(rotationAngle: degrees * .pi / 180)).integral
	}

	func toOriginal(_ p: NPoint) -> NPoint {
		let e = extent
		let px = Double(e.minX) + p.x * Double(e.width), py = Double(e.maxY) - p.y * Double(e.height)
		let a = -degrees * .pi / 180
		let x = px * cos(a) - py * sin(a), y = px * sin(a) + py * cos(a)
		return NPoint(x: x / width, y: (height - y) / height)
	}

	func toOriginal(_ l: OCRLine) -> OCRLine {
		var out = l
		out.quad = l.quad.map(toOriginal)
		let xs = out.quad.map(\.x), ys = out.quad.map(\.y)
		out.box = NRect(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
		out.charCenters = nil
		return out
	}
}

public func upscale(_ image: CGImage, _ factor: Double) -> CGImage? {
	guard let f = CIFilter(name: "CILanczosScaleTransform") else { return nil }
	f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
	f.setValue(factor, forKey: kCIInputScaleKey)
	f.setValue(1.0, forKey: kCIInputAspectRatioKey)
	return f.outputImage.flatMap(flatten)
}

/// 按长边限制缩小（不放大）。
public func downscaled(_ image: CGImage, longSide: Int) -> CGImage {
	let long = max(image.width, image.height)
	guard long > longSide else { return image }
	return upscale(image, Double(longSide) / Double(long)) ?? image
}

/// 按左上原点的归一化区域裁图。
public func crop(_ image: CGImage, _ region: NRect) -> CGImage? {
	let r = region.clamped()
	let rect = CGRect(
		x: (r.x * Double(image.width)).rounded(.down), y: (r.y * Double(image.height)).rounded(.down),
		width: (r.w * Double(image.width)).rounded(.up), height: (r.h * Double(image.height)).rounded(.up))
	return image.cropping(to: rect)
}

public func pngData(_ image: CGImage) -> Data? {
	let data = NSMutableData()
	guard let dst = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
		return nil
	}
	CGImageDestinationAddImage(dst, image, nil)
	return CGImageDestinationFinalize(dst) ? data as Data : nil
}

extension CGImage {
	var pixelCount: Double { Double(width) * Double(height) }
}
