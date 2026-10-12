import Foundation
import Testing
@testable import ShiziKit

// 拾字界面的英文（规矩见 AGENTS.md）：对照表 scripts/app/en.lproj/Localizable.strings，键是代码里的中文原文，
// App 运行时按语言用 Bundle.main 取。这里查三件事：表本身对不对、界面代码里的中文是不是都有英文、表里有没有用不上的。

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let englishTable = repoRoot.appendingPathComponent("scripts/app/en.lproj/Localizable.strings")

/// 整个文件不查：开发用的自检报告；写进灵犀配置文件的字。
private let skippedFiles: Set<String> = ["PhotoCheck.swift", "LingxiConfig.swift"]

/// 界面代码里故意不翻的中文（存设置用的键、线程名这类以「拾字.」开头的直接跳过，不用列）。
private let untranslated: Set<String> = [
	// 判定插件 describe 回的值（收不收图），代码拿它比对，不是界面上的字。
	"收",
	// 识别详情预览（给截图用）里的样例行，是认出来的字，不是界面上的字。
	"一行",
]

/// 有没有汉字：只认汉字本身的码段。\p{Han} 会把「·」这类几种文字共用的标点也算进去。
func hasHan(_ s: String) -> Bool {
	s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
}

/// 占位符的种类（%@、%lld……）：去掉编号（%2$@ 算 %@）再排序，英文可以调换顺序，但种类和个数得一样。%% 是百分号本身，不算。
func formatSpecifiers(_ s: String) -> [String] {
	let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|llu|lu|d|u|@|lf|f|%)")
	return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
		let kind = String(s[Range(m.range(at: 1), in: s)!])
		return kind == "%" ? nil : kind
	}.sorted()
}

/// 键里的占位符换成跟源码插值一样的记号（\u{0}），%% 还原成 %，好跟源码里的字面量比。
func normalizedKey(_ key: String) -> String {
	let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|llu|lu|d|u|@|lf|f)")
	let marked = regex.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "\u{0}")
	return marked.replacingOccurrences(of: "%%", with: "%")
}

struct SourceLiteral {
	var line: Int
	var text: String
	/// 字面量前面的十几个字：认 `Text(verbatim: "…")` 这种原样显示的。
	var prefix: String
}

/// 源码里的字符串字面量：注释里的不算；插值 \(…) 换成 \u{0}；常见的转义还原成字。
/// 多行字符串（"""）原样拿、不去缩进：界面代码里现在没有带中文的多行字符串。
func stringLiterals(_ source: String) -> [SourceLiteral] {
	let s = Array(source)
	var out: [SourceLiteral] = []
	var i = 0, line = 1
	func starts(_ j: Int, _ text: String) -> Bool {
		let t = Array(text)
		return j + t.count <= s.count && Array(s[j..<j + t.count]) == t
	}
	/// 读一个字面量，i 指着开头的引号（或原始字符串的 #）；返回字、读完停在哪、读到第几行。
	func read(_ start: Int, _ startLine: Int) -> (String, Int, Int) {
		var j = start, line = startLine
		let raw = s[j] == "#"
		if raw { j += 1 }
		let quote = starts(j, "\"\"\"") ? "\"\"\"" : "\""
		let close = quote + (raw ? "#" : "")
		j += quote.count
		var text = ""
		while j < s.count {
			if starts(j, close) { return (text, j + close.count, line) }
			let c = s[j]
			if c == "\n" { line += 1 }
			if c == "\\" && !raw && j + 1 < s.count {
				let n = s[j + 1]
				switch n {
				case "(":
					j = skipInterpolation(j + 2)
					text.append("\u{0}")
					continue
				case "n": text.append("\n")
				case "t": text.append("\t")
				case "0": text.append("\0")
				case "\"", "\\", "'": text.append(n)
				case "u":
					if let open = s[j...].firstIndex(of: "{"), let end = s[open...].firstIndex(of: "}"),
						let value = UInt32(String(s[open + 1..<end]), radix: 16), let scalar = Unicode.Scalar(value)
					{
						text.unicodeScalars.append(scalar)
						j = end + 1
						continue
					}
				default: text.append(n)
				}
				j += 2
				continue
			}
			text.append(c)
			j += 1
		}
		return (text, j, line)
	}
	/// 跳过插值：数括号，里面的字符串整个跳过（插值里也会有带引号的字）。
	func skipInterpolation(_ start: Int) -> Int {
		var j = start, depth = 1
		while j < s.count && depth > 0 {
			if s[j] == "\"" {
				j = read(j, 0).1
				continue
			}
			if s[j] == "(" { depth += 1 }
			if s[j] == ")" { depth -= 1 }
			j += 1
		}
		return j
	}
	while i < s.count {
		if s[i] == "\n" {
			line += 1
			i += 1
		} else if starts(i, "//") {
			while i < s.count && s[i] != "\n" { i += 1 }
		} else if starts(i, "/*") {
			i += 2
			while i < s.count && !starts(i, "*/") {
				if s[i] == "\n" { line += 1 }
				i += 1
			}
			i += 2
		} else if s[i] == "\"" || starts(i, "#\"") {
			let prefix = String(s[max(0, i - 12)..<i])
			let (text, end, endLine) = read(i, line)
			out.append(SourceLiteral(line: line, text: text, prefix: prefix))
			i = end
			line = endLine
		} else {
			i += 1
		}
	}
	return out
}

/// 界面代码里的全部字面量：文件名:行号 → 字。
private func uiLiterals() throws -> [(place: String, text: String, prefix: String)] {
	let dir = repoRoot.appendingPathComponent("Sources/ShiziKit")
	let files =
		try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
		.filter { $0.pathExtension == "swift" && !skippedFiles.contains($0.lastPathComponent) }
		+ [repoRoot.appendingPathComponent("Sources/Shizi/ShiziApp.swift")]
	var out: [(String, String, String)] = []
	for file in files.sorted(by: { $0.path < $1.path }) {
		let source = try String(contentsOf: file, encoding: .utf8)
		out += stringLiterals(source).map { ("\(file.lastPathComponent):\($0.line)", $0.text, $0.prefix) }
	}
	return out
}

/// 带汉字、要翻的：原样显示的（verbatim）、存设置的键（「拾字.」开头）、不翻名单里的不算。
private func chineseUILiterals() throws -> [(place: String, text: String)] {
	try uiLiterals().filter { literal in
		hasHan(literal.text) && !literal.prefix.hasSuffix("verbatim: ")
			&& !literal.text.hasPrefix("拾字.") && !untranslated.contains(literal.text)
	}.map { ($0.place, $0.text) }
}

@Test func 认得出源码里的字符串() {
	let source = #"""
		// 注释里的"中文"不算
		let a = Text("共 \(photos.count) 张")  /* 这里的"也不算" */
		let b = String(localized: "文件：\(name.isEmpty ? "无名" : name)，第 \(n) 页")
		let c = Text(verbatim: "简体中文")
		let d = "引号\"里\"的字\n换行"
		"""#
	let found = stringLiterals(source).filter { hasHan($0.text) }
	#expect(found.map(\.text) == ["共 \u{0} 张", "文件：\u{0}，第 \u{0} 页", "简体中文", "引号\"里\"的字\n换行"])
	#expect(found.map(\.line) == [2, 3, 4, 5])
	#expect(found[2].prefix.hasSuffix("verbatim: "))
	#expect(normalizedKey("文件：%@，第 %lld 页") == "文件：\u{0}，第 \u{0} 页" && normalizedKey("100%% %lld") == "100% \u{0}")
	#expect(formatSpecifiers("%2$@ of %1$lld (100%%)") == ["@", "lld"])
}

@Test func 英文对照表的值都是英文且占位符对得上() throws {
	let text = try String(contentsOf: englishTable, encoding: .utf8)
	let table = try #require(NSDictionary(contentsOf: englishTable) as? [String: String], "对照表读不出来，格式不对")
	// 同一个键写了两次，后一条会悄悄盖掉前一条。
	let entries = text.components(separatedBy: "\n").filter { $0.hasPrefix("\"") }.count
	#expect(entries == table.count, "有重复的键：\(entries) 条，去重后 \(table.count) 条")
	for (key, value) in table {
		#expect(!value.isEmpty, "英文是空的：\(key)")
		#expect(!hasHan(value), "英文里还有汉字：\(key) = \(value)")
		#expect(formatSpecifiers(key) == formatSpecifiers(value), "占位符对不上：\(key) = \(value)")
	}
}

@Test func 界面上的中文都有英文() throws {
	let table = try #require(NSDictionary(contentsOf: englishTable) as? [String: String])
	let keys = Set(table.keys.map(normalizedKey))
	let missing = try chineseUILiterals().filter { !keys.contains($0.text) }
		.map { "\($0.place) \($0.text.replacingOccurrences(of: "\u{0}", with: "%…"))" }
	#expect(
		missing.isEmpty,
		"这些界面上的中文没有英文：加进 scripts/app/en.lproj/Localizable.strings（不是给人看的，加进本文件的 untranslated）：\n\(missing.joined(separator: "\n"))"
	)
}

@Test func 对照表里没有用不上的英文() throws {
	let table = try #require(NSDictionary(contentsOf: englishTable) as? [String: String])
	// 只有标点的（拼句子用的「、」「：」）也算用到：代码里写成 String(localized: "、") 的字面量都在这里面。
	let used = Set(try uiLiterals().map(\.text))
	let unused = table.keys.filter { !used.contains(normalizedKey($0)) }.sorted()
	#expect(unused.isEmpty, "界面代码里已经没有这些字了，对照表里删掉：\n\(unused.joined(separator: "\n"))")
}

@Test func 界面语言的设置() throws {
	let name = "拾字测试-\(UUID().uuidString)"
	let defaults = try #require(UserDefaults(suiteName: name))
	defer { defaults.removePersistentDomain(forName: name) }
	#expect(InterfaceLanguage.current(defaults, domain: name) == .system, "没指定过就是跟随系统")
	InterfaceLanguage.set(.english, defaults)
	#expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["en"])
	#expect(InterfaceLanguage.current(defaults, domain: name) == .english)
	InterfaceLanguage.set(.chinese, defaults)
	#expect(InterfaceLanguage.current(defaults, domain: name) == .chinese)
	InterfaceLanguage.set(.system, defaults)
	#expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil && InterfaceLanguage.current(defaults, domain: name) == .system)
	// 系统设置里给拾字指定了一种界面里没有的语言：当成跟随系统。
	defaults.set(["fr"], forKey: "AppleLanguages")
	#expect(InterfaceLanguage.current(defaults, domain: name) == .system)
}
