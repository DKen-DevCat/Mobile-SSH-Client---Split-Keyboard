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

    /// フリックの面は、枠いっぱいに(左端から右端、上端から下端まで)並ぶ。2 段にまたがるキーも含めて
    func testFlickFacesFillTheirRect() {
        let rect = CGRect(x: 44, y: 40, width: 182, height: 246)
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight, KeyboardLayouts.alphaLeft, KeyboardLayouts.alphaRight] {
            let frames = face.frames(in: rect)
            // 段ごとに、左端から右端まで埋まる
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

    /// id → 枠（上下に分けたキーは、子の id で）
    func frameTable(_ face: KeyboardFace, in rect: CGRect) -> [String: CGRect] {
        Dictionary(face.frames(in: rect).map { ($0.key.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// 段 r のキーの枠（上下に分けたキーは子の枠）
    func rowFrames(_ face: KeyboardFace, _ r: Int, _ table: [String: CGRect]) -> [CGRect] {
        face.rows[r].flatMap { key -> [CGRect] in
            key.stacked.isEmpty ? [table[key.id]].compactMap { $0 } : key.stacked.compactMap { table[$0.id] }
        }
    }

    /// 実物の比率: 左右・全段で共通の単位 u。1u のキーは u×u、F キーの段は高さ 0.6u、面は左 8.25u・右 9.5u × 5.6u
    func testJISKeysUseTheRealProportions() {
        let u: CGFloat = 24
        let leftRect = CGRect(x: 0, y: 0, width: 8.25 * u, height: 5.6 * u)
        let rightRect = CGRect(x: 0, y: 0, width: 9.5 * u, height: 5.6 * u)
        let left = frameTable(KeyboardLayouts.jisLeft, in: leftRect)
        let right = frameTable(KeyboardLayouts.jisRight, in: rightRect)
        let acc: CGFloat = 0.001

        // 両面のすべての 1u キーが同じ u×u。F キーの段は幅 u・高さ 0.6u
        for (face, table) in [(KeyboardLayouts.jisLeft, left), (KeyboardLayouts.jisRight, right)] {
            var squares = 0
            for (r, row) in face.rows.enumerated() {
                for key in row where key.width == 1 && key.stacked.isEmpty {
                    let f = table[key.id]!
                    XCTAssertEqual(f.width, u, accuracy: acc, key.id)
                    XCTAssertEqual(f.height, r == 0 ? 0.6 * u : u, accuracy: acc, key.id)
                    if r > 0 { squares += 1 }
                }
            }
            XCTAssertGreaterThan(squares, 20)
        }
        // ▲▼ は 1u の枠を上下に分ける（u × u/2 が 2 つ）
        XCTAssertEqual(right["up"]!.width, u, accuracy: acc)
        XCTAssertEqual(right["up"]!.height, u / 2, accuracy: acc)
        XCTAssertEqual(right["down"]!.height, u / 2, accuracy: acc)
        XCTAssertEqual(right["up"]!.maxY, right["down"]!.minY, accuracy: acc)

        // 幅が 1u でないキー（u 単位）
        let widths: [(String, CGFloat, CGFloat)] = [
            ("esc", 1.5, left["esc"]!.width), ("tab", 1.5, left["tab"]!.width),
            ("mod-control-l", 1.75, left["mod-control-l"]!.width), ("mod-shift-l", 2.25, left["mod-shift-l"]!.width),
            ("mod-command-l", 1.25, left["mod-command-l"]!.width), ("space-l", 4, left["space-l"]!.width),
            ("bs", 1.5, right["bs"]!.width), ("mod-shift-r", 1.25, right["mod-shift-r"]!.width),
            ("mod-command-r", 1.25, right["mod-command-r"]!.width), ("space-r", 3.25, right["space-r"]!.width),
            ("send", 1, right["send"]!.width), ("send-lower", 0.75, right["send-lower"]!.width),
        ]
        for (id, units, width) in widths { XCTAssertEqual(width, units * u, accuracy: acc, id) }

        // Q・A・Z の左端 = tab・control・shift の幅
        XCTAssertEqual(left["ch-q"]!.minX, 1.5 * u, accuracy: acc)
        XCTAssertEqual(left["ch-a"]!.minX, 1.75 * u, accuracy: acc)
        XCTAssertEqual(left["ch-z"]!.minX, 2.25 * u, accuracy: acc)

        // 段の高さ: F キーの段 0.6u の下に、1u の段が 5 つ（面の高さ 5.6u）
        let tops: [CGFloat] = [0, 0.6, 1.6, 2.6, 3.6, 4.6].map { $0 * u }
        for (face, table) in [(KeyboardLayouts.jisLeft, left), (KeyboardLayouts.jisRight, right)] {
            for r in 0..<6 {
                for key in face.rows[r] where key.stacked.isEmpty {
                    XCTAssertEqual(table[key.id]!.minY, tops[r], accuracy: acc, "row \(r) \(key.id)")
                }
            }
        }

        // 面の幅: 左 8.25u（左端をそろえる）、右 9.5u（右端をそろえる）。内側の端は段ごとにずれる
        let leftWidths: [CGFloat] = [7.5, 6, 7.5, 7.75, 8.25, 8.25]
        let rightWidths: [CGFloat] = [8, 9.5, 8, 7.75, 7.25, 9.5]
        for r in 0..<6 {
            let l = rowFrames(KeyboardLayouts.jisLeft, r, left)
            XCTAssertEqual(l.map(\.minX).min() ?? -1, 0, accuracy: acc, "left row \(r)")
            XCTAssertEqual(l.map(\.maxX).max() ?? -1, leftWidths[r] * u, accuracy: acc, "left row \(r)")
            let rr = rowFrames(KeyboardLayouts.jisRight, r, right)
            XCTAssertEqual(rr.map(\.maxX).max() ?? -1, 9.5 * u, accuracy: acc, "right row \(r)")
            XCTAssertEqual(rr.map(\.minX).min() ?? -1, (9.5 - rightWidths[r]) * u, accuracy: acc, "right row \(r)")
        }
        XCTAssertEqual(left.values.map(\.maxX).max() ?? 0, 8.25 * u, accuracy: acc)
        XCTAssertEqual(right.values.map(\.maxX).max() ?? 0, 9.5 * u, accuracy: acc)
        XCTAssertEqual(left.values.map(\.maxY).max() ?? 0, 5.6 * u, accuracy: acc)
        XCTAssertEqual(right.values.map(\.maxY).max() ?? 0, 5.6 * u, accuracy: acc)
        // 内側の端はそろわない（左の面の右端は段ごとにずれる）
        XCTAssertEqual(Set(leftWidths).count, 4)

        // 6・Y・H・N の列（と F6）は左右の両方。右の面は左の面の 5u の位置から始まる
        for id in ["f6", "ch-6", "ch-y", "ch-h", "ch-n"] {
            XCTAssertEqual(right[id]!.minX + 5 * u, left[id]!.minX, accuracy: acc, id)
            XCTAssertEqual(right[id]!.minY, left[id]!.minY, accuracy: acc, id)
            XCTAssertEqual(right[id]!.width, left[id]!.width, accuracy: acc, id)
        }
    }

    /// return は実物の逆 L 字: 上 1u と下 0.75u の 2 つの枠で、右端がそろう。どちらも送信で、つながって見える相手を指す
    func testReturnIsTwoJoinedKeys() {
        let u: CGFloat = 24
        let table = frameTable(KeyboardLayouts.jisRight, in: CGRect(x: 0, y: 0, width: 9.5 * u, height: 5.6 * u))
        let upper = table["send"]!, lower = table["send-lower"]!
        XCTAssertEqual(upper.maxX, 9.5 * u, accuracy: 0.001)
        XCTAssertEqual(lower.maxX, 9.5 * u, accuracy: 0.001)
        XCTAssertEqual(upper.minX, 8.5 * u, accuracy: 0.001)
        XCTAssertEqual(lower.minX, 8.75 * u, accuracy: 0.001)
        XCTAssertEqual(upper.maxY, lower.minY, accuracy: 0.001)
        XCTAssertEqual(upper.height, u, accuracy: 0.001)
        XCTAssertEqual(lower.height, u, accuracy: 0.001)
        // 上の枠は Y の段、下の枠は H の段
        XCTAssertEqual(upper.minY, table["ch-y"]!.minY, accuracy: 0.001)
        XCTAssertEqual(lower.minY, table["ch-h"]!.minY, accuracy: 0.001)
        let keys = KeyboardLayouts.jisRight.rows.joined()
        let sends = keys.filter { $0.action == .send }
        XCTAssertEqual(Set(sends.map(\.id)), ["send", "send-lower"])
        XCTAssertEqual(sends.first { $0.id == "send" }?.joinedWith, "send-lower")
        XCTAssertEqual(sends.first { $0.id == "send-lower" }?.joinedWith, "send")
        XCTAssertTrue(sends.allSatisfy { $0.rowSpan == 1 })
    }

    /// 利用者の写真（Magic Keyboard の JIS）から日本語の刻印を外した配列
    func testJISFollowsThePhoto() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 280)
        let left = frameTable(KeyboardLayouts.jisLeft, in: rect)
        let right = frameTable(KeyboardLayouts.jisRight, in: rect)
        func spec(_ face: KeyboardFace, _ id: String) -> KeySpec? { face.rows.joined().first { $0.id == id } }
        // shift の記号は JIS（2 は "、7 は '、; は +、: は *、@ は `）
        XCTAssertEqual(spec(KeyboardLayouts.jisLeft, "ch-2")?.subLabel, "\"")
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-7")?.subLabel, "'")
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-;")?.subLabel, "+")
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-:")?.subLabel, "*")
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-@")?.subLabel, "`")
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-^")?.subLabel, "~")
        // L の右は ; と :、P の右は @ と [
        XCTAssertLessThan(right["ch-l"]!.maxX, right["ch-;"]!.maxX)
        XCTAssertEqual(right["ch-;"]!.minY, right["ch-l"]!.minY)
        XCTAssertEqual(right["ch-@"]!.minY, right["ch-p"]!.minY)
        // ¥ のキーは \ を打つ（option で ¥）
        if case .character(let c, let shifted, _) = spec(KeyboardLayouts.jisRight, "ch-yen")!.action {
            XCTAssertEqual(c, "\\")
            XCTAssertEqual(shifted, "|")
        } else { XCTFail() }
        XCTAssertEqual(spec(KeyboardLayouts.jisRight, "ch-yen")?.option, "¥")
        // control は A の左、caps lock は左下
        XCTAssertEqual(left["mod-control-l"]!.minY, left["ch-a"]!.minY)
        XCTAssertEqual(left["mod-control-l"]!.minX, rect.minX)
        XCTAssertEqual(left["caps"]!.minX, rect.minX)
        XCTAssertEqual(left["caps"]!.maxY, rect.maxY, accuracy: 0.01)
        // 6・Y・H・N の列（と F6）は左右の両方で、同じキー
        for (r, id) in ["f6", "ch-6", "ch-y", "ch-h", "ch-n"].enumerated() {
            XCTAssertEqual(KeyboardLayouts.jisLeft.rows[r].last?.id, KeyboardLayouts.jisRight.rows[r].first?.id)
            XCTAssertEqual(KeyboardLayouts.jisLeft.rows[r].last?.id, id)
        }
        // 🌐 は右の command の右。もう 1 つの 🌐 は右の面の左下（空白兼ポインタの左）
        XCTAssertEqual(right["globe"]!.minX, right["mod-command-r"]!.maxX, accuracy: 0.01)
        XCTAssertEqual(right["globe-inner"]!.maxX, right["space-r"]!.minX, accuracy: 0.01)
        // F と J だけがホームポジション
        let all = Array(KeyboardLayouts.jisLeft.rows.joined()) + Array(KeyboardLayouts.jisRight.rows.joined())
        XCTAssertEqual(Set(all.filter { $0.homing }.map { $0.id }), ["ch-f", "ch-j"])
        // ↑ と ↓ は 1 つの枠を上下に分ける
        let up = right["up"]!, down = right["down"]!
        XCTAssertEqual(up.maxY, down.minY, accuracy: 0.01)
        XCTAssertEqual(up.height, down.height, accuracy: 0.01)
        // F キーの段は低い
        XCTAssertLessThan(left["f1"]!.height, left["ch-q"]!.height)
    }

    /// 最下段の並び（docs/design.md の表）。赤い丸のキーは無く、左右の空白キーがポインタを兼ねる。🌐 は修飾キーの fn で見分ける
    func testBottomRowsFollowTheDesign() {
        func ids(_ face: KeyboardFace) -> [String] { face.rows.last!.map(\.id) }
        func widths(_ face: KeyboardFace) -> [CGFloat] { face.rows.last!.map(\.width) }
        XCTAssertEqual(ids(KeyboardLayouts.jisLeft), ["caps", "mod-option-l", "mod-command-l", "space-l", "attach"])
        XCTAssertEqual(widths(KeyboardLayouts.jisLeft), [1, 1, 1.25, 4, 1])
        XCTAssertEqual(ids(KeyboardLayouts.jisRight),
                       ["globe-inner", "space-r", "mod-command-r", "globe", "left", "updown", "right"])
        XCTAssertEqual(widths(KeyboardLayouts.jisRight), [1, 3.25, 1.25, 1, 1, 1, 1])
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.alphaLeft] {
            XCTAssertEqual(ids(face), ["globe", "space-b", "attach"])
            XCTAssertEqual(widths(face), [1, 3, 1])
        }
        for face in [KeyboardLayouts.kanaRight, KeyboardLayouts.alphaRight] {
            XCTAssertEqual(ids(face), ["globe-inner", "space-b", "globe"])
            XCTAssertEqual(widths(face), [1, 3, 1])
        }
        let jis = KeyboardLayouts.jisLeft.rows.last! + KeyboardLayouts.jisRight.rows.last!
        // 空白兼ポインタは左右の面に 1 つずつ。ID は space-l・space-r・space-b
        XCTAssertEqual(KeyboardLayouts.jisLeft.rows.last!.first { $0.id == "space-l" }?.action, .spacePointer(.left))
        XCTAssertEqual(KeyboardLayouts.jisRight.rows.last!.first { $0.id == "space-r" }?.action, .spacePointer(.right))
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.alphaLeft] {
            XCTAssertEqual(face.rows.last!.first { $0.id == "space-b" }?.action, .spacePointer(.left))
        }
        for face in [KeyboardLayouts.kanaRight, KeyboardLayouts.alphaRight] {
            XCTAssertEqual(face.rows.last!.first { $0.id == "space-b" }?.action, .spacePointer(.right))
        }
        // 🌐 はどれも fn の修飾キー（長押しは ID ではなく fn で見分ける）。ID は面の中で重ならない
        let faces = [KeyboardLayouts.jisLeft, KeyboardLayouts.jisRight, KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight,
                     KeyboardLayouts.alphaLeft, KeyboardLayouts.alphaRight]
        for face in faces {
            let keys = Array(face.rows.joined())
            XCTAssertEqual(Set(keys.map(\.id)).count, keys.count, "ID が重なっている")
            for g in keys where g.symbol == "globe" { XCTAssertEqual(g.action, .modifier(.fn), g.id) }
            for a in keys where a.id == "attach" { XCTAssertEqual(a.action, .attachMedia) }
            // 赤い丸のキーは無い
            XCTAssertFalse(keys.contains { $0.id.hasPrefix("pointer") })
        }
        XCTAssertEqual(jis.filter { $0.symbol == "globe" }.count, 2)
        XCTAssertEqual(KeyboardLayouts.jisLeft.rows.joined().filter { $0.action == .attachMedia }.count, 1)
        XCTAssertTrue(KeyboardLayouts.jisRight.rows.joined().allSatisfy { $0.action != .attachMedia })
    }

    /// フリックの 2 段目の「空白」は普通の空白（空白兼ポインタではない。長押しのトラックパッドは今のまま）
    func testFlickSpaceKeyIsAPlainSpace() {
        for face in [KeyboardLayouts.kanaLeft, KeyboardLayouts.kanaRight, KeyboardLayouts.alphaLeft, KeyboardLayouts.alphaRight] {
            let space = face.rows[1].last!
            XCTAssertEqual(space.id, "space")
            XCTAssertEqual(space.label, "空白")
            XCTAssertEqual(space.action, .character(" ", shifted: nil, fn: nil))
        }
        // 分割の空白兼ポインタは、普通の空白（character " "）ではない
        XCTAssertNotEqual(KeyboardLayouts.jisLeft.rows.last![3].action, .character(" ", shifted: nil, fn: nil))
    }

    /// フリック: 最下段は 左「🌐・空白兼ポインタ（3）・📎」、右「🌐・空白兼ポインタ（3）・🌐」。ABC と あいう で、かなと英字を行き来する
    func testFlickFacesHaveSpacePointerAndGlobes() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        for (face, left) in [(KeyboardLayouts.kanaLeft, true), (KeyboardLayouts.kanaRight, false),
                             (KeyboardLayouts.alphaLeft, true), (KeyboardLayouts.alphaRight, false)] {
            let table = frameTable(face, in: rect)
            let space = table["space-b"]!
            XCTAssertEqual(space.maxY, rect.maxY, accuracy: 0.01)
            XCTAssertEqual(space.width, 120, accuracy: 0.01)
            XCTAssertEqual(space.minX, 40, accuracy: 0.01)
            // 外側の角は 🌐（左の面では左端、右の面では右端）。内側（シェル側）は、左が 📎、右が 🌐
            XCTAssertEqual(table["globe"]!.minX, left ? rect.minX : 160, accuracy: 0.01)
            XCTAssertEqual(left ? table["attach"]!.minX : table["globe-inner"]!.minX, left ? 160 : rect.minX, accuracy: 0.01)
            // 上の段（esc・矢印）は無い
            XCTAssertNil(table["esc"])
            XCTAssertNil(table["left"])
        }
        XCTAssertTrue(KeyboardLayouts.kanaLeft.rows.joined().contains { $0.action == .setKeyboard(.flickEnglish) })
        XCTAssertTrue(KeyboardLayouts.alphaLeft.rows.joined().contains { $0.action == .setKeyboard(.kana) })
        // 送信は「send」、改行は ↩︎
        XCTAssertEqual(KeyboardLayouts.kanaLeft.rows.joined().first { $0.id == "send" }?.label, "send")
        XCTAssertEqual(KeyboardLayouts.kanaLeft.rows.joined().first { $0.id == "newline" }?.label, "↩︎")
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
