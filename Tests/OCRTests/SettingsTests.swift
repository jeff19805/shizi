import Foundation
import Testing
@testable import OCRCore
@testable import ShiziKit

@Test func 插件名字的规矩() {
	#expect(PluginDraft.nameProblem("clef") == nil && PluginDraft.nameProblem("jev-2_b") == nil)
	for bad in ["", "-clef", "带中文", "有 空格", "a;b", String(repeating: "x", count: 33)] {
		#expect(PluginDraft.nameProblem(bad) != nil, "「\(bad)」不该放行")
	}
}

@Test func 插件设置的检查() {
	var d = PluginPreset.all[0].draft
	d.url = "http://clef.local:8000"
	#expect(d.problem(existing: []) == nil)
	#expect(d.problem(existing: ["clef"])?.contains("已经有") == true)
	var e = d
	e.url = "ftp://x"
	#expect(e.problem(existing: [])?.contains("http") == true)
	e = d
	e.url = "http://user:pw@x"
	#expect(e.problem(existing: [])?.contains("用户名密码") == true)
	e = d
	e.model = " "
	#expect(e.problem(existing: []) != nil)
	e = d
	e.route = false
	e.review = false
	e.classify = false
	#expect(e.problem(existing: []) == "看图、复核、分类至少选一样")
	e.classify = true
	#expect(e.problem(existing: []) == nil, "只接分类也行")
	#expect(e.config(keeping: nil).hooks == ["classify"] && PluginDraft(config: e.config(keeping: nil)).classify)
	#expect(e.egress == "会把分类时照片认出的字（看画面时是缩到长边 360 的照片）发到 clef.local。")
	#expect(PluginPreset.all.first { $0.id == "Clef" }?.draft.classify == true && PluginPreset.all.first { $0.id == "TypeSafe Jev" }?.draft.classify == false)
	e = d
	e.newKey = "有中文的密钥"
	#expect(e.problem(existing: []) != nil)
	#expect(PluginKeys.problem("sk-123\nabc") != nil && PluginKeys.problem("sk-123_\"$`\\ ok") == nil)
}

@Test func 插件设置和配置互相转() {
	let original = PluginConfig(
		name: "clef", command: ["/旧/ocr-plugin-systemone"], hooks: ["route", "review"], timeoutMs: 4000,
		env: ["SYSTEMONE_URL": "http://a:1", "SYSTEMONE_MODEL": "clef", "SYSTEMONE_PROXY": "http://127.0.0.1:7890"], enabled: false)
	var d = PluginDraft(config: original)
	#expect(d.name == "clef" && d.url == "http://a:1" && d.model == "clef" && d.route && d.review && !d.enabled)
	d.url = "http://b:2"
	d.route = false
	d.enabled = true
	let c = d.config(keeping: original)
	#expect(c.hooks == ["review"] && c.enabled == nil && c.timeoutMs == 4000)
	#expect(c.env?["SYSTEMONE_URL"] == "http://b:2" && c.env?["SYSTEMONE_PROXY"] == "http://127.0.0.1:7890", "别的 env 要留着")
	#expect(c.command.first?.hasSuffix("/ocr-plugin-systemone") == true && PluginSettings.isSystemOne(c))
	#expect(d.egress == "会把可能认错的行和前后两行发到 b。")
	#expect(PluginDraft.normalized("HTTP://A:1/v1/systemone/") == PluginDraft.normalized("http://a:1"))
}

@MainActor @Test func 插件设置读写配置文件() throws {
	let path = Fixtures.tempURL("json").path
	let settings = PluginSettings(path: path, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	#expect(settings.plugins.isEmpty && settings.problem == nil)
	// 用不会跟真插件撞名的名字：保存时会去钥匙串里挪、删同名的密钥。
	let name = "t\(UUID().uuidString.prefix(8))"
	var d = PluginPreset.all[0].draft
	d.name = name
	d.url = "http://127.0.0.1:9"
	try settings.save(d, replacing: nil)
	#expect(OCRConfig.load(path: path).config.plugins?.map(\.name) == [name])
	try settings.setEnabled(false, for: name)
	#expect(OCRConfig.load(path: path).config.plugins?.first?.enabled == false)
	var renamed = PluginDraft(config: settings.plugins[0])
	renamed.name = name + "x"
	try settings.save(renamed, replacing: settings.plugins[0])
	#expect(settings.plugins.map(\.name) == [name + "x"])
	#expect(throws: SettingsError.self) { try settings.save(renamed, replacing: nil) }
	try settings.remove(name + "x")
	#expect(OCRConfig.load(path: path).config.plugins?.isEmpty == true)
}

@Test func 改灵犀配置只动那一行() {
	let text = """
		# 灵犀的配置
		model = "x"

		[mcpServers.browser]
		command = "/usr/local/bin/browser-mcp"

		[mcpServers.ocr]
		command = "/Users/me/.local/bin/mac-ocr-mcp"   # 本机文字识别
		description = "本机文字识别"
		timeoutMs = 300000

		[other]
		command = "不是 MCP 的"
		"""
	#expect(LingxiConfig.find(in: text) == LingxiConfig.Entry(name: "ocr", command: "/Users/me/.local/bin/mac-ocr-mcp"))
	let updated = LingxiConfig.setCommand("/Applications/拾字 \"新\".app/Contents/MacOS/shizi-mcp", section: "ocr", in: text)
	#expect(LingxiConfig.find(in: updated)?.command == "/Applications/拾字 \"新\".app/Contents/MacOS/shizi-mcp")
	let changed = zip(text.components(separatedBy: "\n"), updated.components(separatedBy: "\n")).filter { $0 != $1 }
	#expect(changed.count == 1, "只该改一行：\(changed)")
	#expect(updated.contains(#"command = "/usr/local/bin/browser-mcp""#) && updated.contains(#"command = "不是 MCP 的""#))

	// 名字不叫 ocr，但 command 指向 shizi-mcp（或改名前的 mac-ocr-mcp）的也认得。
	let other = "[mcpServers.wenzi]\ncommand = '/x/shizi-mcp'\n"
	#expect(LingxiConfig.find(in: other) == LingxiConfig.Entry(name: "wenzi", command: "/x/shizi-mcp"))
	let old = "[mcpServers.wenzi]\ncommand = '/x/mac-ocr-mcp'\n"
	#expect(LingxiConfig.find(in: old) == LingxiConfig.Entry(name: "wenzi", command: "/x/mac-ocr-mcp"))
	// 那一节没有 command：在节标题下面加一行。
	let bare = LingxiConfig.setCommand("/a/shizi-mcp", section: "ocr", in: "[mcpServers.ocr]\ntimeoutMs = 1\n")
	#expect(bare == "[mcpServers.ocr]\ncommand = \"/a/shizi-mcp\"\ntimeoutMs = 1\n")
	// 还没接入：末尾加一节，原来的不动。
	let appended = LingxiConfig.appendSection(command: "/a/shizi-mcp", to: "[mcpServers.browser]\ncommand = \"/b\"")
	#expect(appended.hasPrefix("[mcpServers.browser]\ncommand = \"/b\"\n\n[mcpServers.ocr]\ncommand = \"/a/shizi-mcp\"\n"))
	#expect(LingxiConfig.find(in: appended)?.command == "/a/shizi-mcp")
	#expect(LingxiConfig.find(in: "[mcpServers.browser]\ncommand = \"/b\"") == nil)
}

@Test func 配置文件的位置和改名前的旧配置() throws {
	let fm = FileManager.default
	let home = Fixtures.tempURL("home").path
	defer { try? fm.removeItem(atPath: home) }
	let new = home + "/.config/shizi/config.json", old = home + "/.config/mac-ocr-mcp/config.json"
	#expect(OCRConfig.defaultPath([:], home: home) == new)
	#expect(OCRConfig.defaultPath(["SHIZI_CONFIG": "/a.json"], home: home) == "/a.json")
	#expect(OCRConfig.defaultPath(["MAC_OCR_MCP_CONFIG": "/b.json"], home: home) == "/b.json", "改名前的环境变量也认")

	OCRConfig.copyOldConfigIfNeeded([:], home: home)
	#expect(!fm.fileExists(atPath: home + "/.config/shizi"), "新旧都没有时什么都不做，文件夹也不建")

	try OCRConfig(recognition: RecognitionConfig(languages: "chinese-first")).save(path: old)
	OCRConfig.copyOldConfigIfNeeded(["SHIZI_CONFIG": "/指定了的.json"], home: home)
	#expect(!fm.fileExists(atPath: new), "用环境变量指定了配置文件的不搬")
	OCRConfig.copyOldConfigIfNeeded([:], home: home)
	#expect(OCRConfig.load(path: new).config.languagePreference == .chineseFirst)
	#expect(fm.fileExists(atPath: old), "旧的留着：升级前起的服务还在读它")
	#expect(try fm.contentsOfDirectory(atPath: home + "/.config/shizi") == ["config.json"], "复制用的临时文件没留下")

	try OCRConfig().save(path: new)
	OCRConfig.copyOldConfigIfNeeded([:], home: home)
	#expect(OCRConfig.load(path: new).config.languagePreference == .auto, "新位置已经有了，不再拿旧的盖")
}

@Test func 识别的默认选项() throws {
	let defaults = try #require(UserDefaults(suiteName: "拾字测试-\(UUID().uuidString)"))
	var o = RecognitionDefaults.options(defaults)
	#expect(o.mode == .auto && o.rectify == .auto && o.tiles == .auto && o.barcodes && o.usePlugins)
	defaults.set("document", forKey: RecognitionDefaults.mode)
	defaults.set("off", forKey: RecognitionDefaults.rectify)
	defaults.set(false, forKey: RecognitionDefaults.plugins)
	o = RecognitionDefaults.options(defaults)
	#expect(o.mode == .document && o.rectify == .off && !o.usePlugins)

	// 认照片：跟着文件的认法，插件另有开关、默认不用；原图默认下载。
	defaults.set(true, forKey: RecognitionDefaults.plugins)
	o = RecognitionDefaults.photoOptions(defaults)
	#expect(o.mode == .document && !o.usePlugins && RecognitionDefaults.downloadOriginals(defaults))
	defaults.set(true, forKey: RecognitionDefaults.photoPlugins)
	defaults.set(false, forKey: RecognitionDefaults.photoDownload)
	#expect(RecognitionDefaults.photoOptions(defaults).usePlugins && !RecognitionDefaults.downloadOriginals(defaults))
}

/// 要动真的钥匙串，平时不跑：SHIZI_KEYCHAIN_TEST=1 ./scripts/test.sh --filter 钥匙串
/// 拾字用 security 存密钥，插件用 security 读：中间不弹确认，密钥原样发到服务（带引号、反斜杠这些也不走样）。
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIZI_KEYCHAIN_TEST"] == "1"))
func 钥匙串存的密钥插件读得到() throws {
	let name = "t\(UUID().uuidString.prefix(8))"
	let key = #"sk-test_"$`\ ok'end"#
	defer { PluginKeys.remove(name) }
	try PluginKeys.save(key, for: name)
	#expect(PluginKeys.has(name) && PluginKeys.read(name) == key)
	let server = try FakeSystemOne(goodAnswers)
	let (host, p) = systemOne(server, name: name, key: nil)
	_ = try host.call(p, hook: "describe", input: [:]).get()
	#expect(server.requests.first?.headers["authorization"] == "Bearer " + key)
	PluginKeys.remove(name)
	#expect(!PluginKeys.has(name))
}

/// 也要动真的钥匙串：SHIZI_KEYCHAIN_TEST=1 ./scripts/test.sh --filter 钥匙串
/// 改名前（0.0.35 及以前）密钥存在服务 mac-ocr-mcp 下面：拾字看得到、插件读得到；存新的以后用新的；删的时候新旧两边都删。
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIZI_KEYCHAIN_TEST"] == "1"))
func 钥匙串里改名前存的密钥也认() throws {
	let name = "t\(UUID().uuidString.prefix(8))"
	let key = "sk-old-key"
	defer { PluginKeys.remove(name) }
	let hex = key.utf8.map { String(format: "%02x", $0) }.joined()
	#expect(PluginKeys.run(["-i"], input: "add-generic-password -U -s \(PluginKeys.oldService) -a \(name) -X \(hex)\n").status == 0)
	#expect(PluginKeys.has(name) && !PluginKeys.has(name, in: [PluginKeys.service]) && PluginKeys.read(name) == key)
	let server = try FakeSystemOne(goodAnswers)
	let (host, p) = systemOne(server, name: name, key: nil)
	_ = try host.call(p, hook: "describe", input: [:]).get()
	#expect(server.requests.first?.headers["authorization"] == "Bearer " + key)
	try PluginKeys.save("sk-new-key", for: name)
	#expect(PluginKeys.has(name, in: [PluginKeys.service]) && PluginKeys.read(name) == "sk-new-key")
	PluginKeys.remove(name)
	#expect(!PluginKeys.has(name), "新旧两个服务下的都该删掉")
}
