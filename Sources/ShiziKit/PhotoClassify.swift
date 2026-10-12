import Foundation
import OCRCore

/// 一批照片分到哪了。
public struct ClassifyProgress: Equatable {
	/// 这批要问几张（分过、字没变的不算在里面）。
	public let total: Int
	/// 问完了（含没分成的）几张。
	public var done = 0
	public var failed = 0
	/// 最近一次没分成的原因。
	public var lastProblem: String?
	public var stopping = false
}

/// 分类的设置：看字还是看画面、上次用的分法和写的类别、条件。下次打开还是它，网格上的筛选也按它。
/// 按字、按画面的类别和条件各记各的（默认类别也不一样）。
enum ClassifySettings {
	static let input = "拾字.分类.看什么"
	static let mode = "拾字.分类.方式"
	static let topics = "拾字.分类.类别"
	static let condition = "拾字.分类.条件"
	static let imageMode = "拾字.分类.画面方式"
	static let imageTopics = "拾字.分类.画面类别"
	static let imageCondition = "拾字.分类.画面条件"
	/// 分过类没有：没分过就不在网格上放筛选条。
	static let used = "拾字.分类.用过"

	static func input(_ d: UserDefaults) -> ClassifyRules.Input { ClassifyRules.Input(rawValue: d.string(forKey: input) ?? "") ?? .text }
	static func mode(_ d: UserDefaults, _ i: ClassifyRules.Input) -> ClassifyRules.Mode {
		ClassifyRules.Mode(rawValue: d.string(forKey: i == .image ? imageMode : mode) ?? "") ?? .topics
	}
	static func topicsText(_ d: UserDefaults, _ i: ClassifyRules.Input) -> String {
		d.string(forKey: i == .image ? imageTopics : topics) ?? (i == .image ? ClassifyRules.defaultImageTopics : ClassifyRules.defaultTopics)
	}
	static func conditionText(_ d: UserDefaults, _ i: ClassifyRules.Input) -> String { d.string(forKey: i == .image ? imageCondition : condition) ?? "" }

	/// 上次分类用的规矩；没分过、或者存的写坏了，是 nil。
	static func saved(_ d: UserDefaults) -> ClassifyRules? {
		guard d.bool(forKey: used) else { return nil }
		let i = input(d)
		let m = mode(d, i)
		return try? ClassifyRules.parse(mode: m, source: m == .topics ? topicsText(d, i) : conditionText(d, i), input: i)
	}

	static func save(_ rules: ClassifyRules, source: String, _ d: UserDefaults) {
		let image = rules.input == .image
		d.set(rules.input.rawValue, forKey: input)
		d.set(rules.mode.rawValue, forKey: image ? imageMode : mode)
		d.set(source, forKey: rules.mode == .topics ? (image ? imageTopics : topics) : (image ? imageCondition : condition))
		d.set(true, forKey: used)
	}
}

extension PhotosModel {
	/// 没认出字的照片按字分不了，筛选条上单独一项。
	public static let noText = String(localized: "没有字")

	/// 分类用哪个插件：配置里开着、接了「分类」的第一个。
	public var classifyPlugin: PluginConfig? { recognizer.engine.host.plugins(for: "classify").first }

	/// 这个相簿里能分的：按字分是认出了字的；按画面分是全部（不用先认字）。`input` 不给就照正在用的规矩。
	public func classifiable(_ input: ClassifyRules.Input? = nil) -> [PhotoAsset] {
		(input ?? classifyRules?.input ?? .text) == .image ? assets : assets.filter { status(of: $0) == .text }
	}

	public var classifiable: [PhotoAsset] { classifiable(nil) }

	/// 这张分到哪几类（按正在用的规矩）：按字分时没认出字的是「没有字」；还没分的是 nil。
	public func labels(of asset: PhotoAsset) -> [String]? {
		guard let rules = classifyRules else { return nil }
		if rules.input == .text, status(of: asset) != .text { return [Self.noText] }
		guard let s = classifyScores[asset.id], rules.input == .text || s.source == asset.stamp else { return nil }
		return rules.labels(s.scores)
	}

	/// 筛选条上的每一项和这个相簿里有几张：类别照写的顺序，后面是待确认、没有字（一句条件时是符合、待确认、不符合、没有字）。
	public var labelCounts: [(label: String, count: Int)] {
		guard let rules = classifyRules else { return [] }
		var counts: [String: Int] = [:]
		for asset in assets {
			for label in labels(of: asset) ?? [] { counts[label, default: 0] += 1 }
		}
		let order =
			rules.mode == .condition
			? [ClassifyRules.matched, ClassifyRules.undecided, ClassifyRules.unmatched]
			: rules.rules.map(\.title) + [ClassifyRules.undecided]
		return (order + (rules.input == .text ? [Self.noText] : [])).map { ($0, counts[$0] ?? 0) }
	}

	/// 网格里显示的：选了某一类就只看这一类。
	public var shownAssets: [PhotoAsset] {
		guard let filter = labelFilter else { return assets }
		return assets.filter { labels(of: $0)?.contains(filter) == true }
	}

	/// 这个相簿里能分、按正在用的规矩还没分的（按画面分时照片改过的也算）有几张。
	public var unclassifiedCount: Int {
		classifiable.filter { labels(of: $0) == nil }.count
	}

	/// 打开相簿、重列以后：读上次用的规矩和它的分数。
	func loadClassification() {
		classifyRules = ClassifySettings.saved(defaults)
		classifyScores = classifyRules.flatMap { index?.scores(rules: $0.fingerprint) } ?? [:]
		if let filter = labelFilter, !labelCounts.contains(where: { $0.label == filter }) { labelFilter = nil }
	}

	/// 按这套规矩分这个相簿：按字分只分认出字的，按画面分全部；分过、字（照片）没变的跳过；几张一起问。
	/// `source` 是人写的原文，存下来下次还用它。
	public func classify(_ rules: ClassifyRules, source: String) {
		guard classifyRun == nil, let index else { return }
		guard let plugin = classifyPlugin else {
			problem = String(localized: "还没有能分类的判定插件：在「设置 › 判定插件」里改一个插件，打开「分类照片」。")
			return
		}
		ClassifySettings.save(rules, source: source, defaults)
		classifyRules = rules
		classifyScores = index.scores(rules: rules.fingerprint)
		labelFilter = nil
		var work: [ClassifyBatch.Work] = []
		for asset in classifiable(rules.input) {
			if rules.input == .image {
				// 按画面分：照片没改过（改动标记一样）就不重问。
				if classifyScores[asset.id]?.source == asset.stamp { continue }
				work.append(ClassifyBatch.Work(asset: asset, text: nil, source: asset.stamp))
				continue
			}
			guard let text = index.record(asset.id)?.text, !text.isEmpty else { continue }
			let source = digest(text)
			if classifyScores[asset.id]?.source == source { continue }
			work.append(ClassifyBatch.Work(asset: asset, text: text, source: source))
		}
		guard !work.isEmpty else { return }
		let flag = StopFlag()
		classifyStop = flag
		classifyRun = ClassifyProgress(total: work.count)
		let batch = ClassifyBatch(
			work: work, rules: rules, host: recognizer.engine.host, plugin: plugin, library: library, index: index, stop: flag,
			onPhoto: { [weak self] id, result in
				guard let self, self.classifyStop === flag else { return }
				self.classifyRun?.done += 1
				switch result {
				case .success(let scores): self.classifyScores[id] = scores
				case .failure(let f):
					self.classifyRun?.failed += 1
					self.classifyRun?.lastProblem = f.message
				}
			},
			onFinish: { [weak self] gaveUp in
				guard let self, self.classifyStop === flag else { return }
				if let run = self.classifyRun, run.failed > 0 {
					let reason = run.lastProblem ?? String(localized: "插件没说原因")
					self.problem =
						gaveUp
						? String(localized: "连着 \(ClassifyBatch.failureLimit) 张没分成，先停了：\(reason)")
						: String(localized: "有 \(run.failed) 张没分成，下次分类时再问：\(reason)")
				}
				self.classifyRun = nil
				self.classifyStop = nil
			})
		batch.start()
	}

	public func stopClassify() {
		guard classifyRun != nil else { return }
		classifyStop?.stop()
		classifyRun?.stopping = true
	}

	/// 分类会把字（或缩小的照片）发到哪：System One 插件写地址，别的写插件名字。
	public var classifyDestination: String? {
		guard let plugin = classifyPlugin else { return nil }
		if let url = plugin.env?["SYSTEMONE_URL"], let host = URL(string: url)?.host { return host }
		return plugin.name
	}
}

/// 一批照片分类：几张一起问插件（不占识别队列：只发字或小图、等回答，不用系统的文字识别），问完一张存一张。
/// 连着几张问不成（多半是连不上判定服务）就不再问了，剩下的下次分类再问；取不到预览图的只算那一张没分成，不算在里头。
final class ClassifyBatch: @unchecked Sendable {
	struct Work: Sendable {
		let asset: PhotoAsset
		/// 按字分时是认出的字；按画面分时是 nil（到时候取预览图）。
		let text: String?
		/// 这次分的东西的指纹：按字分是字的指纹，按画面分是照片的改动标记；变了就得重问。
		let source: String
		var id: String { asset.id }
	}

	/// 连着这么多张没分成就停：服务挂了时每张都白等到超时。
	static let failureLimit = 3
	/// 一次同时问几张：判定服务忙时会排队，问多了也快不了。
	static let concurrency = 4
	/// 按画面分时，照片缩到长边这么大发过去：缩到这么小，分得也不比大图差，图小、发得快；
	/// 本机的预览图就够，不用从 iCloud 下原图。
	static let previewPixels = 360

	let rules: ClassifyRules
	let host: PluginHost
	let plugin: PluginConfig
	let library: PhotoLibrary
	let index: PhotoIndex
	let stop: StopFlag
	let onPhoto: @MainActor (String, Result<PhotoIndex.Scores, PluginFailure>) -> Void
	let onFinish: @MainActor (Bool) -> Void

	private let lock = NSLock()
	private var pending: [Work]
	private var inFlight = 0
	private var failuresInRow = 0
	private var finished = false

	init(
		work: [Work], rules: ClassifyRules, host: PluginHost, plugin: PluginConfig, library: PhotoLibrary, index: PhotoIndex, stop: StopFlag,
		onPhoto: @escaping @MainActor (String, Result<PhotoIndex.Scores, PluginFailure>) -> Void, onFinish: @escaping @MainActor (Bool) -> Void
	) {
		pending = work
		self.rules = rules
		self.host = host
		self.plugin = plugin
		self.library = library
		self.index = index
		self.stop = stop
		self.onPhoto = onPhoto
		self.onFinish = onFinish
	}

	func start() {
		for _ in 0..<Self.concurrency { next() }
	}

	/// 分一张。第二个值：问没问到插件（取不到预览图时没问，不算「连不上」）。
	private func classify(_ work: Work) -> (Result<PhotoIndex.Scores, PluginFailure>, Bool) {
		let scores: Result<[String: Double], PluginFailure>
		if let text = work.text {
			scores = Classifier.classify(text: text, rules: rules, host: host, plugin: plugin)
		} else {
			let pixels = Self.previewPixels
			switch autoreleasepool(invoking: { library.preview(for: work.asset, pixels: pixels, timeout: 30) }) {
			case .image(let image):
				scores = Classifier.classify(image: image, longSide: pixels, rules: rules, host: host, plugin: plugin)
			case .inCloud, .timedOut, .failed:
				let failure = PluginFailure(plugin: String(localized: "照片图库"), message: String(localized: "本机取不到这张的预览图"))
				return (.failure(failure), false)
			}
		}
		return (scores.map { PhotoIndex.Scores(source: work.source, scores: $0) }, true)
	}

	/// 再发一张；没得发了、而且发出去的都回来了，就收尾（只收一次）。
	private func next() {
		lock.lock()
		let gaveUp = failuresInRow >= Self.failureLimit
		if stop.isStopped || gaveUp || pending.isEmpty {
			let done = inFlight == 0 && !finished
			if done { finished = true }
			lock.unlock()
			if done { DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinish(gaveUp) } } }
			return
		}
		let work = pending.removeFirst()
		inFlight += 1
		lock.unlock()
		DispatchQueue.global(qos: .userInitiated).async {
			let (result, askedPlugin) = self.classify(work)
			if case .success(let scores) = result { try? self.index.saveScores(photo: work.id, rules: self.rules.fingerprint, scores) }
			self.lock.lock()
			self.inFlight -= 1
			if case .success = result {
				self.failuresInRow = 0
			} else if askedPlugin {
				self.failuresInRow += 1
			}
			self.lock.unlock()
			DispatchQueue.main.async { MainActor.assumeIsolated { self.onPhoto(work.id, result) } }
			self.next()
		}
	}
}
