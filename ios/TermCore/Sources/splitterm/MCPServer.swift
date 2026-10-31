import Foundation
import TermCore

/// MCP サーバー（stdio、1 行に 1 つの JSON-RPC）。ネットには出ない。道具は Commands をそのまま呼ぶ。
/// 標準出力には JSON-RPC だけを書き、ほかの表示は標準エラーへ
struct MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    var commands: Commands
    var doctor: Doctor

    struct Tool {
        var name: String
        var description: String
        var properties: [String: [String: Any]]
        var required: [String]
        var call: ([String: Any]) -> CommandResult
    }

    var tools: [Tool] {
        let c = commands
        // 道具が触るのは決まった config だけ（SPLITTERM_CONFIG か ~/.config/splitterm/config）。
        // ファイルの場所は受け取らない（ほかのファイルを読み書きする道にしない。CLI の --file は人が使う）
        return [
            Tool(name: "doctor",
                 description: "準備（Xcode・無料の Team・jq・tmux・リモートログイン・端末・config・アプリ・公開鍵）を調べ、足りないものと直し方を返す。needs_human の項目は人に頼む",
                 properties: [:], required: []) { _ in doctor.report() },
            Tool(name: "config_show", description: "今効いている config の値（既定値を含む）と、読めない行",
                 properties: [:], required: []) { _ in c.configShow(file: nil) },
            Tool(name: "config_check", description: "config の読めない行を行番号付きで返す。問題が無ければ成功",
                 properties: [:], required: []) { _ in c.configCheck(file: nil) },
            Tool(name: "config_set",
                 description: "config の 1 項目を書き換える（コメントと並びは残る）。書いた後に読み直し、読めなくなる書き換えは断る。値を空にすると既定値。host は host_add / host_remove を使う",
                 properties: ["key": ["type": "string", "description": "項目（例 font-size）"],
                              "value": ["type": "string", "description": "値（例 12）"]],
                 required: ["key", "value"]) { a in
                c.configSet(key: a["key"] as? String ?? "", value: a["value"] as? String ?? "", file: nil)
            },
            Tool(name: "host_add", description: "接続先を足す（同じ名前があれば断る）",
                 properties: ["name": ["type": "string", "description": "名前（英数と . _ -）"],
                              "user": ["type": "string"], "address": ["type": "string", "description": "ホスト名か IP"],
                              "port": ["type": "integer", "description": "既定 22"],
                              "tmux": ["type": "string", "description": "tmux のセッション名。none で素のシェル。既定 main"],
                              "auth": ["type": "string", "enum": ["key", "password"]]],
                 required: ["name", "user", "address"]) { a in
                let tmux = a["tmux"] as? String ?? "main"
                let entry = HostEntry(name: a["name"] as? String ?? "", user: a["user"] as? String ?? "",
                                      address: a["address"] as? String ?? "", port: a["port"] as? Int ?? 22,
                                      tmuxSession: tmux == "none" ? nil : tmux,
                                      auth: HostEntry.AuthKind(rawValue: a["auth"] as? String ?? "key") ?? .key)
                return c.hostAdd(entry, file: nil)
            },
            Tool(name: "host_remove", description: "接続先を消す",
                 properties: ["name": ["type": "string"]], required: ["name"]) { a in
                c.hostRemove(a["name"] as? String ?? "", file: nil)
            },
            Tool(name: "config_push", description: "config を端末へ送る（読めない行があれば送らない）。アプリは開いていればすぐ読み直す",
                 properties: [:], required: []) { _ in c.push() },
            Tool(name: "pubkey_install",
                 description: "端末のアプリの公開鍵を、この Mac の ~/.ssh/authorized_keys に足す（restrict,pty 付き）。アプリの ＋ を長押し →「公開鍵をコピー」に出た指紋を人から聞いて渡す。指紋が違えば足さない",
                 properties: ["fingerprint": ["type": "string", "description": "SHA256:… の形"]],
                 required: ["fingerprint"]) { a in c.pubkey(fingerprint: a["fingerprint"] as? String ?? "") },
            Tool(name: "app_install",
                 description: "アプリを作り直して端末へ入れる（無料の署名、数分かかる）。初回は端末で開発元を信頼する手間が要る",
                 properties: ["force": ["type": "boolean", "description": "メモリの圧迫を見ない"]], required: []) { a in
                c.install(force: a["force"] as? Bool ?? false)
            },
            Tool(name: "app_status", description: "入れたアプリの期限（7 日）・残り時間・ビルド",
                 properties: [:], required: []) { _ in c.status() },
            Tool(name: "inbox_list",
                 description: "端末から送られたメディア（写真・動画・音声・動画のコンタクトシートと添え書き）の一覧。新しい順。種類・時刻・バイト数・パス",
                 properties: ["limit": ["type": "integer", "description": "既定 20"]], required: []) { a in
                c.inboxList(limit: a["limit"] as? Int ?? 20)
            },
            Tool(name: "inbox_clean", description: "受け取り箱の古いものを消す（既定は config の media-retention）",
                 properties: ["days": ["type": "integer"]], required: []) { a in c.inboxClean(days: a["days"] as? Int) },
            Tool(name: "theme_import",
                 description: "Mac の Ghostty が実際に使っている配色（背景・文字・カーソル・選択・パレット 0〜15・minimum-contrast・bold-is-bright・font-thicken・色空間）を config に書く（コメントと並びは残る）。dry_run が true なら、書き換える内容と警告を返すだけで何も書かない。明暗 2 つのテーマは暗い方。端末へは config_push で送る。Ghostty が無ければ、直し方つきのエラー",
                 properties: ["dry_run": ["type": "boolean", "description": "true なら書き換えない（既定 false）"]],
                 required: []) { a in
                c.themeImport(dryRun: a["dry_run"] as? Bool ?? false, file: nil)
            },
        ]
    }

    // MARK: JSON-RPC

    /// 1 行の上限（config の道具に大きな入力は要らない。読んだ後に比べるので、メモリの上限ではなく、大きすぎる要求を断る印）
    static let maxLine = 1 << 20

    /// 1 行の要求に答える。通知（id が無い）には nil
    func handle(line: String) -> String? {
        guard line.utf8.count <= Self.maxLine, let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let method = msg["method"] as? String else {
            // 応答（こちらからは要求を出さないので、来ても捨てる）。それ以外の形は不正な要求
            if msg["result"] != nil || msg["error"] != nil { return nil }
            return encode(["jsonrpc": "2.0", "id": msg["id"] ?? NSNull(),
                           "error": ["code": -32600, "message": "invalid request"]])
        }
        guard let id = msg["id"] else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            return reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "splitterm", "title": "Mobile-SSH-Client---Split-Keyboard", "version": "0.1"],
                "instructions": "Mobile-SSH-Client---Split-Keyboard（iPhone・iPad の横持ち SSH ターミナル）の設定と運用。まず doctor を呼び、needs_human の項目は人に頼む。手順は Get Started（get-started.md）にある",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": tools.map { t in
                [
                    "name": t.name,
                    "description": t.description,
                    "inputSchema": ["type": "object", "properties": t.properties, "required": t.required,
                                    "additionalProperties": false] as [String: Any],
                ] as [String: Any]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return error(id, -32602, "知らない道具です")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            if let missing = tool.required.first(where: { args[$0] == nil }) {
                return reply(id, toolResult(.fail("\(missing) が要ります")))
            }
            return reply(id, toolResult(tool.call(args)))
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    func toolResult(_ r: CommandResult) -> [String: Any] {
        var text = r.output
        if r.needsHuman { text += "\n\nneeds_human: 人の手が要る段があります。上の直し方を人に頼んでください" }
        return ["content": [["type": "text", "text": text]], "isError": r.exitCode != 0]
    }

    func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func error(_ id: Any, _ code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func encode(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: d, as: UTF8.self)
    }

    /// 標準入力から 1 行ずつ読み、答えを標準出力へ
    func serve() {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let out = handle(line: line) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
    }
}
