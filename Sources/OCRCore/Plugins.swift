import Foundation

/// 插件约定（第 2 版）：插件是一个独立的小程序。核心每次调用时启动它，往标准输入写一行 JSON
/// `{"protocol":2,"hook":"<口子>","input":{...}}`，它往标准输出回一行 `{"output":{...}}` 或 `{"error":"原因"}`。
/// 环境变量只给白名单里的几个（见 `PluginHost.environment`），加上 `OCR_PLUGIN_NAME`（配置里的 name）、`OCR_PLUGIN_LANGUAGE`
/// （核心给人看的字用的语言，en 或 zh-Hans）和配置里的 env。
///
/// 插件只给概率，所有门槛和「怎么认」都由核心定，这样不装插件也能测、插件也能随时换。三个口子：
/// - `describe`：测连接、说明自己。输入 `{"hooks":[配置里接的口子]}`；回什么随意，`ocr_status` 原样显示，
///   其中 `warnings`（字符串数组）单独一行一行列出来。
/// - `route`（认之前）：输入 `{"image":{"data","width","height"}}`，data 是 base64 的 PNG（长边不超过 1600），
///   width、height 是原图的尺寸；回 `{"signals":{"vertical","table","columns","photo","curved","tiny"}}`，每项是 0–1 的概率，可以只给一部分。
///   第 1 版给的是临时文件的路径（path），第 2 版改成直接给数据：图不落到硬盘上。
/// - `review`（认完）：输入 `{"lines":[{"id","text","confidence"}],"candidates":[id]}`，回 `{"suspects":{"<id>":概率}}`，
///   概率是「这行认错了」的可能性；只需要回 candidates 里的。
public struct PluginConfig: Codable, Sendable {
	public var name: String
	/// 程序和参数，第一项是程序路径（可以用 ~）。
	public var command: [String]
	/// 接哪些口子：route、review。
	public var hooks: [String]
	/// 每次调用最多等多久，超时就当没装插件、按代码规则走。默认 route 1500、review 3000。
	public var timeoutMs: Int?
	/// 额外传给插件的环境变量（核心自己的环境变量也会原样传下去）。
	public var env: [String: String]?
	/// 设成 false 可以先停用、不用删配置。
	public var enabled: Bool?

	public init(name: String, command: [String], hooks: [String], timeoutMs: Int? = nil, env: [String: String]? = nil, enabled: Bool? = nil) {
		self.name = name
		self.command = command
		self.hooks = hooks
		self.timeoutMs = timeoutMs
		self.env = env
		self.enabled = enabled
	}
}

public struct OCRConfig: Codable, Sendable {
	public var plugins: [PluginConfig]?
	/// 识别的默认做法。拾字的设置页写，MCP 服务（灵犀、Claude Code 调的）照着认。
	public var recognition: RecognitionConfig?

	public init(plugins: [PluginConfig]? = nil, recognition: RecognitionConfig? = nil) {
		self.plugins = plugins
		self.recognition = recognition
	}

	/// 配置文件位置：环境变量 SHIZI_CONFIG（改名前叫 MAC_OCR_MCP_CONFIG，也认），没有就是 ~/.config/shizi/config.json。
	/// 文件不存在 = 没有插件。
	public static func defaultPath(_ env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
		if let custom = env["SHIZI_CONFIG"] ?? env["MAC_OCR_MCP_CONFIG"] { return expandPath(custom) }
		return (home as NSString).appendingPathComponent(".config/shizi/config.json")
	}

	/// 改名前（0.0.35 及以前叫 mac-ocr-mcp）配置文件的位置。
	static func oldDefaultPath(home: String) -> String {
		(home as NSString).appendingPathComponent(".config/mac-ocr-mcp/config.json")
	}

	/// 新位置还没有配置文件、改名前的位置有，就复制过来。拾字和 shizi-mcp 启动时各调一次；用环境变量指定了配置文件的不动。
	/// 只复制不搬走：升级前起的服务进程（灵犀开着的那种，一开好几天）还在读旧文件，搬走了它就当没有插件、没有识别语言设置。
	public static func copyOldConfigIfNeeded(_ env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
		guard env["SHIZI_CONFIG"] == nil, env["MAC_OCR_MCP_CONFIG"] == nil else { return }
		let fm = FileManager.default
		let new = defaultPath(env, home: home), old = oldDefaultPath(home: home)
		guard !fm.fileExists(atPath: new), fm.fileExists(atPath: old) else { return }
		// 先复制成同一个文件夹里的临时文件，再「新位置没有才改名」：拾字和服务同时启动时，谁也读不到复制了一半的文件，
		// 也不会把对方刚复制好、可能已经改过的那份盖掉。
		let dir = (new as NSString).deletingLastPathComponent
		let tmp = (dir as NSString).appendingPathComponent(".config.json.\(UUID().uuidString).tmp")
		guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil,
			(try? fm.copyItem(atPath: old, toPath: tmp)) != nil
		else { return }
		if renamex_np(tmp, new, UInt32(RENAME_EXCL)) != 0 { try? fm.removeItem(atPath: tmp) }
	}

	/// 写回配置文件（拾字的设置页用）。里面没有密钥：密钥在钥匙串里。
	public func save(path: String) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let url = URL(fileURLWithPath: path)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try encoder.encode(self).write(to: url, options: .atomic)
	}

	/// 没指定语言时怎么认：配置里没写或写的不认识，就是自动判断。
	public var languagePreference: LanguagePreference {
		recognition?.languages.flatMap(LanguagePreference.init(rawValue:)) ?? .auto
	}

	public static func load(path: String) -> (config: OCRConfig, problem: String?) {
		guard FileManager.default.fileExists(atPath: path) else { return (OCRConfig(), nil) }
		do {
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			return (try JSONDecoder().decode(OCRConfig.self, from: data), nil)
		} catch {
			let why = "\(error)"
			return (OCRConfig(), Texts.text("配置文件 \(path) 读不了，先按没有插件处理：\(why)"))
		}
	}
}

/// 配置文件里「识别」那一节。
public struct RecognitionConfig: Codable, Sendable, Equatable {
	/// 没指定语言时怎么认："auto"（默认，系统自己判断）或 "chinese-first"（中文优先）。
	public var languages: String?

	public init(languages: String? = nil) {
		self.languages = languages
	}
}

public struct PluginFailure: Error, CustomStringConvertible {
	public init(plugin: String, message: String) {
		self.plugin = plugin
		self.message = message
	}

	public var plugin: String
	public var message: String
	public var description: String { Texts.text("插件 \(plugin)：\(message)") }
}

/// 一次正在进行的插件调用；`wait()` 等它结束（最多等到超时）。
public final class PendingCall {
	let done = DispatchSemaphore(value: 0)
	var result: Result<[String: Any], PluginFailure>?

	public func wait() -> Result<[String: Any], PluginFailure> {
		done.wait()
		done.signal()
		return result!
	}
}

public final class PluginHost: Sendable {
	public let plugins: [PluginConfig]
	let environment: [String: String]

	public init(config: OCRConfig, environment: [String: String] = ProcessInfo.processInfo.environment) {
		plugins = (config.plugins ?? []).filter { $0.enabled != false && !$0.command.isEmpty }
		self.environment = environment
	}

	public func plugins(for hook: String) -> [PluginConfig] { plugins.filter { $0.hooks.contains(hook) } }

	/// 分类给 30 秒：判定服务分一张本来就要等一会儿，忙的时候还会排队、等得更久；一批照片是几张一起问的，等一会儿不卡界面。
	static func defaultTimeout(_ hook: String) -> Int {
		switch hook {
		case "review": return 3000
		case "classify": return 30000
		default: return 1500
		}
	}

	/// 插件进程只拿这几个环境变量（跟灵犀启动 MCP 服务的白名单一样），加上 OCR_PLUGIN_NAME 和配置里的 env：
	/// 不把整个环境传下去，里面可能有别的服务的密钥。
	static let passThrough: Set<String> = ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER", "LANG", "TMPDIR"]

	static func environment(for plugin: PluginConfig, parent: [String: String]) -> [String: String] {
		var env = parent.filter { passThrough.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("XDG_") }
		env["OCR_PLUGIN_NAME"] = plugin.name
		// 插件报的话（出错、测连接的结果）跟核心用同一种语言：插件自己照系统定的话，会跟拾字设的界面语言、跟测试里的核心对不上。
		env["OCR_PLUGIN_LANGUAGE"] = Texts.english == nil ? "zh-Hans" : "en"
		for (k, v) in plugin.env ?? [:] { env[k] = v }
		return env
	}

	/// 在后台启动一次调用，马上返回；结果用 `wait()` 取。
	public func start(_ plugin: PluginConfig, hook: String, input: [String: Any], timeoutMs: Int? = nil) -> PendingCall {
		let pending = PendingCall()
		let timeout = timeoutMs ?? plugin.timeoutMs ?? Self.defaultTimeout(hook)
		let env = Self.environment(for: plugin, parent: environment)
		DispatchQueue.global(qos: .userInitiated).async {
			pending.result = Self.run(plugin, hook: hook, input: input, timeoutMs: timeout, env: env)
			pending.done.signal()
		}
		return pending
	}

	public func call(_ plugin: PluginConfig, hook: String, input: [String: Any], timeoutMs: Int? = nil) -> Result<[String: Any], PluginFailure> {
		start(plugin, hook: hook, input: input, timeoutMs: timeoutMs).wait()
	}

	static func run(_ plugin: PluginConfig, hook: String, input: [String: Any], timeoutMs: Int, env: [String: String])
		-> Result<[String: Any], PluginFailure>
	{
		func fail(_ m: String) -> Result<[String: Any], PluginFailure> { .failure(PluginFailure(plugin: plugin.name, message: m)) }
		let payload: [String: Any] = ["protocol": 2, "hook": hook, "input": input]
		guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
			return fail(Texts.text("输入没法写成 JSON"))
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: expandPath(plugin.command[0]))
		process.arguments = Array(plugin.command.dropFirst())
		process.environment = env
		let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
		process.standardInput = stdin
		process.standardOutput = stdout
		process.standardError = stderr
		let exited = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in exited.signal() }
		do {
			try process.run()
		} catch {
			return fail(Texts.text("启动不了（\(plugin.command[0])）：\(error.localizedDescription)"))
		}
		// 输出要边跑边读，插件写满管道缓冲区时才不会互相等死。
		var outData = Data(), errData = Data()
		let readers = DispatchGroup()
		readers.enter()
		DispatchQueue.global().async {
			outData = stdout.fileHandleForReading.readDataToEndOfFile()
			readers.leave()
		}
		readers.enter()
		DispatchQueue.global().async {
			errData = stderr.fileHandleForReading.readDataToEndOfFile()
			readers.leave()
		}
		// 插件不读输入就退出时，往管道写会收到 SIGPIPE 把整个服务带走：这个管道上关掉它，
		// 再用会抛 Swift 错误的新写法（老的 write(_:) 出错直接抛 ObjC 异常崩掉）。
		_ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		var line = body
		line.append(0x0A)
		try? stdin.fileHandleForWriting.write(contentsOf: line)
		try? stdin.fileHandleForWriting.close()
		if exited.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
			process.terminate()
			if exited.wait(timeout: .now() + .milliseconds(300)) == .timedOut { kill(process.processIdentifier, SIGKILL) }
			_ = readers.wait(timeout: .now() + .seconds(1))
			return fail(Texts.text("超过 \(timeoutMs) 毫秒没回，已停掉"))
		}
		_ = readers.wait(timeout: .now() + .seconds(2))
		guard let obj = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any] else {
			let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			let code = "\(process.terminationStatus)", detail = String(err.prefix(200))
			return fail(err.isEmpty ? Texts.text("回的不是 JSON（退出码 \(code)）") : Texts.text("回的不是 JSON（退出码 \(code)）：\(detail)"))
		}
		if let message = obj["error"] as? String { return fail(message) }
		guard let output = obj["output"] as? [String: Any] else { return fail(Texts.text("回的 JSON 里没有 output")) }
		return .success(output)
	}
}
