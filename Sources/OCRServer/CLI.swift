import Foundation
import OCRCore

/// 命令行帮助：每次现算，测试会在一个进程里来回切中英文（见 Texts）。
var usage: String {
	Texts.text("""
		用法：
		  shizi-mcp                       作为 MCP 服务运行（标准输入输出）
		  shizi-mcp ocr <图片或PDF> [选项]    在命令行里认一张图
		  shizi-mcp status                看系统能力和插件状况
		  shizi-mcp --version             版本号

		ocr 的选项：
		  --mode auto|lines|document      默认 auto
		  --lang auto|chinese-first|zh-Hans,en-US,...
		                                  默认照配置（拾字设置里的「识别语言」），没配就是自动判断
		  --pages 1-3,5                   PDF 页码，默认前 20 页
		  --region 左,上,宽,高             只认这一块（0–1，左上为原点）
		  --rectify auto|on|off           拉正拍歪的纸，默认 auto
		  --tiles auto|on|off             大图小字切块细认，默认 auto
		  --no-barcodes                   不找二维码 / 条码（默认找）
		  --no-plugins                    这次不调插件
		  --no-text-layer                 PDF 也全部认图，不用它自带的文字
		  --json                          输出完整的结构化结果

		插件配置：~/.config/shizi/config.json（或环境变量 SHIZI_CONFIG），见 docs/plugins.zh-CN.md。
		""")
}

public enum CLI {
	/// 返回进程退出码。
	public static func main(_ argv: [String]) -> Int32 {
		signal(SIGPIPE, SIG_IGN)
		let args = Array(argv.dropFirst())
		switch args.first {
		case nil, "serve":
			MCPServer(watching: ProcessInfo.processInfo.environment).run()
			return 0
		case "ocr":
			return ocr(Array(args.dropFirst()))
		case "status":
			print(statusText(OCREngine.fromDefaultConfig()))
			return 0
		case "--version", "version":
			print(OCRVersion.current)
			return 0
		case "-h", "--help", "help":
			print(usage)
			return 0
		default:
			FileHandle.standardError.write(Data((Texts.text("不认识的命令：\(args[0])") + "\n\n\(usage)\n").utf8))
			return 2
		}
	}

	static func ocr(_ args: [String]) -> Int32 {
		var path: String?
		var options = OCROptions()
		var json = false
		var i = 0
		func value() throws -> String {
			i += 1
			guard i < args.count else { throw ArgumentError.invalid(Texts.text("\(args[i - 1]) 后面要跟一个值")) }
			return args[i]
		}
		do {
			while i < args.count {
				switch args[i] {
				case "--mode": options.mode = try parseEnum(try value(), "mode", default: .auto)
				case "--lang": (options.languages, options.languagePreference) = parseLanguages(try value().split(separator: ",").map(String.init))
				case "--pages": options.pages = try parsePages(try value())
				case "--region": options.region = try parseRegion(try value().split(separator: ",").compactMap { Double($0) })
				case "--rectify": options.rectify = try parseEnum(try value(), "rectify", default: .auto)
				case "--tiles": options.tiles = try parseEnum(try value(), "tiles", default: .auto)
				case "--no-barcodes": options.barcodes = false
				case "--no-plugins": options.usePlugins = false
				case "--no-text-layer": options.textLayer = false
				case "--json": json = true
				default:
					if args[i].hasPrefix("--") { throw ArgumentError.invalid(Texts.text("不认识的选项 \(args[i])")) }
					path = args[i]
				}
				i += 1
			}
			guard let path else { throw ArgumentError.invalid(Texts.text("要给一个图片或 PDF 的路径")) }
			let engine = OCREngine.fromDefaultConfig()
			let result = try engine.run(path: path, options: options)
			print(json ? jsonString(resultJSON(result.pages, totalPages: result.totalPages), pretty: true) : renderText(result.pages, totalPages: result.totalPages))
			return 0
		} catch {
			FileHandle.standardError.write(Data("\(error)\n".utf8))
			return 1
		}
	}
}

/// 系统能力 + 插件状况（会调一次每个插件的 describe）。
func statusText(_ engine: OCREngine) -> String {
	var lines: [String] = []
	let v = ProcessInfo.processInfo.operatingSystemVersion
	lines.append(Texts.text("拾字 shizi-mcp \(OCRVersion.current)"))
	lines.append(Texts.text("系统：macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"))
	let documentMode = OCREngine.documentModeAvailable ? Texts.text("可用") : Texts.text("不可用，要 macOS 26 或更新")
	lines.append(Texts.text("认文档（表格、多栏、竖排）：\(documentMode)"))
	// 语言代码照原样，只有隔开它们的「、」跟着界面语言。
	let languages = supportedLanguages().joined(separator: Texts.text("、"))
	lines.append(Texts.text("支持的语言：\(languages)"))
	let preference =
		engine.languagePreference == .chineseFirst
		? Texts.text("中文优先（先按中文认，西文页、中文认不了的页改回自动判断）") : Texts.text("系统自动判断")
	lines.append(Texts.text("不指定语言时：\(preference)"))
	if let path = engine.configPath {
		lines.append(
			FileManager.default.fileExists(atPath: path) ? Texts.text("配置文件：\(path)") : Texts.text("配置文件：\(path)（不存在，等于没有插件）"))
	}
	if let p = engine.configProblem { lines.append(Texts.text("配置问题：\(p)")) }
	if engine.host.plugins.isEmpty {
		lines.append(Texts.text("插件：没有"))
	} else {
		for p in engine.host.plugins {
			// 钩子名（route、review……）是配置里的名字，照原样。
			let hooks = p.hooks.joined(separator: Texts.text("、"))
			// 测连接可能要问两次（测试题、收不收图），给足 10 秒。
			switch engine.host.call(p, hook: "describe", input: ["hooks": p.hooks], timeoutMs: 10_000) {
			case .success(var out):
				let warnings = out.removeValue(forKey: "warnings") as? [String] ?? []
				// 收不收图，插件约定里的值是「收」「不收」（App 也拿它比对，不能改）：印给人看时换成界面的语言。
				if let images = out["images"] as? String { out["images"] = Texts.text(String.LocalizationValue(images)) }
				lines.append(Texts.text("插件 \(p.name)（\(hooks)）：正常 \(jsonString(out))"))
				lines += warnings.map { Texts.text("  注意：\($0)") }
			case .failure(let f):
				lines.append(Texts.text("插件 \(p.name)（\(hooks)）：有问题 —— \(f.message)"))
			}
		}
	}
	return lines.joined(separator: "\n")
}
