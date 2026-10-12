import OCRCore
import SwiftUI

/// 一个文件：左边原图（多页时最左边一条页码栏），右边认出的字；页头写状态和操作。
struct DocumentView: View {
	@Bindable var doc: DocumentModel
	/// 在相簿里点开的照片：页头写「第 3 / 78 张」。
	var position: String?
	@AppStorage(ViewOptions.showBoxes) private var showBoxes = true
	@AppStorage(ViewOptions.textMode) private var textMode = TextMode.page

	var body: some View {
		HSplitView {
			HStack(spacing: 0) {
				if doc.totalPages > 1 {
					PageStrip(doc: doc)
						.frame(width: 104)
					Divider()
				}
				// 换了文件就是一条新的：滚到哪、点了哪页不带过去。
				PageScroller(doc: doc)
					.id(doc.id)
			}
			.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
			TextPane(doc: doc)
				.frame(minWidth: 280, idealWidth: 380, maxWidth: 680, maxHeight: .infinity)
		}
		.navigationTitle(doc.name)
		.navigationSubtitle(subtitle)
		.toolbar { DocumentToolbar(doc: doc, showBoxes: $showBoxes, textMode: $textMode) }
	}

	var subtitle: String {
		guard let position else { return state }
		return state.isEmpty ? position : "\(position) · \(state)"
	}

	var state: String {
		switch doc.state {
		case .running:
			let current = min(doc.finishedCount + 1, doc.totalPages), total = doc.totalPages
			return total > 1 ? String(localized: "正在识别第 \(current) / \(total) 页") : String(localized: "正在识别")
		case .stopped:
			let finished = doc.finishedCount, total = doc.totalPages
			return String(localized: "认了 \(finished) 页就停了，共 \(total) 页")
		case .failed:
			return String(localized: "出错了")
		case .done:
			let total = doc.totalPages
			return total > 1 ? String(localized: "\(total) 页") : ""
		}
	}
}

/// 页头：最前面是右边那一栏的看法（整页 / 逐行，像访达切换显示方式那样放在工具栏上），后面是操作。
/// 识别中只有进度和「停止」；认完是重新识别、复制全文、导出。同样的命令菜单栏里也有，带快捷键。
struct DocumentToolbar: ToolbarContent {
	let doc: DocumentModel
	@Binding var showBoxes: Bool
	@Binding var textMode: TextMode

	var body: some ToolbarContent {
		ToolbarItem(placement: .primaryAction) {
			Picker("看法", selection: $textMode) {
				Text("整页").tag(TextMode.page)
				Text("逐行").tag(TextMode.lines)
			}
			.pickerStyle(.segmented)
			.help("整页给读和复制，逐行标出可能认错的（⌘1、⌘2）")
		}
		ToolbarItem(placement: .primaryAction) {
			RecognitionDetailsButton(doc: doc)
		}
		ToolbarItem(placement: .primaryAction) {
			Toggle(isOn: $showBoxes) {
				Label("显示识别框", systemImage: "rectangle.dashed")
			}
			.help(showBoxes ? String(localized: "隐藏原图上的识别框（⇧⌘B）") : String(localized: "显示原图上的识别框（⇧⌘B）"))
		}
		ToolbarItemGroup(placement: .primaryAction) {
			if doc.isRunning {
				ProgressView(value: Double(doc.finishedCount), total: Double(max(doc.totalPages, 1)))
					.progressViewStyle(.linear)
					.frame(width: 120)
				Button("停止") { doc.stop() }
					.help("停止识别（⌘.）")
			} else {
				Button("重新识别", systemImage: "arrow.clockwise") { doc.start() }
					.help("重新识别（⌘R）")
				Button("复制全文", systemImage: "doc.on.doc") { doc.copyAll() }
					.help("复制全文（⇧⌘C）")
					.disabled(doc.results.isEmpty)
				Menu("导出", systemImage: "square.and.arrow.up") {
					ForEach(DocumentModel.ExportFormat.allCases, id: \.self) { format in
						Button(format.title) { doc.export(format) }
					}
				}
				.help("导出…")
				.disabled(doc.results.isEmpty)
			}
		}
	}
}

/// 多页时左边那一条：缩略图加页码。还没认到的页淡一些，正在认的页码旁一个小转圈，认不了的一个红色感叹号。
struct PageStrip: View {
	let doc: DocumentModel

	var body: some View {
		ScrollViewReader { proxy in
			List(selection: Binding(get: { doc.page }, set: { if let n = $0 { doc.show(page: n) } })) {
				ForEach(1...doc.totalPages, id: \.self) { n in
					PageThumb(doc: doc, n: n).tag(n)
				}
			}
			.listStyle(.sidebar)
			.onChange(of: doc.page) { _, n in proxy.scrollTo(n) }
			// 回到这个文件、或者一打开就不在第 1 页：页码栏也滚到当前页（等排好版再滚，刚出来时滚不动）。
			.onAppear {
				guard doc.page > 1 else { return }
				DispatchQueue.main.async { proxy.scrollTo(doc.page) }
			}
		}
	}
}

struct PageThumb: View {
	let doc: DocumentModel
	let n: Int

	var body: some View {
		let finished = doc.results[n] != nil || doc.failures[n] != nil
		let working = doc.isRunning && !finished && n == firstUnfinished
		VStack(spacing: 4) {
			Group {
				if let thumb = doc.thumbnails[n] {
					Image(decorative: thumb, scale: 2)
						.resizable()
						.aspectRatio(contentMode: .fit)
				} else {
					Rectangle().fill(.quaternary).aspectRatio(0.71, contentMode: .fit)
				}
			}
			.frame(maxWidth: 64, maxHeight: 88)
			.overlay(Rectangle().strokeBorder(.separator))
			.opacity(finished || !doc.isRunning ? 1 : 0.5)
			HStack(spacing: 4) {
				if doc.failures[n] != nil {
					Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help("这一页认不了")
				} else if working {
					ProgressView().controlSize(.mini)
				}
				Text("\(n)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 4)
		.onAppear { doc.loadThumbnail(n) }
	}

	var firstUnfinished: Int {
		(1...doc.totalPages).first { doc.results[$0] == nil && doc.failures[$0] == nil } ?? 0
	}
}

/// 页头的「识别详情」：点开说这一页怎么认的、判定插件做了什么（没用插件也说为什么）。认完这一页才能点。
struct RecognitionDetailsButton: View {
	let doc: DocumentModel
	@State private var showing = false

	var body: some View {
		Button("识别详情", systemImage: "info.circle") { showing.toggle() }
			.help("识别详情：这一页怎么认的、判定插件做了什么")
			.disabled(doc.results[doc.page] == nil)
			.popover(isPresented: $showing, arrowEdge: .bottom) {
				if let result = doc.results[doc.page] {
					RecognitionDetails(
						report: RecognitionReport(
							result: result, options: doc.options, configured: doc.recognizer.engine.host.plugins, isPhoto: doc.photo != nil))
				}
			}
	}
}

struct RecognitionDetails: View {
	let report: RecognitionReport

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("这一页怎么认的").font(.headline)
			Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
				ForEach(report.items, id: \.self) { item in
					GridRow {
						Text(item.label).foregroundStyle(.secondary)
						Text(item.value)
					}
				}
			}
			Divider()
			Text("判定插件").font(.headline)
			VStack(alignment: .leading, spacing: 8) {
				ForEach(report.plugins, id: \.self) { line in
					Label {
						Text(line.text)
					} icon: {
						Image(systemName: line.problem ? "exclamationmark.triangle.fill" : "puzzlepiece.extension")
							.foregroundStyle(line.problem ? Color.orange : Color.secondary)
					}
				}
			}
		}
		.padding(16)
		.frame(width: 380, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
	}
}

/// 给出截图的工具用：一份样例的「识别详情」（看了图、复核了几行、拉正、切块）。
public struct RecognitionDetailsPreview: View {
	public init() {}

	public var body: some View {
		var page = PageResult(
			page: 1, width: 100, height: 100, mode: .document, lines: [], text: "", cleanText: "", document: nil, barcodes: [], notes: [],
			coordinateSpace: "original", rectifiedImage: nil,
			steps: [
				"route": [["name": "clef", "ms": 420, "signals": ["table": 0.82, "photo": 0.1]]], "signals": ["table": 0.82, "photo": 0.1],
				"review": [["name": "clef", "ms": 830, "reviewed": 3, "flagged": 1]], "reviewCandidates": 3,
				"rectified": ["kind": "paper", "skewDegrees": 7.6], "ms": 1240,
			])
		page.lines = [
			OCRLine(text: "一行", confidence: 0.3, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [], suspect: Suspect(reason: .plugin, probability: 0.9)),
			OCRLine(text: "一行", confidence: 0.3, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [], suspect: Suspect(reason: .lowConfidence, probability: nil)),
		]
		let clef = PluginConfig(name: "clef", command: ["/x"], hooks: ["route", "review"])
		return RecognitionDetails(report: RecognitionReport(result: page, options: OCROptions(), configured: [clef], isPhoto: false))
	}
}
