import CoreGraphics
import Foundation

/// 画面のキーボードの配置（データだけ。描画と触れ方はアプリ側）。docs/design.md「横持ち：US（Mac）分割」「横持ち：かなフリック」
public struct KeySpec: Hashable, Sendable {
    public var id: String
    public var label: String
    /// shift（US）または fn の小さな表示
    public var subLabel: String?
    /// 幅（その面の単位）
    public var width: CGFloat
    /// 縦に何段ぶん使うか（かなの送信・改行キーは 2）
    public var rowSpan: Int
    public var action: KeyAction
    public var style: KeyStyle

    public init(_ id: String, _ label: String, sub: String? = nil, width: CGFloat = 1, rowSpan: Int = 1,
                action: KeyAction, style: KeyStyle = .character) {
        self.id = id
        self.label = label
        self.subLabel = sub
        self.width = width
        self.rowSpan = rowSpan
        self.action = action
        self.style = style
    }
}

public enum KeyStyle: Hashable, Sendable {
    case character, function, modifier, accent
}

public enum ModifierKey: Hashable, Sendable, CaseIterable {
    case shift, control, option, command, fn
}

public enum KeyAction: Hashable, Sendable {
    /// 文字。shift で `shifted`、fn で `fn` のキーになる
    case character(String, shifted: String?, fn: TermKey?)
    /// 機能キー（矢印・⌫ など）。fn で `fn` のキーになる。`repeats` なら長押しでリピート
    case key(TermKey, fn: TermKey?, repeats: Bool)
    case modifier(ModifierKey)
    /// 送信（⏎、CR）
    case send
    /// 改行（設定の `newline`）
    case newline
    /// US とかなの切り替え
    case switchKeyboard
    /// かなの 1 列。フリックの方向で文字が決まる
    case flick(FlickSet)
    /// 「→」。同じキーの連打で文字を進める（トグル入力）のを区切る
    case kanaBreak
    /// 「゛゜小」。直前の文字を、濁点・半濁点・小さい文字に順に変える
    case kanaModify
}

/// フリックの 5 方向に割り当てた文字。nil の方向は中央と同じに扱う
public struct FlickSet: Hashable, Sendable {
    public var center: String
    public var left: String?
    public var up: String?
    public var right: String?
    public var down: String?

    public init(_ center: String, _ left: String?, _ up: String?, _ right: String?, _ down: String?) {
        self.center = center
        self.left = left
        self.up = up
        self.right = right
        self.down = down
    }

    public func character(_ d: FlickDirection) -> String {
        switch d {
        case .center: return center
        case .left: return left ?? center
        case .up: return up ?? center
        case .right: return right ?? center
        case .down: return down ?? center
        }
    }

    /// トグル入力（同じキーの連打）で巡る順。中央 → 左 → 上 → 右 → 下
    public var cycle: [String] { [center, left, up, right, down].compactMap { $0 } }
}

public enum FlickDirection: Sendable, Equatable {
    case center, left, up, right, down

    /// 指を置いた位置から離した位置までの移動で方向を決める（離した位置で決まる。docs/design.md「同時入力」）
    public static func resolve(dx: CGFloat, dy: CGFloat, threshold: CGFloat) -> FlickDirection {
        guard dx * dx + dy * dy >= threshold * threshold else { return .center }
        if abs(dx) > abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }
}

/// キーボードの片側 1 面
public struct KeyboardFace: Sendable {
    public var rows: [[KeySpec]]
    /// 全段で共通の格子の幅（単位）。nil なら段ごとに幅の合計で割る（US）
    public var gridUnits: CGFloat?

    public init(rows: [[KeySpec]], gridUnits: CGFloat? = nil) {
        self.rows = rows
        self.gridUnits = gridUnits
    }

    /// 各キーの枠（rect の中で下寄せ、段の高さは rowHeight）。2 段にまたがるキーは下の段の同じ位置をふさぐ
    public func frames(in rect: CGRect, rowHeight: CGFloat) -> [(key: KeySpec, frame: CGRect)] {
        var out: [(key: KeySpec, frame: CGRect)] = []
        // (段, 開始単位, 幅単位) のふさがった場所
        var blocked: [(row: Int, x: CGFloat, w: CGFloat)] = []
        let top = rect.maxY - rowHeight * CGFloat(rows.count)
        for (r, row) in rows.enumerated() {
            let units = gridUnits ?? row.reduce(0) { $0 + $1.width }
            let unit = rect.width / max(units, 0.0001)
            var x: CGFloat = 0
            for key in row {
                // 上の段からのびたキーを避ける
                while let b = blocked.first(where: { $0.row == r && abs($0.x - x) < 0.001 }) {
                    x += b.w
                }
                let frame = CGRect(x: rect.minX + x * unit, y: top + CGFloat(r) * rowHeight,
                                   width: key.width * unit, height: rowHeight * CGFloat(key.rowSpan))
                out.append((key: key, frame: frame))
                for extra in 1..<max(1, key.rowSpan) {
                    blocked.append((r + extra, x, key.width))
                }
                x += key.width
            }
        }
        return out
    }
}

public enum KeyboardLayouts {
    // MARK: US（Mac）分割。5|6・T|Y・G|H・B|N で分ける。caps lock の位置は control

    static func ch(_ c: String, _ shifted: String? = nil, fn: TermKey? = nil, sub: String? = nil) -> KeySpec {
        KeySpec("ch-\(c)", c, sub: sub ?? shifted, action: .character(c, shifted: shifted, fn: fn))
    }

    static func letter(_ c: String) -> KeySpec {
        KeySpec("ch-\(c)", c.uppercased(), action: .character(c, shifted: c.uppercased(), fn: nil))
    }

    static func mod(_ m: ModifierKey, _ label: String, width: CGFloat = 1) -> KeySpec {
        KeySpec("mod-\(m)", label, width: width, action: .modifier(m), style: .modifier)
    }

    static func fnKey(_ id: String, _ label: String, _ key: TermKey, fn: TermKey? = nil, sub: String? = nil,
                      width: CGFloat = 1, repeats: Bool = false) -> KeySpec {
        KeySpec(id, label, sub: sub, width: width, action: .key(key, fn: fn, repeats: repeats), style: .function)
    }

    public static let usLeft = KeyboardFace(rows: [
        [ch("`", "~", fn: .escape, sub: "~"), ch("1", "!", fn: .function(1)), ch("2", "@", fn: .function(2)),
         ch("3", "#", fn: .function(3)), ch("4", "$", fn: .function(4)), ch("5", "%", fn: .function(5))],
        [fnKey("tab", "tab", .tab, width: 1.5), letter("q"), letter("w"), letter("e"), letter("r"), letter("t")],
        [mod(.control, "control", width: 1.75), letter("a"), letter("s"), letter("d"), letter("f"), letter("g")],
        [mod(.shift, "shift", width: 2.25), letter("z"), letter("x"), letter("c"), letter("v"), letter("b")],
        [fnKey("esc", "esc", .escape), mod(.fn, "fn"), mod(.option, "option"), mod(.command, "command", width: 1.25),
         KeySpec("space-l", "", width: 2.5, action: .character(" ", shifted: nil, fn: nil))],
    ])

    public static let usRight = KeyboardFace(rows: [
        [ch("6", "^", fn: .function(6)), ch("7", "&", fn: .function(7)), ch("8", "*", fn: .function(8)),
         ch("9", "(", fn: .function(9)), ch("0", ")", fn: .function(10)), ch("-", "_", fn: .function(11)),
         ch("=", "+", fn: .function(12)), fnKey("bs", "⌫", .backspace, fn: .delete, width: 1.5, repeats: true)],
        [letter("y"), letter("u"), letter("i"), letter("o"), letter("p"), ch("[", "{"), ch("]", "}"), ch("\\", "|")],
        [letter("h"), letter("j"), letter("k"), letter("l"), ch(";", ":"), ch("'", "\""),
         KeySpec("send", "return", width: 1.75, action: .send, style: .accent)],
        [letter("n"), letter("m"), ch(",", "<"), ch(".", ">"), ch("/", "?"),
         KeySpec("newline", "改行", width: 1.5, action: .newline, style: .function)],
        [KeySpec("space-r", "", width: 2.5, action: .character(" ", shifted: nil, fn: nil)),
         KeySpec("switch", "かな", action: .switchKeyboard, style: .function),
         fnKey("left", "←", .left, fn: .home, sub: "home", repeats: true),
         fnKey("down", "↓", .down, fn: .pageDown, sub: "pgdn", repeats: true),
         fnKey("up", "↑", .up, fn: .pageUp, sub: "pgup", repeats: true),
         fnKey("right", "→", .right, fn: .end, sub: "end", repeats: true)],
    ])

    // MARK: かなフリック。iOS の 12 キーを左右に 1 面ずつ。上に 1 段足す

    static func kana(_ id: String, _ set: FlickSet) -> KeySpec {
        KeySpec("kana-\(id)", set.center, action: .flick(set))
    }

    static let a = kana("a", FlickSet("あ", "い", "う", "え", "お"))
    static let ka = kana("ka", FlickSet("か", "き", "く", "け", "こ"))
    static let sa = kana("sa", FlickSet("さ", "し", "す", "せ", "そ"))
    static let ta = kana("ta", FlickSet("た", "ち", "つ", "て", "と"))
    static let na = kana("na", FlickSet("な", "に", "ぬ", "ね", "の"))
    static let ha = kana("ha", FlickSet("は", "ひ", "ふ", "へ", "ほ"))
    static let ma = kana("ma", FlickSet("ま", "み", "む", "め", "も"))
    static let ya = kana("ya", FlickSet("や", "（", "ゆ", "）", "よ"))
    static let ra = kana("ra", FlickSet("ら", "り", "る", "れ", "ろ"))
    static let wa = kana("wa", FlickSet("わ", "を", "ん", "ー", nil))
    static let punct = kana("punct", FlickSet("、", "。", "？", "！", nil))
    static let dash = kana("dash", FlickSet("ー", "〜", "・", "…", nil))

    static func kanaFace(top: [KeySpec], corner: KeySpec, tall: KeySpec) -> KeyboardFace {
        KeyboardFace(rows: [
            top,
            [KeySpec("kana-break", "→", action: .kanaBreak, style: .function), a, ka, sa,
             fnKey("bs", "⌫", .backspace, repeats: true)],
            [dash, ta, na, ha, KeySpec("space", "空白", action: .character(" ", shifted: nil, fn: nil), style: .function)],
            [KeySpec("switch", "ABC", action: .switchKeyboard, style: .function), ma, ya, ra, tall],
            [corner, KeySpec("kana-mod", "゛゜小", action: .kanaModify, style: .character), wa, punct],
        ], gridUnits: 5)
    }

    /// 左: 上段は esc / tab / ctrl / alt / ⌨。左下が改行（☺ の位置）、右下が送信（⏎ の位置、縦 2 マス）
    public static let kanaLeft = kanaFace(
        top: [fnKey("esc", "esc", .escape), fnKey("tab", "tab", .tab), mod(.control, "ctrl"), mod(.option, "alt"),
              KeySpec("switch-top", "⌨", action: .switchKeyboard, style: .function)],
        corner: KeySpec("newline", "改行", action: .newline, style: .function),
        tall: KeySpec("send", "送信", rowSpan: 2, action: .send, style: .accent))

    /// 右: 上段は ← ↓ ↑ →。左下が送信（☺ の位置）、右下が改行（⏎ の位置、縦 2 マス）
    public static let kanaRight = kanaFace(
        top: [fnKey("left", "←", .left, width: 1.25, repeats: true), fnKey("down", "↓", .down, width: 1.25, repeats: true),
              fnKey("up", "↑", .up, width: 1.25, repeats: true), fnKey("right", "→", .right, width: 1.25, repeats: true)],
        corner: KeySpec("send", "送信", action: .send, style: .accent),
        tall: KeySpec("newline", "改行", rowSpan: 2, action: .newline, style: .function))

    public static func faces(for kind: KeyboardKind) -> (left: KeyboardFace, right: KeyboardFace) {
        switch kind {
        case .us: return (usLeft, usRight)
        case .kana: return (kanaLeft, kanaRight)
        }
    }
}
