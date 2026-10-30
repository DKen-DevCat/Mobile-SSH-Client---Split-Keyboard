import TermCore
import UIKit

/// 分割キーボードの片側。指ごとに独立して追跡し、両手で同時に押しても取りこぼさない。
/// 文字は指を離した時点で確定する（出力順はその確定順）。⌫ と矢印は長押しでリピートする。
/// 修飾キーは押している間だけ効き、長押ししてもリピートしない。スペースの横の赤い丸はポインタ（PointerStick）
final class SplitKeyboardView: UIView {
    let model: KeyboardModel
    var face: KeyboardFace { didSet { relayout() } }
    /// 1 段の高さの目安（隙間と文字の大きさに使う。段ごとの高さは面の比で決まる）
    var rowHeight: CGFloat = 40 { didSet { setNeedsDisplay() } }
    var colors: KeyboardColors { didSet { setNeedsDisplay() } }
    var repeatDelay: TimeInterval = 0.4
    var repeatInterval: TimeInterval = 0.05
    var haptics = true {
        didSet { model.pointer.haptics = haptics }
    }
    /// フリックとみなす移動量（pt）
    var flickThreshold: CGFloat = 14
    /// 🌐 を長押しとみなす時間
    static let globeHoldTime: TimeInterval = 0.45

    /// ThinkPad の TrackPoint の赤
    static let pointerRed = UIColor(red: 0.86, green: 0.13, blue: 0.11, alpha: 1)

    private var keys: [(key: KeySpec, frame: CGRect)] = []
    private var active: [ObjectIdentifier: TouchState] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    /// F と J（ホームポジション）は少し強く
    private let homingFeedback = UIImpactFeedbackGenerator(style: .medium)

    @MainActor
    private final class TouchState {
        let key: KeySpec
        let frame: CGRect
        let start: CGPoint
        let highlight: CALayer
        var popup: UILabel?
        var timer: Timer?
        var repeated = false
        init(key: KeySpec, frame: CGRect, start: CGPoint, highlight: CALayer) {
            self.key = key
            self.frame = frame
            self.start = start
            self.highlight = highlight
        }
    }

    init(face: KeyboardFace, model: KeyboardModel, colors: KeyboardColors) {
        self.face = face
        self.model = model
        self.colors = colors
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    private func relayout() {
        keys = face.frames(in: bounds)
        setNeedsDisplay()
    }

    // MARK: 描画（面は静的に描き、押したキーだけ上に重ねる）

    override func draw(_ rect: CGRect) {
        colors.background.setFill()
        UIRectFill(bounds)
        let activeMods = model.active
        let gap: CGFloat = max(2, rowHeight * 0.06)
        for (key, frame) in keys {
            let r = frame.insetBy(dx: gap / 2, dy: gap / 2)
            let path = UIBezierPath(roundedRect: r, cornerRadius: min(6, r.height * 0.18))
            var fill = key.style == .character ? colors.key : colors.functionKey
            if key.style == .accent { fill = colors.accent }
            if case .modifier(let m) = key.action, activeMods.contains(m) { fill = colors.accent }
            fill.setFill()
            path.fill()
            if case .pointer = key.action {
                drawPointer(in: r)
                continue
            }
            if case .capsLock = key.action { drawCapsLight(in: r, on: model.capsLock) }
            drawLabel(key, in: r)
            if key.homing { drawHomingBar(in: r) }
        }
    }

    private func paragraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    private func drawLabel(_ key: KeySpec, in r: CGRect) {
        let p = paragraph()
        if let name = key.symbol {
            // 絵（F キー・🌐・Touch ID）。F キーは絵の下に小さく番号
            let hasText = !key.label.isEmpty
            let side = min(r.width, r.height) * (hasText ? 0.42 : 0.52)
            let conf = UIImage.SymbolConfiguration(pointSize: side, weight: .regular)
            if let img = UIImage(systemName: name, withConfiguration: conf)?.withTintColor(colors.text, renderingMode: .alwaysOriginal) {
                let sz = img.size
                let y = hasText ? r.minY + r.height * 0.12 : r.midY - sz.height / 2
                img.draw(in: CGRect(x: r.midX - sz.width / 2, y: y, width: sz.width, height: sz.height))
            }
            if hasText {
                let font = UIFont.systemFont(ofSize: min(9, r.height * 0.24))
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.subText, .paragraphStyle: p]
                (key.label as NSString).draw(in: CGRect(x: r.minX, y: r.maxY - font.lineHeight - r.height * 0.06,
                                                        width: r.width, height: font.lineHeight), withAttributes: attrs)
            }
            return
        }
        let isWord = key.label.count > 2
        let size = isWord ? min(11, r.height * 0.24) : min(20, r.height * 0.42)
        let font = UIFont.systemFont(ofSize: size, weight: isWord ? .medium : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.text, .paragraphStyle: p]
        let label = key.label as NSString
        let h = label.size(withAttributes: attrs).height
        var y = r.midY - h / 2
        if let sub = key.subLabel {
            let subFont = UIFont.systemFont(ofSize: min(10, r.height * 0.22))
            let subAttrs: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: colors.subText, .paragraphStyle: p]
            (sub as NSString).draw(in: CGRect(x: r.minX, y: r.minY + r.height * 0.08, width: r.width, height: subFont.lineHeight),
                                   withAttributes: subAttrs)
            y += r.height * 0.1
        }
        label.draw(in: CGRect(x: r.minX, y: y, width: r.width, height: h), withAttributes: attrs)
        if let option = key.option {
            // option で打つ文字（€・#）は右下に小さく
            let f = UIFont.systemFont(ofSize: min(9, r.height * 0.2))
            let right = NSMutableParagraphStyle()
            right.alignment = .right
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: colors.subText, .paragraphStyle: right]
            (option as NSString).draw(in: CGRect(x: r.minX, y: r.maxY - f.lineHeight - r.height * 0.06,
                                                 width: r.width - r.width * 0.1, height: f.lineHeight), withAttributes: a)
        }
    }

    /// F と J の突起（指で探す印）
    private func drawHomingBar(in r: CGRect) {
        let w = r.width * 0.28, h: CGFloat = max(1.5, r.height * 0.035)
        let bar = UIBezierPath(roundedRect: CGRect(x: r.midX - w / 2, y: r.maxY - r.height * 0.16, width: w, height: h),
                               cornerRadius: h / 2)
        colors.subText.setFill()
        bar.fill()
    }

    /// caps lock のランプ（入のとき緑に光る）
    private func drawCapsLight(in r: CGRect, on: Bool) {
        let d = max(4, r.height * 0.1)
        let dot = UIBezierPath(ovalIn: CGRect(x: r.minX + r.width * 0.1, y: r.minY + r.height * 0.12, width: d, height: d))
        (on ? UIColor.systemGreen : colors.subText.withAlphaComponent(0.4)).setFill()
        dot.fill()
    }

    /// 赤い丸（TrackPoint）。触れている間は少し明るく
    private func drawPointer(in r: CGRect) {
        let d = min(r.width, r.height) * 0.62
        let circle = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        let red = model.pointer.isActive ? Self.pointerRed.withAlphaComponent(1) : Self.pointerRed.withAlphaComponent(0.92)
        red.setFill()
        UIBezierPath(ovalIn: circle).fill()
        // 滑り止めの粒の質感（内側の輪）
        UIColor.black.withAlphaComponent(0.25).setStroke()
        let ring = UIBezierPath(ovalIn: circle.insetBy(dx: d * 0.18, dy: d * 0.18))
        ring.lineWidth = max(1, d * 0.06)
        ring.stroke()
    }

    // MARK: タッチ

    private func key(at p: CGPoint) -> (key: KeySpec, frame: CGRect)? {
        if let hit = keys.first(where: { $0.frame.contains(p) }) { return hit }
        // 隙間や端は、いちばん近いキー
        return keys.min { a, b in
            hypot(a.frame.midX - p.x, a.frame.midY - p.y) < hypot(b.frame.midX - p.x, b.frame.midY - p.y)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            guard let hit = key(at: p) else { continue }
            let id = ObjectIdentifier(t)
            if case .pointer = hit.key.action {
                // ポインタ: ずれはウィンドウの座標で測る（左右の面をまたいでも同じ尺度）
                let state = TouchState(key: hit.key, frame: hit.frame, start: p, highlight: CALayer())
                active[id] = state
                model.pointer.down(id, at: t.location(in: nil), time: t.timestamp)
                setNeedsDisplay(hit.frame)
                continue
            }
            if haptics {
                if hit.key.homing { homingFeedback.impactOccurred(intensity: 1) } else { feedback.impactOccurred(intensity: 0.6) }
            }
            let hl = CALayer()
            hl.frame = hit.frame.insetBy(dx: 1, dy: 1)
            hl.cornerRadius = 6
            // F と J は押すと赤く光る
            hl.backgroundColor = hit.key.homing ? Self.pointerRed.withAlphaComponent(0.85).cgColor : colors.pressed.cgColor
            hl.opacity = hit.key.homing ? 1 : 0.85
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(hl)
            CATransaction.commit()
            let state = TouchState(key: hit.key, frame: hit.frame, start: p, highlight: hl)
            active[id] = state
            switch hit.key.action {
            case .modifier(let m):
                model.modifierDown(m)
                if hit.key.id == "globe" { startGlobeHold(state) }
            case .capsLock:
                model.toggleCapsLock()
            case .key(_, _, true):
                startRepeat(state)
            case .flick(let set):
                showPopup(state, text: set.center)
            default:
                break
            }
        }
        feedback.prepare()
        homingFeedback.prepare()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let s = active[ObjectIdentifier(t)] else { continue }
            switch s.key.action {
            case .pointer:
                model.pointer.moved(ObjectIdentifier(t), to: t.location(in: nil))
            case .flick(let set):
                let p = t.location(in: self)
                let d = FlickDirection.resolve(dx: p.x - s.start.x, dy: p.y - s.start.y, threshold: flickThreshold)
                showPopup(s, text: set.character(d))
            default:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 同時に離れた指は、時刻順に確定する
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = ObjectIdentifier(t)
            guard let s = active.removeValue(forKey: id) else { continue }
            finish(s)
            let start = Perf.begin(.keyToSend)
            switch s.key.action {
            case .pointer:
                model.pointer.up(id, at: t.location(in: nil), time: t.timestamp)
                setNeedsDisplay(s.frame)
            case .modifier(let m):
                model.modifierUp(m)
            case .capsLock:
                break
            case .flick:
                let p = t.location(in: self)
                let d = FlickDirection.resolve(dx: p.x - s.start.x, dy: p.y - s.start.y, threshold: flickThreshold)
                model.commit(s.key, direction: d)
            default:
                if !s.repeated { model.commit(s.key) }
            }
            Perf.end(.keyToSend, start)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let s = active.removeValue(forKey: id) else { continue }
            finish(s)
            switch s.key.action {
            case .modifier(let m): model.modifierUp(m, cancelled: true)
            case .pointer: model.pointer.cancel(id)
            default: break
            }
        }
    }

    private func finish(_ s: TouchState) {
        s.timer?.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.highlight.removeFromSuperlayer()
        CATransaction.commit()
        s.popup?.removeFromSuperview()
    }

    /// 🌐 を押したまま少し待ったら、キーボードを選ぶ吹き出しを出す（ほかのキーを押していなければ）
    private func startGlobeHold(_ s: TouchState) {
        s.timer = Timer.scheduledTimer(withTimeInterval: Self.globeHoldTime, repeats: false) { [weak self, weak s] _ in
            MainActor.assumeIsolated {
                guard let self, let s, self.active.values.contains(where: { $0 === s }) else { return }
                self.model.globeLongPressed(anchor: self.convert(s.frame, to: nil))
            }
        }
    }

    private func startRepeat(_ s: TouchState) {
        s.timer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self, weak s] _ in
            MainActor.assumeIsolated {
                guard let self, let s else { return }
                s.repeated = true
                self.model.commit(s.key)
                s.timer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval, repeats: true) { [weak self, weak s] _ in
                    MainActor.assumeIsolated {
                        guard let self, let s else { return }
                        self.model.commit(s.key)
                    }
                }
            }
        }
    }

    /// フリックの候補をキーの上に出す
    private func showPopup(_ s: TouchState, text: String) {
        let label: UILabel
        if let l = s.popup {
            label = l
        } else {
            label = UILabel()
            label.textAlignment = .center
            label.font = .systemFont(ofSize: min(30, s.frame.height * 0.6), weight: .medium)
            label.textColor = colors.text
            label.backgroundColor = colors.pressed
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            let w = max(s.frame.width, 44), h = max(s.frame.height * 0.9, 40)
            label.frame = CGRect(x: s.frame.midX - w / 2, y: s.frame.minY - h - 4, width: w, height: h)
            addSubview(label)
            s.popup = label
        }
        label.text = text
    }
}
