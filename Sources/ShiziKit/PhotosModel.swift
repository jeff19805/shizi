import AppKit
import Observation
import OCRCore

/// 一批照片认到哪了。
public struct PhotoRun: Equatable {
	/// 认的是哪个相簿。
	public let albumID: String
	/// 这批要认几张（认过、没改过的不算在里面）。
	public let total: Int
	/// 认完了（含没认成的）几张。
	public var done = 0
	/// 第二趟要从 iCloud 下载原图的（编号），开始下载时才知道。
	public var downloads: [String] = []
	/// 认完了的编号：网格上「等着下载」的角标靠它撤掉。
	public var finished: Set<String> = []
	public var stopping = false

	public var isDownloading: Bool { !downloads.isEmpty }
	/// 下载这一趟认完了几张。
	public var downloaded: Int { downloads.filter { finished.contains($0) }.count }
}

/// 按字搜出来的一张。
public struct PhotoHit: Identifiable, Equatable {
	public let asset: PhotoAsset
	public let record: PhotoIndex.Record
	public var id: String { asset.id }
}

/// 在相簿里点开的一张（导航路径里放它）。
public struct PhotoRoute: Hashable {
	public let id: String
}

/// 一个相簿里的照片认到什么程度：页头那句话和「识别」按钮用。
public struct AlbumCounts: Equatable {
	public var total = 0
	/// 认过的（有字、没字都算）。
	public var recognized = 0
	public var withText = 0
	/// 原图在 iCloud 上、还没认成的。
	public var inCloud = 0
	public var failed = 0

	/// 还没认过的（含照片改过的）。
	public var notYet: Int { total - recognized - inCloud - failed }
	/// 点「识别」会认的：除了认过的都认。
	public var todo: Int { total - recognized }
}

/// 「照片」那一节：照片权限、相簿、正在看的相簿里的照片和它们认没认过、一批照片认到哪了。
@MainActor @Observable
public final class PhotosModel {
	public private(set) var access: PhotoAccess
	public private(set) var albums: [PhotoAlbum] = []
	/// 正在看的相簿。
	public private(set) var albumID: String?
	/// 正在看的相簿里的照片，新拍的在前。
	public private(set) var assets: [PhotoAsset] = []
	/// 库里每张的简况（编号 → 简况）。
	public private(set) var briefs: [String: PhotoIndex.Brief] = [:]
	/// 网格里看得见的那些照片的缩略图；滚出去的就放掉，几千张的相簿也只占几十 MB。
	public private(set) var thumbnails: [String: CGImage] = [:]
	/// 网格里选中的照片。
	public var selection: Set<String> = []
	/// 正在认的一批；没在认是 nil。
	public private(set) var run: PhotoRun?
	/// 顶上搜索框里的字；空的时候看相簿。
	public var searchText = ""
	/// 按字搜出来的，新拍的在前，最多 `searchLimit` 张。
	public private(set) var searchHits: [PhotoHit] = []
	/// `searchHits` 是按哪几个字搜的：打字停一下才搜，这之间结果还是上一次的。
	public private(set) var searchedQuery: String?
	/// 出了事说一句（弹出提示用），看过就清掉。
	public var problem: String?

	@ObservationIgnored let library: PhotoLibrary
	@ObservationIgnored let indexPath: String
	@ObservationIgnored let recognizer: Recognizer
	@ObservationIgnored var stopFlag: StopFlag?
	@ObservationIgnored var openedIndex: PhotoIndex?
	/// 网格里正露着的格子：编号 → 有几格在显示它。缩略图到的时候已经一格都没有了，就不要了。
	/// 记个数、不记有没有：SwiftUI 重建网格时，新格子的「露出来」常常先于旧格子的「收起来」，只记有没有的话，
	/// 旧格子一收就把新格子的缩略图也放掉了，刚打开拾字点相簿时会整片空白。
	@ObservationIgnored var visible: [String: Int] = [:]

	/// 格子约 120–200 点，按 2 倍屏要的像素。
	static let thumbnailPixels = 360

	// MARK: 分类的状态（怎么分在 PhotoClassify.swift）

	/// 正在用的分类规矩：上次分类用的那套（存在设置里）；还没分过类是 nil。
	public internal(set) var classifyRules: ClassifyRules?
	/// 按正在用的规矩分过的照片：编号 → 分数。
	public internal(set) var classifyScores: [String: PhotoIndex.Scores] = [:]
	/// 正在分类的一批；没在分是 nil。
	public internal(set) var classifyRun: ClassifyProgress?
	/// 网格只看这一类（分类结果里的名字，或「没有字」）；nil 是全部。
	public var labelFilter: String?
	@ObservationIgnored var classifyStop: StopFlag?
	/// 分类的设置存在哪（测试里换成临时的，不碰真的偏好）。
	@ObservationIgnored let defaults: UserDefaults

	public init(
		library: PhotoLibrary = SystemPhotoLibrary.shared, indexPath: String = PhotoIndex.defaultPath, recognizer: Recognizer = .shared,
		defaults: UserDefaults = .standard
	) {
		self.library = library
		self.indexPath = indexPath
		self.recognizer = recognizer
		self.defaults = defaults
		access = library.access()
		if access == .granted { reloadAlbums() }
	}

	/// 照片库：头一次用到时才打开（没有就建）。
	var index: PhotoIndex? {
		if openedIndex == nil {
			do {
				openedIndex = try PhotoIndex(path: indexPath)
			} catch {
				problem = "照片库打不开：\(error)"
			}
		}
		return openedIndex
	}

	// MARK: 权限和相簿

	/// 弹系统的「允许访问照片」；允许了就列相簿，再调 `then`。
	public func requestAccess(then: @escaping @MainActor () -> Void = {}) {
		library.requestAccess { access in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.access = access
					guard access == .granted else { return }
					self.reloadAlbums(then: then)
				}
			}
		}
	}

	/// 在系统设置里改了权限、再切回拾字时看一眼。
	public func refreshAccess() {
		let now = library.access()
		guard now != access else { return }
		access = now
		if now == .granted { reloadAlbums() }
	}

	/// 列相簿放到后台：要数每个相簿里有几张，相簿多了要花点时间，不让窗口卡这一下。
	public func reloadAlbums(then: @escaping @MainActor () -> Void = {}) {
		let library = library
		DispatchQueue.global(qos: .userInitiated).async {
			let albums = library.albums()
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.albums = albums
					then()
				}
			}
		}
	}

	public var album: PhotoAlbum? { albums.first { $0.id == albumID } }

	/// 看一个相簿：列出里面的照片（很快，就在主线程上列），读一遍库里的简况。
	public func show(album id: String) {
		guard id != albumID else { return }
		albumID = id
		selection = []
		path = []
		returnTo = nil
		// 在左栏点了别的相簿，就是要看那个相簿：搜的收起来。
		searchText = ""
		searchHits = []
		searchedQuery = nil
		assets = library.assets(in: id)
		// 两个相簿共有的照片（截屏也都在「最近项目」里），网格里那一格会留着、不再「露出来」一次：
		// 只放掉新相簿里没有的，共有的缩略图留着，不然它们一直是灰的。
		let ids = Set(assets.map(\.id))
		thumbnails = thumbnails.filter { ids.contains($0.key) }
		visible = visible.filter { ids.contains($0.key) }
		labelFilter = nil
		refreshBriefs()
		loadClassification()
	}

	/// 重新列一遍正在看的相簿（照片可能改过、删过），选中的还在的留着。
	public func reloadAlbum() {
		guard let albumID else { return }
		assets = library.assets(in: albumID)
		selection.formIntersection(assets.map(\.id))
		refreshBriefs()
		loadClassification()
	}

	func refreshBriefs() {
		briefs = index?.briefs() ?? [:]
	}

	// MARK: 认没认过

	/// 这张在库里的状态；照片改过（改动标记对不上）算没认过，给 nil。
	public func status(of asset: PhotoAsset) -> PhotoIndex.Status? {
		guard let b = briefs[asset.id], b.stamp == asset.stamp else { return nil }
		return b.status
	}

	public func problem(of asset: PhotoAsset) -> String? {
		guard let b = briefs[asset.id], b.stamp == asset.stamp else { return nil }
		return b.problem
	}

	/// 认过了（有字、没字）：再点「识别」也跳过。
	func isDone(_ asset: PhotoAsset) -> Bool {
		let s = status(of: asset)
		return s == .text || s == .empty
	}

	public var counts: AlbumCounts {
		var c = AlbumCounts(total: assets.count)
		for asset in assets {
			switch status(of: asset) {
			case .text?:
				c.recognized += 1
				c.withText += 1
			case .empty?: c.recognized += 1
			case .icloud?: c.inCloud += 1
			case .failed?: c.failed += 1
			case nil: break
			}
		}
		return c
	}

	/// 页头标题下面那句：在认就说认到哪了，不在认就说这个相簿认到什么程度。认完不另外报喜。
	public var subtitle: String {
		if let run, run.albumID == albumID {
			if run.stopping { return "正在停……" }
			if run.isDownloading {
				let first = run.downloaded == 0 ? "，头一张可能要等一两分钟" : ""
				return "正在从 iCloud 下载原图来认：第 \(min(run.downloaded + 1, run.downloads.count)) / \(run.downloads.count) 张\(first)"
			}
			return "正在识别：\(run.done) / \(run.total) 张"
		}
		let c = counts
		guard c.total > 0 else { return "" }
		guard c.recognized + c.inCloud + c.failed > 0 else { return "\(c.total) 张，都还没认" }
		var parts = ["认过 \(c.recognized) 张（\(c.withText) 张有字）"]
		if c.inCloud > 0 { parts.append("\(c.inCloud) 张原图在 iCloud 上没下下来") }
		if c.failed > 0 { parts.append("\(c.failed) 张出错") }
		if c.notYet > 0 { parts.append("\(c.notYet) 张还没认") }
		return "\(c.total) 张：" + parts.joined(separator: "，")
	}

	// MARK: 认一批

	/// 认正在看的相簿里还没认过的（认过、没改过的跳过）。同一时间只认一批。
	public func recognizeAlbum() {
		guard run == nil, let albumID, let index else { return }
		let todo = assets.filter { !isDone($0) }
		guard !todo.isEmpty else { return }
		let flag = StopFlag()
		stopFlag = flag
		run = PhotoRun(albumID: albumID, total: todo.count)
		recognizer.recognize(
			photos: todo, library: library, index: index, options: RecognitionDefaults.photoOptions(),
			allowDownload: RecognitionDefaults.downloadOriginals(), stop: flag,
			onDownloads: { [weak self] assets in self?.run?.downloads = assets.map(\.id) },
			onPhoto: { [weak self] asset, record in
				guard let self, self.stopFlag === flag else { return }
				self.run?.done += 1
				self.run?.finished.insert(asset.id)
				if let record { self.briefs[asset.id] = PhotoIndex.Brief(stamp: record.stamp, status: record.status, problem: record.problem) }
			},
			onFinish: { [weak self] in
				guard let self, self.stopFlag === flag else { return }
				self.run = nil
				self.stopFlag = nil
				self.refreshBriefs()
			})
	}

	public func stop() {
		guard run != nil else { return }
		stopFlag?.stop()
		run?.stopping = true
	}

	/// 这张正排着等下载（网格上标出来）。
	public func isWaitingForDownload(_ asset: PhotoAsset) -> Bool {
		guard let run, run.downloads.contains(asset.id) else { return false }
		return !run.finished.contains(asset.id)
	}

	// MARK: 按字搜

	/// 一次最多列这么多张：搜「的」这种字会命中几千张，列多了没法看，也慢。
	static let searchLimit = 200

	public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

	/// 结果是不是按搜索框里现在的字搜的。不是的时候别说「没有」：刚打了一个字、还没搜，会闪一下「没有」。
	public var searchIsCurrent: Bool { searchedQuery == searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

	/// 在认过的全部照片里按字找（不只正在看的相簿）；照片图库里已经删了的不列。选中的只留还在结果里的。
	public func search() {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty, let index else {
			searchHits = []
			searchedQuery = nil
			return
		}
		searchedQuery = query
		let records = index.search(query, limit: Self.searchLimit)
		let assets = Dictionary(library.assets(ids: records.map(\.id)).map { ($0.id, $0) }) { a, _ in a }
		searchHits = records.compactMap { r in assets[r.id].map { PhotoHit(asset: $0, record: r) } }
		selection.formIntersection(searchHits.map(\.id))
	}

	/// 认过的有几张（有字、没字都算）：搜的范围。
	public var recognizedCount: Int { briefs.values.filter { $0.status == .text || $0.status == .empty }.count }

	/// 搜的时候页头那句：在多少张里找、找到几张。一张没找到时不说（中间已经写了「没有」，别一屏说两遍）。
	public var searchSubtitle: String {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		let n = searchHits.count
		if n == 0 || !searchIsCurrent { return "" }
		if n >= Self.searchLimit { return "认过的 \(recognizedCount) 张照片里，带「\(query)」的至少 \(n) 张，只列最新的 \(n) 张" }
		return "认过的 \(recognizedCount) 张照片里，带「\(query)」的有 \(n) 张"
	}

	// MARK: 在相簿里点开一张

	/// 在相簿里点开看的照片：网格 → 这一张（左上角返回回网格）。空的时候看网格。
	public var path: [PhotoRoute] = []
	/// 点开看过的照片：编号 → 一份认出来的。来回翻不用重认；只留最近 `viewedLimit` 张（大照片一张要几十 MB）。
	public private(set) var viewed: [String: DocumentModel] = [:]
	/// 取图没成的：编号 → 为什么。
	public private(set) var viewProblems: [String: String] = [:]
	/// 翻到别的照片以后回网格：网格滚到这一张。
	public var returnTo: String?
	@ObservationIgnored var viewedOrder: [String] = []
	@ObservationIgnored var fetching: Set<String> = []

	/// 留 4 张：上一张、这一张、下一张，再多一张来回的余地。大照片认的时候一张就占不少内存。
	static let viewedLimit = 4

	public var viewingID: String? { path.last?.id }
	public var viewingDocument: DocumentModel? { viewingID.flatMap { viewed[$0] } }

	/// 翻张的顺序：搜的时候是搜出来的那些，不然是相簿里的。
	var browseList: [PhotoAsset] { isSearching ? searchHits.map(\.asset) : shownAssets }

	/// 在相簿里点开一张：右边换成这一张，没看过的取图来认。网格上它跟着选中。
	public func view(_ asset: PhotoAsset) {
		selection = [asset.id]
		path = [PhotoRoute(id: asset.id)]
		load(asset)
	}

	/// 正在看第几张（从 0 数）、一共几张。
	public var position: (index: Int, count: Int)? {
		guard let id = viewingID, let i = browseList.firstIndex(where: { $0.id == id }) else { return nil }
		return (i, browseList.count)
	}

	public func canStep(_ delta: Int) -> Bool {
		guard let p = position else { return false }
		return browseList.indices.contains(p.index + delta)
	}

	/// 翻到上一张（-1）或下一张（+1）：换掉正在看的这一张，返回时还是回网格，网格滚到最后看的那张。
	public func step(_ delta: Int) {
		guard let p = position, browseList.indices.contains(p.index + delta) else { return }
		let asset = browseList[p.index + delta]
		returnTo = asset.id
		view(asset)
	}

	/// 回网格。
	public func back() {
		path = []
	}

	/// 取图来认：放到后台取（原图在 iCloud 上的要下载，下载开关跟「识别」一样）。看过、照片没改过的直接用留着的。
	/// 库里只存了字，原图上的框要现认。认完把字存进照片库，跟「识别」存的一样。
	func load(_ asset: PhotoAsset) {
		if let doc = viewed[asset.id], doc.photo?.stamp == asset.stamp {
			remember(asset.id)
			return
		}
		guard !fetching.contains(asset.id) else { return }
		fetching.insert(asset.id)
		viewProblems[asset.id] = nil
		let library = library
		let allowDownload = RecognitionDefaults.downloadOriginals() && Recognizer.enoughSpaceForDownload()
		DispatchQueue.global(qos: .userInitiated).async {
			let image = library.image(
				for: asset, maxPixel: Recognizer.photoMaxPixel, allowDownload: allowDownload, timeout: Recognizer.downloadTimeout)
			let filename = library.filename(for: asset)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.fetching.remove(asset.id)
					switch image {
					case .image(let image):
						let doc = DocumentModel(image: image, name: filename ?? Self.photoName(asset), photo: asset, recognizer: self.recognizer)
						doc.onFinished = { [weak self] doc in self?.save(doc, filename: filename) }
						self.viewed[asset.id] = doc
						self.remember(asset.id)
						doc.start()
						doc.loadPageImage(force: true)
					case .inCloud(let reason):
						self.viewProblems[asset.id] =
							allowDownload ? "原图在 iCloud 上，没下下来：\(reason ?? "系统没说原因")" : "原图在 iCloud 上，设置里关了下载原图（或这台 Mac 剩余空间不到 3 GB）。"
					case .timedOut: self.viewProblems[asset.id] = "等了 \(Int(Recognizer.downloadTimeout)) 秒原图还没从 iCloud 下下来，过一会儿再试。"
					case .failed(let message): self.viewProblems[asset.id] = message
					}
				}
			}
		}
	}

	/// 再取一次（取图没成时）。
	public func retry(_ id: String) {
		guard let asset = browseList.first(where: { $0.id == id }) ?? library.assets(ids: [id]).first else { return }
		load(asset)
	}

	/// 记下最近看过的；多出来的放掉（正在看的不放）。
	func remember(_ id: String) {
		viewedOrder.removeAll { $0 == id }
		viewedOrder.append(id)
		while viewedOrder.count > Self.viewedLimit, let oldest = viewedOrder.first(where: { $0 != viewingID }) {
			viewedOrder.removeAll { $0 == oldest }
			viewed[oldest]?.stop()
			viewed[oldest] = nil
		}
	}

	/// 没有文件名时，用拍摄时间起个名。
	static func photoName(_ asset: PhotoAsset) -> String {
		guard let date = asset.created else { return "照片" }
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy-MM-dd HH.mm"
		return "照片 \(f.string(from: date))"
	}

	/// 打开看过的照片认完了：把字存进照片库（跟「识别」存的一样），按字搜得到，网格上也算认过。
	func save(_ doc: DocumentModel, filename: String?) {
		guard let asset = doc.photo, let page = doc.results[1], let index else { return }
		let base = PhotoIndex.Record(id: asset.id, stamp: asset.stamp, status: .failed, name: filename, taken: asset.created)
		let record = Recognizer.recognized(base, page: page)
		try? index.upsert(record)
		briefs[asset.id] = PhotoIndex.Brief(stamp: record.stamp, status: record.status)
	}

	// MARK: 网格

	public func cellAppeared(_ asset: PhotoAsset) {
		visible[asset.id, default: 0] += 1
		guard thumbnails[asset.id] == nil else { return }
		library.thumbnail(for: asset, pixels: Self.thumbnailPixels) { [weak self] image in
			guard let self, let image, self.visible[asset.id] != nil else { return }
			self.thumbnails[asset.id] = image
		}
	}

	/// 一格收起来：显示它的格子一个都不剩了才放掉缩略图。
	public func cellDisappeared(_ id: String) {
		guard let n = visible[id] else { return }
		if n > 1 {
			visible[id] = n - 1
		} else {
			visible[id] = nil
			thumbnails[id] = nil
		}
	}

	/// 点一张：选中它；按着 ⌘ 点是加选或去掉。
	public func click(_ id: String, extend: Bool) {
		if extend {
			if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
		} else {
			selection = [id]
		}
	}

	public func selectAll() {
		selection = Set(browseList.map(\.id))
	}

	// MARK: 加进相簿

	/// 要放进新相簿的那几张（问名字的时候），和问的时候默认的名字。
	public var newAlbumItems: [PhotoAsset]?
	public var newAlbumName = ""

	/// 问新相簿叫什么：在搜的时候默认就叫搜的字（搜「发票」、全选、放进新相簿，就有了一个「发票」相簿）。
	public func askNewAlbum(_ items: [PhotoAsset], name: String? = nil) {
		newAlbumName = name ?? (isSearching ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : "")
		newAlbumItems = items
	}

	/// 问名字那一步点了「新建」：名字空着就说一句，别不声不响地关掉。
	public func confirmNewAlbum() {
		let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
		if let items = newAlbumItems {
			if name.isEmpty { problem = "相簿要有个名字。" } else { add(items, to: .new(name)) }
		}
		newAlbumItems = nil
	}

	/// 选中的照片（网格里的，或搜出来的），按列着的顺序。
	public var selectedAssets: [PhotoAsset] {
		browseList.filter { selection.contains($0.id) }
	}

	/// 能往里加的相簿：自己建的普通相簿；正在看的那个不列（加了也是白加）。
	public var addableAlbums: [PhotoAlbum] {
		albums.filter { $0.canAdd && (isSearching || $0.id != albumID) }
	}

	/// 把照片加进相簿。加完重列相簿（张数变了、新建的冒出来）；正在看的就是那个相簿的，照片也重列。
	public func add(_ items: [PhotoAsset], to target: AlbumTarget) {
		guard !items.isEmpty else { return }
		library.add(items, to: target) { [weak self] problem in
			guard let self else { return }
			if let problem {
				self.problem = "没加进相簿：\(problem)"
				return
			}
			self.reloadAlbums()
			if case .existing(let id) = target, id == self.albumID { self.reloadAlbum() }
		}
	}
}
