import CoreGraphics
import Foundation

/// 画面のキーボードの配置（データだけ。描画と触れ方はアプリ側）。docs/design.md「JIS の分割」「フリックの分割」
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
    /// 前のキーボードへ切り替える（🌐 のタップ）
    case switchKeyboard
    /// そのキーボードへ切り替える（かなフリックの ABC、英字フリックの あいう）
    case setKeyboard(KeyboardKind)
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
        assigned(d) ?? center
    }

    /// その方向に割り当てた文字（無ければ nil。フリックのガイドは、文字のある方向だけ四角を出す）
    public func assigned(_ d: FlickDirection) -> String? {
        switch d {
        case .center: return center
        case .left: return left
        case .up: return up
        case .right: return right
        case .down: return down
        }
    }

    /// トグル入力（同じキーの連打）で巡る順。中央 → 左 → 上 → 右 → 下
    public var cycle: [String] { [center, left, up, right, down].compactMap { $0 } }
}

public enum FlickDirection: Sendable, Hashable, CaseIterable {
    case center, left, up, right, down

    /// 方向を決める移動量（pt）の範囲。キーが小さくても大きくても、軽い動きで決まり、指が少しぶれただけでは決まらない
    public static let thresholdRange: ClosedRange<CGFloat> = 8...16
    /// しきい値 = キーの短い辺 × この値
    public static let thresholdRatio: CGFloat = 0.3

    /// 方向のしきい値。押したキーの大きさから決める（短い辺 × 0.3 を 8〜16pt に。端末ごとの値は持たない）
    public static func threshold(keySize: CGSize) -> CGFloat {
        let t = min(keySize.width, keySize.height) * thresholdRatio
        return min(max(t, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

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
    // MARK: 分割（Mac の JIS 配列から日本語の刻印を外したもの。利用者の写真、2026-10-31）。
    // 6・Y・H・N の列は左右の両方に置く（左の右端と右の左端が同じキー）。
    // 英数とかなの位置は赤い丸（ポインタ）。🌐 はタップで前のキーボード、長押しでキーボードを選ぶ

    static func ch(_ c: String, _ shifted: String? = nil, option: String? = nil, fn: TermKey? = nil, id: String? = nil) -> KeySpec {
        KeySpec(id ?? "ch-\(c)", c, sub: shifted, option: option, action: .character(c, shifted: shifted, fn: fn))
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

    static func space(_ id: String, width: CGFloat, label: String = "") -> KeySpec {
        KeySpec(id, label, width: width, action: .character(" ", shifted: nil, fn: nil))
    }

    static func pointer(_ side: PointerSide, width: CGFloat = 1) -> KeySpec {
        KeySpec("pointer-\(side)", "", width: width, action: .pointer(side), style: .pointer)
    }

    /// 🌐（fn）。タップで前のキーボード、長押しでキーボードを選ぶ。押しながら矢印などで fn の層
    static func globe(width: CGFloat = 1) -> KeySpec {
        KeySpec("globe", "", symbol: "globe", width: width, action: .modifier(.fn), style: .modifier)
    }

    /// F キーの段の高さ（ほかの段を 1 として）
    public static let functionRowWeight: CGFloat = 0.6

    static let f6 = fKey(6, "moon")
    static let k6 = ch("6", "&", fn: .function(6))
    static let y = letter("y"), h = letter("h"), n = letter("n")

    public static let jisLeft = KeyboardFace(rows: [
        [fnKey("esc", "esc", .escape, width: 1.5), fKey(1, "sun.min"), fKey(2, "sun.max"), fKey(3, "rectangle.3.group"),
         fKey(4, "magnifyingglass"), fKey(5, "mic"), f6],
        [ch("1", "!", fn: .function(1)), ch("2", "\"", fn: .function(2)), ch("3", "#", fn: .function(3)),
         ch("4", "$", fn: .function(4)), ch("5", "%", fn: .function(5)), k6],
        [fnKey("tab", "⇥", .tab, width: 1.5), letter("q"), letter("w"), letter("e"), letter("r"), letter("t"), y],
        [mod(.control, "control", sub: "^", width: 1.75, id: "mod-control-l"),
         letter("a"), letter("s"), letter("d"), letter("f", homing: true), letter("g"), h],
        [mod(.shift, "⇧", width: 2.25, id: "mod-shift-l"), letter("z"), letter("x"), letter("c"), letter("v"), letter("b"), n],
        [KeySpec("caps", "⇪", width: 1.25, action: .capsLock, style: .modifier),
         mod(.option, "option", sub: "⌥", width: 1.15, id: "mod-option-l"),
         mod(.command, "command", sub: "⌘", width: 1.35, id: "mod-command-l"),
         pointer(.left, width: 1.15), space("space-l", width: 2.1)],
    ], rowWeights: [functionRowWeight, 1, 1, 1, 1, 1])

    /// 右: 1 単位 = 幅 ÷ 9.5（return が 2 段にまたがるので、全段で共通の格子）
    public static let jisRight = KeyboardFace(rows: [
        [fKey(6, "moon", width: 1.2), fKey(7, "backward", width: 1.2), fKey(8, "playpause", width: 1.2),
         fKey(9, "forward", width: 1.2), fKey(10, "speaker", width: 1.2), fKey(11, "speaker.wave.1", width: 1.2),
         fKey(12, "speaker.wave.3", width: 1.2),
         KeySpec("lock", "", symbol: "lock", width: 1.1, action: .lockApp, style: .function)],
        [k6, ch("7", "'", fn: .function(7)), ch("8", "(", fn: .function(8)), ch("9", ")", fn: .function(9)),
         ch("0", nil, fn: .function(10)), ch("-", "=", fn: .function(11)), ch("^", "~", fn: .function(12)),
         // ¥ のキーは、端末で使う \ を打つ（option で ¥）
         KeySpec("ch-yen", "¥", sub: "|", option: "¥", action: .character("\\", shifted: "|", fn: nil)),
         fnKey("bs", "⌫", .backspace, fn: .delete, width: 1.5, repeats: true)],
        [y, letter("u"), letter("i"), letter("o"), letter("p"), ch("@", "`"), ch("[", "{"),
         KeySpec("send", "⏎", width: 2.5, rowSpan: 2, action: .send, style: .function)],
        [h, letter("j", homing: true), letter("k"), letter("l"), ch(";", "+"), ch(":", "*"), ch("]", "}")],
        [n, letter("m"), ch(",", "<"), ch(".", ">"), ch("/", "?"), ch("_", "_"), mod(.shift, "⇧", width: 3.5, id: "mod-shift-r")],
        [space("space-r", width: 2.25), pointer(.right), mod(.command, "command", sub: "⌘", width: 1.25, id: "mod-command-r"),
         globe(),
         fnKey("left", "◀", .left, fn: .home, width: 4.0 / 3, repeats: true),
         KeySpec("updown", "", width: 4.0 / 3, stacked: [fnKey("up", "▲", .up, fn: .pageUp, repeats: true),
                                                           fnKey("down", "▼", .down, fn: .pageDown, repeats: true)],
                 action: .key(.up, fn: nil, repeats: false), style: .function),
         fnKey("right", "▶", .right, fn: .end, width: 4.0 / 3, repeats: true)],
    ], gridUnits: 9.5, rowWeights: [functionRowWeight, 1, 1, 1, 1, 1])

    // MARK: フリックの分割。iOS の 12 キーを左右に 1 面ずつ。最下段に 🌐・空白・ポインタ（ポインタは内側）

    static func flick(_ id: String, _ set: FlickSet, label: String? = nil) -> KeySpec {
        KeySpec("flick-\(id)", label ?? set.center, action: .flick(set))
    }

    static func kana(_ id: String, _ set: FlickSet) -> KeySpec { flick("kana-\(id)", set) }

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

    // 英字のフリック（iOS の ABC と同じ並び。小文字。a/A で大文字に）
    static let symbols = flick("sym", FlickSet("@", "#", "/", "&", "_"), label: "@#/&_")
    static let abc = flick("abc", FlickSet("a", "b", "c", nil, nil), label: "abc")
    static let def = flick("def", FlickSet("d", "e", "f", nil, nil), label: "def")
    static let ghi = flick("ghi", FlickSet("g", "h", "i", nil, nil), label: "ghi")
    static let jkl = flick("jkl", FlickSet("j", "k", "l", nil, nil), label: "jkl")
    static let mno = flick("mno", FlickSet("m", "n", "o", nil, nil), label: "mno")
    static let pqrs = flick("pqrs", FlickSet("p", "q", "r", "s", nil), label: "pqrs")
    static let tuv = flick("tuv", FlickSet("t", "u", "v", nil, nil), label: "tuv")
    static let wxyz = flick("wxyz", FlickSet("w", "x", "y", "z", nil), label: "wxyz")
    static let quotes = flick("quotes", FlickSet("'", "\"", "(", ")", nil), label: "'\"()")
    static let periods = flick("periods", FlickSet(".", ",", "?", "!", nil), label: ".,?!")
    static let maths = flick("maths", FlickSet("-", "+", "=", "*", "%"), label: "-+=*")

    static let send = KeySpec("send", "send", action: .send, style: .accent)
    static let sendTall = KeySpec("send", "send", rowSpan: 2, action: .send, style: .accent)
    static let newline = KeySpec("newline", "↩︎", action: .newline, style: .function)
    static let newlineTall = KeySpec("newline", "↩︎", rowSpan: 2, action: .newline, style: .function)

    /// 左は 改行が外側の角・send が内側の縦 2 マス。右はその逆。最下段の内側にポインタ
    static func flickFace(grid: [[KeySpec]], switchKey: KeySpec, left: Bool) -> KeyboardFace {
        KeyboardFace(rows: [
            [KeySpec("kana-break", "→", action: .kanaBreak, style: .function)] + grid[0]
                + [fnKey("bs", "⌫", .backspace, repeats: true)],
            grid[1] + [space("space", width: 1, label: "空白")],
            [switchKey] + grid[2] + [left ? sendTall : newlineTall],
            [left ? newline : send] + grid[3],
            left ? [globe(), space("space-b", width: 3), pointer(.left)]
                 : [pointer(.right), space("space-b", width: 3), globe()],
        ], gridUnits: 5)
    }

    static let kanaGrid: [[KeySpec]] = [[a, ka, sa], [dash, ta, na, ha], [ma, ya, ra],
                                        [KeySpec("kana-mod", "゛゜小", action: .kanaModify, style: .character), wa, punct]]
    static let alphaGrid: [[KeySpec]] = [[symbols, abc, def], [maths, ghi, jkl, mno], [pqrs, tuv, wxyz],
                                         [KeySpec("case", "a/A", action: .capsLock, style: .character), quotes, periods]]

    public static let kanaLeft = flickFace(grid: kanaGrid, switchKey: KeySpec("to-alpha", "ABC", action: .setKeyboard(.flickEnglish), style: .function), left: true)
    public static let kanaRight = flickFace(grid: kanaGrid, switchKey: KeySpec("to-alpha", "ABC", action: .setKeyboard(.flickEnglish), style: .function), left: false)
    public static let alphaLeft = flickFace(grid: alphaGrid, switchKey: KeySpec("to-kana", "あいう", action: .setKeyboard(.kana), style: .function), left: true)
    public static let alphaRight = flickFace(grid: alphaGrid, switchKey: KeySpec("to-kana", "あいう", action: .setKeyboard(.kana), style: .function), left: false)

    public static func faces(for kind: KeyboardKind) -> (left: KeyboardFace, right: KeyboardFace) {
        switch kind {
        case .english, .romaji: return (jisLeft, jisRight)
        case .kana: return (kanaLeft, kanaRight)
        case .flickRomaji, .flickEnglish: return (alphaLeft, alphaRight)
        }
    }
}
