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
        let (c, d) = ConfigParser.parse("key-repeat-delay = 300ms\nkey-repeat-interval = 40\nclipboard-clear = 2m\nkeepalive = 1.5s")
        XCTAssertEqual(c.keyRepeatDelay, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.keyRepeatInterval, 0.04, accuracy: 1e-9)
        XCTAssertEqual(c.keepalive, 1.5, accuracy: 1e-9)
        XCTAssertEqual(d.map(\.line), [3])
    }

    func testZoomSteps() {
        XCTAssertEqual(ConfigParser.parse("zoom-steps = 100, 85%, 70").config.zoomSteps, [100, 85, 70])
        XCTAssertEqual(ConfigParser.parse("zoom-steps = 10").diagnostics.count, 1)
    }

    func testHosts() {
        let (c, d) = ConfigParser.parse("""
        host = mac dken@s-macbook-air.tail65f907.ts.net
        host = pi pi@192.168.1.5:2222 tmux=none auth=password
        host = v6 me@[fe80::1]:2200 tmux=work
        auto-connect = pi
        """)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.hosts.count, 3)
        XCTAssertEqual(c.hosts[0], HostEntry(name: "mac", user: "dken", address: "s-macbook-air.tail65f907.ts.net"))
        XCTAssertEqual(c.hosts[0].startupCommand,
                       "exec \"$SHELL\" -lc 'if command -v tmux >/dev/null 2>&1; then exec tmux -u new-session -A -s main; "
                       + "else echo \"tmux が見つかりません。素のシェルを開きます\"; exec \"$SHELL\" -l; fi'")
        XCTAssertEqual(c.hosts[1].port, 2222)
        XCTAssertNil(c.hosts[1].tmuxSession)
        XCTAssertNil(c.hosts[1].startupCommand)
        XCTAssertEqual(c.hosts[1].auth, .password)
        XCTAssertEqual(c.hosts[2].address, "fe80::1")
        XCTAssertEqual(c.hosts[2].port, 2200)
        XCTAssertEqual(c.hosts[2].tmuxSession, "work")
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
            guard line.hasPrefix("# "), let eq = line.firstIndex(of: "=") else { return nil }
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
