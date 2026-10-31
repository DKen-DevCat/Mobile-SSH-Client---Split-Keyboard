import Foundation
import TermCore

/// splitterm の引数を読んで、Commands を呼ぶ
enum CLI {
    static let usage = """
    splitterm — Mobile-SSH-Client---Split-Keyboard の設定と運用（Mac で動く）

      splitterm config path                 config の場所
      splitterm config init                 見本から config を作る
      splitterm config check [--file F]     読めない行を出す（無ければ 0 で終わる）
      splitterm config show [--file F]      今効いている値（既定値を含む）
      splitterm config set KEY VALUE [--file F]
                                            1 項目を書き換える（コメントは残る。値を "" にすると既定値）
      splitterm host add NAME USER@ADDR[:PORT] [--tmux NAME|none] [--auth key|password] [--file F]
      splitterm host remove NAME [--file F]
      splitterm theme import [--dry-run] [--file F]
                                            Mac の Ghostty の配色を config に取り込む（--dry-run は書き換える内容を出すだけ）
      splitterm push                        config を端末へ送る
      splitterm pubkey --fingerprint SHA256:...
                                            端末の公開鍵を authorized_keys に足す（アプリに出た指紋が要る）
      splitterm install [--force]           アプリを作り直して端末へ入れる
      splitterm status                      入れたアプリの期限
      splitterm doctor                      準備がそろっているか
      splitterm inbox list [--limit N]      端末から届いたメディア（新しい順）
      splitterm inbox clean [--days N]      受け取り箱の古いものを消す
      splitterm mcp                         MCP サーバー（stdio）として動く

    環境変数: SPLITTERM_CONFIG（config の場所）、SPLITTERM_REPO（リポジトリの場所。ふつうは自動で見つける）
    """

    struct ArgError: Error { var message: String }

    /// 引数から `--name value` を抜き出す
    static func option(_ name: String, in args: inout [String]) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw ArgError(message: "\(name) には値が要ります") }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    static func flag(_ name: String, in args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    static func fileURL(_ s: String?) -> URL? {
        s.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// 1 回のコマンド。mcp は呼んだ側で扱う
    static func run(_ argv: [String], env: Environment) -> CommandResult {
        let c = Commands(env: env)
        var args = argv
        do {
            let file = fileURL(try option("--file", in: &args))
            switch (args.first, args.dropFirst().first) {
            case ("config", "path"): return c.configPath()
            case ("config", "init"): return c.configInit()
            case ("config", "check"): return c.configCheck(file: file)
            case ("config", "show"): return c.configShow(file: file)
            case ("config", "set"):
                guard args.count == 4 else { throw ArgError(message: "config set KEY VALUE") }
                return c.configSet(key: args[2], value: args[3], file: file)
            case ("host", "add"):
                let tmux = try option("--tmux", in: &args) ?? "main"
                let auth = try option("--auth", in: &args) ?? "key"
                guard args.count == 4 else { throw ArgError(message: "host add NAME USER@ADDR[:PORT]") }
                // config と同じ規則で読む（名前・アドレス・ポートの検査を 1 か所に）
                var line = "host = \(args[2]) \(args[3])"
                if tmux != "main" { line += " tmux=\(tmux)" }
                if auth != "key" { line += " auth=\(auth)" }
                let (parsed, d) = ConfigParser.parse(line)
                guard d.isEmpty, let entry = parsed.hosts.first else {
                    throw ArgError(message: d.first?.message ?? "host を読めません")
                }
                return c.hostAdd(entry, file: file)
            case ("host", "remove"):
                guard args.count == 3 else { throw ArgError(message: "host remove NAME") }
                return c.hostRemove(args[2], file: file)
            case ("theme", "import"):
                let dryRun = flag("--dry-run", in: &args)
                guard args.count == 2 else { throw ArgError(message: "theme import [--dry-run]") }
                return c.themeImport(dryRun: dryRun, file: file)
            case ("push", _): return c.push()
            case ("pubkey", _):
                guard let fp = try option("--fingerprint", in: &args) else {
                    throw ArgError(message: "--fingerprint にアプリの ＋ を長押し →「公開鍵をコピー」に出た指紋を渡してください")
                }
                return c.pubkey(fingerprint: fp)
            case ("install", _): return c.install(force: flag("--force", in: &args))
            case ("status", _): return c.status()
            case ("doctor", _): return Doctor(env: env).report()
            case ("inbox", "list"):
                let limit = try option("--limit", in: &args).map { s -> Int in
                    guard let n = Int(s), n > 0 else { throw ArgError(message: "--limit は 1 以上の整数") }
                    return n
                } ?? 20
                return c.inboxList(limit: limit)
            case ("inbox", "clean"):
                let days = try option("--days", in: &args).map { s -> Int in
                    guard let n = Int(s), n >= 0 else { throw ArgError(message: "--days は 0 以上の整数") }
                    return n
                }
                return c.inboxClean(days: days)
            case (nil, _), ("help", _), ("-h", _), ("--help", _):
                return .ok(usage)
            default:
                throw ArgError(message: "知らないコマンドです: \(argv.joined(separator: " "))")
            }
        } catch let e as ArgError {
            return .fail("\(e.message)\n\n\(usage)", code: 2)
        } catch {
            return .fail("\(error)", code: 2)
        }
    }
}
