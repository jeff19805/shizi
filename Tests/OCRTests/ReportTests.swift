import Foundation
import Testing
@testable import OCRCore
@testable import ShiziKit

/// 系统没把握的一行（可信度最低那档），字够长、会交给插件复核。
func unsureLine(_ text: String) -> OCRLine {
	OCRLine(text: text, confidence: 0.3, box: NRect(x: 0, y: 0, w: 0.5, h: 0.05), quad: [])
}

@Test func 插件看图记下谁说了什么() throws {
	let p = try fakePlugin(#"cat > /dev/null; echo '{"output":{"signals":{"table":0.8,"photo":0.1}}}'"#, hooks: ["route"])
	let engine = OCREngine(config: OCRConfig(plugins: [p]))
	let page = try engine.runPage(Fixtures.text(["插件看图的测试页"]), page: 1, options: OCROptions())
	let route = try #require(page.steps["route"] as? [[String: Any]])
	#expect(route.count == 1 && route[0]["name"] as? String == "假插件" && route[0]["failed"] == nil)
	#expect((route[0]["signals"] as? [String: Double]) == ["table": 0.8, "photo": 0.1] && (route[0]["ms"] as? Int ?? -1) >= 0)

	// 认法不是「自动」：插件不看图，也就不记。
	var lines = OCROptions()
	lines.mode = .lines
	#expect(try engine.runPage(Fixtures.text(["逐行认"]), page: 1, options: lines).steps["route"] == nil)
}

@Test func 插件复核记下每行的判断() throws {
	let p = try fakePlugin(#"cat > /dev/null; echo '{"output":{"suspects":{"0":0.92,"1":0.1}}}'"#, hooks: ["review"])
	let engine = OCREngine(config: OCRConfig(plugins: [p]))
	var lines = [unsureLine("认得不太对的一行字"), unsureLine("其实没认错的一行"), OCRLine(text: "很有把握的一行", confidence: 1, box: NRect(x: 0, y: 0.5, w: 0.5, h: 0.05), quad: [])]
	var notes: [String] = []
	var steps: [String: Any] = [:]
	engine.markSuspects(&lines, skip: { _ in false }, usePlugins: true, notes: &notes, steps: &steps)
	#expect(lines[0].suspect?.reason == .plugin && lines[1].suspect == nil && lines[2].suspect == nil)
	#expect(steps["reviewCandidates"] as? Int == 2 && steps["reviewed"] as? Int == 2)
	#expect((steps["reviewedLines"] as? [String: Double]) == ["0": 0.92, "1": 0.1])
	let review = try #require((steps["review"] as? [[String: Any]])?.first)
	#expect(review["name"] as? String == "假插件" && review["reviewed"] as? Int == 2 && review["flagged"] as? Int == 1)

	// 没有要复核的行：不叫插件，但记下「0 行」，界面好说用不着。
	var clean = [OCRLine(text: "清清楚楚", confidence: 1, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [])]
	steps = [:]
	engine.markSuspects(&clean, skip: { _ in false }, usePlugins: true, notes: &notes, steps: &steps)
	#expect(steps["reviewCandidates"] as? Int == 0 && steps["review"] == nil)

	// 插件出错：记下没成，可疑行照系统可信度标。
	let broken = try fakePlugin("cat > /dev/null; exit 3", hooks: ["review"])
	var again = [unsureLine("认得不太对的一行字")]
	steps = [:]
	notes = []
	OCREngine(config: OCRConfig(plugins: [broken])).markSuspects(&again, skip: { _ in false }, usePlugins: true, notes: &notes, steps: &steps)
	#expect((steps["review"] as? [[String: Any]])?.first?["failed"] != nil && again[0].suspect?.reason == .lowConfidence)
}

/// 一页假的识别结果，只放识别详情要看的东西。
func reportPage(mode: OCRMode = .lines, steps: [String: Any], suspects: [Suspect.Reason] = []) -> PageResult {
	var page = fakePage(1, "字")
	page.mode = mode
	page.steps = steps
	page.lines = suspects.map { OCRLine(text: "一行", confidence: 0.3, box: NRect(x: 0, y: 0, w: 1, h: 0.1), quad: [], suspect: Suspect(reason: $0, probability: 0.9)) }
	return page
}

@Test func 识别详情说清插件做了什么() {
	let clef = PluginConfig(name: "clef", command: ["/x"], hooks: ["route", "review"])
	let auto = OCROptions()
	var off = OCROptions()
	off.usePlugins = false

	// 没配、关了、认照片默认不用：都说为什么。
	#expect(RecognitionReport(result: reportPage(steps: [:]), options: auto, configured: [], isPhoto: false).plugins.map(\.text) == ["没配判定插件"])
	#expect(RecognitionReport(result: reportPage(steps: [:]), options: off, configured: [clef], isPhoto: true).plugins.first?.text.hasPrefix("认照片默认不用判定插件") == true)
	#expect(RecognitionReport(result: reportPage(steps: [:]), options: off, configured: [clef], isPhoto: false).plugins.first?.text.hasPrefix("这次没用判定插件") == true)

	// 看了图、复核了几行。
	let steps: [String: Any] = [
		"route": [["name": "clef", "ms": 420, "signals": ["table": 0.8, "photo": 0.1]]],
		"signals": ["table": 0.8, "photo": 0.1],
		"review": [["name": "clef", "ms": 830, "reviewed": 3, "flagged": 1]],
		"reviewedLines": ["2": 0.9, "4": 0.2, "5": 0.1],
		"reviewCandidates": 3,
		"rectified": ["kind": "paper", "skewDegrees": 7.6],
		"tiles": 6,
		"ms": 1234,
	]
	let report = RecognitionReport(result: reportPage(mode: .document, steps: steps, suspects: [.plugin, .lowConfidence]), options: auto, configured: [clef], isPhoto: false)
	#expect(report.plugins.map(\.text) == ["clef 看了图（0.4 秒）：看出是表格", "clef 复核了 3 行（0.8 秒）：1 行可能认错，2 行没问题"])
	#expect(
		report.items.map(\.value) == [
			"认文档：判定插件看出有表格", "自动判断（设置 › 识别 里能改成中文优先）", "纸歪了约 8 度，拉正了再认", "字很小，切成 6 块细认", "2 行（判定插件认为的 1 行）", "1.2 秒",
		])
	#expect(report.reviewed == [2: 0.9, 4: 0.2, 5: 0.1] && report.reviewer == "clef")

	// 认法不是「自动」、这一页没要复核的、插件出错。
	var lines = OCROptions()
	lines.mode = .lines
	#expect(
		RecognitionReport(result: reportPage(steps: ["reviewCandidates": 0]), options: lines, configured: [clef], isPhoto: false).plugins.map(\.text)
			== ["认法不是「自动」，插件不看图", "这一页没有系统没把握的长行，用不着插件复核"])
	let failed = RecognitionReport(
		result: reportPage(steps: ["route": [["name": "clef", "ms": 1500, "failed": "连不上"]]]), options: auto, configured: [clef], isPhoto: false)
	#expect(failed.plugins == [RecognitionReport.PluginLine(text: "clef 看图没成：连不上，这一步按代码规则处理", problem: true)])
	#expect(RecognitionReport.seconds(30) == "不到 0.1 秒" && RecognitionReport.seconds(2049) == "2.0 秒")
}
