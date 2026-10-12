import Foundation

/// 灵犀的 MCP 配置：~/.lingxi/agent/config.toml 里的 `[mcpServers.<名字>]`。
/// 只改那一节的 command 一行（灵犀里还没接入时在末尾加一节），别的原样不动；写之前另存一份备份。
enum LingxiConfig {
	static var path: String { (NSHomeDirectory() as NSString).appendingPathComponent(".lingxi/agent/config.toml") }
	static let defaultName = "ocr"

	struct Entry: Equatable {
		var name: String
		var command: String?
	}

	/// 找拾字的那一节：先找名字叫 ocr 的，没有就找 command 指向 shizi-mcp（改名前叫 mac-ocr-mcp）的。
	static func find(in text: String) -> Entry? {
		let entries = sections(text).map { Entry(name: $0.name, command: $0.command) }
		return entries.first { $0.name == defaultName } ?? entries.first { c in ["/shizi-mcp", "/mac-ocr-mcp"].contains { c.command?.hasSuffix($0) == true } }
	}

	/// 把那一节的 command 换掉；那一节里没有 command 就在节标题下面加一行。
	static func setCommand(_ command: String, section name: String, in text: String) -> String {
		var lines = text.components(separatedBy: "\n")
		guard let s = sections(text).first(where: { $0.name == name }) else { return text }
		let line = "command = \(quoted(command))"
		if let i = s.commandLine { lines[i] = line } else { lines.insert(line, at: s.header + 1) }
		return lines.joined(separator: "\n")
	}

	/// 在末尾加一节。
	static func appendSection(name: String = defaultName, command: String, to text: String) -> String {
		var out = text
		if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
		if !out.isEmpty { out += "\n" }
		out += """
			[mcpServers.\(name)]
			command = \(quoted(command))
			description = "本机文字识别（拾字）：读图片、截图、扫描件和 PDF 里的字，表格、竖排、任意角度都行，不联网"
			timeoutMs = 300000

			"""
		return out
	}

	/// 写回去：先把原来的另存成「config.toml.拾字备份」。
	static func write(_ text: String, path: String = path) throws {
		let url = URL(fileURLWithPath: path)
		let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".拾字备份")
		if FileManager.default.fileExists(atPath: path) {
			try? FileManager.default.removeItem(at: backup)
			try FileManager.default.copyItem(at: url, to: backup)
		}
		try Data(text.utf8).write(to: url, options: .atomic)
	}

	// MARK: 读 TOML（只认这几样：节标题、command = "..."）

	struct Section {
		var name: String
		/// 节标题在第几行。
		var header: Int
		var commandLine: Int?
		var command: String?
	}

	static func sections(_ text: String) -> [Section] {
		var result: [Section] = []
		for (i, raw) in text.components(separatedBy: "\n").enumerated() {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("[") {
				if let m = line.firstMatch(of: #/^\[mcpServers\.([A-Za-z0-9_-]+)\]\s*(#.*)?$/#) {
					result.append(Section(name: String(m.1), header: i))
				} else {
					// 别的节：后面的行不算这个 MCP 服务的。
					result.append(Section(name: "", header: i))
				}
				continue
			}
			guard !result.isEmpty, !result[result.count - 1].name.isEmpty, result[result.count - 1].commandLine == nil else { continue }
			if let m = line.firstMatch(of: #/^command\s*=\s*(.+)$/#) {
				result[result.count - 1].commandLine = i
				result[result.count - 1].command = unquote(String(m.1))
			}
		}
		return result.filter { !$0.name.isEmpty }
	}

	/// TOML 的双引号字符串：反斜杠和双引号要转义。
	static func quoted(_ s: String) -> String {
		"\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
	}

	/// 读一个 TOML 字符串值（双引号或单引号），后面的注释不要。
	static func unquote(_ value: String) -> String? {
		let v = value.trimmingCharacters(in: .whitespaces)
		if v.hasPrefix("'") {
			let rest = v.dropFirst()
			return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
		}
		guard v.hasPrefix("\"") else { return nil }
		var out = ""
		var escaped = false
		for ch in v.dropFirst() {
			if escaped {
				out.append(ch)
				escaped = false
			} else if ch == "\\" {
				escaped = true
			} else if ch == "\"" {
				return out
			} else {
				out.append(ch)
			}
		}
		return nil
	}
}
