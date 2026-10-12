import Foundation
import Observation
import OCRCore

/// 设置页里存在 ~/.config/shizi/config.json 的几项（跟 MCP 服务用的是同一份）：判定插件（密钥进钥匙串）、识别语言。
@MainActor @Observable
public final class PluginSettings {
	public private(set) var plugins: [PluginConfig] = []
	/// 没指定语言时怎么认。放配置文件而不放 UserDefaults：灵犀、Claude Code 调识别服务时也照这个认。
	public private(set) var languagePreference: LanguagePreference = .auto
	/// 配置文件读不了时说一句。
	public private(set) var problem: String?
	@ObservationIgnored let path: String
	@ObservationIgnored let recognizer: Recognizer

	public init(path: String = OCRConfig.defaultPath(), recognizer: Recognizer = .shared) {
		self.path = path
		self.recognizer = recognizer
		reload()
	}

	public func reload() {
		let (config, problem) = OCRConfig.load(path: path)
		plugins = config.plugins ?? []
		languagePreference = config.languagePreference
		self.problem = problem
	}

	/// 改配置文件的一部分：先读最新的那份再改、再存，别的部分原样留着（插件和识别语言各改各的，谁也不冲掉谁）。
	/// 文件在、却读不了（手改坏了）时不写：照空的改完存回去，原来的插件就全没了。
	func update(_ change: (inout OCRConfig) -> Void) throws {
		let loaded = OCRConfig.load(path: path)
		if loaded.problem != nil { throw SettingsError("配置文件 \(path) 读不了，没改；先修好或删掉它") }
		var config = loaded.config
		change(&config)
		try config.save(path: path)
		plugins = config.plugins ?? []
		languagePreference = config.languagePreference
		problem = nil
		recognizer.reloadConfig()
	}

	func write(_ plugins: [PluginConfig]) throws {
		try update { $0.plugins = plugins }
	}

	/// 改识别语言。自动判断是默认，不写进文件。
	func setLanguagePreference(_ preference: LanguagePreference) throws {
		try update { $0.recognition = preference == .auto ? nil : RecognitionConfig(languages: preference.rawValue) }
	}

	/// 存一个插件：新加的（`original` 为 nil）或改过的。换了名字，钥匙串里的密钥跟着挪；换了地址又没重填密钥，旧密钥删掉
	/// （照灵犀的规矩：一家的密钥不带到另一个地址去）。
	func save(_ draft: PluginDraft, replacing original: PluginConfig?) throws {
		if let problem = draft.problem(existing: plugins.map(\.name).filter { $0 != original?.name }) { throw SettingsError(problem) }
		let oldName = original?.name
		let oldURL = original.flatMap { PluginDraft(config: $0).url }
		if let oldName, oldName != draft.name, draft.newKey.isEmpty, let key = PluginKeys.read(oldName) {
			try PluginKeys.save(key, for: draft.name)
		}
		if !draft.newKey.isEmpty {
			try PluginKeys.save(draft.newKey, for: draft.name)
		} else if let oldURL, PluginDraft.normalized(oldURL) != PluginDraft.normalized(draft.url) {
			PluginKeys.remove(draft.name)
		}
		if let oldName, oldName != draft.name { PluginKeys.remove(oldName) }
		var list = plugins
		let config = draft.config(keeping: original)
		if let i = list.firstIndex(where: { $0.name == oldName }) { list[i] = config } else { list.append(config) }
		try write(list)
	}

	func setEnabled(_ enabled: Bool, for name: String) throws {
		var list = plugins
		guard let i = list.firstIndex(where: { $0.name == name }) else { return }
		list[i].enabled = enabled ? nil : false
		try write(list)
	}

	/// 删插件，连同钥匙串里它的密钥。
	func remove(_ name: String) throws {
		try write(plugins.filter { $0.name != name })
		PluginKeys.remove(name)
	}

	/// 测连接：用还没存的这份设置跑一次插件的 describe。填了新密钥就用新的，没填就用钥匙串里存着的。
	func test(_ draft: PluginDraft, done: @escaping @MainActor (Result<[String: Any], PluginFailure>) -> Void) {
		var config = draft.config(keeping: nil)
		if !draft.newKey.isEmpty { config.env?["SYSTEMONE_KEY"] = draft.newKey }
		let host = PluginHost(config: OCRConfig(plugins: [config]))
		DispatchQueue.global(qos: .userInitiated).async {
			let result = host.call(config, hook: "describe", input: ["hooks": config.hooks], timeoutMs: 15_000)
			DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
		}
	}

	/// 拾字里带的插件程序在哪（出截图的工具写示例配置用）。
	public var pluginPath: String { PluginDraft.pluginPath }

	/// 这个插件是不是拾字带的 System One 插件（只有它能在设置页里改地址、模型）。
	nonisolated static func isSystemOne(_ config: PluginConfig) -> Bool {
		(config.command.first.map { ($0 as NSString).lastPathComponent }) == "ocr-plugin-systemone"
	}
}

/// 设置页里正在改的一个 System One 插件。
struct PluginDraft: Equatable {
	var name = ""
	var url = ""
	var model = ""
	/// 认之前看图（route，会发图）。
	var route = false
	/// 复核可能认错的行（review，会发认出的行）。
	var review = true
	/// 照片分类（classify，会发照片认出的字；看画面时发缩小的照片）。
	var classify = false
	var enabled = true
	/// 新填的密钥；空的表示不改。
	var newKey = ""

	init() {}

	init(config: PluginConfig) {
		name = config.name
		url = config.env?["SYSTEMONE_URL"] ?? ""
		model = config.env?["SYSTEMONE_MODEL"] ?? ""
		route = config.hooks.contains("route")
		review = config.hooks.contains("review")
		classify = config.hooks.contains("classify")
		enabled = config.enabled != false
	}

	/// 变回配置：地址、模型写进 env，别的 env（比如代理）照旧保留。
	func config(keeping original: PluginConfig?) -> PluginConfig {
		var env = original?.env ?? [:]
		env["SYSTEMONE_URL"] = url.trimmingCharacters(in: .whitespaces)
		env["SYSTEMONE_MODEL"] = model.trimmingCharacters(in: .whitespaces)
		env["SYSTEMONE_KEY"] = nil
		var hooks: [String] = []
		if route { hooks.append("route") }
		if review { hooks.append("review") }
		if classify { hooks.append("classify") }
		return PluginConfig(
			name: name, command: [PluginDraft.pluginPath], hooks: hooks, timeoutMs: original?.timeoutMs, env: env,
			enabled: enabled ? nil : false)
	}

	/// 拾字里带的插件程序：跟 App 的程序放在同一个文件夹（.app 里是 Contents/MacOS）。
	static var pluginPath: String {
		(Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL).appendingPathComponent("ocr-plugin-systemone").path
	}

	/// 名字：字母或数字开头，只用字母、数字、- 和 _，最多 32 个（跟灵犀给 MCP 服务起名的规矩一样）；也是钥匙串里的账号。
	static func nameProblem(_ name: String) -> String? {
		if name.isEmpty { return "要起个名字" }
		guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
			return "名字只能用英文字母、数字、- 和 _，字母或数字开头，最多 32 个"
		}
		return nil
	}

	/// 去掉末尾的 /、/v1、/v1/systemone，比地址时用。
	static func normalized(_ url: String) -> String {
		var s = url.trimmingCharacters(in: .whitespaces).lowercased()
		while s.hasSuffix("/") { s.removeLast() }
		for suffix in ["/v1/systemone", "/v1"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
		return s
	}

	/// 存不了的原因；能存返回 nil。`existing` 是别的插件的名字。
	func problem(existing: [String]) -> String? {
		if let p = Self.nameProblem(name) { return p }
		if existing.contains(name) { return "已经有一个叫「\(name)」的插件了" }
		guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else {
			return "地址要 http:// 或 https:// 开头"
		}
		if u.user != nil || u.password != nil { return "地址里不要带用户名密码" }
		if model.trimmingCharacters(in: .whitespaces).isEmpty { return "要填模型名" }
		if !route && !review && !classify { return "看图、复核、分类至少选一样" }
		if !newKey.isEmpty, let p = PluginKeys.problem(newKey) { return p }
		return nil
	}

	/// 这份设置会把什么发到哪个地址（设置页上要写明）。
	var egress: String {
		// 中文和英文、数字之间空一格；还没填好地址时说「这个地址」，前面不空。
		let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host.map { " \($0)" } ?? "这个地址"
		var what: [String] = []
		if route { what.append("每张要认的图（缩到长边 1600）") }
		if review { what.append("可能认错的行和前后两行") }
		if classify { what.append("分类时照片认出的字（看画面时是缩到长边 \(ClassifyBatch.previewPixels) 的照片）") }
		return what.isEmpty ? "" : "会把" + what.joined(separator: "、") + "发到\(host)。"
	}
}

/// 添加插件时给的几种预设：只是帮着填好地址和模型，存下来跟自己填的没有分别。
struct PluginPreset: Identifiable {
	let id: String
	let title: String
	let draft: PluginDraft
	let note: String

	static let all: [PluginPreset] = [
		preset("clef", "Clef", url: "http://", model: "clef", route: true, note: "局域网里的 Clef 服务，地址自己填；看图和复核都能接。"),
		preset("jev", "TypeSafe Jev", url: "https://api.typesafe.ai", model: "jev-latest", route: false, note: "收不收图，填好密钥后点「测试连接」看。"),
		preset("lingxi", "灵犀判定", url: "http://127.0.0.1:18486", model: "lingxi-decision", route: false, note: "灵犀自己的判定网关，不收图，只能接复核；密钥在灵犀的「实验室」里生成。"),
		preset("", "自己填", url: "https://", model: "", route: false, note: ""),
	]

	static func preset(_ name: String, _ title: String, url: String, model: String, route: Bool, note: String) -> PluginPreset {
		var d = PluginDraft()
		d.name = name
		d.url = url
		d.model = model
		d.route = route
		d.review = true
		// 分类只给 Clef 默认打开：在 Clef 上实际分过；别的服务没试过，自己打开。
		d.classify = name == "clef"
		return PluginPreset(id: title, title: title, draft: d, note: note)
	}
}
