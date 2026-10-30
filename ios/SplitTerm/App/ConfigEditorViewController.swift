import TermCore
import UIKit

/// 設定ファイルをその場で直す画面。保存すると、すぐに読み直して効く。読めない行は下に出す
final class ConfigEditorViewController: UIViewController, UITextViewDelegate {
    let store: ConfigStore
    private let text = UITextView()
    private let problems = UILabel()

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "config"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in
            self?.save()
        })
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.autocorrectionType = .no
        text.autocapitalizationType = .none
        text.smartQuotesType = .no
        text.smartDashesType = .no
        text.spellCheckingType = .no
        text.text = store.text
        text.delegate = self
        problems.numberOfLines = 0
        problems.font = .systemFont(ofSize: 12)
        problems.textColor = .systemOrange
        view.addSubview(text)
        view.addSubview(problems)
        check()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let g = view.safeAreaLayoutGuide.layoutFrame
        let h = problems.isHidden ? 0 : min(120, problems.sizeThatFits(CGSize(width: g.width - 32, height: 400)).height + 12)
        text.frame = CGRect(x: g.minX, y: g.minY, width: g.width, height: g.height - h)
        problems.frame = CGRect(x: g.minX + 16, y: g.maxY - h, width: g.width - 32, height: h)
    }

    func textViewDidChange(_ textView: UITextView) { check() }

    /// 打っている間も、読めない行を出す
    private func check() {
        let d = ConfigParser.parse(text.text).diagnostics
        problems.isHidden = d.isEmpty
        problems.text = d.map(\.description).joined(separator: "\n")
        view.setNeedsLayout()
    }

    private func save() {
        do {
            try store.save(text.text)
            dismiss(animated: true)
        } catch {
            let a = UIAlertController(title: "保存できませんでした", message: error.localizedDescription, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        }
    }
}
