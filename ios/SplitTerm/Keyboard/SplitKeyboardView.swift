import TermCore
import UIKit

/// 分割キーボードの片側。指ごとに独立して追跡し、両手で同時に押しても取りこぼさない。
/// 文字は指を離した時点で確定する（出力順はその確定順）。⌫ と矢印は長押しでリピートする。
/// 修飾キーは押している間だけ効き、長押ししてもリピートしない。スペースの横の赤い丸はポインタ（PointerStick）。
/// フリックは押した瞬間にキーの上と上下左右へ文字の四角を出し（`FlickGuide`）、空白は 0.5 秒の長押しでキーボード全体が
/// トラックパッドになる（docs/design.md「フリックの分割」「同時入力」）
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
    /// 🌐 を長押しとみなす時間
    static let globeHoldTime: TimeInterval = 0.45
    /// 空白を長押しして、トラックパッドに入る時間と、待つ間に動いてよい距離（これ以上動いたら、離したときに空白を打つ）
    static let trackpadHoldTime: TimeInterval = 0.5
    static let trackpadSlop: CGFloat = 6

    /// ThinkPad の TrackPoint の赤
    static let pointerRed = UIColor(red: 0.86, green: 0.13, blue: 0.11, alpha: 1)

    private var keys: [(key: KeySpec, frame: CGRect)] = []
    private var active: [ObjectIdentifier: TouchState] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    /// F と J（ホームポジション）は少し強く。トラックパッドに入ったときの手応えも同じ（medium）
    private let homingFeedback = UIImpactFeedbackGenerator(style: .medium)
    /// 使い終わったフリックのガイド（押すたびに作らず、使い回す）
    private var guidePool: [FlickGuide] = []

    /// その指が何をしているか
    private enum Role {
        /// 普通のキー
        case key
        /// 赤い丸（ポインタ）
        case stick
        /// 空白を長押しして、キーボード全体をトラックパッドにしている指
        case trackpad
        /// トラックパッドの間に触れたほかの指（タップで右クリック。キーは打たない）
        case tap
    }

    @MainActor
    private final class TouchState {
        let key: KeySpec
        let frame: CGRect
        /// キーボードの座標での、触れた点
        let start: CGPoint
        let highlight: CALayer
        /// フリックの方向を決める移動量（キーの大きさから）
        let threshold: CGFloat
        var role = Role.key
        /// ウィンドウの座標での、今の点（トラックパッドに入るとき、ポインタに渡す）
        var windowPoint: CGPoint
        /// トラックパッドに入った点（ウィンドウの座標）
        var trackpadOrigin: CGPoint = .zero
        /// トラックパッドに入ってから、タップの範囲を超えて動かしたか
        var moved = false
        var guide: FlickGuide?
        var timer: Timer?
        var repeated = false
        init(key: KeySpec, frame: CGRect, start: CGPoint, windowPoint: CGPoint, highlight: CALayer, threshold: CGFloat = 0) {
            self.key = key
            self.frame = frame
            self.start = start
            self.windowPoint = windowPoint
            self.highlight = highlight
            self.threshold = threshold
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
        // トラックパッドの間は、文字と絵を薄くして、キーの面だけに見せる（iOS 標準のキーボードと同じ）
        let dim = model.trackpadMode
        let g = UIGraphicsGetCurrentContext()
        for (key, frame) in keys {
            let r = frame.insetBy(dx: gap / 2, dy: gap / 2)
            let path = UIBezierPath(roundedRect: r, cornerRadius: min(6, r.height * 0.18))
            var fill = key.style == .character ? colors.key : colors.functionKey
            if key.style == .accent { fill = colors.accent }
            if case .modifier(let m) = key.action, activeMods.contains(m) { fill = colors.accent }
            fill.setFill()
            path.fill()
            if dim { g?.setAlpha(key.style == .pointer ? 0.3 : 0.18) }
            if case .pointer = key.action {
                drawPointer(in: r)
                if dim { g?.setAlpha(1) }
                continue
            }
            if case .capsLock = key.action { drawCapsLight(in: r, on: model.capsLock) }
            drawLabel(key, in: r)
            if key.homing { drawHomingBar(in: r) }
            if dim { g?.setAlpha(1) }
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
            let wp = t.location(in: nil)
            if model.trackpadMode {
                // トラックパッドの間は、ほかの指のタップが右クリック（キーは打たない）
                let state = TouchState(key: hit.key, frame: hit.frame, start: p, windowPoint: wp, highlight: CALayer())
                state.role = .tap
                active[id] = state
                model.pointer.down(id, at: wp, time: t.timestamp)
                continue
            }
            if case .pointer = hit.key.action {
                // ポインタ: ずれはウィンドウの座標で測る（左右の面をまたいでも同じ尺度）
                let state = TouchState(key: hit.key, frame: hit.frame, start: p, windowPoint: wp, highlight: CALayer())
                state.role = .stick
                active[id] = state
                model.pointer.down(id, at: wp, time: t.timestamp)
                setNeedsDisplay(hit.frame)
                continue
            }
            // 振動とハイライトは、何よりも先に（押した感触を遅らせない）
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
            let state = TouchState(key: hit.key, frame: hit.frame, start: p, windowPoint: wp, highlight: hl,
                                   threshold: FlickDirection.threshold(keySize: hit.frame.size))
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
                showGuide(state, set: set)
            case .character(" ", _, _):
                startTrackpadHold(state, id: id)
            default:
                break
            }
        }
        feedback.prepare()
        homingFeedback.prepare()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let s = active[id] else { continue }
            s.windowPoint = t.location(in: nil)
            switch s.role {
            case .stick:
                model.pointer.moved(id, to: s.windowPoint, time: t.timestamp)
            case .trackpad:
                if hypot(s.windowPoint.x - s.trackpadOrigin.x, s.windowPoint.y - s.trackpadOrigin.y) > Self.trackpadSlop {
                    s.moved = true
                }
                model.pointer.moved(id, to: s.windowPoint, time: t.timestamp)
            case .tap:
                break
            case .key:
                let p = t.location(in: self)
                switch s.key.action {
                case .flick(let set):
                    let d = FlickDirection.resolve(dx: p.x - s.start.x, dy: p.y - s.start.y, threshold: s.threshold)
                    // 文字の無い方向は、中央の文字になる
                    s.guide?.select(set.assigned(d) == nil ? .center : d, colors: colors)
                case .character(" ", _, _):
                    // 待つ間に動いたら、トラックパッドには入らない（離したら空白）
                    if s.timer != nil, hypot(p.x - s.start.x, p.y - s.start.y) >= Self.trackpadSlop {
                        s.timer?.invalidate()
                        s.timer = nil
                    }
                default:
                    break
                }
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
            switch s.role {
            case .stick:
                model.pointer.up(id, at: t.location(in: nil), time: t.timestamp)
                setNeedsDisplay(s.frame)
            case .trackpad:
                endTrackpad(s, id: id, at: t.location(in: nil), time: t.timestamp)
            case .tap:
                model.pointer.up(id, at: t.location(in: nil), time: t.timestamp)
            case .key:
                switch s.key.action {
                case .modifier(let m):
                    model.modifierUp(m)
                case .capsLock:
                    break
                case .flick:
                    let p = t.location(in: self)
                    let d = FlickDirection.resolve(dx: p.x - s.start.x, dy: p.y - s.start.y, threshold: s.threshold)
                    model.commit(s.key, direction: d)
                default:
                    if !s.repeated { model.commit(s.key) }
                }
            }
            Perf.end(.keyToSend, start)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let s = active.removeValue(forKey: id) else { continue }
            finish(s)
            switch s.role {
            case .stick, .tap:
                model.pointer.cancel(id)
            case .trackpad:
                endTrackpad(s, id: id, at: s.windowPoint, time: t.timestamp, cancelled: true)
            case .key:
                if case .modifier(let m) = s.key.action { model.modifierUp(m, cancelled: true) }
            }
        }
    }

    private func finish(_ s: TouchState) {
        s.timer?.invalidate()
        s.timer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.highlight.removeFromSuperlayer()
        CATransaction.commit()
        if let g = s.guide {
            g.hide()
            guidePool.append(g)
            s.guide = nil
        }
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

    // MARK: 空白の長押し → トラックパッド

    /// 空白を押したまま、動かさずに 0.5 秒待ったら、キーボード全体がトラックパッドになる（iOS 標準のキーボードと同じ）。
    /// その指の動きはポインタに流れ、離したら元に戻る（空白は打たない）。0.5 秒より前に離せば、今までどおり空白
    private func startTrackpadHold(_ s: TouchState, id: ObjectIdentifier) {
        s.timer = Timer.scheduledTimer(withTimeInterval: Self.trackpadHoldTime, repeats: false) { [weak self, weak s] _ in
            MainActor.assumeIsolated {
                guard let self, let s, s.role == .key, self.active[id] === s else { return }
                // 赤い丸を使っている間は入らない（ポインタを横取りして、右クリックと取り違えるため）
                guard !self.model.pointer.isActive, !self.model.trackpadMode else { return }
                s.timer = nil
                s.role = .trackpad
                s.trackpadOrigin = s.windowPoint
                s.moved = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                s.highlight.removeFromSuperlayer()
                CATransaction.commit()
                self.model.trackpadMode = true
                if self.haptics { self.homingFeedback.impactOccurred(intensity: 1) }
                self.model.pointer.down(id, at: s.windowPoint, time: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// トラックパッドの指が離れた（取り消された）。動かさずに離したときは、クリックにしない
    private func endTrackpad(_ s: TouchState, id: ObjectIdentifier, at p: CGPoint, time: TimeInterval, cancelled: Bool = false) {
        if cancelled || !s.moved {
            model.pointer.cancel(id)
        } else {
            model.pointer.up(id, at: p, time: time)
        }
        model.trackpadMode = false
    }

    // MARK: フリックのガイド

    /// ガイドを足す層。キーボードの外のシェルや上のバーの前面まで出すので、ウィンドウの全面を覆う、タッチを受けない層に置く。
    /// 画面のビューに四角を足し引き・並べ替えすると画面全体の配置をやり直させてしまうので、層は 1 度だけ足して使い回す
    private func guideHost() -> FlickGuideHost? {
        guard let window else { return nil }
        if let host = window.subviews.first(where: { $0 is FlickGuideHost }) as? FlickGuideHost { return host }
        let host = FlickGuideHost(frame: window.bounds)
        window.addSubview(host)
        return host
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 最初の 1 打から遅れないよう、先に作っておく
        _ = guideHost()
    }

    /// フリックのキーを押した瞬間に、そのキーの上と上下左右へ同じ大きさの四角を十字に出す
    private func showGuide(_ s: TouchState, set: FlickSet) {
        guard let host = guideHost() else { return }
        // ウィンドウの上の層なので、シェルや上のバーより前面。ほかの層が後から足されていたときだけ、前に出す
        if host.superview?.subviews.last !== host { host.superview?.bringSubviewToFront(host) }
        let guide = guidePool.popLast() ?? FlickGuide(host: host)
        // 英字は a/A（caps lock）か shift で大文字（commit と同じ条件）
        let upper = model.capsLock || model.modifiers.contains(.shift)
        guide.show(set: set, upper: upper, keyFrame: convert(s.frame, to: nil), limit: window?.bounds ?? host.bounds,
                   colors: colors)
        s.guide = guide
    }

    /// フリックのガイド（iOS のフリックと同じ形）。キーの上と上下左右（その方向に文字があるものだけ）に、キーと同じ大きさの
    /// 四角を出し、指の向きの四角をアクセント色、ほかを押した色にする。画面（ウィンドウ）の外にはみ出す四角は内側へずらす
    @MainActor
    private final class FlickGuide {
        private let host: UIView
        private var labels: [FlickDirection: UILabel] = [:]
        private var selected = FlickDirection.center

        init(host: UIView) {
            self.host = host
            // 中央を最後に足す（いちばん上に重なる）
            for d in [FlickDirection.left, .up, .right, .down, .center] {
                let label = UILabel()
                label.textAlignment = .center
                label.layer.cornerRadius = 6
                label.layer.masksToBounds = true
                label.isHidden = true
                host.addSubview(label)
                labels[d] = label
            }
        }

        /// keyFrame・limit はウィンドウの座標
        func show(set: FlickSet, upper: Bool, keyFrame: CGRect, limit: CGRect, colors: KeyboardColors) {
            let w = keyFrame.width, h = keyFrame.height
            let font = UIFont.systemFont(ofSize: min(28, min(w, h) * 0.55), weight: .medium)
            let offsets: [(FlickDirection, CGFloat, CGFloat)] = [
                (.left, -w, 0), (.up, 0, -h), (.right, w, 0), (.down, 0, h), (.center, 0, 0),
            ]
            selected = .center
            for (d, dx, dy) in offsets {
                guard let label = labels[d] else { continue }
                guard let text = set.assigned(d) else {
                    label.isHidden = true
                    continue
                }
                label.text = upper ? text.uppercased() : text
                label.font = font
                label.textColor = colors.text
                label.backgroundColor = d == .center ? colors.accent : colors.pressed
                let r = Self.inside(keyFrame.offsetBy(dx: dx, dy: dy).insetBy(dx: 1, dy: 1), limit)
                label.frame = host.convert(r, from: nil)
                label.isHidden = false
                host.bringSubviewToFront(label)
            }
        }

        /// 指の向きの四角を、アクセント色にして前面に出す
        func select(_ d: FlickDirection, colors: KeyboardColors) {
            guard d != selected, let next = labels[d], !next.isHidden else { return }
            labels[selected]?.backgroundColor = colors.pressed
            next.backgroundColor = colors.accent
            host.bringSubviewToFront(next)
            selected = d
        }

        func hide() {
            for label in labels.values { label.isHidden = true }
        }

        /// 範囲の外にはみ出していたら、内側へずらす
        static func inside(_ r: CGRect, _ limit: CGRect) -> CGRect {
            var r = r
            if r.maxX > limit.maxX { r.origin.x = limit.maxX - r.width }
            if r.minX < limit.minX { r.origin.x = limit.minX }
            if r.maxY > limit.maxY { r.origin.y = limit.maxY - r.height }
            if r.minY < limit.minY { r.origin.y = limit.minY }
            return r
        }
    }
}

/// フリックのガイドを置く層。ウィンドウの全面を覆い、タッチは受けない（下のシェルやキーボードへ通す）
private final class FlickGuideHost: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
