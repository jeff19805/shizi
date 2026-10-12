import AppKit
import OCRCore
import SwiftUI

/// 设置窗口（⌘,）：识别（含照片）、判定插件、接入灵犀和 Claude Code。「关于」在菜单「拾字 › 关于拾字」（系统自带的那种）。
/// 照「系统设置」的写法：分组表单、左边标签右边控件；说明最多一句短的，细节放悬停提示。原来字太多、窗口太窄。
public struct SettingsView: View {
	public enum Tab: Hashable {
		case recognition, plugins, connect
	}

	/// 650：中文标签和右边的选项放得下一行，再窄就挤了。
	static let width: CGFloat = 650

	@State private var tab: Tab
	@State private var plugins: PluginSettings

	/// `plugins` 只给出截图的工具用：换一份示例配置。
	public init(tab: Tab = .recognition, plugins: PluginSettings? = nil) {
		_tab = State(initialValue: tab)
		_plugins = State(initialValue: plugins ?? PluginSettings())
	}

	public var body: some View {
		TabView(selection: $tab) {
			RecognitionTab(settings: plugins).tabItem { Label("识别", systemImage: "text.viewfinder") }.tag(Tab.recognition)
			PluginsTab(settings: plugins).tabItem { Label("判定插件", systemImage: "puzzlepiece.extension") }.tag(Tab.plugins)
			ConnectTab().tabItem { Label("接入", systemImage: "link") }.tag(Tab.connect)
		}
		.frame(width: Self.width)
	}
}

// MARK: 识别

struct RecognitionTab: View {
	/// 识别语言存在配置文件里（灵犀、Claude Code 调识别服务时也照着认），别的几项存在拾字自己的 UserDefaults。
	let settings: PluginSettings
	@State private var problem: String?
	@AppStorage(RecognitionDefaults.mode) private var mode = "auto"
	@AppStorage(RecognitionDefaults.rectify) private var rectify = "auto"
	@AppStorage(RecognitionDefaults.tiles) private var tiles = "auto"
	@AppStorage(RecognitionDefaults.barcodes) private var barcodes = true
	@AppStorage(RecognitionDefaults.textLayer) private var textLayer = true
	@AppStorage(RecognitionDefaults.plugins) private var plugins = true
	@AppStorage(RecognitionDefaults.photoDownload) private var photoDownload = true
	@AppStorage(RecognitionDefaults.photoPlugins) private var photoPlugins = false

	var body: some View {
		Form {
			Section("识别") {
				Picker("认法", selection: $mode) {
					Text("自动").tag("auto")
					Text("逐行").tag("lines")
					Text("认文档").tag("document")
				}
				.help("自动：自己看要不要按文档认（表格、分栏、竖排）。认文档要 macOS 26。")
				Picker("识别语言", selection: languageBinding) {
					Text("自动判断").tag(LanguagePreference.auto)
					Text("中文优先").tag(LanguagePreference.chineseFirst)
				}
				.help(
					"中文优先：先按中文认，汉字夹在字母、数字、算式里也认得准；整页几乎没有汉字（英文、西班牙文……）或有中文认不了的字（韩文、日文……）时，自动改回自动判断。灵犀、Claude Code 调识别服务时也照这个认。"
				)
				if let problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
				}
				Picker("拉正拍歪的纸", selection: $rectify) {
					Text("自动").tag("auto")
					Text("总是拉正").tag("on")
					Text("不拉正").tag("off")
				}
				.help("拍歪的纸先拉正再认。自动：明显歪了才拉。")
				Picker("大图里的小字", selection: $tiles) {
					Text("自动").tag("auto")
					Text("总是切块").tag("on")
					Text("不切块").tag("off")
				}
				.help("字很小时把图切成几块细认。")
				Toggle("PDF 里有文字时直接用", isOn: $textLayer)
					.help(
						"Word、浏览器导出的 PDF 里本来就有字：直接用，一字不差，也快得多；里面的图片另外认。扫描件、扫描件上别的软件加的隐形文字层、乱码的文字层照样认图上的字。认法选「认文档」时不用。"
					)
				Toggle("找二维码和条码", isOn: $barcodes)
				Toggle("用判定插件", isOn: $plugins)
					.help("认之前先看图、认完复核可能认错的行。插件在「判定插件」里加。")
			}
			Section("照片") {
				Toggle("原图在 iCloud 上时下载来认", isOn: $photoDownload)
					.help("下载的原图存进照片图库，占这台 Mac 的空间；剩余空间不到 3 GB 时不下载。")
				Toggle("认照片时也用判定插件", isOn: $photoPlugins)
					.help("会把每张照片缩小后发到插件的服务，所以默认不用。")
			}
		}
		.formStyle(.grouped)
		.scrollDisabled(true)
		.fixedSize(horizontal: false, vertical: true)
	}

	/// 选了就写进配置文件，识别引擎跟着重读；写不进去就说一句，选择留在原来那项。
	var languageBinding: Binding<LanguagePreference> {
		Binding(
			get: { settings.languagePreference },
			set: { preference in
				do {
					try settings.setLanguagePreference(preference)
					problem = nil
				} catch {
					problem = "\(error)"
				}
			})
	}
}

// MARK: 判定插件

struct PluginsTab: View {
	let settings: PluginSettings
	@State private var editing: EditTarget?
	@State private var deleting: String?
	@State private var problem: String?

	var body: some View {
		Form {
			Section {
				if settings.plugins.isEmpty {
					Text("还没有判定插件。不装也照样认字。").foregroundStyle(.secondary)
				}
				ForEach(settings.plugins, id: \.name) { p in
					PluginRow(
						plugin: p, enabled: Binding(get: { p.enabled != false }, set: { on in perform { try settings.setEnabled(on, for: p.name) } }),
						edit: { editing = EditTarget(original: p, preset: nil) }, delete: { deleting = p.name })
				}
			} header: {
				Text("判定插件")
			} footer: {
				HStack(alignment: .firstTextBaseline) {
					if let p = settings.problem ?? problem {
						Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
					} else {
						Text("密钥存在钥匙串里，不进配置文件。").foregroundStyle(.secondary)
					}
					Spacer()
					Menu("添加插件…") {
						ForEach(PluginPreset.all) { preset in
							Button(preset.title) { editing = EditTarget(original: nil, preset: preset) }
						}
					}
					.fixedSize()
				}
				.font(.callout)
			}
		}
		.formStyle(.grouped)
		.scrollDisabled(true)
		.fixedSize(horizontal: false, vertical: true)
		.sheet(item: $editing) { target in
			PluginEditor(settings: settings, target: target)
		}
		.confirmationDialog("删除「\(deleting ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
			Button("删除", role: .destructive) {
				if let name = deleting { perform { try settings.remove(name) } }
				deleting = nil
			}
			Button("取消", role: .cancel) { deleting = nil }
		} message: {
			Text("钥匙串里它的密钥也一起删掉。")
		}
	}

	func perform(_ action: () throws -> Void) {
		do {
			try action()
			problem = nil
		} catch {
			problem = "\(error)"
		}
	}
}

/// 给出截图的工具用：直接画「添加判定插件」那一页。
public struct PluginEditorPreview: View {
	let settings: PluginSettings
	public init(settings: PluginSettings) { self.settings = settings }
	public var body: some View {
		PluginEditor(settings: settings, target: EditTarget(original: nil, preset: PluginPreset.all[0]))
	}
}

struct EditTarget: Identifiable {
	let id = UUID()
	var original: PluginConfig?
	var preset: PluginPreset?
}

/// 判定插件的一行：名字、连到哪、用在哪；右边开关和 ⓘ（改）。右键还能删。
struct PluginRow: View {
	let plugin: PluginConfig
	@Binding var enabled: Bool
	let edit: () -> Void
	let delete: () -> Void

	var body: some View {
		let systemOne = PluginSettings.isSystemOne(plugin)
		HStack(spacing: 12) {
			Image(systemName: "puzzlepiece.extension")
				.foregroundStyle(.secondary)
				.frame(width: 20)
			VStack(alignment: .leading, spacing: 2) {
				Text(plugin.name).fontWeight(.medium)
				Text(detail(systemOne))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer()
			Toggle("启用", isOn: $enabled)
				.labelsHidden()
				.toggleStyle(.switch)
				.controlSize(.small)
				.help(enabled ? "停用（配置留着）" : "启用")
			Button(action: edit) {
				Image(systemName: "info.circle")
			}
			.buttonStyle(.borderless)
			.disabled(!systemOne)
			.help(systemOne ? "改地址、模型、密钥" : "这个插件不是拾字带的，在配置文件里改")
		}
		.contextMenu {
			Button("编辑…", action: edit).disabled(!systemOne)
			Button("删除…", action: delete)
		}
	}

	func detail(_ systemOne: Bool) -> String {
		var parts: [String] = []
		if systemOne {
			let draft = PluginDraft(config: plugin)
			parts.append(URL(string: draft.url)?.host ?? draft.url)
			parts.append(draft.model)
		} else {
			parts.append(plugin.command.first ?? "")
		}
		let names = ["route": "看图", "review": "复核", "classify": "分类"]
		parts.append(plugin.hooks.map { names[$0] ?? $0 }.joined(separator: "、"))
		return parts.filter { !$0.isEmpty }.joined(separator: " · ")
	}
}

/// 添加或修改一个 System One 判定插件。测连接用的是还没存的这份设置。
struct PluginEditor: View {
	let settings: PluginSettings
	let target: EditTarget
	@Environment(\.dismiss) private var dismiss
	@State private var draft: PluginDraft
	@State private var hasKey: Bool
	@State private var testing = false
	@State private var outcome: TestOutcome?
	@State private var problem: String?

	init(settings: PluginSettings, target: EditTarget) {
		self.settings = settings
		self.target = target
		let draft = target.original.map(PluginDraft.init(config:)) ?? target.preset?.draft ?? PluginDraft()
		_draft = State(initialValue: draft)
		_hasKey = State(initialValue: target.original.map { PluginKeys.has($0.name) } ?? false)
	}

	/// 标题、结果、按钮往里收 20，跟下面分组表单的边对齐（分组表单自己会往里收 20）。
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 4) {
				Text(target.original.map { "改「\($0.name)」" } ?? "添加判定插件\(target.preset.map { "：\($0.title)" } ?? "")")
					.font(.headline)
				if let note = target.preset?.note, !note.isEmpty {
					Text(note).font(.callout).foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 20)
			Form {
				Section {
					TextField("名字", text: $draft.name, prompt: Text("英文字母、数字、- 和 _"))
					TextField("地址", text: $draft.url, prompt: Text("http://地址:端口"))
					TextField("模型", text: $draft.model)
					SecureField("密钥", text: $draft.newKey, prompt: Text(hasKey ? "已存在钥匙串 · 留空不变" : "还没存"))
				}
				Section {
					Toggle("看图（认之前把图发过去）", isOn: $draft.route)
					Toggle("复核可能认错的行", isOn: $draft.review)
					Toggle("分类照片（把认出的字或缩小的照片发过去）", isOn: $draft.classify)
					Toggle("启用", isOn: $draft.enabled)
				} footer: {
					if !draft.egress.isEmpty {
						Text(draft.egress).font(.callout).foregroundStyle(.secondary)
					}
				}
			}
			.formStyle(.grouped)
			.scrollDisabled(true)
			.fixedSize(horizontal: false, vertical: true)
			Group {
				if let outcome { outcome.view }
				if let problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
				}
				HStack(spacing: 8) {
					Button("测试连接") { test() }
						.disabled(testing)
					if testing { ProgressView().controlSize(.small) }
					Spacer()
					Button("取消", role: .cancel) { dismiss() }
						.keyboardShortcut(.cancelAction)
					Button("保存") { save() }
						.keyboardShortcut(.defaultAction)
				}
			}
			.padding(.horizontal, 20)
		}
		.padding(.vertical, 20)
		.frame(width: 520)
		.onChange(of: draft) { outcome = nil }
	}

	func test() {
		let others = settings.plugins.map(\.name).filter { $0 != target.original?.name }
		if let p = draft.problem(existing: others) {
			problem = p
			return
		}
		problem = nil
		testing = true
		settings.test(draft) { result in
			testing = false
			outcome = TestOutcome(result)
		}
	}

	func save() {
		do {
			try settings.save(draft, replacing: target.original)
			dismiss()
		} catch {
			problem = "\(error)"
		}
	}
}

/// 测连接的结果：通了说耗时、服务报的模型版本、收不收图；不通说一句为什么。成功不用绿色（设计规范：正常时不出声）。
struct TestOutcome {
	var lines: [String] = []
	var warnings: [String] = []
	var failure: String?

	init(_ result: Result<[String: Any], PluginFailure>) {
		switch result {
		case .success(let out):
			var parts: [String] = []
			if let ms = (out["elapsedMs"] as? NSNumber)?.intValue { parts.append("\(ms) 毫秒") }
			if let m = out["serverModel"] as? String { parts.append("服务说它是 \(m)") }
			if let images = out["images"] as? String { parts.append(images == "收" ? "收图" : "不收图") }
			lines = ["通了" + (parts.isEmpty ? "" : "：" + parts.joined(separator: "，"))]
			warnings = out["warnings"] as? [String] ?? []
		case .failure(let f):
			failure = f.message
		}
	}

	@ViewBuilder var view: some View {
		VStack(alignment: .leading, spacing: 4) {
			if let failure {
				Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
			}
			ForEach(lines, id: \.self) { Label($0, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
			ForEach(warnings, id: \.self) { w in
				Label {
					Text(w)
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
				}
			}
		}
		.font(.callout)
	}
}

// MARK: 接入

/// 让灵犀、Claude Code 这些助手也能用拾字认字（MCP）。一个助手一行：现在接没接、一个按钮；命令和路径放在悬停提示里，不铺在页面上。
struct ConnectTab: View {
	@State private var lingxi: LingxiStatus = LingxiStatus.read()
	@State private var confirming = false
	@State private var changed = false
	@State private var problem: String?
	/// 刚复制的是哪一个（按钮上暂时写「已复制」）。
	@State private var copied: String?

	static var serverPath: String {
		(Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL).appendingPathComponent("shizi-mcp").path
	}

	var body: some View {
		let path = Self.serverPath
		let claude = "claude mcp add shizi -- '\(path)'"
		let json = "{ \"mcpServers\": { \"shizi\": { \"command\": \"\(path)\" } } }"
		Form {
			Section {
				LabeledContent {
					lingxiAction(path)
				} label: {
					ClientLabel(title: "灵犀", detail: lingxiDetail(path), symbol: "sparkles")
				}
				LabeledContent {
					copyButton("复制命令", text: claude)
				} label: {
					ClientLabel(title: "Claude Code", detail: "复制以后在终端里运行", symbol: "terminal")
				}
				LabeledContent {
					copyButton("复制配置", text: json)
				} label: {
					ClientLabel(title: "别的助手", detail: "写进它的 MCP 配置", symbol: "ellipsis.curlybraces")
				}
			} header: {
				Text("让灵犀、Claude Code 这些助手也能用拾字认字")
			} footer: {
				if let problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
				} else if changed {
					Text("改好了。在灵犀里重启 ocr 才用上。").foregroundStyle(.secondary).font(.callout)
				}
			}
			Section {
				LabeledContent("识别服务") {
					HStack(spacing: 8) {
						Text((path as NSString).abbreviatingWithTildeInPath)
							.lineLimit(1)
							.truncationMode(.middle)
							.foregroundStyle(.secondary)
							.help(path)
						Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
					}
				}
			}
		}
		.formStyle(.grouped)
		.scrollDisabled(true)
		.fixedSize(horizontal: false, vertical: true)
		.confirmationDialog("改灵犀的配置？", isPresented: $confirming) {
			Button(lingxi.entry == nil ? "接入" : "改") { apply(path) }
			Button("取消", role: .cancel) {}
		} message: {
			Text(
				(lingxi.entry == nil
					? "在 \(LingxiConfig.path) 末尾加一节 [mcpServers.\(LingxiConfig.defaultName)]，用拾字里带的识别服务："
					: "把 \(LingxiConfig.path) 里 [mcpServers.\(lingxi.entry!.name)] 的 command 换成：")
					+ "\n\(path)\n原来的文件另存一份「config.toml.拾字备份」。")
		}
	}

	func lingxiDetail(_ path: String) -> String {
		guard lingxi.found else { return "没找到灵犀（装好、打开过一次以后再来）" }
		guard let entry = lingxi.entry else { return "还没接入" }
		if entry.command == path { return "已接入，用的是拾字里带的" }
		if let c = entry.command, !FileManager.default.fileExists(atPath: c) { return "接着的识别服务已经不在了" }
		return "用的是别的识别服务"
	}

	@ViewBuilder func lingxiAction(_ path: String) -> some View {
		if !lingxi.found {
			EmptyView()
		} else if let entry = lingxi.entry {
			if entry.command == path {
				Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("灵犀里的「\(entry.name)」用的就是拾字里带的")
			} else {
				Button("改成拾字里带的…") { confirming = true }
					.help("灵犀里的「\(entry.name)」现在用的是：\(entry.command ?? "（没写 command）")")
			}
		} else {
			Button("接入…") { confirming = true }
		}
	}

	func copyButton(_ title: String, text: String) -> some View {
		Button(copied == text ? "已复制" : title) {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
			copied = text
			Task {
				try? await Task.sleep(for: .seconds(1.5))
				if copied == text { copied = nil }
			}
		}
		.help(text)
	}

	func apply(_ path: String) {
		do {
			let text = (try? String(contentsOfFile: LingxiConfig.path, encoding: .utf8)) ?? ""
			let updated =
				lingxi.entry.map { LingxiConfig.setCommand(path, section: $0.name, in: text) } ?? LingxiConfig.appendSection(command: path, to: text)
			try LingxiConfig.write(updated)
			lingxi = LingxiStatus.read()
			changed = true
			problem = nil
		} catch {
			problem = "没改成：\(error.localizedDescription)"
		}
	}
}

/// 接入页一行左边：图标、助手的名字，下面一行现在怎样。
struct ClientLabel: View {
	let title: String
	let detail: String
	let symbol: String

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: symbol)
				.foregroundStyle(.secondary)
				.frame(width: 20)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).fontWeight(.medium)
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}

struct LingxiStatus {
	var found: Bool
	var entry: LingxiConfig.Entry?

	static func read() -> LingxiStatus {
		guard let text = try? String(contentsOfFile: LingxiConfig.path, encoding: .utf8) else { return LingxiStatus(found: false) }
		return LingxiStatus(found: true, entry: LingxiConfig.find(in: text))
	}
}

/// 菜单「拾字 › 关于拾字」：系统自带的「关于」窗口，写版本和一句话（原来是设置里的一个标签页）。
public enum AboutPanel {
	@MainActor public static func show() {
		let center = NSMutableParagraphStyle()
		center.alignment = .center
		let credits = NSAttributedString(
			string: "把图里的字拾出来。\nmacOS 自带的文字识别，全在本机，不联网。",
			attributes: [
				.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
			])
		// 版本号只写一遍：Info.plist 里两个版本号一样，系统默认会写成「0.0.20 (0.0.20)」。
		NSApp.orderFrontStandardAboutPanel(options: [
			.applicationName: "拾字", .applicationVersion: OCRVersion.current, .version: "", .credits: credits,
		])
	}
}
