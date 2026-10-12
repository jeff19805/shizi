import Foundation
import OCRCore

/// 一页是怎么认的、判定插件做了什么：「识别详情」和逐行里的插件标记用。都从识别结果里的 steps、notes 读，不另外记。
/// 插件没用上时也要说为什么：你加了 Clef 却看不出区别，多半是它根本没被叫到（认照片默认不用、认法不是「自动」、
/// 这一页没有要复核的行），不说清楚就像没装一样。
struct RecognitionReport: Equatable {
	struct Item: Equatable, Hashable {
		var label: String
		var value: String
	}

	/// 判定插件那一节的一句；`problem` 的前面放警告图标。
	struct PluginLine: Equatable, Hashable {
		var text: String
		var problem = false
	}

	var items: [Item] = []
	var plugins: [PluginLine] = []
	/// 插件复核过的行：第几行（阅读顺序）→ 插件认为认错的概率。
	var reviewed: [Int: Double] = [:]
	/// 复核的插件叫什么；几个一起复核时就说「判定插件」。
	var reviewer = String(localized: "判定插件")

	/// `configured`：配置里开着的插件；`isPhoto`：认的是照片（没用插件时说的原因不一样）。
	init(result: PageResult, options: OCROptions, configured: [PluginConfig], isPhoto: Bool) {
		let steps = result.steps
		items.append(Item(label: String(localized: "认法"), value: Self.modeText(result, steps: steps, auto: options.mode == .auto)))
		if let layer = Self.textLayerText(result) { items.append(Item(label: String(localized: "文字层"), value: layer)) }
		if !result.textLayer { items.append(Item(label: String(localized: "语言"), value: Self.languageText(steps: steps, options: options))) }
		if let rectified = steps["rectified"] as? [String: Any], let skew = (rectified["skewDegrees"] as? NSNumber)?.doubleValue {
			let degrees = Int(skew.rounded())
			items.append(Item(label: String(localized: "拉正"), value: String(localized: "纸歪了约 \(degrees) 度，拉正了再认")))
		}
		if let grid = (steps["tiles"] as? NSNumber)?.intValue {
			items.append(Item(label: String(localized: "小字"), value: String(localized: "字很小，切成 \(grid) 块细认")))
		} else if steps["upscaled"] != nil {
			items.append(Item(label: String(localized: "小字"), value: String(localized: "放大 2 倍再认")))
		}
		if !result.barcodes.isEmpty {
			let count = result.barcodes.count
			items.append(Item(label: String(localized: "二维码"), value: String(localized: "\(count) 个")))
		}
		let suspects = result.lines.filter { $0.suspect != nil }
		let byPlugin = suspects.filter { $0.suspect?.reason == .plugin }.count
		let suspectCount = suspects.count
		items.append(
			Item(
				label: String(localized: "可能认错"),
				value: suspects.isEmpty
					? String(localized: "没有")
					: byPlugin > 0 ? String(localized: "\(suspectCount) 行（判定插件认为的 \(byPlugin) 行）") : String(localized: "\(suspectCount) 行")))
		if let ms = (steps["ms"] as? NSNumber)?.intValue { items.append(Item(label: String(localized: "用时"), value: Self.seconds(ms))) }

		(reviewed, reviewer) = Self.review(steps)
		let reviewLog = (steps["review"] as? [[String: Any]]) ?? []
		plugins = Self.pluginLines(steps: steps, options: options, configured: configured, isPhoto: isPhoto, reviewLog: reviewLog)
	}

	/// 插件复核过的行（第几行 → 认为认错的概率）和复核的插件名：逐行里标「插件看过」用。
	static func review(_ steps: [String: Any]) -> (lines: [Int: Double], name: String) {
		var lines: [Int: Double] = [:]
		for (k, v) in (steps["reviewedLines"] as? [String: Any]) ?? [:] {
			if let i = Int(k), let p = (v as? NSNumber)?.doubleValue { lines[i] = p }
		}
		let log = (steps["review"] as? [[String: Any]]) ?? []
		let name = log.count == 1 ? (log[0]["name"] as? String ?? String(localized: "判定插件")) : String(localized: "判定插件")
		return (lines, name)
	}

	static func modeText(_ result: PageResult, steps: [String: Any], auto: Bool) -> String {
		if result.textLayer { return String(localized: "PDF 自带的文字（没有 OCR）") }
		guard result.mode == .document else { return String(localized: "逐行") }
		guard auto else { return String(localized: "认文档（表格、分栏、竖排）") }
		let signals = (steps["signals"] as? [String: Any]) ?? [:]
		let said = ["table": String(localized: "表格"), "columns": String(localized: "分栏"), "vertical": String(localized: "竖排")].filter {
			((signals[$0.key] as? NSNumber)?.doubleValue ?? 0) >= 0.5
		}
		if !said.isEmpty {
			let found = said.values.sorted().joined(separator: String(localized: "、"))
			return String(localized: "认文档：判定插件看出有\(found)")
		}
		return String(localized: "认文档：版面像分了几栏")
	}

	/// PDF 的页：文字层用没用、为什么（图片不说）。
	static func textLayerText(_ result: PageResult) -> String? {
		guard let layer = result.steps["textLayer"] as? [String: Any] else { return nil }
		if layer["used"] as? Bool == true {
			let pictures = (layer["pictures"] as? NSNumber)?.intValue ?? 0
			return pictures > 0 ? String(localized: "用了；页上 \(pictures) 张图里的字另外认的") : String(localized: "用了")
		}
		switch TextLayerSkip(rawValue: layer["reason"] as? String ?? "") {
		case .noText: return String(localized: "没有（扫描件这类），认的是图上的字")
		case .hiddenOnly: return String(localized: "只有别的软件加的隐形文字层，质量不知道，没用")
		case .doubled: return String(localized: "同样的字有可见、隐形两份（被别的软件 OCR 过），没用")
		case .mostlyImage: return String(localized: "这页以图为主，整页认图")
		case .badCharacters: return String(localized: "有乱码（字体没带编码表），没用")
		case .failedCheck: return String(localized: "抽查一段跟页面上的字对不上，没用")
		case nil: return nil
		}
	}

	/// 这一页按什么语言认的。中文优先时说清楚有没有改回自动判断、为什么。
	static func languageText(steps: [String: Any], options: OCROptions) -> String {
		if let langs = options.languages, !langs.isEmpty {
			let list = langs.joined(separator: String(localized: "、"))
			return String(localized: "指定：\(list)")
		}
		switch steps["languages"] as? String {
		case "chinese": return String(localized: "中文优先：按中文认")
		case "chinese→auto:western": return String(localized: "中文优先：这页几乎没有汉字，改用自动判断")
		case "chinese→auto:unreadable": return String(localized: "中文优先：有中文认不了的字（韩文、日文这类），改用自动判断")
		case "auto:western-before": return String(localized: "中文优先：上一页是西文，这页也按自动判断认")
		case "auto→chinese": return String(localized: "中文优先：上一页是西文，这页汉字不少，改回按中文认")
		default: return String(localized: "自动判断（设置 › 识别 里能改成中文优先）")
		}
	}

	static func pluginLines(
		steps: [String: Any], options: OCROptions, configured: [PluginConfig], isPhoto: Bool, reviewLog: [[String: Any]]
	) -> [PluginLine] {
		guard !configured.isEmpty else { return [PluginLine(text: String(localized: "没配判定插件"))] }
		guard options.usePlugins else {
			return [
				PluginLine(
					text: isPhoto
						? String(localized: "认照片默认不用判定插件（设置 › 识别 › 照片 里能开）") : String(localized: "这次没用判定插件（设置 › 识别 里关了）"))
			]
		}
		var out: [PluginLine] = []
		// 看图：认之前先看一眼图，说有没有表格、分栏、竖排，是不是拍的照片。
		if configured.contains(where: { $0.hooks.contains("route") }) {
			if options.mode != .auto {
				out.append(PluginLine(text: String(localized: "认法不是「自动」，插件不看图")))
			} else {
				for entry in (steps["route"] as? [[String: Any]]) ?? [] {
					let name = entry["name"] as? String ?? String(localized: "判定插件")
					let ms = (entry["ms"] as? NSNumber)?.intValue ?? 0
					if let failed = entry["failed"] as? String {
						out.append(PluginLine(text: String(localized: "\(name) 看图没成：\(failed)，这一步按代码规则处理"), problem: true))
					} else {
						let time = seconds(ms)
						let found = signalText(entry["signals"] as? [String: Any] ?? [:])
						out.append(PluginLine(text: String(localized: "\(name) 看了图（\(time)）：\(found)")))
					}
				}
			}
		}
		// 复核：系统没把握的长行交给插件看是不是认错了。
		if configured.contains(where: { $0.hooks.contains("review") }) {
			if reviewLog.isEmpty {
				if (steps["reviewCandidates"] as? NSNumber)?.intValue == 0 {
					out.append(PluginLine(text: String(localized: "这一页没有系统没把握的长行，用不着插件复核")))
				}
			} else {
				for entry in reviewLog {
					let name = entry["name"] as? String ?? String(localized: "判定插件")
					let ms = (entry["ms"] as? NSNumber)?.intValue ?? 0
					if let failed = entry["failed"] as? String {
						out.append(PluginLine(text: String(localized: "\(name) 复核没成：\(failed)，可能认错的只按系统可信度标"), problem: true))
					} else {
						let n = (entry["reviewed"] as? NSNumber)?.intValue ?? 0
						let flagged = (entry["flagged"] as? NSNumber)?.intValue ?? 0
						let fine = n - flagged
						let time = seconds(ms)
						out.append(PluginLine(text: String(localized: "\(name) 复核了 \(n) 行（\(time)）：\(flagged) 行可能认错，\(fine) 行没问题")))
					}
				}
			}
		}
		return out.isEmpty ? [PluginLine(text: String(localized: "配着的插件这一页用不上"))] : out
	}

	/// 插件看图的结论：过半的才算「看出」。
	static func signalText(_ signals: [String: Any]) -> String {
		let names = [
			"table": String(localized: "表格"), "columns": String(localized: "分栏"), "vertical": String(localized: "竖排"),
			"photo": String(localized: "拍的照片"),
		]
		let yes = names.keys.sorted().filter { ((signals[$0] as? NSNumber)?.doubleValue ?? 0) >= 0.5 }.map { names[$0]! }
		if yes.isEmpty { return String(localized: "没看出表格、分栏、竖排，按普通排版认") }
		let found = yes.joined(separator: String(localized: "、"))
		return String(localized: "看出是\(found)")
	}

	/// 420 毫秒写成「0.4 秒」，太短的写「不到 0.1 秒」。数先照原样格式化成字，再放进要翻的句子：
	/// 直接把 Double 插进 String(localized:) 会写成 0.400000。
	static func seconds(_ ms: Int) -> String {
		if ms < 50 { return String(localized: "不到 0.1 秒") }
		let s = String(format: "%.1f", Double(ms) / 1000)
		return String(localized: "\(s) 秒")
	}
}
