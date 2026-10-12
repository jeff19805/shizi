import AppKit
import OCRCore
import SwiftUI

/// 左栏「照片」那一节的一行：相簿名和照片张数；正在认的相簿，图标换成小转圈（跟文件那一节一个样）。
struct AlbumRow: View {
	let album: PhotoAlbum
	let running: Bool

	var body: some View {
		HStack(spacing: 8) {
			Group {
				if running {
					ProgressView().controlSize(.small)
				} else {
					Image(systemName: album.symbol).foregroundStyle(.secondary)
				}
			}
			.frame(width: 16)
			Text(album.title)
				.fontWeight(.medium)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 4)
			Text("\(album.count)")
				.font(.caption)
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
	}
}

extension PhotoAlbum {
	var symbol: String {
		switch kind {
		case .screenshots: return "camera.viewfinder"
		case .all: return "photo.on.rectangle"
		case .favorites: return "heart"
		case .album: return "rectangle.stack"
		}
	}
}

/// 还没给照片权限时：说清能干什么、照片去哪了，一个主按钮。被拒过的，告诉人去系统设置里打开。
struct PhotoAccessView: View {
	let photos: PhotosModel
	let granted: @MainActor () -> Void

	var body: some View {
		Group {
			if photos.access == .denied {
				ContentUnavailableView {
					Label("拾字看不到你的照片", systemImage: "photo.on.rectangle.angled")
				} description: {
					Text("到「系统设置 › 隐私与安全性 › 照片」里打开「拾字」。")
				} actions: {
					Button("打开系统设置") {
						if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
							NSWorkspace.shared.open(url)
						}
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
				}
			} else {
				ContentUnavailableView {
					Label("按字找照片", systemImage: "photo.on.rectangle.angled")
				} description: {
					Text("拾字认出照片里的字，以后按字就找得到。\n照片不复制、不上传，认出的字只存在这台 Mac 上。")
				} actions: {
					Button("允许访问照片…") { photos.requestAccess(then: granted) }
						.buttonStyle(.borderedProminent)
						.controlSize(.large)
				}
			}
		}
		.navigationTitle("照片")
		// 在系统设置里改了权限再切回来：重新看一眼。
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in photos.refreshAccess() }
	}
}

/// 相簿那一栏：网格（或搜出来的）在底下，点开一张就推上来那一张，左上角返回。照「照片」App 的做法：
/// 看的照片不进左栏，滚到哪、选了哪张，回来都还在。
struct AlbumStack: View {
	@Bindable var photos: PhotosModel
	let open: (PhotoAsset) -> Void

	var body: some View {
		NavigationStack(path: $photos.path) {
			AlbumView(photos: photos, open: open)
				.navigationDestination(for: PhotoRoute.self) { route in
					PhotoDetailView(photos: photos, id: route.id)
				}
		}
		// 网格里、点开的照片上都能「新建相簿…」：问名字放在这一层。
		.alert("新建相簿", isPresented: Binding(get: { photos.newAlbumItems != nil }, set: { if !$0 { photos.newAlbumItems = nil } })) {
			TextField("相簿名", text: $photos.newAlbumName)
			Button("新建") { photos.confirmNewAlbum() }
				.disabled(photos.newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			Button("取消", role: .cancel) { photos.newAlbumItems = nil }
		} message: {
			Text("把这 \(photos.newAlbumItems?.count ?? 0) 张放进一个新相簿。照片不复制，原来在哪还在哪。")
		}
	}
}

/// 在相簿里点开的一张：跟打开文件一样的看法（原图叠框、整页 / 逐行）。← → 或工具栏的上下箭头翻张，Esc 回网格。
struct PhotoDetailView: View {
	@Bindable var photos: PhotosModel
	let id: String
	@FocusState private var focused: Bool

	var body: some View {
		Group {
			if let doc = photos.viewed[id] {
				DocumentView(doc: doc, position: position)
			} else if let problem = photos.viewProblems[id] {
				ContentUnavailableView {
					Label("打不开这张照片", systemImage: "exclamationmark.triangle")
				} description: {
					Text(problem)
				} actions: {
					Button("再试一次") { photos.retry(id) }
				}
				.navigationTitle("照片")
			} else {
				VStack(spacing: 8) {
					ProgressView()
					Text("正在取这张照片……").foregroundStyle(.secondary)
					Text("原图在 iCloud 上的要先下载，头一张可能要等一两分钟").font(.callout).foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.navigationTitle("照片")
			}
		}
		.toolbar { PhotoDetailToolbar(photos: photos) }
		.focusable()
		.focusEffectDisabled()
		.focused($focused)
		.onAppear { focused = true }
		.onKeyPress(.leftArrow) {
			photos.step(-1)
			return .handled
		}
		.onKeyPress(.rightArrow) {
			photos.step(1)
			return .handled
		}
		.onExitCommand { photos.back() }
	}

	var position: String? {
		photos.position.map { String(localized: "第 \($0.index + 1) / \($0.count) 张") }
	}
}

/// 点开的照片的页头：上一张、下一张（像「邮件」翻信那样的上下箭头，免得跟左上角的返回混了），加进相簿。
struct PhotoDetailToolbar: ToolbarContent {
	let photos: PhotosModel

	var body: some ToolbarContent {
		ToolbarItemGroup(placement: .primaryAction) {
			ControlGroup {
				Button("上一张", systemImage: "chevron.up") { photos.step(-1) }
					.disabled(!photos.canStep(-1))
					.help("上一张（←）")
				Button("下一张", systemImage: "chevron.down") { photos.step(1) }
					.disabled(!photos.canStep(1))
					.help("下一张（→）")
			}
			if let asset = photos.viewingID.flatMap({ id in photos.browseList.first { $0.id == id } }) {
				AddToAlbumMenu(photos: photos, items: [asset], newAlbum: { photos.askNewAlbum($0) })
			}
		}
	}
}

/// 一个相簿：照片网格；页头写这个相簿认到什么程度，「识别」只认还没认过的。
/// 顶上的搜索框按字搜认过的全部照片（不只这个相簿），搜的时候网格换成结果列表。双击（或回车）一张打开看。
struct AlbumView: View {
	@Bindable var photos: PhotosModel
	let open: (PhotoAsset) -> Void
	/// 「分类」那一小窗开着没有。
	@State private var classifying = false

	var body: some View {
		let actions = PhotoActions(open: open, newAlbum: askNewAlbum)
		Group {
			if photos.isSearching {
				PhotoSearchResults(photos: photos, actions: actions)
			} else if photos.assets.isEmpty {
				ContentUnavailableView("这个相簿里没有照片", systemImage: "photo.on.rectangle", description: Text("拾字只认照片，视频不认。"))
			} else {
				VStack(spacing: 0) {
					// 分过类才有筛选条。
					if photos.classifyRules != nil {
						LabelFilterBar(photos: photos)
						Divider()
					}
					PhotoGrid(photos: photos, actions: actions)
				}
			}
		}
		.navigationTitle(photos.isSearching ? String(localized: "按字找照片") : photos.album?.title ?? String(localized: "照片"))
		.navigationSubtitle(subtitle)
		.toolbar { AlbumToolbar(photos: photos, newAlbum: askNewAlbum, classify: { classifying = true }) }
		.sheet(isPresented: $classifying) { ClassifySheet(photos: photos) }
		.searchable(text: $photos.searchText, placement: .toolbar, prompt: "按字找照片")
		// 打字停一下再搜：一个字一个字搜白费工夫。
		.task(id: photos.searchText) {
			try? await Task.sleep(for: .milliseconds(150))
			guard !Task.isCancelled else { return }
			photos.search()
		}
	}

	var subtitle: String {
		if photos.isSearching { return photos.searchSubtitle }
		// 在认字时说认字的进度；只在分类时说分类的进度。
		if let c = photos.classifyRun, photos.run == nil {
			return c.stopping ? String(localized: "正在停……") : String(localized: "正在分类：\(c.done) / \(c.total) 张")
		}
		return photos.subtitle
	}

	func askNewAlbum(_ items: [PhotoAsset]) {
		photos.askNewAlbum(items)
	}
}

/// 网格和搜出来的列表上，对一张或几张照片能做的事。
struct PhotoActions {
	let open: (PhotoAsset) -> Void
	/// 放进新相簿：先问名字。
	let newAlbum: ([PhotoAsset]) -> Void
}

/// 「加进相簿」菜单：自己建的相簿一个一项，最后是「新建相簿…」。页头和右键菜单里都用它。
struct AddToAlbumMenu: View {
	let photos: PhotosModel
	let items: [PhotoAsset]
	let newAlbum: ([PhotoAsset]) -> Void

	var body: some View {
		Menu("加进相簿", systemImage: "rectangle.stack.badge.plus") {
			ForEach(photos.addableAlbums) { album in
				Button(album.title) { photos.add(items, to: .existing(album.id)) }
			}
			if !photos.addableAlbums.isEmpty { Divider() }
			Button("新建相簿…") { newAlbum(items) }
		}
		.help(items.isEmpty ? String(localized: "先选几张照片") : String(localized: "把选中的 \(items.count) 张加进相簿（照片不复制）"))
		.disabled(items.isEmpty)
	}
}

/// 相簿页头的操作：不在认时「识别」，认的时候是进度和「停止」。
/// 同样的命令菜单栏里也有（⌘R、⌘.）。搜的时候不放「识别」：结果不只这个相簿的。
struct AlbumToolbar: ToolbarContent {
	let photos: PhotosModel
	let newAlbum: ([PhotoAsset]) -> Void
	/// 开「分类」那一小窗。
	let classify: () -> Void

	var body: some ToolbarContent {
		ToolbarItemGroup(placement: .primaryAction) {
			// 选了照片才出来：加进相簿。
			if !photos.selection.isEmpty {
				AddToAlbumMenu(photos: photos, items: photos.selectedAssets, newAlbum: newAlbum)
			}
			if let run = photos.run, run.albumID == photos.albumID {
				ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
					.progressViewStyle(.linear)
					.frame(width: 120)
				Button("停止") { photos.stop() }
					.help("停止识别（⌘.）")
					.disabled(run.stopping)
			} else if !photos.isSearching {
				let todo = photos.counts.todo
				// 相簿不像文件那样一打开就认（可能几百张、要下载），「识别」是这里的主要操作，图标旁带上字。
				Button("识别", systemImage: "text.viewfinder") { photos.recognizeAlbum() }
					.labelStyle(.titleAndIcon)
					.help(
						photos.run != nil
							? String(localized: "正在认另一个相簿，认完再来")
							: todo == 0 ? String(localized: "这个相簿里的照片都认过了") : String(localized: "认这个相簿里还没认过的 \(todo) 张（⌘R）"))
					.disabled(photos.run != nil || todo == 0)
			}
			// 分类：在分的时候是进度和「停止分类」。
			if let c = photos.classifyRun {
				ProgressView(value: Double(c.done), total: Double(max(c.total, 1)))
					.progressViewStyle(.linear)
					.frame(width: 120)
				Button("停止分类") { photos.stopClassify() }
					.disabled(c.stopping)
			} else if !photos.isSearching {
				Button("分类", systemImage: "tag") { classify() }
					.labelStyle(.titleAndIcon)
					.help("给这个相簿的照片分类：看认出的字（只发字），或者看画面（发缩小的照片）")
			}
		}
	}
}

/// 照片网格：格子按窗口宽排，缩略图看到哪张取哪张。点一张选中，按着 ⌘ 点是加选，点空处、按 Esc 都不选；
/// ⌘A 全选；双击或回车打开。
struct PhotoGrid: View {
	let photos: PhotosModel
	let actions: PhotoActions
	@FocusState private var focused: Bool

	var body: some View {
		GeometryReader { geo in
			ScrollViewReader { proxy in
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 192), spacing: 8)], spacing: 8) {
						ForEach(photos.shownAssets) { asset in
							PhotoCell(photos: photos, asset: asset, actions: actions) { focused = true }
						}
					}
					.padding(16)
					// 撑满整个可见的高度：照片少的时候，下面的空处点了也算「点空处」。
					.frame(minHeight: geo.size.height, alignment: .top)
					.background {
						Color.clear
							.contentShape(Rectangle())
							.onTapGesture {
								photos.selection = []
								focused = true
							}
					}
				}
				// 换了相簿从头看起，不停在上一个相簿滚到的地方。
				.onChange(of: photos.albumID) { _, _ in
					if let first = photos.assets.first { proxy.scrollTo(first.id, anchor: .top) }
				}
				// 点开一张又翻到别处，回来时网格滚到最后看的那张。
				.onAppear {
					if let id = photos.returnTo {
						proxy.scrollTo(id, anchor: .center)
						photos.returnTo = nil
					}
				}
			}
		}
		.focusable()
		.focusEffectDisabled()
		.focused($focused)
		.onKeyPress(.return) {
			guard photos.selection.count == 1, let asset = photos.assets.first(where: { photos.selection.contains($0.id) }) else { return .ignored }
			actions.open(asset)
			return .handled
		}
		.onExitCommand { photos.selection = [] }
		.onCommand(#selector(NSText.selectAll(_:))) { photos.selectAll() }
	}
}

/// 网格里的一格：方的缩略图，选中时强调色描边；角上只标要人留意的（原图在 iCloud 上、出错、排着等下载），
/// 认过的不标（认完不出声），悬停能看到认没认过。
struct PhotoCell: View {
	let photos: PhotosModel
	let asset: PhotoAsset
	let actions: PhotoActions
	/// 点了格子：网格要拿到键盘（回车、⌘A、Esc）。
	let touched: () -> Void

	var body: some View {
		Rectangle()
			.fill(.quaternary)
			.aspectRatio(1, contentMode: .fit)
			.overlay {
				if let image = photos.thumbnails[asset.id] {
					Image(decorative: image, scale: 2)
						.resizable()
						.scaledToFill()
				}
			}
			.clipShape(RoundedRectangle(cornerRadius: 6))
			.overlay(alignment: .bottomTrailing) {
				PhotoBadge(photos: photos, asset: asset).padding(4)
			}
			.overlay {
				if photos.selection.contains(asset.id) {
					RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
				}
			}
			.contentShape(Rectangle())
			// 单击马上选中（不等看是不是双击），双击再打开。
			.gesture(TapGesture(count: 2).onEnded { actions.open(asset) })
			.simultaneousGesture(
				TapGesture().onEnded {
					photos.click(asset.id, extend: NSEvent.modifierFlags.contains(.command))
					touched()
				})
			.contextMenu {
				// 右键点在选中的那几张上，对选中的几张做；点在没选中的一张上，只对这一张做。
				let items = photos.selection.contains(asset.id) ? photos.selectedAssets : [asset]
				Button("打开") { actions.open(asset) }
				AddToAlbumMenu(photos: photos, items: items, newAlbum: actions.newAlbum)
			}
			.onAppear { photos.cellAppeared(asset) }
			.onDisappear { photos.cellDisappeared(asset.id) }
			.help(photos.describe(asset))
	}
}

/// 按字搜出来的照片：一行一张，缩略图、文件名、拍摄时间，和字里搜到的那一段（搜的词用主色，其余次要灰）。
/// 能多选（⌘ 点、⇧ 点、⌘A），双击或回车打开。
struct PhotoSearchResults: View {
	@Bindable var photos: PhotosModel
	let actions: PhotoActions

	var body: some View {
		let query = photos.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		if photos.searchHits.isEmpty && photos.searchIsCurrent {
			ContentUnavailableView {
				Label("认过的照片里没有「\(query)」", systemImage: "magnifyingglass")
			} description: {
				Text("拾字认过 \(photos.recognizedCount) 张照片，没认过的搜不到。\n要搜更多，先在相簿里点「识别」。")
			}
		} else {
			List(selection: $photos.selection) {
				ForEach(photos.searchHits) { hit in
					PhotoHitRow(photos: photos, hit: hit, query: query).tag(hit.id)
				}
			}
			.contextMenu(forSelectionType: String.self) { ids in
				Button("打开") { openFirst(ids) }.disabled(ids.count != 1)
				AddToAlbumMenu(photos: photos, items: photos.searchHits.map(\.asset).filter { ids.contains($0.id) }, newAlbum: actions.newAlbum)
			} primaryAction: { ids in
				openFirst(ids)
			}
		}
	}

	func openFirst(_ ids: Set<String>) {
		if let hit = photos.searchHits.first(where: { ids.contains($0.id) }) { actions.open(hit.asset) }
	}
}

struct PhotoHitRow: View {
	let photos: PhotosModel
	let hit: PhotoHit
	let query: String

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Rectangle()
				.fill(.quaternary)
				.frame(width: 56, height: 56)
				.overlay {
					if let image = photos.thumbnails[hit.id] {
						Image(decorative: image, scale: 2)
							.resizable()
							.scaledToFill()
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 6))
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text(hit.record.name ?? String(localized: "照片（单张）", defaultValue: "照片"))
						.fontWeight(.medium)
						.lineLimit(1)
						.truncationMode(.middle)
					Spacer(minLength: 8)
					if let taken = hit.record.taken {
						// 写法跟 photos_search 回的一样，只有数字：中文、英文界面都这么写，不跟着系统的地区格式变。
						Text(Self.day.string(from: taken))
							.font(.caption)
							.monospacedDigit()
							.foregroundStyle(.secondary)
					}
				}
				Text(Self.highlighted(PhotoIndex.snippet(hit.record.text, around: query, width: 30), query: query))
					.font(.callout)
					.lineLimit(2)
			}
		}
		.padding(.vertical, 4)
		.onAppear { photos.cellAppeared(hit.asset) }
		.onDisappear { photos.cellDisappeared(hit.id) }
	}

	static let day: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy-MM-dd HH:mm"
		return f
	}()

	/// 搜到的那个词用主色，其余次要灰（不用别的颜色、不加粗，见界面规范 §2、§3）。
	static func highlighted(_ snippet: String, query: String) -> AttributedString {
		var text = AttributedString(snippet)
		text.foregroundColor = .secondary
		let pattern = PhotoIndex.matchPattern(query)
		if !pattern.isEmpty, let r = snippet.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
			let match = Range(r, in: text)
		{
			text[match].foregroundColor = .primary
		}
		return text
	}
}

/// 格子角上的标：图标加悬停的一句话，不只靠颜色。
struct PhotoBadge: View {
	let photos: PhotosModel
	let asset: PhotoAsset

	var body: some View {
		if photos.isWaitingForDownload(asset) {
			mark("icloud.and.arrow.down", .secondary)
		} else {
			switch photos.status(of: asset) {
			case .icloud?: mark("icloud", .secondary)
			case .failed?: mark("exclamationmark.circle.fill", .red)
			default: EmptyView()
			}
		}
	}

	func mark(_ symbol: String, _ style: some ShapeStyle) -> some View {
		Image(systemName: symbol)
			.font(.caption)
			.foregroundStyle(style)
			.padding(4)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
	}
}

extension PhotosModel {
	/// 悬停在格子上看到的那句：认没认过、有没有字，没认成的说为什么。
	func describe(_ asset: PhotoAsset) -> String {
		if isWaitingForDownload(asset) { return String(localized: "排着等从 iCloud 下载原图来认") }
		switch status(of: asset) {
		case .text?: return String(localized: "认过，有字")
		case .empty?: return String(localized: "认过，没有字")
		case .icloud?: return problem(of: asset) ?? String(localized: "原图在 iCloud 上，还没认")
		case .failed?:
			let reason = problem(of: asset) ?? String(localized: "出错了")
			return String(localized: "没认成：\(reason)")
		case nil: return briefs[asset.id] == nil ? String(localized: "还没认") : String(localized: "照片改过，要重新认")
		}
	}
}
