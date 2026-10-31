import XCTest
@testable import TermCore

/// 先行表示の instant のモード（既定。docs/design.md「先行表示」）。押した瞬間に出す。画面は 1 行（0 行目）の桁 → 文字の表で作る
final class EchoPredictorInstantTests: XCTestCase {
    typealias Predictor = EchoPredictor

    let plain = Predictor.Context()

    /// 0 行目の画面。表に無い桁は空のセル、画面の外（80 桁・1 行の外）は nil
    func screen(_ cells: [Int: String]) -> (Int, Int) -> String? {
        { col, row in (0..<80).contains(col) && row == 0 ? (cells[col] ?? "") : nil }
    }

    func testInstantIsTheDefault() {
        XCTAssertEqual(Predictor().mode, .instant)
        XCTAssertEqual(Predictor.Mode.allCases.map(\.rawValue), ["instant", "confirmed", "off"])
    }

    /// 最初の 1 文字は、確かめる前でもすぐ出す（iOS のキーボードと同じく、押したら見える）
    func testFirstCharIsShownImmediately() {
        var p = Predictor()
        p.typed("l", cursor: (2, 0), now: 0, context: plain)
        XCTAssertFalse(p.confirmed)
        XCTAssertEqual(p.display?.text, "l")
        XCTAssertEqual(p.display?.at.col, 2)
    }

    /// 確かめる前に出すのは 1 文字だけ。返ってきたら（確かめたら）続けて打った分も出す
    func testOnlyTheFirstCharBeforeConfirmation() {
        var p = Predictor()
        p.typed("l", cursor: (2, 0), now: 0, context: plain)
        p.typed("s", cursor: (2, 0), now: 0.05, context: plain)
        XCTAssertEqual(p.display?.text, "l")
        XCTAssertEqual(p.pending.count, 2)
        // l が返ってきてカーソルが進んだ → 確かめた。残りの s が出る
        p.reconcile(cellText: screen([2: "l"]), cursor: (3, 0), now: 0.08)
        XCTAssertTrue(p.confirmed)
        XCTAssertEqual(p.display?.text, "s")
        p.typed("x", cursor: (3, 0), now: 0.1, context: plain)
        XCTAssertEqual(p.display?.text, "sx")
    }

    /// 返らない入力（言葉で見分けられなかったパスワードなど）: 出るのは最初の 1 文字だけ、1 秒まで。外れて疑う状態になり、
    /// 確かめるまで（Enter を押しても）出さない
    func testUnmatchedSecretShowsAtMostOneCharForOneSecond() {
        var p = Predictor()
        for (i, ch) in ["h", "u", "n", "t", "e", "r"].enumerated() {
            p.typed(ch, cursor: (10, 0), now: Double(i) * 0.1, context: plain)
            // 返らないのでカーソルは 10 のまま。出ているのはずっと最初の 1 文字
            p.reconcile(cellText: screen([:]), cursor: (10, 0), now: Double(i) * 0.1 + 0.05)
            XCTAssertEqual(p.display?.text, "h", ch)
        }
        // 1 秒たっても返らない → 外れ
        p.reconcile(cellText: screen([:]), cursor: (10, 0), now: 1.01)
        XCTAssertTrue(p.doubtful)
        XCTAssertNil(p.display)
        p.typed("2", cursor: (10, 0), now: 1.1, context: plain)
        XCTAssertNil(p.display)
        // Enter で次の行へ。疑っている状態は保つ
        p.key(.enter)
        XCTAssertTrue(p.doubtful)
        p.typed("l", cursor: (2, 0), now: 2, context: plain)
        XCTAssertNil(p.display)
        // 返ってくるのを見たら、また出す
        p.reconcile(cellText: screen([2: "l"]), cursor: (3, 0), now: 2.05)
        XCTAssertFalse(p.doubtful)
        p.typed("s", cursor: (3, 0), now: 2.1, context: plain)
        XCTAssertEqual(p.display?.text, "s")
    }

    /// Enter・Esc・Tab・control／option・貼り付け: 予測を消して、その行は確かめ直す（次の最初の 1 文字はすぐ出る）
    func testEnterAndFriendsStartANewUnconfirmedLine() {
        for kind in [Predictor.KeyKind.enter, .escape, .tab, .modified, .paste] {
            var p = Predictor()
            p.typed("a", cursor: (5, 0), now: 0, context: plain)
            p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 0.05)
            p.typed("b", cursor: (6, 0), now: 0.1, context: plain)
            p.key(kind)
            XCTAssertTrue(p.pending.isEmpty, "\(kind)")
            XCTAssertFalse(p.confirmed, "\(kind)")
            XCTAssertFalse(p.doubtful, "\(kind)")
            // 次の最初の 1 文字はすぐ出るが、2 文字目は確かめるまで待つ
            p.typed("c", cursor: (2, 0), now: 1, context: plain)
            p.typed("d", cursor: (2, 0), now: 1.05, context: plain)
            XCTAssertEqual(p.display?.text, "c", "\(kind)")
        }
    }

    /// 違う文字が返った（vim の通常モードなど）→ 外れて疑う。確かめるまで出さない
    func testMismatchMakesItDoubtful() {
        var p = Predictor()
        p.typed("j", cursor: (0, 0), now: 0, context: plain)
        XCTAssertEqual(p.display?.text, "j")
        p.reconcile(cellText: screen([0: "#"]), cursor: (0, 0), now: 0.05)
        XCTAssertTrue(p.doubtful)
        XCTAssertNil(p.display)
        p.typed("j", cursor: (0, 0), now: 0.2, context: plain)
        XCTAssertNil(p.display)
    }

    /// カーソルが隠れていても出す（Claude Code）。止めるのは、スクロールバック・選択・変換中・秘密の入力らしい行。
    /// 止めても外れではない（疑う状態にしない）
    func testBlockedContextsAndHiddenCursor() {
        let blocked: [(String, Predictor.Context)] = [
            ("scrolledBack", .init(scrolledBack: true)),
            ("composing", .init(composing: true)),
            ("selecting", .init(selecting: true)),
            ("secretPrompt", .init(secretPrompt: true)),
        ]
        for (name, context) in blocked {
            var p = Predictor()
            p.typed("x", cursor: (6, 0), now: 0, context: plain)
            XCTAssertNotNil(p.display, name)
            p.typed("y", cursor: (6, 0), now: 0.1, context: context)
            XCTAssertTrue(p.pending.isEmpty, name)
            XCTAssertNil(p.display, name)
            XCTAssertFalse(p.doubtful, name)
        }
    }

    /// ⌫: 予測の最後の 1 文字だけ消す（予測が無ければ何もしない。画面の文字を消すのは返事を待つ）。矢印は予測を消す
    func testBackspacePopsTheLastPredictedChar() {
        var p = Predictor()
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        p.reconcile(cellText: screen([5: "a"]), cursor: (6, 0), now: 0.05)
        p.typed("b", cursor: (6, 0), now: 0.1, context: plain)
        p.typed("c", cursor: (6, 0), now: 0.12, context: plain)
        XCTAssertEqual(p.display?.text, "bc")
        p.key(.backspace)
        XCTAssertEqual(p.display?.text, "b")
        XCTAssertTrue(p.confirmed)
        p.key(.backspace)
        XCTAssertNil(p.display)
        p.key(.backspace)
        XCTAssertTrue(p.pending.isEmpty)
        // 次の文字は、確かめた状態のまま続きの位置から
        p.typed("z", cursor: (6, 0), now: 0.3, context: plain)
        XCTAssertEqual(p.display?.text, "z")
        p.key(.arrow)
        XCTAssertNil(p.display)
    }

    func testOffNeverShows() {
        var p = Predictor(mode: .off)
        p.typed("a", cursor: (5, 0), now: 0, context: plain)
        XCTAssertNil(p.display)
        XCTAssertFalse(p.hasPending)
    }

    func testResetForgetsDoubt() {
        var p = Predictor()
        p.typed("j", cursor: (0, 0), now: 0, context: plain)
        p.reconcile(cellText: screen([0: "#"]), cursor: (0, 0), now: 0.05)
        XCTAssertTrue(p.doubtful)
        p.reset()
        XCTAssertFalse(p.doubtful)
        p.typed("a", cursor: (0, 0), now: 1, context: plain)
        XCTAssertEqual(p.display?.text, "a")
    }

    // MARK: 秘密の入力らしい行

    func testSecretPromptWords() {
        let secret = [
            "[sudo] password for dken: ", "dken@mac's password: ", "Password:", "Enter passphrase for key '/Users/x/.ssh/id':",
            "Password for 'https://github.com': ", "PIN: ", "Enter PIN: ", "Verification code: ", "One-time password (OTP): ",
            "export GITHUB_TOKEN=", "API key: ", "OPENAI_API_KEY=", "client secret: ", "2FA code: ", "パスワード：",
            "暗証番号: ", "認証コードを入力: ", "Passcode:", "Enter the apikey ",
        ]
        for line in secret { XCTAssertTrue(Predictor.looksLikeSecretPrompt(line), line) }
        let plainLines = [
            "dken@mac ~ % ", "❯ ", "> ", "$ git commit -m \"fix ping\"", "Username for 'https://github.com': ",
            "~/src/app (main) $ ls", "pinned versions: ", "",
        ]
        for line in plainLines { XCTAssertFalse(Predictor.looksLikeSecretPrompt(line), line) }
    }
}
