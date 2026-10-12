import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// 照片分类的规矩：分哪几类（或者一句条件）、多少分算是、长字怎么分段。判定插件只回每道题的概率，这些都在这儿定。
/// 门槛：0.8 才算是；一句条件时 0.2 以下算不符合，中间算待确认。
public struct ClassifyRules: Equatable, Sendable {
	public enum Mode: String, Sendable {
		/// 按主题分：一张可以同时属于几类，哪类都不到门槛就是「待确认」。
		case topics
		/// 按一句条件找：符合、不符合、待确认。
		case condition
	}

	public struct Rule: Equatable, Sendable {
		public var id: String
		public var title: String
		/// 判断标准：插件拿它当「是」的描述。
		public var criteria: String
	}

	/// 看什么：照片认出的字（不发照片），还是照片本身（把缩小的照片发过去）。
	public enum Input: String, Sendable {
		case text, image
	}

	public var mode: Mode
	public var rules: [Rule]
	public var input: Input

	/// 分完的结果里这几个名字有专门的意思，类别不能叫这些。它们算在指纹里、存在照片库里，一直是中文，给人看时才换成界面的语言。
	public static let undecided = "待确认"
	public static let matched = "符合条件"
	public static let unmatched = "不符合条件"

	/// 类别不能叫的名字：上面三个，加上它们在界面上显示的样子。英文界面上「待确认」显示成 Unsure，
	/// 类别也叫 Unsure 的话，筛选条上两个 Unsure 分不清。
	static var reserved: Set<String> {
		let fixed = [undecided, matched, unmatched]
		return Set(fixed + fixed.map { Texts.text(String.LocalizationValue($0)) })
	}

	/// 到这个分算「是」：再低误报多。
	public static let hit = 0.8
	/// 一句条件时到不了这个分算「不符合」，中间的算待确认。
	public static let miss = 0.2
	/// 一段最多这么多字，段与段重叠这么多（不截断，某一段够分就算有）。
	public static let chunkLength = 1600
	public static let chunkOverlap = 100
	/// 改了分段、门槛以外影响结果的东西（题目说法等）时加一，旧的分数就不算数了。
	public static let revision = 1

	/// 按字分的默认类别（6 类）。一行一个，「名称：判断标准」。跟界面语言走，英文在对照表里。
	/// 中文的一个字都别改：用默认类别分好的照片，分数是按这几行字算的指纹存的，改了就得全部重分（测试里钉着它的指纹）。
	public static var defaultTopics: String {
		Texts.text("""
			技术资料：软件开发、计算机、网络、人工智能、技术教程或故障排查
			工作事务：工作安排、会议通知、项目协作、业务沟通或工作流程
			订单票据：商品订单、付款、交易、发票、收据或报销
			生活攻略：旅行、餐饮、购物、家居等生活经验与攻略
			学习知识：课程、读书笔记、知识讲解或学习资料
			合同约定：合同条款、双方义务、付款期限或协议约定
			""")
	}

	/// 类别写得不对：说哪儿不对，给人看。
	public struct Problem: Error, CustomStringConvertible, Equatable {
		public var description: String
		init(_ message: String) { description = message }
	}

	/// 按画面分的默认类别（8 类）。一行一个，「名称：判断标准」。跟按字分的一样：跟界面语言走，中文的一个字都别改。
	public static var defaultImageTopics: String {
		Texts.text("""
			人物：照片中有作为重要内容的真人或人群；不包括文档、屏幕或海报中很小的人像。
			动物：照片以宠物、野生动物、鸟类或其他真实动物为重要内容。
			美食：食物、饮品、菜肴或烹饪是图片的重要内容。
			自然风景：山川、海滩、天空、树林、花草等自然景观是图片的重要内容。
			建筑街景：建筑、城市街景、室内空间或历史古迹是图片的重要内容。
			文档票据：文档、书页、笔记、证件、收据、票据或以阅读文字为目的的资料图片。
			屏幕截图：手机或电脑屏幕截图、应用界面、聊天界面或软件页面；不包括普通相机拍摄的风景。
			物品：以商品、工具、设备、车辆、服饰或其他具体物件为主体的图片。
			""")
	}

	public init(mode: Mode, rules: [Rule], input: Input = .text) {
		self.mode = mode
		self.rules = rules
		self.input = input
	}

	/// 读人写的类别：一行一个「名称：判断标准」，1–8 类；一句条件时整段就是条件（200 字以内）。不对就说哪儿不对。
	public static func parse(mode: Mode, source: String, input: Input = .text) throws -> ClassifyRules {
		var rules = try parse(mode: mode, source: source)
		rules.input = input
		return rules
	}

	static func parse(mode: Mode, source: String) throws -> ClassifyRules {
		let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw Problem(mode == .condition ? Texts.text("先写一句要找什么") : Texts.text("先写几个类别")) }
		if mode == .condition {
			guard text.count <= 200 else { throw Problem(Texts.text("条件写在 200 字以内")) }
			return ClassifyRules(mode: .condition, rules: [Rule(id: "match", title: matched, criteria: text)])
		}
		let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		guard (1...8).contains(lines.count) else { throw Problem(Texts.text("类别写 1 到 8 个，一行一个「名称：判断标准」")) }
		var names = Set<String>()
		var rules: [Rule] = []
		for (i, line) in lines.enumerated() {
			guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
				throw Problem(Texts.text("第 \(i + 1) 行少了冒号，写成「名称：判断标准」"))
			}
			let title = line[..<colon].trimmingCharacters(in: .whitespaces)
			let criteria = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			guard !title.isEmpty, !criteria.isEmpty else { throw Problem(Texts.text("第 \(i + 1) 行的名称或判断标准是空的")) }
			guard title.count <= 20, criteria.count <= 200 else { throw Problem(Texts.text("第 \(i + 1) 行太长：名称最多 20 字，判断标准最多 200 字")) }
			guard !reserved.contains(title) else { throw Problem(Texts.text("「\(title)」是留着的名字，换一个")) }
			guard names.insert(title).inserted else { throw Problem(Texts.text("「\(title)」写了两次")) }
			rules.append(Rule(id: "t\(i)", title: title, criteria: criteria))
		}
		return ClassifyRules(mode: .topics, rules: rules)
	}

	/// 这套规矩的指纹：类别、判断标准、说法有一样变了，指纹就变，存着的分数不再算数。
	public var fingerprint: String {
		// 按字分的指纹照旧（不带「看什么」），早先按字分好的分数还算数；按画面分的另带一个 image，跟按字分的分开记。
		let input = self.input == .image ? ["image"] : []
		let body = ([String(Self.revision), mode.rawValue] + input + rules.flatMap { [$0.id, $0.title, $0.criteria] }).joined(separator: "\u{1F}")
		return digest(body)
	}

	/// 分数换成结果：主题是过门槛的那几类（都不到是「待确认」）；条件是符合、不符合、待确认。
	public func labels(_ scores: [String: Double]) -> [String] {
		if mode == .condition {
			let p = scores["match"] ?? 0.5
			return [p >= Self.hit ? Self.matched : p < Self.miss ? Self.unmatched : Self.undecided]
		}
		let hits = rules.filter { (scores[$0.id] ?? 0) >= Self.hit }.map(\.title)
		return hits.isEmpty ? [Self.undecided] : hits
	}

	/// 长字分段：每段最多 1600 字、跟上一段重叠 100 字，不截掉任何字。
	public static func chunks(_ text: String) -> [String] {
		let chars = Array(text)
		guard !chars.isEmpty else { return [] }
		var parts: [String] = []
		var start = 0
		while start < chars.count {
			let end = min(start + chunkLength, chars.count)
			parts.append(String(chars[start..<end]))
			if end == chars.count { break }
			start = end - chunkOverlap
		}
		return parts
	}
}

/// 一段字的指纹：照片的字变了（重认过），分数就得重问。
public func digest(_ text: String) -> String {
	SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum Classifier {
	/// 按字分一张：长字分段，每段把全部题一起问插件，每道题取各段里最高的分（某一段说得上就算有）。
	/// 有一段问不成就整张算没分成，下次再问：缺一段的分数会把「有」说成「没有」。
	public static func classify(text: String, rules: ClassifyRules, host: PluginHost, plugin: PluginConfig) -> Result<[String: Double], PluginFailure> {
		var scores: [String: Double] = [:]
		for chunk in ClassifyRules.chunks(text) {
			switch ask(["questions": questions(rules), "text": chunk], rules: rules, host: host, plugin: plugin) {
			case .success(let got):
				for (id, p) in got { scores[id] = max(scores[id] ?? 0, p) }
			case .failure(let f):
				return .failure(f)
			}
		}
		return .success(scores)
	}

	/// 按画面分一张：缩到长边 `longSide`、存成 JPEG（质量 0.82），连同全部题一起问一次。
	public static func classify(image: CGImage, longSide: Int, rules: ClassifyRules, host: PluginHost, plugin: PluginConfig)
		-> Result<[String: Double], PluginFailure>
	{
		let small = downscaledQuickly(image, longSide: longSide)
		guard let jpeg = jpegData(small, quality: 0.82) else { return .failure(PluginFailure(plugin: plugin.name, message: Texts.text("照片存不成 JPEG"))) }
		let image: [String: Any] = ["data": jpeg.base64EncodedString(), "type": "jpeg", "width": small.width, "height": small.height]
		return ask(["questions": questions(rules), "image": image], rules: rules, host: host, plugin: plugin)
	}

	static func questions(_ rules: ClassifyRules) -> [[String: String]] {
		rules.rules.map { ["id": $0.id, "criteria": $0.criteria] }
	}

	/// 问一次插件，收齐每道题的分；缺一题就算没分成（缺的那题会被当成「不是」）。
	static func ask(_ input: [String: Any], rules: ClassifyRules, host: PluginHost, plugin: PluginConfig) -> Result<[String: Double], PluginFailure> {
		host.call(plugin, hook: "classify", input: input).flatMap { out in
			let got = (out["scores"] as? [String: Any]) ?? [:]
			var scores: [String: Double] = [:]
			for rule in rules.rules {
				guard let p = (got[rule.id] as? NSNumber)?.doubleValue, p.isFinite, (0...1).contains(p) else {
					// 按一句条件找时，题目的名字是固定标签（符合条件……），它们要留着中文算指纹，给人看时换成界面的语言；用户写的类别名查不到，原样出。
					let title = Texts.text(String.LocalizationValue(rule.title))
					return .failure(PluginFailure(plugin: plugin.name, message: Texts.text("回的分数里缺了「\(title)」")))
				}
				scores[rule.id] = p
			}
			return .success(scores)
		}
	}

	static func jpegData(_ image: CGImage, quality: Double) -> Data? {
		let data = NSMutableData()
		guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		return CGImageDestinationFinalize(dest) ? data as Data : nil
	}
}
