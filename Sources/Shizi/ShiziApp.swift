import AppKit
import OCRCore
import ShiziKit
import SwiftUI

@main
struct ShiziApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

	init() {
		// 改名前（mac-ocr-mcp）的配置文件复制到新位置，只第一次。要赶在设置页、识别服务读配置之前。
		OCRConfig.copyOldConfigIfNeeded()
	}

	var body: some Scene {
		Window("拾字", id: "main") {
			RootView(workspace: .shared)
				.frame(minWidth: 820, minHeight: 520)
		}
		.defaultSize(width: 1200, height: 760)
		.commands { ShiziCommands(workspace: .shared) }

		Settings {
			SettingsView()
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// 照片自检（开发、排查用）：open -a 拾字.app --args --photos-check 报告.json [--download-probe 4]，见 PhotoCheck。
		let args = CommandLine.arguments
		if let i = args.firstIndex(of: "--photos-check"), i + 1 < args.count {
			let probe = args.firstIndex(of: "--download-probe").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
			PhotoCheck.run(report: args[i + 1], downloadProbe: probe)
		}
		// 只量按画面分类用的预览图（不认字、不下载）：open -a 拾字.app --args --preview-check 报告.json
		if let i = args.firstIndex(of: "--preview-check"), i + 1 < args.count {
			PhotoCheck.runPreviews(report: args[i + 1])
		}
	}

	/// 文件拖到 Dock 上的图标、或在访达里用「打开方式」选了拾字。
	func application(_ application: NSApplication, open urls: [URL]) {
		Workspace.shared.open(urls)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
