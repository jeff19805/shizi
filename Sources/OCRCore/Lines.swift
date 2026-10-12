import CoreGraphics
import Foundation
import Vision

/// 一行识别结果。坐标都是 0–1、左上角为原点，相对「实际拿去识别的那张图」。
public struct OCRLine: Sendable {
	public var text: String
	/// 系统给的可信度，实际只有 0.3 / 0.5 / 1.0 三档左右。
	public var confidence: Double
	public var box: NRect
	/// 左上、右上、右下、左下四个角，沿字的走向（倒着的字，「左上」就在图的右下）。
	public var quad: [NPoint]
	public var suspect: Suspect?
	/// 每个字中心的横坐标（相对整图）。只给切块时贴着左右接缝的行算，拼接碎片时按它从接缝中线切开。
	var charCenters: [Double]?

	public init(text: String, confidence: Double, box: NRect, quad: [NPoint], suspect: Suspect? = nil) {
		self.text = text
		self.confidence = confidence
		self.box = box
		self.quad = quad
		self.suspect = suspect
	}

	/// 只算字母、数字、汉字的个数（标点空格不算）。
	public var coreLength: Int { text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count }

	func mapped(into region: NRect) -> OCRLine {
		var l = self
		l.box = box.mapped(into: region)
		l.quad = quad.map { $0.mapped(into: region) }
		l.charCenters = charCenters?.map { region.x + $0 * region.w }
		return l
	}
}

public struct Suspect: Sendable {
	public enum Reason: String, Sendable {
		/// 系统可信度在最低一档。
		case lowConfidence = "low-confidence"
		/// 判定插件认为这行认错了。
		case plugin
		/// 只有认文档认出来、逐行识别在那儿什么都没认出（多是公章、签名上的乱码）。
		case documentOnly = "document-only"
	}

	public var reason: Reason
	/// 插件给的「认错了」的概率；只看可信度时没有。
	public var probability: Double?

	public init(reason: Reason, probability: Double?) {
		self.reason = reason
		self.probability = probability
	}
}

public struct LineOptions: Sendable {
	/// nil 或空 = 让系统一行一行自己判断语言（日韩文要靠它，不判断又不指定就一个字都不出）。
	/// 汉字夹在字母、数字里的行会被当成西文认成乱码，短的中文会被当成日文，见 `LanguagePreference`。
	/// 指定时只用第一个语言的模型。
	public var languages: [String]?
	public var correction = true
	public var customWords: [String] = []

	public init(languages: [String]? = nil, correction: Bool = true, customWords: [String] = []) {
		self.languages = languages
		self.correction = correction
		self.customWords = customWords
	}
}

/// 逐行识别。`regions` 每个区域各认一遍（左上原点、相对整图），结果坐标换算回整图，按区域分组返回。
/// `charCentersNearEdges`：贴着区域左右边的行另算每个字的位置（切块拼接用）。
public func recognizeLines(_ image: CGImage, regions: [NRect] = [.full], options: LineOptions, charCentersNearEdges: Bool = false)
	throws -> [[OCRLine]]
{
	try recognizeLines(image, regions: regions, options: options, charCentersNearEdges: charCentersNearEdges, findText: false).lines
}

/// 逐行认整张图，同时让系统「找字的位置」（只找哪里有字、不认字，跟语言无关，花不了多少时间）。
/// 中文优先时拿找到的字块看中文认没认全：韩文、日文按中文认什么都不出。字块坐标左上原点、0–1。
func recognizeLinesFindingText(_ image: CGImage, options: LineOptions) throws -> (lines: [OCRLine], textBlocks: [NRect]) {
	let r = try recognizeLines(image, regions: [.full], options: options, charCentersNearEdges: false, findText: true)
	return (r.lines[0], r.textBlocks)
}

func recognizeLines(_ image: CGImage, regions: [NRect], options: LineOptions, charCentersNearEdges: Bool, findText: Bool)
	throws -> (lines: [[OCRLine]], textBlocks: [NRect])
{
	let handler = VNImageRequestHandler(cgImage: image, options: [:])
	let requests = regions.map { region -> VNRecognizeTextRequest in
		let r = VNRecognizeTextRequest()
		r.recognitionLevel = .accurate
		if let langs = options.languages, !langs.isEmpty {
			r.recognitionLanguages = langs
		} else {
			r.automaticallyDetectsLanguage = true
		}
		r.usesLanguageCorrection = options.correction
		if !options.customWords.isEmpty { r.customWords = options.customWords }
		r.regionOfInterest = region.clamped().visionRect
		return r
	}
	let finder = findText ? VNDetectTextRectanglesRequest() : nil
	do {
		try handler.perform(requests + (finder.map { [$0] } ?? []))
	} catch {
		throw OCRError.recognition(error.localizedDescription)
	}
	let blocks = (finder?.results ?? []).map { NRect(visionRect: $0.boundingBox) }
	let edge = 3.0 / Double(max(image.width, 1))
	// 区域里的结果坐标是相对区域的，要换算回整图。
	let lines = zip(requests, regions).map { req, rawRegion in
		let region = rawRegion.clamped()
		return (req.results ?? []).compactMap { obs -> OCRLine? in
			guard let best = obs.topCandidates(1).first, !best.string.isEmpty else { return nil }
			let quad = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { NPoint(visionPoint: $0) }
			var line = OCRLine(text: best.string, confidence: Double(best.confidence), box: NRect(visionRect: obs.boundingBox), quad: quad)
			if charCentersNearEdges {
				let b = line.box.mapped(into: region)
				let lineH = b.h * Double(image.height) / Double(image.width)
				let tol = max(edge, 0.5 * lineH)
				if b.x <= region.x + tol || b.maxX >= region.maxX - tol { line.charCenters = charCenters(best, line.text) }
			}
			return line.mapped(into: region)
		}
	}
	return (lines, blocks)
}

/// 每个字中心的横坐标（相对识别区域）。有一个字给不出位置就整行返回 nil，拼接时改按整行平均分摊。
func charCenters(_ candidate: VNRecognizedText, _ s: String) -> [Double]? {
	var out: [Double] = []
	for i in s.indices {
		guard let r = try? candidate.boundingBox(for: i..<s.index(after: i)) else { return nil }
		out.append(Double(r.boundingBox.midX))
	}
	return out.isEmpty ? nil : out
}

public func detectBarcodes(_ image: CGImage) -> [String] {
	let req = VNDetectBarcodesRequest()
	try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
	return (req.results ?? []).compactMap(\.payloadStringValue)
}

/// 精确档支持的语言（快速档只有 6 种西文，中文只能用精确档，所以这里只报精确档）。
public func supportedLanguages() -> [String] {
	let r = VNRecognizeTextRequest()
	r.recognitionLevel = .accurate
	return (try? r.supportedRecognitionLanguages()) ?? []
}
