import AppKit
import OCRCore
import SwiftUI

/// 「分类」那一小窗：看认出的字（不发照片）还是看画面（发缩小的照片）；按类别分（一行一个「名称：判断标准」），
/// 或者按一句条件找。写明会把什么发到哪。看字、看画面的类别和条件各记各的，切来切去写的还在。
struct ClassifySheet: View {
	@Bindable var photos: PhotosModel
	@Environment(\.dismiss) private var dismiss
	@State private var input: ClassifyRules.Input
	@State private var modes: [ClassifyRules.Input: ClassifyRules.Mode]
	@State private var topics: [ClassifyRules.Input: String]
	@State private var conditions: [ClassifyRules.Input: String]
	@State private var problem: String?

	init(photos: PhotosModel) {
		self.photos = photos
		let d = photos.defaults
		_input = State(initialValue: ClassifySettings.input(d))
		_modes = State(initialValue: [.text: ClassifySettings.mode(d, .text), .image: ClassifySettings.mode(d, .image)])
		_topics = State(initialValue: [.text: ClassifySettings.topicsText(d, .text), .image: ClassifySettings.topicsText(d, .image)])
		_conditions = State(initialValue: [.text: ClassifySettings.conditionText(d, .text), .image: ClassifySettings.conditionText(d, .image)])
	}

	var mode: ClassifyRules.Mode { modes[input] ?? .topics }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("分类").font(.headline)
			if photos.classifyPlugin == nil {
				Text("还没有能分类的判定插件。在「设置 › 判定插件」里改一个插件（比如 Clef），打开「分类照片」。")
					.foregroundStyle(.secondary)
				SettingsLink { Text("打开设置") }
			} else {
				HStack(spacing: 12) {
					Picker("看什么", selection: $input) {
						Text("看认出的字").tag(ClassifyRules.Input.text)
						Text("看画面").tag(ClassifyRules.Input.image)
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					Picker("分法", selection: Binding(get: { mode }, set: { modes[input] = $0 })) {
						Text("按类别分").tag(ClassifyRules.Mode.topics)
						Text("按一句条件找").tag(ClassifyRules.Mode.condition)
					}
					.pickerStyle(.segmented)
					.labelsHidden()
				}
				if mode == .topics {
					TextEditor(text: Binding(get: { topics[input] ?? "" }, set: { topics[input] = $0 }))
						.font(.body)
						.scrollContentBackground(.hidden)
						.padding(4)
						.frame(height: 180)
						.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
						.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
					HStack(alignment: .firstTextBaseline) {
						Text("一行一个「名称：判断标准」，1 到 8 个；一张可以同时是几类。")
						Spacer()
						Button("用默认的") { topics[input] = input == .image ? ClassifyRules.defaultImageTopics : ClassifyRules.defaultTopics }
							.controlSize(.small)
					}
					.font(.callout)
					.foregroundStyle(.secondary)
				} else {
					TextField(
						"要找什么", text: Binding(get: { conditions[input] ?? "" }, set: { conditions[input] = $0 }),
						prompt: Text(input == .image ? String(localized: "比如：照片里有猫") : String(localized: "比如：包含付款期限的约定")),
						axis: .vertical
					)
					.lineLimit(2...4)
					.textFieldStyle(.roundedBorder)
					Text("每张照片说符合还是不符合，拿不准的算待确认。").font(.callout).foregroundStyle(.secondary)
				}
				Text(scope).font(.callout).foregroundStyle(.secondary)
				if let problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
				}
			}
			HStack {
				Spacer()
				Button("取消", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("开始分类") { start() }
					.keyboardShortcut(.defaultAction)
					.disabled(photos.classifyPlugin == nil || photos.classifiable(input).isEmpty)
			}
		}
		.padding(20)
		.frame(width: 560)
		.onChange(of: input) { problem = nil }
	}

	/// 分哪些、把什么发到哪：看字只发认出的字（没认的照片要先「识别」）；看画面发缩小的照片，不下载原图。
	var scope: String {
		let where_ = photos.classifyDestination ?? String(localized: "判定插件")
		if input == .image {
			let n = photos.assets.count
			return String(localized: "分这个相簿的 \(n) 张：把每张照片缩到 \(ClassifyBatch.previewPixels) 像素发到 \(where_)（一张几十 KB），不下载 iCloud 上的原图。")
		}
		let n = photos.classifiable(.text).count
		let c = photos.counts
		let notYet = c.total - c.recognized
		guard n > 0 else { return String(localized: "这个相簿里还没有认出字的照片，先点「识别」；或者换成「看画面」。") }
		var text = String(localized: "分这个相簿里认出字的 \(n) 张：只把认出的字发到 \(where_)，不发照片。")
		if notYet > 0 { text += String(localized: "还有 \(notYet) 张没认，先点「识别」才分得到。") }
		return text
	}

	func start() {
		let source = mode == .topics ? (topics[input] ?? "") : (conditions[input] ?? "")
		do {
			photos.classify(try ClassifyRules.parse(mode: mode, source: source, input: input), source: source)
			dismiss()
		} catch {
			problem = "\(error)"
		}
	}
}

/// 网格上面的一排：全部、每一类、待确认、没有字，各几张；点一项网格只看那一类。选了一类可以「存为相簿…」。
struct LabelFilterBar: View {
	@Bindable var photos: PhotosModel

	var body: some View {
		HStack(spacing: 8) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					chip(String(localized: "全部"), count: photos.assets.count, selected: photos.labelFilter == nil) { photos.labelFilter = nil }
					ForEach(photos.labelCounts, id: \.label) { item in
						chip(Self.shown(item.label), count: item.count, selected: photos.labelFilter == item.label) { photos.labelFilter = item.label }
							.disabled(item.count == 0)
					}
				}
			}
			if photos.classifyRun == nil, photos.unclassifiedCount > 0 {
				Text("还有 \(photos.unclassifiedCount) 张没分")
					.font(.callout)
					.foregroundStyle(.secondary)
					.help(
						photos.classifyRules?.input == .image
							? String(localized: "这几张是分过类以后才加进来的（或者照片改过），也可能上次没分成；再点「分类」只问它们")
							: String(localized: "这几张是分过类以后才认出字的（或者字变了），也可能上次没分成；再点「分类」只问它们"))
			}
			if let filter = photos.labelFilter.map(Self.shown), photos.labelFilter != PhotosModel.noText {
				Button("存为相簿…") { photos.askNewAlbum(photos.shownAssets, name: String(localized: "拾字 · \(filter)")) }
					.help("把「\(filter)」这 \(photos.shownAssets.count) 张放进一个新相簿（照片不复制）")
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}

	/// 识别核心定的几个固定标签（待确认、符合条件、不符合条件）只在显示时换成界面的语言；筛选、存进照片库的还是原来的值。
	/// 类别名是用户自己写的，原样显示。
	static func shown(_ label: String) -> String {
		switch label {
		case ClassifyRules.undecided: return String(localized: "待确认")
		case ClassifyRules.matched: return String(localized: "符合条件")
		case ClassifyRules.unmatched: return String(localized: "不符合条件")
		default: return label
		}
	}

	/// 一项：名字加张数；选中的用强调色（界面规范：强调色只给选中、进度、主按钮）。
	func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 4) {
				Text(title)
				Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
			}
			.font(.callout)
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.foregroundStyle(selected ? Color.white : Color.primary)
			.background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
			.contentShape(RoundedRectangle(cornerRadius: 6))
		}
		.buttonStyle(.plain)
	}
}

/// 给出截图的工具用：直接画「分类」那一小窗。
public struct ClassifySheetPreview: View {
	let photos: PhotosModel
	public init(photos: PhotosModel) { self.photos = photos }
	public var body: some View { ClassifySheet(photos: photos) }
}
