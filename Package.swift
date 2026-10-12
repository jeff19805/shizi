// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "shizi",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "shizi-mcp", targets: ["shizi-mcp"]),
		.executable(name: "ocr-plugin-systemone", targets: ["ocr-plugin-systemone"]),
		.executable(name: "Shizi", targets: ["Shizi"]),
	],
	targets: [
		// 识别核心：只用系统自带的文字识别，不联网、不认任何插件的名字。照片的字存在系统自带的 sqlite3 里（拾字写、MCP 读）。
		.target(name: "OCRCore", linkerSettings: [.linkedLibrary("sqlite3")]),
		// MCP 服务（标准输入输出上的 JSON-RPC）和命令行入口。
		.target(name: "OCRServer", dependencies: ["OCRCore"]),
		// MCP 服务和命令行的程序。不叫 shizi：Mac 的文件名默认不分大小写，跟 App 的程序 Shizi 会是同一个文件。
		// 启动时要把改名前的配置文件搬过来，所以也直接用到 OCRCore。
		.executableTarget(name: "shizi-mcp", dependencies: ["OCRServer", "OCRCore"]),
		// System One 判定插件（Clef、TypeSafe Jev、灵犀的判定网关说的都是这个约定）：独立小程序，核心只按插件约定跟它说话。
		.executableTarget(name: "ocr-plugin-systemone"),
		// 拾字：带界面的 App。界面和数据都在 ShiziKit，Shizi 只是个壳：测试和出截图都用得上 ShiziKit。
		.target(name: "ShiziKit", dependencies: ["OCRCore"]),
		.executableTarget(name: "Shizi", dependencies: ["ShiziKit", "OCRCore"]),
		// 开发用：把各个界面画成图片，评审界面用，不进 App。
		.executableTarget(name: "shizi-snapshots", dependencies: ["ShiziKit"]),
		.testTarget(name: "OCRTests", dependencies: ["OCRCore", "OCRServer", "ShiziKit"]),
	],
	// 系统识别接口里的类型大多没标并发安全，用 Swift 5 语言模式，免得满屏并发告警。
	swiftLanguageModes: [.v5]
)
