import CoreGraphics
import Foundation

/// 没指定语言时怎么认。
///
/// 不指定语言时，系统一行一行地判断用哪种语言的模型：字母、数字多的行用西文模型，行里的汉字成了乱码
/// （扫描件上夹着算式的中文行，汉字认成一串乱码字母；截图里数字后面的「秒」也会认成字母），
/// 短的中文常被当成日文（「出错」认成「出錯」、「转帖」认成「装帖」）。英文哪个模型都认得，所以看着对英文特别灵。
/// 先按中文认能修好这些，代价见 `chineseFirstPass`。
public enum LanguagePreference: String, Sendable, CaseIterable {
	/// 系统自己一行一行判断（原来的做法，默认）。
	case auto
	/// 先按中文认；整页几乎没有汉字，或者有中文认不了的字（韩文、日文这类），改回自动判断。
	case chineseFirst = "chinese-first"
}

/// 中文优先时第一遍用的语言。系统只用列表里第一个语言的模型（英文排在前面时汉字全错），
/// 中文放在最前面，英文、数字照样认得出。
public let chineseFirstLanguages = ["zh-Hans", "en-US"]

/// 一份文件（或一批照片）一页页认下来要记住的东西：
/// - 中文优先时上一页是不是西文：是的话这一页先按自动判断认，省掉白认的一遍中文（中文模型认西文页反而慢，
///   西文 PDF 每页都先认一遍中文的话慢得多）。只决定先试哪个，不替代判断：认完照样看汉字多少，不对就换回来。
/// - PDF 文字层抽查过没有、对不对得上（见 TextLayer.swift）：一份文件只抽查一次。
/// - 文字层页上图片区认出来的字：每页页眉都是同一张标志图时只认一次。
public final class RunMemory: @unchecked Sendable {
	private let lock = NSLock()
	private var autoFirst = false
	private var goodFonts = Set<Int>()
	private var badFonts = Set<Int>()
	private var images: [String: [OCRLine]] = [:]

	public init() {}

	/// 这一页先按自动判断认。
	var startWithAuto: Bool {
		get { lock.withLock { autoFirst } }
		set { lock.withLock { autoFirst = newValue } }
	}

	/// 文字层这一页用的字体都抽查过、对得上（没用字体的页不算）。
	func fontsVerified(_ fonts: Set<Int>) -> Bool { lock.withLock { !fonts.isEmpty && fonts.isSubset(of: goodFonts) } }

	/// 这一页用了抽查对不上的字体（字体编码错位，换一页也一样错）。
	func usesBadFont(_ fonts: Set<Int>) -> Bool { lock.withLock { !fonts.isDisjoint(with: badFonts) } }

	/// 记下抽查结果：对得上，这页的字体都算查过；对不上，还没查过的字体算坏的。
	/// `blameFonts` = false：这页是因为有白字才查的，对不上多半是垫的一层假字，不怪字体。
	func recordCheck(fonts: Set<Int>, agrees: Bool, blameFonts: Bool) {
		lock.withLock {
			if agrees {
				goodFonts.formUnion(fonts)
			} else if blameFonts {
				badFonts.formUnion(fonts.subtracting(goodFonts))
			}
		}
	}

	/// 图片区认出来的行（按图片对象和它在页上的位置记）。
	func imageLines(_ key: String) -> [OCRLine]? { lock.withLock { images[key] } }
	func setImageLines(_ key: String, _ lines: [OCRLine]) { lock.withLock { images[key] = lines } }
}

/// 指定的语言里，中日韩的排到最前（相对顺序不变）：系统只用第一个语言的模型，英文放前面时汉字全认错。
public func cjkFirst(_ languages: [String]) -> [String] {
	let isCJK = { (l: String) in ["zh", "ja", "ko", "yue"].contains(where: { l.lowercased().hasPrefix($0) }) }
	return languages.filter(isCJK) + languages.filter { !isCJK($0) }
}

/// 一页认出的字里，汉字、假名各有多少，字母数字汉字一共多少（标点空格不算）。
struct ScriptCounts {
	var han = 0
	var kana = 0
	var alphanumerics = 0

	init(_ lines: [OCRLine]) {
		for l in lines {
			for u in l.text.unicodeScalars {
				switch u.value {
				case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: han += 1
				case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
				default: break
				}
				if CharacterSet.alphanumerics.contains(u) { alphanumerics += 1 }
			}
		}
	}

	/// 西文页：汉字不到字母数字汉字的 1%。字太少（不到 20 个）不下结论。
	/// 1%：西文页按中文认，只冒出零星几个汉字，远不到 1%；中文扫描件、截图里的汉字要多得多。
	var looksWestern: Bool { alphanumerics >= 20 && han * 100 < alphanumerics }

	/// 先按自动判断认的页（上一页是西文），汉字多到可以改回中文：至少 2 个、到 1%，而且不是日文（假名不到一成半）。
	var chineseEnough: Bool { han >= 2 && han * 100 >= alphanumerics && kana * 20 < (han + kana) * 3 }

	/// 日文页：假名占汉字假名的一成半以上。日文页里也有汉字，按中文重认只会白认一遍（中文模型认不出假名，一整行日文常常什么都不出）。
	var looksJapanese: Bool { kana >= 2 && kana * 20 >= (han + kana) * 3 }
}

/// 系统「找字的位置」找到的字块，有多大比例（按面积）被认出的行盖住。
func coverage(of blocks: [NRect], by lines: [OCRLine]) -> Double {
	let total = blocks.reduce(0) { $0 + $1.area }
	guard total > 0 else { return 1 }
	let covered = blocks.reduce(0) { sum, b in sum + min(b.area, lines.reduce(0) { $0 + $1.box.overlapArea(b) }) }
	return covered / total
}

/// 中文那一遍是不是碰上了中文认不了的字（韩文、日文这类）：找到的字块盖住不到一半，而且认出的汉字不到字块数的两倍。
/// 光看盖住多少不够：卡通插画、大图里第一遍认不清的小字也会被当成字块，插画多的设计图、截图盖住的常常不到一半，
/// 可认出的汉字比字块多好几倍，中文是认出来了的；韩文、日文按中文认一个字都不出（一块也盖不住、一个汉字也没有）。
/// 中文扫描件、手机截图大多盖得住。判错了也只是退回原来的自动判断（慢一遍），漏判（韩文页按中文认）才会丢字。
func chineseLooksUnreadable(coverage: Double, han: Int, textBlocks: Int) -> Bool {
	coverage < 0.5 && han < 2 * textBlocks
}

/// 中文模型会把英文、代码里的标点认成全角（比如 `add(a, b);` 认成 `add（a,b）；`，`"format": 1,` 认成 `"format"： 1，`）。
/// 改回半角的只有英文语境里的。没有汉字的行：
/// - 逗号、冒号这类：左右最近的非空白字都是英文（ASCII、别的全角标点，或者是行首行尾）就改。
/// - 括号成对看（用栈配，套着的也配得上）：里面没有汉字、左边最近的非空白字是英文（或行首），一对一起改
///   （`add（a,b）` → `add(a,b)`，`foo（bar（x））` → `foo(bar(x))`）。配不成对的括号按逗号那样看（代码里单独一行的 `｝`）。
/// 有汉字的行要严得多：左右都得挨着真的 ASCII 字，行首行尾不算；括号还要右边挨着 ASCII。
/// 不然中文句子里夹个英文词就被改：「请使用 API！」「推荐 Mac（Intel）版本」都会被改成半角。
/// 「2019年，」「日期 ：2019」「说明（1）」「（ps5独占）」都不动；数字中间的「134，28」照样改。
/// 连着几个全角标点时一个个看，前面改过的算 ASCII（`）；` 两个都改）。
public func halfWidthPunctuationInLatin(_ s: String) -> String {
	let marks: [Character: Character] = ["，": ",", "：": ":", "；": ";", "！": "!", "？": "?"]
	let brackets: [Character: Character] = ["（": "(", "）": ")", "［": "[", "］": "]", "｛": "{", "｝": "}"]
	let closing: [Character: Character] = ["（": "）", "［": "］", "｛": "｝"]
	var chars = Array(s)
	guard chars.contains(where: { marks[$0] != nil || brackets[$0] != nil }) else { return s }
	func isHan(_ c: Character) -> Bool {
		c.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
	}
	let chineseLine = chars.contains(where: isHan)
	/// 往左（`step` = -1）或往右找最近的非空白字；找不到（到了行首行尾）算 nil。
	func neighbor(_ i: Int, _ step: Int) -> Character? {
		var j = i + step
		while j >= 0 && j < chars.count {
			if !chars[j].isWhitespace { return chars[j] }
			j += step
		}
		return nil
	}
	func latin(_ c: Character?) -> Bool {
		guard let c else { return !chineseLine }
		return c.isASCII || (!chineseLine && (marks[c] != nil || brackets[c] != nil))
	}
	// 括号先成对改：用栈配，配上的从里到外都按自己的左右邻居看。
	var paired = Set<Int>()
	var open: [Int] = []
	var pairs: [(Int, Int)] = []
	for i in chars.indices {
		if closing[chars[i]] != nil {
			open.append(i)
		} else if brackets[chars[i]] != nil, let k = open.last, closing[chars[k]] == chars[i] {
			open.removeLast()
			pairs.append((k, i))
		}
	}
	for (i, j) in pairs.sorted(by: { $0.0 < $1.0 }) {
		paired.insert(i)
		paired.insert(j)
		guard !chars[(i + 1)..<j].contains(where: isHan), latin(neighbor(i, -1)) else { continue }
		if chineseLine, !latin(neighbor(j, 1)) { continue }
		chars[i] = brackets[chars[i]]!
		chars[j] = brackets[chars[j]]!
	}
	for i in chars.indices where !paired.contains(i) {
		guard let half = marks[chars[i]] ?? brackets[chars[i]] else { continue }
		if latin(neighbor(i, -1)) && latin(neighbor(i, 1)) { chars[i] = half }
	}
	return String(chars)
}

/// 中文模型偶尔把同一段字认出两遍：一行长的，外加它里头的一截（整行认出来了，开头几个字又单独多出一行）。
/// 框大半（六成以上）落在另一行里、字也是那一行的一部分，就去掉这一截。
/// 框要在「字是正的」坐标系里比（`width`、`height` 是图的像素尺寸）：斜着的页外接框很胖，两行明明分开，外接框也能叠在一起，
/// 会把真正重复的值删掉（比如斜着的页上一行「合计100」，和它下面单独一行的「100」）。
func droppingContainedDuplicates(_ lines: [OCRLine], width: Int, height: Int) -> [OCRLine] {
	let compact = lines.map { String($0.text.filter { !$0.isWhitespace }) }
	let boxes = uprightBoxes(lines, width: width, height: height)
	func inside(_ i: Int, _ j: Int) -> Double {
		let a = boxes[i], b = boxes[j]
		let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x), h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
		return a.w * a.h > 0 && w > 0 && h > 0 ? w * h / (a.w * a.h) : 0
	}
	return lines.indices.filter { i in
		!lines.indices.contains { j in
			j != i && compact[j].count > compact[i].count && !compact[i].isEmpty && compact[j].contains(compact[i]) && inside(i, j) > 0.6
		}
	}.map { lines[$0] }
}

extension OCRLine {
	func halfWidthPunctuation() -> OCRLine {
		var l = self
		l.text = halfWidthPunctuationInLatin(text)
		return l
	}
}

extension DocResult {
	/// 认文档按中文认出的字也一样改标点：没换成逐行结果的格子、段落用的是它自己的字。
	func halfWidthPunctuation() -> DocResult {
		var d = self
		d.lines = lines.map { $0.halfWidthPunctuation() }
		d.paragraphs = paragraphs.map { p in
			var p = p
			p.text = halfWidthPunctuationInLatin(p.text)
			return p
		}
		d.tables = tables.map { t in
			var t = t
			t.cells = t.cells.map { c in
				var c = c
				c.text = halfWidthPunctuationInLatin(c.text)
				return c
			}
			return t
		}
		return d
	}
}

/// 中文优先的第一遍怎么认出来的（写进 steps["languages"]，识别详情照着说）。
enum LanguagePass: String {
	/// 按中文认。
	case chinese
	/// 先按中文认，这页几乎没有汉字（西文页），改回自动判断。
	case chineseThenAutoWestern = "chinese→auto:western"
	/// 先按中文认，有一半以上的字块没认出来（韩文、日文这类），改回自动判断。
	case chineseThenAutoUnreadable = "chinese→auto:unreadable"
	/// 上一页是西文，这页先按自动判断认，还是西文（或者按中文认反而更差）。
	case autoAfterWestern = "auto:western-before"
	/// 上一页是西文，这页先按自动判断认，汉字不少，改回按中文认。
	case autoThenChinese = "auto→chinese"
}

/// 中文优先的第一遍：先按中文认（同时找出哪里有字），西文页、中文认不了的页改回自动判断；上一页是西文时先按自动判断认。
/// 返回这一页的行、后面各步（拉正后重认、切块、放大、认文档）要接着用的语言，和怎么定下来的。
///
/// 代价：中文页反而稍快（省了逐行判断语言）；西文页要认两遍，所以 PDF 记住上一页的结论；
/// 中文模型认英文有小毛病（撇号后少空格、Ive 认成 lve、® 认成 @），所以只在用户选了「中文优先」时这样认。
func chineseFirstPass(_ image: CGImage, correction: Bool, memory: RunMemory?) throws
	-> (lines: [OCRLine], options: LineOptions, pass: LanguagePass, check: [String: Any])
{
	let chinese = LineOptions(languages: chineseFirstLanguages, correction: correction)
	let auto = LineOptions(languages: nil, correction: correction)
	var check: [String: Any] = [:]
	func tryChinese() throws -> (lines: [OCRLine], western: Bool, unreadable: Bool) {
		let r = try recognizeLinesFindingText(image, options: chinese)
		let lines = r.lines.map { $0.halfWidthPunctuation() }
		let counts = ScriptCounts(lines)
		let cover = coverage(of: r.textBlocks, by: lines)
		check["han"] = counts.han
		check["alphanumerics"] = counts.alphanumerics
		check["coverage"] = (cover * 100).rounded() / 100
		check["textBlocks"] = r.textBlocks.count
		return (lines, counts.looksWestern, chineseLooksUnreadable(coverage: cover, han: counts.han, textBlocks: r.textBlocks.count))
	}
	if memory?.startWithAuto == true {
		let a = try recognizeLines(image, options: auto)[0]
		let counts = ScriptCounts(a)
		// 这一页自己就是一大片西文（或者是日文）：不用再按中文试（西文 PDF 每页都试的话每页要多认一遍）。字少的页、有汉字的页都再按中文试一遍。
		if counts.looksWestern || counts.looksJapanese { return (a, auto, .autoAfterWestern, check) }
		let z = try tryChinese()
		// 改回中文：自动判断认出的汉字够多，或者按中文认出的汉字比自动判断多。不能只看前一条：汉字被认成了字母
		// （「计100」认成「it100」）就一个汉字也没有，永远换不回中文。零星一个汉字的英文页两边认出的一样多，不改。
		// 按中文认反而不行（其实是西文，或者中文认不了）也不改：留自动判断的结果，下一页也先按自动判断认。
		guard !z.western, !z.unreadable, counts.chineseEnough || ScriptCounts(z.lines).han > counts.han else {
			return (a, auto, .autoAfterWestern, check)
		}
		memory?.startWithAuto = false
		return (z.lines, chinese, .autoThenChinese, check)
	}
	let z = try tryChinese()
	if z.western || z.unreadable {
		memory?.startWithAuto = true
		let a = try recognizeLines(image, options: auto)[0]
		return (a, auto, z.western ? .chineseThenAutoWestern : .chineseThenAutoUnreadable, check)
	}
	return (z.lines, chinese, .chinese, check)
}
