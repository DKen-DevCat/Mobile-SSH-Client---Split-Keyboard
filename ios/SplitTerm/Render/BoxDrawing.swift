import CoreGraphics

/// 罫線とブロック文字を、フォントを使わず図形（四角）として描く（docs/design.md「文字の描画」）。
/// 行の間に隙間ができず、Claude Code や tmux の枠がきれいにつながる
enum BoxDrawing {
    /// 線の太さ: 0 なし、1 細、2 太
    struct Arms {
        var left: UInt8 = 0, right: UInt8 = 0, up: UInt8 = 0, down: UInt8 = 0
    }

    static func arms(_ v: UInt32) -> Arms? {
        func a(_ l: UInt8, _ r: UInt8, _ u: UInt8, _ d: UInt8) -> Arms { Arms(left: l, right: r, up: u, down: d) }
        switch v {
        case 0x2500, 0x2504, 0x2508, 0x254C, 0x2550: return a(1, 1, 0, 0)  // ─ ┄ ┈ ╌ ═
        case 0x2501, 0x2505, 0x2509, 0x254D: return a(2, 2, 0, 0)          // ━
        case 0x2502, 0x2506, 0x250A, 0x254E, 0x2551: return a(0, 0, 1, 1)  // │ ║
        case 0x2503, 0x2507, 0x250B, 0x254F: return a(0, 0, 2, 2)          // ┃
        case 0x250C, 0x256D, 0x2554: return a(0, 1, 0, 1)                  // ┌ ╭ ╔
        case 0x2510, 0x256E, 0x2557: return a(1, 0, 0, 1)                  // ┐ ╮ ╗
        case 0x2514, 0x2570, 0x255A: return a(0, 1, 1, 0)                  // └ ╰ ╚
        case 0x2518, 0x256F, 0x255D: return a(1, 0, 1, 0)                  // ┘ ╯ ╝
        case 0x250F: return a(0, 2, 0, 2)                                  // ┏
        case 0x2513: return a(2, 0, 0, 2)                                  // ┓
        case 0x2517: return a(0, 2, 2, 0)                                  // ┗
        case 0x251B: return a(2, 0, 2, 0)                                  // ┛
        case 0x251C, 0x2560: return a(0, 1, 1, 1)                          // ├ ╠
        case 0x2524, 0x2563: return a(1, 0, 1, 1)                          // ┤ ╣
        case 0x252C, 0x2566: return a(1, 1, 0, 1)                          // ┬ ╦
        case 0x2534, 0x2569: return a(1, 1, 1, 0)                          // ┴ ╩
        case 0x253C, 0x256C: return a(1, 1, 1, 1)                          // ┼ ╬
        case 0x2523: return a(0, 2, 2, 2)                                  // ┣
        case 0x252B: return a(2, 0, 2, 2)                                  // ┫
        case 0x2533: return a(2, 2, 0, 2)                                  // ┳
        case 0x253B: return a(2, 2, 2, 0)                                  // ┻
        case 0x254B: return a(2, 2, 2, 2)                                  // ╋
        case 0x2574: return a(1, 0, 0, 0)                                  // ╴
        case 0x2575: return a(0, 0, 1, 0)                                  // ╵
        case 0x2576: return a(0, 1, 0, 0)                                  // ╶
        case 0x2577: return a(0, 0, 0, 1)                                  // ╷
        case 0x2578: return a(2, 0, 0, 0)
        case 0x2579: return a(0, 0, 2, 0)
        case 0x257A: return a(0, 2, 0, 0)
        case 0x257B: return a(0, 0, 0, 2)
        default: return nil
        }
    }

    /// 文字が図形で描くものなら、セルの中の四角（とその不透明度）を返す。そうでなければ nil
    static func shapes(for text: String, cell: CGRect) -> [(rect: CGRect, alpha: Float)]? {
        guard let u = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
        let v = u.value
        guard (0x2500...0x259F).contains(v) else { return nil }
        let x = cell.minX, y = cell.minY, w = cell.width, h = cell.height

        if let arms = arms(v) {
            let light = max(1, (h / 14).rounded())
            var out: [(rect: CGRect, alpha: Float)] = []
            func thick(_ a: UInt8) -> CGFloat { a == 2 ? light * 2 : light }
            let cx = x + ((w - light) / 2).rounded(.down)
            let cy = y + ((h - light) / 2).rounded(.down)
            if arms.left > 0 || arms.right > 0 {
                let t = thick(max(arms.left, arms.right))
                let ty = y + ((h - t) / 2).rounded(.down)
                let x0 = arms.left > 0 ? x : cx
                let x1 = arms.right > 0 ? x + w : cx + light
                out.append((rect: CGRect(x: x0, y: ty, width: x1 - x0, height: t), alpha: 1))
            }
            if arms.up > 0 || arms.down > 0 {
                let t = thick(max(arms.up, arms.down))
                let tx = x + ((w - t) / 2).rounded(.down)
                let y0 = arms.up > 0 ? y : cy
                let y1 = arms.down > 0 ? y + h : cy + light
                out.append((rect: CGRect(x: tx, y: y0, width: t, height: y1 - y0), alpha: 1))
            }
            return out
        }

        func lower(_ n: CGFloat) -> CGRect {
            let hh = (h * n / 8).rounded()
            return CGRect(x: x, y: y + h - hh, width: w, height: hh)
        }
        func left(_ n: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: (w * n / 8).rounded(), height: h)
        }
        switch v {
        case 0x2580: return [(CGRect(x: x, y: y, width: w, height: (h / 2).rounded()), 1)]        // ▀
        case 0x2581...0x2588: return [(lower(CGFloat(v - 0x2580)), 1)]                         // ▁〜█
        case 0x2589...0x258F: return [(left(CGFloat(0x2590 - v)), 1)]                          // ▉〜▏
        case 0x2590:                                                                           // ▐
            let hw = (w / 2).rounded()
            return [(CGRect(x: x + w - hw, y: y, width: hw, height: h), 1)]
        case 0x2591: return [(cell, 0.25)]                                                     // ░
        case 0x2592: return [(cell, 0.5)]                                                      // ▒
        case 0x2593: return [(cell, 0.75)]                                                     // ▓
        case 0x2594: return [(CGRect(x: x, y: y, width: w, height: max(1, (h / 8).rounded())), 1)]  // ▔
        case 0x2595:                                                                           // ▕
            let ew = max(1, (w / 8).rounded())
            return [(CGRect(x: x + w - ew, y: y, width: ew, height: h), 1)]
        default:
            return nil
        }
    }
}
