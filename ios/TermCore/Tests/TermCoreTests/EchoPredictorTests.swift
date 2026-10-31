import XCTest
@testable import TermCore

/// 先行表示の confirmed のモード（docs/design.md「先行表示」。前の版の出し方）。画面は 1 行（0 行目）の桁 → 文字の表で作る。
/// 2026-10-31: 既定が instant になったので、ここのテストは `Predictor(mode: .confirmed)` で作る（中身は前の版のまま）。
/// instant のテストは EchoPredictorInstantTests
final class EchoPredictorTests: XCTestCase {
    typealias Predictor = EchoPredictor

    let plain = Predictor.Context()

    /// 0 行目の画面。表に無い桁は空のセル、画面の外（80 桁・1 行の外）は nil
    func screen(_ cells: [Int: String]) -> (Int, Int) -> String? {
        { col, row in (0..<80).contains(col) && row == 0 ? (cells[col] ?? "") : nil }
    }

    /// 1 文字打って、返ってきた（確かめた）状態にする。カーソルは col の次へ進む
    func confirmedPredictor(at col: Int = 5, now: TimeInterval = 0) -> Predictor {
        var p = Predictor(mode: .confirmed)
        p.typed("a", cursor: (col, 0), now: now, context: plain)
        p.reconcile(cellText: screen([col: "a"]), cursor: (col + 1, 0), now: now + 0.05)
        return p
    }

    func testFirstCharIsNeverShown() {
        var p = Predictor(mode: .confirmed)
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        XCTAssertFalse(p.confirmed)
        XCTAssertEqual(p.pending.count, 1)
        XCTAssertNil(p.display)
        // 返る前に続けて打っても、確かめるまでは出ない
        p.typed("b", cursor: (5, 0), now: 0.05, context: plain)
        XCTAssertEqual(p.pending.map(\.col), [5, 6])
        XCTAssertNil(p.display)
    }

    func testConfirmedAfterTheEchoAndShownFromThenOn() {
        var p = Predictor(mode: .confirmed)
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 0.1)
        XCTAssertTrue(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertNil(p.display)
        // 次からは、返る前に出る
        p.typed("b", cursor: (6, 0), now: 0.2, context: plain)
        XCTAssertEqual(p.display?.text, "b")
        XCTAssertEqual(p.display?.at.col, 6)
        XCTAssertEqual(p.display?.at.row, 0)
        p.typed("c", cursor: (6, 0), now: 0.25, context: plain)
        XCTAssertEqual(p.display?.text, "bc")
        XCTAssertEqual(p.display?.at.col, 6)
        // b だけ返った: 残りは c で、7 桁目から
        p.reconcile(cellText: screen([5: "a", 6: "b"]), cursor: (7, 0), now: 0.3)
        XCTAssertEqual(p.display?.text, "c")
        XCTAssertEqual(p.display?.at.col, 7)
        // c も返った: 出すものが無くなる。確かめた状態は保つ
        p.reconcile(cellText: screen([5: "a", 6: "b", 7: "c"]), cursor: (8, 0), now: 0.35)
        XCTAssertNil(p.display)
        XCTAssertTrue(p.confirmed)
    }

    func testKeepsWaitingWhileTheCellIsStillEmpty() {
        var p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 1.2)
        XCTAssertEqual(p.display?.text, "x")
        XCTAssertTrue(p.confirmed)
    }

    func testSameCharWithoutCursorMoveIsNotConfirmed() {
        // もとからそこにあった同じ文字かもしれない。カーソルが進むまで、確かめたことにしない
        var p = Predictor(mode: .confirmed)
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (5, 0), now: 0.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertEqual(p.pending.count, 1)
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 0.2)
        XCTAssertTrue(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testEnterAndFriendsClearAndRequireConfirmationAgain() {
        for kind in [Predictor.KeyKind.enter, .escape, .tab, .modified, .paste] {
            var p = confirmedPredictor()
            p.typed("x", cursor: (6, 0), now: 1, context: plain)
            XCTAssertNotNil(p.display, "\(kind)")
            p.key(kind)
            XCTAssertTrue(p.pending.isEmpty, "\(kind)")
            XCTAssertFalse(p.confirmed, "\(kind)")
            // 次の 1 文字は、また出ない
            p.typed("y", cursor: (0, 1), now: 2, context: plain)
            XCTAssertNil(p.display, "\(kind)")
        }
    }

    func testBackspaceAndArrowOnlyClearWhatIsShown() {
        for kind in [Predictor.KeyKind.backspace, .arrow] {
            var p = confirmedPredictor()
            p.typed("x", cursor: (6, 0), now: 1, context: plain)
            p.key(kind)
            XCTAssertTrue(p.pending.isEmpty, "\(kind)")
            XCTAssertTrue(p.confirmed, "\(kind)")
            XCTAssertNil(p.display, "\(kind)")
            // 確かめた状態は保つので、次の文字はすぐ出る
            p.typed("y", cursor: (5, 0), now: 2, context: plain)
            XCTAssertEqual(p.display?.text, "y", "\(kind)")
        }
    }

    func testDifferentCharClearsThePrediction() {
        var p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 1, context: plain)
        p.typed("y", cursor: (6, 0), now: 1.01, context: plain)
        // 6 桁目に x ではなく z が出た（予測が外れた）
        p.reconcile(cellText: screen([5: "a", 6: "z"]), cursor: (7, 0), now: 1.1)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertFalse(p.confirmed)
        XCTAssertNil(p.display)
    }

    func testCursorMovingAwayClearsThePrediction() {
        // 手前の桁へ
        var p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (2, 0), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        // 別の行へ
        p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (0, 3), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        // 空のセルのまま、カーソルだけ先へ進んだ（返るはずの文字が来なかった）
        p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (9, 0), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testWrappingOrLeavingTheScreenClearsThePrediction() {
        // 行の終わりで折り返した: x は 80 桁目に返り、カーソルは次の行の頭へ
        var p = confirmedPredictor(at: 78)
        p.typed("x", cursor: (79, 0), now: 1, context: plain)
        p.typed("y", cursor: (79, 0), now: 1.01, context: plain)
        p.reconcile(cellText: screen([78: "a", 79: "x"]), cursor: (0, 1), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        // 予測の位置が画面の外（桁が行の幅を超える）
        p = confirmedPredictor(at: 78)
        p.typed("x", cursor: (80, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([78: "a"]), cursor: (80, 0), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testExpiresAfterOneSecond() {
        var p = confirmedPredictor()
        p.typed("x", cursor: (6, 0), now: 10, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 10.99)
        XCTAssertEqual(p.display?.text, "x")
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 11.01)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertFalse(p.confirmed)
        XCTAssertNil(p.display)
    }

    func testPasswordIsNeverShown() {
        // パスワードの入力: 文字が返らない（画面は空のまま、カーソルも動かない）
        var p = confirmedPredictor()
        p.key(.enter)
        var t: TimeInterval = 20
        for ch in "secret" {
            p.typed(String(ch), cursor: (10, 4), now: t, context: plain)
            XCTAssertNil(p.display, "\(ch)")
            p.reconcile(cellText: { _, _ in "" }, cursor: (10, 4), now: t + 0.01)
            XCTAssertNil(p.display, "\(ch)")
            t += 0.1
        }
        // 1 秒たって消えても、続きは出ない
        p.reconcile(cellText: { _, _ in "" }, cursor: (10, 4), now: 21.5)
        XCTAssertTrue(p.pending.isEmpty)
        p.typed("x", cursor: (10, 4), now: 21.6, context: plain)
        XCTAssertNil(p.display)
    }

    func testBlockedContextsClearAndShowNothing() {
        // 2026-10-31: カーソルが隠れているのは止めなくなった（Claude Code のため。EchoPredictorInstantTests）。
        // 秘密の入力らしい行を足した
        let blocked: [(String, Predictor.Context)] = [
            ("secretPrompt", .init(secretPrompt: true)),
            ("scrolledBack", .init(scrolledBack: true)),
            ("composing", .init(composing: true)),
            ("selecting", .init(selecting: true)),
        ]
        for (name, context) in blocked {
            var p = confirmedPredictor()
            p.typed("x", cursor: (6, 0), now: 1, context: plain)
            XCTAssertNotNil(p.display, name)
            p.typed("y", cursor: (6, 0), now: 1.1, context: context)
            XCTAssertTrue(p.pending.isEmpty, name)
            XCTAssertFalse(p.confirmed, name)
            XCTAssertNil(p.display, name)
        }
    }

    /// tmux は外側の端末を代替画面にし、mouse on ならマウス報告も使う。それでも確かめた後なら出る
    /// （Context に代替画面・マウス報告の項目は無い。守りは「確かめる前は出さない」「突き合わせて外れたら消す」の 2 つ）
    func testShownInsideAlternateScreenOrMouseReportingOnceConfirmed() {
        // 代替画面でもマウス報告でも、アプリが渡す Context は同じ（plain）。最初の 1 文字は出ない
        var p = Predictor(mode: .confirmed)
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        XCTAssertNil(p.display)
        // 返ってきた（確かめた）後は、次の文字から出る
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 0.1)
        XCTAssertTrue(p.confirmed)
        p.typed("b", cursor: (6, 0), now: 0.2, context: plain)
        XCTAssertEqual(p.display?.text, "b")
        XCTAssertEqual(p.display?.at.col, 6)
    }

    func testViNormalModeNeverConfirms() {
        // vim の通常モードで l を打つ: 5 桁目はもとの文字（w）のまま、カーソルが 1 つ進むだけ。予測と合わないので出ない
        var p = Predictor(mode: .confirmed)
        p.typed("l", cursor: (5, 0), now: 0, context: plain)
        p.reconcile(cellText: screen([5: "w", 6: "x"]), cursor: (6, 0), now: 0.05)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertNil(p.display)
        // 打ち続けても、確かめが通らないので出ない
        p.typed("l", cursor: (6, 0), now: 0.1, context: plain)
        XCTAssertNil(p.display)
    }

    func testSpaceEchoIsRecognizedEvenThoughTheCellStaysEmpty() {
        // 空白が返ってきても、画面のセルは空のまま。カーソルが先へ進んだら、返ってきたとみなす
        var p = confirmedPredictor()
        p.typed(" ", cursor: (6, 0), now: 1, context: plain)
        XCTAssertEqual(p.display?.text, " ")
        // まだ返っていない（カーソルが動かない）
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 1.05)
        XCTAssertTrue(p.confirmed)
        XCTAssertEqual(p.pending.count, 1)
        // 返ってきた: セルは空のまま、カーソルが 7 桁目へ
        p.reconcile(cellText: screen([5: "a"]), cursor: (7, 0), now: 1.1)
        XCTAssertTrue(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
        // 確かめた状態が続くので、空白の後の文字もすぐ出る
        p.typed("b", cursor: (7, 0), now: 1.2, context: plain)
        XCTAssertEqual(p.display?.text, "b")
        XCTAssertEqual(p.display?.at.col, 7)
    }

    func testSpaceCellMayAlsoBeASpaceCharacter() {
        var p = confirmedPredictor()
        p.typed(" ", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a", 6: " "]), cursor: (7, 0), now: 1.1)
        XCTAssertTrue(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testTypingWithSpacesKeepsBeingConfirmed() {
        // ls -la のように空白を挟んで打っても、確かめた状態が続き、空白の後の文字も出る
        var p = Predictor(mode: .confirmed)
        var cells: [Int: String] = [:]
        var col = 2
        var t: TimeInterval = 0
        // 最初の 1 文字は、返事を待って確かめる
        p.typed("l", cursor: (col, 0), now: t, context: plain)
        XCTAssertNil(p.display)
        cells[col] = "l"
        col += 1
        t += 0.1
        p.reconcile(cellText: screen(cells), cursor: (col, 0), now: t)
        XCTAssertTrue(p.confirmed)
        for ch in "s -la" {
            t += 0.1
            p.typed(String(ch), cursor: (col, 0), now: t, context: plain)
            // 打った瞬間に出る（空白の後の文字も）
            XCTAssertEqual(p.display?.text, String(ch), "\(ch)")
            XCTAssertEqual(p.display?.at.col, col, "\(ch)")
            // 返事: 空白はセルが空のまま、カーソルだけが進む
            if ch != " " { cells[col] = String(ch) }
            col += 1
            t += 0.05
            p.reconcile(cellText: screen(cells), cursor: (col, 0), now: t)
            XCTAssertTrue(p.confirmed, "\(ch)")
            XCTAssertTrue(p.pending.isEmpty, "\(ch)")
        }
    }

    func testSeveralCharsIncludingSpaceInFlight() {
        // 空白を含む 3 文字が返る前に続けて打たれ、まとめて返ってきた
        var p = confirmedPredictor()
        p.typed("-", cursor: (6, 0), now: 1, context: plain)
        p.typed(" ", cursor: (6, 0), now: 1.01, context: plain)
        p.typed("l", cursor: (6, 0), now: 1.02, context: plain)
        XCTAssertEqual(p.display?.text, "- l")
        // 先頭の - だけ返った
        p.reconcile(cellText: screen([5: "a", 6: "-"]), cursor: (7, 0), now: 1.05)
        XCTAssertEqual(p.display?.text, " l")
        XCTAssertEqual(p.display?.at.col, 7)
        // 空白まで返った（セルは空のまま、カーソルは 8 桁目）。残りは l
        p.reconcile(cellText: screen([5: "a", 6: "-"]), cursor: (8, 0), now: 1.1)
        XCTAssertEqual(p.display?.text, "l")
        XCTAssertEqual(p.display?.at.col, 8)
        XCTAssertTrue(p.confirmed)
        // l も返った
        p.reconcile(cellText: screen([5: "a", 6: "-", 8: "l"]), cursor: (9, 0), now: 1.15)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertTrue(p.confirmed)
    }

    func testSpaceWithTheCursorOnAnotherRowIsNotConfirmed() {
        // 空白を打ったのに、カーソルが別の行へ動いた（画面の書き換え）: 返ってきたとは見ない
        var p = confirmedPredictor()
        p.typed(" ", cursor: (6, 0), now: 1, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (9, 3), now: 1.1)
        XCTAssertFalse(p.confirmed)
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testOnlyPrintableASCIIIsPredicted() {
        for text in ["あ", "é", "e\u{301}", "ab", "", "\n", "\u{1b}", "\u{7f}", "😀"] {
            var p = confirmedPredictor()
            p.typed(text, cursor: (6, 0), now: 1, context: plain)
            XCTAssertTrue(p.pending.isEmpty, text.debugDescription)
            XCTAssertFalse(p.confirmed, text.debugDescription)
            XCTAssertNil(p.display, text.debugDescription)
        }
        // 空白 (0x20) と ~ (0x7E) は予測する
        var p = confirmedPredictor()
        p.typed(" ", cursor: (6, 0), now: 1, context: plain)
        p.typed("~", cursor: (6, 0), now: 1, context: plain)
        XCTAssertEqual(p.display?.text, " ~")
    }

    func testPendingFollowsThePreviousCharNotTheCursor() {
        // 続けて打つ文字の位置は、前の予測の次の桁（カーソルがまだ動いていなくても）
        var p = confirmedPredictor()
        for (i, ch) in "abc".enumerated() {
            p.typed(String(ch), cursor: (6, 0), now: 1 + Double(i) * 0.01, context: plain)
        }
        XCTAssertEqual(p.pending.map(\.col), [6, 7, 8])
        XCTAssertEqual(p.pending.map(\.row), [0, 0, 0])
        XCTAssertEqual(p.display?.text, "abc")
    }
}
