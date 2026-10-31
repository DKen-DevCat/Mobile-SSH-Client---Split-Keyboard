import Foundation

/// セルの色の指定（接続先が決めたもの）。エミュレータの型に頼らず、色を決める規則だけを TermCore に置く
/// （docs/design.md「色」）。Mac の `swift test` で固定できる
public enum CellColor: Equatable, Sendable {
    /// 256 色の表の番号（0〜15 はテーマのパレット、16〜255 は xterm の標準）
    case palette(Int)
    case rgb(RGB)
    /// 既定の文字色・背景色
    case defaultColor
    /// 既定色の反転（文字色なら背景色、背景色なら文字色）
    case defaultInverted
}

/// セルの見た目の指定のうち、色の決め方に効くもの
public struct CellColorFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// 文字色と背景色を入れ替える
    public static let inverse = CellColorFlags(rawValue: 1)
    /// 薄く（背景へ寄せる）
    public static let dim = CellColorFlags(rawValue: 2)
    /// 隠す（文字色を背景色にする）
    public static let invisible = CellColorFlags(rawValue: 4)
    /// 太字
    public static let bold = CellColorFlags(rawValue: 8)
}

/// 256 色の表。0〜15 はテーマのパレット、16〜255 は xterm の標準
public enum XTerm256 {
    /// 6×6×6 の立方体の 1 軸の値
    static let cubeSteps: [UInt8] = [0, 95, 135, 175, 215, 255]

    /// 16〜231（6×6×6 の色の立方体）と 232〜255（灰色 24 段）の標準の色。範囲外は nil
    public static func standard(_ index: Int) -> RGB? {
        switch index {
        case 16...231:
            let i = index - 16
            return RGB(cubeSteps[i / 36], cubeSteps[(i / 6) % 6], cubeSteps[i % 6])
        case 232...255:
            let v = UInt8(8 + (index - 232) * 10)
            return RGB(v, v, v)
        default:
            return nil
        }
    }

    /// 256 色の表。パレットが 16 色に足りなければ、足りない所は黒
    public static func table(palette: [RGB]) -> [RGB] {
        var t = Array(palette.prefix(16))
        while t.count < 16 { t.append(RGB(0, 0, 0)) }
        for i in 16..<256 { t.append(standard(i)!) }
        return t
    }
}

/// セルの文字色と背景色を決める規則（画面にもエミュレータにも頼らない純粋な関数）。
/// 順に、太字を明るく（`bold-is-bright`）→ 反転 → 薄く → 隠す、隠さないなら最小コントラスト補正（`minimum-contrast`）
public struct CellColorRules: Equatable, Sendable {
    public var foreground: RGB
    public var background: RGB
    /// 256 色の表
    public var table: [RGB]
    /// 文字と背景のコントラスト比の下限。1 以下で補正しない
    public var minimumContrast: Double
    public var boldIsBright: Bool

    public init(foreground: RGB, background: RGB, palette: [RGB], minimumContrast: Double = 1, boldIsBright: Bool = false) {
        self.foreground = foreground
        self.background = background
        table = XTerm256.table(palette: palette)
        self.minimumContrast = minimumContrast
        self.boldIsBright = boldIsBright
    }

    public init(config: TermConfig) {
        self.init(foreground: config.foreground, background: config.background, palette: config.palette,
                  minimumContrast: config.minimumContrast, boldIsBright: config.boldIsBright)
    }

    public func color(_ c: CellColor, isForeground: Bool) -> RGB {
        switch c {
        case .palette(let i): return table[min(max(i, 0), table.count - 1)]
        case .rgb(let v): return v
        case .defaultColor: return isForeground ? foreground : background
        case .defaultInverted: return isForeground ? background : foreground
        }
    }

    /// 太字を明るく: 太字で、文字色がパレットの 0〜7 なら 8〜15。true color と既定の文字色は変えない
    public func brightened(_ fg: CellColor, flags: CellColorFlags) -> CellColor {
        guard boldIsBright, flags.contains(.bold), case .palette(let i) = fg, (0..<8).contains(i) else { return fg }
        return .palette(i + 8)
    }

    /// 補正を覚えずに決める（テスト・描画以外の用途）
    public func resolve(fg: CellColor, bg: CellColor, flags: CellColorFlags) -> (fg: RGB, bg: RGB) {
        resolve(fg: fg, bg: bg, flags: flags) { Contrast.adjusted(foreground: $0, background: $1, minimum: minimumContrast) }
    }

    /// 文字色と背景色を決める。`readable` は最小コントラスト補正（文字色, 背景色）で、描画は結果を覚える版を渡す。
    /// 隠すときと、補正しない設定のときは呼ばない
    public func resolve(fg: CellColor, bg: CellColor, flags: CellColorFlags,
                        readable: (RGB, RGB) -> RGB) -> (fg: RGB, bg: RGB) {
        // 太字を明るくするのは反転の前（反転すると、明るくした色が背景になる）
        var f = color(brightened(fg, flags: flags), isForeground: true)
        var b = color(bg, isForeground: false)
        if flags.contains(.inverse) { swap(&f, &b) }
        if flags.contains(.dim) { f = Contrast.mix(f, b, 0.4) }
        if flags.contains(.invisible) {
            f = b
        } else if minimumContrast > 1 {
            f = readable(f, b)
        }
        return (f, b)
    }
}
