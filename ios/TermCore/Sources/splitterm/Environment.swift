import Foundation
import TermCore

/// コマンドが触る場所（config・リポジトリ・受け取り箱）と、外のプログラムの起動。
/// テストでは場所と起動を差し替える
struct Environment {
    var configURL: URL
    /// リポジトリの根（scripts/ がある所）。見つからなければ nil（端末に触る道具だけが使えない）
    var repoRoot: URL?
    var home: URL
    var run: (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessResult
    var now: () -> Date = Date.init
    /// Ghostty.app の場所（`theme import` が実行ファイルとテーマを探す）
    var ghosttyApp = URL(fileURLWithPath: "/Applications/Ghostty.app")
    /// `ghostty` を探す PATH の並び（絶対パスのフォルダ）。テストでは空にして、実機の Ghostty を見ない
    var searchPath: [String] = []
    /// `$XDG_CONFIG_HOME`（Ghostty の config の置き場所）。無ければ nil
    var xdgConfigHome: String? = nil

    static func live() -> Environment {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
        let config = env["SPLITTERM_CONFIG"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".config/splitterm/config")
        return Environment(configURL: config, repoRoot: findRepoRoot(env), home: home, run: ProcessRunner.run,
                           searchPath: (env["PATH"] ?? "").split(separator: ":").map(String.init),
                           xdgConfigHome: env["XDG_CONFIG_HOME"])
    }

    /// SPLITTERM_REPO、なければ実行ファイルの場所から上へ、scripts/ios_reinstall.sh がある所を探す
    static func findRepoRoot(_ env: [String: String]) -> URL? {
        if let r = env["SPLITTERM_REPO"] { return URL(fileURLWithPath: (r as NSString).expandingTildeInPath) }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/ios_reinstall.sh").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func script(_ name: String) -> URL? {
        repoRoot?.appendingPathComponent("scripts").appendingPathComponent(name)
    }

    /// config の media-dir（接続先の受け取り箱）を、この Mac の場所に直す（接続先がこの Mac のとき）
    func inboxURL(_ config: TermConfig) -> URL {
        let d = config.mediaDir
        if d.hasPrefix("~/") { return home.appendingPathComponent(String(d.dropFirst(2))) }
        return URL(fileURLWithPath: d)
    }
}

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
}

/// 外のプログラムを、シェルを通さずに起動する（引数はそのまま渡す。人が入れた文字がシェルに解釈されない）
enum ProcessRunner {
    /// 読み取りのスレッドが書く入れ物（ロックで守る）
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // 出力が大きくてもパイプが詰まらないよう、読みながら待つ
        let outData = Output(), errData = Output()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            let reader = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global().async {
                box.set(reader.readDataToEndOfFile())
                group.leave()
            }
        }
        // 終わりの知らせは起動の前に付ける（すぐ終わるプログラムで知らせを取りこぼさない）
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            return ProcessResult(status: 127, stdout: "", stderr: "\(executable) を起動できません: \(error.localizedDescription)")
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        // 時間切れのときは、孫のプロセス（xcodebuild など）がパイプを持ったままのことがある。待ちすぎない
        // （読み取りのスレッドは孫が終わるまで残るが、MCP サーバーは次の要求を受けられる）
        if group.wait(timeout: .now() + (timedOut ? 5 : 3600)) == .timedOut {
            return ProcessResult(status: p.terminationStatus, stdout: "",
                                 stderr: "\(executable) の子のプロセスが出力を閉じませんでした", timedOut: true)
        }
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(decoding: outData.get(), as: UTF8.self),
                             stderr: String(decoding: errData.get(), as: UTF8.self),
                             timedOut: timedOut)
    }
}
