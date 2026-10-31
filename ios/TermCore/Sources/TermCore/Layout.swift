import CoreGraphics
import Foundation

/// 画面の配置を、画面の大きさ・セーフエリア・入力手段から毎回算出する（docs/design.md「レイアウトの決め方」「縦持ちの配置」）。
/// 端末ごとの固定値は持たない。iPhone 13 mini の横持ち（812×375pt）で、左 198pt・右 228pt のキーボードと中央 282pt のシェルになる。
/// 窓の高さが幅より大きければ縦持ち（別の作り: タブの 1 行・シェル・JIS の一体型を上から積む）。
/// 座標はウィンドウの左上を原点とする pt
public struct LayoutInput: Equatable, Sendable {
    public var size: CGSize
    public var safeArea: Insets
    public var hardwareKeyboard: Bool
    public var keyboard: KeyboardKind
    /// 設定の `keyboard-pitch`（キー 1 つの大きさ u）。nil なら算出する
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
        /// 左右に分けた画面のキーボード（横持ち）
        case split
        /// 縦持ちの JIS の一体型（画面の下に 1 枚）
        case full
        /// ハードウェアキーボード。シェルを全面に
        case hardware
        /// 窓が狭すぎて、分割キーボードとシェルが並ばない（Split View など）。シェルだけ出して知らせる
        case tooNarrow
    }

    public enum Orientation: Equatable, Sendable {
        case landscape
        /// 窓の高さが幅より大きい。シェルはトラックパッド（docs/design.md「縦持ち：シェルはトラックパッド」）
        case portrait
    }

    public var mode: Mode
    public var orientation: Orientation
    /// シェル。横持ちは画面の上端から下端まで（上の 2 行はこの上に前面で重なる）。縦持ちはタブの 1 行の下から、キーボードの上まで
    public var shell: CGRect
    /// 上の 1 行目（時計・状態・倍率）。セーフエリアの左右いっぱい。
    /// 縦持ちは行が無く、タブの 1 行の右端の幅 0 の枠（倍率・⚠・進み具合は、画面の側が中身の幅でタブの 1 行の右端に置く）
    public var statusRow: CGRect
    /// 上の 2 行目（タブと＋）。statusRow のすぐ下。縦持ちは上のセーフエリアの下の 1 行（左右いっぱい）
    public var tabRow: CGRect
    public var candidateBar: CGRect?
    /// キーボード選択のボタン。シェルの右下の角（候補バーがあればその上）。split のときだけ
    public var keyboardButton: CGRect?
    /// 左のキーボード（8.25u × 5.6u）と右（9.5u × 5.6u）。どちらも下寄せ（横持ち）
    public var leftKeyboard: CGRect?
    public var rightKeyboard: CGRect?
    /// 縦持ちの JIS の一体型（14.5u × 1 段の高さ × 5.6）。下寄せ・左右の中央
    public var fullKeyboard: CGRect?
    /// キー 1 つの大きさ u（pt）。横持ちの文字キー（1u）は u×u の正方形。縦持ちはキーの幅
    public var unit: CGFloat
    /// キーボードの 1 段の高さ（pt）。横持ちは u、縦持ちは u と 44pt の大きい方
    public var rowHeight: CGFloat
}

public enum LayoutEngine {
    /// 上の 1 行目（状態）の高さ
    public static let statusRowHeight: CGFloat = 20
    /// 上の 2 行目（タブ）の高さ
    public static let tabRowHeight: CGFloat = 32
    public static let candidateBarHeight: CGFloat = 34
    /// キーボードの上に空ける高さ = 上の 2 行の高さ（キーボードが 2 行に重ならない）
    public static let keyboardTopGap: CGFloat = statusRowHeight + tabRowHeight
    /// シェルの角に重ねる丸いボタン（📎 とキーボード選択）の大きさと、シェルの端からの余白
    public static let cornerButtonSize: CGFloat = 36
    public static let cornerButtonMargin: CGFloat = 6
    /// u = 画面の短辺 × この値を切り捨てた整数を、下の範囲に収める（13 mini で 24、iPad で 36）
    public static let unitRatio: CGFloat = 0.064
    public static let unitRange: ClosedRange<CGFloat> = 24...36
    /// 窓が狭い・低いときに u を縮めてよい下限。これを割るなら画面のキーボードを隠す（tooNarrow）
    public static let minimumUnit: CGFloat = 18
    /// キーボードとシェルの間の隙間（13 mini: 812 − 44×2 − 198 − 228 − 8×2 = 282pt）
    public static let keyboardGap: CGFloat = 8
    /// シェルの幅の下限。これを割るなら u を縮める
    public static let minimumShellWidth: CGFloat = 200
    /// 縦持ちの 1 段の高さの下限（Apple の HIG の最小のタップ領域）。iPhone の縦持ちは u がこれに届かないので、キーは縦に長い
    public static let portraitMinRowHeight: CGFloat = 44
    /// 縦持ちでシェルに残す高さの下限（約 11 行）。これが残らない低い窓では、1 段の高さを縮める
    public static let minimumShellHeight: CGFloat = 120

    /// 窓の高さが幅より大きければ縦持ち（向きのセンサーではなく窓の大きさで決める）
    public static func isPortrait(_ size: CGSize) -> Bool { size.height > size.width }

    public static func compute(_ input: LayoutInput) -> LayoutResult {
        if isPortrait(input.size) { return portrait(input) }
        let w = input.size.width, h = input.size.height
        let s = input.safeArea
        let contentLeft = s.left, contentRight = w - s.right
        let contentWidth = max(0, contentRight - contentLeft)
        let bottom = h - s.bottom

        var unit = input.pitchOverride.map { CGFloat($0) }
            ?? (min(w, h) * unitRatio).rounded(.down).clamped(unitRange.lowerBound, unitRange.upperBound)

        let useSoft = !input.hardwareKeyboard || input.softKeyboardWithHardware
        if useSoft {
            // 狭ければ、シェルの幅の下限が残るまで u を縮める（切り捨て）
            let facesUnits = KeyboardLayouts.leftUnits + KeyboardLayouts.rightUnits
            let fitWidth = ((contentWidth - minimumShellWidth - 2 * keyboardGap) / facesUnits).rounded(.down)
            // 低ければ、上の 2 行に重ならない高さ（下端 − 上端 − 上の 2 行）に面の高さ 5.6u が収まるまで縮める（切り捨て）
            let fitHeight = (max(0, bottom - s.top - keyboardTopGap) / KeyboardLayouts.heightUnits).rounded(.down)
            unit = min(unit, fitWidth, fitHeight)
        }

        // 上の 2 行は、セーフエリアの左右いっぱい・上端から（シェルに重なる）
        let statusRow = CGRect(x: contentLeft, y: s.top, width: contentWidth, height: statusRowHeight)
        let tabRow = CGRect(x: contentLeft, y: s.top + statusRowHeight, width: contentWidth, height: tabRowHeight)

        if !useSoft || unit < minimumUnit {
            // シェルを全面に（ハードウェアキーボード、または狭すぎる・低すぎる窓）
            let shell = CGRect(x: contentLeft, y: s.top, width: contentWidth, height: max(0, bottom - s.top))
            return LayoutResult(
                mode: useSoft ? .tooNarrow : .hardware, orientation: .landscape,
                shell: shell.integral,
                statusRow: statusRow, tabRow: tabRow,
                candidateBar: nil, keyboardButton: nil, leftKeyboard: nil, rightKeyboard: nil, fullKeyboard: nil,
                unit: unit, rowHeight: 0)
        }

        // 左 8.25u × 5.6u、右 9.5u × 5.6u。分割もフリックも同じ枠で、下に寄せる（親指の届きやすい高さ。上の 2 行には重ならない）
        let kbHeight = unit * KeyboardLayouts.heightUnits
        let kbY = bottom - kbHeight
        let left = CGRect(x: contentLeft, y: kbY, width: unit * KeyboardLayouts.leftUnits, height: kbHeight)
        let rightWidth = unit * KeyboardLayouts.rightUnits
        let right = CGRect(x: contentRight - rightWidth, y: kbY, width: rightWidth, height: kbHeight)

        let centerX = left.maxX + keyboardGap
        let centerWidth = right.minX - keyboardGap - centerX
        // シェルは上端から下端まで。かな漢字変換を使うキーボードのときだけ、下端に候補バーを置いてその上まで
        var shellBottom = bottom
        var candidate: CGRect? = nil
        if input.keyboard.isJapanese {
            shellBottom -= candidateBarHeight
            candidate = CGRect(x: centerX, y: shellBottom, width: centerWidth, height: candidateBarHeight)
        }
        let shell = CGRect(x: centerX, y: s.top, width: centerWidth, height: max(0, shellBottom - s.top))
        // キーボード選択のボタンはシェルの右下の角（📎 は左下の角。画面のキーボードを出している間は隠す）
        let button = CGRect(x: shell.maxX - cornerButtonMargin - cornerButtonSize,
                            y: shell.maxY - cornerButtonMargin - cornerButtonSize,
                            width: cornerButtonSize, height: cornerButtonSize)
        return LayoutResult(
            mode: .split, orientation: .landscape,
            shell: shell,
            statusRow: statusRow, tabRow: tabRow,
            candidateBar: candidate, keyboardButton: button, leftKeyboard: left, rightKeyboard: right, fullKeyboard: nil,
            unit: unit, rowHeight: unit)
    }

    /// 縦持ち（docs/design.md「縦持ちの配置」）。上から タブの 1 行・シェル・（候補バー）・JIS の一体型を積む（重ねない）。
    /// u = 幅 ÷ 14.5（切り捨てない）、1 段の高さ = u と 44pt の大きい方。シェルとキーボード（候補バー）の間は 8pt
    static func portrait(_ input: LayoutInput) -> LayoutResult {
        let w = input.size.width, h = input.size.height
        let s = input.safeArea
        let contentLeft = s.left, contentRight = w - s.right
        let contentWidth = max(0, contentRight - contentLeft)
        let bottom = h - s.bottom

        // タブの 1 行。状態の行は無い（時計・通信・電池は iOS の状態バー。倍率などはタブの 1 行の右端に、画面の側が置く）
        let tabRow = CGRect(x: contentLeft, y: s.top, width: contentWidth, height: tabRowHeight)
        let statusRow = CGRect(x: contentRight, y: s.top, width: 0, height: tabRowHeight)
        let shellTop = tabRow.maxY

        let useSoft = !input.hardwareKeyboard || input.softKeyboardWithHardware
        // キーの幅: 幅に 14.5 列を並べる。keyboard-pitch があれば、それと幅に収まる値の小さい方
        let fitWidth = contentWidth / KeyboardLayouts.fullUnits
        var unit = min(input.pitchOverride.map { CGFloat($0) } ?? fitWidth, fitWidth)
        var row = max(unit, portraitMinRowHeight)
        let candidateHeight = input.keyboard.isJapanese ? candidateBarHeight : 0
        if useSoft {
            // 低い窓: シェルに minimumShellHeight が残るまで 1 段の高さを縮める（キーの幅もそれより大きくしない）
            let room = bottom - shellTop - minimumShellHeight - keyboardGap - candidateHeight
            row = min(row, max(0, room) / KeyboardLayouts.heightUnits)
            unit = min(unit, row)
        }

        if !useSoft || unit < minimumUnit {
            // シェルをタブの 1 行の下から下端まで（ハードウェアキーボード、または狭すぎる・低すぎる窓）
            let shell = CGRect(x: contentLeft, y: shellTop, width: contentWidth, height: max(0, bottom - shellTop))
            return LayoutResult(
                mode: useSoft ? .tooNarrow : .hardware, orientation: .portrait,
                shell: shell.integral,
                statusRow: statusRow, tabRow: tabRow,
                candidateBar: nil, keyboardButton: nil, leftKeyboard: nil, rightKeyboard: nil, fullKeyboard: nil,
                unit: unit, rowHeight: 0)
        }

        let kbHeight = row * KeyboardLayouts.heightUnits
        let kbWidth = unit * KeyboardLayouts.fullUnits
        let keyboard = CGRect(x: contentLeft + (contentWidth - kbWidth) / 2, y: bottom - kbHeight,
                              width: kbWidth, height: kbHeight)
        // かな漢字変換を使うときは、キーボードのすぐ上に候補バー
        var above = keyboard.minY
        var candidate: CGRect? = nil
        if candidateHeight > 0 {
            above -= candidateHeight
            candidate = CGRect(x: contentLeft, y: above, width: contentWidth, height: candidateHeight)
        }
        let shell = CGRect(x: contentLeft, y: shellTop, width: contentWidth,
                           height: max(0, above - keyboardGap - shellTop))
        return LayoutResult(
            mode: .full, orientation: .portrait,
            shell: shell,
            statusRow: statusRow, tabRow: tabRow,
            candidateBar: candidate, keyboardButton: nil, leftKeyboard: nil, rightKeyboard: nil, fullKeyboard: keyboard,
            unit: unit, rowHeight: row)
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
