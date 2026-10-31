import TermCore
import UIKit

/// キーボードが入力ルータへ渡すもの
enum KeyboardEmit {
    case key(TermKey, KeyModifiers)
    /// フリック。upper は英字を大文字にする（a/A が入のとき）
    case flick(keyID: String, set: FlickSet, direction: FlickDirection, upper: Bool)
    case kanaBreak
    case kanaModify
    /// 前のキーボードへ（🌐 のタップ）
    case switchKeyboard
    /// そのキーボードへ（ABC・あいう）
    case setKeyboard(KeyboardKind)
    /// キーボードを選ぶ吹き出しを出す（🌐 の長押し）。anchor はウィンドウの座標
    case keyboardMenu(anchor: CGRect)
    /// Touch ID の位置のキー。アプリをすぐロックする
    case lockApp
    /// 📎 のキー。メディアを送るメニューを、そのキーを指す吹き出しで出す。anchor はウィンドウの座標
    case attachMedia(anchor: CGRect)
}

@MainActor
protocol KeyboardOutput: AnyObject {
    func keyboard(_ emit: KeyboardEmit)
}

/// 左右の面で共有する状態（修飾キー・caps lock・ポインタ・トラックパッド）。docs/design.md「同時入力」:
/// 修飾キーは Mac のキーボードと同じく、押している間だけ効く（離すと外れる。長押ししても 1 回）
@MainActor
final class KeyboardModel {
    weak var output: KeyboardOutput?
    /// 修飾キーの見た目が変わった（両面を描き直す）
    var onChange: (() -> Void)?
    /// ポインタへの出口（動きとクリック。左右で 1 つを共有する）
    let pointer = PointerStick()
    /// 空白兼ポインタ（左右の空白キー）の触れ方の判定。左右の指をまとめて見る（両押しが右クリック）
    private(set) var spacePointer = SpacePointerGesture()
    /// 空白兼ポインタの指に付ける ID。左右の面で重ならないよう、ここで振る
    private var touchSerial = 0
    /// 空白の長押しで、キーボード全体がトラックパッドになっている（文字と絵を薄くし、キーの面だけにする）。
    /// その指の動きはポインタ（`pointer`）に流れ、空白は打たない。変わったら両方の面を描き直す
    var trackpadMode = false {
        didSet { if trackpadMode != oldValue { onChange?() } }
    }

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
        spacePointer.keyTyped()
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

    /// 🌐 を長押しした。離してもキーボードは切り替えず、選ぶ吹き出しを出す
    func globeLongPressed(anchor: CGRect) {
        // fn として矢印などに使っている間は出さない
        guard !usedWhileHeld.contains(.fn) else { return }
        usedWhileHeld.insert(.fn)
        output?.keyboard(.keyboardMenu(anchor: anchor))
    }

    func toggleCapsLock() {
        capsLock.toggle()
        spacePointer.keyTyped()
        onChange?()
    }

    func reset() {
        held.removeAll()
        usedWhileHeld.removeAll()
        pointer.reset()
        spacePointer.reset()
        trackpadMode = false
        onChange?()
    }

    // MARK: 空白兼ポインタ（判定は TermCore の `SpacePointerGesture`。ここでは出力を実行する）

    /// 空白兼ポインタの指の ID（指が触れた時に 1 つ振る）
    func nextTouchID() -> Int {
        touchSerial += 1
        return touchSerial
    }

    func spacePointerDown(_ id: Int, key: KeySpec, side: PointerSide, at p: CGPoint, time: TimeInterval) {
        perform(spacePointer.touchDown(id, side: side, at: p, time: time), key: key)
    }

    func spacePointerMoved(_ id: Int, key: KeySpec, to p: CGPoint, time: TimeInterval) {
        perform(spacePointer.touchMoved(id, to: p, time: time), key: key)
    }

    func spacePointerUp(_ id: Int, key: KeySpec, at p: CGPoint, time: TimeInterval) {
        perform(spacePointer.touchUp(id, at: p, time: time), key: key)
    }

    func spacePointerCancelled(_ id: Int) {
        spacePointer.touchCancelled(id)
    }

    /// 出力を実行する。空白は、普通の空白キーと同じ道（修飾キー・ローマ字の変換・先行表示）で打つ。
    /// クリックは `PointerStick.click`（振動つき）、ポインタの移動は `PointerStick.move`
    private func perform(_ outputs: [SpacePointerGesture.Output], key: KeySpec) {
        for o in outputs {
            switch o {
            case .space:
                commit(key)
            case .click(let right):
                pointer.click(right: right)
            case .movePointer(let dx, let dy):
                pointer.move(dx: dx, dy: dy)
            }
        }
    }

    /// 📎 を離した。シェルの左下の 📎 と同じメニューを、そのキーを指す吹き出しで出す。anchor はウィンドウの座標
    func attachMediaTapped(anchor: CGRect) {
        noteKeyTyped()
        output?.keyboard(.attachMedia(anchor: anchor))
    }

    /// ほかのキーを打った。押している修飾キーは使われたことになり、空白兼ポインタのクリックの猶予は終わる
    private func noteKeyTyped() {
        usedWhileHeld.formUnion(held.keys)
        spacePointer.keyTyped()
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
        var action = spec.action
        // 空白兼ポインタの空白は、普通の空白キーと同じ道（修飾キー・ローマ字の変換・先行表示）。ほかのキーは猶予を終わらせる
        if case .spacePointer = action {
            action = .character(" ", shifted: nil, fn: nil)
        } else {
            spacePointer.keyTyped()
        }
        switch action {
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
        case .setKeyboard(let kind):
            emit = .setKeyboard(kind)
        case .lockApp:
            emit = .lockApp
        case .flick(let set):
            emit = .flick(keyID: spec.id, set: set, direction: direction, upper: capsLock || mods.contains(.shift))
        case .kanaBreak:
            emit = .kanaBreak
        case .kanaModify:
            emit = .kanaModify
        case .modifier, .capsLock, .attachMedia, .spacePointer:
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
