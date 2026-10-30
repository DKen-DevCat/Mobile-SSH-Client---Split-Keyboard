import Foundation
import TermCore

/// 準備がそろっているかを調べ、足りないものと直し方を返す（エージェントが Get Started を進める足場）
struct Doctor {
    enum Status: String { case ok, warn, fail }

    struct Check {
        var id: String
        var status: Status
        var message: String
        var fix: String = ""
        var needsHuman = false
    }

    var env: Environment

    func run() -> [Check] {
        [xcode(), team(), jq(), tmux(), remoteLogin(), device(), config(), app(), authorizedKey()]
    }

    func report() -> CommandResult {
        let checks = run()
        let lines = checks.map { c -> String in
            var s = "[\(c.status.rawValue)] \(c.id): \(c.message)"
            if !c.fix.isEmpty { s += "\n    直し方: \(c.fix)" }
            if c.needsHuman { s += "\n    （人の手が要ります）" }
            return s
        }
        var r = CommandResult(exitCode: checks.contains { $0.status == .fail } ? 1 : 0,
                              output: lines.joined(separator: "\n"))
        r.needsHuman = checks.contains { $0.status != .ok && $0.needsHuman }
        return r
    }

    private func ok(_ cmd: String, _ args: [String]) -> ProcessResult { env.run(cmd, args, 60) }

    func xcode() -> Check {
        let r = ok("/usr/bin/xcrun", ["--find", "xcodebuild"])
        if r.status == 0 { return Check(id: "xcode", status: .ok, message: "Xcode があります") }
        return Check(id: "xcode", status: .fail, message: "Xcode が見つかりません",
                     fix: "App Store から Xcode を入れ、一度開いて追加の部品を入れる", needsHuman: true)
    }

    func team() -> Check {
        // ios_reinstall.sh と同じ読み方（Xcode の設定にある無料の Team）
        let pipeline = "defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null | jq -r '[.[][] | select(.isFreeProvisioningTeam == true) | .teamID] | unique | length' 2>/dev/null"
        let r = ok("/bin/bash", ["-c", pipeline])
        let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if n == 1 { return Check(id: "team", status: .ok, message: "無料の Team が 1 つあります") }
        if n > 1 {
            return Check(id: "team", status: .warn, message: "無料の Team が \(n) つあります",
                         fix: "SPLITTERM_IOS_TEAM で使う Team ID を指定する")
        }
        return Check(id: "team", status: .fail, message: "無料の Team がありません",
                     fix: "Xcode > Settings > Accounts で Apple ID にサインインする", needsHuman: true)
    }

    func jq() -> Check {
        let r = ok("/bin/zsh", ["-lc", "command -v jq"])
        if r.status == 0 { return Check(id: "jq", status: .ok, message: "jq があります") }
        return Check(id: "jq", status: .fail, message: "jq がありません", fix: "brew install jq")
    }

    func tmux() -> Check {
        // アプリが接続時に探すのと同じ一覧（HostEntry.tmuxSearchPaths）を、上から順に。$HOME は展開する
        let home = env.home.path
        for candidate in HostEntry.tmuxSearchPaths {
            let path = candidate.replacingOccurrences(of: "$HOME", with: home)
            if FileManager.default.isExecutableFile(atPath: path) {
                return Check(id: "tmux", status: .ok, message: "tmux があります（\(path)）")
            }
        }
        // 一覧に無い場所は、アプリと同じくログインシェルの PATH で探す
        let r = ok("/bin/zsh", ["-lc", "command -v tmux"])
        if r.status == 0 {
            // ログインシェルが前置きの行を出すことがあるので、最後の行を取る
            let path = r.stdout.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if path.hasPrefix("/") { return Check(id: "tmux", status: .ok, message: "tmux があります（\(path)）") }
        }
        return Check(id: "tmux", status: .warn, message: "tmux がありません（切れたら作業が消えます）", fix: "brew install tmux")
    }

    func remoteLogin() -> Check {
        let r = ok("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", "22"])
        if r.status == 0 { return Check(id: "remote-login", status: .ok, message: "SSH（リモートログイン）が動いています") }
        return Check(id: "remote-login", status: .fail, message: "SSH（リモートログイン）が動いていません",
                     fix: "システム設定 > 一般 > 共有 >「リモートログイン」をオンにする", needsHuman: true)
    }

    func device() -> Check {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("splitterm-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = ok("/usr/bin/xcrun", ["devicectl", "list", "devices", "--timeout", "30", "--json-output", tmp.path])
        guard r.status == 0, let data = try? Data(contentsOf: tmp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            return Check(id: "device", status: .fail, message: "端末の一覧を取れません", fix: "Xcode を一度開く")
        }
        let paired = devices.filter { d in
            let props = d["properties"] as? [String: Any] ?? [:]
            let hw = props["hardware"] as? [String: Any] ?? d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = props["connection"] as? [String: Any] ?? d["connectionProperties"] as? [String: Any] ?? [:]
            return hw["platform"] as? String == "iOS" && hw["reality"] as? String == "physical"
                && conn["pairingState"] as? String == "paired"
        }
        switch paired.count {
        case 1: return Check(id: "device", status: .ok, message: "Mac と対になった端末が 1 台あります")
        case 0:
            return Check(id: "device", status: .fail, message: "Mac と対になった端末がありません",
                         fix: "iPhone・iPad を USB でつないで「信頼」し、設定 > プライバシーとセキュリティ > デベロッパモードをオンにする",
                         needsHuman: true)
        default:
            return Check(id: "device", status: .warn, message: "端末が \(paired.count) 台あります",
                         fix: "SPLITTERM_IOS_DEVICE で UDID を選ぶ")
        }
    }

    func config() -> Check {
        guard let text = try? String(contentsOf: env.configURL, encoding: .utf8) else {
            return Check(id: "config", status: .fail, message: "config がありません（\(env.configURL.path)）",
                         fix: "splitterm config init")
        }
        let (c, d) = ConfigParser.parse(text)
        if !d.isEmpty {
            return Check(id: "config", status: .fail, message: "読めない行が \(d.count) 行あります", fix: "splitterm config check")
        }
        if c.hosts.isEmpty {
            return Check(id: "config", status: .warn, message: "接続先（host）がありません",
                         fix: "splitterm host add mac あなた@この Mac の名前")
        }
        return Check(id: "config", status: .ok, message: "config は読めます（接続先 \(c.hosts.count) つ）")
    }

    func app() -> Check {
        let s = Commands(env: env).status()
        if s.exitCode == 0 { return Check(id: "app", status: .ok, message: "アプリが入っています（\(s.output.replacingOccurrences(of: "\n", with: "、"))）") }
        return Check(id: "app", status: .warn, message: "アプリの記録がありません", fix: "splitterm install")
    }

    func authorizedKey() -> Check {
        let url = env.home.appendingPathComponent(".ssh/authorized_keys")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.split(separator: "\n").contains(where: { $0.hasSuffix(" splitterm") }) {
            return Check(id: "pubkey", status: .ok, message: "アプリの公開鍵が authorized_keys にあります")
        }
        return Check(id: "pubkey", status: .warn, message: "アプリの公開鍵が authorized_keys にありません",
                     fix: "アプリの ＋ →「公開鍵をコピー」に出た指紋で splitterm pubkey --fingerprint SHA256:…", needsHuman: true)
    }
}
