import Foundation
import Testing
@testable import OCRCore
@testable import ShiziKit

/// 假的分类插件：判断标准里的词出现在字里就给 0.9，不然 0.1；每问一次在 `log` 里记一行。
func fakeClassifier(log: String) throws -> PluginConfig {
	try fakePlugin(
		"""
		exec /usr/bin/python3 -c '
		import json, sys
		inp = json.load(sys.stdin)["input"]
		open("\(log)", "a").write("问\\n")
		print(json.dumps({"output": {"scores": {q["id"]: (0.9 if q["criteria"] in inp["text"] else 0.1) for q in inp["questions"]}}}))
		'
		""", hooks: ["classify"])
}

func lineCount(_ path: String) -> Int {
	((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
}

@MainActor @Test func 按字给相簿分类() async throws {
	let log = Fixtures.tempURL("log").path
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	for (i, id) in ["一", "二", "三", "四"].enumerated() {
		library.add(id, .local(Fixtures.text([id])), created: day.addingTimeInterval(Double(-60 * i)))
	}
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	let asset = library.assetList
	try index.upsert(PhotoIndex.Record(id: "一", stamp: asset[0].stamp, status: .text, text: "这是一张增值税发票"))
	try index.upsert(PhotoIndex.Record(id: "二", stamp: asset[1].stamp, status: .text, text: "明天下午开会议"))
	try index.upsert(PhotoIndex.Record(id: "三", stamp: asset[2].stamp, status: .empty))
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig(plugins: [try fakeClassifier(log: log)])))
	let defaults = try #require(UserDefaults(suiteName: "拾字测试-\(UUID().uuidString)"))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: recognizer, defaults: defaults)
	await waitFor { !photos.albums.isEmpty }
	photos.show(album: "all")
	#expect(photos.classifyRules == nil && photos.labelCounts.isEmpty, "没分过类：不放筛选条")
	#expect(photos.classifyPlugin?.name == "假插件" && photos.classifiable.map(\.id) == ["一", "二"], "只有认出字的能按字分")

	// 分类：只问有字的两张；没字、没认的算「没有字」。
	let source = "票据：发票\n会议：会议"
	let rules = try ClassifyRules.parse(mode: .topics, source: source)
	photos.classify(rules, source: source)
	#expect(photos.classifyRun?.total == 2)
	await waitFor { photos.classifyRun == nil }
	#expect(photos.labels(of: asset[0]) == ["票据"] && photos.labels(of: asset[1]) == ["会议"])
	#expect(photos.labels(of: asset[2]) == ["没有字"] && photos.labels(of: asset[3]) == ["没有字"] && photos.problem == nil)
	#expect(photos.labelCounts.map { "\($0.label)\($0.count)" } == ["票据1", "会议1", "待确认0", "没有字2"])
	#expect(lineCount(log) == 2 && photos.unclassifiedCount == 0)

	// 筛选：网格、翻张、全选都只走这一类。
	photos.labelFilter = "票据"
	#expect(photos.shownAssets.map(\.id) == ["一"] && photos.browseList.map(\.id) == ["一"])
	photos.selectAll()
	#expect(photos.selection == ["一"])

	// 再分一遍：分过、字没变的不问。
	photos.classify(rules, source: source)
	#expect(photos.classifyRun == nil && lineCount(log) == 2)

	// 重开拾字：记得上次的规矩和分数，筛选条还在。
	let again = PhotosModel(library: library, indexPath: path, recognizer: recognizer, defaults: defaults)
	await waitFor { !again.albums.isEmpty }
	again.show(album: "all")
	#expect(again.classifyRules == rules && again.labels(of: asset[0]) == ["票据"])

	// 字变了（重认过）：只重问那一张。
	try index.upsert(PhotoIndex.Record(id: "一", stamp: asset[0].stamp, status: .text, text: "一份租房合同"))
	again.classify(rules, source: source)
	#expect(again.classifyRun?.total == 1)
	await waitFor { again.classifyRun == nil }
	#expect(lineCount(log) == 3 && again.labels(of: asset[0]) == ["待确认"])

	// 按一句条件找：符合、待确认、不符合、没有字。
	let condition = try ClassifyRules.parse(mode: .condition, source: "会议")
	again.classify(condition, source: "会议")
	await waitFor { again.classifyRun == nil }
	#expect(again.labelCounts.map { "\($0.label)\($0.count)" } == ["符合条件1", "待确认0", "不符合条件1", "没有字2"])
	#expect(ClassifySettings.mode(defaults, .text) == .condition && ClassifySettings.conditionText(defaults, .text) == "会议")
	#expect(ClassifySettings.topicsText(defaults, .text) == source, "类别留着，切回来还是它")
}

@MainActor @Test func 分类连着没分成就先停() async throws {
	let library = FakePhotoLibrary()
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	for i in 0..<8 {
		library.add("图\(i)", .local(Fixtures.text(["图"])), created: Date(timeIntervalSince1970: Double(1000 - i)))
		try index.upsert(PhotoIndex.Record(id: "图\(i)", stamp: library.assetList[i].stamp, status: .text, text: "第 \(i) 张的字"))
	}
	let log = Fixtures.tempURL("log").path
	let broken = try fakePlugin("echo 问 >> \(log); cat > /dev/null; exit 3", hooks: ["classify"])
	let defaults = try #require(UserDefaults(suiteName: "拾字测试-\(UUID().uuidString)"))
	let photos = PhotosModel(
		library: library, indexPath: path, recognizer: Recognizer(engine: OCREngine(config: OCRConfig(plugins: [broken]))), defaults: defaults)
	await waitFor { !photos.albums.isEmpty }
	photos.show(album: "all")
	photos.classify(try ClassifyRules.parse(mode: .topics, source: "票据：发票"), source: "票据：发票")
	await waitFor { photos.classifyRun == nil }
	#expect(photos.problem?.hasPrefix("连着 3 张没分成，先停了") == true, "\(photos.problem ?? "")")
	#expect(photos.classifyScores.isEmpty && lineCount(log) < 8, "停了就不再问后面的：问了 \(lineCount(log)) 张")

	// 没有接了「分类」的插件：说清楚去哪儿开。
	let none = PhotosModel(library: library, indexPath: path, recognizer: Recognizer(engine: OCREngine(config: OCRConfig())), defaults: defaults)
	await waitFor { !none.albums.isEmpty }
	none.show(album: "all")
	none.classify(try ClassifyRules.parse(mode: .topics, source: "票据：发票"), source: "票据：发票")
	#expect(none.classifyRun == nil && none.problem?.contains("打开「分类照片」") == true)
}

/// 假的按画面分的插件：判断标准写「横」的，横图给 0.9；写「竖」的，竖图给 0.9；别的给 0.1。
/// 每问一次在 `log` 里记一行：发来的图长边几像素、是不是 JPEG。
func fakeImageClassifier(log: String) throws -> PluginConfig {
	try fakePlugin(
		"""
		exec /usr/bin/python3 -c '
		import base64, json, sys
		inp = json.load(sys.stdin)["input"]
		img = inp["image"]
		w, h = img["width"], img["height"]
		jpeg = img["type"] == "jpeg" and base64.b64decode(img["data"])[:2] == b"\\xff\\xd8"
		open("\(log)", "a").write("%d %s\\n" % (max(w, h), "jpeg" if jpeg else "other"))
		def p(c): return 0.9 if (c == "横" and w > h) or (c == "竖" and h > w) else 0.1
		print(json.dumps({"output": {"scores": {q["id"]: p(q["criteria"]) for q in inp["questions"]}}}))
		'
		""", hooks: ["classify"])
}

@MainActor @Test func 按画面给相簿分类() async throws {
	let log = Fixtures.tempURL("log").path
	let library = FakePhotoLibrary()
	let day = Date(timeIntervalSince1970: 1_790_000_000)
	// 最前面六张取不到预览图：只算它们没分成，不算「连不上」，后面的照分。算进去的话整批就停了：同时发四张，
	// 数到「连着三张」之前每没成一张又补发一张，停下时发出去的六张全是取不到图的，后面好的一张都轮不到。
	for i in 0..<6 { library.add("坏\(i)", .broken, created: day.addingTimeInterval(Double(-i))) }
	library.add("横", .local(Fixtures.text(["横"], width: 1600, height: 900)), created: day.addingTimeInterval(-60))
	library.add("竖", .cloud(Fixtures.text(["竖"], width: 600, height: 1200)), created: day.addingTimeInterval(-120))
	library.add("方", .local(Fixtures.text(["方"], width: 800, height: 800)), created: day.addingTimeInterval(-180))
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	let byID = { (id: String) in library.assetList.first { $0.id == id }! }
	// 「方」认过、没有字；别的都没认：按画面分不用先认字。
	try index.upsert(PhotoIndex.Record(id: "方", stamp: byID("方").stamp, status: .empty))
	let recognizer = Recognizer(engine: OCREngine(config: OCRConfig(plugins: [try fakeImageClassifier(log: log)])))
	let defaults = try #require(UserDefaults(suiteName: "拾字测试-\(UUID().uuidString)"))
	let photos = PhotosModel(library: library, indexPath: path, recognizer: recognizer, defaults: defaults)
	await waitFor { !photos.albums.isEmpty }
	photos.show(album: "all")
	#expect(photos.classifiable(.image).count == 9 && photos.classifiable(.text).isEmpty, "按画面分的是全部，按字分的一张没有")

	let source = "横图：横\n竖图：竖"
	let rules = try ClassifyRules.parse(mode: .topics, source: source, input: .image)
	#expect(rules.fingerprint != (try ClassifyRules.parse(mode: .topics, source: source)).fingerprint, "看字、看画面的分数各存各的")
	photos.classify(rules, source: source)
	#expect(photos.classifyRun?.total == 9)
	await waitFor { photos.classifyRun == nil }
	#expect(photos.labels(of: byID("横")) == ["横图"] && photos.labels(of: byID("竖")) == ["竖图"])
	#expect(photos.labels(of: byID("方")) == ["待确认"] && photos.labels(of: byID("坏0")) == nil)
	#expect(photos.labelCounts.map { "\($0.label)\($0.count)" } == ["横图1", "竖图1", "待确认1"], "按画面分没有「没有字」")
	#expect(photos.unclassifiedCount == 6)
	#expect(photos.problem == "有 6 张没分成，下次分类时再问：本机取不到这张的预览图", "\(photos.problem ?? "")")
	// 发的是缩到 360 像素的 JPEG；原图在 iCloud 上的（竖）也用本机的预览图，不下载。
	let sent = { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
	#expect(sent() == ["360 jpeg", "360 jpeg", "360 jpeg"] && library.log.isEmpty, "\(sent()) \(library.log)")
	#expect(ClassifySettings.input(defaults) == .image && ClassifySettings.topicsText(defaults, .image) == source)
	#expect(ClassifySettings.topicsText(defaults, .text) == ClassifyRules.defaultTopics, "看字的类别没动")

	// 再分一遍：分过、照片没改过的不问；取不到预览图的再试。
	photos.classify(rules, source: source)
	#expect(photos.classifyRun?.total == 6)
	await waitFor { photos.classifyRun == nil }
	#expect(sent().count == 3)

	// 照片改过：算没分，再分只问它。
	library.touch("横")
	photos.reloadAlbum()
	#expect(photos.labels(of: byID("横")) == nil && photos.unclassifiedCount == 7)
	photos.classify(rules, source: source)
	#expect(photos.classifyRun?.total == 7)
	await waitFor { photos.classifyRun == nil }
	#expect(sent().count == 4 && photos.labels(of: byID("横")) == ["横图"])

	// 重开拾字：记得上次是按画面分的。
	let again = PhotosModel(library: library, indexPath: path, recognizer: recognizer, defaults: defaults)
	await waitFor { !again.albums.isEmpty }
	again.show(album: "all")
	#expect(again.classifyRules == rules && again.labels(of: byID("竖")) == ["竖图"])
}
