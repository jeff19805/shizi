import Foundation
import Network
import Testing
@testable import OCRCore

/// 测试用的假 System One 服务：只在 127.0.0.1 上听，按 `respond` 回话，记下收到的请求。
final class FakeSystemOne {
	struct Request {
		var method: String
		var path: String
		var headers: [String: String]
		var body: [String: Any]
	}

	let listener: NWListener
	let queue = DispatchQueue(label: "fake-systemone")
	var received: [Request] = []
	let respond: (Request) -> (Int, Any)

	init(_ respond: @escaping (Request) -> (Int, Any)) throws {
		self.respond = respond
		let params = NWParameters.tcp
		params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: params)
		let ready = DispatchSemaphore(value: 0)
		listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
		listener.newConnectionHandler = { [unowned self] in self.serve($0) }
		listener.start(queue: queue)
		_ = ready.wait(timeout: .now() + 5)
	}

	deinit { listener.cancel() }

	var url: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }
	var requests: [Request] { queue.sync { received } }

	func serve(_ connection: NWConnection) {
		connection.start(queue: queue)
		var buffer = Data()
		func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
				if let data { buffer.append(data) }
				if let request = Self.parse(buffer) {
					self.received.append(request)
					let (status, obj) = self.respond(request)
					let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
					let head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
					connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
				} else if done || error != nil {
					connection.cancel()
				} else {
					receive()
				}
			}
		}
		receive()
	}

	/// 头收齐、正文也收够 Content-Length 那么长，才算一个完整的请求。
	static func parse(_ data: Data) -> Request? {
		guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
		let first = head[0].split(separator: " ")
		guard first.count >= 2 else { return nil }
		var headers: [String: String] = [:]
		for line in head.dropFirst() {
			if let colon = line.firstIndex(of: ":") {
				headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			}
		}
		let length = Int(headers["content-length"] ?? "0") ?? 0
		let rest = data[split.upperBound...]
		guard rest.count >= length else { return nil }
		let body = (try? JSONSerialization.jsonObject(with: Data(rest.prefix(length)))) as? [String: Any] ?? [:]
		return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
	}
}

/// 编出来的插件程序（swift build 会连插件一起编）。
let systemOnePlugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
	.appendingPathComponent(".build/debug/ocr-plugin-systemone").path

func systemOne(_ server: FakeSystemOne, name: String = "测试服务", hooks: [String] = ["route", "review"], key: String? = "k-123", url: String? = nil)
	-> (PluginHost, PluginConfig)
{
	var env = ["SYSTEMONE_URL": url ?? server.url, "SYSTEMONE_MODEL": "m1"]
	if let key { env["SYSTEMONE_KEY"] = key }
	let p = PluginConfig(name: name, command: [systemOnePlugin], hooks: hooks, timeoutMs: 15_000, env: env, enabled: nil)
	return (PluginHost(config: OCRConfig(plugins: [p])), p)
}

/// 明摆着的那道题答对、看图题也答对的服务。
func goodAnswers(_ r: FakeSystemOne.Request) -> (Int, Any) {
	let questions = r.body["questions"] as? [String: Any] ?? [:]
	var answers: [String: Any] = [:]
	for id in questions.keys { answers[id] = ["type": "noul", "noul": id == "five" ? 0.03 : 0.95] }
	return (200, ["model": "m1-2026.10", "answers": answers])
}

@Test func 判定插件测连接答对才算通() throws {
	#expect(FileManager.default.isExecutableFile(atPath: systemOnePlugin), "先 swift build 把插件编出来：\(systemOnePlugin)")
	let server = try FakeSystemOne(goodAnswers)
	// 地址末尾带了 /v1/systemone/ 也认。
	let (host, p) = systemOne(server, url: server.url + "/v1/systemone/")
	let out = try host.call(p, hook: "describe", input: ["hooks": p.hooks]).get()
	#expect(out["serverModel"] as? String == "m1-2026.10" && out["images"] as? String == "收" && out["elapsedMs"] is NSNumber)
	#expect(out["warnings"] == nil)
	let first = try #require(server.requests.first)
	#expect(first.method == "POST" && first.path == "/v1/systemone")
	#expect(first.headers["authorization"] == "Bearer k-123")
	#expect(first.body["model"] as? String == "m1")
	#expect((server.requests.last?.body["images"] as? [String])?.first?.hasPrefix("data:image/png;base64,") == true)
}

@Test func 判定插件答错测试题就不算通() throws {
	let server = try FakeSystemOne { r in
		let questions = r.body["questions"] as? [String: Any] ?? [:]
		return (200, ["answers": Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, ["noul": 0.5]) })])
	}
	let (host, p) = systemOne(server)
	guard case .failure(let f) = host.call(p, hook: "describe", input: [:]) else {
		Issue.record("答错了应该不算通")
		return
	}
	#expect(f.message.contains("没答对测试题"))
}

@Test func 不收图的服务只能接复核() throws {
	let server = try FakeSystemOne { r in r.body["images"] == nil ? goodAnswers(r) : (422, ["detail": "unknown field images"]) }
	let (host, p) = systemOne(server, hooks: ["route", "review"])
	let out = try host.call(p, hook: "describe", input: ["hooks": p.hooks]).get()
	#expect(out["images"] as? String == "不收")
	#expect((out["warnings"] as? [String])?.first?.contains("route 用不了") == true)
	let (host2, p2) = systemOne(server, hooks: ["review"])
	#expect(try host2.call(p2, hook: "describe", input: ["hooks": p2.hooks]).get()["warnings"] == nil)
}

@Test func 判定插件出错只说固定的话() throws {
	let server = try FakeSystemOne { r in
		r.headers["authorization"] == "Bearer 错的" ? (401, ["error": "bad key"]) : (500, ["error": "服务里的原话SECRET-BODY"])
	}
	let (host, p) = systemOne(server, key: "错的")
	guard case .failure(let wrongKey) = host.call(p, hook: "describe", input: [:]) else {
		Issue.record("密钥不对应该失败")
		return
	}
	#expect(wrongKey.message.contains("密钥不对"))
	let (host2, p2) = systemOne(server)
	guard case .failure(let broken) = host2.call(p2, hook: "describe", input: [:]) else {
		Issue.record("服务出错应该失败")
		return
	}
	#expect(broken.message.contains("500") && !broken.message.contains("SECRET-BODY"))
	#expect(!broken.message.contains("k-123"))
}

@Test func 判定插件没密钥时说清楚怎么存() throws {
	let server = try FakeSystemOne(goodAnswers)
	let name = "没存过密钥-\(UUID().uuidString.prefix(8))"
	let (host, p) = systemOne(server, name: name, key: nil)
	guard case .failure(let f) = host.call(p, hook: "describe", input: [:]) else {
		Issue.record("没密钥应该失败")
		return
	}
	#expect(f.message.contains("security add-generic-password -s shizi -a \(name)"))
	#expect(server.requests.isEmpty, "没密钥就不该发请求")
}

@Test func 判定插件看图和复核的请求() throws {
	let server = try FakeSystemOne(goodAnswers)
	let (host, p) = systemOne(server)
	let png = try #require(pngData(Fixtures.text(["看图"], width: 200, height: 80)))
	let route = try host.call(p, hook: "route", input: ["image": ["data": png.base64EncodedString(), "width": 200, "height": 80]]).get()
	#expect((route["signals"] as? [String: Any])?.count == 6)
	let sent = try #require(server.requests.last)
	#expect((sent.body["images"] as? [String])?.first == "data:image/png;base64," + png.base64EncodedString())
	let lines: [[String: Any]] = (0..<5).map { ["id": $0, "text": "第 \($0) 行", "confidence": 0.3] }
	let review = try host.call(p, hook: "review", input: ["lines": lines, "candidates": [1, 3]]).get()
	#expect(Set((review["suspects"] as? [String: Any])?.keys.map { $0 } ?? []) == ["1", "3"])
	#expect(Set((server.requests.last?.body["questions"] as? [String: Any])?.keys.map { $0 } ?? []) == ["l1", "l3"])
}
