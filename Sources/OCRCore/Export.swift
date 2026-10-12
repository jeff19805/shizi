import Foundation

/// 给人看的导出（拾字的「复制全文」「导出…」）：正文用不带位置标记的字，多页时按页分节；
/// 不带「可能认错」清单和说明——那些是给只看文字的模型准备的，人有原图可以对。

/// Markdown：标题是文件名，多页时每页一个「## 第 N 页」。认文档认出的表格本来就是 Markdown 表格。
public func exportMarkdown(_ pages: [PageResult], title: String, totalPages: Int) -> String {
	var parts = ["# \(title)"]
	for p in pages {
		var block: [String] = []
		if totalPages > 1 { block.append("## 第 \(p.page) 页") }
		block.append(p.cleanText.isEmpty ? "（没认出字）" : p.cleanText)
		if !p.barcodes.isEmpty { block.append("二维码 / 条码：\n" + p.barcodes.map { "- \($0)" }.joined(separator: "\n")) }
		parts.append(block.joined(separator: "\n\n"))
	}
	return parts.joined(separator: "\n\n") + "\n"
}

/// 纯文字：多页时每页前面一行「第 N 页」。
public func exportPlainText(_ pages: [PageResult], totalPages: Int) -> String {
	pages.map { p in
		var block: [String] = []
		if totalPages > 1 { block.append("第 \(p.page) 页") }
		if !p.cleanText.isEmpty { block.append(p.cleanText) }
		block += p.barcodes
		return block.joined(separator: "\n")
	}.joined(separator: "\n\n") + "\n"
}
