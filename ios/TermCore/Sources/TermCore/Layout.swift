import CoreGraphics
import Foundation

/// 画面の配置を、画面の大きさ・セーフエリア・入力手段から毎回算出する（docs/design.md「レイアウトの決め方」）。
/// 端末ごとの固定値は持たない。iPhone 13 mini の横持ち（812×375pt）で、左右 182pt のキーボードと中央 344pt のシェルになる。
/// 座標はウィンドウの左上を原点とする pt
public struct LayoutInput: Equatable, Sendable {
    public var size: CGSize
    public var safeArea: Insets
    public var hardwareKeyboard: Bool
    public var keyboard: KeyboardKind
    /// 設定の `keyboard-pitch`。nil なら算出する
    public var pitchOverride: Double?
    public var softKeyboardWithHardware: Bool

    public init(size: CGSize, safeArea: Insets, hardwareKeyboard: Bool = false, keyboard: KeyboardKind = .english,
                pitchOverride: Double? = nil, softKeyboardWithHardware: Bool = false) {
        self.size = size
        self.safeArea = safeArea
        self.hardwareKeyboard = hardwareKeyboard
        self.keyboard = keyboard
        self.pitchOverride = pitchOverride
        self.softKeyboardWithHardware = softKeyboardWithHardware
    }
}

public struct Insets: Equatable, Sendable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct LayoutResult: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// 左右に分けた画面のキーボード
        case split
        /// ハードウェアキーボード。シェルを全面に
        case hardware
        /// 窓が狭すぎて、分割キーボードとシェルが並ばない（Split View など）。シェルだけ出して知らせる
        case tooNarrow
    }

    public var mode: Mode
    public var shell: CGRect
    public var environmentBar: CGRect
    public var candidateBar: CGRect?
    public var leftKeyboard: CGRect?
    public var rightKeyboard: CGRect?
    /// キーの基準の大きさ（pt）
    public var pitch: CGFloat
    /// キーボードの 1 段の高さ（pt）
    public var rowHeight: CGFloat
}

public enum LayoutEngine {
    public static let environmentBarHeight: CGFloat = 44
    public static let candidateBarHeight: CGFloat = 34
    /// キーボードの上に空ける高さ（親指が画面の上端まで伸びないように）
    public static let keyboardTopGap: CGFloat = 40
    /// キーボードの片側の幅 = pitch × この値（13 mini: 30 × 6.07 ≒ 182pt）
    public static let keyboardWidthUnits: CGFloat = 6.07
    /// 片側の段の数の目安（1 段の高さ = キーボードの高さ ÷ これ。面ごとの段の高さは面の比で決まる）
    public static let keyboardRows = 5
    /// キーボードの高さの上限 = 幅 × この値（やや縦長。縦に長すぎないように）
    public static let keyboardAspect: CGFloat = 1.35
    /// pitch = 画面の短辺 × この値を、下の範囲に収める
    public static let pitchRatio: CGFloat = 0.08
    public static let pitchRange: ClosedRange<CGFloat> = 28...50
    /// 窓が狭いときに pitch を縮めてよい下限
    public static let minimumPitch: CGFloat = 22
    /// 1 段の高さの上限（iPad で縦に伸びすぎないように）
    public static let maximumRowHeight: CGFloat = 64
    /// キーボードとシェルの間の隙間（13 mini: 812 − 44×2 − 182×2 − 8×2 = 344pt）
    public static let keyboardGap: CGFloat = 8
    /// シェルの幅の下限。これを割るほど狭いと tooNarrow
    public static let minimumShellWidth: CGFloat = 200

    public static func compute(_ input: LayoutInput) -> LayoutResult {
        let w = input.size.width, h = input.size.height
        let s = input.safeArea
        let contentLeft = s.left, contentRight = w - s.right
        let contentWidth = max(0, contentRight - contentLeft)
        let bottom = h - s.bottom

        var pitch = input.pitchOverride.map { CGFloat($0) }
            ?? (min(w, h) * pitchRatio).clamped(pitchRange.lowerBound, pitchRange.upperBound)

        let useSoft = !input.hardwareKeyboard || input.softKeyboardWithHardware
        if useSoft {
            // 狭ければ、シェルの幅の下限が残るまで pitch を縮める
            let fit = (contentWidth - minimumShellWidth - 2 * keyboardGap) / (2 * keyboardWidthUnits)
            if pitch > fit { pitch = fit }
        }

        if !useSoft || pitch < minimumPitch {
            // シェルを全面に（ハードウェアキーボード、または狭すぎる窓）
            let barY = bottom - environmentBarHeight
            let shell = CGRect(x: contentLeft, y: s.top, width: contentWidth, height: max(0, barY - s.top))
            return LayoutResult(
                mode: useSoft ? .tooNarrow : .hardware,
                shell: shell.integral,
                environmentBar: CGRect(x: contentLeft, y: barY, width: contentWidth, height: environmentBarHeight),
                candidateBar: nil, leftKeyboard: nil, rightKeyboard: nil,
                pitch: pitch, rowHeight: 0)
        }

        let kbWidth = (pitch * keyboardWidthUnits).rounded()
        let available = max(0, bottom - s.top - keyboardTopGap)
        let kbHeight = min(available, (kbWidth * keyboardAspect).rounded(), maximumRowHeight * CGFloat(keyboardRows))
        let rowHeight = kbHeight / CGFloat(keyboardRows)
        // 英語・ローマ字の分割は下に、フリックは上に寄せる（日本語の入力で、親指の届きやすい高さに上げる）
        let kbY = input.keyboard.isFlick ? s.top + keyboardTopGap : bottom - kbHeight
        let left = CGRect(x: contentLeft, y: kbY, width: kbWidth, height: kbHeight)
        let right = CGRect(x: contentRight - kbWidth, y: kbY, width: kbWidth, height: kbHeight)

        let centerX = left.maxX + keyboardGap
        let centerWidth = right.minX - keyboardGap - centerX
        let barY = bottom - environmentBarHeight
        var shellBottom = barY
        var candidate: CGRect? = nil
        if input.keyboard.isJapanese {
            shellBottom -= candidateBarHeight
            candidate = CGRect(x: centerX, y: shellBottom, width: centerWidth, height: candidateBarHeight)
        }
        return LayoutResult(
            mode: .split,
            shell: CGRect(x: centerX, y: s.top, width: centerWidth, height: max(0, shellBottom - s.top)),
            environmentBar: CGRect(x: centerX, y: barY, width: centerWidth, height: environmentBarHeight),
            candidateBar: candidate, leftKeyboard: left, rightKeyboard: right,
            pitch: pitch, rowHeight: rowHeight)
    }
}

/// 文字セルの寸法。物理ピクセルの整数に丸める（docs/design.md「解像度」）
public struct CellMetrics: Equatable, Sendable {
    /// 画面の実倍率（UIScreen.nativeScale）
    public var scale: CGFloat
    public var widthPx: Int
    public var heightPx: Int

    public init(scale: CGFloat, widthPx: Int, heightPx: Int) {
        self.scale = scale
        self.widthPx = max(1, widthPx)
        self.heightPx = max(1, heightPx)
    }

    public var widthPt: CGFloat { CGFloat(widthPx) / scale }
    public var heightPt: CGFloat { CGFloat(heightPx) / scale }

    /// シェルの領域に入る桁数と行数
    public func grid(for shell: CGSize) -> (cols: Int, rows: Int) {
        let pxW = Int((shell.width * scale).rounded(.down))
        let pxH = Int((shell.height * scale).rounded(.down))
        return (max(1, pxW / widthPx), max(1, pxH / heightPx))
    }

    /// 点（シェルの左上を原点とする pt）から文字セルへ。85% のときもセルの中心に吸着するよう、範囲の外は端に寄せる
    public func cell(at point: CGPoint, cols: Int, rows: Int) -> (col: Int, row: Int) {
        let c = Int((point.x / widthPt).rounded(.down)).clamped(0, max(0, cols - 1))
        let r = Int((point.y / heightPt).rounded(.down)).clamped(0, max(0, rows - 1))
        return (c, r)
    }
}
