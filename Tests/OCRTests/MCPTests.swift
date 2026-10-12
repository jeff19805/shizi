import Foundation
import OCRCore
import Testing
@testable import OCRServer

func rpc(_ server: MCPServer, _ obj: [String: Any]) -> [String: Any]? {
	server.handle(String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
}

let server = MCPServer(engine: OCREngine(config: OCRConfig()))

@Test func 握手回协议版本() {
	let r = rpc(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]])
	let result = r?["result"] as? [String: Any]
	#expect(result?["protocolVersion"] as? String == "2025-06-18")
	#expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
	#expect((result?["serverInfo"] as? [String: Any])?["version"] as? String == OCRVersion.current)
	let old = rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
	#expect((old?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
}

@Test func 列出四个工具() {
	let r = rpc(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
	let tools = ((r?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
	#expect(tools.map { $0["name"] as? String } == ["ocr_image", "ocr_to_file", "photos_search", "ocr_status"])
	#expect((tools[1]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false, "写文件的工具不能标成只读")
	#expect(((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String]) == ["path"])
}

@Test func 通知和回复不用回() {
	#expect(rpc(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
	#expect(rpc(server, ["jsonrpc": "2.0", "id": 9, "result": [:]]) == nil)
}

@Test func 出错的几种说法() {
	#expect(((server.handle("{坏的") ?? [:])["error"] as? [String: Any])?["code"] as? Int == -32700)
	let unknown = rpc(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]])
	#expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32602)
	let method = rpc(server, ["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
	#expect((method?["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test func 参数不对是工具出错而不是协议出错() {
	for args: [String: Any] in [[:], ["path": "/nonexistent.png"], ["path": "/x.png", "pages": "三"], ["path": "/x.png", "region": [0, 0, 2, 1]], ["path": "/x.png", "多余": 1]] {
		let r = rpc(server, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "ocr_image", "arguments": args]])
		let result = r?["result"] as? [String: Any]
		#expect(result?["isError"] as? Bool == true, "参数 \(args) 应该报工具错误")
	}
}

@Test func 认一张图() throws {
	let path = Fixtures.save(Fixtures.text(["工具调用测试第一行", "Second line 2026"]))
	let r = rpc(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "ocr_image", "arguments": ["path": path, "detail": "full"]]])
	let result = try #require(r?["result"] as? [String: Any])
	#expect(result["isError"] == nil)
	let content = result["content"] as? [[String: Any]] ?? []
	let text = content.first?["text"] as? String ?? ""
	#expect(Fixtures.compact(text).contains("工具调用测试第一行"))
	#expect(Fixtures.compact(text).contains("Secondline2026"))
	#expect(content.count == 2, "detail=full 要另附一块 JSON")
	let json = try JSONSerialization.jsonObject(with: Data((content[1]["text"] as? String ?? "").utf8)) as? [String: Any]
	#expect((json?["pages"] as? [Any])?.count == 1)
	#expect(result["structuredContent"] == nil, "灵犀只看文字块、Claude Code 有 structuredContent 时只看它：不放，两边才一样")
}

@Test func 回复有大小上限多页时写明接着认哪几页() throws {
	let url = Fixtures.pdf(pages: (1...4).map { n in (1...12).map { "第\(n)页第\($0)行正文内容用来占地方" } })
	let small = MCPServer(engine: OCREngine(config: OCRConfig()), maxReplyBytes: 1500)
	let r = rpc(small, ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "ocr_image", "arguments": ["path": url.path]]])
	let text = (((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
	#expect(text.utf8.count <= 1500, "超了上限：\(text.utf8.count) 字节")
	#expect(text.hasPrefix("【第 1 页】") && text.contains("文件一共 4 页") && text.contains("pages=\""), "\(text)")
}

@Test func 参数解析() throws {
	#expect(try parsePages("1-3,5") == [1, 2, 3, 5])
	#expect(throws: ArgumentError.self) { try parsePages("3-1") }
	#expect(parseLanguages(["auto"]) == (nil, .auto))
	#expect(parseLanguages(["zh-Hans", " en-US "]) == (["zh-Hans", "en-US"], nil))
}
