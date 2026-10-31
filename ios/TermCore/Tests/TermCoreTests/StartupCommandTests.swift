import Foundation
import XCTest
@testable import TermCore

/// 接続後に実行するコマンド（tmux を確実に見つけて、タブごとのセッションへ入る）
final class StartupCommandTests: XCTestCase {
    private let mac = HostEntry(name: "mac", user: "me", address: "mac.example")

    /// 1 番のタブの、生成される 1 行そのもの。引用符の入れ子が崩れたら、ここで差が出る
    private let expectedSlot1 = #"exec /bin/sh -c 't=; for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux "$HOME/.nix-profile/bin/tmux" /run/current-system/sw/bin/tmux /usr/bin/tmux; do if [ -x "$p" ]; then t=$p; break; fi; done; if [ -z "$t" ]; then t=$("$SHELL" -lc "command -v tmux" 2>/dev/null | tail -n 1); [ -x "$t" ] || t=; fi; if [ -n "$t" ]; then if "$t" -T RGB -V >/dev/null 2>&1; then exec "$SHELL" -lc "exec env COLORTERM=truecolor \"$t\" -u -T RGB new-session -A -e COLORTERM=truecolor -s main"; fi; exec "$SHELL" -lc "exec env COLORTERM=truecolor \"$t\" -u new-session -A -s main"; fi; echo "tmux が見つかりません（Mac で brew install tmux を入れると、切れても作業が残ります）。素のシェルを開きます"; exec "$SHELL" -l'"#

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
        // 2 番からは、セッション名だけが変わる（tmux 3.2 以上の起動と、3.2 未満の起動の 2 か所）
        XCTAssertEqual(mac.startupCommand(slot: 2),
                       expectedSlot1.replacingOccurrences(of: "-s main\"", with: "-s main-2\""))
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
        XCTAssertTrue(cmd.contains("new-session -A -e COLORTERM=truecolor -s main\""))
        let third = try XCTUnwrap(mac.startupCommand(slot: 3))
        XCTAssertTrue(third.contains("new-session -A -s main-3\""))
        XCTAssertTrue(third.contains("new-session -A -e COLORTERM=truecolor -s main-3\""))
        // 見つからないときの文言
        XCTAssertTrue(cmd.contains("tmux が見つかりません（Mac で brew install tmux を入れると、切れても作業が残ります）。素のシェルを開きます"))
    }

    // MARK: true color を tmux の中まで届ける（docs/design.md「色」①）

    /// tmux 3.2 以上かを試す `if "$t" -T RGB -V …; then … fi;` の、then と fi の間
    private func versionBranch(_ cmd: String) throws -> String {
        let probe = #"if "$t" -T RGB -V >/dev/null 2>&1; then "#
        let open = try XCTUnwrap(cmd.range(of: probe), "3.2 以上の判定が無い")
        let close = try XCTUnwrap(cmd.range(of: "; fi; ", range: open.upperBound..<cmd.endIndex), "判定の終わりが無い")
        return String(cmd[open.upperBound..<close.lowerBound])
    }

    /// どの起動でも、tmux のクライアントに COLORTERM=truecolor を渡す（ログインシェルの設定の後、tmux の直前で `env` が付ける）
    func testEveryLaunchPassesColortermToTheTmuxClient() throws {
        for slot in [1, 2, 9] {
            let cmd = try XCTUnwrap(mac.startupCommand(slot: slot))
            let launches = cmd.components(separatedBy: "exec \"$SHELL\" -lc \"").dropFirst()
            // tmux を起動するログインシェルの呼び出しは 2 つ（3.2 以上と、3.2 未満）
            XCTAssertEqual(launches.count, 2)
            for launch in launches {
                XCTAssertTrue(launch.hasPrefix(#"exec env COLORTERM=truecolor \"$t\" -u "#), launch)
            }
        }
    }

    /// `-T RGB` と `-e COLORTERM=truecolor` は、tmux 3.2 以上と分かった枝の中だけにある。
    /// 判定そのもの（`-T RGB -V`）を除けば、枝の外に -T も -e も無い
    func testRgbFeatureAndEnvironmentAreOnlyInsideTheVersionCheck() throws {
        for slot in [1, 2] {
            let cmd = try XCTUnwrap(mac.startupCommand(slot: slot))
            let branch = try versionBranch(cmd)
            XCTAssertTrue(branch.contains("-u -T RGB new-session -A -e COLORTERM=truecolor -s main"), branch)
            XCTAssertEqual(branch.components(separatedBy: "-T RGB").count - 1, 1)
            XCTAssertEqual(branch.components(separatedBy: "-e COLORTERM=truecolor").count - 1, 1)

            // 判定と枝を取り除いた残りは、今までどおりの起動（256 色）。-T も -e も無い
            let probe = #"if "$t" -T RGB -V >/dev/null 2>&1; then "#
            let rest = cmd.replacingOccurrences(of: probe + branch + "; fi; ", with: "")
            XCTAssertFalse(rest.contains("-T"), rest)
            XCTAssertFalse(rest.contains(" -e "), rest)
            XCTAssertTrue(rest.contains(#"\"$t\" -u new-session -A -s main"#), rest)
            // 全体で -T RGB は判定と枝の 2 か所、-e COLORTERM=truecolor は枝の 1 か所
            XCTAssertEqual(cmd.components(separatedBy: "-T RGB").count - 1, 2)
            XCTAssertEqual(cmd.components(separatedBy: "-e COLORTERM=truecolor").count - 1, 1)
        }
    }

    /// 判定は tmux に実際に試させる（3.2 未満は -T を知らず、使い方を出して失敗する）。出力は捨てる。サーバーには触らない（-V）
    func testVersionIsTestedByRunningTmux() throws {
        let cmd = try XCTUnwrap(mac.startupCommand(slot: 1))
        XCTAssertTrue(cmd.contains(#"if "$t" -T RGB -V >/dev/null 2>&1; then "#))
        // 判定は tmux の場所が決まった後（見つからないときの文言より前）
        let probe = try XCTUnwrap(cmd.range(of: "-T RGB -V"))
        let found = try XCTUnwrap(cmd.range(of: #"if [ -n "$t" ]; then "#))
        let notFound = try XCTUnwrap(cmd.range(of: "tmux が見つかりません"))
        XCTAssertLessThan(found.lowerBound, probe.lowerBound)
        XCTAssertLessThan(probe.lowerBound, notFound.lowerBound)
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

    /// tmux の代わり。引数と COLORTERM を出す。`-V` は版を答えて終わる（本物と同じ）。
    /// 古い版（3.2 未満）は `-T` を知らず、使い方を出して失敗する
    private func fakeTmux(newVersion: Bool) -> String {
        let old = newVersion ? "" : "case \"$1\" in -T) echo \"usage: tmux\" >&2; exit 1;; esac\n"
        return "#!/bin/sh\n" + old + "case \"$*\" in *-V*) echo \"tmux 3.5\"; exit 0;; esac\n"
            + "echo \"FAKE-TMUX $* COLORTERM=$COLORTERM\"\n"
    }

    /// 3.2 以上: COLORTERM を渡し、-T RGB と -e COLORTERM=truecolor を付けて起動する
    func testRunsTheTmuxUnderHome() throws {
        try skipIfRealTmuxInFixedPlaces()
        let home = try TempHome()
        _ = try home.write(".nix-profile/bin/tmux", fakeTmux(newVersion: true))
        let out = try runSh(["-c", try XCTUnwrap(mac.startupCommand(slot: 2))],
                            environment: ["HOME": home.url.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("FAKE-TMUX -u -T RGB new-session -A -e COLORTERM=truecolor -s main-2 COLORTERM=truecolor"),
                      out.stdout)
    }

    /// 3.2 未満: -T を断られるので、-T RGB も -e も付けない。COLORTERM は渡す（tmux のクライアントの環境）
    func testOldTmuxIsStartedWithoutRgbFeatureAndSessionEnvironment() throws {
        try skipIfRealTmuxInFixedPlaces()
        let home = try TempHome()
        _ = try home.write(".nix-profile/bin/tmux", fakeTmux(newVersion: false))
        let out = try runSh(["-c", try XCTUnwrap(mac.startupCommand(slot: 1))],
                            environment: ["HOME": home.url.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("FAKE-TMUX -u new-session -A -s main COLORTERM=truecolor"), out.stdout)
        // 目印の FAKE-TMUX に "-T" が入っているので、前後の空白つきで見る
        XCTAssertFalse(out.stdout.contains(" -T "), out.stdout)
        XCTAssertFalse(out.stdout.contains(" -e "), out.stdout)
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
        XCTAssertTrue(out.stdout.contains("ODD-TMUX -u -T RGB new-session -A -e COLORTERM=truecolor -s main"), out.stdout)
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
