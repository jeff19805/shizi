import Foundation

/// 一边认一边往文件里写：给模型看的字写成 .md（跟 ocr_image 回复里的写法一样），要 JSON 时另写一份同名的 .json。
/// 认完一页写一页，几百页也不占内存；中途出错时，已经写下的页还在。
public final class ResultFile {
	public let markdownURL: URL
	public let jsonURL: URL?
	let totalPages: Int
	let markdown: FileHandle
	let json: FileHandle?
	/// 已经写下的页码。
	public private(set) var pages: [Int] = []
	/// 正文字数（不带位置标记、可疑行清单这些）。
	public private(set) var characters = 0
	public private(set) var suspects = 0
	/// 各页的说明，去掉重复的。
	public private(set) var notes: [String] = []
	/// 每页正文的第一行，给回复里列「每页开头」。
	public private(set) var openings: [(page: Int, text: String)] = []
	var finished = false

	/// 两个文件都不能已经存在：不覆盖别的文件（模型写错路径时，别把用户的文件冲掉）。文件夹没有就建。
	public init(markdownURL: URL, withJSON: Bool, header: String, totalPages: Int) throws {
		let jsonURL = withJSON ? markdownURL.deletingPathExtension().appendingPathExtension("json") : nil
		let fm = FileManager.default
		for url in [markdownURL] + (jsonURL.map { [$0] } ?? []) where fm.fileExists(atPath: url.path) {
			throw OCRError.badArgument("\(url.path) 已经有了，不覆盖；换个文件名")
		}
		try fm.createDirectory(at: markdownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard fm.createFile(atPath: markdownURL.path, contents: Data((header + "\n\n").utf8)) else {
			throw OCRError.badArgument("写不了 \(markdownURL.path)")
		}
		let md = try FileHandle(forWritingTo: markdownURL)
		try md.seekToEnd()
		var js: FileHandle?
		if let jsonURL {
			guard fm.createFile(atPath: jsonURL.path, contents: Data("{\"totalPages\":\(totalPages),\"pages\":[".utf8)) else {
				throw OCRError.badArgument("写不了 \(jsonURL.path)")
			}
			js = try FileHandle(forWritingTo: jsonURL)
			try js?.seekToEnd()
		}
		markdown = md
		json = js
		self.markdownURL = markdownURL
		self.jsonURL = jsonURL
		self.totalPages = totalPages
	}

	deinit {
		try? finish()
	}

	public func add(_ page: PageResult) throws {
		let first = pages.isEmpty
		// 先写字再写 JSON：JSON 中途断了，字还是全的。
		try markdown.write(contentsOf: Data(((first ? "" : "\n\n") + renderPage(page, multi: totalPages > 1)).utf8))
		try json?.write(contentsOf: Data(((first ? "" : ",") + jsonString(pageJSON(page))).utf8))
		pages.append(page.page)
		characters += page.cleanText.count
		suspects += page.lines.filter { $0.suspect != nil }.count
		for n in page.notes where !notes.contains(n) { notes.append(n) }
		let opening = page.cleanText.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
		openings.append((page.page, opening.map(String.init) ?? ""))
	}

	/// 收尾：JSON 补上结尾、关文件。可以重复调。
	public func finish() throws {
		guard !finished else { return }
		finished = true
		try markdown.close()
		if let json {
			try json.write(contentsOf: Data("]}".utf8))
			try json.close()
		}
	}
}
