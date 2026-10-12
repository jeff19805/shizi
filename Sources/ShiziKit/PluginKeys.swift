import Foundation

/// 判定插件的密钥放钥匙串：服务 shizi，账号是插件的名字（跟 ocr-plugin-systemone 读的一样）。
/// 改名前存在服务 mac-ocr-mcp 下面的照样认：读的时候先找 shizi、没有再找旧的，删的时候两边都删。
/// 读写都经系统自带的 /usr/bin/security：插件也是用它读，同一个程序存、同一个程序读，钥匙串不弹确认；
/// 要是 App 用系统接口自己存，换 security 去读就会弹确认。
/// 存的时候密钥写成十六进制、从标准输入交给 security（security -i），不出现在命令行参数里，别的程序用 ps 看不到。
enum PluginKeys {
	static let service = "shizi"
	/// 0.0.35 及以前存在这个服务下面。只读、只删，不往里写。
	static let oldService = "mac-ocr-mcp"

	/// 存不了的密钥：空的、有换行的、有非 ASCII 字的（security 读出来会变成十六进制，插件就拿错了）。
	static func problem(_ key: String) -> String? {
		if key.isEmpty { return String(localized: "密钥是空的") }
		if key.contains(where: \.isNewline) { return String(localized: "密钥里不能有换行") }
		if !key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }) { return String(localized: "密钥里只能有英文字母、数字和符号") }
		return nil
	}

	/// 有没有存过（只看有没有这一项，不读密钥本身）。默认新旧两个服务都看，插件也是两边都找。
	static func has(_ name: String, in services: [String] = [service, oldService]) -> Bool {
		services.contains { run(["find-generic-password", "-s", $0, "-a", name]).status == 0 }
	}

	static func save(_ key: String, for name: String) throws {
		if let problem = problem(key) { throw SettingsError(problem) }
		// 名字会拼进给 security 的那一行命令里，只放行字母、数字、- 和 _（插件名字本来就这样限制）。
		if let problem = PluginDraft.nameProblem(name) { throw SettingsError(problem) }
		let hex = key.utf8.map { String(format: "%02x", $0) }.joined()
		let r = run(["-i"], input: "add-generic-password -U -s \(service) -a \(name) -X \(hex)\n")
		// 只认新服务下的这一项：旧服务下还有一份时，新的没存进去也会被它蒙混过去，插件就拿旧密钥去连。
		guard r.status == 0, has(name, in: [service]) else { throw SettingsError(String(localized: "密钥没存进钥匙串")) }
	}

	/// 读出来（只在插件改名、要把密钥挪到新名字下时用）。
	static func read(_ name: String) -> String? {
		for s in [service, oldService] {
			let r = run(["find-generic-password", "-s", s, "-a", name, "-w"])
			let key = r.output.trimmingCharacters(in: .newlines)
			if r.status == 0 && !key.isEmpty { return key }
		}
		return nil
	}

	/// 新旧两个服务下的都删：只删新的，读的时候又会找到旧服务下那一份。
	static func remove(_ name: String) {
		for s in [service, oldService] { _ = run(["delete-generic-password", "-s", s, "-a", name]) }
	}

	static func run(_ args: [String], input: String? = nil) -> (status: Int32, output: String) {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		p.arguments = args
		let stdin = Pipe(), stdout = Pipe()
		p.standardInput = stdin
		p.standardOutput = stdout
		p.standardError = Pipe()
		guard (try? p.run()) != nil else { return (-1, "") }
		if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
		try? stdin.fileHandleForWriting.close()
		let out = stdout.fileHandleForReading.readDataToEndOfFile()
		p.waitUntilExit()
		return (p.terminationStatus, String(decoding: out, as: UTF8.self))
	}
}

struct SettingsError: Error, CustomStringConvertible {
	var description: String
	init(_ message: String) { description = message }
}
