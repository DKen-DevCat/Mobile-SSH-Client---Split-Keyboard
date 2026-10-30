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

    func testUSFacesFillTheirRect() {
        let rect = CGRect(x: 44, y: 40, width: 182, height: 314)
        for face in [KeyboardLayouts.usLeft, KeyboardLayouts.usRight] {
            let frames = face.frames(in: rect)
            XCTAssertEqual(face.rows.count, 6)  // F キーの段 + 5 段
            // 段ごとに、左端から右端まで埋まる（2 段にまたがる return・上下に分けた矢印も含めて）
            let rowTops = Set(frames.map { ($0.frame.minY * 100).rounded() / 100 })
            for top in rowTops {
                let inRow = frames.filter { abs($0.frame.minY - top) < 0.01 && $0.frame.height > 1 }
                    + frames.filter { $0.frame.minY < top - 0.01 && $0.frame.maxY > top + 0.01 }
                XCTAssertEqual(inRow.map(\.frame.minX).min() ?? 0, rect.minX, accuracy: 0.01)
                XCTAssertEqual(inRow.map(\.frame.maxX).max() ?? 0, rect.maxX, accuracy: 0.01)
            }
            XCTAssertEqual(frames.map(\.frame.maxY).max() ?? 0, rect.maxY, accuracy: 0.01)
            XCTAssertEqual(frames.map(\.frame.minY).min() ?? 0, rect.minY, accuracy: 0.01)
        }
    }

    /// 写真の配列（Mac の英国式）: 刷ってある記号・return・F と J・ポインタの位置
    func testUSFollowsTheMacBritishLayout() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 280)
        let left = KeyboardLayouts.usLeft.frames(in: rect)
        let right = KeyboardLayouts.usRight.frames(in: rect)
        func key(_ frames: [(key: KeySpec, frame: CGRect)], _ id: String) -> (key: KeySpec, frame: CGRect)? {
            frames.first { $0.key.id == id }
        }
        // 3 は shift で £、option で #。2 は option で €
        XCTAssertEqual(key(left, "ch-3")?.key.subLabel, "£")
        XCTAssertEqual(key(left, "ch-3")?.key.option, "#")
        XCTAssertEqual(key(left, "ch-2")?.key.option, "€")
        XCTAssertEqual(key(left, "ch-§")?.key.subLabel, "±")
        // ` は Z の左、\ は A の段の右（ISO）
        XCTAssertNotNil(key(left, "ch-`"))
        XCTAssertLessThan(key(left, "ch-`")!.frame.minX, key(left, "ch-z")!.frame.minX)
        XCTAssertEqual(key(right, "ch-\\")?.frame.minY, key(right, "ch-h")?.frame.minY)
        // return は 2 段にまたがり、右端にある
        let send = key(right, "send")!
        XCTAssertEqual(send.key.rowSpan, 2)
        XCTAssertEqual(send.frame.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(send.frame.minY, key(right, "ch-y")!.frame.minY, accuracy: 0.01)
        XCTAssertEqual(send.frame.maxY, key(right, "ch-h")!.frame.maxY, accuracy: 0.01)
        // F と J だけがホームポジション
        XCTAssertEqual((left + right).filter { $0.key.homing }.map(\.key.id).sorted(), ["ch-f", "ch-j"])
        // ↑ と ↓ は 1 つの枠を上下に分ける
        let up = key(right, "up")!.frame, down = key(right, "down")!.frame
        XCTAssertEqual(up.minX, down.minX, accuracy: 0.01)
        XCTAssertEqual(up.maxY, down.minY, accuracy: 0.01)
        XCTAssertEqual(up.height, down.height, accuracy: 0.01)
        // ポインタはスペースの内側（左面の右端、右面の左端）
        let pl = key(left, "pointer-left")!.frame, pr = key(right, "pointer-right")!.frame
        XCTAssertEqual(pl.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(pr.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(key(left, "space-l")!.frame.maxX, pl.minX, accuracy: 0.01)
        XCTAssertEqual(key(right, "space-r")!.frame.minX, pr.maxX, accuracy: 0.01)
        // F キーの段は低い
        XCTAssertLessThan(key(left, "f1")!.frame.height, key(left, "ch-q")!.frame.height)
        // 🌐（fn）が最下段の左端
        XCTAssertEqual(key(left, "mod-fn")?.frame.minX, rect.minX)
    }

    /// ポインタ: 小さな揺れでは動かず、ずれが大きいほど速く、上限で止まる
    func testPointerSpeedGrowsWithOffset() {
        XCTAssertEqual(PointerCurve.speed(for: 0), 0)
        XCTAssertEqual(PointerCurve.speed(for: PointerCurve.deadZone), 0)
        let speeds = stride(from: 4.0, through: 60, by: 4).map { PointerCurve.speed(for: CGFloat($0)) }
        XCTAssertEqual(speeds, speeds.sorted())
        XCTAssertGreaterThan(PointerCurve.speed(for: 20), PointerCurve.speed(for: 8) * 2)
        XCTAssertEqual(PointerCurve.speed(for: 500), PointerCurve.maxSpeed)
    }

    func testKanaTallKeysSpanTwoRows() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight] {
            let frames = face.frames(in: rect)
            let tall = frames.filter { $0.key.rowSpan == 2 }
            XCTAssertEqual(tall.count, 1)
            XCTAssertEqual(tall[0].frame, CGRect(x: 160, y: 180, width: 40, height: 120))
            // 最下段の 4 つのキーは、縦 2 マスのキーとかさならない
            let bottom = frames.filter { $0.frame.minY == 240 }
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
        XCTAssertEqual(at(KeyboardLayouts.kanaLeft, "newline")?.origin, CGPoint(x: 0, y: 240))
        XCTAssertEqual(at(KeyboardLayouts.kanaLeft, "send")?.origin, CGPoint(x: 160, y: 180))
        XCTAssertEqual(at(KeyboardLayouts.kanaRight, "send")?.origin, CGPoint(x: 0, y: 240))
        XCTAssertEqual(at(KeyboardLayouts.kanaRight, "newline")?.origin, CGPoint(x: 160, y: 180))
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
