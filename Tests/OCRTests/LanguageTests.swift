import CoreGraphics
import Foundation
import Testing
@testable import OCRCore
@testable import OCRServer
@testable import ShiziKit

/// 配置里设了「中文优先」的识别引擎。
let chineseFirstEngine = OCREngine(config: OCRConfig(recognition: RecognitionConfig(languages: "chinese-first")))

func oneLine(_ text: String) -> [OCRLine] {
	[OCRLine(text: text, confidence: 1, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [])]
}

@Test func 英文里的全角标点改回半角() {
	#expect(halfWidthPunctuationInLatin("function add（a,b）；") == "function add(a,b);")
	#expect(halfWidthPunctuationInLatin("\"format\"： 1，") == "\"format\": 1,")
	#expect(halfWidthPunctuationInLatin("｝") == "}")
	#expect(halfWidthPunctuationInLatin("What is your nature？") == "What is your nature?")
	#expect(halfWidthPunctuationInLatin("LLM（open source）！！") == "LLM(open source)!!")
	#expect(halfWidthPunctuationInLatin("foo（bar（x））") == "foo(bar(x))", "套着的括号成对改")
	#expect(halfWidthPunctuationInLatin("共计134，28m3方") == "共计134,28m3方", "中文行里数字中间的照样改")
	// 中文语境里的不动：左右挨着汉字的、括号里有汉字的、括号前面是汉字的；中文句子里夹个英文词的，句末、括号后面挨着汉字的也不动。
	for s in ["2019年，开工", "日期 ：2019.10.9", "审定工程造价（元）", "（ps5独占）、双人成行", "说明（1）", "共 13，然后", "1.土壤类别：普通土壤",
		"请使用 API！", "推荐 Mac（Intel）版本", "推荐 Mac（Intel（x））版本"]
	{
		#expect(halfWidthPunctuationInLatin(s) == s, "「\(s)」不该改")
	}
}

@Test func 认重了的一截去掉() {
	let long = Fixtures.line("只在项目「lingxi-core」", x: 0.324, y: 0.456, w: 0.097, h: 0.017)
	let piece = Fixtures.line("只在项目", x: 0.323, y: 0.455, w: 0.041, h: 0.019)
	let other = Fixtures.line("只在项目", x: 0.1, y: 0.8, w: 0.04, h: 0.02)
	#expect(droppingContainedDuplicates([piece, long, other], width: 1000, height: 1000).map(\.text) == ["只在项目「lingxi-core」", "只在项目"], "别处同样的字不去")
}

@Test func 接在西文页后面的中文页也换得回中文() throws {
	// 「计100」：自动判断把「计」认成字母（it100），一个汉字都不剩。只看自动判断认出了多少汉字的话，接在西文页后面就永远换不回中文。
	let image = Fixtures.text(["计100"], size: 38, width: 700, height: 160)
	let alone = try chineseFirstPass(image, correction: true, memory: RunMemory())
	let memory = RunMemory()
	memory.startWithAuto = true
	let after = try chineseFirstPass(image, correction: true, memory: memory)
	let text = { (r: (lines: [OCRLine], options: LineOptions, pass: LanguagePass, check: [String: Any])) in Fixtures.compact(r.lines.map(\.text).joined()) }
	#expect(text(alone) == "计100")
	#expect(text(after) == "计100", "接在西文页后面：\(after.lines.map(\.text))，\(after.pass)")
	#expect(after.pass == .autoThenChinese && !memory.startWithAuto, "换回中文以后下一页先按中文认")
}

@Test func 斜着的页上分开的两行同样的值不去() {
	// 转 45° 的页：「100」在「合同合计100」下面另起一行，转正后两行分开；外接框很胖，按外接框比会叠在一起、把「100」当成认重了。
	let long = Fixtures.line("合同合计100", x: 0.2, y: 0.2, w: 0.6, h: 0.03, degrees: 45)
	let alone = Fixtures.line("100", x: 0.3, y: 0.25, w: 0.08, h: 0.03, degrees: 45)
	#expect(long.box.overlapArea(alone.box) / alone.box.area > 0.6, "外接框确实叠在一起")
	#expect(droppingContainedDuplicates([long, alone], width: 1000, height: 1000).count == 2)
}

@Test func 指定语言时中日韩排到最前() {
	#expect(cjkFirst(["en-US", "zh-Hans"]) == ["zh-Hans", "en-US"])
	#expect(cjkFirst(["ja-JP", "en-US"]) == ["ja-JP", "en-US"])
	#expect(cjkFirst(["en-US", "fr-FR"]) == ["en-US", "fr-FR"])
	#expect(cjkFirst(["en-US", "ko-KR", "zh-Hant"]) == ["ko-KR", "zh-Hant", "en-US"])
}

@Test func 汉字多少的判断() {
	#expect(ScriptCounts(oneLine("Establecer las directrices, responsabilidades y controles")).looksWestern)
	#expect(!ScriptCounts(oneLine("35kv 设备支架区：36*14*1.7=856.8m3")).looksWestern)
	#expect(!ScriptCounts(oneLine("short")).looksWestern, "字太少不下结论")
	#expect(ScriptCounts(oneLine("8.2k tokens 46秒 ui-coder 前端组员")).chineseEnough)
	#expect(!ScriptCounts(oneLine("日本語の文字認識テスト：ひらがな、カタカナ")).chineseEnough, "日文页不改回中文")
	#expect(!ScriptCounts(oneLine("Page 2 with one stray 字 mark in a long English line")).chineseEnough, "零星一个汉字不算")
	#expect(ScriptCounts(oneLine("日本語の文字認識テスト：ひらがな、カタカナ")).looksJapanese)
	#expect(!ScriptCounts(oneLine("8.2k tokens 46秒 ui-coder 前端组员")).looksJapanese)
}

@Test func 字块被认出的行盖住多少() {
	let block = NRect(x: 0, y: 0, w: 0.5, h: 0.1)
	let half = OCRLine(text: "x", confidence: 1, box: NRect(x: 0, y: 0, w: 0.25, h: 0.1), quad: [])
	#expect(abs(coverage(of: [block], by: [half]) - 0.5) < 1e-9)
	#expect(coverage(of: [], by: []) == 1, "没找到字块的页（空白页）不算认不全")
	// 韩文、日文：一个字没认出来。插画多的截图：盖住得少，但汉字认出了一大堆。
	#expect(chineseLooksUnreadable(coverage: 0, han: 0, textBlocks: 5))
	#expect(!chineseLooksUnreadable(coverage: 0.05, han: 52, textBlocks: 13))
	#expect(!chineseLooksUnreadable(coverage: 0.65, han: 0, textBlocks: 64), "盖住六成多就不算认不了")
}

@Test func 中文优先按中文认() throws {
	let p = try chineseFirstEngine.runPage(
		Fixtures.text(["35kv 设备支架区：36*14*1.7=856.8m3", "回填灰土：144.8-25.5=119.3m3"], size: 30, width: 1000), page: 1, options: OCROptions())
	#expect(p.steps["languages"] as? String == "chinese")
	let t = Fixtures.compact(p.text)
	#expect(t.contains("设备支架区") && t.contains("回填灰土"), "认成：\(p.text)")
}

@Test func 中文优先遇到西文页改回自动判断() throws {
	let image = Fixtures.text(["Fecha de creación: año pasado, versión tres", "Aprobación de órdenes de cambio"], size: 30, width: 1100)
	let p = try chineseFirstEngine.runPage(image, page: 1, options: OCROptions())
	#expect(p.steps["languages"] as? String == "chinese→auto:western")
	#expect(p.text.contains("ó") && p.text.contains("ñ"), "带变音的字母要在：\(p.text)")
}

@Test func 中文优先遇到韩文改回自动判断() throws {
	let p = try chineseFirstEngine.runPage(Fixtures.text(["한국어 문자 인식 테스트입니다"], size: 32), page: 1, options: OCROptions())
	#expect(p.steps["languages"] as? String == "chinese→auto:unreadable")
	#expect(p.text.contains("한국어"), "认成：\(p.text)")
}

@Test func 中文优先记住上一页是西文() throws {
	let url = Fixtures.pdf(
		pages: [
			["Establecer las directrices y los controles del proceso", "Aprobación de órdenes de cambio del contrato"],
			["The second page is written in English as well", "with another long line of plain words here"],
			["第三页是中文正文，汉字很多很多", "工程量签证单 35kv 设备支架区"],
		], size: 20)
	var passes: [String] = []
	var ocr = OCROptions()
	ocr.textLayer = false  // 现画的 PDF 有文字层，要量的是认图时的语言
	try chineseFirstEngine.run(try PageSource(path: url.path), pages: [1, 2, 3], options: ocr) { page in
		passes.append(page.steps["languages"] as? String ?? "")
		return true
	}
	#expect(passes == ["chinese→auto:western", "auto:western-before", "auto→chinese"])
}

@Test func 调用时换认法和指定语言() throws {
	var auto = OCROptions()
	auto.languagePreference = .auto
	#expect(try chineseFirstEngine.runPage(Fixtures.text(["这次照自动判断认"]), page: 1, options: auto).steps["languages"] == nil)
	var given = OCROptions()
	given.languages = ["en-US", "zh-Hans"]
	let p = try engine.runPage(Fixtures.text(["指定语言时中文排到最前"]), page: 1, options: given)
	#expect(p.notes.contains { $0.contains("排到了最前") })
	#expect(Fixtures.compact(p.text).contains("指定语言时中文排到最前"), "认成：\(p.text)")
}

@Test func 配置里的识别语言() throws {
	#expect(OCRConfig().languagePreference == .auto)
	#expect(OCRConfig(recognition: RecognitionConfig(languages: "chinese-first")).languagePreference == .chineseFirst)
	#expect(OCRConfig(recognition: RecognitionConfig(languages: "不认识的")).languagePreference == .auto)
	let path = Fixtures.tempURL("json").path
	try OCRConfig(recognition: RecognitionConfig(languages: "chinese-first")).save(path: path)
	#expect(OCREngine.fromDefaultConfig(environment: ["SHIZI_CONFIG": path]).languagePreference == .chineseFirst)
	#expect(parseLanguages(["auto"]) == (nil, .auto))
	#expect(parseLanguages(["chinese-first"]) == (nil, .chineseFirst))
	#expect(parseLanguages(["中文优先"]) == (nil, .chineseFirst))
	#expect(parseLanguages([]) == (nil, nil))
	#expect(parseLanguages(["en-US", "zh-Hans"]) == (["en-US", "zh-Hans"], nil))
	let r = try Tools.ocrRequest(["path": "/x.png", "languages": ["chinese-first"]], toFile: false)
	#expect(r.options.languagePreference == .chineseFirst && r.options.languages == nil)
}

@MainActor @Test func 设置里改识别语言不冲掉插件() throws {
	let path = Fixtures.tempURL("json").path
	try OCRConfig(plugins: [PluginConfig(name: "p", command: ["/x"], hooks: ["review"])]).save(path: path)
	let settings = PluginSettings(path: path, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())))
	#expect(settings.languagePreference == .auto)
	try settings.setLanguagePreference(.chineseFirst)
	var saved = OCRConfig.load(path: path).config
	#expect(saved.plugins?.map(\.name) == ["p"] && saved.languagePreference == .chineseFirst)
	// 改插件也不冲掉识别语言。
	try settings.setEnabled(false, for: "p")
	saved = OCRConfig.load(path: path).config
	#expect(saved.plugins?.first?.enabled == false && saved.languagePreference == .chineseFirst)
	// 改回自动判断：不留这一节。
	try settings.setLanguagePreference(.auto)
	#expect(OCRConfig.load(path: path).config.recognition == nil && settings.languagePreference == .auto)
	// 手改坏了的配置文件不写，原样留着。
	try "{坏了".write(toFile: path, atomically: true, encoding: .utf8)
	settings.reload()
	#expect(throws: SettingsError.self) { try settings.setLanguagePreference(.chineseFirst) }
	#expect(try String(contentsOfFile: path, encoding: .utf8) == "{坏了")
}

@Test func 识别详情说清按什么语言认() {
	let auto = OCROptions()
	#expect(RecognitionReport.languageText(steps: [:], options: auto) == "自动判断（设置 › 识别 里能改成中文优先）")
	#expect(RecognitionReport.languageText(steps: ["languages": "chinese"], options: auto) == "中文优先：按中文认")
	#expect(RecognitionReport.languageText(steps: ["languages": "chinese→auto:western"], options: auto) == "中文优先：这页几乎没有汉字，改用自动判断")
	#expect(RecognitionReport.languageText(steps: ["languages": "auto→chinese"], options: auto).contains("改回按中文认"))
	#expect(RecognitionReport.languageText(steps: ["languages": "auto:western-before"], options: auto) == "中文优先：上一页是西文，这页也按自动判断认")
	#expect(RecognitionReport.languageText(steps: ["languages": "chinese→auto:unreadable"], options: auto).contains("韩文、日文"))
	var given = OCROptions()
	given.languages = ["ja-JP"]
	#expect(RecognitionReport.languageText(steps: [:], options: given) == "指定：ja-JP")
}

@Test func 识别服务照改过的配置文件认() throws {
	// 拾字里改了识别语言，灵犀开着的识别服务下一次调用就照新的认，不用重启。
	let path = Fixtures.tempURL("json").path
	let watcher = ConfigWatcher(environment: ["SHIZI_CONFIG": path])
	#expect(watcher.engine().languagePreference == .auto, "配置文件不存在时是自动判断")
	try OCRConfig(recognition: RecognitionConfig(languages: "chinese-first")).save(path: path)
	#expect(watcher.engine().languagePreference == .chineseFirst)
	let same = watcher.engine()
	#expect(watcher.engine() === same, "文件没改就不重读")
	try FileManager.default.removeItem(atPath: path)
	#expect(watcher.engine().languagePreference == .auto)
}
