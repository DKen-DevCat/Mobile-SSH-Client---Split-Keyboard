import TermCore
import UIKit

/// キーボードが入力ルータへ渡すもの
enum KeyboardEmit {
    case key(TermKey, KeyModifiers)
    case flick(keyID: String, set: FlickSet, direction: FlickDirection)
    case kanaBreak
    case kanaModify
    case switchKeyboard
}

protocol KeyboardOutput: AnyObject {
    func keyboard(_ emit: KeyboardEmit)
}

/// 左右の面で共有する状態（修飾キー）。docs/design.md「同時入力」:
/// 修飾キーは押している間だけ効くのに加え、タップでワンショット（次の 1 キーにだけ掛かる）にもなる
final class KeyboardModel {
    weak var output: KeyboardOutput?
    /// 修飾キーの見た目が変わった（両面を描き直す）
    var onChange: (() -> Void)?

    /// 押している指の数
    private var held: [ModifierKey: Int] = [:]
    /// 押している間に、ほかのキーを確定したか（したなら離してもワンショットにしない）
    private var usedWhileHeld: Set<ModifierKey> = []
    private(set) var oneShot: Set<ModifierKey> = []

    var active: Set<ModifierKey> {
        oneShot.union(held.filter { $0.value > 0 }.map(\.key))
    }

    func modifierDown(_ m: ModifierKey) {
        held[m, default: 0] += 1
        usedWhileHeld.remove(m)
        onChange?()
    }

    func modifierUp(_ m: ModifierKey, cancelled: Bool = false) {
        held[m, default: 1] -= 1
        if held[m]! <= 0 {
            held[m] = nil
            if !cancelled && !usedWhileHeld.contains(m) {
                // タップ: ワンショットを入れる。もう一度タップで外す
                if oneShot.contains(m) { oneShot.remove(m) } else { oneShot.insert(m) }
            }
        }
        onChange?()
    }

    func reset() {
        held.removeAll()
        oneShot.removeAll()
        usedWhileHeld.removeAll()
        onChange?()
    }

    var modifiers: KeyModifiers {
        var m: KeyModifiers = []
        let a = active
        if a.contains(.shift) { m.insert(.shift) }
        if a.contains(.control) { m.insert(.control) }
        if a.contains(.option) { m.insert(.option) }
        if a.contains(.command) { m.insert(.command) }
        return m
    }

    /// キーを確定する（指を離した時）
    func commit(_ spec: KeySpec, direction: FlickDirection = .center) {
        let a = active
        var mods = modifiers
        let fn = a.contains(.fn)
        var emit: KeyboardEmit?
        switch spec.action {
        case .character(let c, let shifted, let fnKey):
            if fn, let fnKey {
                emit = .key(fnKey, mods)
            } else {
                let text = mods.contains(.shift) ? (shifted ?? c.uppercased()) : c
                mods.remove(.shift)
                emit = .key(.text(text), mods)
            }
        case .key(let k, let fnKey, _):
            emit = .key(fn ? (fnKey ?? k) : k, mods)
        case .send:
            emit = .key(.enter, mods)
        case .newline:
            emit = .key(.newline, [])
        case .switchKeyboard:
            emit = .switchKeyboard
        case .flick(let set):
            emit = .flick(keyID: spec.id, set: set, direction: direction)
        case .kanaBreak:
            emit = .kanaBreak
        case .kanaModify:
            emit = .kanaModify
        case .modifier:
            return
        }
        // 使った修飾キーを記録し、ワンショットを外す
        usedWhileHeld.formUnion(held.keys)
        let hadOneShot = !oneShot.isEmpty
        oneShot.removeAll()
        if let emit { output?.keyboard(emit) }
        if hadOneShot { onChange?() }
    }
}

/// キーボードの色（設定のテーマから作る）
struct KeyboardColors {
    var background: UIColor
    var key: UIColor
    var functionKey: UIColor
    var pressed: UIColor
    var text: UIColor
    var subText: UIColor
    var accent: UIColor

    init(config: TermConfig) {
        let bg = config.background, fg = config.foreground
        background = UIColor(rgb: bg, space: config.colorSpace)
        key = UIColor(rgb: Contrast.mix(bg, fg, 0.13), space: config.colorSpace)
        functionKey = UIColor(rgb: Contrast.mix(bg, fg, 0.07), space: config.colorSpace)
        pressed = UIColor(rgb: Contrast.mix(bg, fg, 0.32), space: config.colorSpace)
        text = UIColor(rgb: fg, space: config.colorSpace)
        subText = UIColor(rgb: Contrast.mix(fg, bg, 0.45), space: config.colorSpace)
        accent = UIColor(rgb: config.accent, space: config.colorSpace)
    }
}

extension UIColor {
    /// テーマの色。設定の color-space に合わせて Display P3 か sRGB の座標として読む
    convenience init(rgb c: RGB, space: ColorSpace, alpha: CGFloat = 1) {
        let (r, g, b) = c.components
        if space == .displayP3 {
            self.init(displayP3Red: r, green: g, blue: b, alpha: alpha)
        } else {
            self.init(red: r, green: g, blue: b, alpha: alpha)
        }
    }
}
