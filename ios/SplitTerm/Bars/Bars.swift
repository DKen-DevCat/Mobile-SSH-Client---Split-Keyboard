import Network
import TermCore
import UIKit

/// 環境バー（docs/design.md「横持ち」）: 接続タブ、＋（新規接続とメニュー）、表示倍率、キーボード選択、
/// 時計・通信・電池（Face ID の iPhone の横持ちでは iOS が状態バーを出さないので、その代わり）
final class EnvironmentBar: UIView {
    struct Tab {
        var title: String
        var state: ConnectionState
        var selected: Bool
    }

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onZoom: (() -> Void)?
    var onKeyboard: (() -> Void)?
    var onShowDiagnostics: (() -> Void)?
    /// 📎（写真・動画・音声・ファイルを送る）。メニューは画面の側で作る
    let attach = UIButton(type: .system)
    /// メディアを送っている途中の進み具合
    private let progress = UILabel()

    private let tabs = UIStackView()
    private let scroll = UIScrollView()
    let plus = UIButton(type: .system)
    private let zoom = UIButton(type: .system)
    private let keyboard = UIButton(type: .system)
    private let warning = UIButton(type: .system)
    private var accent = UIColor.systemBlue
    private var text = UIColor.white
    // 時計・通信・電池
    private let clock = UILabel()
    private let network = UIImageView()
    private let battery = UIImageView()
    private let batteryText = UILabel()
    private var clockTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tabs.axis = .horizontal
        tabs.spacing = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(tabs)
        addSubview(scroll)
        plus.setImage(UIImage(systemName: "plus"), for: .normal)
        plus.showsMenuAsPrimaryAction = true
        warning.setImage(UIImage(systemName: "exclamationmark.triangle.fill"), for: .normal)
        warning.tintColor = .systemYellow
        warning.isHidden = true
        warning.addAction(UIAction { [weak self] _ in self?.onShowDiagnostics?() }, for: .touchUpInside)
        zoom.addAction(UIAction { [weak self] _ in self?.onZoom?() }, for: .touchUpInside)
        keyboard.showsMenuAsPrimaryAction = true
        for b in [zoom, keyboard] {
            b.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        attach.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attach.showsMenuAsPrimaryAction = true
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progress.isHidden = true
        for v in [plus, attach, progress, warning, zoom, keyboard] { addSubview(v) }
        setUpStatus()
    }

    /// キーボードを選ぶメニュー（タップで出す）
    func setKeyboardMenu(_ menu: UIMenu) {
        keyboard.menu = menu
    }

    // MARK: 時計・通信・電池

    private func setUpStatus() {
        for l in [clock, batteryText] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            l.textAlignment = .right
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
        network.image = UIImage(systemName: symbol)
        network.tintColor = type == nil ? .systemRed : text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: KeyboardColors) {
        backgroundColor = colors.background
        accent = colors.accent
        text = colors.text
        for b in [plus, attach, zoom, keyboard] { b.tintColor = colors.text }
        clock.textColor = colors.text
        batteryText.textColor = colors.text
        network.tintColor = colors.text
        updateBattery()
        progress.textColor = colors.subText
    }

    /// 送っている途中の進み具合（nil で消す）
    func setProgress(_ text: String?) {
        progress.text = text
        progress.isHidden = text == nil
        setNeedsLayout()
    }

    func update(tabs items: [Tab], zoomPercent: Int, keyboard kind: KeyboardKind, showKeyboardButton: Bool,
                diagnostics: Int) {
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.filled()
            cfg.title = item.title
            cfg.image = UIImage(systemName: Self.symbol(item.state))
            cfg.imagePadding = 4
            cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9)
            cfg.baseBackgroundColor = item.selected ? accent : text.withAlphaComponent(0.1)
            cfg.baseForegroundColor = text
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            cfg.cornerStyle = .medium
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = UIFont.systemFont(ofSize: 12, weight: .medium)
                return a
            }
            b.configuration = cfg
            b.addAction(UIAction { [weak self] _ in self?.onSelectTab?(i) }, for: .touchUpInside)
            b.menu = UIMenu(children: [
                UIAction(title: "閉じる", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                    self?.onCloseTab?(i)
                },
            ])
            tabs.addArrangedSubview(b)
        }
        zoom.setTitle("\(zoomPercent)%", for: .normal)
        keyboard.setTitle(kind.shortTitle, for: .normal)
        keyboard.isHidden = !showKeyboardButton
        warning.isHidden = diagnostics == 0
        setNeedsLayout()
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
        var right = bounds.width - 4
        // 右端に 時計・通信・電池（iOS の状態バーと同じ並び: 時計は左、通信と電池は右）
        let pct = batteryText.sizeThatFits(CGSize(width: 60, height: h)).width
        right -= pct
        batteryText.frame = CGRect(x: right, y: 0, width: pct, height: h)
        right -= 24
        battery.frame = CGRect(x: right, y: 0, width: 22, height: h)
        right -= 18
        network.frame = CGRect(x: right, y: 0, width: 16, height: h)
        let clockW = clock.sizeThatFits(CGSize(width: 60, height: h)).width
        right -= clockW + 4
        clock.frame = CGRect(x: right, y: 0, width: clockW, height: h)
        right -= 4
        for b in [keyboard, zoom, warning] where !b.isHidden {
            let w: CGFloat = b === warning ? 32 : (b === keyboard ? max(48, (b.titleLabel?.intrinsicContentSize.width ?? 40) + 12) : 48)
            right -= w
            b.frame = CGRect(x: right, y: 0, width: w, height: h)
        }
        if !progress.isHidden {
            let w = min(110, progress.sizeThatFits(CGSize(width: 200, height: h)).width + 8)
            right -= w
            progress.frame = CGRect(x: right, y: 0, width: w, height: h)
        }
        if !attach.isHidden {
            right -= 36
            attach.frame = CGRect(x: right, y: 0, width: 36, height: h)
        }
        right -= 36
        plus.frame = CGRect(x: right, y: 0, width: 36, height: h)
        scroll.frame = CGRect(x: 4, y: 0, width: max(0, right - 4), height: h)
        let size = tabs.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: h - 12))
        tabs.frame = CGRect(x: 0, y: 6, width: size.width, height: h - 12)
        scroll.contentSize = CGSize(width: size.width, height: h)
    }
}

/// 変換候補バー（かな入力のときだけ）。読みと候補を並べ、タップで確定する
final class CandidateBar: UIView {
    var onPick: ((KanaCandidate) -> Void)?
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private var colors: KeyboardColors?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: KeyboardColors) {
        self.colors = colors
        backgroundColor = colors.functionKey
    }

    /// 候補を並べる。pending はローマ字のまだかなにならない英字（先頭に薄く出す）
    func update(candidates: [KanaCandidate], pending: String = "") {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !pending.isEmpty {
            let l = UILabel()
            l.text = pending
            l.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            l.textColor = colors?.subText ?? .lightGray
            stack.addArrangedSubview(l)
        }
        for (i, c) in candidates.enumerated() {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.title = c.text
            cfg.baseForegroundColor = colors?.text ?? .white
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
            if i == 0 {
                cfg.background.backgroundColor = colors?.key
                cfg.background.cornerRadius = 6
            }
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = UIFont.systemFont(ofSize: 16)
                return a
            }
            b.configuration = cfg
            b.addAction(UIAction { [weak self] _ in self?.onPick?(c) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        setNeedsLayout()
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
