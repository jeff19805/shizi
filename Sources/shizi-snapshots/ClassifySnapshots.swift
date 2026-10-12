import AppKit
import OCRCore
import ShiziKit
import SwiftUI

/// 照片分类的几张截图：先把样例相簿真的认一遍，再用一个示例分类插件真的分一遍，然后拍分完的网格、只看一类、「分类」那一小窗；
/// 再按画面分一遍，拍网格和看画面时的小窗。不碰真的照片图库，也不连判定服务。
/// 示例插件不会看图，只装个样子：按字分时，判断标准里用「、」隔开的词，字里有就算是；按画面分时按图的长宽比，
/// 细长的算屏幕截图、略高的算文档票据、横的算自然风景（样例里正好是这三种图）。
@MainActor
func classifySnapshots() {
	let script = out.appendingPathComponent("示例分类插件.py")
	try? """
		#!/usr/bin/python3
		import json, sys
		inp = json.load(sys.stdin)["input"]
		if "image" in inp:
		    r = inp["image"]["height"] / inp["image"]["width"]
		    kind = "屏幕截图" if r > 1.8 else "收据" if r > 1.1 else "自然景观"
		    def score(criteria):
		        return 0.9 if kind in criteria else 0.1
		else:
		    def score(criteria):
		        return 0.9 if any(w and w in inp["text"] for w in criteria.split("、")) else 0.1
		print(json.dumps({"output": {"scores": {q["id"]: score(q["criteria"]) for q in inp["questions"]}}}))
		""".write(to: script, atomically: true, encoding: .utf8)
	try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
	let plugin = PluginConfig(name: "示例插件", command: [script.path], hooks: ["classify"], env: ["SYSTEMONE_URL": "http://clef.local:8000"])
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig(plugins: [plugin])))
	let suite = "拾字截图-分类"
	UserDefaults.standard.removePersistentDomain(forName: suite)
	let defaults = UserDefaults(suiteName: suite) ?? .standard
	let photos = PhotosModel(
		library: SamplePhotoLibrary(access: .granted), indexPath: freshIndexPath("分类用的照片库.sqlite"), recognizer: recognizer, defaults: defaults)
	let ws = Workspace(recognizer: recognizer, photos: photos)
	wait(5) { !photos.albums.isEmpty }
	ws.selection = .album("最近项目")
	photos.recognizeAlbum()
	wait(60) { photos.run == nil }
	let source = "票据：发票、小票、订单\n出行：地铁、步行、停车\n日程：开会、复诊、报告"
	if let rules = try? ClassifyRules.parse(mode: .topics, source: source) { photos.classify(rules, source: source) }
	wait(30) { photos.classifyRun == nil }
	snapshot("24-分类结果", RootView(workspace: ws))
	photos.labelFilter = "票据"
	snapshot("25-只看一类", RootView(workspace: ws))
	photos.labelFilter = nil
	snapshot("26-分类小窗", size: CGSize(width: 520, height: 400), fit: true, ClassifySheetPreview(photos: photos))

	// 按画面分：用默认的类别；没有「没有字」那一项。分完小窗打开就是「看画面」。
	if let rules = try? ClassifyRules.parse(mode: .topics, source: ClassifyRules.defaultImageTopics, input: .image) {
		photos.classify(rules, source: ClassifyRules.defaultImageTopics)
	}
	wait(30) { photos.classifyRun == nil }
	snapshot("27-按画面分", RootView(workspace: ws))
	snapshot("28-分类小窗-看画面", size: CGSize(width: 520, height: 400), fit: true, ClassifySheetPreview(photos: photos))
}
