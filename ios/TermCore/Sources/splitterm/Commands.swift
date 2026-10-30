import Foundation
import TermCore

/// コマンドの結果。CLI は exitCode と文字をそのまま出し、MCP は文字を道具の答えにする
struct CommandResult: Equatable {
    var exitCode: Int32
    var output: String
    /// 人の手が要る（Apple ID のサインイン・端末で信頼 など）。MCP ではエージェントが人に頼む印になる
    var needsHuman = false

    static func ok(_ s: String) -> CommandResult { CommandResult(exitCode: 0, output: s) }
    static func fail(_ s: String, code: Int32 = 1) -> CommandResult { CommandResult(exitCode: code, output: s) }
}

/// splitterm の中身。CLI と MCP の両方がこれを呼ぶ
struct Commands {
    var env: Environment

    // MARK: config

    func configPath() -> CommandResult { .ok(env.configURL.path) }

    func readConfig(_ file: URL?) throws -> String {
        try String(contentsOf: file ?? env.configURL, encoding: .utf8)
    }

    /// 見本（全項目の説明付き）から config を作る。もうあれば何もしない
    func configInit() -> CommandResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: env.configURL.path) { return .ok("もうあります: \(env.configURL.path)") }
        guard let example = env.repoRoot?.appendingPathComponent("ios/SplitTerm/Resources/config.example"),
              fm.fileExists(atPath: example.path) else {
            return .fail("見本（ios/SplitTerm/Resources/config.example）が見つかりません。SPLITTERM_REPO でリポジトリを指定してください")
        }
        do {
            try fm.createDirectory(at: env.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: example, to: env.configURL)
            return .ok("作りました: \(env.configURL.path)（host を足してから push で端末へ送る）")
        } catch {
            return .fail("作れませんでした: \(error.localizedDescription)")
        }
    }

    func configCheck(file: URL?) -> CommandResult {
        let text: String
        do { text = try readConfig(file) } catch { return missing(file) }
        let d = ConfigParser.parse(text).diagnostics
        if d.isEmpty { return .ok("問題ありません: \((file ?? env.configURL).path)") }
        return .fail(d.map(\.description).joined(separator: "\n"))
    }

    func configShow(file: URL?) -> CommandResult {
        let text: String
        do { text = try readConfig(file) } catch { return missing(file) }
        let (c, d) = ConfigParser.parse(text)
        var out = "# 今効いている値（既定値を含む）: \((file ?? env.configURL).path)\n" + c.effectiveLines.joined(separator: "\n")
        if !d.isEmpty { out += "\n\n# 読めない行（飛ばしています）\n" + d.map { "# \($0)" }.joined(separator: "\n") }
        return CommandResult(exitCode: d.isEmpty ? 0 : 1, output: out)
    }

    func configSet(key: String, value: String, file: URL?) -> CommandResult {
        edit(file) { try ConfigEditor.set(key, value, in: $0) }
            .map { "\(key) を書き換えました。端末へは push で送ります" }
    }

    func hostAdd(_ entry: HostEntry, file: URL?) -> CommandResult {
        edit(file) { try ConfigEditor.addHost(entry, in: $0) }
            .map { "host \(entry.name) を足しました。端末へは push で送ります" }
    }

    func hostRemove(_ name: String, file: URL?) -> CommandResult {
        edit(file) { try ConfigEditor.removeHost(named: name, in: $0) }
            .map { "host \(name) を消しました。端末へは push で送ります" }
    }

    /// 読んで、書き換えて、書く。書き換えが断られたら、ファイルは触らない
    private func edit(_ file: URL?, _ change: (String) throws -> String) -> EditOutcome {
        let url = file ?? env.configURL
        let text: String
        do { text = try readConfig(file) } catch { return .result(missing(file)) }
        do {
            let new = try change(text)
            try new.write(to: url, atomically: true, encoding: .utf8)
            return .done
        } catch let e as ConfigEditor.EditError {
            return .result(.fail(e.message))
        } catch {
            return .result(.fail("書けませんでした: \(error.localizedDescription)"))
        }
    }

    private enum EditOutcome {
        case done
        case result(CommandResult)
        func map(_ message: () -> String) -> CommandResult {
            switch self {
            case .done: return .ok(message())
            case .result(let r): return r
            }
        }
    }

    private func missing(_ file: URL?) -> CommandResult {
        .fail("config がありません: \((file ?? env.configURL).path)（splitterm config init で見本から作れます）")
    }

    // MARK: 端末（scripts/ を呼ぶ）

    func push() -> CommandResult {
        let check = configCheck(file: nil)
        guard check.exitCode == 0 else { return .fail("読めない行があるので送りません:\n\(check.output)") }
        return runScript("ios_push_config.sh", [], timeout: 120)
    }

    /// 公開鍵を authorized_keys に足す。アプリに出た指紋が要る（書き換えられた鍵を足さないため）
    func pubkey(fingerprint: String) -> CommandResult {
        guard fingerprint.hasPrefix("SHA256:"), fingerprint.count > 10, !fingerprint.contains(" ") else {
            var r = CommandResult.fail("アプリの ＋ を長押し →「公開鍵をコピー」に出た指紋（SHA256:…）を渡してください")
            r.needsHuman = true
            return r
        }
        return runScript("ios_pubkey.sh", ["--fingerprint", fingerprint], timeout: 120)
    }

    func install(force: Bool) -> CommandResult {
        var r = runScript("ios_reinstall.sh", force ? ["--force"] : [], timeout: 1800)
        if r.exitCode != 0, r.output.contains("Team") || r.output.contains("サインイン") || r.output.contains("対になった") {
            r.needsHuman = true
        }
        return r
    }

    private func runScript(_ name: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        guard let script = env.script(name), FileManager.default.fileExists(atPath: script.path) else {
            return .fail("scripts/\(name) が見つかりません。SPLITTERM_REPO でリポジトリを指定してください")
        }
        let r = env.run("/bin/bash", [script.path] + args, timeout)
        var text = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut { text += "\n（時間切れで止めました）" }
        return CommandResult(exitCode: r.status, output: text)
    }

    /// 入れたアプリの期限とビルド（ios_reinstall.sh が書いた記録）
    func status() -> CommandResult {
        guard let root = env.repoRoot else { return .fail("リポジトリが見つかりません（SPLITTERM_REPO）") }
        let url = root.appendingPathComponent("tmp/ios/installed.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expires = obj["expires"] as? Double ?? (obj["expires"] as? Int).map(Double.init) else {
            return .fail("入れた記録がありません（splitterm install で入れます）")
        }
        let left = (expires - env.now().timeIntervalSince1970) / 3600
        let f = ISO8601DateFormatter()
        let lines = [
            "expires: \(f.string(from: Date(timeIntervalSince1970: expires)))",
            "hours_left: \(Int(left.rounded(.down)))",
            "build: \(obj["build"] as? String ?? "-")",
            "device: \(obj["device"] as? String ?? "-")",
        ]
        return CommandResult(exitCode: left > 0 ? 0 : 1, output: lines.joined(separator: "\n"))
    }

    // MARK: 受け取り箱（端末から送ったメディア）

    struct InboxItem: Equatable {
        var name: String
        var path: String
        var kind: String
        var bytes: Int
        var modified: Date
    }

    func inboxItems() throws -> [InboxItem] {
        let config = (try? readConfig(nil)).map { ConfigParser.parse($0).config } ?? TermConfig()
        let dir = env.inboxURL(config)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey,
                                                                                     .contentModificationDateKey],
                                              options: [.skipsHiddenFiles])
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  v.isRegularFile == true, !u.lastPathComponent.hasSuffix(".part") else { return nil }
            return InboxItem(name: u.lastPathComponent, path: u.path, kind: InboxNaming.kind(of: u.lastPathComponent),
                             bytes: v.fileSize ?? 0, modified: v.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    func inboxList(limit: Int) -> CommandResult {
        do {
            let items = try inboxItems().prefix(max(1, limit))
            if items.isEmpty { return .ok("受け取り箱は空です") }
            let f = ISO8601DateFormatter()
            return .ok(items.map { "\($0.kind)\t\(f.string(from: $0.modified))\t\($0.bytes)\t\($0.path)" }
                .joined(separator: "\n"))
        } catch {
            return .fail("受け取り箱を読めません: \(error.localizedDescription)")
        }
    }

    /// 古いものを消す。days が無ければ config の media-retention。0 なら消さない
    func inboxClean(days: Int?) -> CommandResult {
        let config = (try? readConfig(nil)).map { ConfigParser.parse($0).config } ?? TermConfig()
        let keep = days ?? config.mediaRetentionDays
        guard keep > 0 else { return .ok("消しません（media-retention = 0）") }
        let limit = env.now().addingTimeInterval(-Double(keep) * 86_400)
        do {
            // 消すのはアプリが付けた名前のものだけ（受け取り箱に人が置いたものは残す）
            let old = try inboxItems().filter { $0.modified < limit && InboxName.isAppName($0.name) }
            for item in old { try FileManager.default.removeItem(atPath: item.path) }
            return .ok("\(old.count) 件消しました（\(keep) 日より古いもの）")
        } catch {
            return .fail("消せませんでした: \(error.localizedDescription)")
        }
    }
}

/// 受け取り箱の名前の決まり（アプリが付ける。docs/design.md「メディアを送る」）
enum InboxNaming {
    static func kind(of name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".sheet.jpg") { return "video-sheet" }
        if lower.hasSuffix(".video.md") { return "video-notes" }
        if lower.hasSuffix(".transcript.md") { return "transcript" }
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "dng": return "image"
        case "mov", "mp4", "m4v", "hevc": return "video"
        case "m4a", "aac", "wav", "mp3", "caf", "aiff": return "audio"
        default: return "file"
        }
    }
}
