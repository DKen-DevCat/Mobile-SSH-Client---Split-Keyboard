import TermCore
import UIKit

/// 環境バー（docs/design.md「横持ち」）: 接続タブ、＋（新規接続とメニュー）、表示倍率、キーボード選択
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

    private let tabs = UIStackView()
    private let scroll = UIScrollView()
    let plus = UIButton(type: .system)
    private let zoom = UIButton(type: .system)
    private let keyboard = UIButton(type: .system)
    private let warning = UIButton(type: .system)
    private var accent = UIColor.systemBlue
    private var text = UIColor.white

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
        keyboard.addAction(UIAction { [weak self] _ in self?.onKeyboard?() }, for: .touchUpInside)
        for b in [zoom, keyboard] {
            b.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        for v in [plus, warning, zoom, keyboard] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: KeyboardColors) {
        backgroundColor = colors.background
        accent = colors.accent
        text = colors.text
        for b in [plus, zoom, keyboard] { b.tintColor = colors.text }
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
        keyboard.setTitle(kind == .us ? "US" : "かな", for: .normal)
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
        var right = bounds.width
        for b in [keyboard, zoom, warning] where !b.isHidden {
            let w: CGFloat = b === warning ? 32 : 48
            right -= w
            b.frame = CGRect(x: right, y: 0, width: w, height: h)
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
    var onPick: ((String) -> Void)?
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

    func update(candidates: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, c) in candidates.enumerated() {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.title = c
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
