import SwiftUI

/// 菜单栏：每个页头上的操作这里都有，带快捷键（设计规范 §7）。
public struct ShiziCommands: Commands {
	let workspace: Workspace
	@AppStorage(ViewOptions.showBoxes) private var showBoxes = true
	@AppStorage(ViewOptions.textMode) private var textMode = TextMode.page

	public init(workspace: Workspace) {
		self.workspace = workspace
	}

	public var body: some Commands {
		CommandGroup(replacing: .appInfo) {
			Button("关于拾字") { AboutPanel.show() }
		}
		// 跟工具栏上的「整页 / 逐行」是同一个设置；像访达的「显示」菜单，放在最上面、⌘1 ⌘2。没在看文件或照片时灰掉。
		CommandGroup(before: .toolbar) {
			Group {
				Toggle("整页", isOn: textModeIs(.page))
					.keyboardShortcut("1")
				Toggle("逐行", isOn: textModeIs(.lines))
					.keyboardShortcut("2")
			}
			.disabled(workspace.activeDocument == nil)
			Divider()
		}
		CommandGroup(after: .sidebar) {
			Toggle("显示识别框", isOn: $showBoxes)
				.keyboardShortcut("b", modifiers: [.command, .shift])
			// 在相簿里点开了一张：回网格（跟左上角的返回一样）。
			Button("返回相簿") { workspace.photos.back() }
				.keyboardShortcut("[")
				.disabled(workspace.selectedAlbumID == nil || workspace.photos.viewingID == nil)
		}
		CommandGroup(replacing: .newItem) {
			Button("打开…") { workspace.showOpenPanel() }
				.keyboardShortcut("o")
		}
		CommandGroup(after: .pasteboard) {
			Button("复制全文") { workspace.activeDocument?.copyAll() }
				.keyboardShortcut("c", modifiers: [.command, .shift])
				.disabled(workspace.activeDocument?.results.isEmpty ?? true)
		}
		CommandMenu("识别") {
			// 左栏选的是相簿、又没点开照片时，⌘R 认这个相簿里还没认过的照片。
			Button(workspace.activeDocument == nil && workspace.selectedAlbumID != nil ? "识别这个相簿" : "重新识别") {
				workspace.recognizeSelection()
			}
				.keyboardShortcut("r")
				.disabled(!workspace.canRecognize)
			Button("停止") { workspace.stopSelection() }
				.keyboardShortcut(".")
				.disabled(!workspace.canStop)
			Divider()
			Button("导出 Markdown…") { workspace.activeDocument?.export(.markdown) }
				.keyboardShortcut("e")
				.disabled(workspace.activeDocument?.results.isEmpty ?? true)
			Button("导出纯文字…") { workspace.activeDocument?.export(.text) }
				.disabled(workspace.activeDocument?.results.isEmpty ?? true)
			Button("导出 JSON（带每行位置）…") { workspace.activeDocument?.export(.json) }
				.disabled(workspace.activeDocument?.results.isEmpty ?? true)
		}
	}

	/// 菜单里打勾的那一项：点已经勾上的不变（两项总有一项勾着）。
	func textModeIs(_ mode: TextMode) -> Binding<Bool> {
		Binding(get: { textMode == mode }, set: { if $0 { textMode = mode } })
	}
}
