import XCTest
@testable import TermCore

/// セルの色を決める規則（反転・dim・隠す・最小コントラスト補正・太字を明るく。docs/design.md「色」）
final class CellColorTests: XCTestCase {
    private let fg = RGB(0xE6, 0xED, 0xF3)
    private let bg = RGB(0x07, 0x09, 0x0D)

    private func rules(minimumContrast: Double = 1, boldIsBright: Bool = false) -> CellColorRules {
        CellColorRules(foreground: fg, background: bg, palette: TermConfig.defaultPalette,
                       minimumContrast: minimumContrast, boldIsBright: boldIsBright)
    }

    // MARK: 256 色の表

    func testTableIsThePaletteThenTheXtermStandard() {
        let r = rules()
        XCTAssertEqual(r.table.count, 256)
        XCTAssertEqual(Array(r.table.prefix(16)), TermConfig.defaultPalette)
        XCTAssertEqual(r.table[16], RGB(0, 0, 0))
        XCTAssertEqual(r.table[21], RGB(0, 0, 255))
        XCTAssertEqual(r.table[46], RGB(0, 255, 0))
        XCTAssertEqual(r.table[196], RGB(255, 0, 0))
        XCTAssertEqual(r.table[231], RGB(255, 255, 255))
        XCTAssertEqual(r.table[232], RGB(8, 8, 8))
        XCTAssertEqual(r.table[255], RGB(238, 238, 238))
        XCTAssertNil(XTerm256.standard(15))
        XCTAssertNil(XTerm256.standard(256))
        for i in 16..<256 { XCTAssertEqual(r.table[i], XTerm256.standard(i), "\(i)") }
    }

    func testShortPaletteIsPaddedWithBlack() {
        let t = XTerm256.table(palette: [RGB(1, 2, 3)])
        XCTAssertEqual(t.count, 256)
        XCTAssertEqual(t[0], RGB(1, 2, 3))
        XCTAssertEqual(t[1], RGB(0, 0, 0))
        XCTAssertEqual(t[15], RGB(0, 0, 0))
    }

    // MARK: 色の指定

    func testColorSpecifications() {
        let r = rules()
        XCTAssertEqual(r.color(.palette(1), isForeground: true), TermConfig.defaultPalette[1])
        XCTAssertEqual(r.color(.palette(200), isForeground: false), r.table[200])
        // 範囲外は端に寄せる（落ちない）
        XCTAssertEqual(r.color(.palette(-3), isForeground: true), r.table[0])
        XCTAssertEqual(r.color(.palette(999), isForeground: true), r.table[255])
        XCTAssertEqual(r.color(.rgb(RGB(1, 2, 3)), isForeground: true), RGB(1, 2, 3))
        XCTAssertEqual(r.color(.defaultColor, isForeground: true), fg)
        XCTAssertEqual(r.color(.defaultColor, isForeground: false), bg)
        XCTAssertEqual(r.color(.defaultInverted, isForeground: true), bg)
        XCTAssertEqual(r.color(.defaultInverted, isForeground: false), fg)
    }

    func testPlainCellUsesItsOwnColors() {
        let out = rules().resolve(fg: .palette(2), bg: .rgb(RGB(10, 20, 30)), flags: [])
        XCTAssertEqual(out.fg, TermConfig.defaultPalette[2])
        XCTAssertEqual(out.bg, RGB(10, 20, 30))
    }

    // MARK: 太字を明るく（bold-is-bright）

    /// オン: 太字で、文字色がパレットの 0〜7 なら 8〜15
    func testBoldIsBrightMakesBoldPalette0To7BrightWhenOn() {
        let r = rules(boldIsBright: true)
        for i in 0..<8 {
            let out = r.resolve(fg: .palette(i), bg: .defaultColor, flags: [.bold])
            XCTAssertEqual(out.fg, TermConfig.defaultPalette[i + 8], "\(i)")
            XCTAssertEqual(out.bg, bg)
        }
        // 256 色の指定（38;5;N）でも、N が 0〜7 なら同じ
        XCTAssertEqual(r.brightened(.palette(3), flags: [.bold]), .palette(11))
    }

    /// オフ（既定）: 太字でも変えない
    func testBoldIsBrightOffLeavesBoldAlone() {
        let r = rules(boldIsBright: false)
        for i in 0..<8 {
            XCTAssertEqual(r.resolve(fg: .palette(i), bg: .defaultColor, flags: [.bold]).fg,
                           TermConfig.defaultPalette[i], "\(i)")
        }
        XCTAssertFalse(TermConfig().boldIsBright)
        XCTAssertFalse(CellColorRules(config: TermConfig()).boldIsBright)
    }

    /// オンでも効かないもの: 太字でない、パレットの 8 以上、true color、既定の色、背景
    func testBoldIsBrightDoesNotTouchOtherColors() {
        let r = rules(boldIsBright: true)
        XCTAssertEqual(r.brightened(.palette(1), flags: []), .palette(1))
        XCTAssertEqual(r.brightened(.palette(1), flags: [.dim, .inverse]), .palette(1))
        XCTAssertEqual(r.brightened(.palette(8), flags: [.bold]), .palette(8))
        XCTAssertEqual(r.brightened(.palette(9), flags: [.bold]), .palette(9))
        XCTAssertEqual(r.brightened(.palette(15), flags: [.bold]), .palette(15))
        XCTAssertEqual(r.brightened(.palette(100), flags: [.bold]), .palette(100))
        XCTAssertEqual(r.brightened(.palette(-1), flags: [.bold]), .palette(-1))
        XCTAssertEqual(r.brightened(.rgb(RGB(1, 0, 0)), flags: [.bold]), .rgb(RGB(1, 0, 0)))
        XCTAssertEqual(r.brightened(.defaultColor, flags: [.bold]), .defaultColor)
        XCTAssertEqual(r.brightened(.defaultInverted, flags: [.bold]), .defaultInverted)

        // true color の赤は、太字でもパレットの明るい赤にならない
        let trueRed = RGB(205, 49, 49)
        XCTAssertEqual(r.resolve(fg: .rgb(trueRed), bg: .defaultColor, flags: [.bold]).fg, trueRed)
        XCTAssertEqual(r.resolve(fg: .defaultColor, bg: .defaultColor, flags: [.bold]).fg, fg)
        // 背景には効かない
        XCTAssertEqual(r.resolve(fg: .defaultColor, bg: .palette(1), flags: [.bold]).bg, TermConfig.defaultPalette[1])
    }

    /// 太字を明るくするのは反転の前。反転すると、明るくした色が背景になる
    func testBoldIsBrightComesBeforeInverse() {
        let out = rules(boldIsBright: true).resolve(fg: .palette(1), bg: .defaultColor, flags: [.bold, .inverse])
        XCTAssertEqual(out.bg, TermConfig.defaultPalette[9])
        XCTAssertEqual(out.fg, bg)
    }

    func testConfigSwitchesReachTheRules() {
        var c = TermConfig()
        c.boldIsBright = true
        c.minimumContrast = 3
        let r = CellColorRules(config: c)
        XCTAssertTrue(r.boldIsBright)
        XCTAssertEqual(r.minimumContrast, 3)
        XCTAssertEqual(r.foreground, c.foreground)
        XCTAssertEqual(r.background, c.background)
        XCTAssertEqual(Array(r.table.prefix(16)), c.palette)
    }

    // MARK: 反転・dim・隠す

    func testInverseSwapsForegroundAndBackground() {
        let out = rules().resolve(fg: .palette(2), bg: .palette(4), flags: [.inverse])
        XCTAssertEqual(out.fg, TermConfig.defaultPalette[4])
        XCTAssertEqual(out.bg, TermConfig.defaultPalette[2])
        // 既定の色の反転（.defaultInverted）と、フラグの反転は別のもの
        let d = rules().resolve(fg: .defaultInverted, bg: .defaultInverted, flags: [])
        XCTAssertEqual(d.fg, bg)
        XCTAssertEqual(d.bg, fg)
    }

    func testDimMixesTheForegroundTowardTheBackground() {
        let out = rules().resolve(fg: .defaultColor, bg: .defaultColor, flags: [.dim])
        XCTAssertEqual(out.fg, Contrast.mix(fg, bg, 0.4))
        XCTAssertEqual(out.bg, bg)
    }

    func testInvisibleHidesTheForegroundEvenWithContrastCorrection() {
        let out = rules(minimumContrast: 7).resolve(fg: .palette(1), bg: .palette(0), flags: [.invisible])
        XCTAssertEqual(out.fg, out.bg)
        XCTAssertEqual(out.bg, TermConfig.defaultPalette[0])
    }

    // MARK: 最小コントラスト補正（minimum-contrast）

    /// 1 は補正しない。暗い文字が暗い背景の上でも、そのまま
    func testMinimumContrastOfOneDoesNotChangeColors() {
        let dark = RGB(0x1C, 0x21, 0x28)
        let r = rules(minimumContrast: 1)
        XCTAssertLessThan(Contrast.ratio(dark, bg), 1.5)
        XCTAssertEqual(r.resolve(fg: .rgb(dark), bg: .defaultColor, flags: []).fg, dark)
        XCTAssertEqual(r.resolve(fg: .palette(0), bg: .defaultColor, flags: []).fg, TermConfig.defaultPalette[0])
        // 既定の設定が補正しない（Ghostty の既定と同じ）
        XCTAssertEqual(TermConfig().minimumContrast, 1)
        let byConfig = CellColorRules(config: TermConfig())
        XCTAssertEqual(byConfig.resolve(fg: .rgb(dark), bg: .defaultColor, flags: []).fg, dark)
    }

    /// 1 より大きいと、下限に届くまで文字色を白の側へ寄せる
    func testMinimumContrastAboveOnePullsDarkColorsTowardWhite() {
        let dark = RGB(0x1C, 0x21, 0x28)
        let out = rules(minimumContrast: 4.5).resolve(fg: .rgb(dark), bg: .defaultColor, flags: [])
        XCTAssertNotEqual(out.fg, dark)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(out.fg, bg), 4.5 - 1e-6)
        XCTAssertEqual(out.bg, bg)
        // すでに足りている色は変えない
        XCTAssertEqual(rules(minimumContrast: 4.5).resolve(fg: .defaultColor, bg: .defaultColor, flags: []).fg, fg)
    }

    /// 補正の関数は呼び出し側から渡せる（描画は結果を覚える版を渡す）。補正しない設定と、隠すときは呼ばない
    func testReadableHookIsUsedOnlyWhenCorrectionApplies() {
        var calls: [(RGB, RGB)] = []
        let out = rules(minimumContrast: 4.5).resolve(fg: .palette(1), bg: .palette(0), flags: []) { f, b in
            calls.append((f, b))
            return RGB(1, 2, 3)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, TermConfig.defaultPalette[1])
        XCTAssertEqual(calls.first?.1, TermConfig.defaultPalette[0])
        XCTAssertEqual(out.fg, RGB(1, 2, 3))

        _ = rules(minimumContrast: 1).resolve(fg: .palette(1), bg: .palette(0), flags: []) { _, _ in
            XCTFail("補正しない設定では呼ばない")
            return RGB(0, 0, 0)
        }
        _ = rules(minimumContrast: 4.5).resolve(fg: .palette(1), bg: .palette(0), flags: [.invisible]) { _, _ in
            XCTFail("隠すときは呼ばない")
            return RGB(0, 0, 0)
        }
    }

    /// 補正は dim と反転の後の色に対して行う
    func testContrastCorrectionSeesTheInvertedAndDimmedColors() {
        var seen: (RGB, RGB)?
        _ = rules(minimumContrast: 4.5).resolve(fg: .palette(2), bg: .palette(4), flags: [.inverse, .dim]) { f, b in
            seen = (f, b)
            return f
        }
        let swappedFg = TermConfig.defaultPalette[4], swappedBg = TermConfig.defaultPalette[2]
        XCTAssertEqual(seen?.0, Contrast.mix(swappedFg, swappedBg, 0.4))
        XCTAssertEqual(seen?.1, swappedBg)
    }
}
