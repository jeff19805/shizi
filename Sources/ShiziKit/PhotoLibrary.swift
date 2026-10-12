import AppKit
import OCRCore
import Photos

/// 照片图库里的一张照片（只记认字要用的几样，原片不复制）。
public struct PhotoAsset: Identifiable, Hashable, Sendable {
	/// 照片图库给的编号（localIdentifier）。
	public let id: String
	public var created: Date?
	public var modified: Date?
	public var pixelWidth: Int
	public var pixelHeight: Int
	public var isScreenshot: Bool

	public init(id: String, created: Date? = nil, modified: Date? = nil, pixelWidth: Int, pixelHeight: Int, isScreenshot: Bool = false) {
		self.id = id
		self.created = created
		self.modified = modified
		self.pixelWidth = pixelWidth
		self.pixelHeight = pixelHeight
		self.isScreenshot = isScreenshot
	}

	public var stamp: String { PhotoIndex.stamp(modified: modified, width: pixelWidth, height: pixelHeight) }
}

public struct PhotoAlbum: Identifiable, Hashable, Sendable {
	/// 系统的几个智能相簿，和其余的相簿。
	public enum Kind: Sendable {
		case screenshots, all, favorites, album
	}

	public let id: String
	public var title: String
	/// 里面有几张照片（不算视频）。
	public var count: Int
	public var kind: Kind
	/// 能往里加照片：自己建的普通相簿才能加，智能相簿、共享相簿不能。
	public var canAdd: Bool

	public init(id: String, title: String, count: Int, kind: Kind, canAdd: Bool = false) {
		self.id = id
		self.title = title
		self.count = count
		self.kind = kind
		self.canAdd = canAdd
	}
}

public enum PhotoAccess: Sendable {
	case granted, denied, notDetermined
}

/// 照片加进哪个相簿：已有的（自己建的普通相簿），或者新建一个（给名字）。
public enum AlbumTarget: Hashable, Sendable {
	case existing(String)
	case new(String)
}

/// 取一张照片的图的结果。
public enum PhotoImage {
	case image(CGImage)
	/// 原图只在 iCloud 上，没拿到：没让下载时原因是 nil；让了、没下下来时是系统给的原因。
	case inCloud(String?)
	/// 等太久没取到（多半是从 iCloud 下载太慢）。
	case timedOut
	case failed(String)
}

/// 照片图库：真的用 PhotoKit，测试用假的。
public protocol PhotoLibrary: AnyObject, Sendable {
	func access() -> PhotoAccess
	func requestAccess(_ done: @escaping @Sendable (PhotoAccess) -> Void)
	func albums() -> [PhotoAlbum]
	/// 相簿里的照片，新拍的在前；`album` 为 nil 是图库里全部照片。
	func assets(in album: String?) -> [PhotoAsset]
	/// 在调用的线程上等着取图（别在主线程调）：长边不超过 `maxPixel`；原图只在 iCloud 上时，`allowDownload` 决定下不下，
	/// 下载时 `progress` 报进度（0–1，在别的线程上报）。
	func image(
		for asset: PhotoAsset, maxPixel: Int, allowDownload: Bool, timeout: TimeInterval, progress: (@Sendable (Double) -> Void)?
	) -> PhotoImage
	/// 原片的文件名（IMG_1234.HEIC 这种）。
	func filename(for asset: PhotoAsset) -> String?
	/// 按编号找照片（搜出来的要显示缩略图），照片图库里已经删了的不给。
	func assets(ids: [String]) -> [PhotoAsset]
	/// 网格里的缩略图，长边约 `pixels`、不下载：原图只在 iCloud 上的，本机也留着几百像素的缩略图，取得很快。
	/// 在主线程上调、在主线程上回调；没有就给 nil。
	@MainActor func thumbnail(for asset: PhotoAsset, pixels: Int, done: @escaping @MainActor (CGImage?) -> Void)
	/// 按画面分类用的小图：长边约 `pixels`、不下载（原图只在 iCloud 上的，本机也留着几百像素的预览图）。
	/// 在调用的线程上等着取（别在主线程调）；本机一张都没有时给 `.inCloud`。
	func preview(for asset: PhotoAsset, pixels: Int, timeout: TimeInterval) -> PhotoImage
	/// 把几张照片加进相簿：不复制照片，相簿里只是多了指向它们的一项。做完在主线程上回调：成了给 nil，没成给一句话。
	@MainActor func add(_ assets: [PhotoAsset], to target: AlbumTarget, done: @escaping @MainActor (String?) -> Void)
}

extension PhotoLibrary {
	func image(for asset: PhotoAsset, maxPixel: Int, allowDownload: Bool, timeout: TimeInterval) -> PhotoImage {
		image(for: asset, maxPixel: maxPixel, allowDownload: allowDownload, timeout: timeout, progress: nil)
	}
}

/// 真的照片图库（PhotoKit）。
public final class SystemPhotoLibrary: PhotoLibrary, @unchecked Sendable {
	public static let shared = SystemPhotoLibrary()

	/// 列过的照片按编号留着，取缩略图、取图时不用再按编号查一遍。
	private let lock = NSLock()
	private var known: [String: PHAsset] = [:]

	public init() {}

	func phAsset(_ id: String) -> PHAsset? {
		if let a = lock.withLock({ known[id] }) { return a }
		let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
		if let a { lock.withLock { known[id] = a } }
		return a
	}

	func photoAsset(_ a: PHAsset) -> PhotoAsset {
		PhotoAsset(
			id: a.localIdentifier, created: a.creationDate, modified: a.modificationDate, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight,
			isScreenshot: a.mediaSubtypes.contains(.photoScreenshot))
	}

	public func access() -> PhotoAccess {
		switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
		case .authorized, .limited: return .granted
		case .notDetermined: return .notDetermined
		default: return .denied
		}
	}

	public func requestAccess(_ done: @escaping @Sendable (PhotoAccess) -> Void) {
		PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in done(self.access()) }
	}

	public func albums() -> [PhotoAlbum] {
		var out: [PhotoAlbum] = []
		// 常用的几个智能相簿放前面：截屏最常有字。
		let smart: [(PHAssetCollectionSubtype, PhotoAlbum.Kind)] = [
			(.smartAlbumScreenshots, .screenshots), (.smartAlbumUserLibrary, .all), (.smartAlbumFavorites, .favorites),
		]
		for (subtype, kind) in smart {
			PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { c, _, _ in
				out.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "", count: self.imageCount(c), kind: kind))
			}
		}
		PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
			out.append(
				PhotoAlbum(
					id: c.localIdentifier, title: c.localizedTitle ?? "", count: self.imageCount(c), kind: .album,
					canAdd: c.assetCollectionSubtype == .albumRegular && c.canPerform(.addContent)))
		}
		return out
	}

	func imageCount(_ c: PHAssetCollection) -> Int {
		let o = PHFetchOptions()
		o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
		return PHAsset.fetchAssets(in: c, options: o).count
	}

	public func assets(in album: String?) -> [PhotoAsset] {
		let o = PHFetchOptions()
		o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
		o.includeHiddenAssets = false
		o.includeAllBurstAssets = false
		o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
		let result: PHFetchResult<PHAsset>
		if let album {
			// 相簿找不到了（删了）就是空的，别拿整个图库顶上。
			guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else { return [] }
			result = PHAsset.fetchAssets(in: c, options: o)
		} else {
			result = PHAsset.fetchAssets(with: o)
		}
		var out: [PhotoAsset] = []
		var seen: [String: PHAsset] = [:]
		out.reserveCapacity(result.count)
		result.enumerateObjects { a, _, _ in
			out.append(self.photoAsset(a))
			seen[a.localIdentifier] = a
		}
		lock.withLock { known.merge(seen) { _, new in new } }
		return out
	}

	public func assets(ids: [String]) -> [PhotoAsset] {
		var found: [String: PHAsset] = [:]
		PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in found[a.localIdentifier] = a }
		lock.withLock { known.merge(found) { _, new in new } }
		return ids.compactMap { found[$0].map(photoAsset) }
	}

	public func preview(for asset: PhotoAsset, pixels: Int, timeout: TimeInterval) -> PhotoImage {
		guard let a = phAsset(asset.id) else { return .failed("照片图库里找不到这张了") }
		let o = PHImageRequestOptions()
		// 只要一次、够大的那张；「快」的缩法拿本机现成的预览图，不为了凑准尺寸去下原图。
		o.deliveryMode = .highQualityFormat
		o.resizeMode = .fast
		o.isNetworkAccessAllowed = false
		o.version = .current
		let ticket = ImageTicket()
		let id = PHImageManager.default().requestImage(
			for: a, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit, options: o
		) { image, info in
			if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
			if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
				return ticket.finish(.image(downscaledQuickly(cg, longSide: pixels)))
			}
			if info?[PHImageResultIsInCloudKey] as? Bool == true { return ticket.finish(.inCloud(nil)) }
			ticket.finish(.failed(Self.describe(info?[PHImageErrorKey] as? NSError) ?? "没拿到图"))
		}
		// 回调在主线程上来：这里在后台等它，主线程不能反过来等这里。
		if let result = ticket.wait(timeout) { return result }
		PHImageManager.default().cancelImageRequest(id)
		return .timedOut
	}

	@MainActor public func thumbnail(for asset: PhotoAsset, pixels: Int, done: @escaping @MainActor (CGImage?) -> Void) {
		guard let a = phAsset(asset.id) else { return done(nil) }
		let o = PHImageRequestOptions()
		// 只要一次、要够看的那张（「先快后好」会先来一张很小的糊图）；不下载。
		o.deliveryMode = .highQualityFormat
		o.resizeMode = .fast
		o.isNetworkAccessAllowed = false
		o.version = .current
		PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, options: o) {
			image, _ in
			let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
			// 不同步的请求回调本来就在主线程上；以防万一不在，挪过去。
			if Thread.isMainThread {
				MainActor.assumeIsolated { done(cg) }
			} else {
				DispatchQueue.main.async { MainActor.assumeIsolated { done(cg) } }
			}
		}
	}

	public func filename(for asset: PhotoAsset) -> String? {
		guard let a = phAsset(asset.id) else { return nil }
		return PHAssetResource.assetResources(for: a).first?.originalFilename
	}

	public func image(
		for asset: PhotoAsset, maxPixel: Int, allowDownload: Bool, timeout: TimeInterval, progress: (@Sendable (Double) -> Void)?
	) -> PhotoImage {
		guard let a = phAsset(asset.id) else { return .failed("照片图库里找不到这张了") }
		// 长边不超过 maxPixel，原图更小就要原图大小（不放大）。
		let long = max(a.pixelWidth, a.pixelHeight, 1)
		let scale = min(1, Double(maxPixel) / Double(long))
		let size = CGSize(width: (Double(a.pixelWidth) * scale).rounded(), height: (Double(a.pixelHeight) * scale).rounded())
		let options = PHImageRequestOptions()
		options.deliveryMode = .highQualityFormat
		options.resizeMode = .exact
		// 「当前」版本：修过的照片认修过的样子（裁过、转过的）。
		options.version = .current
		options.isNetworkAccessAllowed = allowDownload
		options.isSynchronous = false
		if let progress { options.progressHandler = { value, _, _, _ in progress(value) } }
		let ticket = ImageTicket()
		let id = PHImageManager.default().requestImage(for: a, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
			// 要了高质量也可能先来一张降级的小图，不要它，等下一张。
			if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
			if info?[PHImageCancelledKey] as? Bool == true { return ticket.finish(.failed("取图被取消了")) }
			if let image {
				var rect = CGRect(origin: .zero, size: image.size)
				guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return ticket.finish(.failed("图解不开")) }
				// 给的图比要的大时再压一下（PhotoKit 偶尔给得比要的大）。
				return ticket.finish(.image(downscaledQuickly(cg, longSide: maxPixel)))
			}
			let error = Self.describe(info?[PHImageErrorKey] as? NSError)
			// 没让下载时系统也附一个「要联网才拿得到」的错，那不算原因。
			if info?[PHImageResultIsInCloudKey] as? Bool == true { return ticket.finish(.inCloud(allowDownload ? error : nil)) }
			ticket.finish(.failed(error ?? "没拿到图"))
		}
		// 回调在主线程上来：这里在识别队列上等它，主线程不能反过来等识别队列，不然两边互相等死。
		if let result = ticket.wait(timeout) { return result }
		PHImageManager.default().cancelImageRequest(id)
		return .timedOut
	}
}

extension SystemPhotoLibrary {
	@MainActor public func add(_ assets: [PhotoAsset], to target: AlbumTarget, done: @escaping @MainActor (String?) -> Void) {
		let found = PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
		guard found.count > 0 else { return done("照片图库里找不到这几张了") }
		var album: PHAssetCollection?
		if case .existing(let id) = target {
			album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
			guard album?.canPerform(.addContent) == true else { return done("这个相簿找不到了，或者不能往里加") }
		}
		PHPhotoLibrary.shared().performChanges {
			switch target {
			case .existing:
				if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets(found) }
			case .new(let title):
				PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title).addAssets(found)
			}
		} completionHandler: { ok, error in
			let problem = ok ? nil : (Self.describe(error as NSError?) ?? "照片图库没接受")
			DispatchQueue.main.async { MainActor.assumeIsolated { done(problem) } }
		}
	}

	/// PhotoKit 的错换成大白话：系统给的说明是「未能完成操作。（PHPhotosErrorDomain错误3169。）」这种，看不出原因。
	static func describe(_ error: NSError?) -> String? {
		guard let error else { return nil }
		if error.domain == PHPhotosErrorDomain, let code = PHPhotosError.Code(rawValue: error.code) {
			switch code {
			// 连不上 iCloud 时，系统要等一阵才报这个。
			case .networkError: return "网络出错，连不上 iCloud"
			case .notEnoughSpace: return "这台 Mac 空间不够"
			case .operationInterrupted: return "被打断了（临时的，下次再试）"
			case .missingResource: return "照片图库里缺这张的原图"
			case .userCancelled: return "取消了"
			default: break
			}
		}
		return "\(error.localizedDescription)（\(error.domain) \(error.code)）"
	}
}

/// 取图的回调和超时谁先到算谁的，只收一次。
final class ImageTicket: @unchecked Sendable {
	private let lock = NSLock()
	private let done = DispatchSemaphore(value: 0)
	private var result: PhotoImage?

	func finish(_ r: PhotoImage) {
		lock.lock()
		defer { lock.unlock() }
		guard result == nil else { return }
		result = r
		done.signal()
	}

	func wait(_ timeout: TimeInterval) -> PhotoImage? {
		_ = done.wait(timeout: .now() + timeout)
		lock.lock()
		defer { lock.unlock() }
		let r = result
		// 超时了：占住结果，后来的回调不再算数。
		if r == nil { result = .timedOut }
		return r
	}
}
