import Foundation
import TermCore

/// Mac の Ghostty が使っている値を読む（docs/design.md「Ghostty の配色の取り込み」）。読み方は 2 通りで、
/// ①`ghostty +show-config --changes-only=false`（テーマを当てた後の全部の値）を読み、
/// ②①ができないとき、Ghostty の config ファイルとテーマのファイルを直接読む。
/// 実行ファイルもファイルも決まった場所だけで、場所は受け取らない（MCP の道具から任意のファイルを読ませない）。
/// 値の読み取りと変換は TermCore の `GhosttyImport`（純粋）で、ここは起動とファイルの読み取りだけ
struct GhosttyReader {
    var env: Environment

    /// `+show-config` を待つ時間（秒）
    static let timeout: TimeInterval = 10
    /// 読む出力・ファイルの大きさの上限（バイト）。MCP の 1 行の上限と同じ
    static let maxBytes = MCPServer.maxLine

    struct Reading {
        var settings: GhosttyImport.Settings
        /// 読んだ方法（出力の先頭に書く）
        var via: String
        /// 読み方の事情の知らせ
        var notes: [String]
        /// ファイルを直接読んだ道か（明示されていない色は Ghostty の既定色が分からない）
        var fromFiles: Bool
    }

    enum Outcome {
        case read(Reading)
        case failed(String)
    }

    struct ReadFailure: Error {
        var reason: String
    }

    // MARK: 場所

    /// 実行ファイル。`/Applications/Ghostty.app` の中、無ければ PATH の `ghostty`
    func executable() -> String? {
        let app = appExecutable.path
        if isExecutable(app) { return app }
        for dir in env.searchPath where dir.hasPrefix("/") {
            let path = dir.hasSuffix("/") ? dir + "ghostty" : dir + "/ghostty"
            if isExecutable(path) { return path }
        }
        return nil
    }

    private var appExecutable: URL { env.ghosttyApp.appendingPathComponent("Contents/MacOS/ghostty") }

    private func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// `$XDG_CONFIG_HOME`（絶対パスのときだけ）、無ければ `~/.config`
    private var configHome: URL {
        if let x = env.xdgConfigHome, x.hasPrefix("/") { return URL(fileURLWithPath: x) }
        return env.home.appendingPathComponent(".config")
    }

    /// Ghostty の config ファイル（読む順。後に読んだ方が優先）
    var configCandidates: [URL] {
        [configHome.appendingPathComponent("ghostty/config"),
         env.home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")]
    }

    /// テーマのファイルを探すフォルダ（上から順）
    var themeDirectories: [URL] {
        [configHome.appendingPathComponent("ghostty/themes"),
         env.ghosttyApp.appendingPathComponent("Contents/Resources/ghostty/themes")]
    }

    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 読む

    func read() -> Outcome {
        var reasons: [String] = []
        if let exe = executable() {
            switch showConfig(exe) {
            case .success(var s):
                // 明暗 2 つのテーマは、どちらの値が出ているか分からないので、ファイルで暗い方を読み直す
                guard let theme = s.theme, GhosttyImport.themeChoice(theme)?.isPair == true else {
                    return .read(Reading(settings: s, via: "\(exe) +show-config", notes: [], fromFiles: false))
                }
                if let files = readFiles() {
                    let notes = ["theme が明暗 2 つ（\(theme)）で、+show-config の出力はどちらの値か分からないので、設定ファイルから暗い方を読み直しました"]
                        + files.notes
                    return .read(Reading(settings: files.settings, via: "Ghostty の config ファイルとテーマのファイル",
                                         notes: notes, fromFiles: true))
                }
                s.warnings.append("theme が明暗 2 つ（\(theme)）で、設定ファイルを読めなかったので、+show-config の値を使いました。暗い方の値とは限りません")
                return .read(Reading(settings: s, via: "\(exe) +show-config", notes: [], fromFiles: false))
            case .failure(let e):
                reasons.append(e.reason)
            }
        } else {
            reasons.append("ghostty の実行ファイルがありません（\(appExecutable.path)、PATH の ghostty）")
        }
        if let files = readFiles() {
            let notes = ["\(reasons.joined(separator: "。"))ので、設定ファイルを直接読みました"] + files.notes
            return .read(Reading(settings: files.settings, via: "Ghostty の config ファイルとテーマのファイル",
                                 notes: notes, fromFiles: true))
        }
        return .failed(notFound(reasons))
    }

    /// `ghostty +show-config --changes-only=false` を、シェルを通さずに起動して読む
    private func showConfig(_ exe: String) -> Result<GhosttyImport.Settings, ReadFailure> {
        let r = env.run(exe, ["+show-config", "--changes-only=false"], Self.timeout)
        if r.timedOut {
            return .failure(ReadFailure(reason: "ghostty +show-config が \(Int(Self.timeout)) 秒で終わりませんでした"))
        }
        guard r.status == 0 else {
            return .failure(ReadFailure(reason: "ghostty +show-config が終了コード \(r.status) で終わりました"))
        }
        guard r.stdout.utf8.count <= Self.maxBytes else {
            return .failure(ReadFailure(reason: "ghostty +show-config の出力が大きすぎます（1MB まで）"))
        }
        var s = GhosttyImport.Settings()
        GhosttyImport.apply(r.stdout, to: &s)
        guard s.background != nil || s.foreground != nil || !s.palette.isEmpty else {
            return .failure(ReadFailure(reason: "ghostty +show-config の出力に色の項目がありません（出力の形が変わったかもしれません）"))
        }
        return .success(s)
    }

    /// config ファイルとテーマのファイルを直接読む。config ファイルが 1 つも無ければ nil。
    /// テーマの値の上に config の値を重ねる。色以外の項目は、書いていなければ Ghostty の既定値と見なす
    private func readFiles() -> (settings: GhosttyImport.Settings, notes: [String])? {
        let texts: [(path: String, text: String)] = configCandidates.compactMap { url in
            readText(url).map { (path: url.path, text: $0) }
        }
        guard !texts.isEmpty else { return nil }
        var s = GhosttyImport.Settings.withGhosttyDefaults()
        var notes = ["Ghostty の config: " + texts.map { $0.path }.joined(separator: "、")]

        let entries = texts.flatMap { GhosttyImport.entries(in: $0.text) }
        if let value = entries.last(where: { $0.key == "theme" })?.value, let choice = GhosttyImport.themeChoice(value) {
            if choice.isPair { notes.append("theme が明暗 2 つ（\(value)）なので、暗い方の \(choice.name) を使います") }
            if let found = loadTheme(choice.name, warnings: &s.warnings) {
                GhosttyImport.apply(found.text, to: &s)
                notes.append("テーマ \(choice.name) を読みました（\(found.path)）")
            }
        }
        for item in texts { GhosttyImport.apply(item.text, to: &s) }
        if !s.includes.isEmpty {
            s.warnings.append("config-file で読み込む別のファイル（\(s.includes.joined(separator: "、"))）は読みません")
        }
        return (s, notes)
    }

    private func loadTheme(_ name: String, warnings: inout [String]) -> (text: String, path: String)? {
        guard GhosttyImport.isSafeThemeName(name) else {
            warnings.append("theme `\(name)` はテーマの名前として読めない形（/ を含む、. で始まるなど）なので、テーマの色は書きません")
            return nil
        }
        for dir in themeDirectories {
            let url = dir.appendingPathComponent(name)
            if let text = readText(url) { return (text: text, path: url.path) }
        }
        warnings.append("theme `\(name)` のファイルが見つかりません（探した場所: "
                        + themeDirectories.map(\.path).joined(separator: "、") + "）。テーマの色は書きません")
        return nil
    }

    private func notFound(_ reasons: [String]) -> String {
        var lines = ["Ghostty の設定を読めません。"]
        lines += reasons.map { "  - " + $0 }
        lines.append("  - Ghostty の config ファイルがありません（探した場所: "
                     + configCandidates.map(\.path).joined(separator: "、") + "）")
        lines.append("直し方: Ghostty を入れる（https://ghostty.org 。/Applications/Ghostty.app に置くか、ghostty コマンドを PATH に通す）。"
                     + "入れてあるのに読めないときは、Ghostty の config を \(configCandidates[0].path) に置く。そのあと、もう一度実行する")
        return lines.joined(separator: "\n")
    }
}

extension Commands {
    /// Mac の Ghostty の配色を config に取り込む。`dryRun` なら、書き換える内容を出すだけで何も書かない
    func themeImport(dryRun: Bool, file: URL?) -> CommandResult {
        let url = file ?? env.configURL
        let original: String
        do { original = try readConfig(file) } catch { return missing(file) }

        let reading: GhosttyReader.Reading
        switch GhosttyReader(env: env).read() {
        case .failed(let message): return .fail(message)
        case .read(let r): reading = r
        }
        let settings = reading.settings
        let items = GhosttyImport.items(for: settings)

        // 先に全部を書き換えてみて、読めなくなるなら断る（ファイルは触らない）
        let updated: String
        do {
            updated = try GhosttyImport.write(items, into: original)
        } catch let e as ConfigEditor.EditError {
            return .fail("書き換えると config が読めなくなるので、何も書きません: \(e.message)")
        } catch {
            return .fail("書き換えられませんでした: \(error.localizedDescription)")
        }
        if !dryRun {
            do { try updated.write(to: url, atomically: true, encoding: .utf8) } catch {
                return .fail("書けませんでした: \(error.localizedDescription)")
            }
        }

        var out = ["Ghostty の配色を読みました（\(reading.via)）。"]
        out.append(dryRun ? "--dry-run なので config は書き換えません。書き換える内容（\(url.path)）:"
                          : "config に書きました（\(url.path)）:")
        out += items.map { "  " + $0.line }

        var notes = reading.notes
        let unknownColors = GhosttyImport.missingColors(settings)
        if !unknownColors.isEmpty {
            notes.append(reading.fromFiles
                ? "設定ファイルを直接読んだ道では、明示されていない色は Ghostty の既定色が分からないので書きません（\(unknownColors.joined(separator: "、"))）。色以外の minimum-contrast・bold-is-bright・font-thicken・window-colorspace は、書いていなければ Ghostty の既定値（1・false・false・srgb）と見なしました"
                : "Ghostty で未設定の色は書きません（\(unknownColors.joined(separator: "、"))）。アプリの値のままです")
        }
        if settings.colorSpace == .srgb {
            notes.append("color-space = srgb（Ghostty の window-colorspace）。今の display-p3 より少し落ち着いた色になり、PC と同じ色になります")
        }
        notes.append("tmux の中を true color にするには、動いているセッションを 1 度作り直します（Get Started の「色を PC の Ghostty にそろえる」）")
        out.append("注:")
        out += notes.map { "  - " + $0 }

        let warnings = GhosttyImport.warnings(for: settings)
        if !warnings.isEmpty {
            out.append("警告:")
            out += warnings.map { "  - " + $0 }
        }
        out.append(dryRun ? "書き込むには --dry-run を付けずにもう一度実行します。そのあと splitterm push（MCP なら config_push）で端末へ送ります"
                          : "次は splitterm push（MCP なら config_push）で端末へ送ります")
        return .ok(out.joined(separator: "\n"))
    }
}
