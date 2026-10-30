import CoreGraphics
import XCTest
@testable import TermCore

final class KeyEncoderTests: XCTestCase {
    let ctx = EncodingContext()

    func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    func testPlainAndControl() {
        XCTAssertEqual(KeyEncoder.encode(.text("a"), [], ctx), [0x61])
        XCTAssertEqual(KeyEncoder.encode(.text("c"), .control, ctx), [0x03])
        XCTAssertEqual(KeyEncoder.encode(.text("C"), .control, ctx), [0x03])
        XCTAssertEqual(KeyEncoder.encode(.text("["), .control, ctx), [0x1b])
        XCTAssertEqual(KeyEncoder.encode(.text(" "), .control, ctx), [0x00])
        XCTAssertEqual(KeyEncoder.encode(.text("あ"), [], ctx), Array("あ".utf8))
    }

    func testOptionAsMeta() {
        XCTAssertEqual(KeyEncoder.encode(.text("b"), .option, ctx), [0x1b, 0x62])
        var noMeta = ctx
        noMeta.optionAsMeta = false
        XCTAssertEqual(KeyEncoder.encode(.text("b"), .option, noMeta), [0x62])
        XCTAssertEqual(KeyEncoder.encode(.backspace, .option, ctx), [0x1b, 0x7f])
    }

    func testCommandIsNeverSent() {
        XCTAssertEqual(KeyEncoder.encode(.text("c"), .command, ctx), [])
        XCTAssertEqual(KeyEncoder.encode(.up, [.command, .shift], ctx), [])
    }

    func testCursorKeys() {
        XCTAssertEqual(s(KeyEncoder.encode(.up, [], ctx)), "\u{1b}[A")
        var app = ctx
        app.applicationCursor = true
        XCTAssertEqual(s(KeyEncoder.encode(.up, [], app)), "\u{1b}OA")
        XCTAssertEqual(s(KeyEncoder.encode(.left, .control, app)), "\u{1b}[1;5D")
        XCTAssertEqual(s(KeyEncoder.encode(.right, [.shift, .option], ctx)), "\u{1b}[1;4C")
        XCTAssertEqual(s(KeyEncoder.encode(.pageUp, [], ctx)), "\u{1b}[5~")
        XCTAssertEqual(s(KeyEncoder.encode(.delete, .control, ctx)), "\u{1b}[3;5~")
        XCTAssertEqual(s(KeyEncoder.encode(.tab, .shift, ctx)), "\u{1b}[Z")
    }

    func testFunctionKeys() {
        XCTAssertEqual(s(KeyEncoder.encode(.function(1), [], ctx)), "\u{1b}OP")
        XCTAssertEqual(s(KeyEncoder.encode(.function(5), [], ctx)), "\u{1b}[15~")
        XCTAssertEqual(s(KeyEncoder.encode(.function(12), [], ctx)), "\u{1b}[24~")
        XCTAssertEqual(KeyEncoder.encode(.function(13), [], ctx), [])
    }

    func testEnterAndNewline() {
        XCTAssertEqual(KeyEncoder.encode(.enter, [], ctx), [0x0d])
        // 括弧付きペーストが無効なら ESC+CR
        XCTAssertEqual(KeyEncoder.encode(.newline, [], ctx), [0x1b, 0x0d])
        var bp = ctx
        bp.bracketedPaste = true
        XCTAssertEqual(s(KeyEncoder.encode(.newline, [], bp)), "\u{1b}[200~\n\u{1b}[201~")
        bp.newline = .ctrlJ
        XCTAssertEqual(KeyEncoder.encode(.newline, [], bp), [0x0a])
        bp.newline = .escCR
        XCTAssertEqual(KeyEncoder.encode(.newline, [], bp), [0x1b, 0x0d])
    }

    func testPaste() {
        XCTAssertEqual(s(KeyEncoder.paste("a\nb\r\nc", ctx)), "a\rb\rc")
        var bp = ctx
        bp.bracketedPaste = true
        // 貼った文字に終わりの印を仕込んでも、印は送られない（ESC を取り除く）
        XCTAssertEqual(s(KeyEncoder.paste("x\u{1b}[201~y", bp)), "\u{1b}[200~x[201~y\u{1b}[201~")
    }

    /// 制御文字（ESC・ctrl-C・C1）は貼り付けから取り除く。タブと改行は残す
    func testPasteDropsControlCharacters() {
        XCTAssertEqual(KeyEncoder.sanitizePaste("a\u{1b}]52;c;x\u{07}b\u{03}c\u{9b}d\te\nf"), "a]52;c;xbcd\te\rf")
        XCTAssertEqual(KeyEncoder.sanitizePaste("日本語"), "日本語")
    }

    func testMultiLinePasteNeedsConfirmationOnlyWithoutBracketedPaste() {
        XCTAssertTrue(KeyEncoder.pasteRunsCommands("ls\nrm -rf x", ctx))
        XCTAssertFalse(KeyEncoder.pasteRunsCommands("ls\n", ctx))
        XCTAssertFalse(KeyEncoder.pasteRunsCommands("ls", ctx))
        var bp = ctx
        bp.bracketedPaste = true
        XCTAssertFalse(KeyEncoder.pasteRunsCommands("ls\nrm -rf x", bp))
    }

    func testHorizontalMoveCountsWideCharsOnce() {
        // 「aあb」: a(1) あ(2,0) b(1)
        let widths = [1, 2, 0, 1]
        XCTAssertEqual(s(KeyEncoder.horizontalMove(from: 0, to: 3, widths: widths, ctx)), "\u{1b}[C\u{1b}[C")
        XCTAssertEqual(s(KeyEncoder.horizontalMove(from: 3, to: 0, widths: widths, ctx)), "\u{1b}[D\u{1b}[D")
        XCTAssertEqual(KeyEncoder.horizontalMove(from: 2, to: 2, widths: widths, ctx), [])
    }
}

final class GestureTests: XCTestCase {
    func testModeDecision() {
        XCTAssertEqual(GestureMode.decide(mouseReporting: true, alternateScreen: true, allowMouse: true), .mouse)
        XCTAssertEqual(GestureMode.decide(mouseReporting: true, alternateScreen: true, allowMouse: false), .alternateScroll)
        XCTAssertEqual(GestureMode.decide(mouseReporting: false, alternateScreen: true, allowMouse: true), .alternateScroll)
        XCTAssertEqual(GestureMode.decide(mouseReporting: false, alternateScreen: false, allowMouse: true), .normal)
    }

    func testSGR() {
        let s = { (b: [UInt8]) in String(decoding: b, as: UTF8.self) }
        XCTAssertEqual(s(MouseEncoder.click(.left, col: 0, row: 0)), "\u{1b}[<0;1;1M\u{1b}[<0;1;1m")
        XCTAssertEqual(s(MouseEncoder.press(.wheelUp, col: 9, row: 4)), "\u{1b}[<64;10;5M")
        XCTAssertEqual(s(MouseEncoder.drag(.left, col: 1, row: 1, mods: .control)), "\u{1b}[<48;2;2M")
    }

    func testScrollAccumulatorCarriesRemainder() {
        var a = ScrollAccumulator(lineHeight: 10)
        XCTAssertEqual(a.add(4), 0)
        XCTAssertEqual(a.add(7), 1)
        XCTAssertEqual(a.add(-12), -1)
        XCTAssertEqual(a.add(25), 2)
    }

    func testZoomSteps() {
        var z = ZoomSteps(steps: [85, 100])
        XCTAssertEqual(z.percent, 85)
        z.zoom(in: true)
        XCTAssertEqual(z.percent, 100)
        z.zoom(in: true)
        XCTAssertEqual(z.percent, 100)
        z.zoom(in: false)
        XCTAssertEqual(z.percent, 85)
        z.cycle()
        XCTAssertEqual(z.percent, 100)
        z.cycle()
        XCTAssertEqual(z.percent, 85)
    }
}

final class KeyboardTests: XCTestCase {
    func testFlickDirection() {
        XCTAssertEqual(FlickDirection.resolve(dx: 3, dy: -4, threshold: 12), .center)
        XCTAssertEqual(FlickDirection.resolve(dx: -20, dy: 5, threshold: 12), .left)
        XCTAssertEqual(FlickDirection.resolve(dx: 2, dy: -30, threshold: 12), .up)
        XCTAssertEqual(FlickDirection.resolve(dx: 30, dy: 2, threshold: 12), .right)
        XCTAssertEqual(FlickDirection.resolve(dx: 0, dy: 20, threshold: 12), .down)
    }

    /// 方向のしきい値は押したキーの大きさから: 短い辺 × 0.3 を 8〜16pt に
    func testFlickThresholdFollowsTheKeySize() {
        // 13 mini のフリック（幅 36、高さ 49）→ 短い辺 36 × 0.3
        XCTAssertEqual(FlickDirection.threshold(keySize: CGSize(width: 36.4, height: 49.2)), 36.4 * 0.3, accuracy: 0.001)
        // 短い辺で決まる（縦横を入れ替えても同じ）
        XCTAssertEqual(FlickDirection.threshold(keySize: CGSize(width: 40, height: 60)),
                       FlickDirection.threshold(keySize: CGSize(width: 60, height: 40)))
        // 小さいキーでも 8pt、大きいキーでも 16pt まで
        XCTAssertEqual(FlickDirection.threshold(keySize: CGSize(width: 12, height: 12)), 8)
        XCTAssertEqual(FlickDirection.threshold(keySize: CGSize(width: 200, height: 200)), 16)
        // キーが大きいほど大きく（単調に増える）、範囲の外には出ない
        let sizes = stride(from: 10.0, through: 90, by: 5).map { FlickDirection.threshold(keySize: CGSize(width: $0, height: $0 * 1.3)) }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertTrue(sizes.allSatisfy { FlickDirection.thresholdRange.contains($0) })
        // 決め打ち（pitch × 0.45 = 13 mini で 13.5pt）より軽く決まる
        XCTAssertLessThan(FlickDirection.threshold(keySize: CGSize(width: 36, height: 49)), 13.5)
    }

    /// ガイドは文字のある方向だけ。無い方向は中央の文字になる
    func testFlickSetAssignedAndFallback() {
        let abc = FlickSet("a", "b", "c", nil, nil)
        XCTAssertEqual(abc.assigned(.center), "a")
        XCTAssertEqual(abc.assigned(.left), "b")
        XCTAssertEqual(abc.assigned(.up), "c")
        XCTAssertNil(abc.assigned(.right))
        XCTAssertNil(abc.assigned(.down))
        XCTAssertEqual(abc.character(.right), "a")
        XCTAssertEqual(abc.character(.down), "a")
        XCTAssertEqual(FlickDirection.allCases.count, 5)
    }

    func testJISFacesFillTheirRect() {
        let rect = CGRect(x: 44, y: 40, width: 182, height: 246)
        for face in [KeyboardLayouts.jisLeft, KeyboardLayouts.jisRight, KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight,
                     KeyboardLayouts.alphaLeft, KeyboardLayouts.alphaRight] {
            let frames = face.frames(in: rect)
            // 段ごとに、左端から右端まで埋まる（2 段にまたがるキー・上下に分けた矢印も含めて）
            let rowTops = Set(frames.map { ($0.frame.minY * 100).rounded() / 100 })
            for top in rowTops {
                let inRow = frames.filter { abs($0.frame.minY - top) < 0.01 }
                    + frames.filter { $0.frame.minY < top - 0.01 && $0.frame.maxY > top + 0.01 }
                XCTAssertEqual(inRow.map(\.frame.minX).min() ?? 0, rect.minX, accuracy: 0.01)
                XCTAssertEqual(inRow.map(\.frame.maxX).max() ?? 0, rect.maxX, accuracy: 0.01)
            }
            XCTAssertEqual(frames.map(\.frame.maxY).max() ?? 0, rect.maxY, accuracy: 0.01)
            XCTAssertEqual(frames.map(\.frame.minY).min() ?? 0, rect.minY, accuracy: 0.01)
        }
    }

    /// 利用者の写真（Magic Keyboard の JIS）から日本語の刻印を外した配列
    func testJISFollowsThePhoto() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 280)
        let left = KeyboardLayouts.jisLeft.frames(in: rect)
        let right = KeyboardLayouts.jisRight.frames(in: rect)
        func key(_ frames: [(key: KeySpec, frame: CGRect)], _ id: String) -> (key: KeySpec, frame: CGRect)? {
            frames.first { $0.key.id == id }
        }
        // shift の記号は JIS（2 は "、7 は '、; は +、: は *、@ は `）
        XCTAssertEqual(key(left, "ch-2")?.key.subLabel, "\"")
        XCTAssertEqual(key(right, "ch-7")?.key.subLabel, "'")
        XCTAssertEqual(key(right, "ch-;")?.key.subLabel, "+")
        XCTAssertEqual(key(right, "ch-:")?.key.subLabel, "*")
        XCTAssertEqual(key(right, "ch-@")?.key.subLabel, "`")
        XCTAssertEqual(key(right, "ch-^")?.key.subLabel, "~")
        // L の右は ; と :、P の右は @ と [
        XCTAssertLessThan(key(right, "ch-l")!.frame.maxX, key(right, "ch-;")!.frame.maxX)
        XCTAssertEqual(key(right, "ch-;")!.frame.minY, key(right, "ch-l")!.frame.minY)
        XCTAssertEqual(key(right, "ch-@")!.frame.minY, key(right, "ch-p")!.frame.minY)
        // ¥ のキーは \ を打つ（option で ¥）
        if case .character(let c, let shifted, _) = key(right, "ch-yen")!.key.action {
            XCTAssertEqual(c, "\\")
            XCTAssertEqual(shifted, "|")
        } else { XCTFail() }
        XCTAssertEqual(key(right, "ch-yen")?.key.option, "¥")
        // control は A の左、caps lock は左下
        XCTAssertEqual(key(left, "mod-control-l")!.frame.minY, key(left, "ch-a")!.frame.minY)
        XCTAssertEqual(key(left, "mod-control-l")!.frame.minX, rect.minX)
        XCTAssertEqual(key(left, "caps")!.frame.minX, rect.minX)
        XCTAssertEqual(key(left, "caps")!.frame.maxY, rect.maxY, accuracy: 0.01)
        // return は 2 段にまたがり、右端にある
        let send = key(right, "send")!
        XCTAssertEqual(send.key.rowSpan, 2)
        XCTAssertEqual(send.frame.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(send.frame.maxY, key(right, "ch-h")!.frame.maxY, accuracy: 0.01)
        // 6・Y・H・N の列（と F6）は左右の両方。左の右端と右の左端が同じキー
        for (r, id) in ["f6", "ch-6", "ch-y", "ch-h", "ch-n"].enumerated() {
            XCTAssertEqual(key(left, id)?.frame.maxX ?? 0, rect.maxX, accuracy: 0.01, id)
            XCTAssertEqual(key(right, id)?.frame.minX ?? -1, rect.minX, accuracy: 0.01, id)
            XCTAssertEqual(KeyboardLayouts.jisLeft.rows[r].last?.id, KeyboardLayouts.jisRight.rows[r].first?.id)
        }
        // 英数とかなの位置は赤い丸（スペースの隣）。🌐 は右の command の右
        XCTAssertEqual(key(left, "pointer-left")!.frame.maxX, key(left, "space-l")!.frame.minX, accuracy: 0.01)
        XCTAssertEqual(key(right, "pointer-right")!.frame.minX, key(right, "space-r")!.frame.maxX, accuracy: 0.01)
        XCTAssertEqual(key(right, "globe")!.frame.minX, key(right, "mod-command-r")!.frame.maxX, accuracy: 0.01)
        // F と J だけがホームポジション
        XCTAssertEqual(Set((left + right).filter { $0.key.homing }.map(\.key.id)), ["ch-f", "ch-j"])
        // ↑ と ↓ は 1 つの枠を上下に分ける
        let up = key(right, "up")!.frame, down = key(right, "down")!.frame
        XCTAssertEqual(up.maxY, down.minY, accuracy: 0.01)
        XCTAssertEqual(up.height, down.height, accuracy: 0.01)
        // F キーの段は低い
        XCTAssertLessThan(key(left, "f1")!.frame.height, key(left, "ch-q")!.frame.height)
    }

    /// フリック: 最下段の内側に赤い丸、外側の角に 🌐。ABC と あいう で、かなと英字を行き来する
    func testFlickFacesHavePointerAndGlobe() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        for (face, left) in [(KeyboardLayouts.kanaLeft, true), (KeyboardLayouts.kanaRight, false),
                             (KeyboardLayouts.alphaLeft, true), (KeyboardLayouts.alphaRight, false)] {
            let frames = face.frames(in: rect)
            let pointer = frames.first { if case .pointer = $0.key.action { return true } else { return false } }!.frame
            let globe = frames.first { $0.key.id == "globe" }!.frame
            XCTAssertEqual(pointer.maxY, rect.maxY, accuracy: 0.01)
            XCTAssertEqual(left ? pointer.maxX : pointer.minX, left ? rect.maxX : rect.minX, accuracy: 0.01)
            XCTAssertEqual(left ? globe.minX : globe.maxX, left ? rect.minX : rect.maxX, accuracy: 0.01)
            // 上の段（esc・矢印）は無い
            XCTAssertFalse(frames.contains { $0.key.id == "esc" || $0.key.id == "left" })
        }
        XCTAssertTrue(KeyboardLayouts.kanaLeft.rows.joined().contains { $0.action == .setKeyboard(.flickEnglish) })
        XCTAssertTrue(KeyboardLayouts.alphaLeft.rows.joined().contains { $0.action == .setKeyboard(.kana) })
        // 送信は「send」、改行は ↩︎
        XCTAssertEqual(KeyboardLayouts.kanaLeft.rows.joined().first { $0.id == "send" }?.label, "send")
        XCTAssertEqual(KeyboardLayouts.kanaLeft.rows.joined().first { $0.id == "newline" }?.label, "↩︎")
    }

    /// ポインタ: 大きくずらしたときだけ進み続け、ずれが大きいほど速く、上限で止まる
    func testPointerSpeedGrowsWithOffset() {
        XCTAssertEqual(PointerCurve.speed(for: 0), 0)
        XCTAssertEqual(PointerCurve.speed(for: PointerCurve.rateStart), 0)
        let speeds = stride(from: 16.0, through: 80, by: 4).map { PointerCurve.speed(for: CGFloat($0)) }
        XCTAssertEqual(speeds, speeds.sorted())
        XCTAssertGreaterThan(PointerCurve.speed(for: 40), PointerCurve.speed(for: 24) * 2)
        XCTAssertEqual(PointerCurve.speed(for: 500), PointerCurve.maxSpeed)
        // 細かい動きは、そのまま（倍率を掛けて）付いてくる
        XCTAssertGreaterThan(PointerCurve.directGain, 1)
    }

    func testKanaTallKeysSpanTwoRows() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight] {
            let frames = face.frames(in: rect)
            let tall = frames.filter { $0.key.rowSpan == 2 }
            XCTAssertEqual(tall.count, 1)
            XCTAssertEqual(tall[0].frame, CGRect(x: 160, y: 120, width: 40, height: 120))
            // その下の段の 4 つのキーは、縦 2 マスのキーとかさならない
            let bottom = frames.filter { $0.frame.minY == 180 }
            XCTAssertEqual(bottom.count, 4)
            XCTAssertTrue(bottom.allSatisfy { !$0.frame.intersects(tall[0].frame) })
        }
    }

    /// 送信と改行の位置（docs/design.md の表）
    func testKanaSendAndNewlinePositions() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        func at(_ face: KeyboardFace, _ id: String) -> CGRect? {
            face.frames(in: rect).first { $0.key.id == id }?.frame
        }
        XCTAssertEqual(at(KeyboardLayouts.kanaLeft, "newline")?.origin, CGPoint(x: 0, y: 180))
        XCTAssertEqual(at(KeyboardLayouts.kanaLeft, "send")?.origin, CGPoint(x: 160, y: 120))
        XCTAssertEqual(at(KeyboardLayouts.kanaRight, "send")?.origin, CGPoint(x: 0, y: 180))
        XCTAssertEqual(at(KeyboardLayouts.kanaRight, "newline")?.origin, CGPoint(x: 160, y: 120))
    }
}

final class KanaComposerTests: XCTestCase {
    let a = FlickSet("あ", "い", "う", "え", "お")
    let ka = FlickSet("か", "き", "く", "け", "こ")

    func testFlickAndToggle() {
        var k = KanaComposer()
        k.input(keyID: "a", set: a, direction: .up, now: 0)
        XCTAssertEqual(k.reading, "う")
        k.input(keyID: "a", set: a, direction: .center, now: 0.1)
        k.input(keyID: "a", set: a, direction: .center, now: 0.2)
        XCTAssertEqual(k.reading, "うい")
        // 間が空いたら新しい文字
        k.input(keyID: "a", set: a, direction: .center, now: 5)
        XCTAssertEqual(k.reading, "ういあ")
        // →で区切ると、同じキーでも新しい文字
        k.breakToggle()
        k.input(keyID: "a", set: a, direction: .center, now: 5.1)
        XCTAssertEqual(k.reading, "ういああ")
    }

    func testModifyCycles() {
        var k = KanaComposer()
        k.input(keyID: "ha", set: FlickSet("は", "ひ", "ふ", "へ", "ほ"), direction: .center, now: 0)
        k.modifyLast()
        XCTAssertEqual(k.reading, "ば")
        k.modifyLast()
        XCTAssertEqual(k.reading, "ぱ")
        k.modifyLast()
        XCTAssertEqual(k.reading, "は")
        XCTAssertEqual(KanaComposer.nextVariant(of: "つ"), "っ")
        XCTAssertEqual(KanaComposer.nextVariant(of: "ん"), "ん")
    }

    func testDeleteAndCommit() {
        var k = KanaComposer()
        XCTAssertFalse(k.deleteBackward())
        k.input(keyID: "ka", set: ka, direction: .center, now: 0)
        k.input(keyID: "a", set: a, direction: .center, now: 0)
        XCTAssertTrue(k.deleteBackward())
        XCTAssertEqual(k.commit(), "か")
        XCTAssertFalse(k.isComposing)
    }

    func testCandidates() {
        XCTAssertEqual(PassthroughConverter().candidates(for: "かな").map(\.text), ["かな", "カナ"])
        XCTAssertEqual(PassthroughConverter().candidates(for: "かな").map(\.consumed), [2, 2])
        XCTAssertEqual(PassthroughConverter().candidates(for: "ー").map(\.text), ["ー"])
        XCTAssertEqual(PassthroughConverter().candidates(for: ""), [])
        XCTAssertEqual(KanaComposer.katakana("ゔぁー"), "ヴァー")
    }

    /// 文節の候補は読みの先頭だけを確定し、残りは変換中のまま
    func testCommitPartialCandidate() {
        var k = KanaComposer()
        k.append("きょうは")
        XCTAssertEqual(k.commit(KanaCandidate(text: "今日", consumed: 3)), "今日")
        XCTAssertEqual(k.reading, "は")
        XCTAssertEqual(k.commit(KanaCandidate(text: "は", consumed: 99)), "は")
        XCTAssertFalse(k.isComposing)
    }
}

final class ConnectionTests: XCTestCase {
    // ed25519 の公開鍵（乱数の 32 バイトから作った）と、その SHA256 指紋（Python の hashlib で計算）
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKe1UsvBTcaJO2s0G9c4XqXNs5LJTYr9IDXbEbQJc677"
    let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGehbAIq7ZrgT/o2+MwOEvS8Fkhr1tFexvtjSy0dQ5bx"

    func testFingerprint() {
        XCTAssertEqual(HostKeyFingerprint.sha256(openSSHPublicKey: key),
                       "SHA256:+ikU8C8oD1TcGRmxJDyNnEM/WgNEfrfBZy1HShLPBqQ")
        XCTAssertEqual(HostKeyFingerprint.sha256(openSSHPublicKey: other + " comment"),
                       "SHA256:RFwL6QaX5HPHoqUXVmU3kEIMa29nqWTDWD5Lq2agtyI")
        XCTAssertNil(HostKeyFingerprint.sha256(openSSHPublicKey: "garbage"))
    }

    func testVerdict() {
        XCTAssertEqual(HostKeyVerdict.judge(stored: key, presented: key), .trusted)
        XCTAssertEqual(HostKeyVerdict.judge(stored: nil, presented: key),
                       .unknown(fingerprint: "SHA256:+ikU8C8oD1TcGRmxJDyNnEM/WgNEfrfBZy1HShLPBqQ"))
        XCTAssertEqual(HostKeyVerdict.judge(stored: other, presented: key),
                       .changed(expected: "SHA256:RFwL6QaX5HPHoqUXVmU3kEIMa29nqWTDWD5Lq2agtyI",
                                actual: "SHA256:+ikU8C8oD1TcGRmxJDyNnEM/WgNEfrfBZy1HShLPBqQ"))
    }

    func testBackoff() {
        let p = ReconnectPolicy()
        XCTAssertEqual(p.delay(forAttempt: 0), 0)
        XCTAssertEqual(p.delay(forAttempt: 3), 2)
        XCTAssertEqual(p.delay(forAttempt: 100), 15)
    }
}
