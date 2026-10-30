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
        // 上 40pt を空けて下寄せ、ホームインジケータの上まで
        XCTAssertEqual(r.leftKeyboard?.maxY, 375 - 21)
        XCTAssertEqual(r.leftKeyboard?.minY ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(r.environmentBar.height, 44)
        XCTAssertEqual(r.environmentBar.maxY, 375 - 21)
        XCTAssertEqual(r.shell.maxY, r.environmentBar.minY)
        XCTAssertNil(r.candidateBar)
    }

    func testKanaAddsCandidateBar() {
        var input = mini
        input.keyboard = .kana
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.candidateBar?.height, 34)
        XCTAssertEqual(r.candidateBar?.maxY, r.environmentBar.minY)
        XCTAssertEqual(r.shell.maxY, r.candidateBar?.minY)
        // キーボードの幅は US と同じ（切り替えてもシェルの桁数が変わらない）
        XCTAssertEqual(r.shell.width, LayoutEngine.compute(mini).shell.width)
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
