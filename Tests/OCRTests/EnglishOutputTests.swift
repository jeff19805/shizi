import Foundation
import Testing
@testable import OCRCore
@testable import OCRServer

// MCP 服务、命令行、识别结果在英文下不能漏出中文（规矩见 AGENTS.md）。拿 en.lproj 当取字的包，跑主要的几条路：
// 工具说明和握手、命令行帮助和状态、结果的排版和分页提示、真认一张英文图和一份英文 PDF、写文件、按字找照片、参数和文件出错的提示。
// 认出来的字本身不算（图上画的都是英文），查的是程序自己说的话。走不到的说明（某些插件出错、拉正失败这类）新加时照着翻。

private let englishPack = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
	.deletingLastPathComponent().appendingPathComponent("scripts/app/en.lproj")

/// 在英文下跑一段，跑完换回原来的（测试一条条跑，不会互相踩）。
func inEnglish<T>(_ body: () throws -> T) rethrows -> T {
	let saved = Texts.english
	Texts.english = Bundle(path: englishPack.path)
	defer { Texts.english = saved }
	return try body()
}

/// 带汉字的那几行，挂的时候好看是哪句。
func hanLines(_ s: String) -> String {
	s.components(separatedBy: "\n").filter(hasHan).joined(separator: "\n")
}

/// 调一个工具，把回复里的几块文字接起来。
func callTool(_ name: String, _ args: [String: Any]) -> String {
	let r = rpc(server, ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": name, "arguments": args]])
	let content = (r?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
	return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

@Test func 平常取字是中文() {
	// 跑测试的程序旁边没有语言包，也不在仓库里：照原文出中文。原来那些拿中文比对的测试靠的就是这个。
	#expect(Texts.english == nil)
	#expect(Texts.text("共 \(3) 页") == "共 3 页")
}

@Test func 英文下工具说明和握手没有中文() {
	inEnglish {
		let list = rpc(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
		let tools = jsonString(((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? [], pretty: true)
		#expect(tools.contains("ocr_image") && !hasHan(tools), "工具说明里还有中文：\n\(hanLines(tools))")
		let hello = jsonString(rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]) ?? [:])
		#expect(!hasHan(hello), "握手里还有中文：\n\(hanLines(hello))")
	}
}

@Test func 英文下命令行帮助和状态没有中文() {
	inEnglish {
		#expect(usage.contains("shizi-mcp") && !hasHan(usage), "命令行帮助里还有中文：\n\(hanLines(usage))")
		let status = statusText(OCREngine(config: OCRConfig()))
		#expect(!hasHan(status), "状态里还有中文：\n\(hanLines(status))")
		let tool = callTool("ocr_status", [:])
		#expect(!tool.isEmpty && !hasHan(tool), "ocr_status 里还有中文：\n\(hanLines(tool))")
	}
}

@Test func 英文下结果的排版和分页提示没有中文() {
	inEnglish {
		func line(_ text: String, _ reason: Suspect.Reason, _ p: Double?) -> OCRLine {
			OCRLine(text: text, confidence: 0.3, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [], suspect: Suspect(reason: reason, probability: p))
		}
		func page(_ n: Int, text: String, lines: [OCRLine] = [], barcodes: [String] = []) -> PageResult {
			PageResult(
				page: n, width: 100, height: 100, mode: .lines, lines: lines, text: text, cleanText: text, document: nil, barcodes: barcodes,
				notes: [], coordinateSpace: "original", rectifiedImage: nil, steps: [:])
		}
		// 没认出字、多页的页标题、条码、三种可能认错的行（超过上限的略掉）、没认完的页。
		let suspects = [line("Total 12.50", .plugin, 0.9), line("Paid", .lowConfidence, nil), line("Signature", .documentOnly, nil)]
		let rendered = renderText([page(1, text: "", lines: suspects, barcodes: ["https://example.com"])], totalPages: 3, maxSuspects: 2)
		#expect(!hasHan(rendered), "结果里还有中文：\n\(hanLines(rendered))")
		// 一页就放不下：只给前面几行，末尾说怎么分块认、接着认哪几页。
		var cut = ModelReply(totalPages: 3, maxBytes: 1200, maxLines: 30)
		let fitted = cut.add(page(1, text: (1...100).map { "Line \($0) of a long page" }.joined(separator: "\n")))
		#expect(!fitted)
		let tail = cut.text(remaining: [2, 3])
		#expect(cut.cut != nil && !hasHan(tail), "分页提示里还有中文：\n\(hanLines(tail))")
		// 页数到了一次能认的上限：接着认哪几页。
		var many = ModelReply(totalPages: 300)
		let added = many.add(page(1, text: "Hello"))
		#expect(added)
		let more = many.text(remaining: Array(2...300))
		#expect(!hasHan(more), "分页提示里还有中文：\n\(hanLines(more))")
		// 分栏页面每段开头的位置标记：照 LayoutTests 那张界面截图摆（左边菜单、中间弹窗、右边对话、底下提示条），只是字换成英文。
		let side = ["Today", "Chats", "Team", "Schedule", "Plugins"].enumerated().map { row($1, x: 0.02, y: 0.1 + 0.06 * Double($0), w: 0.1) }
		let dialog = ["Project memory", "Facts that only hold here", "Add one, such as a contact"].enumerated().map {
			row($1, x: 0.35, y: 0.38 + 0.05 * Double($0), w: 0.3)
		}
		let chat = ["Rearrange settings", "Got it", "Working on it", "Done", "Stopped"].enumerated().map { row($1, x: 0.8, y: 0.3 + 0.055 * Double($0)) }
		let banner = [row("This old team chat is read-only", x: 0.35, y: 0.9, w: 0.4)]
		let marked = layoutText(side + dialog + chat + banner)
		#expect(marked.contains("〔") && !hasHan(marked), "位置标记还是中文：\n\(hanLines(marked))")
	}
}

@Test func 英文下认图认PDF写文件找照片和出错的回复没有中文() throws {
	let image = Fixtures.save(Fixtures.text(["Hello world", "Total 12.50"]))
	let pdf = Fixtures.pdf(pages: [["First page"], ["Second page"]]).path
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shizi-english-\(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: folder) }
	let savedIndex = Tools.photoIndexPath
	Tools.photoIndexPath = folder.appendingPathComponent("photos.sqlite").path
	defer { Tools.photoIndexPath = savedIndex }
	inEnglish {
		let calls: [(String, String, [String: Any])] = [
			("认图", "ocr_image", ["path": image]),
			("PDF 自带的字", "ocr_image", ["path": pdf, "pages": "1"]),
			("PDF 认图", "ocr_image", ["path": pdf, "textLayer": false]),
			("写文件", "ocr_to_file", ["path": pdf, "outputPath": folder.path]),
			("找照片", "photos_search", ["query": "hello"]),
			("文件不在", "ocr_image", ["path": "/nonexistent.png"]),
			("页码不对", "ocr_image", ["path": image, "pages": "x"]),
			("多余的参数", "ocr_image", ["path": image, "extra": 1]),
		]
		for (what, tool, args) in calls {
			let text = callTool(tool, args)
			#expect(!text.isEmpty && !hasHan(text), "\(what)的回复里还有中文：\n\(hanLines(text))")
		}
		// 写出来的文件开头那几行（标题、来源）也是英文。
		let written = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "md" } ?? []
		let file = written.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
		#expect(!file.isEmpty && !hasHan(file), "写出的文件里还有中文：\n\(hanLines(file))")
	}
}

@Test func 插件跟核心说同一种语言() throws {
	// 核心启动插件时告诉它自己用的语言：插件自己照系统定的话，会跟拾字设的界面语言、跟测试里的核心对不上。
	let plugin = PluginConfig(name: "x", command: ["/bin/echo"], hooks: ["review"])
	#expect(PluginHost.environment(for: plugin, parent: [:])["OCR_PLUGIN_LANGUAGE"] == "zh-Hans")
	inEnglish { #expect(PluginHost.environment(for: plugin, parent: [:])["OCR_PLUGIN_LANGUAGE"] == "en") }
	// 真起一次插件：没存密钥时报的话跟着核心是英文，存密钥的命令照样在里面。
	let server = try FakeSystemOne(goodAnswers)
	let (host, config) = systemOne(server, name: "no-key-\(UUID().uuidString.prefix(8))", key: nil)
	inEnglish {
		guard case .failure(let failure) = host.call(config, hook: "describe", input: [:]) else {
			Issue.record("没存密钥应该报错")
			return
		}
		#expect(!hasHan(failure.message) && failure.message.contains("security add-generic-password -s shizi"), "插件报的话：\(failure.message)")
	}
}
