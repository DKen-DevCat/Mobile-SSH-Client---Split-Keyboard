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
    /// つながって 1 つの形に見えるキーの ID（return の上の枠と下の枠。逆 L 字）。描くときと押した色に使う
    public var joinedWith: String?
    public var action: KeyAction
    public var style: KeyStyle

    public init(_ id: String, _ label: String, sub: String? = nil, option: String? = nil, symbol: String? = nil,
                homing: Bool = false, width: CGFloat = 1, rowSpan: Int = 1, stacked: [KeySpec] = [],
                joinedWith: String? = nil, action: KeyAction, style: KeyStyle = .character) {
        self.id = id
        self.label = label
        self.subLabel = sub
        self.option = option
        self.symbol = symbol
        self.homing = homing
        self.width = width
        self.rowSpan = rowSpan
        self.stacked = stacked
        self.joinedWith = joinedWith
        self.action = action
        self.style = style
    }
}

public enum KeyStyle: Hashable, Sendable {
    case character, function, modifier, accent
}

/// 空白兼ポインタが左右どちらか
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
    /// 空白とポインタを兼ねるキー。動かさずに離せば空白、動かせばポインタ、動かした指を離して 1 秒以内のタップは左クリック、
    /// 左右の同時押しは右クリック（判定は `SpacePointerGesture`）
    case spacePointer(PointerSide)
    /// 📎。離したら、メディアを送るメニュー（写真・動画を選ぶ／撮る／録音する／ファイル）を、そのキーを指す形で出す
    case attachMedia
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
    /// 幅が格子より短い段を、どちらの端に寄せるか（外側の端にそろえる）
    public enum Alignment: Sendable {
        /// 左端にそろえる（左の面）
        case leading
        /// 右端にそろえる（右の面）
        case trailing
    }

    public var rows: [[KeySpec]]
    /// 面の幅（単位）。全段で共通の格子で、rect の幅がこれにあたる。nil なら段ごとに幅の合計で割る（段がそろう）
    public var gridUnits: CGFloat?
    /// 段ごとの高さの比（nil なら全段 1。JIS の F キーの段は低い）
    public var rowWeights: [CGFloat]?
    /// 格子より短い段を寄せる向き
    public var alignment: Alignment

    public init(rows: [[KeySpec]], gridUnits: CGFloat? = nil, rowWeights: [CGFloat]? = nil,
                alignment: Alignment = .leading) {
        self.rows = rows
        self.gridUnits = gridUnits
        self.rowWeights = rowWeights
        self.alignment = alignment
    }

    /// 段の高さの比の合計（rect の高さをこれで割ったものが 1 の高さ）
    public var totalWeight: CGFloat { (0..<rows.count).reduce(0) { $0 + weight($1) } }

    func weight(_ row: Int) -> CGFloat { rowWeights.flatMap { row < $0.count ? $0[row] : nil } ?? 1 }

    /// 各キーの枠（rect いっぱいに、段の高さは比で分ける）。2 段にまたがるキーは下の段の同じ位置をふさぐ。
    /// 上下に分けるキー（stacked）は、子のキーを上下半分ずつに置く。格子より短い段は `alignment` の端に寄せる
    /// （キーの無い隙間は、触れたときにいちばん近いキーになる）
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
            let rowUnits = row.reduce(0) { $0 + $1.width }
            let units = gridUnits ?? rowUnits
            let unit = rect.width / max(units, 0.0001)
            var x: CGFloat = 0
            if alignment == .trailing {
                // 上の段からのびたキーがふさぐ幅も、段の幅に数える
                let blockedUnits = blocked.filter { $0.row == r }.reduce(0) { $0 + $1.w }
                x = max(0, units - rowUnits - blockedUnits)
            }
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
    // 左右・全段で共通の単位 u を使い、文字キー（1u）は u×u の正方形。各段の幅は Magic Keyboard の JIS（本体 14.5u）に合わせる。
    // 内側の端は実物どおり段ごとにずれ、外側の端はそろう（左の面は左端、右の面は右端）。
    // 6・Y・H・N の列は左右の両方に置く（左の右端と右の左端が同じキー。右の面の左端は、左の面の 5u の位置）。
    // 英数とかなの位置は 📎 と 🌐（空白キーがポインタを兼ねる）。🌐 はタップで前のキーボード、長押しでキーボードを選ぶ

    /// 面の幅・高さ（u 単位）。`LayoutEngine` が枠の大きさに使う値で、下の面の並びと同じ（テストで一致を確かめる）
    public static let leftUnits: CGFloat = 8.25
    public static let rightUnits: CGFloat = 9.5
    /// F キーの段の高さ（ほかの段を 1 として）
    public static let functionRowWeight: CGFloat = 0.6
    /// 面の高さ = F キーの段 + ほかの 5 段
    public static let heightUnits: CGFloat = functionRowWeight + 5

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

    /// 空白兼ポインタ。見た目は空白キーの中央に小さな赤い丸
    static func spacePointer(_ id: String, _ side: PointerSide, width: CGFloat) -> KeySpec {
        KeySpec(id, "", width: width, action: .spacePointer(side))
    }

    /// 📎（メディアを送る）
    static func attach(width: CGFloat = 1) -> KeySpec {
        KeySpec("attach", "", symbol: "paperclip", width: width, action: .attachMedia, style: .function)
    }

    /// 🌐（fn）。タップで前のキーボード、長押しでキーボードを選ぶ。押しながら矢印などで fn の層
    static func globe(id: String = "globe", width: CGFloat = 1) -> KeySpec {
        KeySpec(id, "", symbol: "globe", width: width, action: .modifier(.fn), style: .modifier)
    }

    /// 右の面とフリックの右の内側に置く 🌐（外側の `globe` と同じ働き。ID だけ違う）
    static func globeInner(width: CGFloat = 1) -> KeySpec { globe(id: "globe-inner", width: width) }

    static let f6 = fKey(6, "moon")
    static let k6 = ch("6", "&", fn: .function(6))
    static let y = letter("y"), h = letter("h"), n = letter("n")

    /// 左: 幅 8.25u。左端をそろえる（短い段は右の内側に隙間ができる）
    public static let jisLeft = KeyboardFace(rows: [
        [fnKey("esc", "esc", .escape, width: 1.5), fKey(1, "sun.min"), fKey(2, "sun.max"), fKey(3, "rectangle.3.group"),
         fKey(4, "magnifyingglass"), fKey(5, "mic"), f6],
        [ch("1", "!", fn: .function(1)), ch("2", "\"", fn: .function(2)), ch("3", "#", fn: .function(3)),
         ch("4", "$", fn: .function(4)), ch("5", "%", fn: .function(5)), k6],
        [fnKey("tab", "⇥", .tab, width: 1.5), letter("q"), letter("w"), letter("e"), letter("r"), letter("t"), y],
        [mod(.control, "control", sub: "^", width: 1.75, id: "mod-control-l"),
         letter("a"), letter("s"), letter("d"), letter("f", homing: true), letter("g"), h],
        [mod(.shift, "⇧", width: 2.25, id: "mod-shift-l"), letter("z"), letter("x"), letter("c"), letter("v"), letter("b"), n],
        [KeySpec("caps", "⇪", action: .capsLock, style: .modifier),
         mod(.option, "option", sub: "⌥", id: "mod-option-l"),
         mod(.command, "command", sub: "⌘", width: 1.25, id: "mod-command-l"),
         spacePointer("space-l", .left, width: 4), attach()],
    ], gridUnits: leftUnits, rowWeights: [functionRowWeight, 1, 1, 1, 1, 1], alignment: .leading)

    /// 右: 幅 9.5u。右端をそろえる（短い段は左の内側に隙間ができる）。return は実物の逆 L 字で、
    /// 上 1u の `send` と下 0.75u の `send-lower` の 2 つの枠（どちらも送信。つながって見えるように描く）
    public static let jisRight = KeyboardFace(rows: [
        [fKey(6, "moon"), fKey(7, "backward"), fKey(8, "playpause"), fKey(9, "forward"), fKey(10, "speaker"),
         fKey(11, "speaker.wave.1"), fKey(12, "speaker.wave.3"),
         KeySpec("lock", "", symbol: "lock", action: .lockApp, style: .function)],
        [k6, ch("7", "'", fn: .function(7)), ch("8", "(", fn: .function(8)), ch("9", ")", fn: .function(9)),
         ch("0", nil, fn: .function(10)), ch("-", "=", fn: .function(11)), ch("^", "~", fn: .function(12)),
         // ¥ のキーは、端末で使う \ を打つ（option で ¥）
         KeySpec("ch-yen", "¥", sub: "|", option: "¥", action: .character("\\", shifted: "|", fn: nil)),
         fnKey("bs", "⌫", .backspace, fn: .delete, width: 1.5, repeats: true)],
        [y, letter("u"), letter("i"), letter("o"), letter("p"), ch("@", "`"), ch("[", "{"),
         KeySpec("send", "⏎", joinedWith: "send-lower", action: .send, style: .function)],
        [h, letter("j", homing: true), letter("k"), letter("l"), ch(";", "+"), ch(":", "*"), ch("]", "}"),
         KeySpec("send-lower", "", width: 0.75, joinedWith: "send", action: .send, style: .function)],
        [n, letter("m"), ch(",", "<"), ch(".", ">"), ch("/", "?"), ch("_", "_"), mod(.shift, "⇧", width: 1.25, id: "mod-shift-r")],
        [globeInner(), spacePointer("space-r", .right, width: 3.25),
         mod(.command, "command", sub: "⌘", width: 1.25, id: "mod-command-r"),
         globe(),
         fnKey("left", "◀", .left, fn: .home, repeats: true),
         KeySpec("updown", "", stacked: [fnKey("up", "▲", .up, fn: .pageUp, repeats: true),
                                           fnKey("down", "▼", .down, fn: .pageDown, repeats: true)],
                 action: .key(.up, fn: nil, repeats: false), style: .function),
         fnKey("right", "▶", .right, fn: .end, repeats: true)],
    ], gridUnits: rightUnits, rowWeights: [functionRowWeight, 1, 1, 1, 1, 1], alignment: .trailing)

    // MARK: 縦持ちの JIS の一体型（分割する前の Mac の JIS 配列。docs/design.md「JIS の一体型（縦持ち）」）。
    // 横持ちの分割とは別の面: 6・Y・H・N・F6 は 1 つずつ、英数とかなを元の位置に、空白はただの空白（ポインタを兼ねない）、
    // 📎 のキーと 2 つ目の 🌐 は無い。キーは分割の面と同じもの（KeySpec）を使う

    /// 一体型の幅（u 単位）= Magic Keyboard の JIS 本体の幅。`LayoutEngine` が縦持ちの u（幅 ÷ これ）に使う
    public static let fullUnits: CGFloat = 14.5

    /// 英数: 英語のキーボードへ。かな: ローマ字へ（Mac と同じく、もうその入力なら何もしない）
    static let eisu = KeySpec("lang-eisu", "英数", action: .setKeyboard(.english), style: .function)
    static let kanaMode = KeySpec("lang-kana", "かな", action: .setKeyboard(.romaji), style: .function)

    /// 最下段: caps・option・command・英数・空白 4・かな・command・🌐・◀・▲▼・▶
    static let fullBottomRow: [KeySpec] = {
        let left = jisLeft.rows[5], right = jisRight.rows[5]
        // 左の caps・option・command と、右の command・🌐・矢印は分割の面と同じキー
        return Array(left.prefix(3)) + [eisu, space("space", width: 4), kanaMode] + Array(right.dropFirst(2))
    }()

    /// 幅 14.5u・高さ 5.6 段（F キーの段 0.6）。上の 5 段は、分割の左の段に、右の段から重ねたキー（右の先頭）を除いたものを
    /// つなげる（どの段も 14.5u。刻印・shift の記号・return の逆 L 字は分割と同じ）
    public static let jisFull: KeyboardFace = {
        var rows: [[KeySpec]] = []
        for r in 0..<5 {
            rows.append(jisLeft.rows[r] + jisRight.rows[r].dropFirst())
        }
        rows.append(fullBottomRow)
        return KeyboardFace(rows: rows, gridUnits: fullUnits, rowWeights: [functionRowWeight, 1, 1, 1, 1, 1],
                            alignment: .leading)
    }()

    // MARK: フリックの分割。iOS の 12 キーを左右に 1 面ずつ（分割と同じ枠いっぱいに並べる）。最下段は、左が 🌐・空白兼ポインタ・📎、右が 🌐・空白兼ポインタ・🌐

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

    /// 左は 改行が外側の角・send が内側の縦 2 マス。右はその逆。最下段は空白兼ポインタ（幅 3）を真ん中に
    static func flickFace(grid: [[KeySpec]], switchKey: KeySpec, left: Bool) -> KeyboardFace {
        KeyboardFace(rows: [
            [KeySpec("kana-break", "→", action: .kanaBreak, style: .function)] + grid[0]
                + [fnKey("bs", "⌫", .backspace, repeats: true)],
            grid[1] + [space("space", width: 1, label: "空白")],
            [switchKey] + grid[2] + [left ? sendTall : newlineTall],
            [left ? newline : send] + grid[3],
            left ? [globe(), spacePointer("space-b", .left, width: 3), attach()]
                 : [globeInner(), spacePointer("space-b", .right, width: 3), globe()],
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
