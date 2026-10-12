import AppKit
import OCRCore
import Photos

/// 照片自检（开发、排查用）：`open -a 拾字.app --args --photos-check 报告.json`；只量分类用的预览图：`--preview-check 报告.json`。
/// 要从 open 启动：系统把照片授权记在启动它的 App 名下，在终端里直接跑可执行文件，授权就算到终端头上了。
/// 做的事：要授权 → 列一遍图库、数原图在本机的有几张 → 取最近的 3 张截屏、最早的 2 张截屏、最近的 3 张照片和
/// 最近 500 张里像素最多的一张，量 PhotoKit 实际给多大的图、在本机还是 iCloud、取图多久；原图在 iCloud 上的，
/// 看本机有多大的预览图、拿它认得出多少字，再试着下载（最多下 2 张）→ 按真的流程认一遍、存进照片库
/// （跟在拾字里点「识别」一样）→ 写报告 → 退出。报告里不放认出的字和文件名。
public enum PhotoCheck {
	/// `downloadProbe`：另外同时下这么多张只在 iCloud 上的原图，量总共多久（`--download-probe 4`；0 是不试）。
	public static func run(report path: String, downloadProbe: Int = 0) {
		DispatchQueue(label: "拾字.照片自检").async {
			var report: [String: Any]
			do {
				report = try check()
				report["缩略图（不下载）"] = probeThumbnails()
				report["网格缩略图"] = probeGridThumbnails()
				report["分类用的预览图（不下载）"] = probePreviews()
				if downloadProbe > 0 { report["同时下载"] = probeDownloads(downloadProbe) }
			} catch {
				report = ["出错": "\(error)"]
			}
			report["版本"] = OCRVersion.current
			try? jsonString(report, pretty: true).write(toFile: path, atomically: true, encoding: .utf8)
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}
	}

	/// 只量按画面分类用的预览图：不要授权、不认字、不下载、不动照片库。
	public static func runPreviews(report path: String) {
		DispatchQueue(label: "拾字.照片自检").async {
			let library = SystemPhotoLibrary.shared
			var report: [String: Any] = ["授权": "\(library.access())", "版本": OCRVersion.current]
			if library.access() == .granted { report["分类用的预览图（不下载）"] = probePreviews() }
			try? jsonString(report, pretty: true).write(toFile: path, atomically: true, encoding: .utf8)
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}
	}

	/// 在自检自己的队列上一步步做；取图要等主线程上的回调，所以主线程不能等这里。
	static func check() throws -> [String: Any] {
		let library = SystemPhotoLibrary.shared
		var report: [String: Any] = ["授权（之前）": "\(library.access())"]
		var access = library.access()
		if access == .notDetermined {
			let answered = DispatchSemaphore(value: 0)
			let box = Locked(PhotoAccess.denied)
			library.requestAccess {
				box.value = $0
				answered.signal()
			}
			answered.wait()
			access = box.value
		}
		report["授权"] = "\(access)"
		guard access == .granted else { return report }

		var t = Date()
		let albums = library.albums()
		report["相簿"] = ["个数": albums.count, "秒": seconds(since: t)]
		t = Date()
		let all = library.assets(in: nil)
		report["全部照片"] = ["张数": all.count, "截屏": all.filter(\.isScreenshot).count, "列一遍秒": seconds(since: t)]
		t = Date()
		let local = localOriginals()
		report["原图在本机"] = ["截屏": local.screenshots, "照片": local.photos, "数一遍秒": seconds(since: t)]

		let screenshots = all.filter(\.isScreenshot)
		var chosen = Array(screenshots.prefix(3)) + Array(all.filter { !$0.isScreenshot }.prefix(3))
		let biggest = all.prefix(500).filter { !$0.isScreenshot }.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
		// 最早的截屏最可能只在 iCloud 上：看看那时候本机还剩多大的预览图。
		for asset in [biggest].compactMap({ $0 }) + screenshots.suffix(2) where !chosen.contains(asset) { chosen.append(asset) }
		var options = RecognitionDefaults.options()
		// 自检不往判定插件的服务发照片。
		options.usePlugins = false

		var rows: [[String: Any]] = []
		var downloads = 0
		for asset in chosen {
			var row: [String: Any] = ["类别": asset.isScreenshot ? "截屏" : "照片", "原图像素": "\(asset.pixelWidth)x\(asset.pixelHeight)"]
			t = Date()
			var result = library.image(for: asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: false, timeout: 30)
			row["本机取图秒"] = seconds(since: t)
			if case .inCloud = result {
				row["原图在 iCloud 上"] = true
				let preview = localPreview(asset.id)
				row["本机的预览图"] = preview.sizes
				if let best = preview.best {
					let page = Recognizer.shared.queue.sync { try? Recognizer.shared.engine.runPage(best, page: 1, options: options) }
					row["拿预览图认出几个字"] = page.map { $0.cleanText.filter { !$0.isWhitespace }.count } ?? -1
				}
				if downloads < 2 {
					downloads += 1
					// 下载时系统报了几次进度、报到多少、头一次报是开始后几秒：看是根本没开始下，还是下到一半断了。
					let started = Date()
					let reports = Locked((count: 0, highest: 0.0, first: -1.0))
					result = library.image(
						for: asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: true, timeout: Recognizer.downloadTimeout,
						progress: { value in
							reports.update {
								$0.count += 1
								$0.highest = max($0.highest, value)
								if $0.first < 0 { $0.first = seconds(since: started) }
							}
						})
					row["下载秒"] = seconds(since: started)
					let r = reports.value
					row["下载进度"] = ["报了几次": r.count, "最高": r.highest, "头一次报在第几秒": r.first]
				}
			}
			switch result {
			case .image(let image): row["给的像素"] = "\(image.width)x\(image.height)"
			case .inCloud(let reason): row["取图"] = "在 iCloud 上，没拿到：\(reason ?? "没让下载")"
			case .timedOut: row["取图"] = "超时"
			case .failed(let message): row["取图"] = "出错：\(message)"
			}
			rows.append(row)
		}

		// 按真的流程认。下载关着：刚才下过的，看是不是留在本机了。之前自检认过的先删掉，好量认一张多久。
		let index = try PhotoIndex()
		try index.remove(chosen.map(\.id))
		let started = Date()
		let times = Locked([String: Double]())
		let finished = DispatchSemaphore(value: 0)
		Recognizer.shared.recognize(
			photos: chosen, library: library, index: index, options: options, allowDownload: false, stop: StopFlag(),
			onPhoto: { asset, _ in times.update { $0[asset.id] = seconds(since: started) } }, onFinish: { finished.signal() })
		finished.wait()
		report["认这几张秒"] = seconds(since: started)

		var previous = 0.0
		for (i, asset) in chosen.enumerated() {
			let at = times.value[asset.id] ?? previous
			rows[i]["认这张秒"] = ((at - previous) * 1000).rounded() / 1000
			previous = at
			guard let r = index.record(asset.id) else { continue }
			rows[i]["状态"] = r.status.rawValue
			rows[i]["字数"] = r.text.filter { !$0.isWhitespace }.count
			rows[i]["可疑行"] = r.suspects
			if let problem = r.problem { rows[i]["问题"] = problem }
			// 拿字里的一小段搜一下，看找不找得回这张（报告里不放这段字）。
			if let term = sample(r.text) { rows[i]["按字找得回来"] = index.search(term, limit: 50).contains { $0.id == asset.id } }
		}
		report["照片"] = rows

		let stats = index.stats()
		report["照片库"] = ["张数": stats.count, "有字": stats.withText, "iCloud 上没认": stats.inCloud, "出错": stats.failed, "位置": PhotoIndex.defaultPath]
		report["剩余空间够下载"] = Recognizer.enoughSpaceForDownload()
		let memory = footprint()
		report["内存 MB"] = ["现在": memory.now >> 20, "最高": memory.peak >> 20]
		return report
	}

	/// 原图在本机的有几张。
	static func localOriginals() -> (screenshots: String, photos: String) {
		var counts = (screenshots: 0, screenshotsLocal: 0, photos: 0, photosLocal: 0)
		PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
			let local = originalIsLocal(asset)
			if asset.mediaSubtypes.contains(.photoScreenshot) {
				counts.screenshots += 1
				if local { counts.screenshotsLocal += 1 }
			} else {
				counts.photos += 1
				if local { counts.photosLocal += 1 }
			}
		}
		return ("\(counts.screenshotsLocal)/\(counts.screenshots)", "\(counts.photosLocal)/\(counts.photos)")
	}

	/// 原图在不在本机：要原图的数据、不让下载，拿得到就在本机（只读文件、不解图，很快）。
	static func originalIsLocal(_ asset: PHAsset) -> Bool {
		autoreleasepool {
			let o = PHImageRequestOptions()
			o.isNetworkAccessAllowed = false
			o.isSynchronous = true
			o.version = .current
			let local = Locked(false)
			PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in local.value = data != nil }
			return local.value
		}
	}

	/// 网格里的缩略图（格子约 140 点、要 280 像素）不让下载时本机有多大的：原图只在 iCloud 上的挑 3 张，原图在本机的挑 1 张对照。
	/// 原图在 iCloud 上时按原图大小要，本机只给一张很小的图；网格要的小，看本机有没有够用的中等缩略图，决定网格要不要联网取缩略图。
	static func probeThumbnails() -> [[String: Any]] {
		var cloud: [PHAsset] = [], local: [PHAsset] = []
		let o = PHFetchOptions()
		o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
		PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { asset, _, stop in
			if originalIsLocal(asset) {
				if local.isEmpty && !asset.mediaSubtypes.contains(.photoScreenshot) { local.append(asset) }
			} else if cloud.count < 3 {
				cloud.append(asset)
			}
			if cloud.count >= 3 && !local.isEmpty { stop.pointee = true }
		}
		return (cloud + local).map { asset in
			var row: [String: Any] = ["原图像素": "\(asset.pixelWidth)x\(asset.pixelHeight)", "原图在本机": originalIsLocal(asset)]
			for (label, mode) in [("高质量", PHImageRequestOptionsDeliveryMode.highQualityFormat), ("先快后好", .opportunistic)] {
				let opts = PHImageRequestOptions()
				opts.deliveryMode = mode
				opts.resizeMode = .fast
				opts.isNetworkAccessAllowed = false
				opts.version = .current
				let got = Locked([String]())
				let done = DispatchSemaphore(value: 0)
				let started = Date()
				PHImageManager.default().requestImage(
					for: asset, targetSize: CGSize(width: 280, height: 280), contentMode: .aspectFill, options: opts
				) { image, info in
					let early = info?[PHImageResultIsDegradedKey] as? Bool == true
					let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
					got.update { $0.append((cg.map { "\($0.width)x\($0.height)" } ?? "没给") + (early ? "（先给的）" : "")) }
					if !early { done.signal() }
				}
				_ = done.wait(timeout: .now() + 10)
				row[label] = got.value
				row[label + "秒"] = seconds(since: started)
			}
			return row
		}
	}

	/// 照网格的取法（`SystemPhotoLibrary.thumbnail`，在主线程上要、回调）取「最近项目」头 60 张的缩略图：几张到了、多久、多大。
	static func probeGridThumbnails() -> [String: Any] {
		let library = SystemPhotoLibrary.shared
		let assets = Array(library.assets(in: nil).prefix(60))
		let sizes = Locked([String: Int]())
		let missing = Locked(0)
		let group = DispatchGroup()
		let started = Date()
		for asset in assets {
			group.enter()
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					library.thumbnail(for: asset, pixels: PhotosModel.thumbnailPixels) { image in
						if let image {
							sizes.update { $0["\(image.width)x\(image.height)", default: 0] += 1 }
						} else {
							missing.update { $0 += 1 }
						}
						group.leave()
					}
				}
			}
		}
		let finished = group.wait(timeout: .now() + 30) == .success
		return [
			"张数": assets.count, "都到了": finished, "没给": missing.value, "秒": seconds(since: started),
			"尺寸（最多的 5 种）": sizes.value.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) ×\($0.value)" },
		]
	}

	/// 同时下 n 张原图只在 iCloud 上的照片（最近拍的那几张），量每张和总共多久：认一批时值不值得几张一起下。
	/// iCloud 闲了一阵以后，头一张要等很久、进度只在最后报一次；热起来以后几张一起下就快了。
	static func probeDownloads(_ n: Int) -> [String: Any] {
		var picked: [PHAsset] = []
		let o = PHFetchOptions()
		o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
		PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { asset, _, stop in
			if !asset.mediaSubtypes.contains(.photoScreenshot) && !originalIsLocal(asset) { picked.append(asset) }
			if picked.count >= n { stop.pointee = true }
		}
		let library = SystemPhotoLibrary.shared
		let rows = Locked([[String: Any]]())
		let group = DispatchGroup()
		let started = Date()
		for a in picked {
			let asset = PhotoAsset(id: a.localIdentifier, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight)
			DispatchQueue.global(qos: .userInitiated).async(group: group) {
				let result = library.image(for: asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: true, timeout: 180)
				var row: [String: Any] = ["原图像素": "\(asset.pixelWidth)x\(asset.pixelHeight)", "秒": seconds(since: started)]
				switch result {
				case .image(let image): row["结果"] = "下下来了，\(image.width)x\(image.height)"
				case .inCloud(let reason): row["结果"] = "没下下来：\(reason ?? "")"
				case .timedOut: row["结果"] = "等了 180 秒还没下完"
				case .failed(let message): row["结果"] = "出错：\(message)"
				}
				rows.update { $0.append(row) }
			}
		}
		group.wait()
		return ["张数": picked.count, "总秒": seconds(since: started), "每张（按下完的先后）": rows.value]
	}

	/// 按画面分类取的预览图，照分类时的取法（`SystemPhotoLibrary.preview`：长边 360、不下载；这里只等 10 秒）。
	/// 原图只在 iCloud 上的挑：最近的照片 6 张、接近正方形的 2 张（本机的小图只有几百像素，正方形的长边可能不到 360）、截屏 2 张；
	/// 原图在本机的挑 2 张对照。只记拿没拿到、多大、多久；没拿到的照原样再要一次，记下系统每次回调给了什么。
	static func probePreviews() -> [String: Any] {
		var picked: [(asset: PHAsset, kind: String)] = []
		var n = (photos: 0, square: 0, shots: 0, local: 0)
		let o = PHFetchOptions()
		o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
		PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { asset, _, stop in
			let long = Double(max(asset.pixelWidth, asset.pixelHeight)), short = Double(max(1, min(asset.pixelWidth, asset.pixelHeight)))
			if originalIsLocal(asset) {
				if n.local < 2 {
					n.local += 1
					picked.append((asset, "原图在本机"))
				}
			} else if asset.mediaSubtypes.contains(.photoScreenshot) {
				if n.shots < 2 {
					n.shots += 1
					picked.append((asset, "截屏，原图在 iCloud"))
				}
			} else if long / short < 1.1 {
				if n.square < 2 {
					n.square += 1
					picked.append((asset, "接近正方形，原图在 iCloud"))
				}
			} else if n.photos < 6 {
				n.photos += 1
				picked.append((asset, "照片，原图在 iCloud"))
			}
			if n.photos >= 6 && n.square >= 2 && n.shots >= 2 && n.local >= 2 { stop.pointee = true }
		}
		let library = SystemPhotoLibrary.shared
		let rows: [[String: Any]] = picked.map { a, kind in
			var row: [String: Any] = ["类别": kind, "原图像素": "\(a.pixelWidth)x\(a.pixelHeight)"]
			let started = Date()
			let result = library.preview(for: library.photoAsset(a), pixels: ClassifyBatch.previewPixels, timeout: 10)
			row["秒"] = seconds(since: started)
			switch result {
			case .image(let image): row["给的像素"] = "\(image.width)x\(image.height)"
			case .inCloud: row["没拿到"] = "说在 iCloud 上"
			case .timedOut: row["没拿到"] = "等了 10 秒"
			case .failed(let message): row["没拿到"] = "出错：\(message)"
			}
			if row["没拿到"] != nil { row["系统回调"] = previewCallbacks(a) }
			return row
		}
		let cloud = rows.filter { ($0["类别"] as? String)?.hasSuffix("iCloud") == true }
		return ["原图在 iCloud 上的": "\(cloud.filter { $0["给的像素"] != nil }.count) / \(cloud.count) 张拿到", "每张": rows]
	}

	/// 照 `SystemPhotoLibrary.preview` 的取法再要一次，记下系统每次回调给了什么：多大、是不是先给的、说没说在 iCloud 上。
	static func previewCallbacks(_ asset: PHAsset) -> [String] {
		let o = PHImageRequestOptions()
		o.deliveryMode = .highQualityFormat
		o.resizeMode = .fast
		o.isNetworkAccessAllowed = false
		o.version = .current
		let got = Locked([String]())
		let done = DispatchSemaphore(value: 0)
		let side = CGFloat(ClassifyBatch.previewPixels)
		PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: o) {
			image, info in
			let early = info?[PHImageResultIsDegradedKey] as? Bool == true
			let cloud = info?[PHImageResultIsInCloudKey] as? Bool == true
			let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
			got.update { $0.append((cg.map { "\($0.width)x\($0.height)" } ?? "没给") + (early ? "，先给的" : "") + (cloud ? "，说在 iCloud 上" : "")) }
			if !early { done.signal() }
		}
		_ = done.wait(timeout: .now() + 10)
		return got.value
	}

	/// 原图在 iCloud 上时本机有多大的图（缩略图、预览）：不让下载，系统给几张收几张，留最大的。
	static func localPreview(_ id: String) -> (sizes: [String], best: CGImage?) {
		guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return ([], nil) }
		let o = PHImageRequestOptions()
		o.deliveryMode = .opportunistic
		o.isNetworkAccessAllowed = false
		o.resizeMode = .none
		o.version = .current
		let found = Locked((sizes: [String](), best: CGImage?.none))
		let done = DispatchSemaphore(value: 0)
		PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: o) {
			image, info in
			let early = info?[PHImageResultIsDegradedKey] as? Bool == true
			let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
			found.update { f in
				if let cg {
					f.sizes.append("\(cg.width)x\(cg.height)\(early ? "（先给的）" : "")")
					if cg.width * cg.height > (f.best.map { $0.width * $0.height } ?? 0) { f.best = cg }
				} else {
					f.sizes.append(early ? "先给的是空的" : "最后没给")
				}
			}
			if !early { done.signal() }
		}
		_ = done.wait(timeout: .now() + 10)
		return found.value
	}

	/// 字里最长的一段（不带空白）中间取 4 个字。
	static func sample(_ text: String) -> String? {
		guard let run = text.split(whereSeparator: \.isWhitespace).max(by: { $0.count < $1.count }), !run.isEmpty else { return nil }
		let start = run.index(run.startIndex, offsetBy: max(0, run.count / 2 - 2))
		return String(run[start...].prefix(4))
	}

	static func seconds(since t: Date) -> Double { (Date().timeIntervalSince(t) * 1000).rounded() / 1000 }

	/// 这个进程实际占的内存（跟「活动监视器」里的「内存」一列同一个数）和启动以来的最高值。
	static func footprint() -> (now: Int, peak: Int) {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
		}
		guard kr == KERN_SUCCESS else { return (0, 0) }
		return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
	}
}

/// 几个线程都要碰的一个值，加把锁。
final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Value

	init(_ value: Value) { stored = value }

	var value: Value {
		get { lock.withLock { stored } }
		set { lock.withLock { stored = newValue } }
	}

	/// 读、改、写一气做完：几个线程一起往里加东西时用它，用 `value` 分两步会丢。
	func update(_ change: (inout Value) -> Void) {
		lock.withLock { change(&stored) }
	}
}
