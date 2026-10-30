import Foundation

/// 入力ルータが扱うキー。画面のキーボードも、ハードウェアキーボードも、ここに集める
public enum TermKey: Hashable, Sendable {
    /// 文字（1 文字以上。かなの確定や貼り付けもこれ）
    case text(String)
    /// 送信（⏎）。CR を送る
    case enter
    /// 改行。設定の `newline` に従う（docs/design.md「改行と送信」）
    case newline
    case backspace, tab, escape, delete
    case up, down, left, right
    case home, end, pageUp, pageDown
    case function(Int)
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    /// option。設定の `option-as-meta` なら ESC を前に付けて送る
    public static let option = KeyModifiers(rawValue: 1 << 2)
    /// command。接続先には届かない。アプリ内の操作（コピー・ペースト・倍率）に使う
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// xterm の修飾キーの番号（1 + shift + alt×2 + ctrl×4）
    var xtermParameter: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.option) ? 2 : 0) + (contains(.control) ? 4 : 0)
    }
}

/// 送り先（接続先のアプリ）の状態のうち、キーの変換に要るもの。エミュレータから受け取る
public struct EncodingContext: Equatable, Sendable {
    public var applicationCursor: Bool
    public var bracketedPaste: Bool
    public var optionAsMeta: Bool
    public var newline: NewlineMode

    public init(applicationCursor: Bool = false, bracketedPaste: Bool = false,
                optionAsMeta: Bool = true, newline: NewlineMode = .auto) {
        self.applicationCursor = applicationCursor
        self.bracketedPaste = bracketedPaste
        self.optionAsMeta = optionAsMeta
        self.newline = newline
    }
}

public enum KeyEncoder {
    static let esc: UInt8 = 0x1b
    static let pasteStart: [UInt8] = Array("\u{1b}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

    /// キーを接続先へ送るバイト列にする。command 付きは送らない（空を返す）
    public static func encode(_ key: TermKey, _ mods: KeyModifiers = [], _ ctx: EncodingContext) -> [UInt8] {
        if mods.contains(.command) { return [] }
        let meta = mods.contains(.option) && ctx.optionAsMeta
        switch key {
        case .text(let s):
            return encodeText(s, mods, meta: meta)
        case .enter:
            return meta ? [esc, 0x0d] : [0x0d]
        case .newline:
            return newline(ctx)
        case .backspace:
            if mods.contains(.control) { return meta ? [esc, 0x08] : [0x08] }
            return meta ? [esc, 0x7f] : [0x7f]
        case .tab:
            if mods.contains(.shift) { return Array("\u{1b}[Z".utf8) }
            return meta ? [esc, 0x09] : [0x09]
        case .escape:
            return meta ? [esc, esc] : [esc]
        case .delete:
            return tilde(3, mods)
        case .up: return cursor("A", mods, ctx)
        case .down: return cursor("B", mods, ctx)
        case .right: return cursor("C", mods, ctx)
        case .left: return cursor("D", mods, ctx)
        case .home: return cursor("H", mods, ctx)
        case .end: return cursor("F", mods, ctx)
        case .pageUp: return tilde(5, mods)
        case .pageDown: return tilde(6, mods)
        case .function(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                if mods.xtermParameter > 1 { return Array("\u{1b}[1;\(mods.xtermParameter)\(final)".utf8) }
                return Array("\u{1b}O\(final)".utf8)
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return tilde(codes[n - 5], mods)
            default:
                return []
            }
        }
    }

    /// 改行（docs/design.md「改行と送信」）。auto は括弧付きペーストが有効なら貼り付けとして、無効なら ESC+CR
    public static func newline(_ ctx: EncodingContext) -> [UInt8] {
        switch ctx.newline {
        case .auto, .paste:
            return ctx.bracketedPaste ? pasteStart + [0x0a] + pasteEnd : [esc, 0x0d]
        case .escCR:
            return [esc, 0x0d]
        case .ctrlJ:
            return [0x0a]
        }
    }

    /// 貼り付け。括弧付きペーストが有効なら印で挟む（中に終わりの印があれば取り除く）。改行は CR にそろえる
    public static func paste(_ text: String, _ ctx: EncodingContext) -> [UInt8] {
        var t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if ctx.bracketedPaste {
            t = t.replacingOccurrences(of: "\u{1b}[201~", with: "")
            return pasteStart + Array(t.utf8) + pasteEnd
        }
        return Array(t.utf8)
    }

    static func encodeText(_ s: String, _ mods: KeyModifiers, meta: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if mods.contains(.control), s.unicodeScalars.count == 1, let c = control(s.unicodeScalars.first!) {
            out = [c]
        } else {
            out = Array(s.utf8)
        }
        return meta ? [esc] + out : out
    }

    /// ctrl を付けた文字のバイト。対応が無ければ nil（そのまま送る）
    static func control(_ u: Unicode.Scalar) -> UInt8? {
        switch u {
        case "a"..."z": return UInt8(u.value - 0x60)
        case "A"..."Z": return UInt8(u.value - 0x40)
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1b
        case "\\", "4": return 0x1c
        case "]", "5": return 0x1d
        case "^", "6": return 0x1e
        case "_", "-", "7", "/": return 0x1f
        case "8", "?": return 0x7f
        default: return nil
        }
    }

    static func cursor(_ final: String, _ mods: KeyModifiers, _ ctx: EncodingContext) -> [UInt8] {
        let p = mods.xtermParameter
        if p > 1 { return Array("\u{1b}[1;\(p)\(final)".utf8) }
        return Array((ctx.applicationCursor ? "\u{1b}O" : "\u{1b}[").utf8) + Array(final.utf8)
    }

    static func tilde(_ code: Int, _ mods: KeyModifiers) -> [UInt8] {
        let p = mods.xtermParameter
        return Array((p > 1 ? "\u{1b}[\(code);\(p)~" : "\u{1b}[\(code)~").utf8)
    }

    /// 同じ行の中で、カーソルを `from` 桁から `to` 桁へ動かす矢印キーの列（入力行のタップ）。
    /// `widths` は行の各セルの幅（全角の先頭は 2、続きは 0）。矢印 1 回で 1 文字動く前提で数える
    public static func horizontalMove(from: Int, to: Int, widths: [Int], _ ctx: EncodingContext) -> [UInt8] {
        guard from != to else { return [] }
        let lo = min(from, to), hi = max(from, to)
        var chars = 0
        var x = lo
        while x < hi {
            let w = x < widths.count ? widths[x] : 1
            if w != 0 { chars += 1 }
            x += 1
        }
        let one = encode(to > from ? .right : .left, [], ctx)
        return Array([[UInt8]](repeating: one, count: chars).joined())
    }
}
