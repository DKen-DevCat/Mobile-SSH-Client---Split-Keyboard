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
    /// 変換中の読みと先行表示を重ねるカーソルのセル（見えている画面の中の桁と行）。カーソルが隠れていても返す。
    /// スクロールバックを見ている間などは nil（重ねない）
    func terminalViewCursorCell(_ view: TerminalView) -> (col: Int, row: Int)?
    /// 縦持ちのトラックパッドの出力（`TrackpadGesture`）。行き先はポインタの位置で、受け手が決める
    func terminalView(_ view: TerminalView, trackpad output: TrackpadGesture.Output)
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
    private nonisolated let flagLock = NSLock()
    /// flagLock の中だけで読み書きする
    private nonisolated(unsafe) var renderRequested = false

    // 縦ドラッグを行単位にそろえる。指を離したら止まる（慣性は無い）
    private var accumulator = ScrollAccumulator(lineHeight: 10)
    private var lastPanCell = GridPoint(row: 0, col: 0)

    // カーソルの点滅
    var cursorBlink = false {
        didSet { if cursorBlink != oldValue { blinkPhaseStart = CACurrentMediaTime(); requestRender() } }
    }
    private var blinkPhaseStart = CACurrentMediaTime()

    private var editMenu: UIEditMenuInteraction?
    /// 横持ちの、シェルを指で直接触る操作（タップ・ダブルタップ・2 本指のタップ・長押し・縦ドラッグ・ピンチ）
    private var directGestures: [UIGestureRecognizer] = []
    /// 縦持ちのトラックパッド（docs/design.md「縦持ち：シェルはトラックパッド」）。判定は TermCore の `TrackpadGesture`
    private var trackpad = TrackpadGesture()
    /// 触れている指 → トラックパッドに渡す指の ID
    private var trackpadTouches: [ObjectIdentifier: Int] = [:]
    private var trackpadSerial = 0
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
    func configureFont(family: String, cjkFamily: String, pointSize: CGFloat, thicken: Bool) -> CellMetrics? {
        let scale = nativeScale
        let spec = GlyphAtlas.FontSpec(family: family, cjkFamily: cjkFamily,
                                       pixelSize: (pointSize * scale).rounded(), scale: scale, thicken: thicken)
        metrics = renderer?.configure(spec)
        if let m = metrics { accumulator = ScrollAccumulator(lineHeight: m.heightPt) }
        setInlineFont(family: family, pointSize: pointSize)
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
            // ウィンドウに載る前の描画の頼み（起動時のフォントの設定など）は、印だけ立って描画のループが動いていない。
            // requestRender は「もう頼んである」と見て何もしないので、ここで必ず描画のループを動かす
            flagLock.lock()
            renderRequested = true
            flagLock.unlock()
            startLink()
        }
    }

    // MARK: 描画ループ（変化が無ければ止める。docs/design.md「待機中は描画しない」）

    /// どのスレッドからでもよい（解析のキューからも呼ぶ）
    nonisolated func requestRender() {
        flagLock.lock()
        let was = renderRequested
        renderRequested = true
        flagLock.unlock()
        guard !was else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { startLink() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.startLink() }
        }
    }

    /// 描画のループを動かす。ウィンドウに載っていなければ何もしない（載ったときに didMoveToWindow が動かす）
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
        flagLock.lock()
        let need = renderRequested
        renderRequested = false
        flagLock.unlock()
        if need {
            idleTicks = 0
            if !render() { requestRender() }
        } else if !cursorBlink {
            idleTicks += 1
            if idleTicks > 2 { link.isPaused = true }
        } else {
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
        let drawn = renderer.draw(data.frame, theme: data.theme, selection: data.selection,
                                  cursorVisible: blinkOn, scrolledBack: !data.frame.atBottom, layer: metalLayer)
        // 出力でカーソルが動いたら、重ねた文字も合わせる（重ねる文字が無いときは何もしない）
        if !inlineText.isEmpty { layoutInline() }
        return drawn
    }

    // MARK: タッチ

    /// 点（このビューの左上を原点とする pt）の文字セル。範囲の外は端のセル。ポインタ（RootViewController）のクリックも使う
    func cell(at p: CGPoint) -> GridPoint {
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
        directGestures = [tap, double, two, long, pan, pinch]
        for g in directGestures { addGestureRecognizer(g) }
    }

    // MARK: 縦持ち: シェルはトラックパッド（指で直接触る操作をやめ、ポインタの位置に効かせる）

    /// true なら、シェルの面をトラックパッドにする（縦持ち）。直接触る操作のジェスチャを止め、指の動きを `TrackpadGesture` に渡す。
    /// 切り替えたら、途中の状態は捨てる（ドラッグは取り消しとして終える）
    var trackpadMode = false {
        didSet {
            guard trackpadMode != oldValue else { return }
            for g in directGestures { g.isEnabled = !trackpadMode }
            resetTrackpad()
        }
    }

    /// 途中の状態を捨てる（向きを替えた・トラックパッドでなくなった）
    func resetTrackpad() {
        trackpadTouches.removeAll()
        emitTrackpad(trackpad.reset())
    }

    private func emitTrackpad(_ outputs: [TrackpadGesture.Output]) {
        for o in outputs { delegate?.terminalView(self, trackpad: o) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackpadMode else { return super.touchesBegan(touches, with: event) }
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            trackpadSerial += 1
            trackpadTouches[ObjectIdentifier(t)] = trackpadSerial
            emitTrackpad(trackpad.touchDown(trackpadSerial, at: t.location(in: self), time: t.timestamp))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackpadMode else { return super.touchesMoved(touches, with: event) }
        for t in touches {
            guard let id = trackpadTouches[ObjectIdentifier(t)] else { continue }
            emitTrackpad(trackpad.touchMoved(id, to: t.location(in: self), time: t.timestamp))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackpadMode else { return super.touchesEnded(touches, with: event) }
        // 同時に離れた指は、時刻順に
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let id = trackpadTouches.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            emitTrackpad(trackpad.touchUp(id, at: t.location(in: self), time: t.timestamp))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackpadMode else { return super.touchesCancelled(touches, with: event) }
        for t in touches {
            guard let id = trackpadTouches.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            emitTrackpad(trackpad.touchCancelled(id))
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
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
            accumulator.reset()
            lastPanCell = cell(at: g.location(in: self))
        case .changed:
            let dy = g.translation(in: self).y
            g.setTranslation(.zero, in: self)
            let lines = accumulator.add(dy)
            if lines != 0 { delegate?.terminalView(self, scrollLines: lines, at: lastPanCell) }
        default:
            // 指を離したら止まる。どのモードでも、離した後にスクロールを呼ぶ道は無い
            break
        }
    }

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

    // MARK: 読み・先行表示の重ね（docs/design.md「ローマ字入力」「先行表示」）

    /// 重ねる文字の種類
    enum InlineStyle {
        /// かな漢字変換の読み。端末の前景色の文字・端末の背景色・アクセント色の下線（iOS の変換中の文字と同じ）
        case composing
        /// 先行表示（返事を待たずに出した文字）。本物の文字と同じ見た目（前景色そのまま、下線なし。iOS のキーボードで打った文字と同じ）
        case predicted
    }

    /// 端末の上に重ねる 1 つのラベル（初めて使うときに足す）。タッチは受けない
    private lazy var inlineLabel: UILabel = {
        let l = UILabel()
        l.isUserInteractionEnabled = false
        l.numberOfLines = 1
        l.lineBreakMode = .byClipping
        l.isHidden = true
        self.addSubview(l)
        return l
    }()
    private var inlineText = ""
    private var inlineStyle = InlineStyle.composing
    /// nil なら端末のカーソルのセル。先行表示は先頭の文字のセルを渡す
    private var inlineAnchor: GridPoint?
    /// ラベルを出しているか（隠すときに、まだ作っていないラベルを作らないため）
    private var inlineVisible = false
    private var inlineFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private var inlineAdvances: [Character: CGFloat] = [:]
    private var inlineColors = (text: UIColor.white, background: UIColor.black, accent: UIColor.systemBlue)

    /// 重ねる文字の色（テーマから）
    func setInlineColors(text: UIColor, background: UIColor, accent: UIColor) {
        inlineColors = (text, background, accent)
        restyleInline()
    }

    /// 端末と同じフォントと大きさ。日本語は iOS の代わりの字体に任せる
    private func setInlineFont(family: String, pointSize: CGFloat) {
        let mono = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        if family == "system-mono" {
            inlineFont = mono
        } else {
            let f = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: pointSize)
            inlineFont = f.familyName == family ? f : mono
        }
        inlineAdvances.removeAll()
        restyleInline()
    }

    /// 変換中の読み・先行表示の文字をカーソルの位置に重ねる。空文字で隠す。
    /// at を渡せばそのセルから（先行表示）、無ければ端末のカーソルのセルから。変化が無ければ何もしない
    func setInlineText(_ text: String, style: InlineStyle, at cell: (col: Int, row: Int)? = nil) {
        let anchor = cell.map { GridPoint(row: $0.row, col: $0.col) }
        guard text != inlineText || style != inlineStyle || anchor != inlineAnchor else { return }
        inlineText = text
        inlineStyle = style
        inlineAnchor = anchor
        restyleInline()
    }

    /// 文字・種類・フォント・色のどれかが変わった。ラベルの中身を作り直して置き直す
    private func restyleInline() {
        guard !inlineText.isEmpty, let attributed = makeInlineText() else {
            hideInline()
            return
        }
        // 変更はアニメーションさせない
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inlineLabel.attributedText = attributed
        inlineLabel.backgroundColor = inlineColors.background
        CATransaction.commit()
        layoutInline()
    }

    private func hideInline() {
        guard inlineVisible else { return }
        inlineVisible = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inlineLabel.isHidden = true
        CATransaction.commit()
    }

    /// 重ねる文字を、端末のセルの幅にそろえた属性付き文字列にする（全角は 2 セル、半角は 1 セル。字送りは kern で合わせる）
    private func makeInlineText() -> NSAttributedString? {
        guard let m = metrics else { return nil }
        // 変換中の読みはアクセント色の下線。先行表示は本物の文字と同じ（前景色そのまま、下線なし）
        let composing = inlineStyle == .composing
        let out = NSMutableAttributedString()
        for ch in inlineText {
            let advance = inlineAdvance(of: ch)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: inlineFont,
                .foregroundColor: inlineColors.text,
                .kern: CGFloat(Self.cellCount(of: ch)) * m.widthPt - advance,
            ]
            if composing {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = inlineColors.accent
            }
            out.append(NSAttributedString(string: String(ch), attributes: attrs))
        }
        return out
    }

    private func inlineAdvance(of ch: Character) -> CGFloat {
        if let a = inlineAdvances[ch] { return a }
        let a = (String(ch) as NSString).size(withAttributes: [.font: inlineFont]).width
        inlineAdvances[ch] = a
        return a
    }

    /// 端末のセルを何個使うか（全角は 2、それ以外は 1）
    private static func cellCount(of ch: Character) -> Int {
        guard let v = ch.unicodeScalars.first?.value else { return 1 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// カーソル（または渡されたセル）の位置に置く。右端からはみ出すなら左へずらす。
    /// スクロールバックを見ている間（カーソルのセルが nil）は隠す
    private func layoutInline() {
        guard !inlineText.isEmpty, let m = metrics, let cursor = delegate?.terminalViewCursorCell(self) else {
            hideInline()
            return
        }
        let cell = inlineAnchor.map { (col: $0.col, row: $0.row) } ?? cursor
        let cells = inlineText.reduce(0) { $0 + Self.cellCount(of: $1) }
        let width = CGFloat(cells) * m.widthPt
        var x = CGFloat(cell.col) * m.widthPt
        if x + width > bounds.width { x = max(0, bounds.width - width) }
        let frame = CGRect(x: x, y: CGFloat(cell.row) * m.heightPt, width: width, height: m.heightPt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inlineLabel.frame != frame { inlineLabel.frame = frame }
        inlineLabel.isHidden = false
        CATransaction.commit()
        inlineVisible = true
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
