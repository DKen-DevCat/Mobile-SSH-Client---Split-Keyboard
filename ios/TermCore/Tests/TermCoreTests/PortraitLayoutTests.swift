import CoreGraphics
import XCTest
@testable import TermCore

/// 縦持ちの配置（docs/design.md「縦持ちの配置」）
final class PortraitLayoutTests: XCTestCase {
    /// iPhone 13 mini の縦持ち（375×812pt。上のセーフエリア 50、下 34）
    let mini = LayoutInput(size: CGSize(width: 375, height: 812), safeArea: Insets(top: 50, bottom: 34))
    let acc: CGFloat = 0.001

    func testMiniMatchesDesign() throws {
        let r = LayoutEngine.compute(mini)
        XCTAssertEqual(r.orientation, .portrait)
        XCTAssertEqual(r.mode, .full)
        // u = 375 ÷ 14.5（切り捨てない）、1 段の高さは u と 44 の大きい方
        XCTAssertEqual(r.unit, 375 / 14.5, accuracy: acc)
        XCTAssertEqual(r.rowHeight, 44)
        let kb = try XCTUnwrap(r.fullKeyboard)
        XCTAssertEqual(kb.width, 375, accuracy: acc)
        XCTAssertEqual(kb.height, 44 * 5.6, accuracy: acc)
        XCTAssertEqual(kb.minX, 0, accuracy: acc)
        // 下寄せ（ホームインジケータの上まで）
        XCTAssertEqual(kb.maxY, 812 - 34, accuracy: acc)
        // 分割の面と選択のボタンは無い
        XCTAssertNil(r.leftKeyboard)
        XCTAssertNil(r.rightKeyboard)
        XCTAssertNil(r.keyboardButton)
        XCTAssertNil(r.candidateBar)
        // タブの 1 行は上のセーフエリアの下・左右いっぱい。状態の行は無く、タブの 1 行の右端の幅 0 の枠
        XCTAssertEqual(r.tabRow, CGRect(x: 0, y: 50, width: 375, height: 32))
        XCTAssertEqual(r.statusRow, CGRect(x: 375, y: 50, width: 0, height: 32))
        // シェルはタブの 1 行の下から、キーボードの 8pt 上まで（重ねない）
        XCTAssertEqual(r.shell.minY, 82)
        XCTAssertEqual(r.shell.minX, 0)
        XCTAssertEqual(r.shell.width, 375)
        XCTAssertEqual(kb.minY - r.shell.maxY, LayoutEngine.keyboardGap, accuracy: acc)
        XCTAssertEqual(r.shell.height, 441.6, accuracy: acc)
        XCTAssertFalse(r.shell.intersects(r.tabRow))
        XCTAssertFalse(r.shell.intersects(kb))
    }

    /// ローマ字（かな漢字変換）のときは、キーボードのすぐ上に候補バー。シェルはその 8pt 上まで。キーボードの枠は英語と同じ
    func testRomajiPutsTheCandidateBarOnTheKeyboard() throws {
        var input = mini
        input.keyboard = .romaji
        let r = LayoutEngine.compute(input)
        let english = LayoutEngine.compute(mini)
        let bar = try XCTUnwrap(r.candidateBar)
        let kb = try XCTUnwrap(r.fullKeyboard)
        XCTAssertEqual(bar.height, LayoutEngine.candidateBarHeight)
        XCTAssertEqual(bar.maxY, kb.minY, accuracy: acc)
        XCTAssertEqual(bar.width, 375)
        XCTAssertEqual(bar.minY - r.shell.maxY, LayoutEngine.keyboardGap, accuracy: acc)
        XCTAssertEqual(r.shell.height, 407.6, accuracy: acc)
        XCTAssertEqual(r.fullKeyboard, english.fullKeyboard)
        // 横持ちと同じく、かな漢字変換を使う種類だけ
        for kind in KeyboardKind.allCases {
            var i = mini
            i.keyboard = kind
            XCTAssertEqual(LayoutEngine.compute(i).candidateBar != nil, kind.isJapanese, kind.rawValue)
        }
    }

    /// 設計書の縦持ちの表（u・1 段の高さ・キーボードの高さ・シェル）
    func testDeviceTable() throws {
        // (画面, セーフエリア, u, 1 段の高さ, キーボードの高さ, シェルの高さ)
        let rows: [(CGSize, Insets, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (CGSize(width: 375, height: 667), Insets(top: 20), 25.86, 44, 246.4, 360.6),
            (CGSize(width: 375, height: 812), Insets(top: 50, bottom: 34), 25.86, 44, 246.4, 441.6),
            (CGSize(width: 393, height: 852), Insets(top: 59, bottom: 34), 27.10, 44, 246.4, 472.6),
            (CGSize(width: 440, height: 956), Insets(top: 62, bottom: 34), 30.34, 44, 246.4, 573.6),
            (CGSize(width: 744, height: 1133), Insets(top: 24, bottom: 20), 51.31, 51.31, 287.3, 761.7),
            (CGSize(width: 768, height: 1024), Insets(top: 20), 52.97, 52.97, 296.6, 667.4),
            (CGSize(width: 820, height: 1180), Insets(top: 24, bottom: 20), 56.55, 56.55, 316.7, 779.3),
            (CGSize(width: 1032, height: 1376), Insets(top: 24, bottom: 20), 71.17, 71.17, 398.6, 893.4),
        ]
        for (size, safe, u, row, kbHeight, shell) in rows {
            let r = LayoutEngine.compute(LayoutInput(size: size, safeArea: safe))
            XCTAssertEqual(r.mode, .full, "\(size)")
            XCTAssertEqual(r.unit, u, accuracy: 0.005, "\(size)")
            XCTAssertEqual(r.rowHeight, row, accuracy: 0.005, "\(size)")
            let kb = try XCTUnwrap(r.fullKeyboard, "\(size)")
            XCTAssertEqual(kb.height, kbHeight, accuracy: 0.05, "\(size)")
            XCTAssertEqual(kb.width, size.width, accuracy: acc, "\(size)")
            XCTAssertEqual(r.shell.width, size.width, "\(size)")
            XCTAssertEqual(r.shell.height, shell, accuracy: 0.05, "\(size)")
        }
    }

    /// iPhone のキーは縦に長く（幅 u < 1 段の高さ 44）、iPad は正方形（u が 44 を超える）
    func testKeysAreTallOnIPhoneAndSquareOnIPad() throws {
        let phone = LayoutEngine.compute(mini)
        XCTAssertLessThan(phone.unit, phone.rowHeight)
        XCTAssertEqual(phone.rowHeight, LayoutEngine.portraitMinRowHeight)
        let pad = LayoutEngine.compute(LayoutInput(size: CGSize(width: 820, height: 1180), safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(pad.unit, pad.rowHeight)
        XCTAssertGreaterThan(pad.unit, LayoutEngine.portraitMinRowHeight)
        // 1u の文字キーの枠: iPhone は u × 44、iPad は u × u（面の並びは同じ）
        let phoneKeys = KeyboardLayouts.jisFull.frames(in: try XCTUnwrap(phone.fullKeyboard))
        let q = try XCTUnwrap(phoneKeys.first { $0.key.id == "ch-q" }?.frame)
        XCTAssertEqual(q.width, phone.unit, accuracy: acc)
        XCTAssertEqual(q.height, 44, accuracy: acc)
        let f1 = try XCTUnwrap(phoneKeys.first { $0.key.id == "f1" }?.frame)
        XCTAssertEqual(f1.height, 44 * KeyboardLayouts.functionRowWeight, accuracy: acc)
    }

    /// 窓の高さが幅より大きければ縦持ち。同じ大きさ（正方形）は横持ち
    func testOrientationFollowsTheWindowShape() {
        XCTAssertTrue(LayoutEngine.isPortrait(CGSize(width: 375, height: 812)))
        XCTAssertFalse(LayoutEngine.isPortrait(CGSize(width: 812, height: 375)))
        XCTAssertFalse(LayoutEngine.isPortrait(CGSize(width: 600, height: 600)))
        XCTAssertFalse(LayoutEngine.isPortrait(.zero))
        let landscape = LayoutEngine.compute(LayoutInput(size: CGSize(width: 812, height: 375),
                                                         safeArea: Insets(left: 44, bottom: 21, right: 44)))
        XCTAssertEqual(landscape.orientation, .landscape)
        XCTAssertNil(landscape.fullKeyboard)
        XCTAssertEqual(landscape.mode, .split)
    }

    /// 縦長の狭い窓（iPad の Split View の半分など）も縦持ちの作り（前は横持ちの分割を縮めていた）
    func testTallNarrowWindowIsPortrait() throws {
        let half = LayoutEngine.compute(LayoutInput(size: CGSize(width: 590, height: 820), safeArea: Insets()))
        XCTAssertEqual(half.orientation, .portrait)
        XCTAssertEqual(half.mode, .full)
        XCTAssertEqual(half.unit, 590 / 14.5, accuracy: acc)
        XCTAssertEqual(try XCTUnwrap(half.fullKeyboard).width, 590, accuracy: acc)
    }

    /// キー 1 つが 18pt を割る狭さ（幅 261pt 未満）なら、画面のキーボードを隠してシェルだけ（タブの 1 行の下から下端まで）
    func testNarrowPortraitGivesUp() {
        let edge = LayoutEngine.compute(LayoutInput(size: CGSize(width: 18 * 14.5, height: 820), safeArea: Insets()))
        XCTAssertEqual(edge.mode, .full)
        XCTAssertEqual(edge.unit, LayoutEngine.minimumUnit, accuracy: acc)
        let under = LayoutEngine.compute(LayoutInput(size: CGSize(width: 260, height: 820), safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(under.mode, .tooNarrow)
        XCTAssertEqual(under.orientation, .portrait)
        XCTAssertNil(under.fullKeyboard)
        XCTAssertNil(under.candidateBar)
        XCTAssertEqual(under.shell, CGRect(x: 0, y: 24 + 32, width: 260, height: 820 - 20 - 24 - 32))
    }

    /// 低い窓: シェルに 120pt が残るまで 1 段の高さを縮め（キーの幅もそれより大きくしない）、18pt を割るなら隠す
    func testShortPortraitShrinksTheRowsToKeepTheShell() throws {
        // 利用できる高さ = 500 − 32 − 120 − 8 = 340 → 1 段 = 340 ÷ 5.6 ≈ 60.7。u = 480 ÷ 14.5 ≈ 33.1 なので 1 段は 44 のまま
        let roomy = LayoutEngine.compute(LayoutInput(size: CGSize(width: 480, height: 500), safeArea: Insets()))
        XCTAssertEqual(roomy.rowHeight, 44)
        // 利用できる高さ = 400 − 32 − 120 − 8 = 240 → 1 段 = 240 ÷ 5.6 ≈ 42.9（44 を割る。u ≈ 26.2 はそのまま）
        let short = LayoutEngine.compute(LayoutInput(size: CGSize(width: 380, height: 400), safeArea: Insets()))
        XCTAssertEqual(short.mode, .full)
        XCTAssertEqual(short.rowHeight, 240 / 5.6, accuracy: acc)
        XCTAssertEqual(short.unit, 380 / 14.5, accuracy: acc)
        XCTAssertEqual(short.shell.height, LayoutEngine.minimumShellHeight, accuracy: acc)
        // さらに低いと u も 1 段の高さまで縮み、18 を割れば隠す
        let lower = LayoutEngine.compute(LayoutInput(size: CGSize(width: 380, height: 390), safeArea: Insets()))
        XCTAssertLessThan(lower.rowHeight, 44)
        let tiny = LayoutEngine.compute(LayoutInput(size: CGSize(width: 380, height: 381), safeArea: Insets()))
        // (381 − 160) ÷ 5.6 ≈ 39.5 なので、まだ出す。キーの幅は 1 段の高さを超えない
        XCTAssertEqual(tiny.mode, .full)
        XCTAssertLessThanOrEqual(tiny.unit, tiny.rowHeight)
        // ローマ字は候補バーの分だけ低くなる
        var romaji = LayoutInput(size: CGSize(width: 380, height: 400), safeArea: Insets())
        romaji.keyboard = .romaji
        let r = LayoutEngine.compute(romaji)
        XCTAssertEqual(r.rowHeight, (240 - 34) / 5.6, accuracy: acc)
        XCTAssertEqual(r.shell.height, LayoutEngine.minimumShellHeight, accuracy: acc)
    }

    /// ハードウェアキーボード: 画面のキーボードを出さず、シェルはタブの 1 行の下から下端まで（トラックパッドのまま）
    func testHardwareKeyboardInPortrait() {
        var input = LayoutInput(size: CGSize(width: 820, height: 1180), safeArea: Insets(top: 24, bottom: 20))
        input.hardwareKeyboard = true
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.mode, .hardware)
        XCTAssertEqual(r.orientation, .portrait)
        XCTAssertNil(r.fullKeyboard)
        XCTAssertEqual(r.shell, CGRect(x: 0, y: 56, width: 820, height: 1180 - 20 - 56))
        input.softKeyboardWithHardware = true
        XCTAssertEqual(LayoutEngine.compute(input).mode, .full)
    }

    /// keyboard-pitch は縦持ちでもキーの幅（u）。幅に収まる値より大きければ、幅に収まる値。左右の中央に置く
    func testPitchOverrideInPortrait() throws {
        var input = mini
        input.pitchOverride = 22
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.unit, 22)
        XCTAssertEqual(r.rowHeight, 44)
        let kb = try XCTUnwrap(r.fullKeyboard)
        XCTAssertEqual(kb.width, 22 * 14.5, accuracy: acc)
        XCTAssertEqual(kb.midX, 375 / 2, accuracy: acc)
        input.pitchOverride = 40
        XCTAssertEqual(LayoutEngine.compute(input).unit, 375 / 14.5, accuracy: acc)
    }

    /// 左右のセーフエリアがあるとき（縦持ちの iPhone では無いが、窓の形は自由）は、その内側
    func testSideSafeAreaIsRespected() throws {
        let r = LayoutEngine.compute(LayoutInput(size: CGSize(width: 400, height: 800), safeArea: Insets(top: 20, left: 10, right: 10)))
        let kb = try XCTUnwrap(r.fullKeyboard)
        XCTAssertEqual(kb.minX, 10, accuracy: acc)
        XCTAssertEqual(kb.maxX, 390, accuracy: acc)
        XCTAssertEqual(r.tabRow.minX, 10)
        XCTAssertEqual(r.tabRow.width, 380)
        XCTAssertEqual(r.shell.minX, 10)
        XCTAssertEqual(r.shell.width, 380)
    }
}
