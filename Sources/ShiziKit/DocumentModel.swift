import AppKit
import Observation
import OCRCore
import UniformTypeIdentifiers

/// 打开的一个文件（或一张粘贴进来的图）：一页一页认，认完的页随时能看、能复制。
@MainActor @Observable
public final class DocumentModel: Identifiable {
	public enum State: Equatable {
		case running, done, stopped
		case failed(String)
	}

	public let id = UUID()
	public let name: String
	public let isPDF: Bool
	public let totalPages: Int
	/// 认完的页：页码 → 结果。
	public private(set) var results: [Int: PageResult] = [:]
	/// 认不了的页：页码 → 一句话说怎么了。
	public private(set) var failures: [Int: String] = [:]
	public private(set) var state: State = .running
	/// 正在看的页。
	public private(set) var page = 1
	/// 点页码、菜单跳页的次数。滚动和点原图只改当前页，不反过来要求中栏再滚一次。
	public private(set) var pageNavigation = 0
	/// 逐行里选中的那一行（当前页 lines 的下标），原图上那一行的框跟着亮。
	public var selectedLine: Int?
	/// 原图那一栏里每页的图（给人看的大小），后台画好再放进来。只留露着的页和最近收起来的两页：
	/// 一页长边 3000 约 25 MB，几十页全留着就是好几百 MB。
	public private(set) var pageImages: [Int: CGImage] = [:]
	/// 缩略图，画过的不再画：多页时左边那一栏用，原图那一栏也先拿它顶着还没画好的页。
	public private(set) var thumbnails: [Int: CGImage] = [:]
	/// 正在看的那一页的图（还没画好是 nil）。
	public var pageImage: CGImage? { pageImages[page] }
	public var options = OCROptions()
	/// 打开的是照片图库里的一张：认用照片的选项（插件另有开关，默认不用），认完把字存进照片库、按字搜得到。
	@ObservationIgnored public private(set) var photo: PhotoAsset?
	/// 整个认完（没停、没全出错）时调一次：照片用它把字存进照片库。
	@ObservationIgnored var onFinished: (@MainActor (DocumentModel) -> Void)?

	/// 认字和画图各用一份：同一个 PDF 文件对象不在两条线程上同时画。
	@ObservationIgnored let recognitionSource: PageSource
	@ObservationIgnored let displaySource: PageSource
	@ObservationIgnored let recognizer: Recognizer
	@ObservationIgnored var stopFlag: StopFlag?
	@ObservationIgnored let drawQueue = DispatchQueue(label: "拾字.画页", qos: .userInitiated)
	/// 每页原图的大小（像素，照给人看的长边算），打开时就算好：连续滚动先按它排出每页占多高，图后画。
	@ObservationIgnored let pageSizes: [CGSize]
	/// 原图那一栏里每页露着几格。按个数记：SwiftUI 重建列表时，新格子的 onAppear 常常先于旧格子的 onDisappear。
	@ObservationIgnored var showing: [Int: Int] = [:]
	/// 收起来了、图还留着的页，先收的在前。
	@ObservationIgnored var hidden: [Int] = []
	/// 正在画（或排着等画）的页的开关：页收起来了就停掉，快速滚过去的页不白画。
	@ObservationIgnored var drawing: [Int: StopFlag] = [:]

	/// 给人看的图的长边。
	static let displayLongSide = 3000
	/// 收起来以后图还留着的页数：来回滚一两页不用重画。
	static let keptHidden = 2

	init(name: String, isPDF: Bool, recognitionSource: PageSource, displaySource: PageSource, recognizer: Recognizer) {
		self.name = name
		self.isPDF = isPDF
		self.recognitionSource = recognitionSource
		self.displaySource = displaySource
		self.recognizer = recognizer
		totalPages = recognitionSource.totalPages
		pageSizes = (1...max(totalPages, 1)).map { displaySource.pixelSize(page: $0, longSide: Self.displayLongSide) }
	}

	/// 打开一个图片或 PDF 文件。
	public convenience init(url: URL, recognizer: Recognizer = .shared) throws {
		let a = try PageSource(path: url.path), b = try PageSource(path: url.path)
		self.init(
			name: url.lastPathComponent, isPDF: a.totalPages > 1 || url.pathExtension.lowercased() == "pdf", recognitionSource: a, displaySource: b,
			recognizer: recognizer)
	}

	/// 照片图库里取来的一张图。
	public convenience init(image: CGImage, name: String, photo: PhotoAsset? = nil, recognizer: Recognizer = .shared) {
		self.init(
			name: name, isPDF: false, recognitionSource: PageSource(image: image, name: name), displaySource: PageSource(image: image, name: name),
			recognizer: recognizer)
		self.photo = photo
	}

	/// 内存里的图片或 PDF（粘贴进来的）。
	public convenience init(data: Data, name: String, recognizer: Recognizer = .shared) throws {
		let a = try PageSource(data: data, name: name), b = try PageSource(data: data, name: name)
		self.init(name: name, isPDF: data.starts(with: Data("%PDF-".utf8)), recognitionSource: a, displaySource: b, recognizer: recognizer)
	}

	// MARK: 认字

	/// 从头认（已经认过的页先清掉），用设置页里当时的默认选项。
	public func start() {
		options = photo != nil ? RecognitionDefaults.photoOptions() : RecognitionDefaults.options()
		stopFlag?.stop()
		// 上一遍拉正过的页，留着的是拉正后的图：换回原图（这一遍不一定还拉正）。
		let rectified = results.filter { $0.value.rectifiedImage != nil }.map(\.key)
		results = [:]
		for n in rectified {
			pageImages[n] = nil
			if showing[n] != nil { loadImage(n) }
		}
		failures = [:]
		selectedLine = nil
		state = .running
		let flag = StopFlag()
		stopFlag = flag
		recognizer.recognize(
			recognitionSource, pages: Array(1...totalPages), options: options, stop: flag,
			onPage: { [weak self] n, result in
				guard let self, self.stopFlag === flag else { return }
				switch result {
				case .success(let page): self.results[n] = page
				case .failure(let error): self.failures[n] = "\(error)"
				}
				// 拉正过的页要换成拉正后的图，框才对得上（框的坐标相对它）。
				if self.results[n]?.rectifiedImage != nil, self.showing[n] != nil || self.pageImages[n] != nil {
					self.loadImage(n, force: true)
				}
			},
			onFinish: { [weak self] in
				guard let self, self.stopFlag === flag else { return }
				if flag.isStopped {
					self.state = .stopped
				} else if self.results.isEmpty, let first = self.failures.sorted(by: { $0.key < $1.key }).first {
					self.state = .failed(first.value)
				} else {
					self.state = .done
					self.onFinished?(self)
				}
			})
	}

	public func stop() {
		stopFlag?.stop()
	}

	public var isRunning: Bool { state == .running }

	/// 认完了几页（含认不了的）。
	public var finishedCount: Int { results.count + failures.count }

	/// 认完的页按页码排好。
	public var finishedPages: [PageResult] { results.keys.sorted().compactMap { results[$0] } }

	/// 框选识别：在第 `n` 页（默认当前页）的图上框一块，只认这一块。
	/// 用了 PDF 文字层的页不用再认：按框从 PDF 里取字，框住半行就是半行（PDFKit 按框选字；显示那份 PageSource 的 PDFKit 只在主线程用）。
	/// 框到另外认过的图片区（插图、流程图）还是认图。
	public func recognize(region: NRect, onPage n: Int? = nil, done: @escaping @MainActor (Result<String, Error>) -> Void) {
		let n = n ?? page
		if let result = results[n], result.textLayer, !result.pictureBoxes.contains(where: { $0.overlapArea(region) > 0 }),
			let text = displaySource.textLayerText(page: n, in: region)
		{
			done(.success(text))
			return
		}
		let image: CGImage
		if let rectified = results[n]?.rectifiedImage {
			image = rectified
		} else {
			do { image = try recognitionSource.image(page: n) } catch {
				done(.failure(error))
				return
			}
		}
		recognizer.recognize(region: region, in: image, options: options) { result in
			done(result.map { $0.cleanText })
		}
	}

	// MARK: 翻页和画图

	/// 主动跳页。同一页也能再跳一次：手动滚偏后，点当前页的页码仍能找回这一页。
	public func show(page n: Int) {
		guard n >= 1, n <= totalPages else { return }
		pageNavigation += 1
		selectPage(n)
	}

	/// 原图滚到了或点到了这一页，只同步页码和文字，不发跳页请求。
	func selectPage(_ n: Int) {
		guard n >= 1, n <= totalPages, n != page else { return }
		// 连点几个远页时，中间的页可能从没来得及建视图，没有 onDisappear 替它清图。
		// 切走时主动收起这些页，否则每点一页就多留约 25 MB。
		if showing[page] == nil { retireImage(page) }
		page = n
		selectedLine = nil
		hidden.removeAll { $0 == n }
		loadImage(n)
	}

	/// 第 n 页占多大（像素）：认完且拉正过的照拉正后的图，其余照原图。读不了的页当 A4 竖放。
	public func pageSize(_ n: Int) -> CGSize {
		if let rectified = results[n]?.rectifiedImage {
			let long = Double(max(rectified.width, rectified.height)), scale = min(1, Double(Self.displayLongSide) / max(long, 1))
			return CGSize(width: Double(rectified.width) * scale, height: Double(rectified.height) * scale)
		}
		let size = n >= 1 && n <= pageSizes.count ? pageSizes[n - 1] : .zero
		return size.width > 0 && size.height > 0 ? size : CGSize(width: 2121, height: 3000)
	}

	/// 原图那一栏里第 n 页露出来了（连续滚动时一页页地来）：先画缩略图顶着，再画清楚的。
	public func pageAppeared(_ n: Int) {
		showing[n, default: 0] += 1
		hidden.removeAll { $0 == n }
		loadThumbnail(n)
		loadImage(n)
	}

	/// 第 n 页收起来了：没画的不画了；图只给最近收起来的两页留着，再早的放掉。
	public func pageDisappeared(_ n: Int) {
		guard let count = showing[n] else { return }
		guard count <= 1 else {
			showing[n] = count - 1
			return
		}
		showing[n] = nil
		retireImage(n)
	}

	private func retireImage(_ n: Int) {
		drawing[n]?.stop()
		drawing[n] = nil
		guard pageImages[n] != nil else { return }
		hidden.removeAll { $0 == n }
		hidden.append(n)
		while hidden.count > Self.keptHidden {
			pageImages[hidden.removeFirst()] = nil
		}
	}

	/// 当前页的图（打开时、照片取来时先画上，不等原图那一栏露出来）。
	public func loadPageImage(force: Bool) {
		loadImage(page, force: force)
	}

	/// 第 n 页的图：认完且拉正过的用拉正后的图（框的坐标相对它），其余在后台按给人看的大小画原图。
	func loadImage(_ n: Int, force: Bool = false) {
		guard n >= 1, n <= totalPages else { return }
		if let rectified = results[n]?.rectifiedImage {
			drawing[n]?.stop()
			drawing[n] = nil
			if force || pageImages[n] == nil { pageImages[n] = downscaledQuickly(rectified, longSide: Self.displayLongSide) }
			return
		}
		guard force || (pageImages[n] == nil && drawing[n] == nil) else { return }
		drawing[n]?.stop()
		let flag = StopFlag()
		drawing[n] = flag
		let source = displaySource, longSide = Self.displayLongSide
		drawQueue.async {
			guard !flag.isStopped else { return }
			let image = try? source.image(page: n, longSide: longSide)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					// 画的时候这一页收起来了、又要了一张新的，或者刚认完换成了拉正后的图：这张不要了。
					guard self.drawing[n] === flag else { return }
					self.drawing[n] = nil
					guard let image, self.results[n]?.rectifiedImage == nil else { return }
					self.pageImages[n] = image
				}
			}
		}
	}

	/// 缩略图（多页时左边那一栏用），画过的不再画。
	public func loadThumbnail(_ n: Int) {
		guard thumbnails[n] == nil else { return }
		let source = displaySource
		drawQueue.async {
			guard let image = try? source.image(page: n, longSide: 240) else { return }
			DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnails[n] = image } }
		}
	}

	// MARK: 复制、导出

	public var plainText: String { exportPlainText(finishedPages, totalPages: totalPages) }

	public func copyAll() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(plainText, forType: .string)
	}

	public enum ExportFormat: CaseIterable {
		case markdown, text, json

		public var title: String {
			switch self {
			case .markdown: return "Markdown…"
			case .text: return "纯文字…"
			case .json: return "JSON（带每行位置）…"
			}
		}

		var fileExtension: String {
			switch self {
			case .markdown: return "md"
			case .text: return "txt"
			case .json: return "json"
			}
		}
	}

	public func exportContent(_ format: ExportFormat) -> String {
		switch format {
		case .markdown: return exportMarkdown(finishedPages, title: name, totalPages: totalPages)
		case .text: return plainText
		case .json:
			let pages = finishedPages.map { p -> PageResult in
				var q = p
				q.rectifiedImage = nil
				return q
			}
			return jsonString(resultJSON(pages, totalPages: totalPages), pretty: true)
		}
	}

	/// 弹出存放位置再写。
	public func export(_ format: ExportFormat) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = (name as NSString).deletingPathExtension + "." + format.fileExtension
		if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
		let content = exportContent(format)
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			try? Data(content.utf8).write(to: url, options: .atomic)
		}
	}
}
