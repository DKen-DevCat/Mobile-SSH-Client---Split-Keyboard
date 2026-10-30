import Network
import TermCore
import UIKit

/// 上の 2 行の土台（docs/design.md「画面構成」の「上の 2 行」）。背景は透明でシェルの上に前面で重なる。
/// タッチを受けるのはボタン（UIControl）の上だけで、空いている所はシェルへ通す（シェルの表示範囲は縮めない）
class TopRow: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        var v: UIView? = hit
        while let x = v, x !== self {
            if x is UIControl { return hit }
            v = x.superview
        }
        return nil
    }
}

/// 上の 1 行目: 左に時計、右から 電池（％）・通信・⚠・倍率。⚠ は設定に読めない行があるときだけ（タップで今の診断）、
/// 倍率のタップで段を巡る。iOS が状態バーを出しているとき（iPad など）は、時計・通信・電池を隠す（二重に出さない）。
/// Face ID の iPhone の横持ちでは iOS が状態バーを出さないので、その代わりに時計・通信・電池を出す
final class StatusRow: TopRow {
    var onZoom: (() -> Void)?
    var onShowDiagnostics: (() -> Void)?

    private let zoom = UIButton(type: .system)
    private let warning = UIButton(type: .system)
    /// メディアを送っている途中の進み具合
    private let progress = UILabel()
    private var text = UIColor.white
    // 時計・通信・電池
    private let clock = UILabel()
    private let network = UIImageView()
    private let battery = UIImageView()
    private let batteryText = UILabel()
    private var clockTimer: Timer?
    private var networkUp = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        warning.setImage(UIImage(systemName: "exclamationmark.triangle.fill"), for: .normal)
        warning.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold),
                                                forImageIn: .normal)
        warning.tintColor = .systemYellow
        warning.isHidden = true
        warning.accessibilityLabel = "設定に読めない行があります"
        warning.addAction(UIAction { [weak self] _ in self?.onShowDiagnostics?() }, for: .touchUpInside)
        zoom.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        zoom.accessibilityLabel = "表示倍率"
        zoom.addAction(UIAction { [weak self] _ in self?.onZoom?() }, for: .touchUpInside)
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progress.isHidden = true
        for v in [progress, warning, zoom] { addSubview(v) }
        setUpStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 時計・通信・電池

    private func setUpStatus() {
        clock.textAlignment = .left
        batteryText.textAlignment = .right
        for l in [clock, batteryText] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            addSubview(l)
        }
        for v in [network, battery] {
            v.contentMode = .scaleAspectFit
            v.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            addSubview(v)
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateBattery), name: name, object: nil)
        }
        updateBattery()
        updateClock()
        // 分が変わるのに遅れないよう、15 秒ごとに
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        setNetwork(nil)
    }

    private func updateClock() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        clock.text = f.string(from: Date())
    }

    @objc private func updateBattery() {
        let d = UIDevice.current
        let level = d.batteryLevel
        let charging = d.batteryState == .charging || d.batteryState == .full
        let symbol: String
        switch level {
        case ..<0: symbol = "battery.100"
        case ..<0.13: symbol = "battery.0"
        case ..<0.38: symbol = "battery.25"
        case ..<0.63: symbol = "battery.50"
        case ..<0.88: symbol = "battery.75"
        default: symbol = "battery.100"
        }
        battery.image = UIImage(systemName: charging ? "battery.100.bolt" : symbol)
        battery.tintColor = level >= 0 && level < 0.2 && !charging ? .systemRed : text
        batteryText.text = level >= 0 ? "\(Int((level * 100).rounded()))%" : ""
        setNeedsLayout()
    }

    /// 通信の種類（nil はつながっていない）
    func setNetwork(_ type: NWInterface.InterfaceType?) {
        let symbol: String
        switch type {
        case .wifi?: symbol = "wifi"
        case .cellular?: symbol = "antenna.radiowaves.left.and.right"
        case .wiredEthernet?: symbol = "cable.connector"
        case nil: symbol = "wifi.slash"
        default: symbol = "network"
        }
        networkUp = type != nil
        network.image = UIImage(systemName: symbol)
        network.tintColor = networkUp ? text : .systemRed
    }

    func apply(colors: KeyboardColors) {
        text = colors.text
        zoom.tintColor = colors.text
        clock.textColor = colors.text
        batteryText.textColor = colors.text
        network.tintColor = networkUp ? colors.text : .systemRed
        updateBattery()
        progress.textColor = colors.subText
    }

    /// 送っている途中の進み具合（nil で消す）
    func setProgress(_ text: String?) {
        progress.text = text
        progress.isHidden = text == nil
        setNeedsLayout()
    }

    func update(zoomPercent: Int, diagnostics: Int) {
        zoom.setTitle("\(zoomPercent)%", for: .normal)
        warning.isHidden = diagnostics == 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        // iOS の状態バーが出ているなら、時計・通信・電池は隠す
        let systemBar = window?.windowScene?.statusBarManager?.isStatusBarHidden == false
        for v in [clock, network, battery, batteryText] as [UIView] { v.isHidden = systemBar }
        var right = bounds.width - 6
        if !systemBar {
            // 左に時計、右端に 通信・電池（iOS の状態バーと同じ並び）
            let pct = batteryText.sizeThatFits(CGSize(width: 60, height: h)).width
            right -= pct
            batteryText.frame = CGRect(x: right, y: 0, width: pct, height: h)
            right -= 24
            battery.frame = CGRect(x: right, y: 0, width: 22, height: h)
            right -= 18
            network.frame = CGRect(x: right, y: 0, width: 16, height: h)
            right -= 6
            let clockW = clock.sizeThatFits(CGSize(width: 60, height: h)).width
            clock.frame = CGRect(x: 6, y: 0, width: clockW, height: h)
        }
        if !warning.isHidden {
            right -= 28
            warning.frame = CGRect(x: right, y: 0, width: 28, height: h)
        }
        let zoomW = max(40, (zoom.titleLabel?.intrinsicContentSize.width ?? 30) + 16)
        right -= zoomW
        zoom.frame = CGRect(x: right, y: 0, width: zoomW, height: h)
        if !progress.isHidden {
            let w = min(110, progress.sizeThatFits(CGSize(width: 200, height: h)).width + 8)
            right -= w
            progress.frame = CGRect(x: right, y: 0, width: w, height: h)
        }
    }
}

/// 上の 2 行目: タブと＋。横のスクロールで、中身は左端からタブ、最後のタブの右隣に＋（＋もスクロールの中身）。
/// 選んだとき・足したときに、今のタブと＋が見えるようスクロールする。はみ出さないときはスクロールしない。
/// タブと＋は不透明（シェルの文字の上に重なる）。タブはタップで切り替え・長押しで「閉じる」、
/// ＋はタップで新しいタブ・長押しでメニュー（`plus.menu`）
final class TabRow: TopRow {
    struct Tab: Equatable {
        var title: String
        var state: ConnectionState
        var selected: Bool
    }

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// ＋。タップは `onNewTab`、長押しは `menu`（接続先の一覧と道具。画面の側で入れる）
    let plus = UIButton(type: .system)

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var accent = UIColor.systemBlue
    private var text = UIColor.white
    /// タブと＋の地の色（不透明）
    private var fill = UIColor.darkGray
    /// 今並べているタブ（同じなら作り直さない。長押しのメニューを出している途中に壊さない）
    private var shown: [Tab]?
    private var selectedIndex: Int?
    private var tabCount = 0
    private var needsReveal = false
    private static let margin: CGFloat = 6
    private static let plusSize: CGFloat = 26

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.contentInsetAdjustmentBehavior = .never
        stack.axis = .horizontal
        stack.spacing = 4
        scroll.addSubview(stack)
        addSubview(scroll)
        plus.setImage(UIImage(systemName: "plus"), for: .normal)
        plus.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .bold),
                                             forImageIn: .normal)
        plus.showsMenuAsPrimaryAction = false
        plus.accessibilityLabel = "新しいタブ"
        plus.addAction(UIAction { [weak self] _ in self?.onNewTab?() }, for: .touchUpInside)
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.widthAnchor.constraint(equalToConstant: Self.plusSize).isActive = true
        stack.addArrangedSubview(plus)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: KeyboardColors) {
        accent = colors.accent
        text = colors.text
        fill = colors.key
        plus.tintColor = colors.text
        plus.backgroundColor = colors.key
        shown = nil  // 色を変えたので、次の update で作り直す
    }

    func update(tabs items: [Tab]) {
        guard items != shown else { return }
        let selected = items.firstIndex { $0.selected }
        if selected != selectedIndex || items.count != tabCount { needsReveal = true }
        selectedIndex = selected
        tabCount = items.count
        shown = items
        for v in stack.arrangedSubviews where v !== plus {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            stack.insertArrangedSubview(makeTab(item, index: i), at: i)
        }
        setNeedsLayout()
    }

    private func makeTab(_ item: Tab, index i: Int) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.title = item.title
        cfg.image = UIImage(systemName: Self.symbol(item.state))
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9)
        // 不透明（シェルの文字の上に重なる）。選んだタブはアクセント色
        cfg.baseBackgroundColor = item.selected ? accent : fill
        cfg.baseForegroundColor = text
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        cfg.cornerStyle = .medium
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            return a
        }
        b.configuration = cfg
        // 長い題名は末尾を省く
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.onSelectTab?(i) }, for: .touchUpInside)
        b.menu = UIMenu(children: [
            UIAction(title: "閉じる", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onCloseTab?(i)
            },
        ])
        return b
    }

    static func symbol(_ s: ConnectionState) -> String {
        switch s {
        case .connected: return "circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .idle, .disconnected: return "circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let m = Self.margin
        scroll.frame = bounds
        let size = stack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: h))
        stack.frame = CGRect(x: m, y: 3, width: size.width, height: max(0, h - 6))
        stack.layoutIfNeeded()
        plus.layer.cornerRadius = plus.bounds.height / 2
        scroll.contentSize = CGSize(width: m + size.width + m, height: h)
        // はみ出さないときはスクロールしない。幅が変わって行き過ぎたら戻す
        let maxOffset = max(0, scroll.contentSize.width - scroll.bounds.width)
        if scroll.contentOffset.x > maxOffset { scroll.contentOffset = CGPoint(x: maxOffset, y: 0) }
        if needsReveal {
            needsReveal = false
            revealSelected()
        }
    }

    /// 選んだタブ（いちばん右のタブなら、右隣の＋も）が見えるようにスクロールする
    private func revealSelected() {
        guard scroll.contentSize.width > scroll.bounds.width, let i = selectedIndex else { return }
        let tabs = stack.arrangedSubviews.filter { $0 !== plus }
        guard tabs.indices.contains(i) else { return }
        var target = scroll.convert(tabs[i].frame, from: stack)
        if i == tabs.count - 1 { target = target.union(scroll.convert(plus.frame, from: stack)) }
        scroll.scrollRectToVisible(target.insetBy(dx: -Self.margin, dy: 0), animated: true)
    }
}

/// 変換候補バー（かな入力のときだけ）。読みと候補を並べ、タップで確定する。
/// ボタンは使い回す（打つたびに作り直さない。候補が増えたときだけ作る）
final class CandidateBar: UIView {
    var onPick: ((KanaCandidate) -> Void)?
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private var colors: KeyboardColors?
    /// ローマ字のまだかなにならない英字（先頭に薄く出す）
    private let pendingLabel = UILabel()
    private var buttons: [UIButton] = []
    /// いまボタンに出ている題（同じなら書き換えない）
    private var titles: [String] = []
    /// 見た目を付け終えたボタンの数（色を変えたら 0 に戻す）。それ以降は題だけ書き換える
    private var styled = 0
    /// ボタンが指す候補（ボタンの番号 = 候補の番号）
    private var candidates: [KanaCandidate] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 6
        pendingLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        pendingLabel.isHidden = true
        stack.addArrangedSubview(pendingLabel)
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: KeyboardColors) {
        self.colors = colors
        backgroundColor = colors.functionKey
        pendingLabel.textColor = colors.subText
        // 次の update で、色を付け直す
        titles.removeAll()
        styled = 0
    }

    /// 候補を並べる。pending はローマ字のまだかなにならない英字（先頭に薄く出す）
    func update(candidates: [KanaCandidate], pending: String = "") {
        if pendingLabel.text != pending { pendingLabel.text = pending }
        pendingLabel.isHidden = pending.isEmpty
        self.candidates = candidates
        for (i, c) in candidates.enumerated() {
            let b = i < buttons.count ? buttons[i] : makeButton()
            b.isHidden = false
            // 出ている題と同じなら、何もしない
            if i < titles.count, titles[i] == c.text { continue }
            if i < styled {
                b.configuration?.title = c.text
            } else {
                style(b, title: c.text, first: i == 0)
                styled = i + 1
            }
            if i < titles.count { titles[i] = c.text } else { titles.append(c.text) }
        }
        // 余ったボタンは隠す（スタックは隠れたものを詰める）
        for b in buttons.dropFirst(candidates.count) { b.isHidden = true }
        setNeedsLayout()
    }

    private func makeButton() -> UIButton {
        let i = buttons.count
        let b = UIButton(type: .system)
        b.addAction(UIAction { [weak self] _ in self?.pick(i) }, for: .touchUpInside)
        stack.addArrangedSubview(b)
        buttons.append(b)
        return b
    }

    private func pick(_ i: Int) {
        guard candidates.indices.contains(i) else { return }
        onPick?(candidates[i])
    }

    private func style(_ b: UIButton, title: String, first: Bool) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = colors?.text ?? .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
        if first {
            cfg.background.backgroundColor = colors?.key
            cfg.background.cornerRadius = 6
        }
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = UIFont.systemFont(ofSize: 16)
            return a
        }
        b.configuration = cfg
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds.insetBy(dx: 4, dy: 3)
        let size = stack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width,
                                                        height: scroll.bounds.height))
        stack.frame = CGRect(x: 0, y: 0, width: size.width, height: scroll.bounds.height)
        scroll.contentSize = stack.frame.size
    }
}
