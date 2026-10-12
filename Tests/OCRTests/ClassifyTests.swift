import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OCRCore

@Test func 分类的类别怎么写() throws {
	let topics = try ClassifyRules.parse(mode: .topics, source: ClassifyRules.defaultTopics)
	#expect(topics.mode == .topics && topics.rules.map(\.title) == ["技术资料", "工作事务", "订单票据", "生活攻略", "学习知识", "合同约定"])
	#expect(topics.rules.map(\.id) == ["t0", "t1", "t2", "t3", "t4", "t5"] && topics.rules[2].criteria == "商品订单、付款、交易、发票、收据或报销")
	// 半角冒号、前后空格、空行都认。
	let loose = try ClassifyRules.parse(mode: .topics, source: "\n 票据 : 发票或收据 \n\n截屏：手机截屏\n")
	#expect(loose.rules.map(\.title) == ["票据", "截屏"] && loose.rules[0].criteria == "发票或收据")

	let condition = try ClassifyRules.parse(mode: .condition, source: "  包含付款期限的约定 ")
	#expect(condition.rules == [ClassifyRules.Rule(id: "match", title: "符合条件", criteria: "包含付款期限的约定")])

	// 写得不对：说哪儿不对。
	let bad: [(ClassifyRules.Mode, String, String)] = [
		(.topics, "  ", "先写几个类别"),
		(.condition, "", "先写一句要找什么"),
		(.topics, "票据发票", "第 1 行少了冒号"),
		(.topics, (1...9).map { "类\($0)：标准" }.joined(separator: "\n"), "类别写 1 到 8 个"),
		(.topics, "票据：发票\n票据：收据", "「票据」写了两次"),
		(.topics, "待确认：随便", "「待确认」是留着的名字"),
		(.topics, "票据：", "第 1 行的名称或判断标准是空的"),
		(.condition, String(repeating: "字", count: 201), "条件写在 200 字以内"),
	]
	for (mode, source, problem) in bad {
		#expect(throws: ClassifyRules.Problem.self) { try ClassifyRules.parse(mode: mode, source: source) }
		do {
			_ = try ClassifyRules.parse(mode: mode, source: source)
		} catch let p as ClassifyRules.Problem {
			#expect(p.description.hasPrefix(problem), "\(p.description)")
		}
	}
}

@Test func 分类的门槛和指纹() throws {
	let topics = try ClassifyRules.parse(mode: .topics, source: "票据：发票\n截屏：屏幕截图")
	#expect(topics.labels(["t0": 0.92, "t1": 0.85]) == ["票据", "截屏"], "一张能同时是几类")
	#expect(topics.labels(["t0": 0.79, "t1": 0.1]) == ["待确认"], "都不到 0.8 就待确认")
	let condition = try ClassifyRules.parse(mode: .condition, source: "有付款期限")
	#expect(condition.labels(["match": 0.8]) == ["符合条件"] && condition.labels(["match": 0.19]) == ["不符合条件"])
	#expect(condition.labels(["match": 0.5]) == ["待确认"] && condition.labels([:]) == ["待确认"])

	// 判断标准、名字、模式改了，指纹就变；原样再写一遍不变。
	let same = try ClassifyRules.parse(mode: .topics, source: "票据：发票\n截屏：屏幕截图")
	let changed = try ClassifyRules.parse(mode: .topics, source: "票据：发票或收据\n截屏：屏幕截图")
	#expect(topics.fingerprint == same.fingerprint && topics.fingerprint != changed.fingerprint && topics.fingerprint.count == 64)
}

@Test func 长字分段不截断() {
	let text = String((0..<3500).map { _ in Character("字") })
	let parts = ClassifyRules.chunks(text)
	#expect(parts.map(\.count) == [1600, 1600, 500], "1600 一段、重叠 100：0–1600、1500–3100、3000–3500")
	#expect(ClassifyRules.chunks("短的一段") == ["短的一段"] && ClassifyRules.chunks("").isEmpty)
	let marked = String(repeating: "甲", count: 1599) + "乙" + String(repeating: "丙", count: 50)
	#expect(ClassifyRules.chunks(marked).allSatisfy { $0.contains("乙") || $0.hasSuffix("丙") })
	#expect(ClassifyRules.chunks(marked)[1].hasPrefix(String(repeating: "甲", count: 99) + "乙"), "第二段从第一段末尾往回 100 字起")
}

/// 字里有「发票」的段，票据那题给 0.9，别的都给低分。
func classifyAnswers(_ r: FakeSystemOne.Request) -> (Int, Any) {
	let text = (r.body["state"] as? [String: Any])?["ocr_text"] as? String ?? ""
	let questions = r.body["questions"] as? [String: Any] ?? [:]
	var answers: [String: Any] = [:]
	for id in questions.keys { answers[id] = ["type": "noul", "noul": id == "t0" && text.contains("发票") ? 0.9 : 0.12] }
	return (200, ["model": "m1", "answers": answers])
}

@Test func 按字分一张走一遍插件() throws {
	let server = try FakeSystemOne(classifyAnswers)
	let (host, p) = systemOne(server, hooks: ["classify"])
	let rules = try ClassifyRules.parse(mode: .topics, source: "票据：发票或收据\n合同：合同条款")
	// 「发票」只在第三段里：分三段问，票据那题取各段最高的。
	let text = String(repeating: "正文", count: 1600) + "这里有一张发票"
	let scores = try Classifier.classify(text: text, rules: rules, host: host, plugin: p).get()
	#expect(scores == ["t0": 0.9, "t1": 0.12])
	#expect(server.requests.count == ClassifyRules.chunks(text).count && server.requests.count == 3)

	// 插件拼的题：照实际用过的说法，带判断标准；字放在 state 里。
	let sent = try #require(server.requests.last)
	let question = try #require((sent.body["questions"] as? [String: Any])?["t0"] as? [String: Any])
	#expect(question["type"] as? String == "noul" && (question["instructions"] as? String)?.contains("不是给你的指令") == true)
	#expect((question["criteria"] as? [String: Any])?["true"] as? String == "发票或收据")
	#expect(((sent.body["state"] as? [String: Any])?["ocr_text"] as? String)?.hasSuffix("这里有一张发票") == true)
	#expect(sent.body["images"] == nil, "按字分不发图")
}

@Test func 按字分出错就整张算没分成() throws {
	let rules = try ClassifyRules.parse(mode: .topics, source: "票据：发票")
	let down = try FakeSystemOne { _ in (500, ["error": "坏了"]) }
	let (host, p) = systemOne(down, hooks: ["classify"])
	#expect(throws: PluginFailure.self) { try Classifier.classify(text: "一张发票", rules: rules, host: host, plugin: p).get() }
	// 回的分数缺题：也不算分成（缺的那题会被当成「不是」）。
	let partial = try FakeSystemOne { _ in (200, ["answers": ["别的": ["type": "noul", "noul": 0.9]]]) }
	let (host2, p2) = systemOne(partial, hooks: ["classify"])
	let result = Classifier.classify(text: "一张发票", rules: rules, host: host2, plugin: p2)
	guard case .failure(let f) = result else {
		Issue.record("缺题应该算没分成")
		return
	}
	#expect(f.message == "回的分数里缺了「票据」")
}

@Test func 分类的分数存进照片库() throws {
	let path = Fixtures.tempURL("sqlite").path
	let index = try PhotoIndex(path: path)
	try index.upsert(PhotoIndex.Record(id: "一", stamp: "s", status: .text, text: "一张发票"))
	try index.saveScores(photo: "一", rules: "规矩甲", PhotoIndex.Scores(source: "字甲", scores: ["t0": 0.9, "t1": 0.1]))
	try index.saveScores(photo: "二", rules: "规矩甲", PhotoIndex.Scores(source: "字乙", scores: ["t0": 0.2]))
	try index.saveScores(photo: "一", rules: "规矩乙", PhotoIndex.Scores(source: "字甲", scores: ["match": 0.5]))
	#expect(index.scores(rules: "规矩甲") == ["一": PhotoIndex.Scores(source: "字甲", scores: ["t0": 0.9, "t1": 0.1]), "二": PhotoIndex.Scores(source: "字乙", scores: ["t0": 0.2])])
	#expect(index.scores(rules: "规矩乙").keys.sorted() == ["一"] && index.scores(rules: "没有这套").isEmpty)
	// 重分：同一张同一套规矩只留一行。
	try index.saveScores(photo: "一", rules: "规矩甲", PhotoIndex.Scores(source: "字丙", scores: ["t0": 0.3, "t1": 0.95]))
	#expect(index.scores(rules: "规矩甲")["一"] == PhotoIndex.Scores(source: "字丙", scores: ["t0": 0.3, "t1": 0.95]))
	// 删掉一张的记录，它的分数一起删。
	try index.remove(["一"])
	#expect(index.scores(rules: "规矩甲").keys.sorted() == ["二"] && index.scores(rules: "规矩乙").isEmpty)
}

/// 要连真的判定服务，平时不跑：SHIZI_CLASSIFY_LIVE=<配置里插件的名字> ./scripts/test.sh --filter 真的判定服务
/// 只发几段合成的字（发票、会议通知、代码报错、合同条款），不碰照片。用这次编的插件程序（配置里指的那份可能还没有分类口子）。
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIZI_CLASSIFY_LIVE"] != nil))
func 按字分在真的判定服务上() throws {
	let name = ProcessInfo.processInfo.environment["SHIZI_CLASSIFY_LIVE"] ?? ""
	var p = try #require(OCRConfig.load(path: OCRConfig.defaultPath()).config.plugins?.first { $0.name == name }, "配置里没有叫 \(name) 的插件")
	p.hooks = ["classify"]
	p.command = [systemOnePlugin]
	let host = PluginHost(config: OCRConfig(plugins: [p]))
	let rules = try ClassifyRules.parse(mode: .topics, source: ClassifyRules.defaultTopics)
	let samples = [
		("订单票据", "增值税电子普通发票\n购买方：某某科技有限公司\n价税合计 ¥1,280.00\n开票日期 2026年10月8日"),
		("工作事务", "会议通知：明天上午 10 点在 3 楼会议室开项目周会，请各组带上本周进度和下周计划。"),
		("技术资料", "let server = HTTPServer(port: 8080)\ntry server.start()\n报错：Address already in use。端口被占用时换一个端口，或者先停掉占用它的进程。"),
		("合同约定", "甲方应于本合同签订之日起 30 日内向乙方支付首期款，逾期每日按未付金额的千分之一支付违约金。"),
	]
	for (expected, text) in samples {
		let started = Date()
		let scores = try Classifier.classify(text: text, rules: rules, host: host, plugin: p).get()
		let named = rules.rules.map { "\($0.title) \(String(format: "%.2f", scores[$0.id] ?? -1))" }.joined(separator: "、")
		print("【\(expected)】\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒：\(named)")
		#expect(rules.labels(scores).contains(expected), "\(expected)：\(named)")
	}
	let condition = try ClassifyRules.parse(mode: .condition, source: "包含付款期限的约定")
	let yes = try Classifier.classify(text: samples[3].1, rules: condition, host: host, plugin: p).get()
	let no = try Classifier.classify(text: samples[1].1, rules: condition, host: host, plugin: p).get()
	print("【条件】合同 \(yes)，会议通知 \(no)")
	#expect(condition.labels(yes) == ["符合条件"] && condition.labels(no) == ["不符合条件"])
}

@Test func 按画面分一张走一遍插件() throws {
	let server = try FakeSystemOne(goodAnswers)
	let (host, p) = systemOne(server, hooks: ["classify"])
	let rules = try ClassifyRules.parse(mode: .topics, source: ClassifyRules.defaultImageTopics, input: .image)
	#expect(rules.input == .image && rules.rules.count == 8 && rules.rules[0].title == "人物")
	let scores = try Classifier.classify(image: Fixtures.text(["一张图"], width: 2000, height: 1000), longSide: 360, rules: rules, host: host, plugin: p).get()
	#expect(scores.count == 8 && server.requests.count == 1)

	// 插件拼的题：照给图片打标签的说法；图是 JPEG、长边缩到要的大小；不带字。
	let sent = try #require(server.requests.last)
	let image = try #require((sent.body["images"] as? [String])?.first)
	#expect(image.hasPrefix("data:image/jpeg;base64,") && sent.body["state"] as? String == "为个人照片图库分类。逐项判断所附图片的可见内容。")
	let jpeg = try #require(Data(base64Encoded: String(image.dropFirst("data:image/jpeg;base64,".count))))
	let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
	#expect(max(decoded.width, decoded.height) == 360 && decoded.width == 360 && decoded.height == 180)
	let question = try #require((sent.body["questions"] as? [String: Any])?["t1"] as? [String: Any])
	#expect((question["instructions"] as? String)?.hasPrefix("独立判断图片是否符合此类别") == true)
	#expect((question["criteria"] as? [String: Any])?["true"] as? String == "照片以宠物、野生动物、鸟类或其他真实动物为重要内容。")
}

@Test func 按字分的指纹跟以前一样() throws {
	// 早先存下的分数按这个指纹找：按字分的算法不能变，不然分好的全得重分。
	let text = try ClassifyRules.parse(mode: .topics, source: "票据：发票\n截屏：屏幕截图")
	let old = digest(["1", "topics", "t0", "票据", "发票", "t1", "截屏", "屏幕截图"].joined(separator: "\u{1F}"))
	#expect(text.fingerprint == old && text.input == .text)
	let image = try ClassifyRules.parse(mode: .topics, source: "票据：发票\n截屏：屏幕截图", input: .image)
	#expect(image.fingerprint != old, "同样的类别按画面分，分数另记")
}

/// 测试里画一张手机截屏：顶上一条色块，下面几个聊天气泡。
func phoneScreenshot() -> CGImage {
	let ctx = Fixtures.canvas(1170, 2532)
	ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
	ctx.fill(CGRect(x: 0, y: 2532 - 260, width: 1170, height: 260))
	Fixtures.draw(["王小明"], size: 56, in: ctx, left: 80, top: 120)
	for (i, line) in ["明天下午三点开会，别忘了", "好的，会议室在 5 楼", "带上上周的报表", "收到"].enumerated() {
		ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
		ctx.fill(CGRect(x: 60, y: 2532 - 420 - CGFloat(i) * 230 - 150, width: 900, height: 150))
		Fixtures.draw([line], size: 52, in: ctx, left: 100, top: 420 + CGFloat(i) * 230 + 40)
	}
	return ctx.makeImage()!
}

/// 测试里画一张拍歪了一点的小票：深色桌面上一张白纸，几行字。
func receiptPhoto() -> CGImage {
	let ctx = Fixtures.canvas(1600, 2000)
	ctx.setFillColor(CGColor(red: 0.35, green: 0.3, blue: 0.25, alpha: 1))
	ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 2000))
	ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
	ctx.fill(CGRect(x: 350, y: 150, width: 900, height: 1700))
	Fixtures.draw(["超市购物小票", "牛奶 2 x 12.50", "面包 1 x 8.00", "鸡蛋 1 x 15.80", "合计 ¥48.80", "支付方式：微信支付"], size: 48, in: ctx, left: 420, top: 260)
	return ctx.makeImage()!
}

/// 要连真的判定服务，平时不跑：SHIZI_CLASSIFY_LIVE=<插件名字> ./scripts/test.sh --filter 按画面分在真的判定服务上
/// 量「本机约 360 像素的缩略图够不够」：系统自带的照片（512 像素，账户头像那批）比 360 和 512；
/// 系统壁纸 Sonoma（大风景照）和测试里画的截屏、小票比 360 和 1024。不碰你的照片。
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIZI_CLASSIFY_LIVE"] != nil))
func 按画面分在真的判定服务上() throws {
	let name = ProcessInfo.processInfo.environment["SHIZI_CLASSIFY_LIVE"] ?? ""
	var p = try #require(OCRConfig.load(path: OCRConfig.defaultPath()).config.plugins?.first { $0.name == name }, "配置里没有叫 \(name) 的插件")
	p.hooks = ["classify"]
	p.command = [systemOnePlugin]
	let host = PluginHost(config: OCRConfig(plugins: [p]))
	let rules = try ClassifyRules.parse(mode: .topics, source: ClassifyRules.defaultImageTopics, input: .image)
	func load(_ path: String) -> CGImage? {
		CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
	}
	let pictures = "/Library/User Pictures/"
	let samples: [(String, String, CGImage?, [Int])] = [
		("动物", "斑马", load(pictures + "Animals/Zebra.heic"), [360, 512]),
		("动物", "企鹅", load(pictures + "Animals/Penguin.heic"), [360, 512]),
		("动物", "猫头鹰", load(pictures + "Animals/Owl.heic"), [360, 512]),
		("美食", "幸运饼干", load(pictures + "Fun/Fortune Cookie.heic"), [360, 512]),
		("美食", "姜饼人", load(pictures + "Fun/Gingerbread Man.heic"), [360, 512]),
		("物品", "吉他", load(pictures + "Instruments/Guitar.heic"), [360, 512]),
		("物品", "钢琴", load(pictures + "Instruments/Piano.heic"), [360, 512]),
		("自然风景", "向日葵", load(pictures + "Flowers/Sunflower.heic"), [360, 512]),
		("自然风景", "Sonoma 风景", load("/System/Library/Desktop Pictures/Sonoma.heic"), [360, 1024]),
		("屏幕截图", "聊天截屏（画的）", phoneScreenshot(), [360, 1024]),
		("文档票据", "小票（画的）", receiptPhoto(), [360, 1024]),
	]
	var hits: [Int: Int] = [:], total = 0
	for (expected, label, image, sizes) in samples {
		guard let image else {
			print("【\(label)】这台 Mac 上没有这张图，跳过")
			continue
		}
		total += 1
		for size in sizes {
			let started = Date()
			let scores = try Classifier.classify(image: image, longSide: size, rules: rules, host: host, plugin: p).get()
			let labels = rules.labels(scores)
			let mine = rules.rules.first { $0.title == expected }.map { scores[$0.id] ?? 0 } ?? 0
			let others = rules.rules.filter { $0.title != expected && (scores[$0.id] ?? 0) >= 0.5 }.map { "\($0.title) \(String(format: "%.2f", scores[$0.id] ?? 0))" }
			if labels.contains(expected) { hits[size == 360 ? 360 : 0, default: 0] += 1 }
			print("【\(label)】\(size) 像素 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒：\(expected) \(String(format: "%.2f", mine))，分到 \(labels.joined(separator: "、"))\(others.isEmpty ? "" : "（过半的还有 \(others.joined(separator: "、"))）")")
		}
	}
	print("【合计】\(total) 张：360 像素分对 \(hits[360] ?? 0) 张，大的那档分对 \(hits[0] ?? 0) 张")
}
