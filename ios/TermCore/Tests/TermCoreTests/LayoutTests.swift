import CoreGraphics
import XCTest
@testable import TermCore

final class LayoutTests: XCTestCase {
    /// iPhone 13 mini の横持ち（設計の基準）
    let mini = LayoutInput(size: CGSize(width: 812, height: 375), safeArea: Insets(left: 44, bottom: 21, right: 44))

    func testMiniMatchesDesign() {
        let r = LayoutEngine.compute(mini)
        XCTAssertEqual(r.mode, .split)
        XCTAssertEqual(r.pitch, 30)
        XCTAssertEqual(r.leftKeyboard?.width, 182)
        XCTAssertEqual(r.rightKeyboard?.width, 182)
        XCTAssertEqual(r.shell.width, 344)
        XCTAssertEqual(r.leftKeyboard?.minX, 44)
        XCTAssertEqual(r.rightKeyboard?.maxX, 812 - 44)
        // 高さは幅 × 1.35 まで（やや縦長）。分割は下寄せで、ホームインジケータの上まで
        XCTAssertEqual(r.leftKeyboard?.height, (182 * LayoutEngine.keyboardAspect).rounded())
        XCTAssertEqual(r.leftKeyboard?.maxY, 375 - 21)
        // シェルは上端から下端まで（下のバーは無い）
        XCTAssertEqual(r.shell.minY, 0)
        XCTAssertEqual(r.shell.maxY, 375 - 21)
        XCTAssertEqual(r.shell.height, 354)
        // 上の 2 行は、セーフエリアの左右いっぱい・上端から
        XCTAssertEqual(r.statusRow, CGRect(x: 44, y: 0, width: 812 - 88, height: 20))
        XCTAssertEqual(r.tabRow, CGRect(x: 44, y: 20, width: 812 - 88, height: 32))
        XCTAssertEqual(LayoutEngine.keyboardTopGap, 52)
        XCTAssertNil(r.candidateBar)
    }

    func testKanaAddsCandidateBar() {
        var input = mini
        input.keyboard = .kana
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.candidateBar?.height, 34)
        // 候補バーはシェルの下端に置き、シェルはその上まで
        XCTAssertEqual(r.candidateBar?.maxY, 375 - 21)
        XCTAssertEqual(r.shell.maxY, r.candidateBar?.minY)
        XCTAssertEqual(r.shell.minY, 0)
        // キーボードの幅は英語と同じ（切り替えてもシェルの桁数が変わらない）
        XCTAssertEqual(r.shell.width, LayoutEngine.compute(mini).shell.width)
        XCTAssertEqual(r.leftKeyboard?.height, LayoutEngine.compute(mini).leftKeyboard?.height)
    }

    /// フリックも、分割と同じく下に寄せる
    func testFlickKeyboardsAreBottomAligned() {
        let bottom: CGFloat = 375 - 21
        for kind in KeyboardKind.allCases {
            var input = mini
            input.keyboard = kind
            let r = LayoutEngine.compute(input)
            XCTAssertEqual(r.leftKeyboard?.maxY, bottom, kind.rawValue)
            XCTAssertEqual(r.rightKeyboard?.maxY, bottom, kind.rawValue)
            XCTAssertEqual(r.leftKeyboard?.height, LayoutEngine.compute(mini).leftKeyboard?.height, kind.rawValue)
        }
    }

    /// キーボードは上の 2 行に重ならない（高さの足りない窓でも。画面の上端が 0 でも 24 でも）
    func testKeyboardNeverOverlapsTheTopRows() {
        let cases: [LayoutInput] = [
            mini,
            LayoutInput(size: CGSize(width: 667, height: 375), safeArea: Insets()),
            LayoutInput(size: CGSize(width: 1180, height: 820), safeArea: Insets(top: 24, bottom: 20)),
            // 高さが足りない窓（キーボードの高さが空きに合わせて縮む）
            LayoutInput(size: CGSize(width: 1000, height: 200), safeArea: Insets(top: 24, bottom: 20)),
        ]
        for base in cases {
            for kind in KeyboardKind.allCases {
                var input = base
                input.keyboard = kind
                let r = LayoutEngine.compute(input)
                for kb in [r.leftKeyboard, r.rightKeyboard] {
                    guard let kb else { return XCTFail("split のはず \(input.size)") }
                    XCTAssertGreaterThanOrEqual(kb.minY, r.tabRow.maxY - 0.001, "\(input.size) \(kind.rawValue)")
                }
            }
        }
    }

    /// シェルは上端から（上の 2 行がシェルに重なる）。シェルの表示範囲は縮めない
    func testShellStartsAtTheTopAndTheRowsOverlapIt() {
        let r = LayoutEngine.compute(LayoutInput(size: CGSize(width: 1180, height: 820),
                                                 safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(r.shell.minY, 24)
        XCTAssertEqual(r.shell.maxY, 820 - 20)
        XCTAssertEqual(r.statusRow.minY, 24)
        XCTAssertEqual(r.tabRow.minY, r.statusRow.maxY)
        XCTAssertEqual(r.tabRow.height, LayoutEngine.tabRowHeight)
        XCTAssertTrue(r.shell.intersects(r.statusRow))
        XCTAssertTrue(r.shell.intersects(r.tabRow))
        // 2 行は左右のセーフエリアの内側いっぱい（シェルより広い）
        XCTAssertEqual(r.statusRow.width, 1180)
        XCTAssertGreaterThan(r.tabRow.width, r.shell.width)
    }

    /// キーボード選択のボタンは、シェルの右下の角（候補バーがあればその上）。split のときだけ
    func testKeyboardButtonSitsInTheShellCorner() {
        for kind in KeyboardKind.allCases {
            var input = mini
            input.keyboard = kind
            let r = LayoutEngine.compute(input)
            guard let b = r.keyboardButton else { return XCTFail(kind.rawValue) }
            XCTAssertEqual(b.size, CGSize(width: 36, height: 36))
            XCTAssertEqual(b.maxX, r.shell.maxX - 6, kind.rawValue)
            XCTAssertEqual(b.maxY, r.shell.maxY - 6, kind.rawValue)
            XCTAssertTrue(r.shell.contains(b), kind.rawValue)
            if let c = r.candidateBar { XCTAssertLessThanOrEqual(b.maxY, c.minY, kind.rawValue) }
        }
    }

    /// ハードウェアキーボード・狭すぎる窓: シェルは左右いっぱい・上端から下端まで。上の 2 行はある。キーボード選択は出さない
    func testFullShellKeepsTheTopRowsAndHasNoKeyboardButton() {
        var hw = LayoutInput(size: CGSize(width: 1180, height: 820), safeArea: Insets(top: 24, bottom: 20))
        hw.hardwareKeyboard = true
        let slim = LayoutInput(size: CGSize(width: 320, height: 820), safeArea: Insets(top: 24, bottom: 20))
        for input in [hw, slim] {
            let r = LayoutEngine.compute(input)
            XCTAssertNil(r.keyboardButton)
            XCTAssertNil(r.candidateBar)
            XCTAssertEqual(r.shell.minY, 24)
            XCTAssertEqual(r.shell.maxY, 820 - 20)
            XCTAssertEqual(r.shell.width, input.size.width)
            XCTAssertEqual(r.statusRow, CGRect(x: 0, y: 24, width: input.size.width, height: 20))
            XCTAssertEqual(r.tabRow, CGRect(x: 0, y: 44, width: input.size.width, height: 32))
        }
    }

    /// かな漢字変換を使うキーボード（ローマ字・かな・英字フリックのローマ字）だけ候補バーを出す
    func testCandidateBarFollowsTheKeyboard() {
        for kind in KeyboardKind.allCases {
            var input = mini
            input.keyboard = kind
            XCTAssertEqual(LayoutEngine.compute(input).candidateBar != nil, kind.isJapanese, kind.rawValue)
        }
    }

    func testIPadScalesUpAndCapsRowHeight() {
        // iPad Air 11 インチの横持ち
        let r = LayoutEngine.compute(LayoutInput(size: CGSize(width: 1180, height: 820),
                                                 safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(r.mode, .split)
        XCTAssertEqual(r.pitch, 50)
        XCTAssertEqual(r.leftKeyboard?.width, 304)
        XCTAssertEqual(r.rowHeight, LayoutEngine.maximumRowHeight)
        XCTAssertEqual(r.shell.width, 1180 - 304 * 2 - 16)
        XCTAssertEqual(r.shell.minY, 24)
    }

    func testHardwareKeyboardGivesFullShell() {
        var input = LayoutInput(size: CGSize(width: 1180, height: 820), safeArea: Insets(top: 24, bottom: 20))
        input.hardwareKeyboard = true
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.mode, .hardware)
        XCTAssertNil(r.leftKeyboard)
        XCTAssertEqual(r.shell.width, 1180)
        input.softKeyboardWithHardware = true
        XCTAssertEqual(LayoutEngine.compute(input).mode, .split)
    }

    func testNarrowWindowShrinksPitchThenGivesUp() {
        // Split View の半分ほど
        let half = LayoutEngine.compute(LayoutInput(size: CGSize(width: 590, height: 820), safeArea: Insets()))
        XCTAssertEqual(half.mode, .split)
        XCTAssertLessThan(half.pitch, 50)
        XCTAssertGreaterThanOrEqual(half.shell.width, LayoutEngine.minimumShellWidth - 1)
        // 細い窓
        let slim = LayoutEngine.compute(LayoutInput(size: CGSize(width: 320, height: 820), safeArea: Insets()))
        XCTAssertEqual(slim.mode, .tooNarrow)
        XCTAssertEqual(slim.shell.width, 320)
    }

    func testPitchOverride() {
        var input = mini
        input.pitchOverride = 26
        XCTAssertEqual(LayoutEngine.compute(input).leftKeyboard?.width, (26 * LayoutEngine.keyboardWidthUnits).rounded())
    }

    func testCellGridAndHitTest() {
        // 13 mini の実倍率で 85%
        let m = CellMetrics(scale: 2.88, widthPx: 14, heightPx: 29)
        let g = m.grid(for: CGSize(width: 344, height: 310))
        XCTAssertEqual(g.cols, Int(344 * 2.88) / 14)
        XCTAssertEqual(g.rows, Int(310 * 2.88) / 29)
        XCTAssertEqual(m.cell(at: CGPoint(x: -5, y: 9999), cols: g.cols, rows: g.rows).col, 0)
        XCTAssertEqual(m.cell(at: CGPoint(x: -5, y: 9999), cols: g.cols, rows: g.rows).row, g.rows - 1)
        let c = m.cell(at: CGPoint(x: m.widthPt * 3.5, y: m.heightPt * 2.5), cols: g.cols, rows: g.rows)
        XCTAssertEqual(c.col, 3)
        XCTAssertEqual(c.row, 2)
    }
}
