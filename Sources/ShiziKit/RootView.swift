import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：左边这次打开过的文件和照片的相簿，右边正在看的那一个；什么都没选时是空状态。
public struct RootView: View {
	@Bindable var workspace: Workspace
	@State private var dropTargeted = false

	public init(workspace: Workspace) {
		self.workspace = workspace
	}

	public var body: some View {
		NavigationSplitView {
			Sidebar(workspace: workspace)
				.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
		} detail: {
			switch workspace.selection {
			case .album?:
				AlbumStack(photos: workspace.photos, open: workspace.openPhoto)
			case .photos?:
				PhotoAccessView(photos: workspace.photos) { workspace.showFirstAlbum() }
			default:
				if let doc = workspace.selected {
					DocumentView(doc: doc)
				} else {
					EmptyState(isTargeted: dropTargeted, open: workspace.showOpenPanel)
				}
			}
		}
		.dropDestination(for: URL.self) { urls, _ in
			workspace.open(urls)
			return !urls.isEmpty
		} isTargeted: { dropTargeted = $0 }
		.onPasteCommand(of: [.fileURL, .image, .pdf]) { _ in workspace.paste() }
		.alert(
			"打不开", isPresented: Binding(get: { workspace.problem != nil }, set: { if !$0 { workspace.problem = nil } })
		) {
			Button("知道了") { workspace.problem = nil }
		} message: {
			Text(workspace.problem ?? "")
		}
		.alert(
			"照片出了点事", isPresented: Binding(get: { workspace.photos.problem != nil }, set: { if !$0 { workspace.photos.problem = nil } })
		) {
			Button("知道了") { workspace.photos.problem = nil }
		} message: {
			Text(workspace.photos.problem ?? "")
		}
	}
}

/// 什么都没打开时：一句话说能干什么、怎么开始，一个主按钮。
struct EmptyState: View {
	var isTargeted: Bool
	var open: () -> Void

	var body: some View {
		ContentUnavailableView {
			Label("把图里的字拾出来", systemImage: "text.viewfinder")
		} description: {
			Text("打开图片或 PDF，认出的字能复制、能导出。\n也可以把文件拖进来，或按 ⌘V 粘贴截图。")
		} actions: {
			Button("打开…", action: open)
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
		}
		.overlay {
			if isTargeted {
				RoundedRectangle(cornerRadius: 10)
					.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
					.padding(16)
			}
		}
	}
}

/// 左栏：这次打开过的文件（打开过才有这一节），和照片的相簿。识别中标题前一个小转圈，出错一个红色感叹号，
/// 认完不出声、行尾只写页数或张数。
struct Sidebar: View {
	@Bindable var workspace: Workspace

	var body: some View {
		List(selection: $workspace.selection) {
			if !workspace.documents.isEmpty {
				Section("文件") {
					ForEach(workspace.documents) { doc in
						DocumentRow(doc: doc)
							.tag(SidebarItem.document(doc.id))
							.contextMenu {
								Button("从列表里移除") { workspace.remove(doc) }
							}
					}
				}
			}
			Section("照片") {
				if workspace.photos.access == .granted {
					ForEach(workspace.photos.albums) { album in
						AlbumRow(album: album, running: workspace.photos.run?.albumID == album.id)
							.tag(SidebarItem.album(album.id))
					}
				} else {
					HStack(spacing: 8) {
						Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary).frame(width: 16)
						Text("照片图库").fontWeight(.medium)
					}
					.tag(SidebarItem.photos)
				}
			}
		}
	}
}

struct DocumentRow: View {
	let doc: DocumentModel

	var body: some View {
		HStack(spacing: 8) {
			Group {
				switch doc.state {
				case .running:
					ProgressView().controlSize(.small)
				case .failed:
					Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help("出错了")
				default:
					Image(systemName: doc.isPDF ? "doc.text" : "photo").foregroundStyle(.secondary)
				}
			}
			.frame(width: 16)
			Text(doc.name)
				.fontWeight(.medium)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 4)
			if doc.totalPages > 1 {
				Text("\(doc.totalPages) 页")
					.font(.caption)
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
		}
	}
}
