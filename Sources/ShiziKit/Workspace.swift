import AppKit
import Observation
import OCRCore
import UniformTypeIdentifiers

/// 左栏里选中的那一项：打开过的一个文件、一个相簿，或者还没给权限时的「照片图库」。
public enum SidebarItem: Hashable {
	case document(DocumentModel.ID)
	case album(String)
	case photos
}

/// 这次打开过的文件、照片那一节，和正在看哪一个。
@MainActor @Observable
public final class Workspace {
	public static let shared = Workspace()

	public private(set) var documents: [DocumentModel] = []
	public var selection: SidebarItem? {
		didSet {
			if case .album(let id) = selection { photos.show(album: id) }
		}
	}
	/// 打不开时说一句（弹出提示用），看过就清掉。
	public var problem: String?
	public let photos: PhotosModel
	@ObservationIgnored let recognizer: Recognizer

	/// `photos` 给测试和出截图的工具换成假的照片图库。
	public init(recognizer: Recognizer = .shared, photos: PhotosModel? = nil) {
		self.recognizer = recognizer
		self.photos = photos ?? PhotosModel(recognizer: recognizer)
	}

	/// 正在看的文件。
	public var selectedID: DocumentModel.ID? {
		get {
			if case .document(let id) = selection { return id }
			return nil
		}
		set { selection = newValue.map { .document($0) } }
	}

	public var selected: DocumentModel? { documents.first { $0.id == selectedID } }

	/// 正在看的相簿。
	public var selectedAlbumID: String? {
		if case .album(let id) = selection { return id }
		return nil
	}

	/// 照片权限刚给：选上第一个相簿（截屏）。
	public func showFirstAlbum() {
		if let first = photos.albums.first { selection = .album(first.id) }
	}

	// MARK: 菜单里「识别」「停止」：看左栏选的是文件还是相簿

	public var canRecognize: Bool {
		if let doc = activeDocument { return !doc.isRunning }
		if selectedAlbumID != nil { return photos.viewingID == nil && photos.run == nil && photos.counts.todo > 0 }
		return false
	}

	public var canStop: Bool {
		if let doc = activeDocument, doc.isRunning { return true }
		if let id = selectedAlbumID { return photos.run?.albumID == id }
		return false
	}

	/// ⌘R：文件、点开的照片是重新识别它；相簿是认里面还没认过的。
	public func recognizeSelection() {
		if let doc = activeDocument {
			doc.start()
		} else if selectedAlbumID != nil {
			photos.recognizeAlbum()
		}
	}

	public func stopSelection() {
		if let doc = activeDocument, doc.isRunning {
			doc.stop()
		} else if selectedAlbumID != nil {
			photos.stop()
		}
	}

	/// 打开文件：每个文件一项，打开就开始认；最后一个选中。
	public func open(_ urls: [URL]) {
		var failed: [String] = []
		for url in urls {
			do {
				add(try DocumentModel(url: url, recognizer: recognizer))
			} catch {
				failed.append(String(localized: "\(url.lastPathComponent)：\(String(describing: error))"))
			}
		}
		if !failed.isEmpty { problem = failed.joined(separator: "\n") }
	}

	/// `select`：打开以后切过去看它。
	public func add(_ doc: DocumentModel, start: Bool = true, select: Bool = true) {
		documents.append(doc)
		if select { selectedID = doc.id }
		if start {
			doc.start()
			doc.loadPageImage(force: true)
		}
	}

	/// 打开照片图库里的一张：在相簿里点开（左上角返回回网格），不进左栏。左栏只放自己带进来的文件和相簿。
	public func openPhoto(_ asset: PhotoAsset) {
		photos.view(asset)
	}

	/// 正在看的那一份：左栏选的文件，或者相簿里点开的照片。菜单里「重新识别」「复制全文」「导出」对它做。
	public var activeDocument: DocumentModel? {
		if let doc = selected { return doc }
		return selectedAlbumID != nil ? photos.viewingDocument : nil
	}

	public func remove(_ doc: DocumentModel) {
		doc.stop()
		documents.removeAll { $0.id == doc.id }
		if selectedID == doc.id { selectedID = documents.last?.id }
	}

	public func showOpenPanel() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image, .pdf]
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.begin { response in
			guard response == .OK else { return }
			MainActor.assumeIsolated { self.open(panel.urls) }
		}
	}

	/// 粘贴：剪贴板里是文件就打开文件，是图（截图）或 PDF 就直接认。认得了返回 true。
	@discardableResult
	public func paste(from pasteboard: NSPasteboard = .general) -> Bool {
		if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
			open(urls)
			return true
		}
		let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
		for (type, label) in [
			(NSPasteboard.PasteboardType.pdf, String(localized: "粘贴的 PDF")), (.png, String(localized: "粘贴的截图")), (.tiff, String(localized: "粘贴的截图")),
		] {
			guard let data = pasteboard.data(forType: type) else { continue }
			do {
				add(try DocumentModel(data: data, name: "\(label) \(stamp)", recognizer: recognizer))
				return true
			} catch {
				problem = String(localized: "剪贴板里的图读不了：\(String(describing: error))")
				return false
			}
		}
		return false
	}
}
