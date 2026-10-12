import Foundation
import OCRCore

extension Recognizer {
	/// 认一批照片：认过、照片也没改过的跳过；认完一张存一张，中途停了，认好的都在库里。
	/// 排在跟文件一样的那条识别队列上（见「已知的坑」），一张一张排：认完一张再排下一张，中间打开的文件、框选识别能插进来先认，
	/// 不用等整批认完。
	/// 分两趟：先认原图在本机的，原图只在 iCloud 上的留到最后再下载（`allowDownload` 时）。本机的认得快；
	/// 下载就难说了：iCloud 那边闲了一阵以后，头一张要等很久（还常常等到最后报「网络出错」），
	/// 之后就快了。不能让本机的排在这种等待后面。
	/// `onPhoto` 的第二个参数是存进库的那一行；跳过的给 nil。开始下载前 `onDownloads` 报一次要下载的是哪几张。
	/// `roomToDownload` 每张要下载前问一次（测试里换掉）。
	func recognize(
		photos: [PhotoAsset], library: PhotoLibrary, index: PhotoIndex, options: OCROptions, allowDownload: Bool, stop: StopFlag,
		roomToDownload: @escaping @Sendable () -> Bool = { Recognizer.enoughSpaceForDownload() },
		onDownloads: @escaping @MainActor ([PhotoAsset]) -> Void = { _ in },
		onPhoto: @escaping @MainActor (PhotoAsset, PhotoIndex.Record?) -> Void, onFinish: @escaping @MainActor () -> Void
	) {
		let run = PhotoBatchRun(
			recognizer: self, photos: photos, library: library, index: index, options: options, allowDownload: allowDownload, stop: stop,
			roomToDownload: roomToDownload, onDownloads: onDownloads, onPhoto: onPhoto, onFinish: onFinish)
		queue.async { run.step() }
	}

	/// 取到的图认出字填进这一行；没取到就写明为什么。`downloading`：这次让不让从 iCloud 下载。
	/// `memory`：认一批时传同一个，中文优先时记住上一张是不是西文（见 RunMemory）。
	static func fill(
		_ record: PhotoIndex.Record, with image: PhotoImage, engine: OCREngine, options: OCROptions, downloading: Bool,
		memory: RunMemory? = nil
	) -> PhotoIndex.Record {
		var r = record
		r.problem = nil
		switch image {
		case .image(let image):
			do {
				r = recognized(r, page: try engine.runPage(image, page: 1, options: options, memory: memory))
			} catch {
				r.status = .failed
				r.problem = "\(error)"
			}
		case .inCloud(let reason):
			r.status = .icloud
			let why = reason ?? String(localized: "系统没说原因")
			r.problem = downloading ? String(localized: "从 iCloud 下载原图没成：\(why)") : String(localized: "原图在 iCloud 上，下载原图关着")
		case .timedOut where downloading:
			// 跟「在 iCloud 上」一样下次再认。
			r.status = .icloud
			r.problem = String(localized: "等了 \(Int(downloadTimeout)) 秒原图还没从 iCloud 下下来，下次再认")
		case .timedOut:
			r.status = .failed
			r.problem = String(localized: "等了 \(Int(localTimeout)) 秒还没从照片图库取到图")
		case .failed(let message):
			r.status = .failed
			r.problem = message
		}
		return r
	}

	/// 认出来的一页填成照片库的一行：二维码、条码的内容也存进去，一起能搜。认一批和打开一张看都用它，存的样子一样。
	static func recognized(_ record: PhotoIndex.Record, page: PageResult) -> PhotoIndex.Record {
		var r = record
		r.text = ([page.cleanText] + page.barcodes).filter { !$0.isEmpty }.joined(separator: "\n")
		r.status = r.text.isEmpty ? .empty : .text
		r.suspects = page.lines.filter { $0.suspect != nil }.count
		r.problem = nil
		return r
	}

	/// 照片长边最多这么大交给识别：系统识别第一遍自己会把整张图缩小（见 `internalPixelBudget`），像素多的好处在小字（核心会切块细认）；
	/// 4800 万像素的照片解开要 190 MB 内存、切块也慢，缩到 4096（约 1200 万像素）。
	static let photoMaxPixel = 4096
	/// 从 iCloud 下一张原图最多等这么久，过了就跳过、标出来，下次再认。头一张下成的也要等很久，
	/// 没下成的系统自己也要等一阵才报「网络出错」，所以给足 120 秒。
	static let downloadTimeout: TimeInterval = 120
	/// 不下载时取一张本机的图：平常很快，给足余量。
	static let localTimeout: TimeInterval = 30
	/// 连着这么多张没下下来就不再下：连不上 iCloud 时每张都要白等一阵，系统才报「网络出错」；只是头一张慢的话，后面的会接着下成。
	static let downloadFailureLimit = 3

	/// 剩余空间不到 3 GB 就不从 iCloud 下原图，只跳过要下载的，本机有原图的照常认：下下来的原图存进照片图库、
	/// 占这台 Mac 的空间，系统以后才慢慢清；一批认几千张时可能先把盘占满。
	static func enoughSpaceForDownload() -> Bool {
		let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		return (values?.volumeAvailableCapacityForImportantUsage ?? Int64.max) >= 3 << 30
	}
}

/// 一批照片认到哪了。状态只在识别队列上碰（一次只走一步），所以不加锁。
final class PhotoBatchRun: @unchecked Sendable {
	let recognizer: Recognizer
	let library: PhotoLibrary
	let index: PhotoIndex
	let options: OCROptions
	let allowDownload: Bool
	let stop: StopFlag
	let roomToDownload: @Sendable () -> Bool
	let onDownloads: @MainActor ([PhotoAsset]) -> Void
	let onPhoto: @MainActor (PhotoAsset, PhotoIndex.Record?) -> Void
	let onFinish: @MainActor () -> Void
	/// 整批用同一个识别引擎：中途改了插件配置，从下一批起才算。
	let engine: OCREngine
	/// 中文优先时记住上一张是不是西文：一相簿英文截图不用每张都先白认一遍中文。
	let memory = RunMemory()
	let activity: NSObjectProtocol

	/// 第一趟还没过的。
	var pending: ArraySlice<PhotoAsset>
	/// 原图在 iCloud 上、等第二趟下载的。
	var waiting: [(asset: PhotoAsset, record: PhotoIndex.Record)] = []
	var downloadsAnnounced = false
	/// 第二趟连着几张没下下来。
	var failures = 0

	init(
		recognizer: Recognizer, photos: [PhotoAsset], library: PhotoLibrary, index: PhotoIndex, options: OCROptions, allowDownload: Bool,
		stop: StopFlag, roomToDownload: @escaping @Sendable () -> Bool, onDownloads: @escaping @MainActor ([PhotoAsset]) -> Void,
		onPhoto: @escaping @MainActor (PhotoAsset, PhotoIndex.Record?) -> Void, onFinish: @escaping @MainActor () -> Void
	) {
		self.recognizer = recognizer
		self.library = library
		self.index = index
		self.options = options
		self.allowDownload = allowDownload
		self.stop = stop
		self.roomToDownload = roomToDownload
		self.onDownloads = onDownloads
		self.onPhoto = onPhoto
		self.onFinish = onFinish
		engine = recognizer.engine
		pending = photos[...]
		// 认一大批时别让 Mac 睡过去（屏幕可以暗）。
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .idleSystemSleepDisabled], reason: String(localized: "拾字在认照片里的字"))
	}

	/// 走一步（认一张或跳过一张），再把下一步排到识别队列末尾。
	func step() {
		if stop.isStopped { return finish() }
		if let asset = pending.popFirst() {
			firstPass(asset)
		} else if !downloadsAnnounced {
			downloadsAnnounced = true
			let assets = waiting.map(\.asset)
			if !assets.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { self.onDownloads(assets) } } }
		} else if !waiting.isEmpty {
			secondPass(waiting.removeFirst())
		} else {
			return finish()
		}
		recognizer.queue.async { self.step() }
	}

	func finish() {
		ProcessInfo.processInfo.endActivity(activity)
		DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinish() } }
	}

	func save(_ asset: PhotoAsset, _ record: PhotoIndex.Record?) {
		if let record { try? index.upsert(record) }
		DispatchQueue.main.async { MainActor.assumeIsolated { self.onPhoto(asset, record) } }
	}

	/// 第一趟：不下载。每张单独一个 autoreleasepool，PhotoKit、识别留下的临时对象认完一张就放掉。
	func firstPass(_ asset: PhotoAsset) {
		if index.isDone(asset.id, stamp: asset.stamp) { return save(asset, nil) }
		autoreleasepool {
			var r = PhotoIndex.Record(
				id: asset.id, stamp: asset.stamp, status: .failed, name: library.filename(for: asset), taken: asset.created)
			let image = library.image(for: asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: false, timeout: Recognizer.localTimeout)
			guard case .inCloud = image else {
				return save(asset, Recognizer.fill(r, with: image, engine: engine, options: options, downloading: false, memory: memory))
			}
			r.status = .icloud
			guard allowDownload else {
				r.problem = String(localized: "原图在 iCloud 上，下载原图关着")
				return save(asset, r)
			}
			// 先记下来：第二趟没轮到就停了的，库里也知道它在 iCloud 上。
			r.problem = String(localized: "原图在 iCloud 上，还没下载")
			try? index.upsert(r)
			waiting.append((asset, r))
		}
	}

	/// 第二趟：下载。连着几张没下下来，多半是连不上 iCloud，这次就不再下了，剩下的下次再认。
	func secondPass(_ item: (asset: PhotoAsset, record: PhotoIndex.Record)) {
		autoreleasepool {
			var r = item.record
			if failures >= Recognizer.downloadFailureLimit {
				r.problem = String(localized: "前面连着 \(Recognizer.downloadFailureLimit) 张从 iCloud 下载都没成，这次先不下了")
			} else if !roomToDownload() {
				r.problem = String(localized: "原图在 iCloud 上，这台 Mac 剩余空间不到 3 GB，没下载")
			} else {
				let image = library.image(
					for: item.asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: true, timeout: Recognizer.downloadTimeout)
				switch image {
				case .image: failures = 0
				case .inCloud, .timedOut: failures += 1
				case .failed: break
				}
				r = Recognizer.fill(r, with: image, engine: engine, options: options, downloading: true, memory: memory)
			}
			save(item.asset, r)
		}
	}
}
