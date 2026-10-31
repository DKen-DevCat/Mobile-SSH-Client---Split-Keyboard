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
    /// `ghostty` を探す PATH の並び。実機の PATH は見ない
    var searchPath: [String] = []
    var xdgConfigHome: String?

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
                    now: { Date(timeIntervalSince1970: 1_793_340_000) },
                    ghosttyApp: ghosttyApp, searchPath: searchPath, xdgConfigHome: xdgConfigHome)
    }

    /// Ghostty.app の場所（一時フォルダの中。実機の /Applications/Ghostty.app は見ない）。最初は無い
    var ghosttyApp: URL { root.appendingPathComponent("Applications/Ghostty.app") }
    var ghosttyExecutable: URL { ghosttyApp.appendingPathComponent("Contents/MacOS/ghostty") }
    /// Ghostty の config（`$XDG_CONFIG_HOME` が無いときの場所）
    var ghosttyConfig: URL { home.appendingPathComponent(".config/ghostty/config") }
    var ghosttyThemes: URL { home.appendingPathComponent(".config/ghostty/themes") }

    /// 実行できるファイルを置く。起動は `run` の差し替えで、中身は動かない
    func installExecutable(at url: URL) throws {
        try write("#!/bin/sh\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func installGhostty() throws { try installExecutable(at: ghosttyExecutable) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
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
        XCTAssertTrue(r.output.contains("splitterm theme import [--dry-run]"))
    }
}

/// Mac の Ghostty の配色の取り込み（`splitterm theme import`）。Ghostty の起動は差し替え、ファイルは一時フォルダの HOME に置く
final class ThemeImportTests: XCTestCase {
    /// 取り込む前の config（見本と同じ形のコメントつき）
    static let sampleConfig = """
    # 設定
    # 色
    # color-space = display-p3
    # background = #07090D
    # foreground = #E6EDF3
    # cursor-color = #2F81F7
    # selection-background = #264F78

    # 16 色のパレット（番号=色）
    # palette = 0=#1C2128
    # palette = 1=#FF5F6D

    # 文字と背景の補正
    # minimum-contrast = 1

    font-size = 12
    # 最後のコメント
    """ + "\n"

    static let base16 = [
        "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
        "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ]

    /// `ghostty +show-config --changes-only=false` の出力の見本。16〜255 は xterm の標準
    static func showConfig(background: String = "#282c34", foreground: String = "#ffffff", theme: String = "Mocha",
                           extra: [String] = []) -> String {
        var lines = ["font-family = JetBrains Mono", "background = \(background)", "foreground = \(foreground)",
                     "selection-background = #3e4451", "cursor-color ="]
        for (i, hex) in base16.enumerated() { lines.append("palette = \(i)=\(hex)") }
        for i in 16..<256 { lines.append("palette = \(i)=\(XTerm256.standard(i)!.description.lowercased())") }
        lines += ["minimum-contrast = 1", "window-colorspace = srgb", "bold-is-bright = false", "font-thicken = false",
                  "theme = \(theme)", "keybind = ctrl+a=select_all"]
        return (lines + extra).joined(separator: "\n") + "\n"
    }

    private func rigWithConfig() throws -> Rig {
        let rig = try Rig()
        try rig.write(Self.sampleConfig, to: rig.env.configURL)
        return rig
    }

    private func parsed(_ rig: Rig) -> TermConfig { ConfigParser.parse(rig.config).config }

    // MARK: ghostty +show-config

    func testImportsFromShowConfig() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)

        // 決まった場所の ghostty を、+show-config だけで起動する（シェルを通さず、場所は受け取らない）
        XCTAssertEqual(rig.calls.count, 1)
        XCTAssertEqual(rig.calls[0].0, rig.ghosttyExecutable.path)
        XCTAssertEqual(rig.calls[0].1, ["+show-config", "--changes-only=false"])

        let c = parsed(rig)
        XCTAssertEqual(ConfigParser.parse(rig.config).diagnostics, [])
        XCTAssertEqual(c.colorSpace, .srgb)
        XCTAssertEqual(c.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(c.foreground, RGB(0xff, 0xff, 0xff))
        XCTAssertEqual(c.selectionBackground, RGB(0x3e, 0x44, 0x51))
        XCTAssertEqual(c.cursorColor, TermConfig().cursorColor, "Ghostty で未設定の色は書かない")
        XCTAssertEqual(c.palette.map(\.description), Self.base16.map { $0.uppercased() })
        XCTAssertEqual(c.minimumContrast, 1)
        XCTAssertFalse(c.boldIsBright)
        XCTAssertFalse(c.fontThicken)
        XCTAssertEqual(c.fontSize, 12, "ほかの項目は変えない")
        XCTAssertTrue(rig.config.contains("background = #282C34\n"))
        XCTAssertTrue(rig.config.contains("palette = 1=#CC6666\n"))

        XCTAssertTrue(r.output.contains("ghostty +show-config"), r.output)
        XCTAssertTrue(r.output.contains("  background = #282C34"), r.output)
        XCTAssertTrue(r.output.contains("color-space = srgb"), r.output)
        XCTAssertTrue(r.output.contains("cursor-color"), "未設定で書かなかったことを知らせる: \(r.output)")
        XCTAssertFalse(r.output.contains("警告:"), r.output)
        // 出力の最後は、次は splitterm push
        XCTAssertTrue(try XCTUnwrap(r.output.split(separator: "\n").last).contains("splitterm push"), r.output)
    }

    func testCommentsAndOrderAreKept() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        let kept = Set(rig.config.components(separatedBy: "\n"))
        for line in Self.sampleConfig.components(separatedBy: "\n") {
            XCTAssertTrue(kept.contains(line), "消えた行: \(line)")
        }
        // 書いた行は、見本の行（# key = …）のすぐ下に入る
        let lines = rig.config.components(separatedBy: "\n")
        let i = try XCTUnwrap(lines.firstIndex(of: "# background = #07090D"))
        XCTAssertEqual(lines[i + 1], "background = #282C34")
        let j = try XCTUnwrap(lines.firstIndex(of: "# minimum-contrast = 1"))
        XCTAssertEqual(lines[j + 1], "minimum-contrast = 1")
        // もう一度流しても同じ（行が増えない）
        let once = rig.config
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(rig.config, once)
    }

    /// --dry-run は書かない。書き換える内容は出す
    func testDryRunWritesNothing() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        let before = rig.config
        let r = rig.run("theme", "import", "--dry-run")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertEqual(rig.config, before)
        XCTAssertTrue(r.output.contains("--dry-run"), r.output)
        XCTAssertTrue(r.output.contains("  background = #282C34"), r.output)
        XCTAssertTrue(r.output.contains("  palette = 15=#EAEAEA"), r.output)
        XCTAssertTrue(r.output.contains("splitterm push"), r.output)
        XCTAssertFalse(r.output.contains("config に書きました"), r.output)
    }

    func testDryRunStillRefusesWhenTheConfigIsMissing() throws {
        let rig = try Rig()
        try rig.installGhostty()
        let r = rig.run("theme", "import", "--dry-run")
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.output.contains("config がありません"), r.output)
        XCTAssertTrue(rig.calls.isEmpty)
    }

    func testFileOptionChoosesTheConfigToWrite() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        let other = rig.root.appendingPathComponent("other-config")
        try rig.write("font-size = 11\n", to: other)
        let before = rig.config
        XCTAssertEqual(rig.run("theme", "import", "--file", other.path).exitCode, 0)
        XCTAssertEqual(rig.config, before)
        let written = try String(contentsOf: other, encoding: .utf8)
        XCTAssertEqual(ConfigParser.parse(written).config.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(ConfigParser.parse(written).config.fontSize, 11)
    }

    /// 色の名前などは書かずに警告。palette の 16〜255 が標準と違えば警告だけ
    func testWarnsAboutColorNamesAndNonStandardPalette() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(
            background: "darkslategray", foreground: "#eeeeee", extra: ["palette = 20=#123456", "palette = 200=#abcdef"]),
            stderr: "")
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("警告:"), r.output)
        XCTAssertTrue(r.output.contains("background の色 `darkslategray`"), r.output)
        XCTAssertTrue(r.output.contains("2 個") && r.output.contains("20") && r.output.contains("200"), r.output)
        let c = parsed(rig)
        XCTAssertEqual(c.background, TermConfig().background, "読めない色は書かない")
        XCTAssertEqual(c.foreground, RGB(0xee, 0xee, 0xee))
        XCTAssertFalse(rig.config.contains("#123456") || rig.config.lowercased().contains("#abcdef"), "16〜255 は取り込まない")
    }

    // MARK: 設定ファイルとテーマのファイル

    /// 明暗 2 つのテーマは暗い方。テーマの値の上に config の値が重なる。明示されていない色は書かない
    func testImportsFromConfigAndThemeFilesPreferringTheDarkTheme() throws {
        let rig = try rigWithConfig()  // ghostty の実行ファイルは無い
        try rig.write("""
        # Ghostty
        font-family = JetBrains Mono
        theme = light:Day,dark:Night
        background = #101010
        palette = 1=#ff0000
        minimum-contrast = 3
        bold-is-bright = true
        window-colorspace = display-p3

        """, to: rig.ghosttyConfig)
        try rig.write("""
        background = #000000
        foreground = #eeeeee
        cursor-color = #ffffff
        selection-background = #444444
        palette = 0=#111111
        palette = 1=#aa0000
        palette = 2=#00aa00

        """, to: rig.ghosttyThemes.appendingPathComponent("Night"))
        try rig.write("background = #ffffff\nforeground = #111111\npalette = 0=#fafafa\n",
                      to: rig.ghosttyThemes.appendingPathComponent("Day"))

        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(rig.calls.isEmpty, "ghostty が無いので起動しない")
        let c = parsed(rig)
        XCTAssertEqual(ConfigParser.parse(rig.config).diagnostics, [])
        XCTAssertEqual(c.background, RGB(0x10, 0x10, 0x10), "config の値がテーマの値に勝つ")
        XCTAssertEqual(c.foreground, RGB(0xee, 0xee, 0xee), "テーマ（暗い方）の値")
        XCTAssertEqual(c.cursorColor, RGB(0xff, 0xff, 0xff))
        XCTAssertEqual(c.selectionBackground, RGB(0x44, 0x44, 0x44))
        XCTAssertEqual(c.palette[0], RGB(0x11, 0x11, 0x11), "明るい方（Day）の値ではない")
        XCTAssertEqual(c.palette[1], RGB(0xff, 0x00, 0x00), "config の palette がテーマの palette に勝つ")
        XCTAssertEqual(c.palette[2], RGB(0x00, 0xaa, 0x00))
        XCTAssertEqual(c.palette[3], TermConfig.defaultPalette[3], "明示されていない色は書かない")
        XCTAssertEqual(c.minimumContrast, 3)
        XCTAssertTrue(c.boldIsBright)
        XCTAssertFalse(c.fontThicken, "書いていなければ Ghostty の既定値")
        XCTAssertEqual(c.colorSpace, .displayP3)

        XCTAssertTrue(r.output.contains("暗い方の Night"), r.output)
        XCTAssertTrue(r.output.contains("既定色が分からない"), r.output)
        XCTAssertTrue(r.output.contains("palette 3・4"), "書かなかった palette を知らせる: \(r.output)")
        XCTAssertTrue(try XCTUnwrap(r.output.split(separator: "\n").last).contains("splitterm push"), r.output)
    }

    /// 色以外は、書いていなければ Ghostty の既定値（1・false・false・srgb）
    func testFileRouteAssumesGhosttyDefaultsForNonColorSettings() throws {
        let rig = try rigWithConfig()
        try rig.write("background = #202020\n", to: rig.ghosttyConfig)
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        let c = parsed(rig)
        XCTAssertEqual(c.background, RGB(0x20, 0x20, 0x20))
        XCTAssertEqual(c.colorSpace, .srgb)
        XCTAssertEqual(c.minimumContrast, 1)
        XCTAssertFalse(c.boldIsBright)
        XCTAssertFalse(c.fontThicken)
        XCTAssertEqual(c.foreground, TermConfig().foreground)
    }

    /// テーマのファイルは、自分のフォルダが先、無ければ Ghostty.app の中
    func testThemeFilesAreSearchedInTheUserFolderThenTheApp() throws {
        let rig = try rigWithConfig()
        let appThemes = rig.ghosttyApp.appendingPathComponent("Contents/Resources/ghostty/themes")
        try rig.write("theme = Both\n", to: rig.ghosttyConfig)
        try rig.write("background = #111111\nforeground = #aaaaaa\n", to: appThemes.appendingPathComponent("Both"))
        try rig.write("background = #222222\n", to: rig.ghosttyThemes.appendingPathComponent("Both"))
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(parsed(rig).background, RGB(0x22, 0x22, 0x22))

        // 自分のフォルダに無いテーマは Ghostty.app の中から
        try rig.write("theme = AppOnly\n", to: rig.ghosttyConfig)
        try rig.write("background = #333333\nforeground = #bbbbbb\n", to: appThemes.appendingPathComponent("AppOnly"))
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(parsed(rig).background, RGB(0x33, 0x33, 0x33))
        XCTAssertEqual(parsed(rig).foreground, RGB(0xbb, 0xbb, 0xbb))
    }

    func testMissingOrUnsafeThemeIsWarnedAbout() throws {
        let rig = try rigWithConfig()
        try rig.write("theme = Nowhere\nbackground = #111111\n", to: rig.ghosttyConfig)
        var r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("theme `Nowhere` のファイルが見つかりません"), r.output)
        XCTAssertEqual(parsed(rig).background, RGB(0x11, 0x11, 0x11))

        // フォルダをたどる名前は読まない
        try rig.write("secret = x\nbackground = #999999\n", to: rig.root.appendingPathComponent("secret-theme"))
        try rig.write("theme = ../../../secret-theme\n", to: rig.ghosttyConfig)
        r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("テーマの名前として読めない形"), r.output)
        XCTAssertNotEqual(parsed(rig).background, RGB(0x99, 0x99, 0x99))
    }

    /// $XDG_CONFIG_HOME があればその下の ghostty/config（~/.config は見ない）。macOS の Application Support のものが後から重なる
    func testConfigLocationsAndPrecedence() throws {
        let rig = try rigWithConfig()
        let xdg = rig.root.appendingPathComponent("xdg")
        rig.xdgConfigHome = xdg.path
        try rig.write("background = #aaaaaa\nforeground = #bbbbbb\n", to: xdg.appendingPathComponent("ghostty/config"))
        try rig.write("background = #cccccc\n", to: rig.ghosttyConfig)  // XDG があるので読まない
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(parsed(rig).background, RGB(0xaa, 0xaa, 0xaa))

        let support = rig.home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")
        try rig.write("foreground = #dddddd\n", to: support)
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertEqual(parsed(rig).background, RGB(0xaa, 0xaa, 0xaa))
        XCTAssertEqual(parsed(rig).foreground, RGB(0xdd, 0xdd, 0xdd), "後から読む Application Support の値が勝つ")
    }

    func testIncludedConfigFilesAreNotReadAndAreSaid() throws {
        let rig = try rigWithConfig()
        try rig.write("config-file = ~/more.conf\nbackground = #111111\n", to: rig.ghosttyConfig)
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("config-file"), r.output)
    }

    // MARK: 2 つの読み方の切り替え

    /// +show-config が失敗・時間切れ・読めない出力のときは、設定ファイルを直接読む
    func testFallsBackToFilesWhenShowConfigFails() throws {
        let failures = [
            ProcessResult(status: 1, stdout: "", stderr: "boom"),
            ProcessResult(status: 0, stdout: "", stderr: "", timedOut: true),
            ProcessResult(status: 0, stdout: "not a config\n???\n", stderr: ""),
            ProcessResult(status: 127, stdout: "", stderr: "起動できません"),
        ]
        for failure in failures {
            let rig = try rigWithConfig()
            try rig.installGhostty()
            try rig.write("background = #121212\nforeground = #fafafa\n", to: rig.ghosttyConfig)
            rig.reply = failure
            let r = rig.run("theme", "import")
            XCTAssertEqual(r.exitCode, 0, r.output)
            XCTAssertEqual(rig.calls.count, 1, "まず +show-config を試す")
            XCTAssertEqual(parsed(rig).background, RGB(0x12, 0x12, 0x12))
            XCTAssertTrue(r.output.contains("設定ファイルを直接読みました"), r.output)
        }
    }

    func testShowConfigIsPreferredOverFilesWhenItWorks() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        try rig.write("background = #121212\n", to: rig.ghosttyConfig)
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(parsed(rig).background, RGB(0x28, 0x2c, 0x34))
    }

    /// PATH の ghostty も使える（/Applications に無いとき）
    func testGhosttyInThePathIsUsed() throws {
        let rig = try rigWithConfig()
        let bin = rig.root.appendingPathComponent("bin")
        try rig.installExecutable(at: bin.appendingPathComponent("ghostty"))
        rig.searchPath = ["/nonexistent/dir", bin.path]
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(), stderr: "")
        XCTAssertEqual(rig.run("theme", "import").exitCode, 0)
        XCTAssertEqual(rig.calls.first?.0, bin.appendingPathComponent("ghostty").path)
        // /Applications 側（ここでは一時フォルダの中）が先
        try rig.installGhostty()
        _ = rig.run("theme", "import")
        XCTAssertEqual(rig.calls.last?.0, rig.ghosttyExecutable.path)
    }

    /// 明暗 2 つのテーマが +show-config に出ているときは、どちらの値か分からないので、ファイルで暗い方を読み直す
    func testDualThemeInShowConfigIsReReadFromFiles() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(
            background: "#fdf6e3", foreground: "#657b83", theme: "light:Day,dark:Night"), stderr: "")
        try rig.write("theme = light:Day,dark:Night\n", to: rig.ghosttyConfig)
        try rig.write("background = #002b36\nforeground = #839496\n", to: rig.ghosttyThemes.appendingPathComponent("Night"))
        try rig.write("background = #fdf6e3\nforeground = #657b83\n", to: rig.ghosttyThemes.appendingPathComponent("Day"))
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertEqual(parsed(rig).background, RGB(0x00, 0x2b, 0x36))
        XCTAssertEqual(parsed(rig).foreground, RGB(0x83, 0x94, 0x96))
        XCTAssertTrue(r.output.contains("暗い方"), r.output)
    }

    /// ファイルを読めないなら、+show-config の値を使い、暗い方とは限らないと警告する
    func testDualThemeWithoutFilesFallsBackToShowConfigWithAWarning() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 0, stdout: Self.showConfig(theme: "light:Day,dark:Night"), stderr: "")
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertEqual(parsed(rig).background, RGB(0x28, 0x2c, 0x34))
        XCTAssertTrue(r.output.contains("警告:") && r.output.contains("暗い方の値とは限りません"), r.output)
    }

    // MARK: Ghostty が無い

    func testErrorWithAFixWhenGhosttyIsNowhere() throws {
        let rig = try rigWithConfig()
        let before = rig.config
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.output.contains("Ghostty の設定を読めません"), r.output)
        XCTAssertTrue(r.output.contains("Ghostty.app/Contents/MacOS/ghostty"), "探した場所を示す: \(r.output)")
        XCTAssertTrue(r.output.contains("PATH"), r.output)
        XCTAssertTrue(r.output.contains(".config/ghostty/config"), r.output)
        XCTAssertTrue(r.output.contains("直し方:") && r.output.contains("Ghostty を入れる"), r.output)
        XCTAssertTrue(rig.calls.isEmpty)
        XCTAssertEqual(rig.config, before)
        // --dry-run でも同じ
        XCTAssertEqual(rig.run("theme", "import", "--dry-run").exitCode, 1)
    }

    /// 実行ファイルはあるが読めず、config ファイルも無いときも、直し方つきのエラー（何も書かない）
    func testErrorWhenGhosttyRunsButNothingCanBeRead() throws {
        let rig = try rigWithConfig()
        try rig.installGhostty()
        rig.reply = ProcessResult(status: 1, stdout: "", stderr: "")
        let before = rig.config
        let r = rig.run("theme", "import")
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.output.contains("終了コード 1"), r.output)
        XCTAssertTrue(r.output.contains("直し方:"), r.output)
        XCTAssertEqual(rig.config, before)
    }

    // MARK: 引数

    func testArgumentErrors() throws {
        let rig = try rigWithConfig()
        XCTAssertEqual(rig.run("theme").exitCode, 2)
        XCTAssertEqual(rig.run("theme", "export").exitCode, 2)
        XCTAssertEqual(rig.run("theme", "import", "extra").exitCode, 2)
        XCTAssertTrue(rig.calls.isEmpty)
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
                        "pubkey_install", "app_install", "app_status", "inbox_list", "inbox_clean", "theme_import"])
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

    func testThemeImportToolHasADryRunArgument() throws {
        let rig = try Rig()
        let r = try call(server(rig), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "theme_import" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Array(props.keys), ["dry_run"])
        XCTAssertEqual((props["dry_run"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual(schema["required"] as? [String], [])
    }

    func testThemeImportToolDryRunAndWrite() throws {
        let rig = try Rig()
        try rig.installGhostty()
        try rig.write(ThemeImportTests.sampleConfig, to: rig.env.configURL)
        rig.reply = ProcessResult(status: 0, stdout: ThemeImportTests.showConfig(), stderr: "")
        let s = server(rig)
        let before = rig.config

        let dry = try call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"theme_import","arguments":{"dry_run":true}}}"#)
        let dryResult = try XCTUnwrap(dry["result"] as? [String: Any])
        XCTAssertEqual(dryResult["isError"] as? Bool, false)
        let dryText = ((dryResult["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(dryText.contains("background = #282C34"), dryText)
        XCTAssertEqual(rig.config, before, "dry_run は書かない")

        let real = try call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"theme_import","arguments":{}}}"#)
        XCTAssertEqual((real["result"] as? [String: Any])?["isError"] as? Bool, false)
        let c = ConfigParser.parse(rig.config).config
        XCTAssertEqual(c.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(c.colorSpace, .srgb)
        XCTAssertEqual(c.palette[1], RGB(0xcc, 0x66, 0x66))
        XCTAssertTrue(rig.config.contains("# 最後のコメント"))

        // dry_run: false も書く
        try rig.write(ThemeImportTests.sampleConfig, to: rig.env.configURL)
        _ = try call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"theme_import","arguments":{"dry_run":false}}}"#)
        XCTAssertEqual(ConfigParser.parse(rig.config).config.background, RGB(0x28, 0x2c, 0x34))
    }

    func testThemeImportToolReportsMissingGhosttyAsAnError() throws {
        let rig = try Rig()
        try rig.write(ThemeImportTests.sampleConfig, to: rig.env.configURL)
        let r = try call(server(rig), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"theme_import","arguments":{}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("直し方:"), text)
    }

    /// 道具が触るのは決まった config と、決まった場所の Ghostty の設定だけ（file や path を渡しても使わない）
    func testThemeImportToolIgnoresFileArguments() throws {
        let rig = try Rig()
        try rig.installGhostty()
        try rig.write(ThemeImportTests.sampleConfig, to: rig.env.configURL)
        rig.reply = ProcessResult(status: 0, stdout: ThemeImportTests.showConfig(), stderr: "")
        let other = rig.home.appendingPathComponent(".npmrc")
        try "registry = https://registry.npmjs.org/\n".write(to: other, atomically: true, encoding: .utf8)
        let path = other.path.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try call(server(rig), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"theme_import","arguments":{"file":""# + path + #"","ghostty":"/etc/passwd","path":"/etc"}}}"#)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "registry = https://registry.npmjs.org/\n")
        XCTAssertEqual(rig.calls.map(\.0), [rig.ghosttyExecutable.path])
        XCTAssertEqual(ConfigParser.parse(rig.config).config.background, RGB(0x28, 0x2c, 0x34))
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
