import AppKit
import Foundation

/// 拾字界面上的字用哪种语言。默认跟着系统：系统语言里排在前面的是简体或繁体中文就用中文，别的都用英文
/// （繁体中文系统也显示简体中文，见 scripts/app/zh-Hant.lproj）。界面上的中文写在代码里，英文在 scripts/app/en.lproj/Localizable.strings。
/// 只给拾字指定一种时，写进拾字自己的 AppleLanguages：系统设置里给单个 App 指定语言，写的也是它，两边看到的一样。
/// 界面上的字是启动时按语言取好的，所以改了要重开拾字才生效。
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
	case system, chinese, english

	public var id: String { rawValue }

	static let key = "AppleLanguages"

	/// 写进 AppleLanguages 的值；跟着系统时不写。
	var languages: [String]? {
		switch self {
		case .system: return nil
		case .chinese: return ["zh-Hans"]
		case .english: return ["en"]
		}
	}

	/// 现在给拾字指定的是哪种：只看拾字自己那一份设置（全局的那份是系统的语言顺序，不算指定）。
	static func current(_ defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) -> InterfaceLanguage {
		guard let domain, let first = (defaults.persistentDomain(forName: domain)?[key] as? [String])?.first else { return .system }
		if first.hasPrefix("zh") { return .chinese }
		if first.hasPrefix("en") { return .english }
		return .system
	}

	static func set(_ choice: InterfaceLanguage, _ defaults: UserDefaults = .standard) {
		if let languages = choice.languages {
			defaults.set(languages, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	/// 装成 App 跑的才能重开；开发时 swift run 起的不是 App，重开不了。
	static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

	/// 等这个进程退出了再打开拾字：两个一起开着会抢同一份设置和照片库。
	@MainActor static func relaunch() {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/sh")
		p.arguments = [
			"-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
			String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
		]
		guard (try? p.run()) != nil else { return }
		NSApp.terminate(nil)
	}
}
