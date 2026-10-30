import Foundation
import TermCore

/// 設定ファイル 1 枚（Ghostty のように config 1 枚で管理する。docs/design.md「設定ファイル」）。
/// 置き場所はアプリの書類フォルダの `config`。「ファイル」アプリから見え、Mac からは scripts/ios_push_config.sh で入れる。
/// ファイルが変わったら読み直す（保存した瞬間に効く）
final class ConfigStore {
    private(set) var config = TermConfig()
    private(set) var diagnostics: [ConfigDiagnostic] = []
    /// 読み直した。メインスレッドで呼ぶ
    var onChange: ((TermConfig, [ConfigDiagnostic]) -> Void)?

    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var lastText: String?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("config")
        installDefaultIfMissing()
        reload()
        watch()
    }

    /// 初回は、同梱の見本（全項目の説明付き。値はすべて既定値）を置く
    private func installDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path),
              let bundled = Bundle.main.url(forResource: "config", withExtension: "example") else { return }
        try? FileManager.default.copyItem(at: bundled, to: url)
    }

    var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func save(_ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    /// ファイルを読み直す。中身が変わっていなければ何もしない
    func reload(force: Bool = false) {
        let t = text
        guard force || t != lastText else { return }
        lastText = t
        (config, diagnostics) = ConfigParser.parse(t)
        onChange?(config, diagnostics)
    }

    /// 保存のしかたによってはファイルが置き換わる（atomic な保存）ので、そのたびに見張り直す
    private func watch() {
        source?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                          queue: .main)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let replaced = !s.data.isDisjoint(with: [.delete, .rename])
            self.reload()
            if replaced {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reload()
                    self?.watch()
                }
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// 公開鍵を書類フォルダに置く（Mac の scripts/ios_pubkey.sh が取りにくる。秘密ではない）
    func writePublicKey(_ line: String) {
        let docs = url.deletingLastPathComponent()
        try? (line + "\n").write(to: docs.appendingPathComponent("splitterm.pub"), atomically: true, encoding: .utf8)
    }
}
