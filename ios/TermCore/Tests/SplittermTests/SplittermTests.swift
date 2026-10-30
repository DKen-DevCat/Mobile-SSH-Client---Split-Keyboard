import Foundation
import XCTest
@testable import splitterm
@testable import TermCore

/// 一時フォルダのリポジトリと HOME で動かす。外のプログラムは起動せず、呼ばれた引数を記録する
final class Rig {
    let root: URL
    let repo: URL
    let home: URL
    var calls: [(String, [String])] = []
    var reply = ProcessResult(status: 0, stdout: "ok", stderr: "")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("splitterm-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        home = root.appendingPathComponent("home")
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("ios/SplitTerm/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for s in ["ios_reinstall.sh", "ios_push_config.sh", "ios_pubkey.sh"] {
            try "#!/bin/bash\n".write(to: repo.appendingPathComponent("scripts/\(s)"), atomically: true, encoding: .utf8)
        }
        try "# 見本\n# font-size = 10\n# host = mac me@mac\n".write(
            to: repo.appendingPathComponent("ios/SplitTerm/Resources/config.example"), atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var env: Environment {
        Environment(configURL: home.appendingPathComponent(".config/splitterm/config"), repoRoot: repo, home: home,
                    run: { [unowned self] exe, args, _ in
                        self.calls.append((exe, args))
                        return self.reply
                    },
                    now: { Date(timeIntervalSince1970: 1_793_340_000) })
    }

    func run(_ args: String...) -> CommandResult { CLI.run(args, env: env) }

    var config: String { (try? String(contentsOf: env.configURL, encoding: .utf8)) ?? "" }
}

final class CLITests: XCTestCase {
    func testInitThenEditTheConfig() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.run("config", "check").exitCode, 1)  // まだ無い
        XCTAssertEqual(rig.run("config", "init").exitCode, 0)
        XCTAssertEqual(rig.run("config", "set", "font-size", "12").exitCode, 0)
        XCTAssertEqual(rig.run("host", "add", "mac", "me@mac.example.ts.net").exitCode, 0)
        XCTAssertEqual(rig.config, "# 見本\n# font-size = 10\nfont-size = 12\n# host = mac me@mac\nhost = mac me@mac.example.ts.net\n")
        XCTAssertEqual(rig.run("config", "check").exitCode, 0)
        let show = rig.run("config", "show")
        XCTAssertTrue(show.output.contains("font-size = 12"))
        XCTAssertTrue(show.output.contains("host = mac me@mac.example.ts.net"))
        XCTAssertEqual(rig.run("host", "remove", "mac").exitCode, 0)
        // 見本のコメント（# host = mac me@mac）は残り、効いている行だけが消える
        XCTAssertFalse(rig.config.contains("\nhost = mac me@"))
        XCTAssertTrue(rig.config.contains("# host = mac me@mac"))
    }

    func testRefusedEditsLeaveTheFileAlone() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        let before = rig.config
        XCTAssertEqual(rig.run("config", "set", "font-size", "huge").exitCode, 1)
        XCTAssertEqual(rig.run("config", "set", "media-dir", "~/$(id)").exitCode, 1)
        XCTAssertEqual(rig.run("host", "add", "bad name", "u@h").exitCode, 2)
        XCTAssertEqual(rig.run("host", "add", "x", "u@h", "--tmux", "a;b").exitCode, 2)
        XCTAssertEqual(rig.config, before)
    }

    func testHostAddOptions() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        XCTAssertEqual(rig.run("host", "add", "pi", "pi@10.0.0.2:2222", "--tmux", "none", "--auth", "password").exitCode, 0)
        XCTAssertEqual(ConfigParser.parse(rig.config).config.hosts,
                       [HostEntry(name: "pi", user: "pi", address: "10.0.0.2", port: 2222, tmuxSession: nil, auth: .password)])
    }

    func testScriptsAreCalledWithoutAShell() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        _ = rig.run("host", "add", "mac", "me@mac")
        XCTAssertEqual(rig.run("push").exitCode, 0)
        XCTAssertEqual(rig.run("pubkey", "--fingerprint", "SHA256:abcdefghijk").exitCode, 0)
        XCTAssertEqual(rig.run("install", "--force").exitCode, 0)
        XCTAssertEqual(rig.calls.map(\.0), ["/bin/bash", "/bin/bash", "/bin/bash"])
        XCTAssertEqual(rig.calls.map { $0.1.dropFirst().map { $0 } },
                       [[], ["--fingerprint", "SHA256:abcdefghijk"], ["--force"]])
        XCTAssertTrue(rig.calls[0].1[0].hasSuffix("scripts/ios_push_config.sh"))
    }

    func testPushRefusesABrokenConfig() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        try "nonsense\n".write(to: rig.env.configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(rig.run("push").exitCode, 1)
        XCTAssertTrue(rig.calls.isEmpty)
    }

    func testPubkeyNeedsAFingerprint() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.run("pubkey").exitCode, 2)
        let r = Commands(env: rig.env).pubkey(fingerprint: "xyz; rm -rf ~")
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.needsHuman)
        XCTAssertTrue(rig.calls.isEmpty)
    }

    func testStatusReadsTheInstallRecord() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.run("status").exitCode, 1)
        let dir = rig.repo.appendingPathComponent("tmp/ios")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"expires": 1793512800, "build": "202610301200", "device": "UDID1"}"#.write(
            to: dir.appendingPathComponent("installed.json"), atomically: true, encoding: .utf8)
        let r = rig.run("status")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.contains("hours_left: 48"))
        XCTAssertTrue(r.output.contains("build: 202610301200"))
    }

    func testInboxListAndClean() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        let inbox = rig.home.appendingPathComponent(".splitterm/inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_793_340_000)
        let files: [(String, TimeInterval)] = [
            ("20261030-101010-ab12.sheet.jpg", 60), ("20261030-101010-ab12.video.md", 60),
            ("20261020-090000-cd34.heic", 10 * 86_400), ("20261030-111111-ef56.m4a.part", 1),
            ("notes.txt", 30 * 86_400),  // 人が置いたもの。古くても消さない
        ]
        for (name, age) in files {
            let u = inbox.appendingPathComponent(name)
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
        }
        let list = rig.run("inbox", "list").output.split(separator: "\n")
        XCTAssertEqual(list.count, 4)  // 送っている途中（.part）は出さない
        XCTAssertTrue(list[0].hasPrefix("video-sheet") || list[0].hasPrefix("video-notes"))
        XCTAssertTrue(list[2].hasPrefix("image"))
        XCTAssertEqual(rig.run("inbox", "clean").output, "1 件消しました（7 日より古いもの）")
        let left = rig.run("inbox", "list").output.split(separator: "\n")
        XCTAssertEqual(left.count, 3)
        XCTAssertTrue(left.contains { $0.hasSuffix("/notes.txt") })
    }

    func testUnknownCommandShowsUsage() throws {
        let rig = try Rig()
        let r = rig.run("frobnicate")
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.output.contains("splitterm config check"))
    }
}

final class MCPTests: XCTestCase {
    func server(_ rig: Rig) -> MCPServer {
        MCPServer(commands: Commands(env: rig.env), doctor: Doctor(env: rig.env))
    }

    func call(_ s: MCPServer, _ json: String) throws -> [String: Any] {
        let out = try XCTUnwrap(s.handle(line: json))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testInitializeNegotiatesTheVersion() throws {
        let rig = try Rig()
        let s = server(rig)
        let r = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let r2 = try call(s, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual((r2["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])
        // 通知には答えない
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testToolsListMatchesTheDocumentedTools() throws {
        let rig = try Rig()
        let r = try call(server(rig), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["doctor", "config_show", "config_check", "config_set", "host_add", "host_remove", "config_push",
                        "pubkey_install", "app_install", "app_status", "inbox_list", "inbox_clean"])
        for t in tools {
            let schema = try XCTUnwrap(t["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }
    }

    func testToolCallEditsTheConfig() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        let s = server(rig)
        let r = try call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"config_set","arguments":{"key":"font-size","value":"13"}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(ConfigParser.parse(rig.config).config.fontSize, 13)
        let bad = try call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"config_set","arguments":{"key":"font-size"}}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testPubkeyWithoutFingerprintAsksForAHuman() throws {
        let rig = try Rig()
        let r = try call(server(rig), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pubkey_install","arguments":{"fingerprint":"nope"}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("needs_human"))
        XCTAssertTrue(rig.calls.isEmpty)
    }

    func testProtocolErrors() throws {
        let rig = try Rig()
        let s = server(rig)
        XCTAssertEqual(((try call(s, "not json"))["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual(((try call(s, #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#))["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(((try call(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"rm"}}"#))["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(((try call(s, #"{"jsonrpc":"2.0","id":9,"method":7}"#))["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(((try call(s, #"{"jsonrpc":"2.0","id":9}"#))["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(((try call(s, String(repeating: " ", count: MCPServer.maxLine + 1) + "{}"))["error"] as? [String: Any])?["code"] as? Int, -32700)
        // 応答には答えない
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#))
    }

    /// 道具は決まった config だけを触る（file を渡しても、ほかのファイルを書き換えない）
    func testToolsIgnoreOtherFiles() throws {
        let rig = try Rig()
        _ = rig.run("config", "init")
        let other = rig.home.appendingPathComponent(".npmrc")
        try "registry = https://registry.npmjs.org/\n".write(to: other, atomically: true, encoding: .utf8)
        let path = other.path.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try call(server(rig), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"config_set","arguments":{"key":"registry","value":"https://evil.example","file":""# + path + #""}}}"#)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "registry = https://registry.npmjs.org/\n")
    }
}

final class DoctorTests: XCTestCase {
    /// 一覧（HostEntry.tmuxSearchPaths）にある場所なら、ログインシェルに聞かずに見つける
    func testTmuxIsFoundInTheSearchList() throws {
        let rig = try Rig()
        let bin = rig.home.appendingPathComponent(".nix-profile/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tmux = bin.appendingPathComponent("tmux")
        try "#!/bin/sh\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        let check = Doctor(env: rig.env).tmux()
        XCTAssertEqual(check.status, .ok)
        XCTAssertTrue(check.message.contains("tmux があります（/"), check.message)
        XCTAssertTrue(rig.calls.isEmpty)
    }

    /// 一覧に無ければ、アプリと同じくログインシェルの PATH で探す。それでも無ければ警告
    func testTmuxFallsBackToTheLoginShell() throws {
        let rig = try Rig()
        let fixed = HostEntry.tmuxSearchPaths.filter { !$0.contains("$") }
        let exists = fixed.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
        try XCTSkipIf(exists, "決まった場所に tmux があるので、見つからない場合を作れない")
        rig.reply = ProcessResult(status: 0, stdout: "motd\n/opt/odd/bin/tmux\n", stderr: "")
        let found = Doctor(env: rig.env).tmux()
        XCTAssertEqual(found.status, .ok)
        XCTAssertTrue(found.message.contains("/opt/odd/bin/tmux"), found.message)
        XCTAssertEqual(rig.calls.first?.1, ["-lc", "command -v tmux"])
        rig.reply = ProcessResult(status: 1, stdout: "", stderr: "")
        let missing = Doctor(env: rig.env).tmux()
        XCTAssertEqual(missing.status, .warn)
        XCTAssertEqual(missing.fix, "brew install tmux")
    }
}
