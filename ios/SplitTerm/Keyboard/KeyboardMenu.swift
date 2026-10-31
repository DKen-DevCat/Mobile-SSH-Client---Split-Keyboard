import TermCore
import UIKit

/// 🌐 の長押しで出す、キーボードを選ぶ吹き出し（iOS のポップオーバー。docs/design.md「キーボードの種類」）。
/// 縦持ちは JIS の一体型の 2 つ（英語・ローマ字）だけ（docs/design.md「JIS の一体型（縦持ち）」）
final class KeyboardMenuController: UITableViewController {
    private let current: KeyboardKind
    private let onPick: (KeyboardKind) -> Void
    private let portrait: Bool
    private var kinds: [KeyboardKind] { KeyboardKind.menuOrder(portrait: portrait) }
    private static let rowHeight: CGFloat = 44

    init(current: KeyboardKind, portrait: Bool, onPick: @escaping (KeyboardKind) -> Void) {
        self.current = current
        self.portrait = portrait
        self.onPick = onPick
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "kind")
        tableView.isScrollEnabled = false
        tableView.rowHeight = Self.rowHeight
        preferredContentSize = CGSize(width: 290, height: Self.rowHeight * CGFloat(kinds.count))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { kinds.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "kind", for: indexPath)
        let kind = kinds[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = kind.title(portrait: portrait)
        content.textProperties.font = .systemFont(ofSize: 15)
        cell.contentConfiguration = content
        cell.accessoryType = kind == current ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let kind = kinds[indexPath.row]
        dismiss(animated: true) { [onPick] in onPick(kind) }
    }
}
