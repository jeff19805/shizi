import Foundation
import OCRCore

/// ocr_to_file 写到哪、回复里说什么。
enum FileOutput {
	/// 一次最多写这么多页：100 页带着插件认，也能在灵犀给 OCR 配的 300 秒以内认完。
	static let maxPages = 100
	/// 没给 outputPath 时放这里，每次写的时候顺手清掉 7 天前的；要留着就用 outputPath 指定位置。
	static var defaultDirectory: URL {
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("shizi/results", isDirectory: true)
	}
	static let keepDays = 7.0
	/// 回复里「每页开头」最多占这么多字节，页多了其余的写「见文件」。
	static let openingsBudget = 16 * 1024

	/// 写到哪个 .md：给了 outputPath 就用它（以 .md 结尾的绝对路径；给的是已有的文件夹就在里面按默认名字起），没给就放默认文件夹。
	static func target(
		_ outputPath: String?, source: String, pages: [Int], totalPages: Int, now: Date = Date(), directory: URL = defaultDirectory
	) throws -> URL {
		let name = defaultName(source: source, pages: pages, totalPages: totalPages, now: now)
		guard let raw = outputPath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
			cleanUp(directory, now: now)
			return unique(directory.appendingPathComponent(name))
		}
		let path = expandPath(raw)
		guard path.hasPrefix("/") else { throw ArgumentError.invalid(Texts.text("outputPath 要写绝对路径（可以用 ~）")) }
		var isDir: ObjCBool = false
		if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
			return unique(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name))
		}
		guard path.hasSuffix(".md") else {
			throw ArgumentError.invalid(Texts.text("outputPath 要以 .md 结尾（detail=full 时另写一份同名的 .json），或者是一个已有的文件夹"))
		}
		return URL(fileURLWithPath: path)
	}

	/// 「源文件名-时间.md」；不是整份时带上页码，如「报告-p101-200-20261010-102030.md」，接着写的几份一看就知道是哪几页。
	static func defaultName(source: String, pages: [Int], totalPages: Int, now: Date) -> String {
		var stem = URL(fileURLWithPath: expandPath(source)).deletingPathExtension().lastPathComponent
			.replacingOccurrences(of: ":", with: "-")
		if stem.isEmpty { stem = "ocr" }
		if stem.count > 60 { stem = String(stem.prefix(60)) }
		let range = pages == Array(1...max(totalPages, 1)) ? "" : "-p" + pageRanges(pages).replacingOccurrences(of: ",", with: "_")
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyyMMdd-HHmmss"
		return "\(stem)\(range)-\(f.string(from: now)).md"
	}

	/// 同名的 .md 或 .json 已经有了，就在后面加 -2、-3。
	static func unique(_ url: URL) -> URL {
		let fm = FileManager.default
		func taken(_ u: URL) -> Bool {
			fm.fileExists(atPath: u.path) || fm.fileExists(atPath: u.deletingPathExtension().appendingPathExtension("json").path)
		}
		guard taken(url) else { return url }
		let base = url.deletingPathExtension()
		for n in 2... {
			let candidate = URL(fileURLWithPath: base.path + "-\(n)").appendingPathExtension("md")
			if !taken(candidate) { return candidate }
		}
		return url
	}

	/// 清掉默认文件夹里 7 天前写的结果。只动这个文件夹，只删 .md、.json。
	static func cleanUp(_ directory: URL, now: Date = Date()) {
		let fm = FileManager.default
		guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
		for f in files where ["md", "json"].contains(f.pathExtension) {
			if let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
				now.timeIntervalSince(date) > keepDays * 86400
			{
				try? fm.removeItem(at: f)
			}
		}
	}

	/// 写完以后的回复：文件在哪、多大、用了多久，可疑行几行，每页开头一句，说明，没写的页接着用什么 pages。
	static func summary(_ file: ResultFile, totalPages: Int, remaining: [Int], seconds: Double) -> String {
		var out: [String] = []
		out.append(Texts.text("写好了：\(file.markdownURL.path)"))
		let took = String(format: "%.1f", seconds)
		out.append(Texts.text("第 \(pageRanges(file.pages)) 页（文件一共 \(totalPages) 页），\(file.characters) 字，\(size(file.markdownURL))，用了 \(took) 秒。"))
		// 没有汉字，但全角的冒号、括号英文里要换掉。
		if let json = file.jsonURL { out.append(Texts.text("JSON：\(json.path)（\(size(json))）")) }
		if file.suspects > 0 { out.append(Texts.text("可能认错的行 \(file.suspects) 行，文件里每页末尾列着，正文里原样保留。")) }
		out.append("")
		out.append(Texts.text("每页开头："))
		var used = 0
		for (i, o) in file.openings.enumerated() {
			let opening = o.text.count > 40 ? String(o.text.prefix(40)) + "…" : o.text.isEmpty ? Texts.text("（没认出字）") : o.text
			let line = Texts.text("第 \(o.page) 页　\(opening)")
			if used + line.utf8.count > openingsBudget {
				out.append(Texts.text("……（其余 \(file.openings.count - i) 页见文件）"))
				break
			}
			out.append(line)
			used += line.utf8.count + 1
		}
		if !file.notes.isEmpty {
			out.append("")
			out.append(Texts.text("【说明】"))
			out += file.notes.prefix(10).map { "- \($0)" }
		}
		if !remaining.isEmpty {
			out.append("")
			out.append(Texts.text("【一次最多写 \(maxPages) 页，这次写了第 \(pageRanges(file.pages)) 页；没写的接着用 pages=\"\(shortRanges(remaining))\"（会另写一个文件）】"))
		}
		return out.joined(separator: "\n")
	}

	static func size(_ url: URL) -> String {
		let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
		return String(format: "%.1f KB", bytes / 1024)
	}
}
