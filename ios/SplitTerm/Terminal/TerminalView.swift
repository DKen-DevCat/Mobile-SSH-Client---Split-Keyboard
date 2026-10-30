import Metal
import QuartzCore
import TermCore
import TermSession
import UIKit

/// シェルの表示面。描くもの（画面の写し）は delegate から受け取る
protocol TerminalViewDelegate: AnyObject {
    /// 今描くもの。nil なら背景だけ
    func terminalViewFrame(_ view: TerminalView) -> (frame: ScreenFrame, theme: Theme, selection: TextSelection?)?
    func terminalView(_ view: TerminalView, tappedAt cell: GridPoint, location: CGPoint)
    func terminalView(_ view: TerminalView, doubleTappedAt cell: GridPoint)
    func terminalView(_ view: TerminalView, twoFingerTappedAt cell: GridPoint, location: CGPoint)
    /// 縦ドラッグを行に直したもの。正 = 過去へ（古い行を見る）
    func terminalView(_ view: TerminalView, scrollLines lines: Int, at cell: GridPoint)
    func terminalView(_ view: TerminalView, longPress state: UIGestureRecognizer.State, at cell: GridPoint, location: CGPoint)
    func terminalView(_ view: TerminalView, pinchZoomIn zoomIn: Bool)
    /// ハードウェアキーボード。true を返したら処理済み
    func terminalView(_ view: TerminalView, hardwareKey key: TermKey, modifiers: KeyModifiers) -> Bool
    func terminalViewEditMenu(_ view: TerminalView) -> UIMenu?
}

/// CADisplayLink から自分を強く持たないための中継
private final class WeakTarget: NSObject {
    weak var view: TerminalView?
    init(_ v: TerminalView) { view = v }
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

final class TerminalView: UIView, UIEditMenuInteractionDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    weak var delegate: TerminalViewDelegate?
    let renderer: MetalRenderer?
    private(set) var metrics: CellMetrics?
    private var link: CADisplayLink?
    private var idleTicks = 0

    // 描く必要があるか。解釈のキューからも立てる
    private let flagLock = NSLock()
    private var renderRequested = false

    // 慣性スクロール（pt/秒）
    private var velocity: CGFloat = 0
    private var accumulator = ScrollAccumulator(lineHeight: 10)
    private var lastPanCell = GridPoint(row: 0, col: 0)

    // カーソルの点滅
    var cursorBlink = false {
        didSet { if cursorBlink != oldValue { blinkPhaseStart = CACurrentMediaTime(); requestRender() } }
    }
    private var blinkPhaseStart = CACurrentMediaTime()

    private var editMenu: UIEditMenuInteraction?
    private var repeatTimer: Timer?
    var keyRepeatDelay: TimeInterval = 0.4
    var keyRepeatInterval: TimeInterval = 0.05

    override init(frame: CGRect) {
        renderer = MetalRenderer()
        super.init(frame: frame)
        isOpaque = true
        isMultipleTouchEnabled = true
        let l = metalLayer
        l.device = renderer?.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.maximumDrawableCount = 3
        l.presentsWithTransaction = false
        setColorSpace(.displayP3)
        installGestures()
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        link?.invalidate()
    }

    func setColorSpace(_ space: ColorSpace) {
        metalLayer.colorspace = CGColorSpace(name: space == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        requestRender()
    }

    // MARK: 解像度

    /// 画面の実倍率（13 mini は約 2.88）。描画レイヤの倍率をこれに合わせ、縮小を通さず物理ピクセルと 1 対 1 で描く
    var nativeScale: CGFloat { window?.screen.nativeScale ?? UIScreen.main.nativeScale }

    /// フォントと倍率を設定し、文字セルの寸法を返す
    @discardableResult
    func configureFont(family: String, cjkFamily: String, pointSize: CGFloat) -> CellMetrics? {
        let scale = nativeScale
        let spec = GlyphAtlas.FontSpec(family: family, cjkFamily: cjkFamily,
                                       pixelSize: (pointSize * scale).rounded(), scale: scale)
        metrics = renderer?.configure(spec)
        if let m = metrics { accumulator = ScrollAccumulator(lineHeight: m.heightPt) }
        requestRender()
        return metrics
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = nativeScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        requestRender()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            setNeedsLayout()
            requestRender()
        }
    }

    // MARK: 描画ループ（変化が無ければ止める。docs/design.md「待機中は描画しない」）

    /// どのスレッドからでもよい
    func requestRender() {
        flagLock.lock()
        let was = renderRequested
        renderRequested = true
        flagLock.unlock()
        if !was {
            if Thread.isMainThread { startLink() } else { DispatchQueue.main.async { [weak self] in self?.startLink() } }
        }
    }

    private func startLink() {
        guard window != nil else { return }
        if link == nil {
            let l = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
            // ProMotion の端末は 120Hz（Info.plist の CADisableMinimumFrameDurationOnPhone）
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        idleTicks = 0
        link?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if velocity != 0 { decelerate(dt: CGFloat(link.targetTimestamp - link.timestamp)) }
        flagLock.lock()
        let need = renderRequested
        renderRequested = false
        flagLock.unlock()
        if need {
            idleTicks = 0
            if !render() { requestRender() }
        } else if velocity == 0 && !cursorBlink {
            idleTicks += 1
            if idleTicks > 2 { link.isPaused = true }
        } else if cursorBlink {
            // 点滅の切り替わりだけ描く
            let phase = Int((CACurrentMediaTime() - blinkPhaseStart) / 0.5)
            if phase != lastBlinkPhase {
                lastBlinkPhase = phase
                render()
            }
        }
    }

    private var lastBlinkPhase = 0

    @discardableResult
    private func render() -> Bool {
        guard let renderer, metrics != nil, bounds.width > 0,
              let data = delegate?.terminalViewFrame(self) else { return true }
        let blinkOn = !cursorBlink || Int((CACurrentMediaTime() - blinkPhaseStart) / 0.5) % 2 == 0
        let start = Perf.begin(.frame)
        defer { Perf.end(.frame, start) }
        return renderer.draw(data.frame, theme: data.theme, selection: data.selection,
                             cursorVisible: blinkOn, scrolledBack: !data.frame.atBottom, layer: metalLayer)
    }

    // MARK: タッチ

    private func cell(at p: CGPoint) -> GridPoint {
        guard let m = metrics, let d = delegate?.terminalViewFrame(self) else { return GridPoint(row: 0, col: 0) }
        let c = m.cell(at: p, cols: d.frame.cols, rows: d.frame.rows)
        return GridPoint(row: c.row, col: c.col)
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        // 1 回のタップは待たせない（ダブルタップの 1 回目もタップとして扱う）
        let two = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        two.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        long.minimumPressDuration = 0.35
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: long)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        for g in [tap, double, two, long, pan, pinch] as [UIGestureRecognizer] { addGestureRecognizer(g) }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        velocity = 0
        let p = g.location(in: self)
        delegate?.terminalView(self, tappedAt: cell(at: p), location: p)
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        delegate?.terminalView(self, doubleTappedAt: cell(at: g.location(in: self)))
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        delegate?.terminalView(self, twoFingerTappedAt: cell(at: p), location: p)
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        delegate?.terminalView(self, longPress: g.state, at: cell(at: p), location: p)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            velocity = 0
            accumulator.reset()
            lastPanCell = cell(at: g.location(in: self))
        case .changed:
            let dy = g.translation(in: self).y
            g.setTranslation(.zero, in: self)
            let lines = accumulator.add(dy)
            if lines != 0 { delegate?.terminalView(self, scrollLines: lines, at: lastPanCell) }
        case .ended:
            velocity = g.velocity(in: self).y
            if abs(velocity) < 50 { velocity = 0 } else { startLink() }
        default:
            velocity = 0
        }
    }

    /// 指を離した後の慣性（UIScrollView と同じ減速率）
    private func decelerate(dt: CGFloat) {
        let step = velocity * dt
        velocity *= pow(0.998, dt * 1000)
        if abs(velocity) < 20 { velocity = 0 }
        let lines = accumulator.add(step)
        if lines != 0 { delegate?.terminalView(self, scrollLines: lines, at: lastPanCell) }
    }

    func stopInertia() { velocity = 0 }

    private var pinchFired = false

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        // 100% と 85% など、設定の段で止まる。1 回のピンチで 1 段
        switch g.state {
        case .began:
            pinchFired = false
        case .changed where !pinchFired && (g.scale > 1.15 || g.scale < 0.87):
            pinchFired = true
            delegate?.terminalView(self, pinchZoomIn: g.scale > 1)
        default:
            break
        }
    }

    // MARK: 編集メニュー（iOS 標準）

    func showEditMenu(at point: CGPoint) {
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        delegate?.terminalViewEditMenu(self)
    }

    // MARK: ハードウェアキーボード（docs/design.md「iPad：ハードウェアキーボード」）

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let t = Self.translate(key) else { continue }
            if delegate?.terminalView(self, hardwareKey: t.key, modifiers: t.mods) == true {
                handled = true
                startRepeat(t.key, t.mods)
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeat()
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeat()
        super.pressesCancelled(presses, with: event)
    }

    private func startRepeat(_ k: TermKey, _ mods: KeyModifiers) {
        stopRepeat()
        guard !mods.contains(.command) else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: keyRepeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.keyRepeatInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                _ = self.delegate?.terminalView(self, hardwareKey: k, modifiers: mods)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    static func translate(_ key: UIKey) -> (key: TermKey, mods: KeyModifiers)? {
        var mods: KeyModifiers = []
        let f = key.modifierFlags
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.alternate) { mods.insert(.option) }
        if f.contains(.command) { mods.insert(.command) }
        switch key.keyCode {
        case .keyboardUpArrow: return (.up, mods)
        case .keyboardDownArrow: return (.down, mods)
        case .keyboardLeftArrow: return (.left, mods)
        case .keyboardRightArrow: return (.right, mods)
        case .keyboardEscape: return (.escape, mods)
        case .keyboardTab: return (.tab, mods)
        case .keyboardReturnOrEnter, .keypadEnter: return (.enter, mods)
        case .keyboardDeleteOrBackspace: return (.backspace, mods)
        case .keyboardDeleteForward: return (.delete, mods)
        case .keyboardHome: return (.home, mods)
        case .keyboardEnd: return (.end, mods)
        case .keyboardPageUp: return (.pageUp, mods)
        case .keyboardPageDown: return (.pageDown, mods)
        case .keyboardF1: return (.function(1), mods)
        case .keyboardF2: return (.function(2), mods)
        case .keyboardF3: return (.function(3), mods)
        case .keyboardF4: return (.function(4), mods)
        case .keyboardF5: return (.function(5), mods)
        case .keyboardF6: return (.function(6), mods)
        case .keyboardF7: return (.function(7), mods)
        case .keyboardF8: return (.function(8), mods)
        case .keyboardF9: return (.function(9), mods)
        case .keyboardF10: return (.function(10), mods)
        case .keyboardF11: return (.function(11), mods)
        case .keyboardF12: return (.function(12), mods)
        default: break
        }
        // ctrl・option・command と組むときは修飾キーを除いた文字、そうでなければ shift を効かせた文字
        let plain = mods.isDisjoint(with: [.control, .option, .command])
        let text = plain ? key.characters : key.charactersIgnoringModifiers
        guard !text.isEmpty else { return nil }
        if plain { mods.remove(.shift) }
        return (.text(text), mods)
    }
}
