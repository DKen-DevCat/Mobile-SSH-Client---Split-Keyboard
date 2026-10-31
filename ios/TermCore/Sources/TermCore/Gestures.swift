import CoreGraphics
import Foundation

/// シェルのタッチ操作の 3 つのモード（docs/design.md「メインシェルのタッチ操作」）
public enum GestureMode: Equatable, Sendable {
    /// 普通のシェル。ジェスチャはアプリの中で処理する
    case normal
    /// vim・tmux・htop などがマウスを求めている。タップやスクロールを SGR のマウスイベントで送る
    case mouse
    /// less・man など（代替画面でマウス報告なし）。スクロールを ↑↓ キーで送る
    case alternateScroll

    public static func decide(mouseReporting: Bool, alternateScreen: Bool, allowMouse: Bool) -> GestureMode {
        if mouseReporting && allowMouse { return .mouse }
        if alternateScreen { return .alternateScroll }
        return .normal
    }
}

/// SGR 形式（1006）のマウスイベント。座標は 0 始まりで受け、1 始まりで送る
public enum MouseEncoder {
    public enum Button: Int, Sendable {
        case left = 0, middle = 1, right = 2
        case wheelUp = 64, wheelDown = 65
    }

    public static func press(_ b: Button, col: Int, row: Int, mods: KeyModifiers = []) -> [UInt8] {
        sgr(code: b.rawValue | bits(mods), col: col, row: row, final: "M")
    }

    public static func release(_ b: Button, col: Int, row: Int, mods: KeyModifiers = []) -> [UInt8] {
        sgr(code: b.rawValue | bits(mods), col: col, row: row, final: "m")
    }

    /// ボタンを押したままの移動（ドラッグ）
    public static func drag(_ b: Button, col: Int, row: Int, mods: KeyModifiers = []) -> [UInt8] {
        sgr(code: (b.rawValue | 32) | bits(mods), col: col, row: row, final: "M")
    }

    /// タップ = 押して離す
    public static func click(_ b: Button, col: Int, row: Int) -> [UInt8] {
        press(b, col: col, row: row) + release(b, col: col, row: row)
    }

    static func bits(_ m: KeyModifiers) -> Int {
        (m.contains(.shift) ? 4 : 0) | (m.contains(.option) ? 8 : 0) | (m.contains(.control) ? 16 : 0)
    }

    static func sgr(code: Int, col: Int, row: Int, final: Character) -> [UInt8] {
        Array("\u{1b}[<\(code);\(col + 1);\(row + 1)\(final)".utf8)
    }
}

/// 縦ドラッグを行単位にそろえる。ドラッグ量を行の高さで割り、端数は次へ持ち越す
public struct ScrollAccumulator: Sendable {
    public var lineHeight: CGFloat
    var remainder: CGFloat = 0

    public init(lineHeight: CGFloat) {
        self.lineHeight = max(1, lineHeight)
    }

    /// 指の移動量（下へ正）を足し、動かす行数を返す。正 = 過去へ（上へスクロールして古い行を見る）
    public mutating func add(_ dy: CGFloat) -> Int {
        remainder += dy
        let lines = Int((remainder / lineHeight).rounded(.towardZero))
        remainder -= CGFloat(lines) * lineHeight
        return lines
    }

    public mutating func reset() { remainder = 0 }
}

/// 倍率の段（ピンチ・倍率ボタン・command +/-）
public struct ZoomSteps: Sendable, Equatable {
    public var steps: [Int]
    public private(set) var index: Int

    public init(steps: [Int], current: Int? = nil) {
        let s = steps.isEmpty ? [100] : steps
        self.steps = s
        self.index = current.flatMap { s.firstIndex(of: $0) } ?? 0
    }

    public var percent: Int { steps[index] }

    /// 次の段へ（ボタン。端まで行ったら最初へ戻る）
    public mutating func cycle() { index = (index + 1) % steps.count }

    /// 大きく / 小さく（ピンチと command +/-）。端で止まる
    public mutating func zoom(in larger: Bool) {
        let sorted = steps.enumerated().sorted { $0.element < $1.element }
        guard let pos = sorted.firstIndex(where: { $0.offset == index }) else { return }
        let next = larger ? min(pos + 1, sorted.count - 1) : max(pos - 1, 0)
        index = sorted[next].offset
    }
}

/// 空白兼ポインタ（ポインタ）の動き（docs/design.md「ポインタ」）。ノートパソコンのトラックパッドと同じ加速:
/// 指の動いた分だけ動き、速く動かすほど遠くへ届く。止めれば止まる
public enum PointerCurve {
    /// これ以下の速さ（pt/秒）では、倍率は最小
    public static let slowSpeed: CGFloat = 60
    /// これ以上の速さ（pt/秒）では、倍率は最大
    public static let fastSpeed: CGFloat = 900
    /// ゆっくり動かしたときの倍率（指より少し細かく動く）
    public static let minGain: CGFloat = 0.9
    /// 速く動かしたときの倍率
    public static let maxGain: CGFloat = 3.2

    /// 指の速さ（pt/秒）から、指の動きに掛ける倍率。`slowSpeed` 以下で `minGain`、`fastSpeed` 以上で `maxGain`、
    /// その間は滑らかに（smoothstep）増える。負・0・数でない値は最小
    public static func gain(speed: CGFloat) -> CGFloat {
        guard speed > slowSpeed else { return minGain }
        let t = min(1, (speed - slowSpeed) / (fastSpeed - slowSpeed))
        return minGain + (maxGain - minGain) * (t * t * (3 - 2 * t))
    }
}

/// ポインタが動ける範囲（四角の和）。範囲の外へ出る動きは、和の中で最も近い点に寄せる
public enum PointerArea {
    /// 点を四角の中に寄せる。右端・下端は 1pt 内側（その点の下のビューを `hitTest` で引けるように）
    public static func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(rect.minX, p.x), max(rect.minX, rect.maxX - 1)),
                y: min(max(rect.minY, p.y), max(rect.minY, rect.maxY - 1)))
    }

    /// 点を、四角の和の中の最も近い点に寄せる（和の中ならそのまま）。空の四角は無いものとして扱う。四角が 1 つも無ければそのまま
    public static func clamp(_ p: CGPoint, toUnionOf rects: [CGRect]) -> CGPoint {
        var best: (point: CGPoint, distance: CGFloat)?
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let q = clamp(p, to: rect)
            let d = hypot(q.x - p.x, q.y - p.y)
            if let b = best, b.distance <= d { continue }
            best = (q, d)
        }
        return best?.point ?? p
    }
}
