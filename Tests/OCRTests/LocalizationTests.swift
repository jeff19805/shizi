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

/// 多行字符串去缩进：开头 """ 后面那个换行不算，每行去掉跟结尾 """ 前面一样的缩进，结尾那行（只有缩进）不算。
func dedent(_ body: String) -> String {
	var lines = body.components(separatedBy: "\n")
	guard lines.count >= 2 else { return body }
	lines.removeFirst()
	let indent = lines.removeLast()
	return lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }.joined(separator: "\n")
}

/// 还原转义：\n、\t、\0、\"、\\、\u{…}；行末的 \（多行字符串里）接着下一行、不换行。
func unescape(_ body: String) -> String {
	let s = Array(body)
	var out = "", k = 0
	while k < s.count {
		guard s[k] == "\\", k + 1 < s.count else {
			out.append(s[k])
			k += 1
			continue
		}
		switch s[k + 1] {
		case "n": out.append("\n")
		case "t": out.append("\t")
		case "0": out.append("\0")
		case "\n": break
		case "u":
			if let open = s[k...].firstIndex(of: "{"), let end = s[open...].firstIndex(of: "}"),
				let value = UInt32(String(s[open + 1..<end]), radix: 16), let scalar = Unicode.Scalar(value)
			{
				out.unicodeScalars.append(scalar)
				k = end + 1
				continue
			}
		default: out.append(s[k + 1])
		}
		k += 2
	}
	return out
}

struct SourceLiteral {
	var line: Int
	var text: String
	/// 字面量前面的十几个字：认 `Text(verbatim: "…")` 这种原样显示的。
	var prefix: String
}

/// 源码里的字符串字面量：注释里的不算；插值 \(…) 换成 \u{0}；常见的转义还原成字。
/// 多行字符串（"""）照 Swift 的规矩去掉每行前面跟结尾 """ 一样的缩进，行末的 \ 接着下一行：工具说明、命令行帮助都是这样写的。
func stringLiterals(_ source: String) -> [SourceLiteral] {
	let s = Array(source)
	var out: [SourceLiteral] = []
	var i = 0, line = 1
	func starts(_ j: Int, _ text: String) -> Bool {
		let t = Array(text)
		return j + t.count <= s.count && Array(s[j..<j + t.count]) == t
	}
	/// 读一个字面量，i 指着开头的引号（或原始字符串的 #）；返回字、读完停在哪、读到第几行。
	/// 先原样收字（转义不还原，插值换成 \u{0}），多行的去完缩进再还原转义：行末的 \ 要在去缩进以后才接得对。
	func read(_ start: Int, _ startLine: Int) -> (String, Int, Int) {
		var j = start, line = startLine
		let raw = s[j] == "#"
		if raw { j += 1 }
		let multi = starts(j, "\"\"\"")
		let close = (multi ? "\"\"\"" : "\"") + (raw ? "#" : "")
		j += multi ? 3 : 1
		var body: [Character] = []
		while j < s.count {
			if starts(j, close) {
				j += close.count
				break
			}
			if s[j] == "\n" { line += 1 }
			if s[j] == "\\" && !raw && j + 1 < s.count {
				if s[j + 1] == "(" {
					j = skipInterpolation(j + 2)
					body.append("\u{0}")
					continue
				}
				body += [s[j], s[j + 1]]
				j += 2
				continue
			}
			body.append(s[j])
			j += 1
		}
		var text = String(body)
		if multi { text = dedent(text) }
		return (raw ? text : unescape(text), j, line)
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

/// 这几个文件夹里全部的字面量：文件名:行号 → 字。
private func literals(in folders: [String]) throws -> [(place: String, text: String, prefix: String)] {
	var out: [(String, String, String)] = []
	for folder in folders {
		let dir = repoRoot.appendingPathComponent(folder)
		let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "swift" && !skippedFiles.contains($0.lastPathComponent) }
		for file in files.sorted(by: { $0.path < $1.path }) {
			let source = try String(contentsOf: file, encoding: .utf8)
			out += stringLiterals(source).map { ("\(file.lastPathComponent):\($0.line)", $0.text, $0.prefix) }
		}
	}
	return out
}

/// App 界面的代码：里面带汉字的字面量都是界面上的字（不是的列在 untranslated）。
private func uiLiterals() throws -> [(place: String, text: String, prefix: String)] {
	try literals(in: ["Sources/ShiziKit", "Sources/Shizi"])
}

/// 识别核心、MCP 服务、判定插件：里面的中文很多不是给人看的（发给判定服务的题目、匹配用的字表、默认的分类类别），
/// 所以不查全部带汉字的字，只查写成 Texts.text("…") 的；漏包的靠 EnglishOutputTests 在英文下跑一遍查。
private func coreLiterals() throws -> [(place: String, text: String, prefix: String)] {
	try literals(in: ["Sources/OCRCore", "Sources/OCRServer", "Sources/ocr-plugin-systemone"])
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
		let e = Texts.text("""
			多行第一行
			第二行 \(n) 页，\
			接着写
			""")
		"""#
	let found = stringLiterals(source).filter { hasHan($0.text) }
	#expect(found.map(\.text) == ["共 \u{0} 张", "文件：\u{0}，第 \u{0} 页", "简体中文", "引号\"里\"的字\n换行", "多行第一行\n第二行 \u{0} 页，接着写"])
	#expect(found.map(\.line) == [2, 3, 4, 5, 6])
	#expect(found[4].prefix.hasSuffix("Texts.text("))
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

@Test func 识别核心和MCP服务里要翻的字都有英文() throws {
	let table = try #require(NSDictionary(contentsOf: englishTable) as? [String: String])
	let keys = Set(table.keys.map(normalizedKey))
	let wrapped = try coreLiterals().filter { $0.prefix.hasSuffix("Texts.text(") }
	#expect(!wrapped.isEmpty)
	let missing = wrapped.filter { !keys.contains($0.text) }.map { "\($0.place) \($0.text.replacingOccurrences(of: "\u{0}", with: "%…"))" }
	#expect(missing.isEmpty, "这些 Texts.text 的字没有英文：加进 scripts/app/en.lproj/Localizable.strings：\n\(missing.joined(separator: "\n"))")
}

@Test func 对照表里没有用不上的英文() throws {
	let table = try #require(NSDictionary(contentsOf: englishTable) as? [String: String])
	// 只有标点的（拼句子用的「、」「：」）也算用到：代码里写成 String(localized: "、") 的字面量都在这里面。
	let used = Set(try uiLiterals().map(\.text) + coreLiterals().map(\.text))
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
