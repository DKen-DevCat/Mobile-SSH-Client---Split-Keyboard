import Foundation

/// 8bit の RGB。テーマの値（`#RRGGBB`）と、接続先が指定する true color の両方に使う。
/// どの色空間の座標として描くかは描画側が決める（設定の `color-space`）
public struct RGB: Hashable, Sendable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#RRGGBB`・`RRGGBB`・`#RGB` を読む。読めなければ nil
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        if s.count == 3 {
            s = Substring(s.map { "\($0)\($0)" }.joined())
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }

    public var description: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// 0...1 の成分
    public var components: (Double, Double, Double) {
        (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
}

/// コントラストの計算（WCAG 2 の相対輝度）。設定の `minimum-contrast` に使う
public enum Contrast {
    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func luminance(_ c: RGB) -> Double {
        let (r, g, b) = c.components
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 文字色と背景色の比が `minimum` を下回るとき、文字色を白か黒の側へ寄せて比を満たす最小の変化を返す。
    /// 色相はできるだけ保つ（白・黒との線形の混ぜ合わせを二分探索する）。満たせなければ白か黒のうち比の高い方
    public static func adjusted(foreground fg: RGB, background bg: RGB, minimum: Double) -> RGB {
        guard minimum > 1, ratio(fg, bg) < minimum else { return fg }
        let white = RGB(255, 255, 255), black = RGB(0, 0, 0)
        // 背景が暗ければ明るい側へ、明るければ暗い側へ
        let toward = luminance(bg) < 0.5 ? white : black
        guard ratio(toward, bg) >= minimum else {
            return ratio(white, bg) >= ratio(black, bg) ? white : black
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if ratio(mix(fg, toward, mid), bg) >= minimum { hi = mid } else { lo = mid }
        }
        return mix(fg, toward, hi)
    }

    /// a と b を t（0〜1）で混ぜる
    public static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded().clamped(0, 255))
        }
        return RGB(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b))
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
