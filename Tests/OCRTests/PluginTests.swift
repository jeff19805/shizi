import Foundation
import ImageIO
import Testing
@testable import OCRCore

/// 写一个假插件脚本，返回它的配置。
/// 不测超时的几条给足 10 秒：整套测试并行跑识别时机器很忙，起一个 sh 偶尔超过默认的 1.5 秒。
func fakePlugin(_ body: String, hooks: [String] = ["route", "review"], timeoutMs: Int? = 10_000) throws -> PluginConfig {
	let url = Fixtures.tempURL("sh")
	try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
	try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
	return PluginConfig(name: "假插件", command: [url.path], hooks: hooks, timeoutMs: timeoutMs, env: ["FAKE": "1"], enabled: nil)
}

@Test func 插件正常回结果() throws {
	let p = try fakePlugin(#"cat > /dev/null; echo '{"output":{"signals":{"table":0.9}}}'"#)
	let host = PluginHost(config: OCRConfig(plugins: [p]))
	let out = try host.call(p, hook: "route", input: ["image": ["path": "/x"]]).get()
	#expect(((out["signals"] as? [String: Any])?["table"] as? NSNumber)?.doubleValue == 0.9)
}

@Test func 插件拿得到输入和配置里的环境变量() throws {
	let p = try fakePlugin(#"read line; echo "{\"output\":{\"echo\":$line,\"fake\":\"$FAKE\"}}""#)
	let out = try PluginHost(config: OCRConfig(plugins: [p])).call(p, hook: "describe", input: [:]).get()
	#expect((out["echo"] as? [String: Any])?["hook"] as? String == "describe")
	#expect(out["fake"] as? String == "1")
}

@Test func 插件报错原样带回() throws {
	let p = try fakePlugin(#"cat > /dev/null; echo '{"error":"连不上服务"}'"#)
	let r = PluginHost(config: OCRConfig(plugins: [p])).call(p, hook: "review", input: [:])
	guard case .failure(let f) = r else { Issue.record("应该失败"); return }
	#expect(f.message == "连不上服务")
}

@Test func 插件超时会被停掉() throws {
	let p = try fakePlugin("sleep 5", timeoutMs: 300)
	let started = Date()
	let r = PluginHost(config: OCRConfig(plugins: [p])).call(p, hook: "route", input: [:])
	#expect(Date().timeIntervalSince(started) < 2)
	guard case .failure(let f) = r else { Issue.record("应该超时"); return }
	#expect(f.message.contains("超过 300 毫秒"))
}

@Test func 插件不读输入就退出也不会把服务带崩() throws {
	let p = try fakePlugin(#"echo '{"output":{}}'"#)
	let big = String(repeating: "很长的一行字", count: 50_000)
	let r = PluginHost(config: OCRConfig(plugins: [p])).call(p, hook: "review", input: ["lines": [["id": 0, "text": big]]])
	if case .failure(let f) = r { #expect(f.message.contains("JSON") || f.message.contains("超过")) }
}

@Test func 插件程序不存在() {
	let p = PluginConfig(name: "没有", command: ["/nonexistent/plugin"], hooks: ["route"], timeoutMs: nil, env: nil, enabled: nil)
	guard case .failure(let f) = PluginHost(config: OCRConfig(plugins: [p])).call(p, hook: "route", input: [:]) else {
		Issue.record("应该失败")
		return
	}
	#expect(f.message.contains("启动不了"))
}

@Test func 配置文件读取与停用() throws {
	let url = Fixtures.tempURL("json")
	try #"{"plugins":[{"name":"a","command":["/bin/echo"],"hooks":["route"]},{"name":"b","command":["/bin/echo"],"hooks":["review"],"enabled":false}]}"#
		.write(to: url, atomically: true, encoding: .utf8)
	let (config, problem) = OCRConfig.load(path: url.path)
	#expect(problem == nil)
	let host = PluginHost(config: config)
	#expect(host.plugins.map(\.name) == ["a"])
	#expect(host.plugins(for: "review").isEmpty)
	#expect(OCRConfig.load(path: "/nonexistent.json").config.plugins == nil)
	try "{不是 JSON".write(to: url, atomically: true, encoding: .utf8)
	#expect(OCRConfig.load(path: url.path).problem != nil)
}

@Test func 插件只拿到白名单里的环境变量() throws {
	let p = try fakePlugin(#"cat > /dev/null; echo "{\"output\":{\"home\":\"$HOME\",\"secret\":\"$SECRET_THING\",\"name\":\"$OCR_PLUGIN_NAME\",\"fake\":\"$FAKE\"}}""#)
	let host = PluginHost(config: OCRConfig(plugins: [p]), environment: ["HOME": "/tmp/家", "PATH": "/usr/bin:/bin", "SECRET_THING": "不该传"])
	let out = try host.call(p, hook: "describe", input: [:]).get()
	#expect(out["home"] as? String == "/tmp/家")
	#expect(out["secret"] as? String == "", "白名单外的环境变量不该传给插件")
	#expect(out["name"] as? String == "假插件")
	#expect(out["fake"] as? String == "1")
}

@Test func 看图的插件直接拿到图的数据() throws {
	let dump = Fixtures.tempURL("json")
	var p = try fakePlugin(#"cat > "$DUMP"; echo '{"output":{"signals":{"table":0.1}}}'"#, hooks: ["route"])
	p.env?["DUMP"] = dump.path
	let image = Fixtures.text(["插件看图"], width: 2400, height: 600)
	let page = try OCREngine(config: OCRConfig(plugins: [p])).runPage(image, page: 1, options: OCROptions())
	#expect((page.steps["signals"] as? [String: Double])?["table"] == 0.1)
	let sent = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
	#expect(sent["protocol"] as? Int == 2 && sent["hook"] as? String == "route")
	let img = try #require((sent["input"] as? [String: Any])?["image"] as? [String: Any])
	#expect(img["path"] == nil && img["width"] as? Int == 2400 && img["height"] as? Int == 600)
	let png = try #require(Data(base64Encoded: img["data"] as? String ?? ""))
	let decoded = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
	#expect(abs(max(decoded.width, decoded.height) - 1600) <= 1, "长边缩到 1600 再给")
}
