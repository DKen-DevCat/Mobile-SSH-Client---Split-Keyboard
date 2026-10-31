import XCTest
@testable import TermCore

final class ConnectedTextTests: XCTestCase {
    typealias Line = ConnectedText.Line
    typealias Cell = ConnectedText.Cell

    /// 文字列を 1 行にする。全角の文字は幅 2 と、その続きのセル（幅 0）にし、桁数まで空白のセルで埋める
    func line(_ s: String, cols: Int, wrapped: Bool = false) -> Line {
        var cells: [Cell] = []
        for ch in s {
            if let v = ch.unicodeScalars.first?.value, (0x3000...0x9FFF).contains(v) || (0xFF00...0xFF60).contains(v) {
                cells.append(Cell(String(ch), width: 2))
                cells.append(Cell("", width: 0))
            } else {
                cells.append(Cell(String(ch)))
            }
        }
        XCTAssertLessThanOrEqual(cells.count, cols, s)
        while cells.count < cols { cells.append(Cell(" ")) }
        return Line(cells: cells, isWrapped: wrapped)
    }

    func screen(_ lines: [Line]) -> (Int) -> Line? {
        { row in lines.indices.contains(row) ? lines[row] : nil }
    }

    func pick(_ lines: [Line], row: Int, col: Int) -> ConnectedText.Selection? {
        ConnectedText.select(row: row, col: col, line: screen(lines))
    }

    // MARK: 1 行の中

    /// URL（? & = % # を含む）を 1 回で選ぶ。前後の言葉は含めない
    func testSelectsAWholeURL() throws {
        let url = "https://example.com/a?b=1&c=%20#x"
        let l = line("see \(url) ok", cols: 60)
        for col in [4, 4 + url.count / 2, 4 + url.count - 1] {
            let s = try XCTUnwrap(pick([l], row: 0, col: col), "col \(col)")
            XCTAssertEqual(s.text, url)
            XCTAssertEqual(s.start, ConnectedText.Position(row: 0, col: 4))
            XCTAssertEqual(s.end, ConnectedText.Position(row: 0, col: 4 + url.count - 1))
        }
        XCTAssertEqual(pick([l], row: 0, col: 1)?.text, "see")
        XCTAssertEqual(pick([l], row: 0, col: 4 + url.count + 2)?.text, "ok")
    }

    /// パスや a=b&c も 1 つ。区切りの上（空白・タブ・空のセル）は選ばない
    func testPathsAndSeparators() {
        let l = line("cd ~/src/my-app/../x.txt  KEY=a&b", cols: 40)
        XCTAssertEqual(pick([l], row: 0, col: 6)?.text, "~/src/my-app/../x.txt")
        XCTAssertEqual(pick([l], row: 0, col: 27)?.text, "KEY=a&b")
        XCTAssertNil(pick([l], row: 0, col: 2))   // 空白
        XCTAssertNil(pick([l], row: 0, col: 24))  // 空白
        XCTAssertNil(pick([l], row: 0, col: 39))  // 行末の空白
        var cells = l.cells
        cells[2] = Cell("\t")
        cells[24] = Cell("")
        XCTAssertNil(pick([Line(cells: cells)], row: 0, col: 2))   // タブ
        XCTAssertNil(pick([Line(cells: cells)], row: 0, col: 24))  // 空のセル
        cells[24] = Cell("\u{0}")
        XCTAssertNil(pick([Line(cells: cells)], row: 0, col: 24))  // NUL のセル
        XCTAssertEqual(pick([Line(cells: cells)], row: 0, col: 6)?.text, "~/src/my-app/../x.txt")
    }

    /// 罫線とブロックの文字（U+2500〜U+259F）で区切る。Claude Code の入力欄の枠を含めない
    func testBoxDrawingSeparates() {
        let l = line("│> foo/bar.txt │", cols: 20)
        XCTAssertEqual(pick([l], row: 0, col: 4)?.text, "foo/bar.txt")
        // 空白を挟まない枠でも、枠は含めない
        let tight = line("│foo/bar│", cols: 12)
        let s = pick([tight], row: 0, col: 3)
        XCTAssertEqual(s?.text, "foo/bar")
        XCTAssertEqual(s?.start.col, 1)
        XCTAssertEqual(s?.end.col, 7)
        XCTAssertNil(pick([tight], row: 0, col: 0))  // 枠そのものは選ばない
        XCTAssertNil(pick([line("██▀▄", cols: 6)], row: 0, col: 1))
        // 範囲の端: U+2500・U+259F は区切り、U+24FF・U+25A0 は区切りでない
        XCTAssertTrue(ConnectedText.isSeparator(Cell("\u{2500}")))
        XCTAssertTrue(ConnectedText.isSeparator(Cell("\u{259F}")))
        XCTAssertFalse(ConnectedText.isSeparator(Cell("\u{24FF}")))
        XCTAssertFalse(ConnectedText.isSeparator(Cell("\u{25A0}")))
        XCTAssertTrue(ConnectedText.isSeparator(Cell("\u{3000}", width: 2)))  // 全角の空白
        XCTAssertFalse(ConnectedText.isSeparator(Cell("a")))
    }

    /// 全角の文字: 続きのセルをタップしても先頭の文字として選ぶ。続きのセルまで範囲に含め、コピーする文字には数えない
    func testWideCharacters() throws {
        let l = line("ab 日本語 cd", cols: 20)
        // 日(3,4) 本(5,6) 語(7,8)
        for col in [3, 4, 6, 8] {
            let s = try XCTUnwrap(pick([l], row: 0, col: col), "col \(col)")
            XCTAssertEqual(s.text, "日本語")
            XCTAssertEqual(s.start.col, 3)
            XCTAssertEqual(s.end.col, 8)
        }
        XCTAssertEqual(pick([l], row: 0, col: 1)?.text, "ab")
        // 日本語と英数字は区切りが無ければ 1 つ
        let mixed = line("x日本y", cols: 10)
        XCTAssertEqual(pick([mixed], row: 0, col: 2)?.text, "x日本y")
        XCTAssertEqual(pick([mixed], row: 0, col: 2)?.end.col, 5)
        // 全角の空白は区切り（その続きのセルも）
        let sp = line("日本\u{3000}語", cols: 10)
        XCTAssertEqual(pick([sp], row: 0, col: 1)?.text, "日本")
        XCTAssertNil(pick([sp], row: 0, col: 4))
        XCTAssertNil(pick([sp], row: 0, col: 5))
        XCTAssertEqual(pick([sp], row: 0, col: 6)?.text, "語")
    }

    func testOutOfRange() {
        let l = line("abc", cols: 5)
        XCTAssertNil(pick([l], row: 0, col: 5))
        XCTAssertNil(pick([l], row: 0, col: -1))
        XCTAssertNil(pick([l], row: 1, col: 0))
        XCTAssertNil(pick([l], row: -1, col: 0))
        XCTAssertNil(pick([], row: 0, col: 0))
        XCTAssertNil(pick([Line(cells: [])], row: 0, col: 0))
    }

    // MARK: 行をまたぐ

    /// 折り返し（isWrapped）で続く URL は、行をまたいでも 1 つ。コピーする文字に改行が入らない
    func testWrappedLinesAreJoinedWithoutNewline() throws {
        // 15 桁。1 行目は最後の桁まで埋まっている
        let lines = [line("see http://exam", cols: 15), line("ple.com/path ok", cols: 15, wrapped: true)]
        for (row, col) in [(0, 6), (0, 14), (1, 0), (1, 5), (1, 11)] {
            let s = try XCTUnwrap(pick(lines, row: row, col: col), "\(row),\(col)")
            XCTAssertEqual(s.text, "http://example.com/path")
            XCTAssertFalse(s.text.contains("\n"))
            XCTAssertEqual(s.start, ConnectedText.Position(row: 0, col: 4))
            XCTAssertEqual(s.end, ConnectedText.Position(row: 1, col: 11))
        }
        XCTAssertEqual(pick(lines, row: 0, col: 1)?.text, "see")
        XCTAssertEqual(pick(lines, row: 1, col: 13)?.text, "ok")
    }

    /// 折り返しの印が無くても（tmux の中の折り返し）、行の最後の桁まで続いていて、次の行の先頭が区切りでなければつなぐ
    func testLinesAreJoinedWhenTheyRunToTheLastColumn() throws {
        let lines = [line("see http://exam", cols: 15), line("ple.com/path ok", cols: 15, wrapped: false)]
        let s = try XCTUnwrap(pick(lines, row: 1, col: 3))
        XCTAssertEqual(s.text, "http://example.com/path")
        XCTAssertEqual(s.start, ConnectedText.Position(row: 0, col: 4))
        XCTAssertEqual(s.end, ConnectedText.Position(row: 1, col: 11))
        XCTAssertEqual(pick(lines, row: 0, col: 9)?.text, "http://example.com/path")
    }

    /// 行の最後の桁が空白なら、次の行が折り返しの続きでもつなげない（言葉の切れ目で折り返した）
    func testASpaceAtTheLastColumnEndsTheText() {
        let lines = [line("aaa bbb ", cols: 8), line("ccc", cols: 8, wrapped: true)]
        XCTAssertEqual(pick(lines, row: 0, col: 5)?.text, "bbb")
        XCTAssertEqual(pick(lines, row: 0, col: 5)?.end, ConnectedText.Position(row: 0, col: 6))
        XCTAssertEqual(pick(lines, row: 1, col: 1)?.text, "ccc")
        XCTAssertEqual(pick(lines, row: 1, col: 1)?.start, ConnectedText.Position(row: 1, col: 0))
    }

    /// 最後の桁まで続いていても、次の行の先頭が区切りなら足すものが無い（折り返しの続きでも）
    func testNextLineStartingWithASeparatorIsNotJoined() throws {
        for wrapped in [false, true] {
            let lines = [line("abcdefgh", cols: 8), line(" ij", cols: 8, wrapped: wrapped)]
            let s = try XCTUnwrap(pick(lines, row: 0, col: 3), "wrapped \(wrapped)")
            XCTAssertEqual(s.text, "abcdefgh")
            XCTAssertEqual(s.end, ConnectedText.Position(row: 0, col: 7))
            XCTAssertNil(pick(lines, row: 1, col: 0))
            XCTAssertEqual(pick(lines, row: 1, col: 2)?.text, "ij")
            XCTAssertEqual(pick(lines, row: 1, col: 2)?.start, ConnectedText.Position(row: 1, col: 1))
        }
    }

    /// 前の行の最後の桁が空白なら、前へはつなげない（折り返しの続きでも）
    func testPreviousLineEndingWithASpaceIsNotJoined() {
        let lines = [line("foo bar ", cols: 8), line("baz", cols: 8, wrapped: true)]
        let s = pick(lines, row: 1, col: 0)
        XCTAssertEqual(s?.text, "baz")
        XCTAssertEqual(s?.start.row, 1)
    }

    /// 3 行以上にまたがる。途中の行は丸ごと、最後の行は区切りまで
    func testThreeLines() throws {
        let lines = [line("x aaaaaaa", cols: 9), line("bbbbbbbbb", cols: 9, wrapped: true),
                     line("ccc ddd", cols: 9, wrapped: true)]
        let s = try XCTUnwrap(pick(lines, row: 1, col: 4))
        XCTAssertEqual(s.text, "aaaaaaabbbbbbbbbccc")
        XCTAssertEqual(s.start, ConnectedText.Position(row: 0, col: 2))
        XCTAssertEqual(s.end, ConnectedText.Position(row: 2, col: 2))
        // どの行からタップしても同じ範囲
        XCTAssertEqual(pick(lines, row: 0, col: 5), s)
        XCTAssertEqual(pick(lines, row: 2, col: 0), s)
    }

    /// 全角の文字が行末で折り返したときの隙間（幅 0 のセル）は、前の文字の一部。次の行へつなぐ
    func testWideCharacterWrappedAtTheEdge() throws {
        // 5 桁: a b 日(2,3) [隙間(4)] ／ 次の行（折り返し）: 本 語
        var first = line("ab日", cols: 5)
        first.cells[4] = Cell("", width: 0)
        let lines = [first, line("本語", cols: 5, wrapped: true)]
        let s = try XCTUnwrap(pick(lines, row: 0, col: 2))
        XCTAssertEqual(s.text, "ab日本語")
        XCTAssertEqual(s.start, ConnectedText.Position(row: 0, col: 0))
        XCTAssertEqual(s.end, ConnectedText.Position(row: 1, col: 3))
    }

    /// つなぐのはタップした行を含めて 50 行まで。上にも下にも同じように足す
    func testAtMost50Lines() throws {
        let lines = (0..<120).map { line("aaaaaaaa", cols: 8, wrapped: $0 > 0) }
        let s = try XCTUnwrap(pick(lines, row: 60, col: 3))
        let rows = s.end.row - s.start.row + 1
        XCTAssertEqual(rows, ConnectedText.maxLines)
        XCTAssertEqual(ConnectedText.maxLines, 50)
        XCTAssertEqual(s.text.count, 50 * 8)
        XCTAssertFalse(s.text.contains("\n"))
        XCTAssertLessThanOrEqual(abs((60 - s.start.row) - (s.end.row - 60)), 1)
        // 端に近いタップは、足せる方へ伸びる
        let atTop = try XCTUnwrap(pick(lines, row: 0, col: 0))
        XCTAssertEqual(atTop.start.row, 0)
        XCTAssertEqual(atTop.end.row - atTop.start.row + 1, ConnectedText.maxLines)
        // 50 行に収まれば全部
        let few = try XCTUnwrap(pick(Array(lines[0..<7]), row: 3, col: 0))
        XCTAssertEqual(few.start.row, 0)
        XCTAssertEqual(few.end.row, 6)
    }

    /// 画面の上端・下端（行が無い）で止まる
    func testStopsAtTheEdgesOfTheBuffer() throws {
        let lines = [line("abcdefgh", cols: 8), line("ijklmnop", cols: 8)]
        let s = try XCTUnwrap(pick(lines, row: 0, col: 0))
        XCTAssertEqual(s.text, "abcdefghijklmnop")
        XCTAssertEqual(s.start.row, 0)
        XCTAssertEqual(s.end.row, 1)
    }
}
