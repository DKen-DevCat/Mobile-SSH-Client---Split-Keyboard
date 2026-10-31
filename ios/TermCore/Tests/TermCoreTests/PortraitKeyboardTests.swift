import CoreGraphics
import XCTest
@testable import TermCore

/// 縦持ちの JIS の一体型と、向きを替えたときのキーボードの種類（docs/design.md「JIS の一体型（縦持ち）」）
final class PortraitKeyboardTests: XCTestCase {
    let face = KeyboardLayouts.jisFull
    var keys: [KeySpec] { Array(face.rows.joined()) }

    func frameTable(in rect: CGRect) -> [String: CGRect] {
        Dictionary(face.frames(in: rect).map { ($0.key.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// 幅 14.5u・高さ 5.6 段。どの段も 14.5u（分割の左右を重ねた幅と同じ）
    func testEveryRowIsTheFullWidth() {
        XCTAssertEqual(KeyboardLayouts.fullUnits, 14.5)
        XCTAssertEqual(face.gridUnits, KeyboardLayouts.fullUnits)
        XCTAssertEqual(face.totalWeight, KeyboardLayouts.heightUnits, accuracy: 1e-9)
        XCTAssertEqual(face.rows.count, 6)
        for (r, row) in face.rows.enumerated() {
            XCTAssertEqual(row.reduce(0) { $0 + $1.width }, 14.5, accuracy: 1e-9, "row \(r)")
        }
        // 面の枠いっぱいに並ぶ（どの段も左端から右端まで）
        let u: CGFloat = 26
        let rect = CGRect(x: 0, y: 0, width: 14.5 * u, height: 5.6 * 44)
        let frames = face.frames(in: rect)
        for (r, row) in face.rows.enumerated() {
            let ids = Set(row.flatMap { $0.stacked.isEmpty ? [$0.id] : $0.stacked.map(\.id) })
            let inRow = frames.filter { ids.contains($0.key.id) }.map(\.frame)
            XCTAssertEqual(inRow.map(\.minX).min() ?? -1, 0, accuracy: 0.001, "row \(r)")
            XCTAssertEqual(inRow.map(\.maxX).max() ?? -1, rect.maxX, accuracy: 0.001, "row \(r)")
        }
    }

    /// 上の 5 段は、分割の左の段に、右の段の先頭（左右で重ねたキー）を除いてつなげたもの（同じ KeySpec）
    func testUpperRowsAreTheSplitHalvesJoined() {
        for r in 0..<5 {
            let left = KeyboardLayouts.jisLeft.rows[r], right = KeyboardLayouts.jisRight.rows[r]
            XCTAssertEqual(left.last?.id, right.first?.id, "row \(r) で重ねたキー")
            XCTAssertEqual(face.rows[r], left + right.dropFirst(), "row \(r)")
        }
        // 重ねていたキーは 1 つずつ
        for id in ["f6", "ch-6", "ch-y", "ch-h", "ch-n"] {
            XCTAssertEqual(keys.filter { $0.id == id }.count, 1, id)
        }
        XCTAssertEqual(Set(keys.map(\.id)).count, keys.count, "ID が重なっている")
    }

    /// Mac の JIS の順（上から esc・F1〜F12・🔒 ／ 1〜0 −^¥ delete ／ tab Q〜P @[ return ／ control A〜L ;:] return ／ shift Z〜M ,./_ shift）
    func testRowsFollowTheMacJISOrder() {
        func labels(_ r: Int) -> [String] { face.rows[r].map(\.id) }
        XCTAssertEqual(labels(0), ["esc"] + (1...12).map { "f\($0)" } + ["lock"])
        XCTAssertEqual(labels(1), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "^"].map { "ch-\($0)" } + ["ch-yen", "bs"])
        XCTAssertEqual(labels(2), ["tab"] + ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "@", "["].map { "ch-\($0)" } + ["send"])
        XCTAssertEqual(labels(3), ["mod-control-l"] + ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", ":", "]"].map { "ch-\($0)" }
                       + ["send-lower"])
        XCTAssertEqual(labels(4), ["mod-shift-l"] + ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "_"].map { "ch-\($0)" }
                       + ["mod-shift-r"])
        // F と J だけがホームポジション。return は逆 L 字の 2 つの枠
        XCTAssertEqual(Set(keys.filter(\.homing).map(\.id)), ["ch-f", "ch-j"])
        XCTAssertEqual(keys.first { $0.id == "send" }?.joinedWith, "send-lower")
        XCTAssertEqual(keys.first { $0.id == "send-lower" }?.joinedWith, "send")
    }

    /// 最下段: caps・option・command・英数・空白 4・かな・command・🌐・◀・▲▼・▶（英数とかなを元の位置に）
    func testBottomRowRestoresEisuAndKana() {
        let bottom = face.rows[5]
        XCTAssertEqual(bottom.map(\.id), ["caps", "mod-option-l", "mod-command-l", "lang-eisu", "space", "lang-kana",
                                          "mod-command-r", "globe", "left", "updown", "right"])
        XCTAssertEqual(bottom.map(\.width), [1, 1, 1.25, 1, 4, 1, 1.25, 1, 1, 1, 1])
        XCTAssertEqual(bottom.first { $0.id == "lang-eisu" }?.action, .setKeyboard(.english))
        XCTAssertEqual(bottom.first { $0.id == "lang-kana" }?.action, .setKeyboard(.romaji))
        XCTAssertEqual(bottom.first { $0.id == "lang-eisu" }?.label, "英数")
        XCTAssertEqual(bottom.first { $0.id == "lang-kana" }?.label, "かな")
        // 英数は command の右、かなは空白の右（Mac と同じ）
        let table = frameTable(in: CGRect(x: 0, y: 0, width: 14.5 * 26, height: 5.6 * 44))
        XCTAssertEqual(table["lang-eisu"]!.minX, table["mod-command-l"]!.maxX, accuracy: 0.001)
        XCTAssertEqual(table["space"]!.minX, table["lang-eisu"]!.maxX, accuracy: 0.001)
        XCTAssertEqual(table["lang-kana"]!.minX, table["space"]!.maxX, accuracy: 0.001)
        XCTAssertEqual(table["mod-command-r"]!.minX, table["lang-kana"]!.maxX, accuracy: 0.001)
    }

    /// 空白はただの空白（ポインタを兼ねない）。📎 のキー・2 つ目の 🌐・空白兼ポインタは無い（マウスのボタンをやめた）
    func testNoPointerKeysInPortrait() {
        XCTAssertEqual(keys.first { $0.id == "space" }?.action, .character(" ", shifted: nil, fn: nil))
        XCTAssertFalse(keys.contains { if case .spacePointer = $0.action { return true } else { return false } })
        XCTAssertFalse(keys.contains { $0.action == .attachMedia })
        XCTAssertEqual(keys.filter { $0.symbol == "globe" }.map(\.id), ["globe"])
        XCTAssertEqual(keys.first { $0.id == "globe" }?.action, .modifier(.fn))
        XCTAssertFalse(keys.contains { $0.id == "globe-inner" })
        // 🔒 は Touch ID の位置（右上）
        XCTAssertEqual(face.rows[0].last?.action, .lockApp)
    }

    // MARK: 種類

    func testPortraitKinds() {
        XCTAssertEqual(KeyboardKind.portraitMenuOrder, [.romaji, .english])
        // 同じ言葉の JIS
        XCTAssertEqual(KeyboardKind.romaji.portraitEquivalent, .romaji)
        XCTAssertEqual(KeyboardKind.english.portraitEquivalent, .english)
        XCTAssertEqual(KeyboardKind.kana.portraitEquivalent, .romaji)
        XCTAssertEqual(KeyboardKind.flickRomaji.portraitEquivalent, .romaji)
        XCTAssertEqual(KeyboardKind.flickEnglish.portraitEquivalent, .english)
        for kind in KeyboardKind.allCases {
            XCTAssertTrue(KeyboardKind.portraitMenuOrder.contains(kind.portraitEquivalent), kind.rawValue)
            XCTAssertEqual(kind.portraitEquivalent.isJapanese, kind.isJapanese, kind.rawValue)
        }
        // 🌐 のタップは英語とローマ字を入れ替える
        XCTAssertEqual(KeyboardKind.english.portraitSwitched, .romaji)
        XCTAssertEqual(KeyboardKind.romaji.portraitSwitched, .english)
        // 縦持ちの名前は「分割」と言わない
        for kind in KeyboardKind.portraitMenuOrder { XCTAssertFalse(kind.portraitTitle.contains("分割"), kind.rawValue) }
    }

    func testOrientationMemoryRestoresTheFlickWhenTheLanguageIsKept() {
        var m = KeyboardOrientationMemory()
        // かなフリック → 縦持ちはローマ字 → 替えずに戻ればかなフリック
        XCTAssertEqual(m.enterPortrait(current: .kana), .romaji)
        XCTAssertEqual(m.savedFlick, .kana)
        XCTAssertEqual(m.enterLandscape(current: .romaji), .kana)
        XCTAssertNil(m.savedFlick)
        // 英語フリック → 英語 → 戻れば英語フリック
        XCTAssertEqual(m.enterPortrait(current: .flickEnglish), .english)
        XCTAssertEqual(m.enterLandscape(current: .english), .flickEnglish)
        XCTAssertEqual(m.enterPortrait(current: .flickRomaji), .romaji)
        XCTAssertEqual(m.enterLandscape(current: .romaji), .flickRomaji)
    }

    func testOrientationMemoryKeepsThePortraitChoiceWhenTheLanguageChanged() {
        var m = KeyboardOrientationMemory()
        XCTAssertEqual(m.enterPortrait(current: .kana), .romaji)
        // 縦持ちの間に英数で英語にした → 戻っても英語（分割）
        XCTAssertEqual(m.enterLandscape(current: .english), .english)
        XCTAssertNil(m.savedFlick)
        // JIS のときは何も覚えない（そのまま行き来する）
        XCTAssertEqual(m.enterPortrait(current: .english), .english)
        XCTAssertNil(m.savedFlick)
        XCTAssertEqual(m.enterLandscape(current: .romaji), .romaji)
        // 覚えたものは 1 度戻ったら捨てる（次に横持ちへ戻っても、前のフリックには戻らない）
        _ = m.enterPortrait(current: .kana)
        _ = m.enterLandscape(current: .romaji)
        XCTAssertEqual(m.enterLandscape(current: .romaji), .romaji)
    }
}
