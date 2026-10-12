import AppKit
import OCRCore
import SwiftUI

/// 右边：当前页认出的字。「整页」是一整段，给读和复制；「逐行」一行一项，可能认错的标出来，点一行原图上那一行的框亮起来。
/// 两种看法在工具栏上切（菜单「显示」里也有，⌘1、⌘2）：原来放在这一栏顶上单占一条，像网页的标签页，不像 Mac 的 App。
struct TextPane: View {
	@Bindable var doc: DocumentModel
	@AppStorage(ViewOptions.textMode) private var mode = TextMode.page

	var body: some View {
		content
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			// 在原图上点了一行：换到逐行，好看到是哪一行。
			.onChange(of: doc.selectedLine) { _, line in
				if line != nil && mode == .page { mode = .lines }
			}
	}

	@ViewBuilder var content: some View {
		let n = doc.page
		if let result = doc.results[n] {
			if result.lines.isEmpty && result.barcodes.isEmpty {
				ContentUnavailableView("这一页没认出字", systemImage: "text.magnifyingglass", description: Text("可以在左边的图上框一块，单独认那一块。"))
			} else if mode == .page {
				PageText(result: result)
			} else {
				LineList(doc: doc, lines: result.lines, review: RecognitionReport.review(result.steps))
			}
		} else if let failure = doc.failures[n] {
			ContentUnavailableView {
				Label("这一页认不了", systemImage: "exclamationmark.triangle")
			} description: {
				Text(failure)
			} actions: {
				Button("重新识别") { doc.start() }
			}
		} else if doc.isRunning {
			VStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text(working == n ? "正在识别这一页" : "还没认到这一页，正在认第 \(working) 页")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		} else {
			ContentUnavailableView {
				Label("这一页还没认", systemImage: "pause.circle")
			} description: {
				Text("识别在前面停下了。")
			} actions: {
				Button("重新识别") { doc.start() }
			}
		}
	}

	var working: Int {
		(1...doc.totalPages).first { doc.results[$0] == nil && doc.failures[$0] == nil } ?? doc.page
	}
}

struct PageText: View {
	let result: PageResult

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				ForEach(Array(textBlocks(result.cleanText).enumerated()), id: \.offset) { _, block in
					switch block {
					case .text(let text):
						Text(text)
							.lineSpacing(5)
							.textSelection(.enabled)
					case .table(let rows):
						TableGrid(rows: rows)
					}
				}
				if !result.barcodes.isEmpty {
					VStack(alignment: .leading, spacing: 4) {
						Text("二维码 / 条码").font(.headline)
						ForEach(result.barcodes, id: \.self) { Text($0).textSelection(.enabled) }
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(16)
		}
	}
}

struct LineList: View {
	@Bindable var doc: DocumentModel
	let lines: [OCRLine]
	/// 判定插件复核过的行和插件名。
	var review: (lines: [Int: Double], name: String) = ([:], "判定插件")

	var body: some View {
		ScrollViewReader { proxy in
			List(selection: $doc.selectedLine) {
				ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
					LineRow(line: line, reviewer: review.lines[i] == nil ? nil : review.name, reviewedOK: (review.lines[i] ?? 1) < 0.5)
						.tag(i)
						.id(i)
						.contextMenu {
							Button("复制这一行") {
								NSPasteboard.general.clearContents()
								NSPasteboard.general.setString(line.text, forType: .string)
							}
						}
				}
			}
			.listStyle(.inset)
			.onChange(of: doc.selectedLine) { _, line in
				if let line { withAnimation { proxy.scrollTo(line) } }
			}
		}
	}
}

/// 逐行里的一行：可能认错的行首琥珀 ⚠︎ 加原因；判定插件复核过、认为没问题的，下面一行淡淡地写「插件 看过，没问题」，
/// 好让人看得出插件起了作用。
struct LineRow: View {
	let line: OCRLine
	/// 复核过这一行的插件名；没复核过是 nil。
	var reviewer: String?
	/// 插件复核过、认为没认错。
	var reviewedOK = false

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			if line.suspect != nil {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(line.text)
					.lineLimit(4)
				if let suspect = line.suspect {
					Text("可能认错 · \(reason(suspect))")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else if let reviewer, reviewedOK {
					Label("\(reviewer) 看过，没问题", systemImage: "checkmark")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding(.vertical, 2)
	}

	func reason(_ s: Suspect) -> String {
		switch s.reason {
		case .lowConfidence: return "系统没把握"
		case .plugin: return "\(reviewer ?? "判定插件") 认为认错了（约 \(Int((s.probability ?? 0) * 100))%）"
		case .documentOnly: return "多半是公章或签名"
		}
	}
}

/// 整页里的一段：普通的字，或者一张表（认文档认出的表格在字里是 Markdown 表格，给人看时画成真的表）。
enum TextBlock {
	case text(String)
	case table([[String]])
}

/// 把整页的字切成一段段：连着的「| … |」行是一张表，分隔行「| --- |」不要；格子里的「\|」是字面上的竖线。
func textBlocks(_ text: String) -> [TextBlock] {
	var blocks: [TextBlock] = []
	var lines: [String] = []
	var rows: [[String]] = []
	func flushText() {
		if !lines.isEmpty { blocks.append(.text(lines.joined(separator: "\n"))) }
		lines = []
	}
	func flushTable() {
		if !rows.isEmpty { blocks.append(.table(rows)) }
		rows = []
	}
	for line in text.components(separatedBy: "\n") {
		let t = line.trimmingCharacters(in: .whitespaces)
		guard t.count >= 2, t.hasPrefix("|"), t.hasSuffix("|") else {
			flushTable()
			lines.append(line)
			continue
		}
		flushText()
		let cells = tableCells(t)
		if !cells.isEmpty && cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
		rows.append(cells)
	}
	flushText()
	flushTable()
	return blocks.filter {
		if case .text(let t) = $0 { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		return true
	}
}

/// 「| a | b\|c |」→ ["a", "b|c"]
func tableCells(_ row: String) -> [String] {
	var cells: [String] = []
	var cell = ""
	var escaped = false
	for ch in row.dropFirst().dropLast() {
		if escaped {
			cell.append(ch == "|" ? "|" : "\\\(ch)")
			escaped = false
		} else if ch == "\\" {
			escaped = true
		} else if ch == "|" {
			cells.append(cell.trimmingCharacters(in: .whitespaces))
			cell = ""
		} else {
			cell.append(ch)
		}
	}
	cells.append(cell.trimmingCharacters(in: .whitespaces))
	return cells
}

/// 表格：第一行是表头（加粗），行与行之间一条细线；数字靠右、用等宽数字，好对着比。
struct TableGrid: View {
	let rows: [[String]]

	var body: some View {
		let columns = rows.map(\.count).max() ?? 0
		// 整列都是数字（空格子不算）的，表头也跟着靠右，跟下面的数对齐。
		let numeric = (0..<columns).map { c in
			let body = rows.dropFirst().map { c < $0.count ? $0[c] : "" }.filter { !$0.isEmpty }
			return !body.isEmpty && body.allSatisfy(isNumber)
		}
		Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
			ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
				if r > 0 { Divider() }
				GridRow {
					ForEach(0..<columns, id: \.self) { c in
						let text = c < row.count ? row[c] : ""
						Text(text)
							.fontWeight(r == 0 ? .semibold : .regular)
							.monospacedDigit()
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: numeric[c] ? .trailing : .leading)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
					}
				}
			}
		}
		.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
	}

	func isNumber(_ s: String) -> Bool {
		!s.isEmpty && s.allSatisfy { $0.isNumber || ".,-+%¥$".contains($0) }
	}
}
