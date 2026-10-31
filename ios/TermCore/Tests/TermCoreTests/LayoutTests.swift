import CoreGraphics
import XCTest
@testable import TermCore

final class LayoutTests: XCTestCase {
    /// iPhone 13 mini の横持ち（設計の基準）
    let mini = LayoutInput(size: CGSize(width: 812, height: 375), safeArea: Insets(left: 44, bottom: 21, right: 44))

    func testMiniMatchesDesign() {
        let r = LayoutEngine.compute(mini)
        XCTAssertEqual(r.mode, .split)
        // u = 短辺 375 × 0.064 = 24。左 8.25u = 198、右 9.5u = 228、高さ 5.6u = 134.4
        XCTAssertEqual(r.unit, 24)
        XCTAssertEqual(r.rowHeight, 24)
        XCTAssertEqual(r.leftKeyboard?.width, 198)
        XCTAssertEqual(r.rightKeyboard?.width, 228)
        XCTAssertEqual(r.leftKeyboard?.height ?? 0, 134.4, accuracy: 0.001)
        XCTAssertEqual(r.rightKeyboard?.height ?? 0, 134.4, accuracy: 0.001)
        XCTAssertEqual(r.shell.width, 282)
        XCTAssertEqual(r.leftKeyboard?.minX, 44)
        XCTAssertEqual(r.rightKeyboard?.maxX, 812 - 44)
        // 左右ともシェルとの隙間は 8pt
        XCTAssertEqual(r.shell.minX - (r.leftKeyboard?.maxX ?? 0), LayoutEngine.keyboardGap)
        XCTAssertEqual((r.rightKeyboard?.minX ?? 0) - r.shell.maxX, LayoutEngine.keyboardGap)
        // 分割は下寄せで、ホームインジケータの上まで（左右とも）
        XCTAssertEqual(r.leftKeyboard?.maxY ?? 0, 375 - 21, accuracy: 0.001)
        XCTAssertEqual(r.rightKeyboard?.maxY ?? 0, 375 - 21, accuracy: 0.001)
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

    /// 面の単位（8.25・9.5・5.6）は KeyboardLayouts の 1 か所にあり、LayoutEngine の枠も面の並びも同じ値を使う
    func testFaceUnitsAreSharedWithTheLayouts() {
        XCTAssertEqual(KeyboardLayouts.leftUnits, 8.25)
        XCTAssertEqual(KeyboardLayouts.rightUnits, 9.5)
        XCTAssertEqual(KeyboardLayouts.heightUnits, 5.6, accuracy: 1e-9)
        XCTAssertEqual(KeyboardLayouts.functionRowWeight, 0.6)
        // 面の並び（JIS）: 格子の幅と、最も長い段の幅が単位と同じ。高さの比の合計も
        let left = KeyboardLayouts.jisLeft, right = KeyboardLayouts.jisRight
        XCTAssertEqual(left.gridUnits, KeyboardLayouts.leftUnits)
        XCTAssertEqual(right.gridUnits, KeyboardLayouts.rightUnits)
        XCTAssertEqual(left.rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0, KeyboardLayouts.leftUnits, accuracy: 1e-9)
        XCTAssertEqual(right.rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0, KeyboardLayouts.rightUnits, accuracy: 1e-9)
        XCTAssertEqual(left.totalWeight, KeyboardLayouts.heightUnits, accuracy: 1e-9)
        XCTAssertEqual(right.totalWeight, KeyboardLayouts.heightUnits, accuracy: 1e-9)
        // LayoutEngine の枠: 幅は u × 単位、高さは u × 5.6
        for u: CGFloat in [20, 24, 28] {
            var input = mini
            input.pitchOverride = Double(u)
            let r = LayoutEngine.compute(input)
            XCTAssertEqual(r.leftKeyboard?.width ?? 0, u * KeyboardLayouts.leftUnits, accuracy: 0.001, "u \(u)")
            XCTAssertEqual(r.rightKeyboard?.width ?? 0, u * KeyboardLayouts.rightUnits, accuracy: 0.001, "u \(u)")
            XCTAssertEqual(r.leftKeyboard?.height ?? 0, u * KeyboardLayouts.heightUnits, accuracy: 0.001, "u \(u)")
        }
        // フリックの面は、同じ枠いっぱいに 5 段（格子 5）を並べる
        for kind in [KeyboardKind.kana, .flickRomaji, .flickEnglish] {
            let faces = KeyboardLayouts.faces(for: kind)
            for face in [faces.left, faces.right] {
                XCTAssertEqual(face.gridUnits, 5)
                XCTAssertEqual(face.rows.count, 5)
                XCTAssertNil(face.rowWeights)
            }
        }
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
        // キーボードの枠は英語と同じ（切り替えてもシェルの桁数が変わらない）
        XCTAssertEqual(r.shell.width, LayoutEngine.compute(mini).shell.width)
        XCTAssertEqual(r.leftKeyboard, LayoutEngine.compute(mini).leftKeyboard)
        XCTAssertEqual(r.rightKeyboard, LayoutEngine.compute(mini).rightKeyboard)
    }

    /// フリックも、分割と同じ枠（左 198・右 228、高さ 134.4）で、下に寄せる
    func testFlickKeyboardsUseTheSameFrameAndAreBottomAligned() {
        let bottom: CGFloat = 375 - 21
        let base = LayoutEngine.compute(mini)
        for kind in KeyboardKind.allCases {
            var input = mini
            input.keyboard = kind
            let r = LayoutEngine.compute(input)
            XCTAssertEqual(r.leftKeyboard?.maxY ?? 0, bottom, accuracy: 0.001, kind.rawValue)
            XCTAssertEqual(r.rightKeyboard?.maxY ?? 0, bottom, accuracy: 0.001, kind.rawValue)
            XCTAssertEqual(r.leftKeyboard, base.leftKeyboard, kind.rawValue)
            XCTAssertEqual(r.rightKeyboard, base.rightKeyboard, kind.rawValue)
            XCTAssertEqual(r.leftKeyboard?.width, 198, kind.rawValue)
            XCTAssertEqual(r.rightKeyboard?.width, 228, kind.rawValue)
            XCTAssertEqual(r.unit, 24, kind.rawValue)
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
        // 2026-10-31: 狭い窓は 320×820（縦長）だったが、縦長の窓は縦持ちの作りになったので、横長のまま狭い窓（400×300）にした
        let slim = LayoutInput(size: CGSize(width: 400, height: 300), safeArea: Insets(top: 24, bottom: 20))
        for input in [hw, slim] {
            let r = LayoutEngine.compute(input)
            XCTAssertEqual(r.orientation, .landscape)
            XCTAssertNil(r.keyboardButton)
            XCTAssertNil(r.candidateBar)
            XCTAssertNil(r.fullKeyboard)
            XCTAssertEqual(r.shell.minY, 24)
            XCTAssertEqual(r.shell.maxY, input.size.height - 20)
            XCTAssertEqual(r.shell.width, input.size.width)
            XCTAssertEqual(r.statusRow, CGRect(x: 0, y: 24, width: input.size.width, height: 20))
            XCTAssertEqual(r.tabRow, CGRect(x: 0, y: 44, width: input.size.width, height: 32))
        }
        XCTAssertEqual(LayoutEngine.compute(slim).mode, .tooNarrow)
    }

    /// かな漢字変換を使うキーボード（ローマ字・かな・英字フリックのローマ字）だけ候補バーを出す
    func testCandidateBarFollowsTheKeyboard() {
        for kind in KeyboardKind.allCases {
            var input = mini
            input.keyboard = kind
            XCTAssertEqual(LayoutEngine.compute(input).candidateBar != nil, kind.isJapanese, kind.rawValue)
        }
    }

    func testIPadUsesTheLargestUnit() {
        // iPad Air 11 インチの横持ち: 短辺 820 × 0.064 = 52 は上限の 36 に収まる
        let r = LayoutEngine.compute(LayoutInput(size: CGSize(width: 1180, height: 820),
                                                 safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(r.mode, .split)
        XCTAssertEqual(r.unit, 36)
        XCTAssertEqual(r.rowHeight, 36)
        XCTAssertEqual(r.leftKeyboard?.width, 297)
        XCTAssertEqual(r.rightKeyboard?.width, 342)
        XCTAssertEqual(r.leftKeyboard?.height ?? 0, 201.6, accuracy: 0.001)
        XCTAssertEqual(r.shell.width, 1180 - 297 - 342 - 16)
        XCTAssertEqual(r.shell.minY, 24)
        XCTAssertEqual(r.leftKeyboard?.maxY ?? 0, 820 - 20, accuracy: 0.001)
    }

    /// 設計書の端末の表（u・左右の幅・シェルの幅）
    func testDeviceTable() {
        // (画面, セーフエリア, u, 左, 右, シェルの幅)
        let rows: [(CGSize, Insets, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (CGSize(width: 667, height: 375), Insets(), 24, 198, 228, 225),
            (CGSize(width: 812, height: 375), Insets(left: 44, bottom: 21, right: 44), 24, 198, 228, 282),
            (CGSize(width: 852, height: 393), Insets(left: 59, bottom: 21, right: 59), 25, 206.25, 237.5, 274.25),
            (CGSize(width: 956, height: 440), Insets(left: 62, bottom: 21, right: 62), 28, 231, 266, 319),
            (CGSize(width: 1133, height: 744), Insets(top: 24, bottom: 20), 36, 297, 342, 478),
            (CGSize(width: 1024, height: 768), Insets(bottom: 20), 36, 297, 342, 369),
            (CGSize(width: 1180, height: 820), Insets(top: 24, bottom: 20), 36, 297, 342, 525),
            (CGSize(width: 1376, height: 1032), Insets(top: 24, bottom: 20), 36, 297, 342, 721),
        ]
        for (size, safe, u, left, right, shell) in rows {
            let r = LayoutEngine.compute(LayoutInput(size: size, safeArea: safe))
            XCTAssertEqual(r.mode, .split, "\(size)")
            XCTAssertEqual(r.unit, u, "\(size)")
            XCTAssertEqual(r.leftKeyboard?.width ?? 0, left, accuracy: 0.001, "\(size)")
            XCTAssertEqual(r.rightKeyboard?.width ?? 0, right, accuracy: 0.001, "\(size)")
            XCTAssertEqual(r.shell.width, shell, accuracy: 0.001, "\(size)")
        }
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

    /// 2026-10-31: 窓の大きさは 590×820 などの縦長（Split View の半分）だったが、縦長の窓は縦持ちの作りになったので
    /// （testTallNarrowWindowIsPortrait）、横長のまま狭い窓（高さ 400）にした。u の求め方と境目の値は変わらない
    func testNarrowWindowShrinksTheUnitThenGivesUp() {
        // 横長で狭い窓: u = 切り捨て((590 − 200 − 16) ÷ 17.75) = 21
        let half = LayoutEngine.compute(LayoutInput(size: CGSize(width: 590, height: 400), safeArea: Insets()))
        XCTAssertEqual(half.mode, .split)
        XCTAssertEqual(half.unit, 21)
        XCTAssertLessThan(half.unit, 36)
        XCTAssertGreaterThanOrEqual(half.shell.width, LayoutEngine.minimumShellWidth)
        // 切り捨てなので、もう 1 つ大きい u ではシェルが 200pt を割る
        XCTAssertLessThan(590 - 22 * 17.75 - 16, LayoutEngine.minimumShellWidth)
        // 18 まで縮めても収まる幅（536）は出し、割る幅（535）は隠す
        let edge = LayoutEngine.compute(LayoutInput(size: CGSize(width: 536, height: 400), safeArea: Insets()))
        XCTAssertEqual(edge.mode, .split)
        XCTAssertEqual(edge.unit, LayoutEngine.minimumUnit)
        XCTAssertGreaterThanOrEqual(edge.shell.width, LayoutEngine.minimumShellWidth)
        let under = LayoutEngine.compute(LayoutInput(size: CGSize(width: 535, height: 400), safeArea: Insets()))
        XCTAssertEqual(under.mode, .tooNarrow)
        XCTAssertNil(under.leftKeyboard)
        // 細い窓（横長のまま）
        let slim = LayoutEngine.compute(LayoutInput(size: CGSize(width: 320, height: 300), safeArea: Insets()))
        XCTAssertEqual(slim.mode, .tooNarrow)
        XCTAssertEqual(slim.shell.width, 320)
        XCTAssertNil(slim.keyboardButton)
    }

    /// 低い窓: 5.6u が「下端 − 上端 − 上の 2 行」に収まるまで u を縮め、18pt を割るなら隠す
    func testShortWindowShrinksTheUnitToFitUnderTheTopRows() throws {
        // 利用できる高さ = 200 − 20 − 24 − 52 = 104 → 切り捨て(104 ÷ 5.6) = 18
        let short = LayoutEngine.compute(LayoutInput(size: CGSize(width: 1000, height: 200), safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(short.mode, .split)
        XCTAssertEqual(short.unit, 18)
        let kb = try XCTUnwrap(short.leftKeyboard)
        XCTAssertEqual(kb.height, 18 * 5.6, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(kb.minY, short.tabRow.maxY - 0.001)
        // もう 1 pt 低いと u が 18 を割る → キーボードを隠してシェルだけに
        let lower = LayoutEngine.compute(LayoutInput(size: CGSize(width: 1000, height: 180), safeArea: Insets(top: 24, bottom: 20)))
        XCTAssertEqual(lower.mode, .tooNarrow)
        XCTAssertNil(lower.rightKeyboard)
        XCTAssertEqual(lower.shell.height, 180 - 20 - 24)
        // 収まるなら縮めない（400 × 0.064 = 25.6 を切り捨てた 25 のまま）
        XCTAssertEqual(LayoutEngine.compute(LayoutInput(size: CGSize(width: 1180, height: 400), safeArea: Insets(top: 24, bottom: 20))).unit, 25)
    }

    /// 設定の keyboard-pitch は u になる（キー 1 つの大きさ）。収まらないときは縮める
    func testPitchOverrideIsTheUnit() {
        var input = mini
        input.pitchOverride = 26
        let r = LayoutEngine.compute(input)
        XCTAssertEqual(r.unit, 26)
        XCTAssertEqual(r.rowHeight, 26)
        XCTAssertEqual(r.leftKeyboard?.width ?? 0, 26 * 8.25, accuracy: 0.001)
        XCTAssertEqual(r.rightKeyboard?.width ?? 0, 26 * 9.5, accuracy: 0.001)
        XCTAssertEqual(r.leftKeyboard?.height ?? 0, 26 * 5.6, accuracy: 0.001)
        XCTAssertEqual(r.shell.width, 724 - 26 * 17.75 - 16, accuracy: 0.001)
        // 20〜80 の設定が、24〜36 の範囲に押し込まれない
        input.pitchOverride = 20
        XCTAssertEqual(LayoutEngine.compute(input).unit, 20)
        var ipad = LayoutInput(size: CGSize(width: 1180, height: 820), safeArea: Insets(top: 24, bottom: 20))
        ipad.pitchOverride = 44
        XCTAssertEqual(LayoutEngine.compute(ipad).unit, 44)
        // 13 mini で 40 にすると、シェルが 200pt を割るので 28 まで縮む
        input.pitchOverride = 40
        let big = LayoutEngine.compute(input)
        XCTAssertEqual(big.unit, 28)
        XCTAssertGreaterThanOrEqual(big.shell.width, LayoutEngine.minimumShellWidth)
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
