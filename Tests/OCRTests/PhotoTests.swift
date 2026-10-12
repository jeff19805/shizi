import CoreGraphics
import Foundation
import Photos
import Testing
@testable import OCRCore
@testable import OCRServer
@testable import ShiziKit

/// 测试用的照片图库：不碰真的照片图库，照片的样子在测试里定。
final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {
	enum Kind {
		/// 原图在本机。
		case local(CGImage)
		/// 原图只在 iCloud 上：让下载才给。
		case cloud(CGImage)
		/// 原图只在 iCloud 上，让下载也下不下来。
		case unreachable
		/// 原图只在 iCloud 上，下载一直下不完（等超时）。
		case slow
		case broken
	}

	private let lock = NSLock()
	private var kinds: [String: Kind] = [:]
	private(set) var assetList: [PhotoAsset] = []
	/// 取一张图前先等这么久（装作照片多、取得慢）。
	var delay: TimeInterval = 0
	/// 取过哪几张图、让不让下载。
	private(set) var requests: [(id: String, allowDownload: Bool)] = []

	func add(_ id: String, _ kind: Kind, created: Date, modified: Date? = nil, width: Int = 900, height: Int = 220) {
		lock.withLock {
			kinds[id] = kind
			assetList.append(PhotoAsset(id: id, created: created, modified: modified, pixelWidth: width, pixelHeight: height))
		}
	}

	var requestedIDs: [String] { lock.withLock { requests.map(\.id) } }

	/// 照片改过：修改时间往后挪。
	func touch(_ id: String) {
		lock.withLock {
			if let i = assetList.firstIndex(where: { $0.id == id }) { assetList[i].modified = Date() }
		}
	}
	/// 取图的记录，让下载的带个「↓」。
	var log: [String] { lock.withLock { requests.map { $0.id + ($0.allowDownload ? "↓" : "") } } }

	func access() -> PhotoAccess { .granted }
	func requestAccess(_ done: @escaping @Sendable (PhotoAccess) -> Void) { done(.granted) }
	/// 自己建的相簿：编号 → (名字, 照片编号)。开头有「部分」（头一张）和「空的」两个。
	private var userAlbums: [(id: String, title: String, ids: [String])] = [("部分", "部分", []), ("空的", "空的", [])]
	/// 往相簿里加过什么：「相簿名 ← 编号,编号」。名字叫「坏」的新相簿建不成。
	private(set) var addLog: [String] = []

	/// 「全部」和自己建的几个相簿。
	func albums() -> [PhotoAlbum] {
		[PhotoAlbum(id: "all", title: "全部", count: lock.withLock { assetList.count }, kind: .all)]
			+ lock.withLock { userAlbums.map { PhotoAlbum(id: $0.id, title: $0.title, count: members($0.id).count, kind: .album, canAdd: true) } }
	}

	/// 调的时候已经拿着锁。
	private func members(_ album: String) -> [PhotoAsset] {
		if album == "部分" {
			let extra = userAlbums.first { $0.id == "部分" }?.ids ?? []
			return assetList.prefix(1) + assetList.filter { extra.contains($0.id) && $0.id != assetList.first?.id }
		}
		guard let ids = userAlbums.first(where: { $0.id == album })?.ids else { return assetList }
		return assetList.filter { ids.contains($0.id) }
	}

	func assets(in album: String?) -> [PhotoAsset] { lock.withLock { album.map(members) ?? assetList } }

	@MainActor func add(_ assets: [PhotoAsset], to target: AlbumTarget, done: @escaping @MainActor (String?) -> Void) {
		let ids = assets.map(\.id)
		let problem: String? = lock.withLock {
			switch target {
			case .existing(let id):
				guard let i = userAlbums.firstIndex(where: { $0.id == id }) else { return "这个相簿找不到了" }
				userAlbums[i].ids += ids.filter { !userAlbums[i].ids.contains($0) }
				addLog.append("\(userAlbums[i].title) ← \(ids.joined(separator: ","))")
			case .new(let title):
				if title == "坏" { return "照片图库没接受" }
				userAlbums.append(("新-\(userAlbums.count)", title, ids))
				addLog.append("新建 \(title) ← \(ids.joined(separator: ","))")
			}
			return nil
		}
		DispatchQueue.main.async { MainActor.assumeIsolated { done(problem) } }
	}
	func assets(ids: [String]) -> [PhotoAsset] { lock.withLock { ids.compactMap { id in assetList.first { $0.id == id } } } }
	func filename(for asset: PhotoAsset) -> String? { "\(asset.id).PNG" }

	/// 预览图：本机的、云上的都有（照片图库本机总留着小图），坏的没有。
	func preview(for asset: PhotoAsset, pixels: Int, timeout: TimeInterval) -> PhotoImage {
		switch lock.withLock({ kinds[asset.id] }) {
		case .local(let image)?, .cloud(let image)?: return .image(downscaledQuickly(image, longSide: pixels))
		default: return .failed("坏了")
		}
	}

	@MainActor func thumbnail(for asset: PhotoAsset, pixels: Int, done: @escaping @MainActor (CGImage?) -> Void) {
		let image: CGImage? =
			switch lock.withLock({ kinds[asset.id] }) {
			case .local(let image)?, .cloud(let image)?: downscaledQuickly(image, longSide: pixels)
			default: nil
			}
		DispatchQueue.main.async { MainActor.assumeIsolated { done(image) } }
	}

	func image(
		for asset: PhotoAsset, maxPixel: Int, allowDownload: Bool, timeout: TimeInterval, progress: (@Sendable (Double) -> Void)?
	) -> PhotoImage {
		let kind = lock.withLock {
			requests.append((asset.id, allowDownload))
			return kinds[asset.id]
		}
		if delay > 0 { Thread.sleep(forTimeInterval: delay) }
		switch kind {
		case .local(let image): return .image(downscaledQuickly(image, longSide: maxPixel))
		case .cloud(let image): return allowDownload ? .image(downscaledQuickly(image, longSide: maxPixel)) : .inCloud(nil)
		case .unreachable: return .inCloud(allowDownload ? "连不上 iCloud" : nil)
		case .slow: return allowDownload ? .timedOut : .inCloud(nil)
		case .broken, nil: return .failed("坏了")
		}
	}
}

func tempIndex() throws -> (PhotoIndex, String) {
	let path = Fixtures.tempURL("sqlite").path
	return (try PhotoIndex(path: path), path)
}

func photo(_ id: String, _ text: String, taken: TimeInterval, status: PhotoIndex.Status = .text) -> PhotoIndex.Record {
	PhotoIndex.Record(
		id: id, stamp: "s", status: status, text: text, name: "\(id).HEIC", taken: Date(timeIntervalSince1970: taken),
		updated: Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func 照片库存了能按字找() throws {
	let (index, path) = try tempIndex()
	try index.upsert(photo("a", "招商银行\n信用卡账单 本期应还 3,280.00", taken: 100))
	try index.upsert(photo("b", "Wi-Fi 密码：hello2026", taken: 300))
	try index.upsert(photo("c", "会议纪要：招商银行合作", taken: 200))
	try index.upsert(photo("d", "", taken: 400, status: .empty))
	try index.upsert(photo("e", "", taken: 500, status: .icloud))

	#expect(index.search("招商银行", limit: 10).map(\.id) == ["c", "a"], "新拍的在前")
	#expect(index.search("招商银行", limit: 1).map(\.id) == ["c"])
	#expect(index.search("银行信用卡", limit: 10).map(\.id) == ["a"], "断了行的词也找得到")
	#expect(index.search("招商银行 账单", limit: 10).map(\.id) == ["a"], "空格隔开的几个词都要有")
	#expect(index.search("wi-fi　ＨＥＬＬＯ", limit: 10).map(\.id) == ["b"], "不分大小写、全角半角")
	#expect(index.search("  ", limit: 10).isEmpty && index.search("没有这句", limit: 10).isEmpty)

	let read = try #require(index.record("a"))
	#expect(read == photo("a", "招商银行\n信用卡账单 本期应还 3,280.00", taken: 100))
	#expect(read.revision == PhotoIndex.revision)
	let s = index.stats()
	#expect(s.count == 5 && s.withText == 3 && s.inCloud == 1 && s.failed == 0)
	#expect(s.newest == Date(timeIntervalSince1970: 1_800_000_000))

	// 认好了、照片没改过才算完；在 iCloud 上没认的下次还认。
	#expect(index.isDone("a", stamp: "s") && index.isDone("d", stamp: "s"))
	#expect(!index.isDone("a", stamp: "改过") && !index.isDone("e", stamp: "s") && !index.isDone("没有", stamp: "s"))

	// 再存一次同一张：文件名、拍摄时间没给就留着原来的。
	try index.upsert(PhotoIndex.Record(id: "a", stamp: "s2", status: .empty))
	let again = try #require(index.record("a"))
	#expect(again.status == .empty && again.name == "a.HEIC" && again.taken == Date(timeIntervalSince1970: 100))
	#expect(index.search("招商银行", limit: 10).map(\.id) == ["c"], "改成没字以后不该再搜到")

	try index.remove(["d", "没有这张"])
	#expect(index.record("d") == nil && index.stats().count == 4)
	try index.upsert(photo("d", "", taken: 400, status: .empty))

	// 拾字开着库的时候，MCP 服务只读打开也搜得到，写不进去。
	let reader = try PhotoIndex(path: path, readOnly: true)
	#expect(reader.search("密码", limit: 10).map(\.id) == ["b"])
	#expect(throws: (any Error).self) { try reader.upsert(photo("x", "写不进去", taken: 1)) }
	#expect(index.stats().count == 5)
	#expect(throws: (any Error).self) { try PhotoIndex(path: Fixtures.tempURL("sqlite").path, readOnly: true) }

	// 拾字关了（WAL 并回主文件），附带的 -wal、-shm 也没了（比如从备份恢复的），只读照样打得开。
	let closed = Fixtures.tempURL("sqlite").path
	do {
		let writer = try PhotoIndex(path: closed)
		try writer.upsert(photo("z", "关了以后还能搜", taken: 1))
	}
	for ext in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: closed + ext) }
	#expect(try PhotoIndex(path: closed, readOnly: true).search("还能搜", limit: 5).map(\.id) == ["z"])
}

@Test func 照片的字摘一段() {
	let text = "第一行开头\n" + String(repeating: "很长的正文", count: 20) + "\n招商\n银行在这里\n" + String(repeating: "结尾", count: 30)
	let s = PhotoIndex.snippet(text, around: "招商银行", width: 10)
	#expect(s.hasPrefix("…") && s.hasSuffix("…") && s.contains("招商 银行在这里"), "\(s)")
	#expect(PhotoIndex.snippet("短的一句", around: "没有") == "短的一句")
	#expect(PhotoIndex.snippet(String(repeating: "长", count: 100), around: "没有", width: 10) == String(repeating: "长", count: 20) + "…")
}

@Test func 按字找照片的工具() throws {
	let missing = try Tools.photosSearch(["query": "发票"], index: Fixtures.tempURL("sqlite").path)
	#expect(missing.contains("还没认过照片"))

	let (index, path) = try tempIndex()
	try index.upsert(photo("a", "增值税电子普通发票\n金额 120.00", taken: 1_790_000_000))
	try index.upsert(photo("b", "停车发票", taken: 1_791_000_000))
	try index.upsert(photo("c", "", taken: 1_792_000_000, status: .icloud))
	try index.upsert(photo("d", "", taken: 1_792_000_000, status: .failed))
	let reply = try Tools.photosSearch(["query": "发票", "limit": 5], index: path)
	let lines = reply.components(separatedBy: "\n")
	#expect(lines.first == "拾字认过的照片里，字里带「发票」的有 2 张（新拍的在前）：")
	#expect(lines[1].hasPrefix("1. b.HEIC　") && lines[1].hasSuffix("　停车发票"))
	#expect(lines[2].hasPrefix("2. a.HEIC　") && lines[2].contains("增值税电子普通发票 金额 120.00"))
	#expect(lines.last?.hasPrefix("【拾字认过 2 张照片（2 张有字），最近一次 ") == true)
	#expect(lines.last?.hasSuffix("没认过的照片搜不到，另有 1 张原图在 iCloud 上、1 张出错，还没认】") == true, "\(lines.last ?? "")")

	let one = try Tools.photosSearch(["query": "发票", "limit": 1], index: path)
	#expect(one.hasPrefix("拾字认过的照片里，字里带「发票」的至少 1 张"), "满了就说「至少」")
	#expect(try Tools.photosSearch(["query": "没有这个"], index: path).hasPrefix("拾字认过的照片里，没有字里带「没有这个」的。"))

	// 走一遍 MCP：tools/call → photos_search → 库。照片库位置是全局的，测完换回去（测试一条条跑，不会撞）。
	let saved = Tools.photoIndexPath
	Tools.photoIndexPath = path
	defer { Tools.photoIndexPath = saved }
	let viaMCP = rpc(server, ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "photos_search", "arguments": ["query": "停车"]]])
	let content = ((viaMCP?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
	#expect((content.first?["text"] as? String)?.hasPrefix("拾字认过的照片里，字里带「停车」的有 1 张") == true)

	for bad: [String: Any] in [[:], ["query": " "], ["query": "x", "多余": 1]] {
		#expect(throws: (any Error).self, "参数 \(bad) 该报错") { try Tools.photosSearch(bad, index: path) }
		let r = rpc(server, ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "photos_search", "arguments": bad]])
		#expect((r?["result"] as? [String: Any])?["isError"] as? Bool == true)
	}
}

@MainActor @Test func 认一批照片跳过认过的标出没下下来的() async throws {
	let (index, _) = try tempIndex()
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	library.add("本机", .local(Fixtures.text(["本机里的一张截屏"])), created: day)
	library.add("云上", .cloud(Fixtures.text(["下载下来的原图"])), created: day.addingTimeInterval(-60))
	library.add("太慢", .slow, created: day.addingTimeInterval(-120))
	library.add("坏的", .broken, created: day.addingTimeInterval(-180))
	library.add("白纸", .local(Fixtures.canvas(600, 400).makeImage()!), created: day.addingTimeInterval(-240))
	library.add("下不来", .unreachable, created: day.addingTimeInterval(-300))
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	var options = OCROptions()
	options.usePlugins = false

	@MainActor func run(_ photos: [PhotoAsset], download: Bool, room: Bool = true) async -> [String: PhotoIndex.Record?] {
		var seen: [String: PhotoIndex.Record?] = [:]
		var finished = false
		recognizer.recognize(
			photos: photos, library: library, index: index, options: options, allowDownload: download, stop: StopFlag(),
			roomToDownload: { room }, onPhoto: { seen[$0.id] = .some($1) }, onFinish: { finished = true })
		await waitFor { finished }
		#expect(finished)
		return seen
	}

	// 下载关着：本机的认，云上的标出来。
	let first = await run(library.assetList, download: false)
	#expect(first.count == 6)
	let local = Fixtures.compact(index.record("本机")?.text ?? "")
	#expect(index.record("本机")?.status == .text && local.contains("本机里的一张截屏"))
	#expect(index.record("本机")?.name == "本机.PNG" && index.record("本机")?.taken == day)
	#expect(index.record("云上")?.status == .icloud && index.record("云上")?.problem == "原图在 iCloud 上，下载原图关着")
	#expect(index.record("太慢")?.status == .icloud && index.record("太慢")?.problem == "原图在 iCloud 上，下载原图关着")
	#expect(index.record("坏的")?.status == .failed && index.record("坏的")?.problem == "坏了")
	#expect(index.record("白纸")?.status == .empty)
	#expect(index.record("下不来")?.problem == "原图在 iCloud 上，下载原图关着")

	// 空间不够：开了下载也不下。
	_ = await run([library.assetList[1]], download: true, room: false)
	#expect(index.record("云上")?.problem == "原图在 iCloud 上，这台 Mac 剩余空间不到 3 GB，没下载")

	// 再认一遍、开了下载：认好的跳过（不再取图），没认成的重来；先把不用下载的过一遍，在 iCloud 上的最后再下。
	let before = library.log.count
	let second = await run(library.assetList, download: true)
	#expect(second["本机"] == .some(nil) && second["白纸"] == .some(nil), "认过的回调给 nil")
	#expect(Array(library.log.dropFirst(before)) == ["云上", "太慢", "坏的", "下不来", "云上↓", "太慢↓", "下不来↓"])
	#expect(index.record("太慢")?.status == .icloud && index.record("太慢")?.problem == "等了 120 秒原图还没从 iCloud 下下来，下次再认")
	#expect(index.record("下不来")?.status == .icloud && index.record("下不来")?.problem == "从 iCloud 下载原图没成：连不上 iCloud")
	#expect(index.record("云上")?.status == .text && index.record("云上")?.problem == nil)
	let downloaded = Fixtures.compact(index.record("云上")?.text ?? "")
	#expect(downloaded.contains("下载下来的原图"))

	// 照片改过（修改时间变了）就重认。
	var edited = library.assetList[0]
	edited.modified = day.addingTimeInterval(3600)
	_ = await run([edited], download: true)
	#expect(library.requestedIDs.last == "本机" && index.record("本机")?.stamp == edited.stamp)

	// 已经叫停了：一张也不认，结束照样回调。
	let stop = StopFlag()
	stop.stop()
	var finished = false
	let count = library.requestedIDs.count
	recognizer.recognize(
		photos: library.assetList, library: library, index: index, options: options, allowDownload: true, stop: stop,
		onPhoto: { _, _ in }, onFinish: { finished = true })
	await waitFor { finished }
	#expect(finished && library.requestedIDs.count == count)
}

@MainActor @Test func 连着几张下载没成就不再下() async throws {
	let (index, _) = try tempIndex()
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	for (i, id) in ["坏1", "坏2", "好1", "坏3", "坏4", "坏5", "坏6", "好2"].enumerated() {
		let kind: FakePhotoLibrary.Kind = id.hasPrefix("好") ? .cloud(Fixtures.text(["能下下来的原图"])) : .unreachable
		library.add(id, kind, created: day.addingTimeInterval(Double(-60 * i)))
	}
	library.add("本机", .local(Fixtures.text(["本机的照片"])), created: day.addingTimeInterval(-600))
	var finished = false
	var downloads: [String] = []
	var options = OCROptions()
	options.usePlugins = false
	Recognizer(engine: OCREngine(config: OCRConfig())).recognize(
		photos: library.assetList, library: library, index: index, options: options, allowDownload: true, stop: StopFlag(),
		roomToDownload: { true }, onDownloads: { downloads = $0.map(\.id) }, onPhoto: { _, _ in }, onFinish: { finished = true })
	await waitFor { finished }
	#expect(downloads == ["坏1", "坏2", "好1", "坏3", "坏4", "坏5", "坏6", "好2"], "开始下载前报一次要下哪几张")
	// 第一趟九张都不下载地取一次（排在最后的「本机」这时就认了）；第二趟下载，下成一张就重新数，连着三张没成就停。
	#expect(Array(library.log.dropFirst(9)) == ["坏1↓", "坏2↓", "好1↓", "坏3↓", "坏4↓", "坏5↓"])
	#expect(index.record("本机")?.status == .text && index.record("好1")?.status == .text)
	for id in ["坏6", "好2"] {
		#expect(index.record(id)?.status == .icloud && index.record(id)?.problem == "前面连着 3 张从 iCloud 下载都没成，这次先不下了")
	}
	#expect(index.record("坏5")?.problem == "从 iCloud 下载原图没成：连不上 iCloud")
}

@MainActor @Test func 认照片时打开的文件能插进来先认() async throws {
	let (index, _) = try tempIndex()
	let library = FakePhotoLibrary()
	library.delay = 0.2
	for i in 0..<6 { library.add("照\(i)", .local(Fixtures.text(["第\(i)张照片"])), created: Date(timeIntervalSince1970: Double(1000 - i))) }
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	var options = OCROptions()
	options.usePlugins = false
	var order: [String] = []
	var batchDone = false, fileDone = false
	recognizer.recognize(
		photos: library.assetList, library: library, index: index, options: options, allowDownload: false, stop: StopFlag(),
		onPhoto: { asset, _ in order.append(asset.id) },
		onFinish: {
			order.append("整批完")
			batchDone = true
		})
	recognizer.recognize(region: NRect(x: 0, y: 0, w: 1, h: 1), in: Fixtures.text(["插进来的文件"]), options: options) { _ in
		order.append("文件")
		fileDone = true
	}
	await waitFor { batchDone && fileDone }
	let file = order.firstIndex(of: "文件") ?? .max
	#expect(file <= 1, "最多等一张照片认完，不用等整批：\(order)")
}

@MainActor @Test func 照片那一节认一个相簿() async throws {
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	library.add("一", .local(Fixtures.text(["第一张截屏里的字"])), created: day)
	library.add("二", .local(Fixtures.canvas(300, 200).makeImage()!), created: day.addingTimeInterval(-60))
	library.add("云", .unreachable, created: day.addingTimeInterval(-120))
	let path = Fixtures.tempURL("sqlite").path
	// 「二」先前认过、没有字。
	try PhotoIndex(path: path).upsert(PhotoIndex.Record(id: "二", stamp: library.assetList[1].stamp, status: .empty))
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: recognizer)
	await waitFor { !photos.albums.isEmpty }
	let ws = Workspace(recognizer: recognizer, photos: photos)
	ws.showFirstAlbum()
	#expect(ws.selectedAlbumID == "all" && ws.selectedID == nil && photos.assets.map(\.id) == ["一", "二", "云"])
	#expect(photos.counts == AlbumCounts(total: 3, recognized: 1))
	#expect(photos.subtitle == "3 张：认过 1 张（0 张有字），2 张还没认")
	#expect(photos.describe(library.assetList[1]) == "认过，没有字" && photos.describe(library.assetList[0]) == "还没认")
	#expect(ws.canRecognize && !ws.canStop)

	// ⌘R：只认没认过的两张；下载默认开着，「云」下不来。
	ws.recognizeSelection()
	#expect(photos.run?.total == 2 && photos.subtitle == "正在识别：0 / 2 张" && ws.canStop && !ws.canRecognize)
	await waitFor { photos.run == nil }
	#expect(photos.counts == AlbumCounts(total: 3, recognized: 2, withText: 1, inCloud: 1))
	#expect(photos.subtitle == "3 张：认过 2 张（1 张有字），1 张原图在 iCloud 上没下下来")
	#expect(photos.describe(library.assetList[2]) == "从 iCloud 下载原图没成：连不上 iCloud")

	// 照片改过：算没认过。
	library.touch("一")
	photos.reloadAlbum()
	#expect(photos.counts.notYet == 1 && photos.describe(library.assetList[0]) == "照片改过，要重新认")

	// 缩略图：格子露出来才取，滚出去就放掉。
	photos.cellAppeared(library.assetList[0])
	await waitFor { photos.thumbnails["一"] != nil }
	photos.cellDisappeared("一")
	#expect(photos.thumbnails.isEmpty)
	// SwiftUI 重建网格时新格子先「露出来」、旧格子后「收起来」：缩略图要留着（刚打开拾字点相簿整片空白就是这个）。
	photos.cellAppeared(library.assetList[0])
	await waitFor { photos.thumbnails["一"] != nil }
	photos.cellAppeared(library.assetList[0])
	photos.cellDisappeared("一")
	#expect(photos.thumbnails["一"] != nil, "还有一格在显示它")
	photos.cellDisappeared("一")
	#expect(photos.thumbnails.isEmpty, "都收起来了才放掉")
	// 换到也有这一张的相簿：那一格留着、不会再「露出来」一次，缩略图得留着；换到没有它的相簿才放掉。
	photos.cellAppeared(library.assetList[0])
	photos.cellAppeared(library.assetList[1])
	await waitFor { photos.thumbnails.count == 2 }
	ws.selection = .album("部分")
	#expect(photos.thumbnails.keys.sorted() == ["一"] && photos.assets.map(\.id) == ["一"])

	// 选中：点一张、⌘ 点加选、再 ⌘ 点去掉；换相簿就清掉。
	ws.selection = .album("all")
	photos.click("一", extend: false)
	photos.click("二", extend: true)
	photos.click("云", extend: true)
	photos.click("二", extend: true)
	#expect(photos.selection == ["一", "云"])
	ws.selection = .album("空的")
	#expect(photos.selection.isEmpty && photos.assets.isEmpty && photos.thumbnails.isEmpty && !ws.canRecognize)
}

@MainActor @Test func 左栏选文件还是相簿() throws {
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	let ws = Workspace(
		recognizer: recognizer, photos: PhotosModel(library: FakePhotoLibrary(), indexPath: Fixtures.tempURL("sqlite").path, recognizer: recognizer))
	let doc = try DocumentModel(url: URL(fileURLWithPath: Fixtures.save(Fixtures.text(["一个文件"]))), recognizer: recognizer)
	ws.add(doc, start: false)
	#expect(ws.selection == .document(doc.id) && ws.selected === doc && ws.selectedAlbumID == nil)
	ws.selection = .album("all")
	#expect(ws.selected == nil && ws.selectedID == nil && ws.selectedAlbumID == "all")
	ws.selectedID = doc.id
	#expect(ws.selection == .document(doc.id))
}

@Test func 照片图库的错说成大白话() {
	let network = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.networkError.rawValue)
	#expect(SystemPhotoLibrary.describe(network) == "网络出错，连不上 iCloud")
	#expect(SystemPhotoLibrary.describe(NSError(domain: "别的", code: 7))?.hasSuffix("（别的 7）") == true)
	#expect(SystemPhotoLibrary.describe(nil) == nil)
}

@Test func 取图的回调和超时只算一次() {
	let late = ImageTicket()
	#expect(late.wait(0.05) == nil, "没回调就是超时")
	late.finish(.inCloud(nil))
	#expect(late.wait(0) != nil, "超时以后来的回调不算数")
	if case .timedOut? = late.wait(0) {} else { Issue.record("超时以后该一直是超时") }

	let ticket = ImageTicket()
	ticket.finish(.inCloud(nil))
	ticket.finish(.failed("第二次"))
	if case .inCloud? = ticket.wait(1) {} else { Issue.record("只认第一次回调") }
}

@Test func 自检拿来搜的一小段字() {
	#expect(PhotoCheck.sample("短 一段很长的字在这里 尾") == "很长的字")
	#expect(PhotoCheck.sample("ab") == "ab" && PhotoCheck.sample(" \n ") == nil)
}

@Test func 照片改过印记就变() {
	let a = PhotoAsset(id: "x", created: nil, modified: Date(timeIntervalSince1970: 10), pixelWidth: 100, pixelHeight: 50)
	var b = a
	#expect(a.stamp == b.stamp)
	b.modified = Date(timeIntervalSince1970: 11)
	#expect(a.stamp != b.stamp)
	b = a
	b.pixelWidth = 50
	b.pixelHeight = 100
	#expect(a.stamp != b.stamp, "转过、裁过的尺寸也算")
	#expect(a.stamp.hasSuffix("|r\(PhotoIndex.revision)"))
}

@MainActor @Test func 按字搜认过的照片() async throws {
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	library.add("新", .local(Fixtures.text(["新"])), created: day)
	library.add("旧", .local(Fixtures.text(["旧"])), created: day.addingTimeInterval(-60))
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	try index.upsert(photo("新", "停车发票 ¥15.00", taken: day.timeIntervalSince1970))
	try index.upsert(photo("旧", "增值税电子普通发票", taken: day.timeIntervalSince1970 - 60))
	// 库里有、照片图库里已经删了的：不列。
	try index.upsert(photo("删了的", "作废的发票", taken: day.timeIntervalSince1970 + 60))
	try index.upsert(photo("没字", "", taken: 0, status: .empty))
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: recognizer)
	await waitFor { !photos.albums.isEmpty }
	photos.show(album: "部分")
	photos.click("新", extend: false)
	#expect(!photos.isSearching)

	photos.searchText = " 发票 "
	photos.search()
	#expect(photos.isSearching && photos.searchHits.map(\.id) == ["新", "旧"], "搜的是认过的全部照片，不只正在看的相簿")
	#expect(photos.searchSubtitle == "认过的 4 张照片里，带「发票」的有 2 张")
	#expect(photos.selection == ["新"], "选中的还在结果里就留着")
	photos.searchText = "停车"
	#expect(!photos.searchIsCurrent && photos.searchSubtitle.isEmpty, "还没按新的字搜：别说找到几张、更别说「没有」")
	photos.search()
	#expect(photos.searchIsCurrent && photos.searchHits.map(\.id) == ["新"])
	photos.searchText = "没有这个"
	photos.search()
	#expect(photos.searchHits.isEmpty && photos.selection.isEmpty && photos.searchSubtitle.isEmpty)
	photos.searchText = ""
	photos.search()
	#expect(!photos.isSearching && photos.searchHits.isEmpty)

	// 搜着的时候在左栏点了别的相簿：搜的收起来，看那个相簿。
	photos.searchText = "发票"
	photos.search()
	photos.show(album: "all")
	#expect(!photos.isSearching && photos.searchHits.isEmpty && photos.searchedQuery == nil)
}

@Test func 搜到的词用主色() {
	let text = PhotoHitRow.highlighted("…明天在会议 室见面…", query: "会议室 见面")
	let strong = text.runs.filter { $0.foregroundColor == .primary }.map { String(text[$0.range].characters) }
	#expect(strong == ["会议 室"], "只标第一个词，字之间夹空白也认得：\(strong)")
	#expect(text.runs.contains { $0.foregroundColor == .secondary })
}

@MainActor @Test func 在相簿里点开一张看() async throws {
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	library.add("票", .local(Fixtures.text(["打开来看的一张票据"])), created: day)
	library.add("云", .unreachable, created: day.addingTimeInterval(-60))
	for i in 1...4 { library.add("图\(i)", .local(Fixtures.text(["第\(i)张"])), created: day.addingTimeInterval(Double(-120 * i))) }
	let path = Fixtures.tempURL("sqlite").path
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: recognizer)
	await waitFor { !photos.albums.isEmpty }
	let ws = Workspace(recognizer: recognizer, photos: photos)
	ws.showFirstAlbum()
	let ticket = library.assetList[0]

	// 点开：右边换成这一张、网格上选中它；不进左栏。跟文件一样认（用照片的选项，插件默认不用），认完字存进照片库。
	ws.openPhoto(ticket)
	#expect(photos.path == [PhotoRoute(id: "票")] && photos.selection == ["票"] && photos.position?.index == 0)
	await waitFor { photos.viewed["票"].map { !$0.isRunning } ?? false }
	let doc = try #require(photos.viewed["票"])
	#expect(doc.name == "票.PNG" && ws.documents.isEmpty && ws.activeDocument === doc && !doc.options.usePlugins)
	await waitFor { photos.status(of: ticket) == .text }
	let saved = Fixtures.compact(try PhotoIndex(path: path, readOnly: true).record("票")?.text ?? "")
	#expect(saved.contains("打开来看的一张票据"))
	#expect(ws.canRecognize && ws.activeDocument?.photo?.id == "票", "点开照片时 ⌘R 是重新识别这一张")

	// 下一张：原图在 iCloud 上、下不下来，就地说清楚；网格的选中跟着走，回网格时滚到它。
	#expect(!photos.canStep(-1) && photos.canStep(1))
	photos.step(1)
	#expect(photos.viewingID == "云" && photos.selection == ["云"] && photos.returnTo == "云")
	await waitFor { photos.viewProblems["云"] != nil }
	#expect(photos.viewProblems["云"] == "原图在 iCloud 上，没下下来：连不上 iCloud" && photos.problem == nil)

	// 回到上一张：用留着的，不再取图、不再认。
	let requests = library.requestedIDs.count
	photos.step(-1)
	#expect(photos.viewed["票"] === doc && library.requestedIDs.count == requests)

	// 一路翻下去：只留最近 4 张。
	for _ in 0..<5 { photos.step(1) }
	await waitFor { photos.viewed.count >= 4 && !photos.viewed.values.contains { $0.isRunning } }
	#expect(photos.viewingID == "图4" && photos.viewed.count <= PhotosModel.viewedLimit && photos.viewed["图4"] != nil)

	// 返回：回网格，选中的是最后看的那张。
	photos.back()
	#expect(photos.path.isEmpty && photos.selection == ["图4"] && ws.activeDocument == nil)

	// 换相簿：点开的收起来。
	photos.view(ticket)
	ws.selection = .album("空的")
	#expect(photos.path.isEmpty)

	// 新相簿名字空着：说一句，不建。
	photos.newAlbumItems = [ticket]
	photos.newAlbumName = "  "
	photos.confirmNewAlbum()
	#expect(photos.problem == "相簿要有个名字。" && photos.newAlbumItems == nil && library.addLog.isEmpty)
}

@MainActor @Test func 选几张加进相簿() async throws {
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	for (i, id) in ["一", "二", "三"].enumerated() {
		library.add(id, .local(Fixtures.text(["第\(id)张"])), created: day.addingTimeInterval(Double(-60 * i)))
	}
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	try index.upsert(photo("二", "停车发票", taken: day.timeIntervalSince1970 - 60))
	try index.upsert(photo("三", "出租车发票", taken: day.timeIntervalSince1970 - 120))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	await waitFor { !photos.albums.isEmpty }

	// 网格里选两张，加进已有的相簿。正在看的「全部」不能加（不是自己建的），列的是自己建的两个。
	photos.show(album: "all")
	photos.click("二", extend: false)
	photos.click("三", extend: true)
	#expect(photos.selectedAssets.map(\.id) == ["二", "三"] && photos.addableAlbums.map(\.title) == ["部分", "空的"])
	photos.add(photos.selectedAssets, to: .existing("空的"))
	await waitFor { photos.albums.first { $0.id == "空的" }?.count == 2 }
	#expect(library.addLog == ["空的 ← 二,三"])

	// 加进正在看的相簿：网格跟着变；正在看的相簿不在「加进相簿」里。
	photos.show(album: "部分")
	#expect(!photos.addableAlbums.contains { $0.id == "部分" })
	photos.add([library.assetList[2]], to: .existing("部分"))
	await waitFor { photos.assets.count == 2 }
	#expect(photos.assets.map(\.id) == ["一", "三"])

	// 新建相簿：左栏冒出来，是能往里加的普通相簿。
	photos.add([library.assetList[0]], to: .new("发票"))
	await waitFor { photos.albums.contains { $0.title == "发票" } }
	let created = try #require(photos.albums.first { $0.title == "发票" })
	#expect(created.count == 1 && created.canAdd && created.kind == .album)

	// 没成：说一句。
	photos.add([library.assetList[0]], to: .new("坏"))
	await waitFor { photos.problem != nil }
	#expect(photos.problem == "没加进相簿：照片图库没接受")

	// 搜的时候：选中的是搜出来的那几张，⌘A 全选的也是；正在看的相簿也能加（结果不只这个相簿的）。
	photos.searchText = "发票"
	photos.search()
	photos.selectAll()
	#expect(photos.selectedAssets.map(\.id) == ["二", "三"] && photos.addableAlbums.contains { $0.id == "部分" })
}
