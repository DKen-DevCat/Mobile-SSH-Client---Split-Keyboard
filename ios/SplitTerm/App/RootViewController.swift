import GameController
import Network
import TermCore
import TermKana
import TermSession
import UIKit
import UniformTypeIdentifiers

/// 画面全体。レイアウトの算出、入力ルータ、タブ、安全（ロック・画面の保護）をまとめる
final class RootViewController: UIViewController {
    let store = ConfigStore()
    private var config: TermConfig { store.config }
    private var theme = Theme(config: TermConfig())
    private var colors = KeyboardColors(config: TermConfig())

    private let terminalView = TerminalView(frame: .zero)
    private let model = KeyboardModel()
    private lazy var leftKeyboard = SplitKeyboardView(face: KeyboardLayouts.jisLeft, model: model, colors: colors)
    private lazy var rightKeyboard = SplitKeyboardView(face: KeyboardLayouts.jisRight, model: model, colors: colors)
    /// 📎（写真・動画・音声・ファイルを送る）。シェルの左下に置く
    private let clipButton = UIButton(type: .system)
    /// キーボード選択（今のキーボードの短い名前を出す丸いボタン）。シェルの右下に置く。分割のときだけ出す
    private let keyboardButton = UIButton(type: .system)
    /// 上の 2 行（シェルの上に前面で重なる）: 1 行目は時計と状態・倍率、2 行目はタブと＋
    private let statusRow = StatusRow()
    private let tabRow = TabRow()
    /// ポインタ（矢印）の層。画面いっぱい・最前面でタッチは受けない
    private let pointerOverlay = PointerOverlayView()
    private let candidateBar = CandidateBar()
    private let notice = UILabel()
    private let emptyLabel = UILabel()

    private var sessions: [TerminalSession] = []
    private var activeIndex = 0
    private var active: TerminalSession? { sessions.indices.contains(activeIndex) ? sessions[activeIndex] : nil }

    private var keyboardKind: KeyboardKind = .english
    /// 🌐 のタップで戻る、前のキーボード
    private var previousKeyboard: KeyboardKind = .romaji
    /// ローマ字入力のまだかなにならない英字（docs/design.md「ローマ字入力」）
    private var romaji = RomajiConverter()
    /// 最後に出した候補と、その読み（空白の変換に使う）
    private var lastCandidates: (reading: String, candidates: [KanaCandidate]) = ("", [])
    private var zoom = ZoomSteps(steps: [85, 100])
    private var composer = KanaComposer()
    /// 先行表示（直接送る文字を、返事を待たずにカーソルの位置へ薄く出す。docs/design.md「先行表示」）
    private var echo = EchoPredictor()
    /// 予測を持っているタブ（予測はタブごとには持たない。替わったら捨てる）
    private weak var echoOwner: TerminalSession?
    /// 最後に描いた画面でカーソルが隠れていたか
    private var echoCursorHidden = false
    private var echoExpiryScheduled = false
    /// かな漢字変換（AzooKey）。裏のキューで変換し、最新の結果だけを候補バーに出す
    private let kana = KanaConversionQueue()
    private var hardwareKeyboard = GCKeyboard.coalesced != nil
    private var layout: LayoutResult?
    private var grid = (cols: 80, rows: 24)

    // 安全（ロックと画面の保護は SecurityGate。ロック中は入力をすべて捨てる）
    private lazy var gate = SecurityGate(colors: colors)
    // メディアを送る（docs/design.md「メディアを送る」）
    private let picker = MediaPicker()
    private let sender = MediaSender()
    /// 起動時の自動接続を、最初にロックを解くまで待たせる
    private var autoConnectPending = true
    private let pathMonitor = NWPathMonitor()
    private var lastInterface: NWInterface.InterfaceType?

    // MARK: 起動

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(terminalView)
        view.addSubview(leftKeyboard)
        view.addSubview(rightKeyboard)
        view.addSubview(candidateBar)
        notice.font = .systemFont(ofSize: 12, weight: .medium)
        notice.textAlignment = .center
        notice.adjustsFontSizeToFitWidth = true
        notice.minimumScaleFactor = 0.7
        notice.isHidden = true
        view.addSubview(notice)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        view.addSubview(emptyLabel)
        // 上の 2 行はシェルとキーボードより前面（レイアウトのたびに前へ出し直す）
        view.addSubview(statusRow)
        view.addSubview(tabRow)

        terminalView.delegate = self
        model.output = self
        model.pointer.output = self
        model.onChange = { [weak self] in
            self?.leftKeyboard.setNeedsDisplay()
            self?.rightKeyboard.setNeedsDisplay()
        }
        tabRow.onSelectTab = { [weak self] i in self?.selectTab(i) }
        tabRow.onCloseTab = { [weak self] i in self?.closeTab(i) }
        tabRow.onNewTab = { [weak self] in self?.newTab() }
        statusRow.onZoom = { [weak self] in self?.changeZoom { $0.cycle() } }
        statusRow.onShowDiagnostics = { [weak self] in self?.showDiagnostics() }
        candidateBar.onPick = { [weak self] candidate in self?.pickCandidate(candidate) }
        setUpMedia()
        setUpKeyboardButton()
        view.addSubview(pointerOverlay)

        gate.scene = { [weak self] in self?.view.window?.windowScene }
        gate.onResume = { [weak self] in self?.resume() }
        gate.onNotice = { [weak self] message in self?.alert("設定を一部効かせていません", message) }
        store.onChange = { [weak self] c, d in self?.apply(config: c, diagnostics: d) }
        apply(config: store.config, diagnostics: store.diagnostics, initial: true)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
        nc.addObserver(self, selector: #selector(willDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didActivate), name: UIScene.didActivateNotification, object: nil)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            // つながっていない間（nil）は前の種類を覚えたままにする（Wi-Fi → 圏外 → 5G も「変わった」と分かるように）。
            // 上の 1 行目の通信の印には、つながっていないことも出す
            let type = path.status == .satisfied ? path.availableInterfaces.first?.type : nil
            DispatchQueue.main.async { [weak self] in
                self?.statusRow.setNetwork(type)
                if let type { self?.pathChanged(type) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "splitterm.path"))

        // 公開鍵を書類フォルダに置く（Mac の scripts/ios_pubkey.sh が取りにくる）。鍵が無ければここで作る
        if let key = try? DeviceKeyStore.loadOrCreate() { store.writePublicKey(key.authorizedKeysLine) }
        // 自動接続は、ロックを解いてから（resume）
    }

    // 状態バーは出す（iPad では出る。Face ID の iPhone の横持ちでは iOS が隠すので、時計・通信・電池は上の 1 行目に出す）
    override var prefersStatusBarHidden: Bool { false }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// キーボードは画面の下端と左右の端に触れるので、システムのジェスチャを後回しにする
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminalView.becomeFirstResponder()
        releaseEdgeTouchDelay()
    }

    /// 画面の端のタッチは、システムのジェスチャ（ホームバーの上スワイプなど）の判定が終わるまで届かず、端のキーが遅れる。
    /// ウィンドウのジェスチャの delaysTouchesBegan を切る（公開の API。ウィンドウに載った後に、毎回かけ直す）
    private func releaseEdgeTouchDelay() {
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    // MARK: 設定

    private func apply(config c: TermConfig, diagnostics: [ConfigDiagnostic], initial: Bool = false) {
        theme = Theme(config: c)
        colors = KeyboardColors(config: c)
        view.backgroundColor = colors.background
        leftKeyboard.colors = colors
        rightKeyboard.colors = colors
        statusRow.apply(colors: colors)
        tabRow.apply(colors: colors)
        applyKeyboardButtonColors()
        clipButton.tintColor = colors.text.withAlphaComponent(0.85)
        candidateBar.apply(colors: colors)
        notice.textColor = colors.subText
        emptyLabel.textColor = colors.subText
        for kb in [leftKeyboard, rightKeyboard] {
            kb.repeatDelay = c.keyRepeatDelay
            kb.repeatInterval = c.keyRepeatInterval
            kb.haptics = c.haptics
        }
        terminalView.keyRepeatDelay = c.keyRepeatDelay
        terminalView.keyRepeatInterval = c.keyRepeatInterval
        terminalView.cursorBlink = c.cursorBlink
        terminalView.setColorSpace(c.colorSpace)
        terminalView.setInlineColors(text: colors.text, background: colors.background, accent: colors.accent)
        gate.colors = colors
        gate.request(appLock: c.appLock, privacyBlur: c.privacyBlur, stripLocation: c.mediaStripLocation,
                     lockAfter: c.appLockAfter)
        if initial || zoom.steps != c.zoomSteps {
            zoom = ZoomSteps(steps: c.zoomSteps, current: initial ? nil : zoom.percent)
        }
        if initial {
            keyboardKind = c.keyboard
            previousKeyboard = c.keyboard == .english ? .romaji : .english
        }
        for s in sessions { s.config = c }
        tabRow.plus.menu = makeMenu()
        updateEnvBar()
        configureFont()
        view.setNeedsLayout()
        terminalView.requestRender()
        if !diagnostics.isEmpty && !initial { showDiagnostics() }
    }

    private func configureFont() {
        let pt = CGFloat(config.fontSize) * CGFloat(zoom.percent) / 100
        terminalView.configureFont(family: config.fontFamily, cjkFamily: config.fontFamilyCJK, pointSize: pt)
        view.setNeedsLayout()
    }

    // MARK: レイアウト（画面サイズ・向き・セーフエリア・入力手段から毎回算出する）

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = view.safeAreaInsets
        let input = LayoutInput(size: view.bounds.size,
                                safeArea: Insets(top: s.top, left: s.left, bottom: s.bottom, right: s.right),
                                hardwareKeyboard: hardwareKeyboard, keyboard: keyboardKind,
                                pitchOverride: config.keyboardPitch,
                                softKeyboardWithHardware: config.softKeyboardWithHardware)
        let r = LayoutEngine.compute(input)
        layout = r
        terminalView.frame = r.shell
        statusRow.frame = r.statusRow
        tabRow.frame = r.tabRow
        let faces = KeyboardLayouts.faces(for: keyboardKind)
        for (kb, frame, face) in [(leftKeyboard, r.leftKeyboard, faces.left), (rightKeyboard, r.rightKeyboard, faces.right)] {
            kb.isHidden = frame == nil
            if let frame {
                kb.frame = frame
                kb.rowHeight = r.rowHeight
                if kb.face.rows != face.rows { kb.face = face }
            }
        }
        candidateBar.isHidden = r.candidateBar == nil
        if let c = r.candidateBar { candidateBar.frame = c }
        notice.isHidden = r.mode != .tooNarrow
        notice.text = "窓が狭いので画面のキーボードを隠しています"
        // シェルの下端の上。左下の 📎・右下の ⌨ を避けて、間に置く
        let side = LayoutEngine.cornerButtonMargin + LayoutEngine.cornerButtonSize + 4
        notice.frame = CGRect(x: r.shell.minX + side, y: r.shell.maxY - 22,
                              width: max(0, r.shell.width - 2 * side), height: 16)
        emptyLabel.frame = r.shell.insetBy(dx: 16, dy: 16)
        // 角の丸いボタン: 左下が 📎、右下がキーボード選択（分割のときだけ）
        let inset = LayoutEngine.cornerButtonMargin, size = LayoutEngine.cornerButtonSize
        clipButton.frame = CGRect(x: r.shell.minX + inset, y: r.shell.maxY - inset - size, width: size, height: size)
        keyboardButton.isHidden = r.keyboardButton == nil
        if let b = r.keyboardButton { keyboardButton.frame = b }
        pointerOverlay.frame = view.bounds
        // 上の 2 行・📎・キーボード選択はシェルとキーボードより前面、ポインタはその上
        for v in [statusRow, tabRow, clipButton, keyboardButton, pointerOverlay] as [UIView] {
            view.bringSubviewToFront(v)
        }
        updateEnvBar()
        regrid()
        releaseEdgeTouchDelay()
    }

    /// シェルの大きさから桁数と行数を出し、端末と接続先へ知らせる（SSH の window-change）
    private func regrid() {
        guard let m = terminalView.metrics, terminalView.bounds.width > 0 else { return }
        let g = m.grid(for: terminalView.bounds.size)
        grid = g
        for s in sessions {
            s.resize(cols: g.cols, rows: g.rows, pixelWidth: g.cols * m.widthPx, pixelHeight: g.rows * m.heightPx)
        }
        terminalView.requestRender()
    }

    // MARK: タブ

    private func openSession(_ host: HostEntry) {
        // 同じ接続先で開いているタブが使っていない、いちばん小さい番号（tmux のセッションが main・main-2…と分かれる）。
        // ⌘T も＋もここを通る
        let slot = TabSlots.next(used: sessions.filter { $0.host.name == host.name }.map { $0.slot })
        let s = TerminalSession(host: host, config: config, cols: grid.cols, rows: grid.rows, slot: slot)
        s.presenter = self
        let tv = terminalView
        s.onDisplayNeeded = { [weak tv] in tv?.requestRender() }
        s.onStateChange = { [weak self] in self?.updateEnvBar() }
        sessions.append(s)
        activeIndex = sessions.count - 1
        regrid()
        s.connect()
        updateEnvBar()
    }

    private func selectTab(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        if i == activeIndex, let s = active {
            // 切れているタブをもう一度タップしたら繋ぎ直す
            switch s.state {
            case .failed, .disconnected, .idle: s.connect()
            default: break
            }
        }
        activeIndex = i
        updateEnvBar()
        terminalView.requestRender()
    }

    private func closeTab(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        // 接続を閉じるだけで、tmux は残す。次に開いたタブが同じ番号なら、そのセッションに戻る
        // （止まるのは、シェルでプロセスを終わらせたとき）
        sessions[i].close()
        sessions.remove(at: i)
        activeIndex = min(activeIndex, max(0, sessions.count - 1))
        updateEnvBar()
        terminalView.requestRender()
    }

    /// ＋のタップ: 新しいタブを開く。接続先は 今のタブの host、無ければ auto-connect の host、無ければ最初の host。
    /// どれも無ければ設定を編集する（番号に応じた tmux のセッションは openSession が決める）
    private func newTab() {
        if let host = active?.host ?? config.autoConnectHost ?? config.hosts.first {
            openSession(host)
        } else {
            editConfig()
        }
    }

    /// 上の 2 行（時計と状態・倍率、タブ）とキーボード選択を、今の状態に合わせる（名前は「環境バー」の頃のまま）
    private func updateEnvBar() {
        let tabs = sessions.enumerated().map { i, s in
            TabRow.Tab(title: s.title, state: s.state, selected: i == activeIndex)
        }
        tabRow.update(tabs: tabs)
        statusRow.update(zoomPercent: zoom.percent, diagnostics: store.diagnostics.count)
        keyboardButton.setTitle(keyboardKind.shortTitle, for: .normal)
        keyboardButton.isHidden = layout?.keyboardButton == nil
        emptyLabel.isHidden = !sessions.isEmpty
        emptyLabel.text = config.hosts.isEmpty
            ? "接続先がありません。\n＋ を長押し →「設定を編集」で host を書いてください。\n例: host = mac you@your-mac.tailnet.ts.net"
            : "＋ をタップで接続します（長押しで接続先を選べます）"
        if let s = active, case .failed(let reason) = s.state {
            notice.isHidden = false
            notice.text = reason
        }
    }

    private func makeMenu() -> UIMenu {
        let hosts = config.hosts.map { h in
            UIAction(title: h.name, subtitle: "\(h.user)@\(h.address)", image: UIImage(systemName: "terminal")) { [weak self] _ in
                self?.openSession(h)
            }
        }
        var tools: [UIMenuElement] = [
            UIAction(title: "公開鍵をコピー", image: UIImage(systemName: "key")) { [weak self] _ in self?.copyPublicKey() },
            UIAction(title: "設定を編集", image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.editConfig() },
            UIAction(title: "設定を読み直す", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.store.reload(force: true)
            },
        ]
        tools.append(UIAction(title: "このタブのホスト鍵を忘れる", image: UIImage(systemName: "xmark.shield"),
                              attributes: .destructive) { [weak self] _ in
            guard let s = self?.active else { return }
            HostKeyStore.forget(s.host.endpointID)
        })
        return UIMenu(children: [
            UIMenu(title: "接続", options: .displayInline, children: hosts),
            UIMenu(options: .displayInline, children: tools),
        ])
    }

    // MARK: 倍率・キーボード

    private func changeZoom(_ f: (inout ZoomSteps) -> Void) {
        let before = zoom.percent
        f(&zoom)
        guard zoom.percent != before else { return }
        configureFont()
        updateEnvBar()
    }

    /// 🌐 のタップ: 前のキーボードへ
    private func switchKeyboard() {
        setKeyboard(previousKeyboard)
    }

    private func setKeyboard(_ kind: KeyboardKind) {
        guard kind != keyboardKind else { return }
        if composer.isComposing || !romaji.isEmpty { commitComposition(nil) }
        previousKeyboard = keyboardKind
        keyboardKind = kind
        model.reset()
        view.setNeedsLayout()
        updateEnvBar()
    }

    /// キーボードを選ぶメニューの中身（シェルの右下のボタン・🌐 の長押しの吹き出し）
    private func keyboardMenuElements() -> [UIMenuElement] {
        KeyboardKind.menuOrder.map { kind in
            UIAction(title: kind.title, state: kind == keyboardKind ? .on : .off) { [weak self] _ in self?.setKeyboard(kind) }
        }
    }

    /// キーボード選択のボタン（シェルの右下の角の丸いボタン）。📎 と同じ作りで、タップでメニューを出す
    private func setUpKeyboardButton() {
        if let label = keyboardButton.titleLabel {
            // 「abcローマ字」のような長い名前は、丸の中に収まるよう縮める
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.lineBreakMode = .byClip
        }
        keyboardButton.layer.cornerRadius = LayoutEngine.cornerButtonSize / 2
        keyboardButton.showsMenuAsPrimaryAction = true
        keyboardButton.accessibilityLabel = "キーボードを選ぶ"
        keyboardButton.menu = UIMenu(title: "キーボード", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.keyboardMenuElements() ?? [])
        }])
        keyboardButton.isHidden = true
        view.addSubview(keyboardButton)
        applyKeyboardButtonColors()
    }

    /// 📎 と同じ見た目: 地は文字色の丸（少し透ける）、字は背景色
    private func applyKeyboardButtonColors() {
        keyboardButton.backgroundColor = colors.text.withAlphaComponent(0.85)
        keyboardButton.setTitleColor(colors.background, for: .normal)
    }

    /// 🌐 の長押し: iOS の吹き出し（ポップオーバー）でキーボードを選ぶ
    private func presentKeyboardMenu(anchor: CGRect) {
        guard !gate.isLocked, presentedViewController == nil else { return }
        let vc = KeyboardMenuController(current: keyboardKind) { [weak self] kind in self?.setKeyboard(kind) }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = view.convert(anchor, from: nil)
            pop.permittedArrowDirections = [.down, .up, .left, .right]
            pop.delegate = self
        }
        present(vc, animated: true)
    }

    @objc private func hardwareKeyboardChanged() {
        hardwareKeyboard = GCKeyboard.coalesced != nil
        view.setNeedsLayout()
    }

    // MARK: 入力ルータ（docs/design.md「入力設計」）

    private var encodingContext: EncodingContext { encodingContext(for: active) }

    private func encodingContext(for session: TerminalSession?) -> EncodingContext {
        let m = session?.engine.modes() ?? TerminalModes()
        return EncodingContext(applicationCursor: m.applicationCursor, bracketedPaste: m.bracketedPaste,
                               optionAsMeta: config.optionAsMeta, newline: config.newline)
    }

    /// キーを接続先へ。command はアプリ内の操作に使う
    private func route(_ key: TermKey, _ mods: KeyModifiers) {
        guard !gate.isLocked else { return }
        // 文字を打ったらポインタを隠す（Mac と同じ）
        hidePointer()
        if mods.contains(.command) {
            handleCommand(key)
            return
        }
        if composer.isComposing || !romaji.isEmpty {
            switch key {
            case .enter, .newline:
                // 変換中の ⏎ は確定だけで、接続先には何も送らない
                commitComposition(nil)
                return
            case .backspace:
                // まだかなにならない英字から消す
                if !romaji.deleteBackward() { _ = composer.deleteBackward() }
                updateCandidates()
                return
            default:
                commitComposition(nil)
            }
        }
        guard let s = active else { return }
        // 先行表示は、スクロールバックや選択を戻す前の状態で見る（戻すと画面が飛ぶので、その 1 打は予測しない）
        let echoState = echoContext(s)
        // スクロールバック中にキーを押したら、最下部（入力位置）へ戻る
        if s.scrollTop != nil || s.selection != nil {
            s.scrollTop = nil
            s.selection = nil
            terminalView.stopInertia()
            terminalView.requestRender()
        }
        noteEcho(key, mods, session: s, context: echoState)
        s.send(KeyEncoder.encode(key, mods, encodingContext))
    }

    // MARK: 読み・先行表示（カーソルの位置に重ねる。docs/design.md「ローマ字入力」「先行表示」）

    /// 予測してはいけない場面（vim などの代替画面、マウス報告、カーソルが隠れている、スクロールバック・選択・変換中）
    private func echoContext(_ s: TerminalSession) -> EchoPredictor.Context {
        let m = s.engine.modes()
        return EchoPredictor.Context(alternateScreen: m.alternateScreen, mouseReporting: m.mouseReporting,
                                     cursorHidden: echoCursorHidden, scrolledBack: s.scrollTop != nil,
                                     composing: composer.isComposing || !romaji.isEmpty, selecting: s.selection != nil)
    }

    /// 送ったキーを予測に知らせる。修飾なしの文字は、返事を待たずにカーソルの位置へ薄く出す
    private func noteEcho(_ key: TermKey, _ mods: KeyModifiers, session s: TerminalSession,
                          context: EchoPredictor.Context) {
        resetEchoIfSessionChanged(s)
        if !mods.isDisjoint(with: [.control, .option]) {
            echo.key(.modified)
        } else {
            switch key {
            case .text(let t):
                echo.typed(t, cursor: s.engine.cursorPosition(), now: CACurrentMediaTime(), context: context)
            case .enter, .newline: echo.key(.enter)
            case .escape: echo.key(.escape)
            case .tab: echo.key(.tab)
            case .backspace, .delete: echo.key(.backspace)
            case .up, .down, .left, .right, .home, .end, .pageUp, .pageDown: echo.key(.arrow)
            case .function: echo.key(.modified)
            }
        }
        refreshInline()
    }

    /// 貼り付け・メディアのパスの挿入。返ってくる画面は予測できない
    private func noteEchoPaste() {
        echo.key(.paste)
        refreshInline()
    }

    /// タブが替わったら予測を捨てる（予測はタブごとには持たない）
    private func resetEchoIfSessionChanged(_ s: TerminalSession?) {
        guard s !== echoOwner else { return }
        echoOwner = s
        echo.reset()
        refreshInline()
    }

    /// 変換中の読み（無ければ先行表示の文字）をカーソルの位置に重ねる。
    /// キーを確定した瞬間に同期で呼ぶ（変換の結果は待たない）。重ねる文字が無ければ隠す
    private func refreshInline() {
        let reading = composer.reading + romaji.pending
        if !reading.isEmpty {
            terminalView.setInlineText(reading, style: .composing)
        } else if let d = echo.display {
            // 行の終わりを越える分は出さない（折り返しは返事で決まる）
            let text = String(d.text.prefix(max(0, grid.cols - d.at.col)))
            terminalView.setInlineText(text, style: .predicted, at: d.at)
            if echo.hasPending { scheduleEchoExpiry() }
        } else {
            terminalView.setInlineText("", style: .predicted)
            if echo.hasPending { scheduleEchoExpiry() }
        }
    }

    /// 返事が来なくても（接続が切れた・遅い）、予測は 1 秒で消える。描画のついでに突き合わせるので、描画を頼む
    private func scheduleEchoExpiry() {
        guard !echoExpiryScheduled else { return }
        echoExpiryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + EchoPredictor.timeout + 0.05) { [weak self] in
            guard let self else { return }
            self.echoExpiryScheduled = false
            guard self.echo.hasPending else { return }
            self.terminalView.requestRender()
            self.scheduleEchoExpiry()
        }
    }

    /// 描いた画面を予測と突き合わせる（返ってきた文字は本物に置き換わり、外れたら予測を消す）
    private func reconcileEcho(_ frame: ScreenFrame, session s: TerminalSession) {
        resetEchoIfSessionChanged(s)
        echoCursorHidden = frame.cursor == nil
        guard echo.hasPending else { return }
        if let c = frame.cursor, frame.atBottom {
            echo.reconcile(cellText: { col, row in
                guard col >= 0, col < frame.cols, row >= 0, row < frame.rows else { return nil }
                return frame.cell(col: col, row: row).text
            }, cursor: (col: c.col, row: c.row), now: CACurrentMediaTime())
        } else {
            echo.reset()
        }
        refreshInline()
    }

    /// ⌘ の操作（Mac のターミナルと同じ。接続先には送らない）
    private func handleCommand(_ key: TermKey) {
        guard case .text(let t) = key else { return }
        switch t.lowercased() {
        case "c": copySelection()
        case "v": pasteClipboard()
        case "-": changeZoom { $0.zoom(in: false) }
        case "=", "+": changeZoom { $0.zoom(in: true) }
        case "t":
            // 新しいタブ（今のタブと同じ接続先）
            if let host = active?.host { openSession(host) }
        case "w":
            if sessions.indices.contains(activeIndex) { closeTab(activeIndex) }
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            // ⌘1〜⌘8 はその番号のタブ、⌘9 は最後のタブ
            guard let n = Int(t), !sessions.isEmpty else { return }
            selectTab(n == 9 ? sessions.count - 1 : n - 1)
        default: break
        }
    }

    private func commitComposition(_ text: String?) {
        // まだかなにならない英字も入れてから（n は「ん」）
        let rest = romaji.flush()
        if !rest.isEmpty { composer.append(rest) }
        let out = composer.commit(text)
        kana.reset()
        updateCandidates()
        sendCommitted(out)
    }

    /// 候補を選んだ。文節の候補なら、残りの読みは変換中のまま候補を出し直す
    private func pickCandidate(_ candidate: KanaCandidate) {
        let out = composer.commit(candidate)
        if !composer.isComposing { kana.reset() }
        updateCandidates()
        sendCommitted(out)
    }

    private func sendCommitted(_ text: String) {
        guard !text.isEmpty else { return }
        // 確定した文字は変換の結果。先行表示の予測（ASCII の直接入力）とは別なので、予測は捨てる
        noteEchoPaste()
        active?.send(KeyEncoder.encode(.text(text), [], encodingContext))
    }

    private func updateCandidates() {
        let reading = composer.reading
        let pending = romaji.pending
        // 読みはキーを確定した瞬間に、カーソルの位置へ出す（候補の変換は待たない。候補バーの更新は裏の結果で）
        refreshInline()
        kana.request(reading) { [weak self] candidates in
            self?.lastCandidates = (reading, candidates)
            self?.candidateBar.update(candidates: candidates, pending: pending)
        }
    }

    /// ローマ字の空白: いちばん上の候補で確定する（候補がまだ無ければ読みのまま）
    private func convertComposition() {
        let rest = romaji.flush()
        if !rest.isEmpty { composer.append(rest) }
        if lastCandidates.reading == composer.reading, let top = lastCandidates.candidates.first {
            pickCandidate(top)
        } else {
            commitComposition(nil)
        }
    }

    // MARK: 選択・コピー・ペースト

    private func copySelection() {
        guard let s = active, let sel = s.selection else { return }
        let (a, b) = sel.ordered
        let text = s.engine.text(from: (a.row, a.col), to: (b.row, b.col))
        guard !text.isEmpty else { return }
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        // アプリからコピーした内容は既定 60 秒で消す（docs/design.md「セキュリティ要件」）
        if config.clipboardClear > 0 { options[.expirationDate] = Date().addingTimeInterval(config.clipboardClear) }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
        s.selection = nil
        terminalView.requestRender()
    }

    private func pasteClipboard() {
        guard !gate.isLocked, active != nil, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if composer.isComposing { commitComposition(nil) }
        let ctx = encodingContext
        guard KeyEncoder.pasteRunsCommands(text, ctx) else {
            sendPaste(text, ctx)
            return
        }
        // 括弧付きペーストが無効な所（素の sh など）に複数行を貼ると、行ごとに実行される。確かめてから送る
        let lines = text.split(whereSeparator: \.isNewline).count
        let a = UIAlertController(title: "\(lines) 行を貼り付けます",
                                  message: "この画面では、改行のたびにコマンドとして実行されます。",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "やめる", style: .cancel))
        a.addAction(UIAlertAction(title: "貼り付ける", style: .destructive) { [weak self] _ in self?.sendPaste(text, ctx) })
        topPresenter.present(a, animated: true)
    }

    private func sendPaste(_ text: String, _ ctx: EncodingContext) {
        guard let s = active else { return }
        s.scrollTop = nil
        noteEchoPaste()
        s.send(KeyEncoder.paste(text, ctx))
    }

    // MARK: メディアを送る

    private func setUpMedia() {
        picker.presenter = self
        picker.onPicked = { [weak self] items in self?.sendMedia(items) }
        picker.onError = { [weak self] message in self?.alert("メディア", message) }
        sender.onStatus = { [weak self] text in self?.statusRow.setProgress(text) }
        sender.onError = { [weak self] message in self?.alert("メディアを送れませんでした", message) }
        sender.onInsert = { [weak self] text, session in self?.insertMediaPaths(text, into: session) }
        // 開くたびに作る（送っている途中なら「やめる」を出す）
        // 📎 はシェルの左下
        clipButton.setImage(UIImage(systemName: "paperclip.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)), for: .normal)
        clipButton.showsMenuAsPrimaryAction = true
        clipButton.accessibilityLabel = "メディアを送る"
        view.addSubview(clipButton)
        clipButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.mediaMenu() ?? [])
        }])
    }

    private func mediaMenu() -> [UIMenuElement] {
        if sender.busy {
            return [UIAction(title: "送るのをやめる", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) {
                [weak self] _ in self?.sender.cancel()
            }]
        }
        return [
            UIAction(title: "写真・動画を選ぶ", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.startPicking { $0.pickLibrary() }
            },
            UIAction(title: "撮る", image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.startPicking { $0.capture() }
            },
            UIAction(title: "録音する", image: UIImage(systemName: "mic")) { [weak self] _ in
                self?.startPicking { $0.record() }
            },
            UIAction(title: "ファイルを選ぶ", image: UIImage(systemName: "doc")) { [weak self] _ in
                self?.startPicking { $0.pickFile() }
            },
        ]
    }

    /// 繋がっているタブがあるときだけ選ばせる（選んだのに送れない、を避ける）
    private func startPicking(_ open: (MediaPicker) -> Void) {
        guard !gate.isLocked else { return }
        guard let s = active, s.isConnected else {
            alert("メディア", "繋がっているタブがありません。接続してから送ってください")
            return
        }
        guard !sender.busy else {
            alert("メディア", "前のメディアを送っている途中です")
            return
        }
        open(picker)
    }

    private func sendMedia(_ items: [PickedMedia]) {
        guard let s = active else { return }
        // 位置情報を外すかは、本人が確かめた値（config の値ではなく。SecurityGate）
        var c = config
        c.mediaStripLocation = gate.stripLocation
        sender.send(items, config: c, session: s)
    }

    /// ロック中に送り終わったパス（ロックを解いたら入れる）
    private var pendingMediaInsert: (text: String, session: TerminalSession)?

    /// 送ったファイルのパスを、送った元のタブの入力行に入れる（Enter は押さない。貼り付けと同じく制御文字は除く）
    private func insertMediaPaths(_ text: String, into session: TerminalSession) {
        guard sessions.contains(where: { $0 === session }) else { return }  // タブを閉じた
        guard !gate.isLocked else {
            pendingMediaInsert = (text, session)
            return
        }
        // 改行は入れない（config の media-insert に何が書かれていても、コマンドを実行しない）
        let line = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        if session === active, composer.isComposing { commitComposition(nil) }
        session.scrollTop = nil
        noteEchoPaste()
        session.send(KeyEncoder.paste(line, encodingContext(for: session)))
    }

    private func flushPendingMediaInsert() {
        guard let p = pendingMediaInsert else { return }
        pendingMediaInsert = nil
        insertMediaPaths(p.text, into: p.session)
    }

    private func copyPublicKey() {
        do {
            let key = try DeviceKeyStore.loadOrCreate()
            let line = key.authorizedKeysLine
            store.writePublicKey(line)
            UIPasteboard.general.string = line
            let where_ = key.isHardwareBacked ? "Secure Enclave の鍵です（端末から取り出せません）。" : "ソフトウェアの鍵です（シミュレータ）。"
            alert("公開鍵をコピーしました", "\(where_)\n指紋: \(key.fingerprint)\n\n接続先の ~/.ssh/authorized_keys に足してください。Mac からは scripts/ios_pubkey.sh で登録できます（この指紋と同じか確かめてから）。\n\n\(line)")
        } catch {
            alert("鍵を作れませんでした", error.localizedDescription)
        }
    }

    private func editConfig() {
        let editor = ConfigEditorViewController(store: store)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        topPresenter.present(nav, animated: true)
    }

    private func showDiagnostics() {
        let list = store.diagnostics.map(\.description).joined(separator: "\n")
        alert("設定に読めない行があります", "読めない行は飛ばして、ほかの行を使っています。\n\n\(list)")
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        topPresenter.present(a, animated: true)
    }

    /// いちばん上に出ている画面（その上に重ねて出す。下の画面から出すと黙って失敗する）
    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: 安全（ロック・画面の保護）と、前面・裏の切り替え

    @objc private func willDeactivate() {
        gate.willDeactivate()
    }

    /// 裏に回ってもしばらく繋いでおくための、iOS のバックグラウンドの猶予（約 30 秒）。全タブで 1 つ
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @objc private func didEnterBackground() {
        gate.didEnterBackground()
        for s in sessions { s.resignedActive() }
        keepConnectionsForAWhile()
    }

    /// 裏に回ったら、繋がっている（繋いでいる途中を含む）タブが 1 つでもあるとき猶予を 1 つ取る。期限が来たら自分で閉じ、
    /// 期限の前に前面へ戻れば、接続はそのまま続く（docs/design.md「接続の安定性」）
    private func keepConnectionsForAWhile() {
        guard backgroundTask == .invalid, sessions.contains(where: { $0.isLive }) else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "keep-ssh") { [weak self] in
            self?.backgroundTimeExpired()
        }
        // 猶予をもらえなかった。止められる前に、自分で閉じる
        if backgroundTask == .invalid { suspendAllForBackground() }
    }

    /// 猶予の期限（メインで呼ばれる）。iOS に止められる前に、全タブの接続を閉じてから猶予を返す。
    /// 返さないと、アプリごと終了させられる
    private func backgroundTimeExpired() {
        suspendAllForBackground()
        endBackgroundTask()
    }

    private func suspendAllForBackground() {
        for s in sessions { s.suspendForBackground() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 前面に戻り始めた。期限の前なら、接続はそのまま続ける（猶予を返すだけ）
    @objc private func willEnterForeground() {
        endBackgroundTask()
    }

    @objc private func didActivate() {
        gate.didActivate()
    }

    /// ロックを解いた、またはロックの無いまま前面に戻った
    private func resume() {
        endBackgroundTask()
        store.reload()
        if autoConnectPending {
            autoConnectPending = false
            if let host = config.autoConnectHost { openSession(host) }
        }
        for s in sessions { s.becameActive() }
        flushPendingMediaInsert()
        terminalView.becomeFirstResponder()
        terminalView.requestRender()
    }

    private func pathChanged(_ type: NWInterface.InterfaceType) {
        defer { lastInterface = type }
        guard let last = lastInterface, type != last else { return }
        for s in sessions { s.networkChanged() }
    }
}

// MARK: - キーボード → 入力ルータ

extension RootViewController: KeyboardOutput {
    func keyboard(_ emit: KeyboardEmit) {
        guard !gate.isLocked else { return }
        switch emit {
        case .key(let k, let mods):
            // ローマ字: 英字と句読点（、。ー「」）はかなにして読みに足す
            if keyboardKind.usesRomaji, mods.subtracting(.shift).isEmpty, case .text(let t) = k, t.count == 1,
               let c = t.first, let kana = romaji.input(c) {
                hidePointer()
                if !kana.isEmpty { composer.append(kana) }
                updateCandidates()
                return
            }
            if keyboardKind.isJapanese, composer.isComposing || !romaji.isEmpty, case .text(" ") = k, mods.isEmpty {
                if keyboardKind.usesRomaji {
                    // 空白は変換（いちばん上の候補で確定）
                    convertComposition()
                    return
                }
                // かな: 読みのまま確定してから空白を送る
                commitComposition(nil)
            }
            route(k, mods)
        case .flick(let id, let set, let d, let upper):
            let c = set.character(d)
            switch keyboardKind {
            case .flickEnglish:
                route(.text(upper ? c.uppercased() : c), [])
            case .flickRomaji:
                if c.count == 1, let first = c.first, let kana = romaji.input(first) {
                    if !kana.isEmpty { composer.append(kana) }
                    updateCandidates()
                } else {
                    route(.text(c), [])
                }
            default:
                composer.input(keyID: id, set: set, direction: d, now: CACurrentMediaTime())
                updateCandidates()
            }
        case .kanaBreak:
            composer.breakToggle()
        case .kanaModify:
            composer.modifyLast()
            updateCandidates()
        case .switchKeyboard:
            switchKeyboard()
        case .setKeyboard(let kind):
            setKeyboard(kind)
        case .keyboardMenu(let anchor):
            presentKeyboardMenu(anchor: anchor)
        case .lockApp:
            gate.lockNow()
        }
    }
}

// MARK: - スペースの横の赤い丸 → ポインタ（docs/design.md「ポインタ」。シェルと上の 2 行を動き、クリックできる）

extension RootViewController: PointerOutput {
    /// ポインタが動ける範囲: シェルの枠と、上の 2 行（左右いっぱい）の和
    private var pointerRects: [CGRect] { [terminalView.frame, statusRow.frame.union(tabRow.frame)] }

    /// ポインタの今の位置。まだ動かしていなければシェルの中央
    private var pointerHome: CGPoint {
        pointerOverlay.location ?? CGPoint(x: terminalView.frame.midX, y: terminalView.frame.midY)
    }

    func pointerMove(dx: CGFloat, dy: CGFloat) {
        guard !gate.isLocked else { return }
        let from = pointerHome
        // 範囲の外へ出る動きは、範囲の中で最も近い点に寄せる
        pointerOverlay.show(at: PointerArea.clamp(CGPoint(x: from.x + dx, y: from.y + dy), toUnionOf: pointerRects))
    }

    /// 文字を打ったらポインタを隠す（Mac と同じ。位置は覚えておく）
    func hidePointer() {
        pointerOverlay.hide()
    }

    func pointerClick(right: Bool) {
        guard !gate.isLocked, presentedViewController == nil else { return }
        let p = PointerArea.clamp(pointerHome, toUnionOf: pointerRects)
        pointerOverlay.show(at: p)
        // 上の 2 行の上: その下のボタン（タブ・＋・倍率・⚠）を押す。右クリックは何もしない
        if statusRow.frame.union(tabRow.frame).contains(p), let button = buttonUnderPointer(at: p) {
            if !right { button.sendActions(for: .touchUpInside) }
            return
        }
        // キーボード選択のボタンの上: 吹き出しでキーボードを選ぶ。📎 の上は何もしない
        if !keyboardButton.isHidden, keyboardButton.frame.contains(p) {
            presentKeyboardMenu(anchor: keyboardButton.convert(keyboardButton.bounds, to: nil))
            return
        }
        if clipButton.frame.contains(p) { return }
        // シェルの上: シェルの座標に直して、タップ（左）・2 本指のタップ（右）と同じ扱い
        // （マウス報告・入力行のカーソル移動・編集メニュー）
        guard terminalView.frame.contains(p) else { return }
        let local = view.convert(p, to: terminalView)
        let cell = terminalView.cell(at: local)
        // terminalView プロパティと名前が同じなので、デリゲートとして呼ぶ
        let delegate: TerminalViewDelegate = self
        if right {
            delegate.terminalView(terminalView, twoFingerTappedAt: cell, location: local)
        } else {
            delegate.terminalView(terminalView, tappedAt: cell, location: local)
        }
    }

    /// 点の下のビューから上へたどって見つけたボタン（UIControl）
    private func buttonUnderPointer(at p: CGPoint) -> UIControl? {
        var v = view.hitTest(p, with: nil)
        while let x = v, x !== view {
            if let c = x as? UIControl, c.isEnabled { return c }
            v = x.superview
        }
        return nil
    }
}

// MARK: - シェルのタッチ（docs/design.md「メインシェルのタッチ操作」）

extension RootViewController: TerminalViewDelegate {
    func terminalViewFrame(_ view: TerminalView) -> (frame: ScreenFrame, theme: Theme, selection: TextSelection?)? {
        guard let s = active else {
            // タブが無い。出していた予測は捨てる
            if echo.hasPending || echo.confirmed { echo.reset(); refreshInline() }
            return nil
        }
        let frame = s.engine.readScreen(theme: theme, scrollTop: s.scrollTop, cursorShape: config.cursorStyle)
        // 最下部に追いついたら、追従に戻す
        if s.scrollTop != nil && frame.atBottom { s.scrollTop = nil }
        // 描く画面を、先行表示の予測と突き合わせる（本物が出たら予測は消える）
        reconcileEcho(frame, session: s)
        return (frame, theme, s.selection)
    }

    func terminalViewCursorCell(_ view: TerminalView) -> (col: Int, row: Int)? {
        // スクロールバックを見ている間は重ねない。カーソルが隠れていても、端末の持つ位置に出す
        guard let s = active, s.scrollTop == nil else { return nil }
        return s.engine.cursorPosition()
    }

    private var gestureMode: GestureMode {
        let m = active?.engine.modes() ?? TerminalModes()
        return GestureMode.decide(mouseReporting: m.mouseReporting, alternateScreen: m.alternateScreen,
                                  allowMouse: config.mouseReporting)
    }

    private func absolute(_ cell: GridPoint) -> GridPoint {
        let top = active?.scrollTop ?? active?.engine.scrollBounds().bottomTop ?? 0
        return GridPoint(row: top + cell.row, col: cell.col)
    }

    func terminalView(_ view: TerminalView, tappedAt cell: GridPoint, location: CGPoint) {
        guard !gate.isLocked, let s = active else { return }
        if s.selection != nil {
            s.selection = nil
            view.requestRender()
            return
        }
        switch gestureMode {
        case .mouse:
            s.send(MouseEncoder.click(.left, col: cell.col, row: cell.row))
        case .normal:
            // 入力行（カーソルのある行）のタップは、その位置へカーソルを動かす
            guard s.scrollTop == nil else { return }
            let line = s.engine.cursorLine()
            guard line.row == cell.row else { return }
            s.send(KeyEncoder.horizontalMove(from: line.col, to: cell.col, widths: line.widths, encodingContext))
        case .alternateScroll:
            break
        }
    }

    func terminalView(_ view: TerminalView, doubleTappedAt cell: GridPoint) {
        guard !gate.isLocked, let s = active else { return }
        if gestureMode == .mouse {
            // 1 回目はタップで送っているので、もう 1 回でダブルクリックになる
            s.send(MouseEncoder.click(.left, col: cell.col, row: cell.row))
            return
        }
        let abs = absolute(cell)
        guard let w = s.engine.wordRange(row: abs.row, col: abs.col) else { return }
        s.selection = TextSelection(anchor: GridPoint(row: abs.row, col: w.start), head: GridPoint(row: abs.row, col: w.end))
        view.requestRender()
        if let m = view.metrics {
            view.showEditMenu(at: CGPoint(x: CGFloat(cell.col) * m.widthPt, y: CGFloat(cell.row) * m.heightPt))
        }
    }

    func terminalView(_ view: TerminalView, twoFingerTappedAt cell: GridPoint, location: CGPoint) {
        guard !gate.isLocked, let s = active else { return }
        if gestureMode == .mouse {
            s.send(MouseEncoder.click(.right, col: cell.col, row: cell.row))
        } else {
            view.showEditMenu(at: location)
        }
    }

    func terminalView(_ view: TerminalView, scrollLines lines: Int, at cell: GridPoint) {
        guard !gate.isLocked, let s = active else { return }
        switch gestureMode {
        case .mouse:
            let b: MouseEncoder.Button = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(lines) { s.send(MouseEncoder.press(b, col: cell.col, row: cell.row)) }
        case .alternateScroll:
            let key: TermKey = lines > 0 ? .up : .down
            let one = KeyEncoder.encode(key, [], encodingContext)
            s.send(Array([[UInt8]](repeating: one, count: abs(lines)).joined()))
        case .normal:
            let bounds = s.engine.scrollBounds()
            let top = (s.scrollTop ?? bounds.bottomTop) - lines
            let clamped = min(max(top, bounds.oldest), bounds.bottomTop)
            s.scrollTop = clamped == bounds.bottomTop ? nil : clamped
            view.requestRender()
        }
    }

    func terminalView(_ view: TerminalView, longPress state: UIGestureRecognizer.State, at cell: GridPoint,
                      location: CGPoint) {
        guard let s = active else { return }
        let abs = absolute(cell)
        switch state {
        case .began:
            // 長押し → ドラッグで選択（マウス報告ありでも接続先へは送らない）
            s.selection = TextSelection(anchor: abs, head: abs)
        case .changed:
            s.selection?.head = abs
        case .ended:
            view.showEditMenu(at: location)
        default:
            break
        }
        view.requestRender()
    }

    func terminalView(_ view: TerminalView, pinchZoomIn zoomIn: Bool) {
        changeZoom { $0.zoom(in: zoomIn) }
    }

    func terminalView(_ view: TerminalView, hardwareKey key: TermKey, modifiers: KeyModifiers) -> Bool {
        route(key, modifiers)
        return true
    }

    func terminalViewEditMenu(_ view: TerminalView) -> UIMenu? {
        var items: [UIMenuElement] = []
        if active?.selection != nil {
            items.append(UIAction(title: "コピー", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
            items.append(UIAction(title: "調べる", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.lookUpSelection()
            })
        }
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "ペースト", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.pasteClipboard()
            })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    private func lookUpSelection() {
        guard let s = active, let sel = s.selection else { return }
        let (a, b) = sel.ordered
        let text = s.engine.text(from: (a.row, a.col), to: (b.row, b.col))
        guard !text.isEmpty else { return }
        topPresenter.present(UIReferenceLibraryViewController(term: text), animated: true)
    }
}

// MARK: - ホスト鍵とパスワード

extension RootViewController: SessionPresenter {
    func confirmHostKey(host: HostEntry, verdict: HostKeyVerdict) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                let a: UIAlertController
                switch verdict {
                case .trusted:
                    cont.resume(returning: true)
                    return
                case .unknown(let fp):
                    a = UIAlertController(
                        title: "初めての接続先です",
                        message: "\(host.name)（\(host.address)）\n\(fp)\n\nこの指紋が接続先のものと同じか確かめてください。Mac では\nssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub",
                        preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "やめる", style: .cancel) { _ in cont.resume(returning: false) })
                    a.addAction(UIAlertAction(title: "接続する", style: .default) { _ in cont.resume(returning: true) })
                case .changed(let expected, let actual):
                    a = UIAlertController(
                        title: "ホスト鍵が変わっています",
                        message: "\(host.name) の鍵が、保存したものと違います。なりすましの恐れがあるので接続を止めました。\n\n保存: \(expected)\n今回: \(actual)\n\n接続先の鍵を作り直したのが確かなときだけ、＋ を長押し →「このタブのホスト鍵を忘れる」で消してから繋ぎ直してください。",
                        preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in cont.resume(returning: false) })
                }
                self.topPresenter.present(a, animated: true)
            }
        }
    }

    func askPassword(host: HostEntry) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.main.async {
                let a = UIAlertController(title: "パスワード", message: "\(host.user)@\(host.address)（保存しません）",
                                          preferredStyle: .alert)
                a.addTextField { f in
                    f.isSecureTextEntry = true
                    f.textContentType = .password
                }
                a.addAction(UIAlertAction(title: "やめる", style: .cancel) { _ in cont.resume(returning: nil) })
                a.addAction(UIAlertAction(title: "接続する", style: .default) { [weak a] _ in
                    cont.resume(returning: a?.textFields?.first?.text ?? "")
                })
                self.topPresenter.present(a, animated: true)
            }
        }
    }
}

// MARK: - 🌐 の吹き出し（iPhone でもポップオーバーのまま出す）

extension RootViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
