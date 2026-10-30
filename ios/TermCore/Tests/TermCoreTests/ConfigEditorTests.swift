import XCTest
@testable import TermCore

final class ConfigEditorTests: XCTestCase {
    let doc = """
    # 見出し
    # font-size = 10

    font-family = Menlo
    font-family = Courier New
    """

    func testSetReplacesTheLastActiveLine() throws {
        let out = try ConfigEditor.set("font-family", "system-mono", in: doc)
        XCTAssertEqual(out, "# 見出し\n# font-size = 10\n\nfont-family = Menlo\nfont-family = system-mono\n")
        XCTAssertEqual(ConfigParser.parse(out).config.fontFamily, "system-mono")
    }

    func testSetInsertsBelowTheDocumentedLine() throws {
        let out = try ConfigEditor.set("font-size", "12", in: doc)
        XCTAssertTrue(out.hasPrefix("# 見出し\n# font-size = 10\nfont-size = 12\n"))
        XCTAssertEqual(ConfigParser.parse(out).config.fontSize, 12)
    }

    func testSetAppendsWhenNothingMatches() throws {
        let out = try ConfigEditor.set("haptics", "false", in: "font-size = 11")
        XCTAssertEqual(out, "font-size = 11\n\nhaptics = false\n")
    }

    func testSetQuotesSurroundingSpacesAndEmptyResets() throws {
        XCTAssertEqual(try ConfigEditor.set("media-insert", "{paths} ", in: ""), "media-insert = \"{paths} \"\n")
        XCTAssertEqual(try ConfigEditor.set("font-size", "", in: "font-size = 14\n"), "font-size =\n")
    }

    func testSetRefusesWhatWouldNotParse() {
        XCTAssertThrowsError(try ConfigEditor.set("font-size", "huge", in: doc))
        XCTAssertThrowsError(try ConfigEditor.set("no-such-key", "1", in: doc))
        XCTAssertThrowsError(try ConfigEditor.set("media-dir", "~/$(rm -rf ~)", in: doc))
        // 改行で別の項目を書き込めないこと
        XCTAssertThrowsError(try ConfigEditor.set("font-family", "Menlo\napp-lock = false", in: doc))
        XCTAssertThrowsError(try ConfigEditor.set("host", "x u@h", in: doc))
    }

    func testExistingProblemsDoNotBlockOtherEdits() throws {
        let broken = "nonsense line\nfont-size = 10\n"
        let out = try ConfigEditor.set("font-size", "12", in: broken)
        XCTAssertEqual(out, "nonsense line\nfont-size = 12\n")
    }

    func testAddAndRemoveHost() throws {
        let base = "# host = mac me@mac\nfont-size = 10\n"
        let h = HostEntry(name: "pi", user: "pi", address: "192.168.1.5", port: 2222, tmuxSession: nil, auth: .password)
        var out = try ConfigEditor.addHost(h, in: base)
        XCTAssertEqual(out, "# host = mac me@mac\nhost = pi pi@192.168.1.5:2222 tmux=none auth=password\nfont-size = 10\n")
        let v6 = HostEntry(name: "v6", user: "me", address: "fe80::1")
        out = try ConfigEditor.addHost(v6, in: out)
        XCTAssertEqual(ConfigParser.parse(out).config.hosts, [h, v6])
        XCTAssertThrowsError(try ConfigEditor.addHost(h, in: out))
        out = try ConfigEditor.removeHost(named: "pi", in: out)
        XCTAssertEqual(ConfigParser.parse(out).config.hosts, [v6])
        XCTAssertThrowsError(try ConfigEditor.removeHost(named: "pi", in: out))
    }

    func testAddHostRejectsUnsafeValues() {
        // 名前・アドレスに空白や記号が入ると、読み直したときに別の接続先になる
        let bad = HostEntry(name: "a b", user: "u", address: "h")
        XCTAssertThrowsError(try ConfigEditor.addHost(bad, in: ""))
        let bad2 = HostEntry(name: "x", user: "u", address: "h tmux=evil")
        XCTAssertThrowsError(try ConfigEditor.addHost(bad2, in: ""))
    }

    /// config show の出力は、そのまま読むと同じ設定になる
    func testEffectiveLinesRoundTrip() {
        var c = TermConfig()
        XCTAssertEqual(ConfigParser.parse(c.effectiveLines.joined(separator: "\n")).config, c)
        c.hosts = [HostEntry(name: "mac", user: "me", address: "mac.example.ts.net"),
                   HostEntry(name: "pi", user: "pi", address: "10.0.0.2", port: 2200, tmuxSession: nil)]
        c.keepalive = 1.5
        c.keyRepeatDelay = 0.25
        c.agentMedia = [.image, .video]
        c.mediaRetentionDays = 0
        c.keyboardPitch = 32
        c.palette[3] = RGB(1, 2, 3)
        let (back, d) = ConfigParser.parse(c.effectiveLines.joined(separator: "\n"))
        XCTAssertEqual(d, [])
        XCTAssertEqual(back, c)
    }
}
