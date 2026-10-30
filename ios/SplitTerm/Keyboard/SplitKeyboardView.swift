import TermCore
import UIKit

/// 分割キーボードの片側。指ごとに独立して追跡し、両手で同時に押しても取りこぼさない。
/// 文字は指を離した時点で確定する（出力順はその確定順）。⌫ と矢印は長押しでリピートする
final class SplitKeyboardView: UIView {
    let model: KeyboardModel
    var face: KeyboardFace { didSet { relayout() } }
    var rowHeight: CGFloat = 40 { didSet { relayout() } }
    var colors: KeyboardColors { didSet { setNeedsDisplay() } }
    var repeatDelay: TimeInterval = 0.4
    var repeatInterval: TimeInterval = 0.05
    var haptics = true
    /// フリックとみなす移動量（pt）
    var flickThreshold: CGFloat = 14

    private var keys: [(key: KeySpec, frame: CGRect)] = []
    private var active: [ObjectIdentifier: TouchState] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .light)

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
        keys = face.frames(in: bounds, rowHeight: rowHeight)
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
            drawLabel(key, in: r)
        }
    }

    private func drawLabel(_ key: KeySpec, in r: CGRect) {
        let isWord = key.label.count > 2
        let size = isWord ? min(12, r.height * 0.26) : min(20, r.height * 0.42)
        let font = UIFont.systemFont(ofSize: size, weight: isWord ? .medium : .regular)
        let p = NSMutableParagraphStyle()
        p.alignment = .center
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
            if haptics { feedback.impactOccurred(intensity: 0.6) }
            let hl = CALayer()
            hl.frame = hit.frame.insetBy(dx: 1, dy: 1)
            hl.cornerRadius = 6
            hl.backgroundColor = colors.pressed.cgColor
            hl.opacity = 0.85
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(hl)
            CATransaction.commit()
            let state = TouchState(key: hit.key, frame: hit.frame, start: p, highlight: hl)
            active[ObjectIdentifier(t)] = state
            switch hit.key.action {
            case .modifier(let m):
                model.modifierDown(m)
            case .key(_, _, true):
                startRepeat(state)
            case .flick(let set):
                showPopup(state, text: set.center)
            default:
                break
            }
        }
        feedback.prepare()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let s = active[ObjectIdentifier(t)], case .flick(let set) = s.key.action else { continue }
            let p = t.location(in: self)
            let d = FlickDirection.resolve(dx: p.x - s.start.x, dy: p.y - s.start.y, threshold: flickThreshold)
            showPopup(s, text: set.character(d))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 同時に離れた指は、時刻順に確定する
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let s = active.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            finish(s)
            let start = Perf.begin(.keyToSend)
            switch s.key.action {
            case .modifier(let m):
                model.modifierUp(m)
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
            guard let s = active.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            finish(s)
            if case .modifier(let m) = s.key.action { model.modifierUp(m, cancelled: true) }
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

    private func startRepeat(_ s: TouchState) {
        s.timer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self, weak s] _ in
            guard let self, let s else { return }
            s.repeated = true
            self.model.commit(s.key)
            s.timer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval, repeats: true) { [weak self, weak s] _ in
                guard let self, let s else { return }
                self.model.commit(s.key)
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
