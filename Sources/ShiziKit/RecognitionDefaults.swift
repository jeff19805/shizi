import Foundation
import OCRCore

/// 看的时候的开关（不影响认出来的字）。
enum ViewOptions {
	/// 原图上叠不叠识别框（默认叠）。
	static let showBoxes = "拾字.显示识别框"
	/// 右边认出的字怎么看：整页还是逐行（默认整页）。
	static let textMode = "拾字.看法"
}

/// 右边认出的字的两种看法。「整页」一整段，给读和复制；「逐行」一行一项，可能认错的标出来。
enum TextMode: String {
	case page, lines
}

/// 设置页「识别」里的默认选项：新打开的文件、按 ⌘R 重新识别时用。
enum RecognitionDefaults {
	static let mode = "拾字.识别.认法"
	static let rectify = "拾字.识别.拉正"
	static let tiles = "拾字.识别.切块"
	static let barcodes = "拾字.识别.条码"
	/// PDF 里有文字时直接用（默认用）。
	static let textLayer = "拾字.识别.文字层"
	static let plugins = "拾字.识别.插件"
	/// 认照片时原图只在 iCloud 上，要不要下载（默认要）。
	static let photoDownload = "拾字.照片.下载原图"
	/// 认照片时用不用判定插件（默认不用）：插件的「看图」口子会把每张照片缩小后发到插件的服务，认几百张就发几百张。
	static let photoPlugins = "拾字.照片.插件"

	static func options(_ d: UserDefaults = .standard) -> OCROptions {
		var o = OCROptions()
		o.mode = OCRMode(rawValue: d.string(forKey: mode) ?? "") ?? .auto
		o.rectify = Switch(rawValue: d.string(forKey: rectify) ?? "") ?? .auto
		o.tiles = Switch(rawValue: d.string(forKey: tiles) ?? "") ?? .auto
		o.barcodes = d.object(forKey: barcodes) as? Bool ?? true
		o.textLayer = d.object(forKey: textLayer) as? Bool ?? true
		o.usePlugins = d.object(forKey: plugins) as? Bool ?? true
		return o
	}

	/// 认照片用的：跟文件一样，只是插件另有一个开关。
	static func photoOptions(_ d: UserDefaults = .standard) -> OCROptions {
		var o = options(d)
		o.usePlugins = d.object(forKey: photoPlugins) as? Bool ?? false
		return o
	}

	static func downloadOriginals(_ d: UserDefaults = .standard) -> Bool {
		d.object(forKey: photoDownload) as? Bool ?? true
	}
}
