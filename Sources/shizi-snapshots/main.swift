// 开发用：把拾字的各个界面画成图片，改了界面拿来看一眼。
// 用法：shizi-snapshots <输出文件夹> <测试图文件夹>
//   测试图文件夹里要有 receipt.png、table.png（一张小票、一张表格），和 short.pdf、long.pdf 两个多页 PDF。
// 界面放进一个真的窗口，浅色、深色各拍一张；窗口放在屏幕外拍，不打扰人（光挪出去不够，系统会拉回来，见 OffscreenWindow）。
import AppKit
import OCRCore
import ShiziKit
import SwiftUI

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "snapshots", isDirectory: true)
let fixtures = URL(fileURLWithPath: args.count > 2 ? args[2] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// 让窗口服务器把整个窗口（含标题栏、工具栏、侧栏的半透明材质）拍下来：自己画自己画不出半透明材质。
/// 拍自己的窗口不要「录屏」权限。这个接口 macOS 14 起标了过时，按名字找出来调，免得编出警告（只在这个开发工具里用）。
func windowImage(_ id: CGWindowID) -> CGImage? {
	guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
	let create = unsafeBitCast(sym, to: WindowListCreateImage.self)
	return create(
		.null, CGWindowListOption.optionIncludingWindow.rawValue, id, CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
	)?.takeRetainedValue()
}

func spin(_ seconds: TimeInterval) {
	RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 等到条件成立（最多等 limit 秒）。
func wait(_ limit: TimeInterval, until done: () -> Bool) {
	let deadline = Date().addingTimeInterval(limit)
	while !done() && Date() < deadline { spin(0.05) }
}

/// 拍照用的窗口，待在屏幕外。带标题栏的窗口一显示，系统就把它拉回屏幕里：挪到 (-20000, -20000) 再显示，会落回左下角；
/// 显示以后再挪也拦，挪出去一截就不让走了，还留一角在屏幕上。系统拉窗口都要过这个方法，
/// 这里原样放行，窗口就一直在屏幕外。拍出来跟在屏幕上一样（照样两倍像素），只差一处：背后没有桌面，深色的底色不再透出
/// 桌面图片的颜色（在屏幕上拍会跟着桌面图片变），每次拍都一样。
final class OffscreenWindow: NSWindow {
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 同上，给系统自带的「关于」窗口用：那个窗口是系统建的，只能建好以后把它的类换成这个
/// （只多一个方法、不多存东西，换得过去；只在这个开发工具里这么干）。
final class OffscreenPanel: NSPanel {
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// `fit`：窗口跟着内容的大小走（设置窗口就是这样），`size` 只给宽。
/// `then`：窗口先照原样画一遍，再做这件事（比如点左栏），再拍：查「第一次点进去」这种只在界面已经开着时才出的毛病。
@MainActor
func snapshot(
	_ name: String, size: CGSize = CGSize(width: 1200, height: 760), settle: TimeInterval = 1.5, fit: Bool = false,
	before setup: (@MainActor () -> Void)? = nil, then action: (@MainActor (Bool, NSWindow) -> Void)? = nil, _ view: some View
) {
	for dark in [false, true] {
		setup?()
		let window = OffscreenWindow(
			contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		window.toolbarStyle = .unified
		let host = NSHostingView(rootView: view)
		host.sceneBridgingOptions = [.toolbars, .title]
		window.contentView = host
		if fit {
			host.layoutSubtreeIfNeeded()
			window.setContentSize(host.fittingSize)
		}
		window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
		window.orderFrontRegardless()
		spin(settle)
		if let action {
			action(dark, window)
			spin(settle)
		}
		guard let image = windowImage(CGWindowID(window.windowNumber)) else { continue }
		let url = out.appendingPathComponent("\(name)-\(dark ? "深色" : "浅色").png")
		try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
		window.orderOut(nil)
		print(url.path)
	}
}

/// 照片库放在输出文件夹里，每次从空的开始。
func freshIndexPath(_ name: String) -> String {
	let path = out.appendingPathComponent(name).path
	for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) }
	return path
}

MainActor.assumeIsolated {
	// 不带插件，结果只取决于这台机器的系统识别。
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig()))
	/// 照片那一节用现画的样例图库，不碰真的照片图库。`access` 是装作给没给照片权限。
	@MainActor func workspace(_ files: [String] = [], access: PhotoAccess = .notDetermined, library: SamplePhotoLibrary? = nil, index: String? = nil)
		-> Workspace
	{
		let photos = PhotosModel(
			library: library ?? SamplePhotoLibrary(access: access), indexPath: index ?? freshIndexPath("空的照片库.sqlite"), recognizer: recognizer)
		let ws = Workspace(recognizer: recognizer, photos: photos)
		ws.open(files.map { fixtures.appendingPathComponent($0) })
		return ws
	}

	snapshot("1-空状态", RootView(workspace: workspace()))

	// 单张小票：逐行，选中第一行可能认错的。
	let receipt = workspace(["receipt.png"])
	let doc = receipt.selected!
	wait(20) { !doc.isRunning && doc.pageImage != nil }
	UserDefaults.standard.set("lines", forKey: "拾字.看法")
	doc.selectedLine = doc.results[1]?.lines.firstIndex { $0.suspect != nil }
	snapshot("2-小票逐行", RootView(workspace: receipt))

	// 表格：整页。
	UserDefaults.standard.set("page", forKey: "拾字.看法")
	let table = workspace(["table.png"])
	wait(20) { !(table.selected!.isRunning) && table.selected!.pageImage != nil }
	snapshot("3-表格整页", RootView(workspace: table))

	// 长 PDF 认到一半：左栏转圈、页头进度、还没认到的页淡一些。
	let long = workspace(["short.pdf", "long.pdf"])
	let longDoc = long.selected!
	wait(30) { longDoc.finishedCount >= 3 && longDoc.pageImage != nil }
	snapshot("4-长文件识别中", settle: 0.8, RootView(workspace: long))
	longDoc.stop()

	// 多页认完：整页，翻到第 2 页。
	let short = long.documents[0]
	long.selectedID = short.id
	wait(60) { !short.isRunning }
	short.show(page: 2)
	wait(10) { short.pageImage != nil }
	snapshot("5-多页认完", RootView(workspace: long))

	// 设置：用一份示例插件配置，不碰真的 ~/.config/shizi/config.json。
	let sample = out.appendingPathComponent("示例插件配置.json").path
	let plugin = PluginSettings(path: sample, recognizer: recognizer).pluginPath
	try? OCRConfig(plugins: [
		PluginConfig(name: "clef", command: [plugin], hooks: ["route", "review"], env: ["SYSTEMONE_URL": "http://clef.local:8000", "SYSTEMONE_MODEL": "clef"]),
		PluginConfig(name: "jev", command: [plugin], hooks: ["review"], env: ["SYSTEMONE_URL": "https://api.typesafe.ai", "SYSTEMONE_MODEL": "jev-latest"], enabled: false),
	]).save(path: sample)
	let settings = PluginSettings(path: sample, recognizer: recognizer)
	let size = CGSize(width: 600, height: 560)
	snapshot("6-设置识别", size: size, fit: true, SettingsView(tab: .recognition, plugins: settings))
	snapshot("7-设置判定插件", size: size, fit: true, SettingsView(tab: .plugins, plugins: settings))
	snapshot("8-设置接入", size: size, fit: true, SettingsView(tab: .connect, plugins: settings))
	snapshot("10-添加插件", size: CGSize(width: 520, height: 640), fit: true, PluginEditorPreview(settings: settings))

	// 关于拾字：系统自带的「关于」窗口，开出来以后按窗口号拍。
	// 开窗口要等这一轮事件处理完才真的上屏幕（刚开完时，屏幕上还没有它）：趁这之前换掉它的类、挪到屏幕外，就一直不露面。
	AboutPanel.show()
	if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
		if type(of: panel) == NSPanel.self {
			object_setClass(panel, OffscreenPanel.self)
		} else {
			print("关于窗口的类变了（\(type(of: panel))），没换：拍的时候它会露一角在屏幕上")
		}
		panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
		spin(1)
		for dark in [false, true] {
			panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			spin(0.8)
			if let image = windowImage(CGWindowID(panel.windowNumber)) {
				let url = out.appendingPathComponent("9-关于拾字-\(dark ? "深色" : "浅色").png")
				try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
				print(url.path)
			}
		}
		panel.orderOut(nil)
	} else {
		print("关于窗口没开出来，没拍")
	}

	// 照片：还没给权限、被拒过。
	let notAsked = workspace()
	notAsked.selection = .photos
	snapshot("11-照片未授权", RootView(workspace: notAsked))
	let denied = workspace(access: .denied)
	denied.selection = .photos
	snapshot("12-照片被拒", RootView(workspace: denied))

	// 截屏相簿认过一部分：三张有字，一张还没认，一张原图在 iCloud 上没下下来，一张出错；选中第二张。
	let library = SamplePhotoLibrary(access: .granted)
	let indexPath = freshIndexPath("样例照片库.sqlite")
	let shots = library.assets(in: "截屏")
	if let index = try? PhotoIndex(path: indexPath) {
		for (i, asset) in shots.enumerated() {
			let name = library.filename(for: asset)
			switch i {
			case 0...2: try? index.upsert(PhotoIndex.Record(id: asset.id, stamp: asset.stamp, status: .text, text: "样例的字", name: name))
			case 4:
				try? index.upsert(
					PhotoIndex.Record(id: asset.id, stamp: asset.stamp, status: .icloud, name: name, problem: "从 iCloud 下载原图没成：网络出错，连不上 iCloud"))
			case 5: try? index.upsert(PhotoIndex.Record(id: asset.id, stamp: asset.stamp, status: .failed, name: name, problem: "图解不开"))
			default: break
			}
		}
	}
	let album = workspace(access: .granted, library: library, index: indexPath)
	wait(5) { !album.photos.albums.isEmpty }
	album.selection = .album("截屏")
	album.photos.click(shots[1].id, extend: false)
	snapshot("13-相簿", RootView(workspace: album))

	// 「最近项目」认到一半：页头进度和「停止」，左栏那个相簿转圈。取一张图慢一点，好拍到中间。
	let slow = SamplePhotoLibrary(access: .granted)
	slow.delay = 0.4
	let running = workspace(access: .granted, library: slow, index: freshIndexPath("认到一半的照片库.sqlite"))
	wait(5) { !running.photos.albums.isEmpty }
	running.selection = .album("最近项目")
	running.photos.recognizeAlbum()
	wait(10) { (running.photos.run?.done ?? 0) >= 2 }
	snapshot("14-相簿识别中", settle: 0.6, RootView(workspace: running))
	running.photos.stop()
	wait(10) { running.photos.run == nil }

	// 按字找：先把「最近项目」真的认一遍（样例图），再搜「发票」，选中第一张。
	let searchLibrary = SamplePhotoLibrary(access: .granted)
	let found = workspace(access: .granted, library: searchLibrary, index: freshIndexPath("搜索用的照片库.sqlite"))
	wait(5) { !found.photos.albums.isEmpty }
	found.selection = .album("最近项目")
	found.photos.recognizeAlbum()
	wait(60) { found.photos.run == nil }
	found.photos.searchText = "发票"
	found.photos.search()
	if let first = found.photos.searchHits.first { found.photos.click(first.id, extend: false) }
	snapshot("15-按字找照片", RootView(workspace: found))
	found.photos.searchText = "护照"
	found.photos.search()
	snapshot("16-搜不到", RootView(workspace: found))

	// 在相簿里点开一张：跟文件一样的看法，左上角返回，上下箭头翻张；不进左栏。
	found.photos.searchText = ""
	found.photos.search()
	found.selection = .album("截屏")
	found.openPhoto(searchLibrary.assets(in: "截屏")[1])
	wait(20) { found.photos.viewingDocument.map { !$0.isRunning && $0.pageImage != nil } ?? false }
	snapshot("17-相簿里点开一张", RootView(workspace: found))

	// 选了几张：页头多一个「加进相簿」。
	let picked = workspace(access: .granted, library: SamplePhotoLibrary(access: .granted), index: freshIndexPath("选几张的照片库.sqlite"))
	wait(5) { !picked.photos.albums.isEmpty }
	picked.selection = .album("最近项目")
	for asset in picked.photos.assets.dropFirst(6).prefix(3) { picked.photos.click(asset.id, extend: true) }
	snapshot("18-选了几张", RootView(workspace: picked))

	// 关了识别框：只画在逐行里选中的那一行。
	UserDefaults.standard.set(false, forKey: "拾字.显示识别框")
	UserDefaults.standard.set("lines", forKey: "拾字.看法")
	let hidden = workspace(["receipt.png"])
	let hiddenDoc = hidden.selected!
	wait(20) { !hiddenDoc.isRunning && hiddenDoc.pageImage != nil }
	hiddenDoc.selectedLine = 2
	snapshot("19-关了识别框", RootView(workspace: hidden))
	UserDefaults.standard.set(true, forKey: "拾字.显示识别框")

	// 识别详情（工具栏点开的那一小块，单独拍）。
	snapshot("20-识别详情", size: CGSize(width: 420, height: 420), RecognitionDetailsPreview())

	// 判定插件复核过的逐行：用一个示例插件，送来复核的头一行说可能认错，其余说没问题。
	let script = out.appendingPathComponent("示例复核插件.py")
	try? """
		#!/usr/bin/python3
		import json, sys
		ids = json.load(sys.stdin).get("input", {}).get("candidates", [])
		print(json.dumps({"output": {"suspects": {str(i): (0.9 if k == 0 else 0.1) for k, i in enumerate(ids)}}}))
		""".write(to: script, atomically: true, encoding: .utf8)
	try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
	let reviewing = Recognizer(engine: OCREngine(config: OCRConfig(plugins: [PluginConfig(name: "示例插件", command: [script.path], hooks: ["review"])])))
	let reviewed = Workspace(recognizer: reviewing, photos: PhotosModel(library: SamplePhotoLibrary(access: .notDetermined), indexPath: freshIndexPath("复核用的照片库.sqlite"), recognizer: reviewing))
	reviewed.open([fixtures.appendingPathComponent("receipt.png")])
	let reviewedDoc = reviewed.selected!
	wait(30) { !reviewedDoc.isRunning && reviewedDoc.pageImage != nil }
	snapshot("21-插件复核过的逐行", RootView(workspace: reviewed))

	// 刚打开拾字、什么都没选，再点左栏的「截屏」：网格要马上出来（出过一片空白、点别处再回来才有的毛病）。
	let firstClick = workspace(access: .granted, library: SamplePhotoLibrary(access: .granted), index: freshIndexPath("第一次点相簿.sqlite"))
	wait(5) { !firstClick.photos.albums.isEmpty }
	snapshot(
		"22-第一次点相簿", before: { firstClick.selection = nil }, then: { _, _ in firstClick.selection = .album("截屏") },
		RootView(workspace: firstClick))

	// 原图那一栏连续滚动：几页上下接成一长条。跳到第 12 页（页码栏点的就是这样）：先按页面大小排好了版，跳多远都落得准，
	// 上下露着相邻页，页码栏、右边的字都是第 12 页。
	let scrolling = workspace(["long.pdf"])
	let scrollDoc = scrolling.selected!
	wait(60) { scrollDoc.results[12] != nil }
	scrollDoc.stop()
	scrollDoc.show(page: 12)
	wait(10) { scrollDoc.pageImage != nil }
	snapshot("23-连续滚动", RootView(workspace: scrolling))

	// 横版的页（幻灯片导出的 PDF）矮，一屏放两三页：跳到最后一页时它对不到正中间，当前页也得是最后一页，不能是正中间的隔壁页。
	// 幻灯片在这里现画，不另要测试图。
	let slidesURL = out.appendingPathComponent("横版幻灯片.pdf")
	var slideBox = CGRect(x: 0, y: 0, width: 842, height: 595)
	if let pdf = CGContext(slidesURL as CFURL, mediaBox: &slideBox, nil) {
		for n in 1...8 {
			pdf.beginPDFPage(nil)
			SamplePhotoLibrary.text("第 \(n) 张幻灯片", size: 72, at: CGPoint(x: 120, y: 360), in: pdf)
			SamplePhotoLibrary.text("拾字连续滚动：横版的页一屏放得下两三页", size: 28, at: CGPoint(x: 120, y: 250), in: pdf)
			pdf.endPDFPage()
		}
		pdf.closePDF()
	}
	let slides = Workspace(recognizer: recognizer, photos: PhotosModel(
		library: SamplePhotoLibrary(access: .notDetermined), indexPath: freshIndexPath("幻灯片用的照片库.sqlite"), recognizer: recognizer))
	slides.open([slidesURL])
	let slidesDoc = slides.selected!
	wait(60) { !slidesDoc.isRunning }
	slidesDoc.show(page: 8)
	snapshot("24-横版跳到最后一页", RootView(workspace: slides))
	if slidesDoc.page != 8 { print("横版跳到最后一页：当前页成了第 \(slidesDoc.page) 页，应为 8") }

	// 实际把中栏的原生容器滚到底，不调用 show(page: 8) 冒充滚动成功。
	// 屏幕外没有滚轮动画；直接改容器位置仍会经过正式的可见页、画图、页码和文字同步逻辑。
	snapshot("29-横版滚到底自动跟到末页", before: { slidesDoc.show(page: 1) }, then: { _, window in
		guard let scroll = pageScroll(in: window) else { fatalError("找不到原图滚动容器") }
		var bounds = scroll.contentView.bounds
		bounds.origin.y = 100_000
		scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
		scroll.reflectScrolledClipView(scroll.contentView)
		wait(5) { slidesDoc.page == 8 && slidesDoc.pageImage != nil }
		precondition(slidesDoc.page == 8, "横版滚到底后必须是第 8 页，实际为 \(slidesDoc.page)")
	}, RootView(workspace: slides))

	// 混排的第 30 页尚未显示过时直接远跳；每页画上页码，截图能确认原图和右栏确实是同一页。
	let mixedURL = out.appendingPathComponent("横竖混排.pdf")
	if let pdf = CGContext(mixedURL as CFURL, mediaBox: &slideBox, nil) {
		for n in 1...32 {
			var box = CGRect(x: 0, y: 0, width: n.isMultiple(of: 2) ? 842 : 595, height: n.isMultiple(of: 2) ? 300 : 842)
			let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
			pdf.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
			SamplePhotoLibrary.text("第 \(n) 页", size: 48, at: CGPoint(x: 80, y: box.height / 2), in: pdf)
			SamplePhotoLibrary.text("横竖混排，原图和右栏必须对应", size: 24, at: CGPoint(x: 80, y: box.height / 2 - 50), in: pdf)
			pdf.endPDFPage()
		}
		pdf.closePDF()
	}
	let mixed = Workspace(recognizer: recognizer, photos: PhotosModel(
		library: SamplePhotoLibrary(access: .notDetermined), indexPath: freshIndexPath("混排用的照片库.sqlite"), recognizer: recognizer))
	mixed.open([mixedURL])
	let mixedDoc = mixed.selected!
	wait(60) { !mixedDoc.isRunning }
	snapshot("30-横竖混排远跳第30页", before: { mixedDoc.show(page: 1) }, then: { _, window in
		mixedDoc.show(page: 30)
		wait(5) { mixedDoc.pageImage != nil && (pageScroll(in: window)?.contentView.bounds.minY ?? 0) > 5_000 }
		precondition(mixedDoc.page == 30, "混排跳页后必须是第 30 页")
	}, RootView(workspace: mixed))

	// 照片分类（另一个文件里）。
	classifySnapshots()
}

/// 测试窗口里找中栏：页码栏较窄，文字栏排在右边；不按私有类名找 SwiftUI 内部节点。
@MainActor
func pageScroll(in window: NSWindow) -> NSScrollView? {
	func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
	guard let host = window.contentView else { return nil }
	return descendants(host).compactMap { $0 as? NSScrollView }
		.filter { $0.bounds.width > 200 && ($0.documentView?.bounds.height ?? 0) > $0.bounds.height + 1 }
		.min { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
}
