import XCTest
@testable import TermCore

final class ConfigParserTests: XCTestCase {
    func testEmptyFileGivesDefaults() {
        let (c, d) = ConfigParser.parse("")
        XCTAssertEqual(c, TermConfig())
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.initialZoom, 85)
    }

    func testCommentsBlankLinesAndQuotes() {
        let (c, d) = ConfigParser.parse("""
        # コメント

        font-family = "SF Mono"
        font-size=12
        """)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.fontFamily, "SF Mono")
        XCTAssertEqual(c.fontSize, 12)
    }

    func testEmptyValueResetsToDefault() {
        let (c, _) = ConfigParser.parse("font-size = 14\nfont-size =\n")
        XCTAssertEqual(c.fontSize, TermConfig().fontSize)
    }

    func testBadLinesAreReportedAndSkipped() {
        let (c, d) = ConfigParser.parse("""
        font-size = 99
        nonsense
        unknown-key = 1
        cursor-style = triangle
        background = #123456
        """)
        XCTAssertEqual(d.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(c.fontSize, TermConfig().fontSize)
        XCTAssertEqual(c.background, RGB(0x12, 0x34, 0x56))
    }

    func testPaletteOverridesByIndex() {
        let (c, d) = ConfigParser.parse("palette = 1=#010203\npalette = 15=#fff\n")
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.palette[1], RGB(1, 2, 3))
        XCTAssertEqual(c.palette[15], RGB(255, 255, 255))
        XCTAssertEqual(c.palette[0], TermConfig.defaultPalette[0])
        XCTAssertEqual(ConfigParser.parse("palette = 16=#000000").diagnostics.count, 1)
    }

    func testDurations() {
        let (c, d) = ConfigParser.parse("key-repeat-delay = 300ms\nkey-repeat-interval = 40\nclipboard-clear = 2m\nkeepalive = 1.5s\nkeepalive = 2x")
        XCTAssertEqual(c.keyRepeatDelay, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.keyRepeatInterval, 0.04, accuracy: 1e-9)
        XCTAssertEqual(c.clipboardClear, 120, accuracy: 1e-9)
        XCTAssertEqual(c.keepalive, 1.5, accuracy: 1e-9)
        XCTAssertEqual(d.map(\.line), [5])
    }

    /// キーボードの種類（us は前の版の名前で、英語の分割）
    func testKeyboardKinds() {
        XCTAssertEqual(TermConfig().keyboard, .english)
        for kind in KeyboardKind.allCases {
            XCTAssertEqual(ConfigParser.parse("keyboard = \(kind.rawValue)").config.keyboard, kind)
        }
        XCTAssertEqual(ConfigParser.parse("keyboard = us").config.keyboard, .english)
        XCTAssertEqual(ConfigParser.parse("keyboard = qwerty").diagnostics.count, 1)
        XCTAssertEqual(KeyboardKind.menuOrder.count, KeyboardKind.allCases.count)
    }

    /// Face ID を求めるまでの時間（既定 15 分、0 で毎回）
    func testAppLockAfter() {
        XCTAssertEqual(TermConfig().appLockAfter, 900)
        XCTAssertEqual(ConfigParser.parse("app-lock-after = 15m").config.appLockAfter, 900)
        XCTAssertEqual(ConfigParser.parse("app-lock-after = 1h").config.appLockAfter, 3600)
        XCTAssertEqual(ConfigParser.parse("app-lock-after = 0").config.appLockAfter, 0)
        XCTAssertEqual(ConfigParser.parse("app-lock-after = 90").config.appLockAfter, 90)
        XCTAssertEqual(ConfigParser.parse("app-lock-after = 2d").diagnostics.count, 1)
    }

    /// inf や巨大な値で、後の整数への変換が落ちないこと
    func testDurationsMustBeFiniteAndBounded() {
        for v in ["inf", "nan", "1e300", "-1", "90000s"] {
            XCTAssertEqual(ConfigParser.parse("keepalive = \(v)").diagnostics.count, 1, v)
        }
        XCTAssertEqual(ConfigParser.parse("keepalive = 86400").config.keepalive, 86400)
    }

    func testZoomSteps() {
        XCTAssertEqual(ConfigParser.parse("zoom-steps = 100, 85%, 70").config.zoomSteps, [100, 85, 70])
        XCTAssertEqual(ConfigParser.parse("zoom-steps = 10").diagnostics.count, 1)
    }

    func testHosts() {
        let (c, d) = ConfigParser.parse("""
        host = mac me@my-mac.example.ts.net
        host = pi pi@192.168.1.5:2222 tmux=none auth=password
        host = v6 me@[fe80::1]:2200 tmux=work
        auto-connect = pi
        """)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.hosts.count, 3)
        XCTAssertEqual(c.hosts[0], HostEntry(name: "mac", user: "me", address: "my-mac.example.ts.net"))
        // 生成される 1 行そのものは StartupCommandTests が固定している
        XCTAssertEqual(c.hosts[0].startupCommand(slot: 1)?.contains("-A -s main\"; fi;"), true)
        XCTAssertEqual(c.hosts[0].tmuxSessionName(slot: 2), "main-2")
        XCTAssertEqual(c.hosts[1].port, 2222)
        XCTAssertNil(c.hosts[1].tmuxSession)
        XCTAssertNil(c.hosts[1].startupCommand(slot: 1))
        XCTAssertEqual(c.hosts[1].auth, .password)
        XCTAssertEqual(c.hosts[2].address, "fe80::1")
        XCTAssertEqual(c.hosts[2].port, 2200)
        XCTAssertEqual(c.hosts[2].tmuxSession, "work")
        XCTAssertEqual(c.hosts[2].tmuxSessionName(slot: 3), "work-3")
        XCTAssertEqual(c.autoConnectHost?.name, "pi")
    }

    func testHostErrors() {
        let bad = [
            "host = onlyname",
            "host = x noatsign",
            "host = x u@h:99999",
            "host = x u@h tmux=a;rm",
            "host = x u@h color=red",
            "host = bad/name u@h",
        ]
        for line in bad {
            XCTAssertEqual(ConfigParser.parse(line).diagnostics.count, 1, line)
        }
        let dup = ConfigParser.parse("host = a u@h\nhost = a u@g")
        XCTAssertEqual(dup.config.hosts.count, 1)
        XCTAssertEqual(dup.diagnostics.map(\.line), [2])
    }

    func testMediaSettings() {
        let (c, d) = ConfigParser.parse("""
        agent = codex
        agent-media = image, video
        media-dir = /Users/me/inbox
        media-retention = 36h
        media-insert = "見て: {paths} "
        video-mode = both
        video-frames = 6
        video-sheet-size = 2048
        audio-mode = transcript
        """)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.agent, .codex)
        XCTAssertEqual(c.readableMedia, [.image, .video])
        XCTAssertEqual(c.mediaDir, "/Users/me/inbox")
        XCTAssertEqual(c.mediaRetentionDays, 2)
        XCTAssertEqual(c.mediaInsert, "見て: {paths} ")
        XCTAssertEqual(c.videoMode, .both)
        XCTAssertEqual(c.videoFrames, 6)
        XCTAssertEqual(c.videoSheetSize, 2048)
        XCTAssertEqual(c.audioMode, .transcript)
        XCTAssertEqual(TermConfig().readableMedia, [.image])
        XCTAssertTrue(AgentKind.claudeCode.imageFormats.contains("webp"))
        XCTAssertFalse(AgentKind.generic.imageFormats.contains("webp"))
    }

    /// media-dir は接続先のシェルに渡すので、決まった文字だけ
    func testMediaDirRejectsShellSyntax() {
        for bad in ["inbox", "~/a b", "~/$(rm -rf ~)", "/tmp/../etc", "~/a;b", "~/a`b`", "/a~b", "~user/x", "~/\"x\"",
                    "~/", "/", "~/.", "//"] {
            XCTAssertEqual(ConfigParser.parse("media-dir = \(bad)").diagnostics.count, 1, bad)
        }
        XCTAssertEqual(ConfigParser.parse("media-dir = ~/.splitterm/in-box_2").diagnostics, [])
    }

    func testMediaValueErrors() {
        for line in ["agent = gemini", "agent-media = image,pdf", "media-retention = 400d", "media-insert = x",
                     "video-frames = 0", "video-sheet-size = 100", "audio-mode = loud"] {
            XCTAssertEqual(ConfigParser.parse(line).diagnostics.count, 1, line)
        }
        XCTAssertEqual(ConfigParser.parse("media-retention = 0").config.mediaRetentionDays, 0)
    }

    func testAutoConnect() {
        var c = TermConfig()
        XCTAssertNil(c.autoConnectHost)
        c.hosts = [HostEntry(name: "a", user: "u", address: "h")]
        XCTAssertEqual(c.autoConnectHost?.name, "a")
        c.autoConnect = "none"
        XCTAssertNil(c.autoConnectHost)
    }

    /// 同梱の設定の見本（ios/SplitTerm/Resources/config.example）は、そのまま読めて指摘が出ないこと
    func testBundledExampleParsesCleanly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/SplitTerm/Resources/config.example")
        let text = try String(contentsOf: url, encoding: .utf8)
        let (c, d) = ConfigParser.parse(text)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c, TermConfig())

        // 見本に書いた値（# を外した行）は、どれも読めて、既定値と同じであること
        let uncommented = text.split(separator: "\n").compactMap { line -> String? in
            // 字下げした説明の行（#   key = value など）は値ではない
            guard line.hasPrefix("# "), line.dropFirst(2).first?.isLetter == true,
                  let eq = line.firstIndex(of: "=") else { return nil }
            let key = line.dropFirst(2)[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLowercase || $0 == "-" }) else { return nil }
            return String(line.dropFirst(2))
        }.joined(separator: "\n")
        let (u, ud) = ConfigParser.parse(uncommented)
        XCTAssertEqual(ud, [])
        XCTAssertEqual(u.hosts.map(\.name), ["mac", "pi"])
        var withoutHosts = u
        withoutHosts.hosts = []
        XCTAssertEqual(withoutHosts, TermConfig())
    }
}
