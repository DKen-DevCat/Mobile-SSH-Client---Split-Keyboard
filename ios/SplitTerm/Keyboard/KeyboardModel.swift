import TermCore
import UIKit

/// キーボードが入力ルータへ渡すもの
enum KeyboardEmit {
    case key(TermKey, KeyModifiers)
    case flick(keyID: String, set: FlickSet, direction: FlickDirection)
    case kanaBreak
    case kanaModify
    case switchKeyboard
    /// Touch ID の位置のキー。アプリをすぐロックする
    case lockApp
}

@MainActor
protocol KeyboardOutput: AnyObject {
    func keyboard(_ emit: KeyboardEmit)
}

/// 左右の面で共有する状態（修飾キー・caps lock・ポインタ）。docs/design.md「同時入力」:
/// 修飾キーは Mac のキーボードと同じく、押している間だけ効く（離すと外れる。長押ししても 1 回）
@MainActor
final class KeyboardModel {
    weak var output: KeyboardOutput?
    /// 修飾キーの見た目が変わった（両面を描き直す）
    var onChange: (() -> Void)?
    /// スペースの横の赤い丸（左右で 1 つを共有する）
    let pointer = PointerStick()

    /// 押している指の数
    private var held: [ModifierKey: Int] = [:]
    /// 押している間に、ほかのキーを確定したか（fn をほかのキーに使わずに離したら、キーボードを切り替える）
    private var usedWhileHeld: Set<ModifierKey> = []
    private(set) var capsLock = false

    var active: Set<ModifierKey> {
        Set(held.filter { $0.value > 0 }.map(\.key))
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
            // 🌐: ほかのキーに使わずに離したら、英語とかなを切り替える（Mac の fn と同じ）
            if m == .fn && !cancelled && !usedWhileHeld.contains(.fn) { output?.keyboard(.switchKeyboard) }
        }
        onChange?()
    }

    func toggleCapsLock() {
        capsLock.toggle()
        onChange?()
    }

    func reset() {
        held.removeAll()
        usedWhileHeld.removeAll()
        pointer.reset()
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

    /// 英字 1 文字（caps lock が効く）
    private static func isLetter(_ c: String) -> Bool {
        c.count == 1 && c.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
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
            } else if mods.contains(.option), !mods.contains(.command), let o = spec.option {
                // キーに刷ってある option の文字（2 の €、3 の #）。option-as-meta より先に効く
                mods.remove(.option)
                mods.remove(.shift)
                emit = .key(.text(o), mods)
            } else {
                // caps lock は英字だけ大文字にする（Mac と同じく、shift と重ねても大文字のまま）
                let upper = mods.contains(.shift) || (capsLock && Self.isLetter(c))
                let text = upper ? (shifted ?? c.uppercased()) : c
                mods.remove(.shift)
                emit = .key(.text(text), mods)
            }
        case .key(let k, let fnKey, _):
            emit = .key(fn ? (fnKey ?? k) : k, mods)
        case .send:
            // shift＋return は改行（Claude Code などで、送らずに次の行へ）
            emit = mods.contains(.shift) ? .key(.newline, []) : .key(.enter, mods)
        case .newline:
            emit = .key(.newline, [])
        case .switchKeyboard:
            emit = .switchKeyboard
        case .lockApp:
            emit = .lockApp
        case .flick(let set):
            emit = .flick(keyID: spec.id, set: set, direction: direction)
        case .kanaBreak:
            emit = .kanaBreak
        case .kanaModify:
            emit = .kanaModify
        case .modifier, .capsLock, .pointer:
            return
        }
        // 押している修飾キーを、ほかのキーに使ったと記録する
        usedWhileHeld.formUnion(held.keys)
        if let emit { output?.keyboard(emit) }
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
