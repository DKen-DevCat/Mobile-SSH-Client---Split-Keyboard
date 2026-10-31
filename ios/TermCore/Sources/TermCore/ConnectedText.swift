import Foundation

/// ダブルタップで選ぶ「つながっている文字列」（URL・パス・`a=b&c` など）。範囲と、コピーする文字を決める純粋な関数
/// （docs/design.md「選択とコピー」）。画面にも SwiftTerm にも頼らない。セルの文字・幅と折り返しの印は、呼び手が行ごとに渡す
public enum ConnectedText {
    /// 画面の 1 セル。全角の先頭は幅 2、その続きは幅 0。空のセルは text が ""
    public struct Cell: Equatable, Sendable {
        public var text: String
        public var width: Int

        public init(_ text: String, width: Int = 1) {
            self.text = text
            self.width = width
        }
    }

    /// 1 行ぶんのセル。isWrapped は、前の行から折り返して続いている行（SwiftTerm の `isWrapped`）
    public struct Line: Equatable, Sendable {
        public var cells: [Cell]
        public var isWrapped: Bool

        public init(cells: [Cell], isWrapped: Bool = false) {
            self.cells = cells
            self.isWrapped = isWrapped
        }
    }

    /// スクロールバックを含めた通し番号の行と、桁
    public struct Position: Equatable, Sendable {
        public var row: Int
        public var col: Int

        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
    }

    public struct Selection: Equatable, Sendable {
        /// 最初の文字のセル
        public var start: Position
        /// 最後の文字のセル（全角なら、その続きのセル）。含む
        public var end: Position
        /// コピーする文字。行をまたいでも改行を入れずにつなげる
        public var text: String
    }

    /// つなげる行の数の上限（タップした行を含む）
    public static let maxLines = 50

    /// 区切りか。空のセル・空白・タブ・制御文字（空のセルは NUL や空白で来ることがある）と、罫線とブロックの文字
    /// （U+2500〜U+259F。Claude Code の入力欄の枠を含めないため）
    public static func isSeparator(_ cell: Cell) -> Bool {
        guard let first = cell.text.unicodeScalars.first else { return true }
        let v = first.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        if (0x2500...0x259F).contains(v) { return true }
        return first.properties.isWhitespace
    }

    /// row・col のセルを含む、つながっている文字列。区切りの上、行や桁が無いときは nil。
    /// `line` は通し番号の行を返す（無い行は nil）。つなげるのは、タップした行を含めて最大 `maxLines` 行
    public static func select(row: Int, col: Int, line: (Int) -> Line?) -> Selection? {
        guard let tapped = line(row), col >= 0, col < tapped.cells.count else { return nil }
        // 全角の続きのセル（幅 0）をタップしたら、その先頭のセルとして扱う
        var c = col
        while c > 0 && tapped.cells[c].width == 0 { c -= 1 }
        guard !isSeparator(tapped.cells, at: c) else { return nil }
        let r = run(in: tapped.cells, around: c)

        let first = Piece(row: row, line: tapped, start: r.start, end: r.end)
        var above: [Piece] = []  // 上へつないだ行（近い順）
        var below: [Piece] = []  // 下へつないだ行（近い順）
        var top = first, bottom = first
        var count = 1
        var canGoUp = true, canGoDown = true
        // 上と下に 1 行ずつ交互に足す（上限に達しても片方だけが伸び切らないように）
        while count < maxLines && (canGoUp || canGoDown) {
            if canGoDown {
                if let next = pieceBelow(bottom, line: line) {
                    below.append(next)
                    bottom = next
                    count += 1
                } else {
                    canGoDown = false
                }
            }
            if canGoUp && count < maxLines {
                if let prev = pieceAbove(top, line: line) {
                    above.append(prev)
                    top = prev
                    count += 1
                } else {
                    canGoUp = false
                }
            }
        }

        let pieces: [Piece] = Array(above.reversed()) + [first] + below
        var text = ""
        for p in pieces {
            for i in p.start...p.end where p.line.cells[i].width != 0 {
                text += p.line.cells[i].text
            }
        }
        return Selection(start: Position(row: top.row, col: top.start),
                         end: Position(row: bottom.row, col: bottom.end),
                         text: text)
    }

    /// 1 行の中で選ぶ範囲（start...end は区切りでないセルだけ）
    private struct Piece {
        var row: Int
        var line: Line
        var start: Int
        var end: Int
    }

    /// i 番目のセルが区切りか。全角の続きのセル（幅 0。行末で全角が折り返した隙間も）は、前の文字で決める
    private static func isSeparator(_ cells: [Cell], at i: Int) -> Bool {
        var j = i
        while j > 0 && cells[j].width == 0 { j -= 1 }
        return isSeparator(cells[j])
    }

    /// i 番目のセルを含む、区切りでないひとかたまりの範囲
    private static func run(in cells: [Cell], around i: Int) -> (start: Int, end: Int) {
        var s = i, e = i
        while s > 0 && !isSeparator(cells, at: s - 1) { s -= 1 }
        while e + 1 < cells.count && !isSeparator(cells, at: e + 1) { e += 1 }
        return (s, e)
    }

    /// 下の行へつなぐ。その行の最後の桁まで続いていて、①次の行が折り返しの続き（isWrapped）、または
    /// ②次の行の先頭の桁が区切りでないとき（tmux の中の折り返しはこちら）。先頭が区切りなら、つないでも足す文字が無いので止める
    private static func pieceBelow(_ p: Piece, line: (Int) -> Line?) -> Piece? {
        guard p.end == p.line.cells.count - 1,
              let next = line(p.row + 1), !next.cells.isEmpty,
              next.isWrapped || !isSeparator(next.cells, at: 0),
              !isSeparator(next.cells, at: 0) else { return nil }
        return Piece(row: p.row + 1, line: next, start: 0, end: run(in: next.cells, around: 0).end)
    }

    /// 上の行へつなぐ（下へつなぐのと同じ考え）。この行がひとかたまりの先頭の桁から始まり、
    /// 上の行の最後の桁が区切りでないとき
    private static func pieceAbove(_ p: Piece, line: (Int) -> Line?) -> Piece? {
        guard p.start == 0, !p.line.cells.isEmpty, !isSeparator(p.line.cells, at: 0),
              let prev = line(p.row - 1), !prev.cells.isEmpty else { return nil }
        let last = prev.cells.count - 1
        guard !isSeparator(prev.cells, at: last) else { return nil }
        return Piece(row: p.row - 1, line: prev, start: run(in: prev.cells, around: last).start, end: last)
    }
}
