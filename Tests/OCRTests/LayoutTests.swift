import Foundation
import Testing
@testable import OCRCore

/// 1000×1000 的图上，行高 0.03（30 像素）。
func row(_ text: String, x: Double, y: Double, w: Double = 0.15, degrees: Double = 0) -> OCRLine {
	Fixtures.line(text, x: x, y: y, w: w, h: 0.03, degrees: degrees)
}

func layoutText(_ lines: [OCRLine]) -> String {
	joinLayout(readingLayout(lines, width: 1000, height: 1000), lines)
}

@Test func 侧栏和正文分开输出() {
	// 界面截图：左边一列菜单，右边正文，两边各排各的，纵向位置对不上。
	let side = ["今天", "对话", "团队", "定时", "插件"].enumerated().map { row($1, x: 0.02, y: 0.1 + 0.1 * Double($0), w: 0.1) }
	let body = ["项目记忆", "只在这个项目里成立的事", "还没有记住任何东西", "加一条，比如对接人", "已中止"].enumerated().map {
		row($1, x: 0.3, y: 0.14 + 0.1 * Double($0), w: 0.5)
	}
	let text = layoutText(side + body)
	let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
	#expect(lines.allSatisfy { l in !(side.contains { l.contains($0.text) } && body.contains { l.contains($0.text) }) }, "同一行里混进了两栏：\n\(text)")
	#expect(text.contains("今天\n对话\n团队\n定时\n插件"))
	#expect(text.range(of: "插件\n\n〔[^〕]+〕\n项目记忆", options: .regularExpression) != nil, "两栏之间要空一行、正文那段开头标位置：\n\(text)")
	#expect(text.hasPrefix("〔") && text.components(separatedBy: "〔").count == 3, "每段只在开头标一次：\n\(text)")
}

@Test func 弹窗在中间标中间底部提示条标下方() {
	// 照一张界面截图摆：左边一列菜单，中间一个弹窗，右边一列对话，最底下一条提示。
	let side = ["今天", "对话", "团队", "定时", "插件"].enumerated().map { row($1, x: 0.02, y: 0.1 + 0.06 * Double($0), w: 0.1) }
	let dialog = ["项目记忆", "只在这个项目里成立的事", "加一条，比如对接人"].enumerated().map { row($1, x: 0.35, y: 0.38 + 0.05 * Double($0), w: 0.3) }
	let chat = ["把设置页重排一下", "收到", "正在改", "改好了", "已中止"].enumerated().map { row($1, x: 0.8, y: 0.3 + 0.055 * Double($0)) }
	let banner = [row("这是旧版团队会话，只能查看历史记录", x: 0.35, y: 0.9, w: 0.4)]
	let text = layoutText((side + dialog + chat + banner).shuffled())
	#expect(text == """
		〔左上〕
		今天
		对话
		团队
		定时
		插件

		〔中间〕
		项目记忆
		只在这个项目里成立的事
		加一条，比如对接人

		〔右侧〕
		把设置页重排一下
		收到
		正在改
		改好了
		已中止

		〔下方〕
		这是旧版团队会话，只能查看历史记录
		""", "位置标错了：\n\(text)")
}

@Test func 给人看的字不带位置标记() {
	let side = ["今天", "对话", "团队", "定时", "插件"].enumerated().map { row($1, x: 0.02, y: 0.1 + 0.1 * Double($0), w: 0.1) }
	let body = ["项目记忆", "只在这个项目里成立的事", "还没有记住任何东西"].enumerated().map { row($1, x: 0.3, y: 0.14 + 0.1 * Double($0), w: 0.5) }
	let lines = side + body
	let layout = readingLayout(lines, width: 1000, height: 1000)
	let marked = joinLayout(layout, lines), clean = joinLayout(layout, lines, markers: false)
	#expect(marked.contains("〔") && !clean.contains("〔"))
	let stripped = marked.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("〔") }.joined(separator: "\n")
	#expect(clean == stripped, "除了标记行，两份应该一样：\n\(clean)\n---\n\(marked)")
}

@Test func 表格的列对齐时不拆开() {
	var cells: [OCRLine] = []
	for (r, y) in [0.1, 0.2, 0.3, 0.4].enumerated() {
		for (c, x) in [0.1, 0.4, 0.7].enumerated() { cells.append(row("格\(r)\(c)", x: x, y: y)) }
	}
	let text = layoutText(cells.shuffled())
	#expect(text == "格00  格01  格02\n格10  格11  格12\n格20  格21  格22\n格30  格31  格32", "表格被拆了：\n\(text)")
}

@Test func 多行格子居中的表格也不拆开() {
	// 序号居中、内容格子两行：序号挨着的是单位那一列（也居中），算对齐。
	let lines = [
		row("14", x: 0.05, y: 0.215, w: 0.05), row("接地安装", x: 0.15, y: 0.215), row("1.材料规格：接地模块", x: 0.35, y: 0.2, w: 0.3),
		row("2.材料由投标人提供", x: 0.35, y: 0.23, w: 0.3), row("1基塔", x: 0.7, y: 0.215, w: 0.08),
		row("15", x: 0.05, y: 0.315, w: 0.05), row("接地土石方", x: 0.15, y: 0.315), row("1.土壤类别：普通土壤", x: 0.35, y: 0.3, w: 0.3),
		row("2.挖土深度：2m内", x: 0.35, y: 0.33, w: 0.3), row("m3", x: 0.7, y: 0.315, w: 0.08),
	]
	let text = layoutText(lines)
	#expect(!text.contains("\n\n"), "表格被切成了几栏：\n\(text)")
	#expect(text.firstRange(of: "14")!.lowerBound < text.firstRange(of: "15")!.lowerBound)
}

@Test func 单栏文章顺序不变() {
	let lines = ["第一段第一行", "第一段第二行", "第二段第一行", "第二段第二行"].enumerated().map { i, t in
		row(t, x: 0.1, y: 0.1 + 0.04 * Double(i) + (i >= 2 ? 0.05 : 0), w: 0.7)
	}
	#expect(layoutText(lines.reversed()).split(separator: "\n").map(String.init) == ["第一段第一行", "第一段第二行", "第二段第一行", "第二段第二行"])
}

@Test func 倒着的界面也按栏分块位置跟着字的走向() {
	func page(_ degrees: Double) -> [OCRLine] {
		["今天", "对话", "团队"].enumerated().map { row($1, x: 0.02, y: 0.1 + 0.1 * Double($0), w: 0.1, degrees: degrees) }
			+ ["项目记忆", "只在这个项目里成立的事", "已中止"].enumerated().map { row($1, x: 0.3, y: 0.14 + 0.1 * Double($0), w: 0.5, degrees: degrees) }
	}
	// 位置按字是正的那个方向说：倒着拍的界面，菜单还是在「左」。
	let text = layoutText(page(180).reversed())
	#expect(text == layoutText(page(0)), "转 180° 后跟正着的不一样：\n\(text)")
	let plain = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("〔") }.joined(separator: "\n")
	#expect(plain == "今天\n对话\n团队\n\n项目记忆\n只在这个项目里成立的事\n已中止", "转 180° 后：\n\(text)")
}

@Test func 标签和值两栏的表单不拆开() {
	let lines = [("姓名：张三", "电话：010-12345678"), ("邮箱：a@example.com", "日期：2026年10月9日"), ("地址：某某路1号", "金额：¥1,280.00")]
		.enumerated().flatMap { i, p in [row(p.0, x: 0.05, y: 0.1 + 0.08 * Double(i), w: 0.35), row(p.1, x: 0.55, y: 0.1 + 0.08 * Double(i), w: 0.35)] }
	#expect(layoutText(lines) == "姓名：张三  电话：010-12345678\n邮箱：a@example.com  日期：2026年10月9日\n地址：某某路1号  金额：¥1,280.00")
}
