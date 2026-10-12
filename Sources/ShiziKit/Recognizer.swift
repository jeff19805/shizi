import CoreGraphics
import Foundation
import OCRCore

/// 认字只在这一条串行队列上跑：系统的识别不能在一堆 Task 里同时同步调（会把 Swift 并发的协作线程占满、卡死，
/// 见 AGENTS.md「已知的坑」）；它本来也是一次只认一张，排队不会更慢。
public final class Recognizer: @unchecked Sendable {
	public static let shared = Recognizer()

	let queue = DispatchQueue(label: "拾字.识别", qos: .userInitiated)
	private let lock = NSLock()
	private var current: OCREngine

	public init(engine: OCREngine = .fromDefaultConfig()) {
		current = engine
	}

	var engine: OCREngine { lock.withLock { current } }

	/// 插件配置改了以后重读。
	public func reloadConfig() {
		lock.withLock { current = .fromDefaultConfig() }
	}

	/// 一页一页地认：认完一页在主线程回调一次，某一页出错只记下这一页、接着认下一页；`stop` 打开了就在页与页之间停下。
	func recognize(
		_ source: PageSource, pages: [Int], options: OCROptions, stop: StopFlag,
		onPage: @escaping @MainActor (Int, Result<PageResult, Error>) -> Void, onFinish: @escaping @MainActor () -> Void
	) {
		queue.async { [self] in
			let engine = self.engine
			// 同一份文件一页页认下来：中文优先时记住上一页是不是西文（见 RunMemory）。
			let memory = RunMemory()
			for n in pages {
				if stop.isStopped { break }
				let result: Result<PageResult, Error> = autoreleasepool {
					Result { try engine.runPage(source, page: n, options: options, memory: memory) }
				}
				DispatchQueue.main.async { MainActor.assumeIsolated { onPage(n, result) } }
			}
			DispatchQueue.main.async { MainActor.assumeIsolated { onFinish() } }
		}
	}

	/// 认一张图里的一块（框选识别）：`image` 是界面上那一页的图（拉正过的就是拉正后的图），`region` 相对它，0–1、左上为原点。
	func recognize(region: NRect, in image: CGImage, options: OCROptions, done: @escaping @MainActor (Result<PageResult, Error>) -> Void) {
		var o = options
		o.region = region
		o.rectify = .off
		queue.async { [self] in
			let engine = self.engine
			let result: Result<PageResult, Error> = autoreleasepool { Result { try engine.runPage(image, page: 1, options: o) } }
			DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
		}
	}
}

/// 停下的开关：识别队列在页与页之间看它。
final class StopFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var stopped = false

	func stop() { lock.withLock { stopped = true } }
	var isStopped: Bool { lock.withLock { stopped } }
}
