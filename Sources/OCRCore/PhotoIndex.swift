import Foundation
import SQLite3

/// 拾字认过的照片里的字，存在本机：~/Library/Application Support/拾字/照片.sqlite。拾字写，MCP 服务只读。
/// 一张照片一行，用照片图库给的编号（localIdentifier）对上原片；原片不复制、不落地。
/// 拾字和 MCP 服务是两个程序开同一个文件：用 WAL（读的时候不挡写），忙的时候等 3 秒再说。
public final class PhotoIndex: @unchecked Sendable {
	public enum Status: String, Sendable {
		/// 认出了字。
		case text
		/// 认了，没有字。
		case empty
		/// 原图只在 iCloud 上，这次没下下来（下载关了、空间不够、等太久）。下次还认。
		case icloud
		/// 出错了。下次还认。
		case failed
	}

	public struct Record: Sendable, Equatable {
		public var id: String
		/// 改动标记：修改时间、像素尺寸、识别版本，照片改过或识别改进过就重认。
		public var stamp: String
		public var revision: Int
		public var status: Status
		/// 给人看的字（不带位置标记）。
		public var text: String
		public var suspects: Int
		public var name: String?
		public var taken: Date?
		public var problem: String?
		public var updated: Date

		public init(
			id: String, stamp: String, status: Status, text: String = "", suspects: Int = 0, name: String? = nil, taken: Date? = nil,
			problem: String? = nil, updated: Date = Date()
		) {
			self.id = id
			self.stamp = stamp
			revision = PhotoIndex.revision
			self.status = status
			self.text = text
			self.suspects = suspects
			self.name = name
			self.taken = taken
			self.problem = problem
			self.updated = updated
		}
	}

	/// 识别改进了、要让认过的照片重认时，把它加一。
	public static let revision = 1

	public static var defaultPath: String {
		(NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/拾字/照片.sqlite")
	}

	/// 改动标记。版本放最后：要找「哪个版本认的」看单独那一列 revision 就行。
	public static func stamp(modified: Date?, width: Int, height: Int) -> String {
		"\(modified?.timeIntervalSince1970 ?? 0)|\(width)x\(height)|r\(revision)"
	}

	let db: OpaquePointer
	let lock = NSLock()

	/// `readOnly`：MCP 服务用，文件不存在就打不开（拾字还没认过照片）。
	/// 只读也是用读写方式打开、再禁写（query_only）：系统的 SQLite 用只读方式开 WAL 库，附带的 -wal、-shm 文件不在
	/// （比如从备份恢复的）就打不开（报 unable to open database file）；读写方式开会自己补上。
	public init(path: String = PhotoIndex.defaultPath, readOnly: Bool = false) throws {
		if !readOnly {
			try FileManager.default.createDirectory(
				at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
		}
		var handle: OpaquePointer?
		let flags = (readOnly ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
		guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
			if let handle { sqlite3_close(handle) }
			throw OCRError.unreadable(path)
		}
		db = handle
		sqlite3_busy_timeout(db, 3000)
		if readOnly {
			try exec("PRAGMA query_only = 1")
		} else {
			try exec("PRAGMA journal_mode=WAL")
			try exec(
				"""
				CREATE TABLE IF NOT EXISTS photos (
					id TEXT PRIMARY KEY, stamp TEXT NOT NULL, revision INTEGER NOT NULL, status TEXT NOT NULL,
					text TEXT NOT NULL DEFAULT '', flat TEXT NOT NULL DEFAULT '', suspects INTEGER NOT NULL DEFAULT 0, name TEXT,
					taken REAL, problem TEXT, updated REAL NOT NULL)
				""")
			try exec("CREATE INDEX IF NOT EXISTS photos_taken ON photos(taken)")
			// 分类的分数：一张照片按一套规矩（类别、判断标准）分一次存一行；source 是分的那段字的指纹，字变了就重分。
			try exec(
				"""
				CREATE TABLE IF NOT EXISTS labels (
					photo TEXT NOT NULL, rules TEXT NOT NULL, source TEXT NOT NULL, scores TEXT NOT NULL, updated REAL NOT NULL,
					PRIMARY KEY (photo, rules))
				""")
		}
	}

	deinit {
		sqlite3_close(db)
	}

	/// 认完了（有字或没字）而且照片没改过，就不用再认。原图没下下来的、出错的，下次还认。
	public func isDone(_ id: String, stamp: String) -> Bool {
		guard let r = record(id) else { return false }
		return r.stamp == stamp && (r.status == .text || r.status == .empty)
	}

	public func upsert(_ r: Record) throws {
		try run(
			"""
			INSERT INTO photos (id, stamp, revision, status, text, flat, suspects, name, taken, problem, updated)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
			ON CONFLICT(id) DO UPDATE SET stamp = ?2, revision = ?3, status = ?4, text = ?5, flat = ?6, suspects = ?7,
				name = COALESCE(?8, name), taken = COALESCE(?9, taken), problem = ?10, updated = ?11
			""",
			[r.id, r.stamp, r.revision, r.status.rawValue, r.text, Self.flatten(r.text), r.suspects, r.name, r.taken?.timeIntervalSince1970,
				r.problem, r.updated.timeIntervalSince1970])
	}

	/// 删掉几张的记录（照片图库里删了的、要重认的），分类的分数一起删。
	public func remove(_ ids: [String]) throws {
		for id in ids {
			try run("DELETE FROM photos WHERE id = ?1", [id])
			try run("DELETE FROM labels WHERE photo = ?1", [id])
		}
	}

	// MARK: 分类的分数

	/// 一张照片按一套规矩分出来的分数，和分的是哪段字（指纹）。
	public struct Scores: Sendable, Equatable {
		public var source: String
		public var scores: [String: Double]

		public init(source: String, scores: [String: Double]) {
			self.source = source
			self.scores = scores
		}
	}

	public func saveScores(photo: String, rules: String, _ s: Scores) throws {
		let data = try JSONSerialization.data(withJSONObject: s.scores, options: [.sortedKeys])
		try run(
			"""
			INSERT INTO labels (photo, rules, source, scores, updated) VALUES (?1, ?2, ?3, ?4, ?5)
			ON CONFLICT(photo, rules) DO UPDATE SET source = ?3, scores = ?4, updated = ?5
			""", [photo, rules, s.source, String(decoding: data, as: UTF8.self), Date().timeIntervalSince1970])
	}

	/// 按一套规矩分过的全部照片：编号 → 分数。
	public func scores(rules: String) -> [String: Scores] {
		lock.lock()
		defer { lock.unlock() }
		var out: [String: Scores] = [:]
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, "SELECT photo, source, scores FROM labels WHERE rules = ?1", -1, &stmt, nil) == SQLITE_OK else { return out }
		defer { sqlite3_finalize(stmt) }
		bind(stmt, [rules])
		while sqlite3_step(stmt) == SQLITE_ROW {
			func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
			let parsed = (try? JSONSerialization.jsonObject(with: Data(text(2).utf8))) as? [String: Any] ?? [:]
			out[text(0)] = Scores(source: text(1), scores: parsed.compactMapValues { ($0 as? NSNumber)?.doubleValue })
		}
		return out
	}

	public func record(_ id: String) -> Record? {
		query("SELECT \(Self.columns) FROM photos WHERE id = ?1", [id]).first
	}

	/// 按字找，新拍的在前。空格隔开的几个词都要有；不管空格换行、大小写、全角半角：
	/// 认出来的字常在词中间断行（「招商\n银行」），中英文之间有没有空格也不一定。
	public func search(_ text: String, limit: Int) -> [Record] {
		let terms = Self.terms(text)
		guard !terms.isEmpty else { return [] }
		let match = terms.indices.map { "instr(flat, ?\($0 + 2)) > 0" }.joined(separator: " AND ")
		return query(
			"SELECT \(Self.columns) FROM photos WHERE status = 'text' AND \(match) ORDER BY taken DESC, updated DESC LIMIT ?1",
			[max(1, limit) as Any?] + terms.map { $0 as Any? })
	}

	/// 要找的几个词（最多 8 个），跟存的时候一样压平。
	static func terms(_ query: String) -> [String] {
		Array(query.split(whereSeparator: \.isWhitespace).map { flatten(String($0)) }.filter { !$0.isEmpty }.prefix(8))
	}

	/// 搜的时候比的样子：去掉空白，大小写、全角半角都不分。
	static func flatten(_ s: String) -> String {
		s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).filter { !$0.isWhitespace }
	}

	/// 一张照片在库里的简况：网格的角标、相簿的数用，不带字（照片再多也很快）。
	public struct Brief: Sendable, Equatable {
		public var stamp: String
		public var status: Status
		public var problem: String?

		public init(stamp: String, status: Status, problem: String? = nil) {
			self.stamp = stamp
			self.status = status
			self.problem = problem
		}
	}

	/// 库里全部照片的简况：编号 → 简况。
	public func briefs() -> [String: Brief] {
		lock.lock()
		defer { lock.unlock() }
		var out: [String: Brief] = [:]
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, "SELECT id, stamp, status, problem FROM photos", -1, &stmt, nil) == SQLITE_OK else { return out }
		defer { sqlite3_finalize(stmt) }
		while sqlite3_step(stmt) == SQLITE_ROW {
			func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
			guard let id = text(0) else { continue }
			out[id] = Brief(stamp: text(1) ?? "", status: Status(rawValue: text(2) ?? "") ?? .failed, problem: text(3))
		}
		return out
	}

	/// 一共几张、其中有字的、原图没下下来的、出错的，最近一次是什么时候认的。
	public struct Stats: Sendable, Equatable {
		public var count = 0
		public var withText = 0
		public var inCloud = 0
		public var failed = 0
		public var newest: Date?
	}

	public func stats() -> Stats {
		lock.lock()
		defer { lock.unlock() }
		var s = Stats()
		var stmt: OpaquePointer?
		let sql = """
			SELECT COUNT(*), SUM(status = 'text'), SUM(status = 'icloud'), SUM(status = 'failed'), MAX(updated) FROM photos
			"""
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return s }
		defer { sqlite3_finalize(stmt) }
		if sqlite3_step(stmt) == SQLITE_ROW {
			s.count = Int(sqlite3_column_int64(stmt, 0))
			s.withText = Int(sqlite3_column_int64(stmt, 1))
			s.inCloud = Int(sqlite3_column_int64(stmt, 2))
			s.failed = Int(sqlite3_column_int64(stmt, 3))
			if sqlite3_column_type(stmt, 4) != SQLITE_NULL { s.newest = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)) }
		}
		return s
	}

	/// 在字里找要搜的第一个词用的正则：词里的字之间可以夹空白，跟搜的时候一样，断了行的也找得到。
	public static func matchPattern(_ query: String) -> String {
		let first = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
		return first.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
	}

	/// 字里第一个词附近的一段（前后各约 `width` 个字），换行换成空格；找不到就给开头一段。
	public static func snippet(_ text: String, around query: String, width: Int = 40) -> String {
		let flat = text.replacingOccurrences(of: "\n", with: " ")
		let pattern = matchPattern(query)
		guard !pattern.isEmpty, let r = flat.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
			return flat.count > width * 2 ? String(flat.prefix(width * 2)) + "…" : flat
		}
		let start = flat.index(r.lowerBound, offsetBy: -width, limitedBy: flat.startIndex) ?? flat.startIndex
		let end = flat.index(r.upperBound, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
		return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
	}

	// MARK: SQLite

	static let columns = "id, stamp, revision, status, text, suspects, name, taken, problem, updated"

	func exec(_ sql: String) throws {
		lock.lock()
		defer { lock.unlock() }
		guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw OCRError.recognition("照片库：\(String(cString: sqlite3_errmsg(db)))") }
	}

	func run(_ sql: String, _ args: [Any?]) throws {
		lock.lock()
		defer { lock.unlock() }
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw OCRError.recognition("照片库：\(String(cString: sqlite3_errmsg(db)))") }
		defer { sqlite3_finalize(stmt) }
		bind(stmt, args)
		guard sqlite3_step(stmt) == SQLITE_DONE else { throw OCRError.recognition("照片库：\(String(cString: sqlite3_errmsg(db)))") }
	}

	func query(_ sql: String, _ args: [Any?]) -> [Record] {
		lock.lock()
		defer { lock.unlock() }
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
		defer { sqlite3_finalize(stmt) }
		bind(stmt, args)
		var out: [Record] = []
		while sqlite3_step(stmt) == SQLITE_ROW {
			func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
			func date(_ i: Int32) -> Date? {
				sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
			}
			var r = Record(
				id: text(0) ?? "", stamp: text(1) ?? "", status: Status(rawValue: text(3) ?? "") ?? .failed, text: text(4) ?? "",
				suspects: Int(sqlite3_column_int64(stmt, 5)), name: text(6), taken: date(7), problem: text(8),
				updated: date(9) ?? Date(timeIntervalSince1970: 0))
			r.revision = Int(sqlite3_column_int64(stmt, 2))
			out.append(r)
		}
		return out
	}

	/// SQLite 要的「临时」标记：绑定的字它自己拷一份。
	static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

	func bind(_ stmt: OpaquePointer?, _ args: [Any?]) {
		for (i, arg) in args.enumerated() {
			let n = Int32(i + 1)
			switch arg {
			case let v as String: sqlite3_bind_text(stmt, n, v, -1, Self.transient)
			case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
			case let v as Double: sqlite3_bind_double(stmt, n, v)
			default: sqlite3_bind_null(stmt, n)
			}
		}
	}
}
