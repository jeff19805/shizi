import Foundation
import OCRCore
import Testing
@testable import OCRServer

func tempDir() throws -> URL {
	let url = Fixtures.tempURL("dir")
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

func callTool(_ server: MCPServer, _ name: String, _ args: [String: Any], meta: [String: Any]? = nil) -> (text: [String], isError: Bool) {
	var params: [String: Any] = ["name": name, "arguments": args]
	if let meta { params["_meta"] = meta }
	let r = rpc(server, ["jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": params])
	let result = r?["result"] as? [String: Any] ?? [:]
	let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
	return (texts, result["isError"] as? Bool == true)
}

@Test func 整份写成文件回复只给摘要() throws {
	let pdf = Fixtures.pdf(pages: [["写文件第一页的正文"], ["写文件第二页的正文"], ["写文件第三页的正文"]])
	let dir = try tempDir()
	let r = callTool(server, "ocr_to_file", ["path": pdf.path, "outputPath": dir.path, "detail": "full"])
	#expect(!r.isError, "\(r.text)")
	let reply = r.text.joined()
	let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
	#expect(files.count == 2 && files[0].hasSuffix(".json") && files[1].hasSuffix(".md"), "\(files)")
	let md = try String(contentsOf: dir.appendingPathComponent(files[1]), encoding: .utf8)
	#expect(md.hasPrefix("# ") && md.contains("【第 1 页】") && md.contains("【第 3 页】"))
	#expect(Fixtures.compact(md).contains("写文件第三页的正文"))
	let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(files[0]))) as? [String: Any]
	#expect((json?["pages"] as? [Any])?.count == 3)
	#expect(reply.contains("写好了：\(dir.appendingPathComponent(files[1]).path)") && reply.contains("第 1-3 页") && reply.contains("每页开头"))
	#expect(!reply.contains("写文件第一页的正文写文件第二页"), "回复里不该有全文")
}

@Test func 写文件不覆盖已有的文件() throws {
	let image = Fixtures.save(Fixtures.text(["不覆盖"]))
	let dir = try tempDir()
	let existing = dir.appendingPathComponent("已经有了.md")
	try Data("别动我".utf8).write(to: existing)
	for args: [String: Any] in [
		["path": image, "outputPath": existing.path],
		["path": image, "outputPath": "相对路径.md"],
		["path": image, "outputPath": dir.appendingPathComponent("不是md.txt").path],
	] {
		#expect(callTool(server, "ocr_to_file", args).isError, "\(args) 应该报错")
	}
	#expect(try String(contentsOf: existing, encoding: .utf8) == "别动我")
	// full 时要另写的 .json 已经有了，也不写。
	try Data("{}".utf8).write(to: dir.appendingPathComponent("只有json.json"))
	#expect(callTool(server, "ocr_to_file", ["path": image, "outputPath": dir.appendingPathComponent("只有json.md").path, "detail": "full"]).isError)
	#expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("只有json.md").path))
}

@Test func 默认文件名带页码同名就加编号() throws {
	let now = Date()
	#expect(FileOutput.defaultName(source: "~/x/报告.pdf", pages: [1, 2, 3], totalPages: 3, now: now).range(of: #"^报告-\d{8}-\d{6}\.md$"#, options: .regularExpression) != nil)
	#expect(FileOutput.defaultName(source: "/x/报告.pdf", pages: [2, 3, 5], totalPages: 9, now: now).range(of: #"^报告-p2-3_5-\d{8}-\d{6}\.md$"#, options: .regularExpression) != nil)
	let dir = try tempDir()
	let first = dir.appendingPathComponent("a.md")
	try Data().write(to: first)
	#expect(FileOutput.unique(first).lastPathComponent == "a-2.md")
	try Data().write(to: dir.appendingPathComponent("b.json"))
	#expect(FileOutput.unique(dir.appendingPathComponent("b.md")).lastPathComponent == "b-2.md")
}

@Test func 默认文件夹只清七天前的结果() throws {
	let dir = try tempDir()
	let fm = FileManager.default
	let old = Date().addingTimeInterval(-8 * 86400)
	for (name, date) in [("旧.md", old), ("旧.json", old), ("旧.txt", old), ("新.md", Date())] {
		let url = dir.appendingPathComponent(name)
		try Data().write(to: url)
		try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
	}
	FileOutput.cleanUp(dir)
	#expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["旧.txt", "新.md"])
}

@Test func 一次最多写一百页的提示() throws {
	let dir = try tempDir()
	let file = try ResultFile(markdownURL: dir.appendingPathComponent("r.md"), withJSON: false, header: "# r", totalPages: 300)
	for n in 1...3 { try file.add(fakePage(n, "第 \(n) 页开头一句\n后面的字")) }
	try file.finish()
	let summary = FileOutput.summary(file, totalPages: 300, remaining: Array(4...300), seconds: 1.5)
	#expect(summary.contains("第 2 页　第 2 页开头一句"))
	#expect(summary.contains("一次最多写 100 页") && summary.contains("pages=\"4-300\""))
}

@Test func 带了进度令牌就每页报一次() throws {
	let pdf = Fixtures.pdf(pages: [["进度第一页"], ["进度第二页"]])
	var sent: [[String: Any]] = []
	let watched = MCPServer(engine: OCREngine(config: OCRConfig())) { line in
		if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { sent.append(obj) }
	}
	_ = callTool(watched, "ocr_image", ["path": pdf.path], meta: ["progressToken": "t1"])
	let progress = sent.filter { $0["method"] as? String == "notifications/progress" }.compactMap { $0["params"] as? [String: Any] }
	#expect(progress.compactMap { $0["progress"] as? Int } == [1, 2])
	#expect(progress.allSatisfy { $0["progressToken"] as? String == "t1" && $0["total"] as? Int == 2 })
	sent = []
	_ = callTool(watched, "ocr_image", ["path": pdf.path])
	#expect(sent.isEmpty, "没要进度就不报")
}
