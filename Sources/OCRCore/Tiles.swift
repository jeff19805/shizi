import CoreGraphics
import Foundation

/// 大图小字：切成边长约 1000 像素、互相重叠的方块逐块细认，再把接缝处切开的行拼回去。
///
/// 为什么是方块：很宽的长条（不管是「只认这一块」还是真裁成小图），上面的小字时而全对、
/// 时而一行不出；边长 1000 左右的方块才稳定（大图上的小字整张认几乎一个不出，切成方块基本都认得出）。
/// 方块的代价是会把满幅长行切成碎片，所以：
/// - 被上下接缝切到的行丢掉：重叠比一行高，它在上下相邻那块里是完整的；
/// - 被左右接缝切到的行是碎片：在两块重叠区的中线处，按每个字的位置切开再接上。
public enum Tiles {
	public static let maxSide = 1000.0
	public static let minOverlapPixels = 96.0

	public struct Tile: Sendable {
		public var rect: NRect
		public var row: Int
		public var col: Int
	}

	public static func grid(width: Int, height: Int) -> (tiles: [Tile], rows: Int, cols: Int) {
		let W = Double(width), H = Double(height)
		let cols = max(1, Int((W / maxSide).rounded(.up)))
		let rows = max(1, Int((H / maxSide).rounded(.up)))
		let ovx = max(minOverlapPixels, 0.12 * W / Double(cols)) / W
		let ovy = max(minOverlapPixels, 0.12 * H / Double(rows)) / H
		var tiles: [Tile] = []
		for r in 0..<rows {
			for c in 0..<cols {
				let x0 = c == 0 ? 0 : Double(c) / Double(cols) - ovx / 2
				let x1 = c == cols - 1 ? 1 : Double(c + 1) / Double(cols) + ovx / 2
				let y0 = r == 0 ? 0 : Double(r) / Double(rows) - ovy / 2
				let y1 = r == rows - 1 ? 1 : Double(r + 1) / Double(rows) + ovy / 2
				tiles.append(Tile(rect: NRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), row: r, col: c))
			}
		}
		return (tiles, rows, cols)
	}

	/// 逐块认完合并。返回合并后的行和切法（如 "3x2"，列×行）。
	public static func recognize(_ image: CGImage, options: LineOptions) throws -> (lines: [OCRLine], grid: String) {
		let g = grid(width: image.width, height: image.height)
		let perTile = try recognizeLines(image, regions: g.tiles.map(\.rect), options: options, charCentersNearEdges: true)
		let merged = merge(perTile, tiles: g.tiles, rows: g.rows, cols: g.cols, width: image.width, height: image.height)
		return (merged, "\(g.cols)x\(g.rows)")
	}

	struct Piece {
		var line: OCRLine
		var tile: Tile
		var cutLeft: Bool
		var cutRight: Bool
	}

	static func merge(_ perTile: [[OCRLine]], tiles: [Tile], rows: Int, cols: Int, width: Int, height: Int) -> [OCRLine] {
		let W = Double(width), H = Double(height)
		var complete: [OCRLine] = []
		var pieces: [Piece] = []
		for (t, lines) in zip(tiles, perTile) {
			for l in lines {
				let lineHpx = l.box.h * H
				let epsX = max(3, 0.5 * lineHpx) / W
				let epsY = max(2, 0.25 * lineHpx) / H
				// 贴着块内侧的上边或下边：被上下接缝切到了，邻块里有完整的。
				if (t.row > 0 && l.box.y <= t.rect.y + epsY) || (t.row < rows - 1 && l.box.maxY >= t.rect.maxY - epsY) { continue }
				let cutLeft = t.col > 0 && l.box.x <= t.rect.x + epsX
				let cutRight = t.col < cols - 1 && l.box.maxX >= t.rect.maxX - epsX
				if cutLeft || cutRight {
					pieces.append(Piece(line: l, tile: t, cutLeft: cutLeft, cutRight: cutRight))
				} else {
					complete.append(l)
				}
			}
		}
		// 从左往右接：每段碎片找右边相邻块里、同一行高度上、跟它在重叠区交叠的那段。
		var alive = Array(repeating: true, count: pieces.count)
		var joined: [OCRLine] = []
		for i in pieces.indices.sorted(by: { pieces[$0].tile.col < pieces[$1].tile.col }) where alive[i] {
			alive[i] = false
			var cur = pieces[i]
			while cur.cutRight, let j = partner(of: cur, in: pieces, alive: alive) {
				alive[j] = false
				cur = join(cur, pieces[j])
			}
			joined.append(cur.line)
		}
		return dedupe(complete + joined)
	}

	static func partner(of a: Piece, in pieces: [Piece], alive: [Bool]) -> Int? {
		var best: (Int, Double)?
		for (j, b) in pieces.enumerated() where alive[j] && b.cutLeft && b.tile.col == a.tile.col + 1 && b.tile.row == a.tile.row {
			let vOverlap = min(a.line.box.maxY, b.line.box.maxY) - max(a.line.box.y, b.line.box.y)
			guard vOverlap >= 0.5 * min(a.line.box.h, b.line.box.h), b.line.box.x < a.line.box.maxX else { continue }
			if best == nil || vOverlap > best!.1 { best = (j, vOverlap) }
		}
		return best?.0
	}

	/// 在两块重叠区的中线处切开：左段留中线左边的字，右段留中线右边的字。
	static func join(_ a: Piece, _ b: Piece) -> Piece {
		let seam = (b.tile.rect.x + a.tile.rect.maxX) / 2
		let left = Array(a.line.text), right = Array(b.line.text)
		let lc = centers(a.line), rc = centers(b.line)
		let keepLeft = left.indices.filter { lc[$0] < seam }
		let keepRight = right.indices.filter { rc[$0] >= seam }
		var leftPart = keepLeft.map { (left[$0], lc[$0]) }
		var rightPart = keepRight.map { (right[$0], rc[$0]) }
		// 接口两边的空格多半是被切了半个的字认出来的（不然「2026」会拼成「202 6」）：只有两边都是西文字母时才留一个。
		while leftPart.last?.0.isWhitespace == true { leftPart.removeLast() }
		while rightPart.first?.0.isWhitespace == true { rightPart.removeFirst() }
		let hadSpace = leftPart.count < keepLeft.count || rightPart.count < keepRight.count
		if hadSpace, let l = leftPart.last?.0, let r = rightPart.first?.0, l.isASCII && l.isLetter, r.isASCII && r.isLetter {
			leftPart.append((" ", seam))
		}
		var line = a.line
		line.text = String(leftPart.map(\.0) + rightPart.map(\.0))
		line.charCenters = leftPart.map(\.1) + rightPart.map(\.1)
		line.confidence = min(a.line.confidence, b.line.confidence)
		line.box = a.line.box.union(b.line.box)
		line.quad = [a.line.quad[0], b.line.quad[1], b.line.quad[2], a.line.quad[3]]
		return Piece(line: line, tile: b.tile, cutLeft: a.cutLeft, cutRight: b.cutRight)
	}

	/// 系统给了每个字的位置就用；没给就按整行平均分摊。
	static func centers(_ l: OCRLine) -> [Double] {
		let n = l.text.count
		if let c = l.charCenters, c.count == n { return c }
		return (0..<n).map { l.box.x + (Double($0) + 0.5) * l.box.w / Double(max(n, 1)) }
	}

	/// 切块结果为主；整图那一遍里切块没覆盖到的行（多是大字，比重叠还高、在每块里都被切到）补回来。
	public static func mergeWithFullPass(tiles: [OCRLine], full: [OCRLine]) -> [OCRLine] {
		var out = tiles
		for l in full where l.box.area > 0 {
			if !tiles.contains(where: { $0.box.overlapArea(l.box) / l.box.area > 0.3 }) { out.append(l) }
		}
		return out
	}
}

/// 重叠区里同一行会认出两遍：可信的、长的先留，被已留下的行盖住六成以上的丢掉。
public func dedupe(_ lines: [OCRLine]) -> [OCRLine] {
	let sorted = lines.sorted {
		$0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.text.count > $1.text.count
	}
	var kept: [OCRLine] = []
	for l in sorted where l.box.area > 0 {
		if kept.contains(where: { $0.box.overlapArea(l.box) / l.box.area > 0.6 }) { continue }
		kept.append(l)
	}
	return kept
}
