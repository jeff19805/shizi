import Foundation
import OCRCore

/// 命令行和 MCP 工具共用的参数解析：名字、取值、出错说法都只有这一份。
enum ArgumentError: Error, CustomStringConvertible {
	case invalid(String)
	var description: String {
		switch self {
		case .invalid(let m): return m
		}
	}
}

/// "1-3,5" → [1, 2, 3, 5]
func parsePages(_ s: String) throws -> [Int] {
	var out: [Int] = []
	for part in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
		let ends = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
		if ends.count == 1, let a = ends[0], a >= 1 {
			out.append(a)
		} else if ends.count == 2, let a = ends[0], let b = ends[1], a >= 1, b >= a {
			out.append(contentsOf: a...b)
		} else {
			throw ArgumentError.invalid("pages 写法是 \"1-3,5\"，看不懂「\(part)」")
		}
	}
	guard !out.isEmpty else { throw ArgumentError.invalid("pages 是空的") }
	return out
}

func parseRegion(_ values: [Double]) throws -> NRect {
	guard values.count == 4, values.allSatisfy({ $0 >= 0 && $0 <= 1 }), values[2] > 0, values[3] > 0 else {
		throw ArgumentError.invalid("region 要四个 0–1 的数：[左, 上, 宽, 高]（左上角为原点）")
	}
	return NRect(x: values[0], y: values[1], w: values[2], h: values[3])
}

func parseEnum<T: RawRepresentable>(_ raw: String?, _ name: String, default value: T) throws -> T where T.RawValue == String {
	guard let raw else { return value }
	guard let v = T(rawValue: raw) else { throw ArgumentError.invalid("\(name) 不认识「\(raw)」") }
	return v
}

/// languages 参数：空 = 照配置（拾字设置里的「识别语言」）；"auto"（自动）、"chinese-first"（中文优先）= 这次用这种认法；
/// 别的 = 指定语言（中日韩的识别时会排到最前）。
func parseLanguages(_ list: [String]?) -> (languages: [String]?, preference: LanguagePreference?) {
	let items = (list ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	let named: [String: LanguagePreference] = ["auto": .auto, "自动": .auto, "chinese-first": .chineseFirst, "中文优先": .chineseFirst]
	let langs = items.filter { named[$0] == nil }
	if !langs.isEmpty { return (langs, nil) }
	return (nil, items.compactMap { named[$0] }.last)
}
