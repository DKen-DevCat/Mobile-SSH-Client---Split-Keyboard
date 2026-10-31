import UIKit

/// 項目を並べた吹き出し（iOS のポップオーバー。iPhone でも吹き出しのまま）。キーボードの 📎 のキーから出す。
/// 項目はシェルの左下の 📎 のメニューと同じ（`RootViewController.mediaMenuItems`）。docs/design.md「JIS の分割」
final class ActionMenuController: UITableViewController {
    struct Item {
        let title: String
        /// SF Symbols の名前
        let symbol: String
        var destructive = false
        let run: () -> Void
    }

    private let items: [Item]
    private static let rowHeight: CGFloat = 44

    init(items: [Item]) {
        self.items = items
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "item")
        tableView.isScrollEnabled = false
        tableView.rowHeight = Self.rowHeight
        preferredContentSize = CGSize(width: 250, height: Self.rowHeight * CGFloat(items.count))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        let item = items[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.textProperties.font = .systemFont(ofSize: 15)
        content.image = UIImage(systemName: item.symbol)
        if item.destructive {
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = items[indexPath.row]
        // 吹き出しを閉じてから実行する（続けて出す写真の選択などが、閉じる途中の吹き出しに邪魔されない）
        dismiss(animated: true) { item.run() }
    }
}
