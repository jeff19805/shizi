import CoreGraphics
import Foundation
import PDFKit

// PDF 自带的文字层：数字 PDF（Word、浏览器导出的）里本来就有字，直接用，一字不差，还比认图快得多。
// 文字层不能拿来就用：扫描件常被扫描仪或 Acrobat 加过一层隐形的 OCR 字（PDFKit 照样当文字给出来，质量不知道，中文常常很差）；
// 数字 PDF 也可能又被人跑过一遍 OCR，字会重复一份。所以每页先看画了什么（scanInk），再决定用不用（textLayerSkip）。

// MARK: 这一页画了什么

/// 一页 PDF 上画了什么：可见的字画了几次、隐形的字（文字模式 3、7）画了几次、图片在哪。
/// 只数不解码字：CGPDFScanner 扫一遍内容流（含表单 XObject），很快。
struct PageInk {
	var visibleText = 0
	var hiddenText = 0
	/// 图片在页面上的外接框（PDF 页面坐标、左下原点，照坐标变换算）和认得出同一张图的记号（同一个图片对象）。
	var images: [(rect: CGRect, key: String)] = []
	/// 用到的字体（字体对象的记号）各画了几次字：拼起来的 PDF 每段字体不一样，没抽查过的字体要再抽查（见 RunMemory）。
	var fonts: [Int: Int] = [:]
	/// 画字占这页一成以上的字体。只画了几个字的（项目符号、特殊符号的字体）坏了影响也小，不为它单查一次：
	/// 不然这种字体在哪页第一次出现，哪页就得多查一次，一份文件下来白白多花不少时间。
	var mainFonts: Set<Int> {
		let total = fonts.values.reduce(0, +)
		return Set(fonts.filter { $0.value * 10 >= total }.keys)
	}
	/// 用白色填的字画在哪（PDF 页面坐标，每次画字的头一个字那么大的一块）。白底上的白字看不见，可能是别人垫的一层字；
	/// 红底白字这种又是正常的（表格的表头常这样画），所以不当隐形字，渲染出来看底色，白底上的才抽查（见 runPage）。
	var whiteText: [CGRect] = []
}

/// 扫内容流时的状态：坐标变换、文字模式、填充色是不是白色、填充色有几个分量（0 = 不知道），跟着 q / Q 存取。
/// 画字的位置：文字矩阵、行矩阵、行距、字号（只为找白字画在哪，字宽不算，同一行接着画的几段当成从行首画）。
private final class InkScan {
	var ctm = CGAffineTransform.identity
	var renderMode = 0
	var fillWhite = false
	var fillComponents = 1
	var saved: [(CGAffineTransform, Int, Bool, Int)] = []
	var textMatrix = CGAffineTransform.identity
	var lineMatrix = CGAffineTransform.identity
	var leading: CGFloat = 0
	var fontSize: CGFloat = 0
	var font: Int?
	var ink = PageInk()
	var resources: [CGPDFDictionaryRef?] = []
	var streams: [CGPDFContentStreamRef] = []
	var depth = 0
}

private func scanState(_ info: UnsafeMutableRawPointer?) -> InkScan {
	Unmanaged<InkScan>.fromOpaque(info!).takeUnretainedValue()
}

private func countText(_ info: UnsafeMutableRawPointer?) {
	let s = scanState(info)
	if let f = s.font { s.ink.fonts[f, default: 0] += 1 }
	if s.renderMode == 3 || s.renderMode == 7 {
		s.ink.hiddenText += 1
	} else {
		s.ink.visibleText += 1
		if s.fillWhite && (s.renderMode == 0 || s.renderMode == 4) {
			// 头一个字那块：从文字的原点往右一个字号、往上七成字号，换到页面坐标。
			let m = s.textMatrix.concatenating(s.ctm)
			let box = CGRect(x: 0, y: 0, width: s.fontSize, height: 0.7 * s.fontSize).applying(m)
			if box.width > 0, box.height > 0 { s.ink.whiteText.append(box) }
		}
	}
}

/// Td、TD：行矩阵挪 (x, y)；TD 顺便把行距设成 -y。
private func moveLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, setLeading: Bool) {
	var x: CGPDFReal = 0, y: CGPDFReal = 0
	guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
	let s = scanState(info)
	if setLeading { s.leading = -y }
	s.lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(s.lineMatrix)
	s.textMatrix = s.lineMatrix
}

/// 换到下一行（T*、'、"）：行矩阵往下挪一个行距。
private func nextLine(_ s: InkScan) {
	s.lineMatrix = CGAffineTransform(translationX: 0, y: -s.leading).concatenating(s.lineMatrix)
	s.textMatrix = s.lineMatrix
}

/// 弹出 `count` 个颜色分量（灰、RGB、CMYK 各 1、3、4 个），看是不是白色。分量数不对的一律不算白、也不弹：
/// 操作数栈弹空了 CoreGraphics 会记一条「stack underflow」的错。
private func popFillIsWhite(_ scanner: CGPDFScannerRef, count: Int) -> Bool {
	guard [1, 3, 4].contains(count) else { return false }
	var values: [CGPDFReal] = []
	var v: CGPDFReal = 0
	for _ in 0..<count {
		guard CGPDFScannerPopNumber(scanner, &v) else { return false }
		values.append(v)
	}
	return count == 4 ? values.allSatisfy { $0 <= 0.03 } : values.allSatisfy { $0 >= 0.97 }
}

/// 色彩空间有几个颜色分量：设备灰、RGB、CMYK，资源里的 ICC 照它写的 N；图案、索引色、专色这些算 0（不管是不是白）。
private func colorComponents(_ name: String, resources: CGPDFDictionaryRef?) -> Int {
	switch name {
	case "DeviceGray", "G", "CalGray": return 1
	case "DeviceRGB", "RGB", "CalRGB": return 3
	case "DeviceCMYK", "CMYK": return 4
	default: break
	}
	var spaces: CGPDFDictionaryRef?
	guard let resources, CGPDFDictionaryGetDictionary(resources, "ColorSpace", &spaces), let spaces else { return 0 }
	var alias: UnsafePointer<CChar>?
	if CGPDFDictionaryGetName(spaces, name, &alias), let alias { return colorComponents(String(cString: alias), resources: nil) }
	var array: CGPDFArrayRef?
	var family: UnsafePointer<CChar>?
	guard CGPDFDictionaryGetArray(spaces, name, &array), let array, CGPDFArrayGetName(array, 0, &family), let family else { return 0 }
	switch String(cString: family) {
	case "CalGray": return 1
	case "CalRGB": return 3
	case "ICCBased":
		var stream: CGPDFStreamRef?
		var n: CGPDFInteger = 0
		guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
			CGPDFDictionaryGetInteger(dict, "N", &n)
		else { return 0 }
		return n
	default: return 0
	}
}

private func inkOperators() -> CGPDFOperatorTableRef {
	let t = CGPDFOperatorTableCreate()!
	CGPDFOperatorTableSetCallback(t, "q") { _, info in
		let s = scanState(info)
		s.saved.append((s.ctm, s.renderMode, s.fillWhite, s.fillComponents))
	}
	CGPDFOperatorTableSetCallback(t, "Q") { _, info in
		let s = scanState(info)
		if let (ctm, mode, white, components) = s.saved.popLast() {
			s.ctm = ctm
			s.renderMode = mode
			s.fillWhite = white
			s.fillComponents = components
		}
	}
	// g、rg、k 连色彩空间一起设；sc、scn 照当前色彩空间的分量数。
	CGPDFOperatorTableSetCallback(t, "g") { scanner, info in
		let s = scanState(info)
		(s.fillWhite, s.fillComponents) = (popFillIsWhite(scanner, count: 1), 1)
	}
	CGPDFOperatorTableSetCallback(t, "rg") { scanner, info in
		let s = scanState(info)
		(s.fillWhite, s.fillComponents) = (popFillIsWhite(scanner, count: 3), 3)
	}
	CGPDFOperatorTableSetCallback(t, "k") { scanner, info in
		let s = scanState(info)
		(s.fillWhite, s.fillComponents) = (popFillIsWhite(scanner, count: 4), 4)
	}
	for op in ["sc", "scn"] {
		CGPDFOperatorTableSetCallback(t, op) { scanner, info in
			let s = scanState(info)
			s.fillWhite = popFillIsWhite(scanner, count: s.fillComponents)
		}
	}
	// 换色彩空间时颜色回到初始的黑色。
	CGPDFOperatorTableSetCallback(t, "cs") { scanner, info in
		let s = scanState(info)
		var name: UnsafePointer<CChar>?
		s.fillWhite = false
		s.fillComponents = CGPDFScannerPopName(scanner, &name) && name != nil ? colorComponents(String(cString: name!), resources: s.resources.last ?? nil) : 0
	}
	CGPDFOperatorTableSetCallback(t, "Tf") { scanner, info in
		let s = scanState(info)
		var size: CGPDFReal = 0
		var name: UnsafePointer<CChar>?
		guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
		s.fontSize = size
		guard let res = s.resources.last ?? nil else {
			s.font = nil
			return
		}
		var fonts: CGPDFDictionaryRef?
		var font: CGPDFDictionaryRef?
		guard CGPDFDictionaryGetDictionary(res, "Font", &fonts), let fonts, CGPDFDictionaryGetDictionary(fonts, name, &font), let font else {
			s.font = nil
			return
		}
		s.font = unsafeBitCast(font, to: Int.self)
	}
	CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
		var v = [CGPDFReal](repeating: 0, count: 6)
		for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
		let s = scanState(info)
		s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
	}
	CGPDFOperatorTableSetCallback(t, "Tr") { scanner, info in
		var mode: CGPDFInteger = 0
		if CGPDFScannerPopInteger(scanner, &mode) { scanState(info).renderMode = mode }
	}
	CGPDFOperatorTableSetCallback(t, "Tj") { _, info in countText(info) }
	CGPDFOperatorTableSetCallback(t, "TJ") { _, info in countText(info) }
	CGPDFOperatorTableSetCallback(t, "'") { _, info in
		nextLine(scanState(info))
		countText(info)
	}
	CGPDFOperatorTableSetCallback(t, "\"") { _, info in
		nextLine(scanState(info))
		countText(info)
	}
	CGPDFOperatorTableSetCallback(t, "BT") { _, info in
		let s = scanState(info)
		(s.textMatrix, s.lineMatrix) = (.identity, .identity)
	}
	CGPDFOperatorTableSetCallback(t, "Tm") { scanner, info in
		var v = [CGPDFReal](repeating: 0, count: 6)
		for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
		let s = scanState(info)
		s.textMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
		s.lineMatrix = s.textMatrix
	}
	CGPDFOperatorTableSetCallback(t, "Td") { scanner, info in moveLine(scanner, info, setLeading: false) }
	CGPDFOperatorTableSetCallback(t, "TD") { scanner, info in moveLine(scanner, info, setLeading: true) }
	CGPDFOperatorTableSetCallback(t, "T*") { _, info in nextLine(scanState(info)) }
	CGPDFOperatorTableSetCallback(t, "TL") { scanner, info in
		var v: CGPDFReal = 0
		if CGPDFScannerPopNumber(scanner, &v) { scanState(info).leading = v }
	}
	CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
		let s = scanState(info)
		var name: UnsafePointer<CChar>?
		guard CGPDFScannerPopName(scanner, &name), let name, let res = s.resources.last ?? nil else { return }
		var objects: CGPDFDictionaryRef?
		var stream: CGPDFStreamRef?
		guard CGPDFDictionaryGetDictionary(res, "XObject", &objects), let objects, CGPDFDictionaryGetStream(objects, name, &stream), let stream,
			let dict = CGPDFStreamGetDictionary(stream)
		else { return }
		var subtype: UnsafePointer<CChar>?
		guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
		switch String(cString: subtype) {
		case "Image":
			s.ink.images.append((CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm), "\(unsafeBitCast(stream, to: Int.self))"))
		case "Form" where s.depth < 8:
			// 表单 XObject：带着它自己的 Matrix 和资源接着往里扫。
			var matrix = CGAffineTransform.identity
			var m: CGPDFArrayRef?
			if CGPDFDictionaryGetArray(dict, "Matrix", &m), let m, CGPDFArrayGetCount(m) == 6 {
				var v = [CGPDFReal](repeating: 0, count: 6)
				for i in 0..<6 { _ = CGPDFArrayGetNumber(m, i, &v[i]) }
				matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
			}
			var formResources: CGPDFDictionaryRef?
			_ = CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
			guard let parent = s.streams.last else { return }
			let saved = (s.ctm, s.renderMode, s.fillWhite, s.fillComponents)
			s.ctm = matrix.concatenating(s.ctm)
			s.depth += 1
			s.resources.append(formResources ?? res)
			let content = CGPDFContentStreamCreateWithStream(stream, formResources ?? res, parent)
			s.streams.append(content)
			CGPDFScannerScan(CGPDFScannerCreate(content, inkOperators(), info))
			s.streams.removeLast()
			s.resources.removeLast()
			s.depth -= 1
			(s.ctm, s.renderMode, s.fillWhite, s.fillComponents) = saved
		default:
			break
		}
	}
	return t
}

func scanInk(_ page: CGPDFPage) -> PageInk {
	let s = InkScan()
	s.resources = [pageResources(page)]
	let content = CGPDFContentStreamCreateWithPage(page)
	s.streams = [content]
	let info = Unmanaged.passUnretained(s).toOpaque()
	CGPDFScannerScan(CGPDFScannerCreate(content, inkOperators(), info))
	return s.ink
}

/// 页面的资源（图片、表单、字体在哪）。页面自己没写的从上级页面树继承（PDF 规范允许）：不往上找的话，
/// 资源放在上级的 PDF 里一张图也看不见，扫描页被当成数字页、正文整片丢掉（只剩文字层里的页眉）。
func pageResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
	var node = page.dictionary
	for _ in 0..<32 {
		guard let d = node else { return nil }
		var resources: CGPDFDictionaryRef?
		if CGPDFDictionaryGetDictionary(d, "Resources", &resources), let resources { return resources }
		var parent: CGPDFDictionaryRef?
		guard CGPDFDictionaryGetDictionary(d, "Parent", &parent) else { return nil }
		node = parent
	}
	return nil
}

/// 图片盖住页面（裁剪框）多大比例：外接框铺到 60 × 80 的格子上求并集，几张叠着的不重复算。
func imageCoverage(_ rects: [CGRect], in box: CGRect) -> Double {
	guard box.width > 0, box.height > 0 else { return 0 }
	let gx = 60, gy = 80
	var grid = [Bool](repeating: false, count: gx * gy)
	for r in rects {
		let x0 = max(0, Int(((r.minX - box.minX) / box.width * CGFloat(gx)).rounded(.down)))
		let x1 = min(gx, Int(((r.maxX - box.minX) / box.width * CGFloat(gx)).rounded(.up)))
		let y0 = max(0, Int(((r.minY - box.minY) / box.height * CGFloat(gy)).rounded(.down)))
		let y1 = min(gy, Int(((r.maxY - box.minY) / box.height * CGFloat(gy)).rounded(.up)))
		guard x0 < x1, y0 < y1 else { continue }
		for y in y0..<y1 { for x in x0..<x1 { grid[y * gx + x] = true } }
	}
	return Double(grid.filter { $0 }.count) / Double(gx * gy)
}

// MARK: 用不用

/// 文字层没用上的原因（写进 steps["textLayer"]["reason"]，识别详情照着说）。
public enum TextLayerSkip: String, Sendable {
	/// 没有画字：扫描件、矢量图。最常见，不用另外说明。
	case noText = "no-text"
	/// 只有隐形的字：扫描件上别的软件做的 OCR 层，质量不知道。
	case hiddenOnly = "hidden-text"
	/// 可见的字上又叠了一层隐形的字（隐形的至少有可见的一半）：数字 PDF 又被人跑过一遍 OCR，取出来字会重复一份。
	case doubled
	/// 图片盖住一半以上：以图为主（流程图、扫描件上加了页眉页码），整页认图更稳。
	case mostlyImage = "mostly-image"
	/// 文字层里乱码多（字体没带编码表时取出来是乱码）。
	case badCharacters = "bad-characters"
	/// 抽查一段跟图上的字对不上（字体编码错位这类，乱码比例看不出来）。
	case failedCheck = "failed-check"

	/// 结果里的说明：常见的（扫描件、以图为主）不说，免得每页一句；少见的说一句，好知道为什么没用 PDF 里的字。
	var note: String? {
		switch self {
		case .noText, .mostlyImage: return nil
		case .hiddenOnly: return "这一页有别的软件加的隐形文字层（扫描件常见），质量不知道，没用它，是重新认的"
		case .doubled: return "这一页的文字层里同样的字有可见、隐形两份（被别的软件 OCR 过），没用它，是重新认的"
		case .badCharacters: return "这一页 PDF 自带的文字有乱码（字体没带编码表），没用它，是重新认的"
		case .failedCheck: return "这一页 PDF 自带的文字跟页面上的字对不上（抽查了一段），没用它，是重新认的"
		}
	}
}

/// 光看画了什么就能定的：没画字、只有隐形字、可见隐形各一大份、图片盖住一半以上，都不用文字层。
/// 隐形字只有零星几处（拿字当裁剪形状的艺术字这类）照样用：OCR 层是盖满整页的，隐形的至少有可见的一半才算「又被 OCR 过」。
/// 这个一半是按经验定的，手上没有这种样本；判宽了整页退回认图、字差还慢得多，所以宁可判窄。
func textLayerSkip(_ ink: PageInk, coverage: Double) -> TextLayerSkip? {
	if ink.visibleText == 0 && ink.hiddenText == 0 { return .noText }
	if ink.visibleText == 0 { return .hiddenOnly }
	if ink.hiddenText * 2 >= ink.visibleText { return .doubled }
	if coverage >= 0.5 { return .mostlyImage }
	return nil
}

/// 乱码占多少：U+FFFD、私用区、控制字符（换行、制表不算）占非空白字的比例。
func badCharacterRatio(_ s: String) -> Double {
	var bad = 0, total = 0
	for u in s.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) {
		total += 1
		if u.value == 0xFFFD || (0xE000...0xF8FF).contains(u.value) || u.properties.generalCategory == .control { bad += 1 }
	}
	return total == 0 ? 0 : Double(bad) / Double(total)
}

// MARK: 按行取字

/// 文字层里的一段字：PDF 里出现的先后、字、位置（PDF 页面坐标；nil = PDFKit 给不出可信的位置）。
struct TextFragment {
	var order: Int
	var text: String
	var rect: CGRect?
}

/// 整页文字（PDFKit 排好的）按换行切段，段的框用 PDFKit 给这段字的选区框：照字号算，同一行一样高。
/// 不用按字取的字框：浏览器导出的 PDF 上它跟整页文字的下标对不上，取出来的是别的字的框。
/// 选区框比一般的段高出 2.5 倍以上的（浏览器导出的中文 PDF 上偶尔一个字的框从页顶跨到页底，PDFKit 也找不到它在哪），位置记成 nil。
func textFragments(_ page: PDFPage) -> [TextFragment] {
	let s = (page.string ?? "") as NSString
	var out: [TextFragment] = []
	var start = 0
	func emit(_ end: Int) {
		guard end > start else { return }
		let range = NSRange(location: start, length: end - start)
		let text = s.substring(with: range).trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty else { return }
		let rect = page.selection(for: range)?.bounds(for: page)
		out.append(TextFragment(order: start, text: text, rect: rect.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }))
	}
	for i in 0..<s.length {
		let c = s.character(at: i)
		if c == 10 || c == 13 {
			emit(i)
			start = i + 1
		}
	}
	emit(s.length)
	let heights = out.compactMap { $0.rect?.height }.sorted()
	if !heights.isEmpty {
		let typical = heights[heights.count / 2]
		for i in out.indices where (out[i].rect?.height ?? 0) > 2.5 * typical { out[i].rect = nil }
	}
	return out
}

/// 同一行上挨着的段拼成一行。浏览器导出的 PDF 同一行常被拆成好几段（中英文、标点分开画）；
/// 表格同一排的几格隔得远（缝比一个字高宽），各算各的。上下重叠六成以上、左右缝不到一个字高才算挨着；
/// 优先挨着最近的那行，被挪到别处的段（位置是对的）也能回到它那一行。行的先后照它最早那一段在整页文字（PDFKit 排好的）里的先后。
/// 拼的时候两边都是西文字母数字、中间又有空当，补一个空格。
func mergeFragments(_ fragments: [TextFragment]) -> [(text: String, rect: CGRect?, order: Int)] {
	let heights = fragments.compactMap { $0.rect?.height }.sorted()
	let unit = heights.isEmpty ? 10 : heights[heights.count / 2]
	var groups: [[TextFragment]] = []
	func fits(_ f: CGRect, _ group: [TextFragment]) -> Bool {
		group.contains { o in
			guard let r = o.rect else { return false }
			let overlap = min(r.maxY, f.maxY) - max(r.minY, f.minY)
			let gap = max(f.minX - r.maxX, r.minX - f.maxX)
			return overlap >= 0.6 * min(r.height, f.height) && gap <= max(unit, min(r.height, f.height)) && gap > -0.5 * unit
		}
	}
	for f in fragments {
		if let r = f.rect, let k = groups.indices.last(where: { fits(r, groups[$0]) }) {
			groups[k].append(f)
		} else {
			groups.append([f])
		}
	}
	return groups.map { g in
		let sorted = g.sorted { ($0.rect?.minX ?? 0) < ($1.rect?.minX ?? 0) }
		var text = ""
		var previous: CGRect?
		for f in sorted {
			if let p = previous, let r = f.rect, let a = text.last, let b = f.text.first, a.isASCII, b.isASCII, a.isLetter || a.isNumber,
				b.isLetter || b.isNumber, r.minX - p.maxX > 0.2 * r.height
			{
				text += " "
			}
			text += f.text
			previous = f.rect
		}
		let rects = g.compactMap(\.rect)
		return (text, rects.isEmpty ? nil : rects.reduce(CGRect.null) { $0.union($1) }, g.map(\.order).min()!)
	}.sorted { $0.order < $1.order }
}

/// PDF 页面坐标（左下原点）换成渲染出来的那张图上的坐标（左上原点、0–1），照页面自带的旋转（顺时针）摆正，跟 renderPDFPage 一样。
/// 四个角沿字的走向排：转了 90° 的页，字的左上在图的右上。
func displayedQuad(_ r: CGRect, crop: CGRect, rotation: Int) -> [NPoint] {
	let u0 = (r.minX - crop.minX) / crop.width, u1 = (r.maxX - crop.minX) / crop.width
	let v0 = (crop.maxY - r.maxY) / crop.height, v1 = (crop.maxY - r.minY) / crop.height
	let corners = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
	return corners.map { u, v in
		switch ((rotation % 360) + 360) % 360 {
		case 90: return NPoint(x: 1 - v, y: u)
		case 180: return NPoint(x: 1 - u, y: 1 - v)
		case 270: return NPoint(x: v, y: 1 - u)
		default: return NPoint(x: u, y: v)
		}
	}
}

/// `displayedQuad` 反过来：渲染出来的图上的一块（0–1、左上原点）换回 PDF 页面坐标。
func pageRect(_ region: NRect, crop: CGRect, rotation: Int) -> CGRect {
	let corners = [(region.x, region.y), (region.maxX, region.y), (region.maxX, region.maxY), (region.x, region.maxY)].map { x, y -> CGPoint in
		let (u, v): (Double, Double)
		switch ((rotation % 360) + 360) % 360 {
		case 90: (u, v) = (y, 1 - x)
		case 180: (u, v) = (1 - x, 1 - y)
		case 270: (u, v) = (1 - y, x)
		default: (u, v) = (x, y)
		}
		return CGPoint(x: crop.minX + u * crop.width, y: crop.maxY - v * crop.height)
	}
	let xs = corners.map(\.x), ys = corners.map(\.y)
	return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

func boundingBox(_ quad: [NPoint]) -> NRect {
	let xs = quad.map(\.x), ys = quad.map(\.y)
	return NRect(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
}

/// PDF 页面上的一个框做成一行：坐标换成渲染出来的图上的（0–1、左上原点），夹在 0–1 里。
func textLayerLine(_ text: String, _ r: CGRect, page: PDFPage, crop: CGRect) -> OCRLine {
	let quad = displayedQuad(r, crop: crop, rotation: page.rotation).map { NPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
	return OCRLine(text: text, confidence: 1, box: boundingBox(quad), quad: quad)
}

/// 一页文字层按行取出来，坐标跟 OCR 的一样（相对渲染出来的图，左上原点、0–1）。给不出位置的段框是空的，字照顺序留着。
/// 画在裁剪框外面的字（藏起来的、出了页面的）不要；被裁剪框切过的行只留框里那截字，框也截到裁剪框里
/// （不截的话，行框伸到图外、坐标成了负数，字却还是整行）。
func textLayerLines(_ page: PDFPage) -> [OCRLine] {
	let crop = page.bounds(for: .cropBox)
	guard crop.width > 0, crop.height > 0 else { return [] }
	return mergeFragments(textFragments(page)).compactMap { m -> OCRLine? in
		guard let r = m.rect else {
			return OCRLine(text: m.text, confidence: 1, box: NRect(x: 0, y: 0, w: 0, h: 0), quad: Array(repeating: NPoint(x: 0, y: 0), count: 4))
		}
		if crop.contains(r) { return textLayerLine(m.text, r, page: page, crop: crop) }
		let inside = r.intersection(crop)
		guard !inside.isNull, inside.width >= 0.5 * r.height, inside.height >= 0.5 * r.height else { return nil }
		// 只取这一行高度中间那一截里的字，免得把上下挨着的行带进来。
		let probe = inside.insetBy(dx: 0, dy: inside.height * 0.25)
		let text = (page.selection(for: probe)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : textLayerLine(text, inside, page: page, crop: crop)
	}
}

/// 文字层页上框出的一块里的字：PDFKit 按框选字（跟在 PDF 阅读器里拖选一样），一行一项。
/// 不能按整行的中心筛：框住半行时要么一个字也取不到、要么带出框外的字。
public func textLayerLines(_ page: PDFPage, in region: NRect) -> [OCRLine] {
	let crop = page.bounds(for: .cropBox)
	guard crop.width > 0, crop.height > 0 else { return [] }
	let rect = pageRect(region, crop: crop, rotation: page.rotation).intersection(crop)
	guard !rect.isNull, let selection = page.selection(for: rect) else { return [] }
	return selection.selectionsByLine().compactMap { line -> OCRLine? in
		let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let r = line.bounds(for: page).intersection(crop)
		guard !text.isEmpty, !r.isNull else { return nil }
		return textLayerLine(text, r, page: page, crop: crop)
	}
}

// MARK: 抽查

/// 抽查文字层：挑一条横跨整页、上下不超过 8 行高、不压着图片的横条（字最多的那条），OCR 一遍，
/// 认出来的字八成以上在这条横条里的文字层里才算对得上。字体编码错位的文字层（取出来是像样的字、却不是页面上的字）
/// 乱码比例看不出来，只能这样对。什么时候查见 runPage。字太少（不到 30 个）判断不了，返回 nil，照用文字层。
/// 横条要横跨整页、跟横条里所有的行比：封面这种字很散的页，只拿挑出来的几行比，同一排别的格子的字会被当成对不上。
func textLayerAgrees(_ image: CGImage, lines: [OCRLine], avoiding pictures: [NRect], options: LineOptions) throws -> Bool? {
	let placed = lines.filter { $0.box.area > 0 }.sorted { $0.box.y < $1.box.y }
	guard !placed.isEmpty else { return nil }
	let heights = placed.map { $0.box.h }.sorted()
	let unit = heights[heights.count / 2]
	var best: (band: NRect, chars: Int)?
	for i in placed.indices {
		var j = i + 1
		while j < placed.count && j - i < 6 && placed[j].box.maxY - placed[i].box.y < 8 * unit { j += 1 }
		let top = placed[i].box.y - 0.5 * unit
		let bottom = placed[i..<j].map { $0.box.maxY }.max()! + 0.5 * unit
		let band = NRect(x: 0, y: top, w: 1, h: bottom - top).clamped()
		if pictures.contains(where: { $0.overlapArea(band) > 0 }) { continue }
		let chars = lines.filter { $0.box.area > 0 && band.contains($0.box.center) }.reduce(0) { $0 + $1.coreLength }
		if best == nil || chars > best!.chars { best = (band, chars) }
	}
	guard let pick = best, pick.chars >= 30 else { return nil }
	let reference = lines.filter { $0.box.area > 0 && pick.band.overlapArea($0.box) > 0 }.map { $0.text }.joined()
	let ocr = try recognizeLines(image, regions: [pick.band], options: options)[0].map { $0.text }.joined()
	guard coreCharacters(ocr).count >= 20 else { return nil }
	return bagRecall(of: ocr, in: reference) >= 0.8
}

// MARK: 认一页

extension OCREngine {
	/// 认一份文件里的第 n 页：PDF 的数字页直接用文字层（图片区另外 OCR），别的照常 OCR。
	/// 设置里关了文字层、认法选了「认文档」（要表格结构，文字层没有）时照常 OCR。
	/// `memory`：一份文件一页页认时传同一个：文字层只抽查一次、同一张图只认一次、中文优先记住上一页。
	public func runPage(_ source: PageSource, page n: Int, options: OCROptions, memory: RunMemory? = nil) throws -> PageResult {
		guard options.textLayer, options.mode != .document, let pdfPage = source.pdfPage(n), let page = source.kitPage(n) else {
			return try runPage(try source.image(page: n), page: n, options: options, memory: memory)
		}
		let started = Date()
		let crop = page.bounds(for: .cropBox)
		let ink = scanInk(pdfPage)
		var skip = textLayerSkip(ink, coverage: imageCoverage(ink.images.map(\.rect), in: crop))
		var lines: [OCRLine] = []
		if skip == nil {
			lines = textLayerLines(page)
			if lines.allSatisfy({ $0.coreLength == 0 }) {
				skip = .noText
			} else if badCharacterRatio(lines.map(\.text).joined()) > 0.02 {
				skip = .badCharacters
			} else if memory?.usesBadFont(Set(ink.fonts.keys)) == true {
				skip = .failedCheck
			}
		}
		var image: CGImage?
		func rendered() throws -> CGImage {
			if let image { return image }
			let made = try source.image(page: n)
			image = made
			return made
		}
		let pictureBoxes = ink.images.map { boundingBox(displayedQuad($0.rect.intersection(crop), crop: crop, rotation: page.rotation)) }
		let lineOptions = textLayerLineOptions(lines, options)
		// 抽查（见 textLayerAgrees）：单认一页时每次都查；一份文件一页页认时，用了没查过的字体的页查（拼起来的 PDF 每段字体不一样，
		// 只查第一页的话后面的错字层能混过去），白底上画了白字的页也查（看不见的字，可能是垫的一层假字）。
		// 红底白字这种看得见，不用查：数字 PDF 的表头常是红底白字，都查的话白白多花时间。
		var checked: String?
		if skip == nil {
			let whiteOnWhite = try !ink.whiteText.isEmpty && onWhite(ink.whiteText, in: rendered(), crop: crop, rotation: page.rotation)
			checked = memory == nil ? "single" : whiteOnWhite ? "white-text" : memory?.fontsVerified(ink.mainFonts) == false ? "new-fonts" : nil
			if checked != nil {
				let agrees = try textLayerAgrees(try rendered(), lines: lines, avoiding: pictureBoxes, options: lineOptions)
				if let agrees { memory?.recordCheck(fonts: ink.mainFonts, agrees: agrees, blameFonts: !whiteOnWhite) }
				if agrees == false { skip = .failedCheck }
			}
		}
		if let skip {
			var result = try runPage(try rendered(), page: n, options: options, memory: memory)
			result.steps["textLayer"] = ["used": false, "reason": skip.rawValue]
			if let note = skip.note { result.notes.append(note) }
			return result
		}
		// 框选、MCP 给了 region：按框选字，不按整行筛。
		if let region = options.region { lines = textLayerLines(page, in: region) }

		// 页面 2% 以上的图片（插图、流程图、截图）里的字：只认这一块，跟文字层重叠的行不要（图上压着的数字字文字层里已经有了），
		// 按位置插进文字层的行里。同一张图在同一个位置、画出来的样子也一样（每页的页眉标志）才用上一次认的：
		// 图上还可能压着别的东西（矢量画的字、图形），只看图片对象会把前一页的字串到这一页。
		let size = source.pixelSize(page: n, longSide: Int(ImageLimits.pdfLongSide))
		let width = Int(size.width), height = Int(size.height)
		var blocks: [[OCRLine]] = []
		var pictures: [NRect] = []
		for (picture, box) in zip(ink.images, pictureBoxes) {
			let r = picture.rect.intersection(crop)
			guard !r.isNull, r.width * r.height >= 0.02 * crop.width * crop.height else { continue }
			pictures.append(box)
			var area = box
			if let region = options.region {
				let x0 = max(box.x, region.x), y0 = max(box.y, region.y), x1 = min(box.maxX, region.maxX), y1 = min(box.maxY, region.maxY)
				guard x1 > x0, y1 > y0 else { continue }
				area = NRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
			}
			let shown = try rendered()
			let key = "\(picture.key)@\([area.x, area.y, area.w, area.h].map { Int(($0 * 1000).rounded()) })#\(pixelFingerprint(shown, area))"
			var found: [OCRLine]
			if let cached = memory?.imageLines(key) {
				found = cached
			} else {
				found = try recognizeLines(shown, regions: [area], options: lineOptions)[0]
				if lineOptions.languages?.first?.lowercased().hasPrefix("zh") == true {
					found = droppingContainedDuplicates(found.map { $0.halfWidthPunctuation() }, width: shown.width, height: shown.height)
				}
				memory?.setImageLines(key, found)
			}
			found = found.filter { l in !lines.contains { $0.box.area > 0 && $0.box.overlapArea(l.box) > 0.5 * l.box.area } }
			if !found.isEmpty { blocks.append(readingRows(found, width: width, height: height).flatMap { $0.map { found[$0] } }) }
		}
		var ordered = lines
		for block in blocks {
			let top = block.map(\.box.y).min()!
			ordered.insert(contentsOf: block, at: ordered.firstIndex { $0.box.area > 0 && $0.box.y > top } ?? ordered.count)
		}

		var notes: [String] = []
		var steps: [String: Any] = [:]
		if let p = configProblem { notes.append(p) }
		// 文字层的行可信度是 1，不会标；图片区认出的照常按系统可信度标、交给判定插件复核。
		markSuspects(&ordered, skip: { _ in false }, usePlugins: options.usePlugins, notes: &notes, steps: &steps)
		// 二维码、条码每页都找（开着的话）：矢量画的、比 2% 小的图里的码，只看大图会漏。
		// 这一页没为别的事渲染过，就按长边 1600 渲染来找（A4 约 137 dpi，2 厘米的二维码每格还有 3–4 像素），
		// 渲染、找码都比按认字用的 2500 快。
		var barcodes: [String] = []
		if options.barcodes {
			let shown = try image ?? source.image(page: n, longSide: 1600)
			barcodes = detectBarcodes(options.region.flatMap { OCRCore.crop(shown, $0) } ?? shown)
		}
		// checked：这一页抽查了没有、为什么查（single 单认一页、new-fonts 有没查过的字体、white-text 白底上有白字）。
		steps["textLayer"] = ["used": true, "lines": lines.count, "pictures": pictures.count, "checked": checked.map { $0 as Any } ?? false]
		steps["mode"] = "textLayer"
		steps["ms"] = Int(Date().timeIntervalSince(started) * 1000)
		let text = textLayerText(ordered)
		var result = PageResult(
			page: n, width: width, height: height, mode: .lines, lines: ordered, text: text, cleanText: text, document: nil, barcodes: barcodes,
			notes: notes, coordinateSpace: "original", rectifiedImage: nil, steps: steps)
		result.textLayer = true
		result.pictureBoxes = pictures
		return result
	}

	/// 文字层的行拼成整页文字：往下隔了一大段（空当比一行字高的八成还大，段与段之间）空一行，跟认图时按大片空白分块一样好读。
	/// 一般的行与行之间：Word 导出的几乎贴着，浏览器导出的空当也不到八成行高；段与段之间的空当比一行字还高。
	func textLayerText(_ lines: [OCRLine]) -> String {
		var parts: [String] = []
		var previous: OCRLine?
		for l in lines {
			if let p = previous, p.box.area > 0, l.box.area > 0, l.box.y - p.box.maxY > 0.8 * max(p.box.h, l.box.h) { parts.append("") }
			parts.append(l.text)
			previous = l
		}
		return parts.joined(separator: "\n")
	}

	/// 文字层页上的图片区、抽查用什么语言认：指定了就照指定的（中日韩排前）；中文优先、文字层不是西文就按中文认；不然自动判断。
	func textLayerLineOptions(_ lines: [OCRLine], _ options: OCROptions) -> LineOptions {
		if let langs = options.languages, !langs.isEmpty { return LineOptions(languages: cjkFirst(langs), correction: options.correction) }
		if (options.languagePreference ?? languagePreference) == .chineseFirst, !ScriptCounts(lines).looksWestern {
			return LineOptions(languages: chineseFirstLanguages, correction: options.correction)
		}
		return LineOptions(correction: options.correction)
	}
}

/// 图上一块的指纹（像素逐个算进去的哈希）：同一张图上压着的东西不一样，指纹就不一样。
func pixelFingerprint(_ image: CGImage, _ r: NRect) -> UInt64 {
	var hash: UInt64 = 0xcbf2_9ce4_8422_2325
	guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return hash }
	let bpp = max(image.bitsPerPixel / 8, 1), rowBytes = image.bytesPerRow
	let x0 = max(0, Int(r.x * Double(image.width))), x1 = min(image.width, Int((r.maxX * Double(image.width)).rounded(.up)))
	let y0 = max(0, Int(r.y * Double(image.height))), y1 = min(image.height, Int((r.maxY * Double(image.height)).rounded(.up)))
	guard x1 > x0, y1 > y0 else { return hash }
	for y in y0..<y1 {
		let row = bytes + y * rowBytes
		for i in (x0 * bpp)..<(x1 * bpp) {
			hash = (hash ^ UInt64(row[i])) &* 0x100_0000_01b3
		}
	}
	return hash
}

/// 白字画的那几块，三成以上画在白底上：渲染出来看每块里的像素，一半以上接近白色就算白底（白字压在描出来的黑字上也算：
/// 黑笔画占不到一半）。红底、黑底上的白字，块里大半是底色。零星几块落在白处的不算（红底白字的表格里也会有这样几块）。
func onWhite(_ boxes: [CGRect], in image: CGImage, crop: CGRect, rotation: Int) -> Bool {
	guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
	let bpp = image.bitsPerPixel / 8, rowBytes = image.bytesPerRow
	guard bpp >= 3 else { return false }
	var onWhite = 0, seen = 0
	for box in boxes {
		let r = boundingBox(displayedQuad(box.intersection(crop), crop: crop, rotation: rotation))
		let x0 = max(0, Int(r.x * Double(image.width))), x1 = min(image.width, Int((r.maxX * Double(image.width)).rounded(.up)))
		let y0 = max(0, Int(r.y * Double(image.height))), y1 = min(image.height, Int((r.maxY * Double(image.height)).rounded(.up)))
		guard x1 > x0, y1 > y0 else { continue }
		var white = 0
		for y in y0..<y1 {
			let row = bytes + y * rowBytes
			for x in x0..<x1 where row[x * bpp] >= 235 && row[x * bpp + 1] >= 235 && row[x * bpp + 2] >= 235 { white += 1 }
		}
		seen += 1
		if white * 2 >= (x1 - x0) * (y1 - y0) { onWhite += 1 }
	}
	return seen > 0 && onWhite * 10 >= seen * 3
}

