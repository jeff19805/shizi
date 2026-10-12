import Foundation
import OCRCore

/// MCP 服务：标准输入一行一条 JSON-RPC 消息，标准输出一行一条回复；日志只往标准错误写。
/// 一次只处理一条请求——系统识别内部本来就排队，并发不会更快（几路同时认，每张用的时间也不变）。
public final class MCPServer {
	/// 每次调用时拿识别引擎：照配置文件给的会看文件改没改过（见 ConfigWatcher），测试里给一个固定的。
	let engine: () -> OCREngine
	/// 一次回复最多多少字节，见 ModelReply。
	let maxReplyBytes: Int
	/// 往外写一行：回复和进度通知都走它。测试里换成收集起来。
	let send: (String) -> Void
	static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
	static let fallbackVersion = "2025-06-18"

	public init(engine: OCREngine, maxReplyBytes: Int = ModelReply.defaultMaxBytes, send: @escaping (String) -> Void = MCPServer.writeLine) {
		self.engine = { engine }
		self.maxReplyBytes = maxReplyBytes
		self.send = send
	}

	/// 照配置文件认：拾字里改了识别语言、判定插件，下一次调用就照新的认，灵犀、Claude Code 不用重启识别服务。
	public init(
		watching environment: [String: String], maxReplyBytes: Int = ModelReply.defaultMaxBytes,
		send: @escaping (String) -> Void = MCPServer.writeLine
	) {
		let watcher = ConfigWatcher(environment: environment)
		engine = { watcher.engine() }
		self.maxReplyBytes = maxReplyBytes
		self.send = send
	}

	public static func writeLine(_ s: String) {
		try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8))
	}

	public func run() {
		while let line = readLine(strippingNewline: true) {
			if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
			if let reply = handle(line) { send(jsonString(reply)) }
		}
	}

	/// 客户端在请求里带了 progressToken，就每认完一页报一次进度：Claude Code 会显示出来，
	/// 也不会因为长时间没动静把调用停掉（它对标准输入输出的服务默认 30 分钟没动静就停）。
	func progressReporter(_ params: [String: Any]) -> ((Int, Int) -> Void)? {
		guard let token = (params["_meta"] as? [String: Any])?["progressToken"], token is String || token is NSNumber else { return nil }
		return { [send] done, total in
			send(jsonString([
				"jsonrpc": "2.0", "method": "notifications/progress",
				"params": ["progressToken": token, "progress": done, "total": total, "message": "认完 \(done) / \(total) 页"],
			]))
		}
	}

	/// 处理一条消息；通知和客户端发来的回复不需要回，返回 nil。
	public func handle(_ text: String) -> [String: Any]? {
		guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else {
			return Self.error(id: NSNull(), code: -32700, message: "Parse error")
		}
		guard let msg = obj as? [String: Any] else {
			return Self.error(id: NSNull(), code: -32600, message: "Invalid Request")
		}
		guard let method = msg["method"] as? String else { return nil }
		guard let id = msg["id"], !(id is NSNull) else { return nil }
		let params = msg["params"] as? [String: Any] ?? [:]
		let result: [String: Any]
		switch method {
		case "initialize":
			result = initialize(params)
		case "ping":
			result = [:]
		case "tools/list":
			result = ["tools": Tools.definitions]
		case "tools/call":
			let name = params["name"] as? String ?? ""
			guard Tools.names.contains(name) else { return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)") }
			result = Tools.call(
				engine(), name: name, arguments: params["arguments"] as? [String: Any] ?? [:], maxReplyBytes: maxReplyBytes,
				progress: progressReporter(params))
		default:
			return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
		}
		return ["jsonrpc": "2.0", "id": id, "result": result]
	}

	func initialize(_ params: [String: Any]) -> [String: Any] {
		let requested = params["protocolVersion"] as? String
		let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.fallbackVersion
		return [
			"protocolVersion": version,
			"capabilities": ["tools": ["listChanged": false]],
			"serverInfo": ["name": "shizi", "title": "拾字：Mac 自带文字识别", "version": OCRVersion.current],
			"instructions": "用 macOS 自带的文字识别读图片或 PDF 里的字，全在本机。要认图里的字就调 ocr_image；页数多、要整份全文就调 ocr_to_file（写成文件，回复只给路径和摘要）；想知道这台机器能认哪些、插件通不通，调 ocr_status。",
		]
	}

	static func error(id: Any, code: Int, message: String) -> [String: Any] {
		["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
	}
}

/// 照配置文件给识别引擎，文件改过（修改时间变了，或者新建、删掉了）就重读。读一次文件的修改时间快得很。
/// 只在 MCP 服务那一条线程上用，不加锁。
final class ConfigWatcher {
	let environment: [String: String]
	let path: String
	private var stamp: Date?
	private var current: OCREngine

	init(environment: [String: String]) {
		self.environment = environment
		path = OCRConfig.defaultPath(environment)
		stamp = Self.modified(path)
		current = OCREngine.fromDefaultConfig(environment: environment)
	}

	func engine() -> OCREngine {
		let now = Self.modified(path)
		if now != stamp {
			stamp = now
			current = OCREngine.fromDefaultConfig(environment: environment)
		}
		return current
	}

	static func modified(_ path: String) -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
	}
}

