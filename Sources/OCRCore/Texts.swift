import Foundation

/// 给人看的字（识别结果里的说明、MCP 的工具说明和回复、命令行的提示）用哪种语言：跟拾字的界面一样（规矩见 AGENTS.md）。
/// 中文就是代码里写的字；英文在 scripts/app/en.lproj/Localizable.strings（键是中文原文），跟 App 界面共用一张表。
///
/// 用哪种语言照系统的语言顺序，跟 App 挑界面语言的规则一样：简体、繁体中文用中文，别的都用英文。
/// App 里带的 shizi-mcp 把整个 App 当自己的包，所以也认拾字设置里的「界面语言」（写在 App 自己那份设置里）。
///
/// 为什么不直接用 String(localized:)：在仓库里编、单独跑的 shizi-mcp 旁边没有语言包，只能拿仓库里的 scripts/app 当包，
/// 可拿别的包取字时，中文那张空表查不到就会退到英文那张，中文界面也出英文。所以先自己定语言：英文就拿 en.lproj 这个文件夹当包
/// （表在包的最上层，取字时不再挑语言），中文就不查表。
public enum Texts {
	/// 英文时取字用的包；中文时是 nil。测试里可以换成 en.lproj 看英文的输出，记得换回来。
	public nonisolated(unsafe) static var english: Bundle? = findEnglish()

	public static func text(_ value: String.LocalizationValue) -> String {
		if let english { return String(localized: value, bundle: english) }
		// 没有这张表：照原文（中文）出，只把插值填进去。
		return String(localized: value, table: "Untranslated", bundle: .main)
	}

	static func findEnglish() -> Bundle? {
		guard Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"], forPreferences: nil).first == "en" else { return nil }
		return languagePacks().flatMap { Bundle(path: $0.appendingPathComponent("en.lproj").path) }
	}

	/// 语言包在哪：App 里在 Contents/Resources（App 里带的 shizi-mcp、判定插件，Bundle.main 都是这个 App）；
	/// 在仓库里编出来单独跑的，顺着程序的真实路径往上找仓库里的 scripts/app（.build/<平台>/release/ 往上三层就是仓库）。
	/// 仓库里的要排在程序旁边的前面：截图工具会把语言包复制到 .build 里自己旁边，对照表一改那份就旧了。
	/// 都找不到（编好的程序被拷到别处单独跑）就用中文。
	static func languagePacks() -> URL? {
		let table = "en.lproj/Localizable.strings"
		func has(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(table).path) }
		if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL, has(resources) { return resources }
		var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
		for _ in 0..<5 {
			guard let d = dir else { break }
			let packs = d.appendingPathComponent("scripts/app", isDirectory: true)
			if has(packs) { return packs }
			dir = d.deletingLastPathComponent()
		}
		if let resources = Bundle.main.resourceURL, has(resources) { return resources }
		return nil
	}
}
