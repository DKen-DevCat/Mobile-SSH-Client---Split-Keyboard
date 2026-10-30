import Foundation
import XCTest
@testable import TermCore

/// 接続後に実行するコマンド（tmux を確実に見つけて、タブごとのセッションへ入る）
final class StartupCommandTests: XCTestCase {
    private let mac = HostEntry(name: "mac", user: "me", address: "mac.example")

    /// 1 番のタブの、生成される 1 行そのもの。引用符の入れ子が崩れたら、ここで差が出る
    private let expectedSlot1 = #"exec /bin/sh -c 't=; for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux "$HOME/.nix-profile/bin/tmux" /run/current-system/sw/bin/tmux /usr/bin/tmux; do if [ -x "$p" ]; then t=$p; break; fi; done; if [ -z "$t" ]; then t=$("$SHELL" -lc "command -v tmux" 2>/dev/null | tail -n 1); [ -x "$t" ] || t=; fi; if [ -n "$t" ]; then exec "$SHELL" -lc "exec \"$t\" -u new-session -A -s main"; fi; echo "tmux が見つかりません（Mac で brew install tmux を入れると、切れても作業が残ります）。素のシェルを開きます"; exec "$SHELL" -l'"#

    func testSessionNamePerSlot() {
        XCTAssertEqual(mac.tmuxSessionName(slot: 1), "main")
        XCTAssertEqual(mac.tmuxSessionName(slot: 2), "main-2")
        XCTAssertEqual(mac.tmuxSessionName(slot: 10), "main-10")
        // 範囲外は 1 番と同じ
        XCTAssertEqual(mac.tmuxSessionName(slot: 0), "main")
        var work = mac
        work.tmuxSession = "work.x_y"
        XCTAssertEqual(work.tmuxSessionName(slot: 1), "work.x_y")
        XCTAssertEqual(work.tmuxSessionName(slot: 3), "work.x_y-3")
        var none = mac
        none.tmuxSession = nil
        XCTAssertNil(none.tmuxSessionName(slot: 1))
        XCTAssertNil(none.tmuxSessionName(slot: 2))
    }

    func testNoTmuxMeansPlainShell() {
        var none = mac
        none.tmuxSession = nil
        XCTAssertNil(none.startupCommand(slot: 1))
        XCTAssertNil(none.startupCommand(slot: 2))
    }

    func testExactCommand() {
        XCTAssertEqual(mac.startupCommand(slot: 1), expectedSlot1)
        // 2 番からは、セッション名だけが変わる
        XCTAssertEqual(mac.startupCommand(slot: 2),
                       expectedSlot1.replacingOccurrences(of: "-A -s main\"", with: "-A -s main-2\""))
    }

    func testContainsEveryCandidateInOrderAndTheName() throws {
        XCTAssertEqual(HostEntry.tmuxSearchPaths, [
            "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux",
            "$HOME/.nix-profile/bin/tmux", "/run/current-system/sw/bin/tmux", "/usr/bin/tmux",
        ])
        let cmd = try XCTUnwrap(mac.startupCommand(slot: 1))
        var from = cmd.startIndex
        for path in HostEntry.tmuxSearchPaths {
            // $HOME を含む候補は二重引用符で囲む（接続先の sh が展開する）
            let word = path.contains("$") ? "\"" + path + "\"" : path
            let r = try XCTUnwrap(cmd.range(of: word, range: from..<cmd.endIndex), path)
            from = r.upperBound
        }
        XCTAssertTrue(cmd.contains("new-session -A -s main\""))
        let third = try XCTUnwrap(mac.startupCommand(slot: 3))
        XCTAssertTrue(third.contains("new-session -A -s main-3\""))
        // 見つからないときの文言
        XCTAssertTrue(cmd.contains("tmux が見つかりません（Mac で brew install tmux を入れると、切れても作業が残ります）。素のシェルを開きます"))
    }

    /// 外側の単一引用符は 1 組だけ（sshd がログインシェルの -c に渡す 1 行。中に単一引用符があると崩れる）
    func testOuterSingleQuotesAreBalanced() throws {
        for slot in [1, 2, 9] {
            let cmd = try XCTUnwrap(mac.startupCommand(slot: slot))
            XCTAssertEqual(cmd.filter { $0 == "'" }.count, 2)
            XCTAssertTrue(cmd.hasPrefix("exec /bin/sh -c '"))
            XCTAssertTrue(cmd.hasSuffix("'"))
            XCTAssertFalse(cmd.contains("\n"))
        }
    }

#if os(macOS)
    // MARK: Mac の /bin/sh で確かめる

    /// 文法だけ（`sh -n` は実行しない）。外側の 1 行も、中のスクリプトも
    func testShellAcceptsTheSyntax() throws {
        let prefix = "exec /bin/sh -c '"
        for slot in [1, 2] {
            let cmd = try XCTUnwrap(mac.startupCommand(slot: slot))
            XCTAssertEqual(try runSh(["-n", "-c", cmd]).status, 0)
            let inner = String(cmd.dropFirst(prefix.count).dropLast())
            XCTAssertEqual(try runSh(["-n", "-c", inner]).status, 0)
        }
    }

    /// 決まった場所に本物の tmux があるときは、結果が変わるので流さない
    private func skipIfRealTmuxInFixedPlaces() throws {
        let fixed = HostEntry.tmuxSearchPaths.filter { !$0.contains("$") }
        let exists = fixed.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
        try XCTSkipIf(exists, "決まった場所に tmux があるので、見つからない場合を作れない")
    }

    func testRunsTheTmuxUnderHome() throws {
        try skipIfRealTmuxInFixedPlaces()
        let home = try TempHome()
        _ = try home.write(".nix-profile/bin/tmux", "#!/bin/sh\necho FAKE-TMUX \"$@\"\n")
        let out = try runSh(["-c", try XCTUnwrap(mac.startupCommand(slot: 2))],
                            environment: ["HOME": home.url.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("FAKE-TMUX -u new-session -A -s main-2"), out.stdout)
    }

    func testAsksTheLoginShellWhenNotInTheList() throws {
        try skipIfRealTmuxInFixedPlaces()
        let home = try TempHome()
        let odd = try home.write("odd/tmux", "#!/bin/sh\necho ODD-TMUX \"$@\"\n")
        // ログインシェル役: `command -v tmux` には前置きの行つきで場所を答え、ほかはそのまま実行する
        let shell = try home.write("fakesh", "#!/bin/sh\ncase \"$2\" in\n\"command -v tmux\") echo motd; echo \"\(odd)\" ;;\n*) eval \"$2\" ;;\nesac\n")
        let out = try runSh(["-c", try XCTUnwrap(mac.startupCommand(slot: 1))],
                            environment: ["HOME": home.url.path, "SHELL": shell, "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("ODD-TMUX -u new-session -A -s main"), out.stdout)
    }

    func testFallsBackToThePlainShell() throws {
        try skipIfRealTmuxInFixedPlaces()
        let home = try TempHome()
        let shell = try home.write("fakesh", "#!/bin/sh\ncase \"$1\" in -lc) exit 1;; esac\necho PLAIN-SHELL \"$@\"\n")
        let out = try runSh(["-c", try XCTUnwrap(mac.startupCommand(slot: 1))],
                            environment: ["HOME": home.url.path, "SHELL": shell, "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("tmux が見つかりません"), out.stdout)
        XCTAssertTrue(out.stdout.contains("PLAIN-SHELL -l"), out.stdout)
    }

    private func runSh(_ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 一時フォルダ（HOME の代わり）。使い終わったら消す
    private final class TempHome {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("startup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        /// 実行できるファイルを書き、そのパスを返す
        func write(_ relative: String, _ text: String) throws -> String {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
    }
#endif
}
