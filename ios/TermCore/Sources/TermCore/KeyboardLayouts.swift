import CoreGraphics
import Foundation

/// 画面のキーボードの配置（データだけ。描画と触れ方はアプリ側）。docs/design.md「横持ち：英語（Mac の英国式）分割」「横持ち：かなフリック」
public struct KeySpec: Hashable, Sendable {
    public var id: String
    public var label: String
    /// shift の文字や記号（キーの上側の小さな表示）
    public var subLabel: String?
    /// option で打つ文字（キーに刷ってあるもの。2 の € と 3 の #）。右下の小さな表示
    public var option: String?
    /// 文字の代わりに描く SF Symbols の名前（F キーの絵、🌐、Touch ID）
    public var symbol: String?
    /// ホームポジションの印（F と J）。押したときの振動を少し強くし、赤く光らせる
    public var homing: Bool
    /// 幅（その面の単位）
    public var width: CGFloat
    /// 縦に何段ぶん使うか（かなの送信・改行キー、英語の return は 2）
    public var rowSpan: Int
    /// 1 つの枠を上下に分けて置くキー（↑ と ↓）。空でなければ、このキー自身は置かない
    public var stacked: [KeySpec]
    public var action: KeyAction
    public var style: KeyStyle

    public init(_ id: String, _ label: String, sub: String? = nil, option: String? = nil, symbol: String? = nil,
                homing: Bool = false, width: CGFloat = 1, rowSpan: Int = 1, stacked: [KeySpec] = [],
                action: KeyAction, style: KeyStyle = .character) {
        self.id = id
        self.label = label
        self.subLabel = sub
        self.option = option
        self.symbol = symbol
        self.homing = homing
        self.width = width
        self.rowSpan = rowSpan
        self.stacked = stacked
        self.action = action
        self.style = style
    }
}

public enum KeyStyle: Hashable, Sendable {
    case character, function, modifier, accent, pointer
}

/// ポインタ（スペースの横の赤い丸）が左右どちらか
public enum PointerSide: Hashable, Sendable {
    case left, right
}

public enum ModifierKey: Hashable, Sendable, CaseIterable {
    case shift, control, option, command, fn
}

public enum KeyAction: Hashable, Sendable {
    /// 文字。shift で `shifted`、fn で `fn` のキーになる
    case character(String, shifted: String?, fn: TermKey?)
    /// 機能キー（矢印・⌫ など）。fn で `fn` のキーになる。`repeats` なら長押しでリピート
    case key(TermKey, fn: TermKey?, repeats: Bool)
    /// 押している間だけ効く（離すと外れる。長押しでも 1 回）。fn だけは、ほかのキーを押さずに離すとキーボードを切り替える（🌐）
    case modifier(ModifierKey)
    /// caps lock。押すたびに入・切（英字だけ大文字になる）
    case capsLock
    /// 送信（⏎、CR）。shift と一緒なら改行（`newline`）
    case send
    /// 改行（設定の `newline`）
    case newline
    /// 英語とかなの切り替え
    case switchKeyboard
    /// Touch ID の位置。アプリをすぐロックする
    case lockApp
    /// スペースの横の赤い丸。触れている間はシェルのポインタを動かす（触れ方はアプリ側）
    case pointer(PointerSide)
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
    /// 全段で共通の格子の幅（単位）。nil なら段ごとに幅の合計で割る
    public var gridUnits: CGFloat?
    /// 段ごとの高さの比（nil なら全段 1。英語の F キーの段は低い）
    public var rowWeights: [CGFloat]?

    public init(rows: [[KeySpec]], gridUnits: CGFloat? = nil, rowWeights: [CGFloat]? = nil) {
        self.rows = rows
        self.gridUnits = gridUnits
        self.rowWeights = rowWeights
    }

    /// 段の高さの比の合計（rect の高さをこれで割ったものが 1 の高さ）
    public var totalWeight: CGFloat { (0..<rows.count).reduce(0) { $0 + weight($1) } }

    func weight(_ row: Int) -> CGFloat { rowWeights.flatMap { row < $0.count ? $0[row] : nil } ?? 1 }

    /// 各キーの枠（rect いっぱいに、段の高さは比で分ける）。2 段にまたがるキーは下の段の同じ位置をふさぐ。
    /// 上下に分けるキー（stacked）は、子のキーを上下半分ずつに置く
    public func frames(in rect: CGRect) -> [(key: KeySpec, frame: CGRect)] {
        var out: [(key: KeySpec, frame: CGRect)] = []
        // (段, 開始単位, 幅単位) のふさがった場所
        var blocked: [(row: Int, x: CGFloat, w: CGFloat)] = []
        let unitHeight = rect.height / max(totalWeight, 0.0001)
        var tops: [CGFloat] = []
        var y = rect.minY
        for r in 0..<rows.count {
            tops.append(y)
            y += weight(r) * unitHeight
        }
        tops.append(y)
        for (r, row) in rows.enumerated() {
            let units = gridUnits ?? row.reduce(0) { $0 + $1.width }
            let unit = rect.width / max(units, 0.0001)
            var x: CGFloat = 0
            for key in row {
                // 上の段からのびたキーを避ける
                while let b = blocked.first(where: { $0.row == r && abs($0.x - x) < 0.001 }) {
                    x += b.w
                }
                let bottom = tops[min(r + max(1, key.rowSpan), rows.count)]
                let frame = CGRect(x: rect.minX + x * unit, y: tops[r], width: key.width * unit, height: bottom - tops[r])
                if key.stacked.isEmpty {
                    out.append((key: key, frame: frame))
                } else {
                    let h = frame.height / CGFloat(key.stacked.count)
                    for (i, child) in key.stacked.enumerated() {
                        out.append((key: child, frame: CGRect(x: frame.minX, y: frame.minY + CGFloat(i) * h,
                                                              width: frame.width, height: h)))
                    }
                }
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
    // MARK: 英語（Mac の英国式、ISO）分割。写真の配列（docs/design.md）をそのまま左右に分ける。
    // 5|6・T|Y・G|H・B|N で分ける。最上段は esc と F1〜F12、最下段は fn（🌐）・control・option・command・矢印

    static func ch(_ c: String, _ shifted: String? = nil, option: String? = nil, fn: TermKey? = nil) -> KeySpec {
        KeySpec("ch-\(c)", c, sub: shifted, option: option, action: .character(c, shifted: shifted, fn: fn))
    }

    static func letter(_ c: String, homing: Bool = false) -> KeySpec {
        KeySpec("ch-\(c)", c.uppercased(), homing: homing, action: .character(c, shifted: c.uppercased(), fn: nil))
    }

    static func mod(_ m: ModifierKey, _ label: String, sub: String? = nil, symbol: String? = nil,
                    width: CGFloat = 1, id: String? = nil) -> KeySpec {
        KeySpec(id ?? "mod-\(m)", label, sub: sub, symbol: symbol, width: width, action: .modifier(m), style: .modifier)
    }

    static func fnKey(_ id: String, _ label: String, _ key: TermKey, fn: TermKey? = nil, sub: String? = nil,
                      symbol: String? = nil, width: CGFloat = 1, repeats: Bool = false) -> KeySpec {
        KeySpec(id, label, sub: sub, symbol: symbol, width: width, action: .key(key, fn: fn, repeats: repeats), style: .function)
    }

    /// F キー（Mac の刷り込みの絵）。端末には F1〜F12 を送る
    static func fKey(_ n: Int, _ symbol: String, width: CGFloat = 1) -> KeySpec {
        fnKey("f\(n)", "F\(n)", .function(n), symbol: symbol, width: width)
    }

    static func space(_ id: String, width: CGFloat) -> KeySpec {
        KeySpec(id, "", width: width, action: .character(" ", shifted: nil, fn: nil))
    }

    static func pointer(_ side: PointerSide) -> KeySpec {
        KeySpec("pointer-\(side)", "", action: .pointer(side), style: .pointer)
    }

    /// F キーの段の高さ（ほかの段を 1 として）
    public static let functionRowWeight: CGFloat = 0.6

    public static let usLeft = KeyboardFace(rows: [
        [fnKey("esc", "esc", .escape, width: 1.5), fKey(1, "sun.min"), fKey(2, "sun.max"), fKey(3, "rectangle.3.group"),
         fKey(4, "magnifyingglass"), fKey(5, "mic"), fKey(6, "moon")],
        [ch("§", "±"), ch("1", "!", fn: .function(1)), ch("2", "@", option: "€", fn: .function(2)),
         ch("3", "£", option: "#", fn: .function(3)), ch("4", "$", fn: .function(4)), ch("5", "%", fn: .function(5))],
        [fnKey("tab", "⇥", .tab, width: 1.5), letter("q"), letter("w"), letter("e"), letter("r"), letter("t")],
        [KeySpec("caps", "⇪", width: 1.75, action: .capsLock, style: .modifier),
         letter("a"), letter("s"), letter("d"), letter("f", homing: true), letter("g")],
        [mod(.shift, "⇧", width: 1.25, id: "mod-shift-l"), ch("`", "~"),
         letter("z"), letter("x"), letter("c"), letter("v"), letter("b")],
        [mod(.fn, "fn", symbol: "globe"), mod(.control, "control", sub: "^", id: "mod-control-l"),
         mod(.option, "option", sub: "⌥", id: "mod-option-l"), mod(.command, "command", sub: "⌘", width: 1.25, id: "mod-command-l"),
         space("space-l", width: 1.5), pointer(.left)],
    ], rowWeights: [functionRowWeight, 1, 1, 1, 1, 1])

    public static let usRight = KeyboardFace(rows: [
        [fKey(7, "backward", width: 1.25), fKey(8, "playpause", width: 1.25), fKey(9, "forward", width: 1.25),
         fKey(10, "speaker", width: 1.25), fKey(11, "speaker.wave.1", width: 1.25), fKey(12, "speaker.wave.3", width: 1.25),
         KeySpec("lock", "", symbol: "touchid", action: .lockApp, style: .function)],
        [ch("6", "^", fn: .function(6)), ch("7", "&", fn: .function(7)), ch("8", "*", fn: .function(8)),
         ch("9", "(", fn: .function(9)), ch("0", ")", fn: .function(10)), ch("-", "_", fn: .function(11)),
         ch("=", "+", fn: .function(12)), fnKey("bs", "⌫", .backspace, fn: .delete, width: 1.5, repeats: true)],
        [letter("y"), letter("u"), letter("i"), letter("o"), letter("p"), ch("[", "{"), ch("]", "}"),
         KeySpec("send", "⏎", width: 1.5, rowSpan: 2, action: .send, style: .function)],
        [letter("h"), letter("j", homing: true), letter("k"), letter("l"), ch(";", ":"), ch("'", "\""), ch("\\", "|")],
        [letter("n"), letter("m"), ch(",", "<"), ch(".", ">"), ch("/", "?"), mod(.shift, "⇧", width: 3.5, id: "mod-shift-r")],
        [pointer(.right), space("space-r", width: 2.25), mod(.command, "command", sub: "⌘", width: 1.25, id: "mod-command-r"),
         mod(.option, "option", sub: "⌥", id: "mod-option-r"),
         fnKey("left", "◀", .left, fn: .home, repeats: true),
         KeySpec("updown", "", stacked: [fnKey("up", "▲", .up, fn: .pageUp, repeats: true),
                                         fnKey("down", "▼", .down, fn: .pageDown, repeats: true)],
                 action: .key(.up, fn: nil, repeats: false), style: .function),
         fnKey("right", "▶", .right, fn: .end, repeats: true)],
    ], gridUnits: 8.5, rowWeights: [functionRowWeight, 1, 1, 1, 1, 1])

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
