import AppKit
import CoreText
import OCRCore
import ShiziKit

/// 出截图用的照片图库：图都在这里现画，不碰真的照片图库（也不用照片权限）。
final class SamplePhotoLibrary: PhotoLibrary, @unchecked Sendable {
	struct Photo {
		let asset: PhotoAsset
		let image: CGImage
		/// 原图只在 iCloud 上：不让下载就拿不到。
		let inCloud: Bool
	}

	let state: PhotoAccess
	private(set) var photos: [Photo] = []
	private var members: [String: [String]] = [:]
	private var albumList: [PhotoAlbum] = []
	/// 取一张图前等这么久：让「识别中」拍得到。
	var delay: TimeInterval = 0

	init(access: PhotoAccess) {
		state = access
		let day = Date(timeIntervalSince1970: 1_791_000_000)
		var n = 0
		func add(_ image: CGImage, screenshot: Bool = false, inCloud: Bool = false) -> String {
			n += 1
			let id = "样例-\(n)"
			let asset = PhotoAsset(
				id: id, created: day.addingTimeInterval(Double(-3600 * n)), modified: day, pixelWidth: image.width, pixelHeight: image.height,
				isScreenshot: screenshot)
			photos.append(Photo(asset: asset, image: image, inCloud: inCloud))
			return id
		}
		let shots = [
			["王小明", "明天下午三点开会", "好的，会议室在 5 楼"], ["无线局域网", "Wi-Fi 密码：shizi2026", "自动加入"],
			["订单详情", "订单号 2026100912345", "实付 ¥128.00"], ["地铁 2 号线", "南京东路站 2 号口", "步行 450 米"],
			["备忘录", "买牛奶、鸡蛋、面包", "周五交报告"], ["日历", "10 月 12 日 星期日", "牙医复诊 14:30"],
		].enumerated().map { i, lines in add(Self.screen(lines, hue: Double(i) / 6), screenshot: true, inCloud: i == 4) }
		let receipts = [
			["增值税电子普通发票", "金额 ¥86.50"], ["停车费", "¥15.00", "2026-10-08"], ["超市购物小票", "合计 ¥236.40"], ["出租车发票", "¥42.00"],
		].map { add(Self.paper($0)) }
		let scenes = (0..<4).map { add(Self.scene(hue: 0.08 + Double($0) * 0.17), inCloud: $0 == 1) }
		let all = photos.sorted { ($0.asset.created ?? .distantPast) > ($1.asset.created ?? .distantPast) }.map(\.asset.id)
		members = ["截屏": shots, "最近项目": all, "个人收藏": [shots[1], scenes[0]], "票据": receipts]
		albumList = [
			PhotoAlbum(id: "截屏", title: "截屏", count: shots.count, kind: .screenshots),
			PhotoAlbum(id: "最近项目", title: "最近项目", count: all.count, kind: .all),
			PhotoAlbum(id: "个人收藏", title: "个人收藏", count: 2, kind: .favorites),
			PhotoAlbum(id: "票据", title: "票据", count: receipts.count, kind: .album, canAdd: true),
		]
	}

	func photo(_ id: String) -> Photo? { photos.first { $0.asset.id == id } }

	func access() -> PhotoAccess { state }
	func requestAccess(_ done: @escaping @Sendable (PhotoAccess) -> Void) { done(state) }
	func albums() -> [PhotoAlbum] {
		albumList.map { a in
			var a = a
			a.count = members[a.id]?.count ?? 0
			return a
		}
	}
	func assets(in album: String?) -> [PhotoAsset] { (members[album ?? "最近项目"] ?? []).compactMap { photo($0)?.asset } }
	func assets(ids: [String]) -> [PhotoAsset] { ids.compactMap { photo($0)?.asset } }
	func filename(for asset: PhotoAsset) -> String? { "IMG_\(asset.id.dropFirst(3)).PNG" }

	func image(
		for asset: PhotoAsset, maxPixel: Int, allowDownload: Bool, timeout: TimeInterval, progress: (@Sendable (Double) -> Void)?
	) -> PhotoImage {
		if delay > 0 { Thread.sleep(forTimeInterval: delay) }
		guard let p = photo(asset.id) else { return .failed("找不到") }
		if p.inCloud && !allowDownload { return .inCloud(nil) }
		return .image(downscaledQuickly(p.image, longSide: maxPixel))
	}

	@MainActor func add(_ assets: [PhotoAsset], to target: AlbumTarget, done: @escaping @MainActor (String?) -> Void) {
		switch target {
		case .existing(let id):
			members[id, default: []].append(contentsOf: assets.map(\.id).filter { !(members[id] ?? []).contains($0) })
		case .new(let title):
			let id = "新相簿-\(albumList.count)"
			members[id] = assets.map(\.id)
			albumList.append(PhotoAlbum(id: id, title: title, count: assets.count, kind: .album, canAdd: true))
		}
		done(nil)
	}

	func preview(for asset: PhotoAsset, pixels: Int, timeout: TimeInterval) -> PhotoImage {
		photo(asset.id).map { .image(downscaledQuickly($0.image, longSide: pixels)) } ?? .failed("找不到")
	}

	@MainActor func thumbnail(for asset: PhotoAsset, pixels: Int, done: @escaping @MainActor (CGImage?) -> Void) {
		done(photo(asset.id).map { downscaledQuickly($0.image, longSide: pixels) })
	}

	// MARK: 画图

	static func canvas(_ w: Int, _ h: Int, _ color: CGColor) -> CGContext {
		let ctx = CGContext(
			data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.setFillColor(color)
		ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
		return ctx
	}

	static func text(_ s: String, size: CGFloat, at p: CGPoint, in ctx: CGContext, color: CGColor = .black) {
		let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
		let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]
		ctx.textPosition = p
		CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), ctx)
	}

	/// 手机截屏：顶上一条色块当标题栏，下面几行字。
	static func screen(_ lines: [String], hue: Double) -> CGImage {
		let w = 390, h = 844
		let ctx = canvas(w, h, CGColor(gray: 0.97, alpha: 1))
		ctx.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor)
		ctx.fill(CGRect(x: 0, y: h - 120, width: w, height: 120))
		text(lines[0], size: 26, at: CGPoint(x: 24, y: CGFloat(h) - 90), in: ctx, color: .white)
		for (i, line) in lines.dropFirst().enumerated() {
			ctx.setFillColor(.white)
			ctx.fill(CGRect(x: 16, y: CGFloat(h) - 230 - CGFloat(i) * 96, width: CGFloat(w - 32), height: 76))
			text(line, size: 22, at: CGPoint(x: 32, y: CGFloat(h) - 198 - CGFloat(i) * 96), in: ctx)
		}
		return ctx.makeImage()!
	}

	/// 拍的小票、发票：米色的纸，几行字。
	static func paper(_ lines: [String]) -> CGImage {
		let w = 420, h = 560
		let ctx = canvas(w, h, CGColor(red: 0.45, green: 0.42, blue: 0.38, alpha: 1))
		ctx.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.9, alpha: 1))
		ctx.fill(CGRect(x: 50, y: 40, width: 320, height: 480))
		for (i, line) in lines.enumerated() {
			text(line, size: i == 0 ? 24 : 20, at: CGPoint(x: 74, y: 450 - CGFloat(i) * 56), in: ctx)
		}
		return ctx.makeImage()!
	}

	/// 风景照：天、地、一个太阳，没有字。
	static func scene(hue: Double) -> CGImage {
		let w = 600, h = 450
		let ctx = canvas(w, h, NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.95, alpha: 1).cgColor)
		ctx.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1).cgColor)
		ctx.fill(CGRect(x: 0, y: 0, width: w, height: 170))
		ctx.setFillColor(NSColor(hue: 0.12, saturation: 0.7, brightness: 1, alpha: 1).cgColor)
		ctx.fillEllipse(in: CGRect(x: 400, y: 280, width: 90, height: 90))
		return ctx.makeImage()!
	}
}
