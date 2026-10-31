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

    /// palette は番号ごとに 1 色を書き換える（コメントと並びを残す）
    func testSetPalette() throws {
        let base = "# 16 色\n# palette = 0=#1C2128\n# palette = 1=#FF5F6D\n\nfont-size = 10\n"
        // 見本の同じ番号の行の下に足す
        var out = try ConfigEditor.setPalette(1, RGB(1, 2, 3), in: base)
        XCTAssertEqual(out, "# 16 色\n# palette = 0=#1C2128\n# palette = 1=#FF5F6D\npalette = 1=#010203\n\nfont-size = 10\n")
        // 有効な行があれば置き換える
        out = try ConfigEditor.setPalette(1, RGB(4, 5, 6), in: out)
        XCTAssertEqual(out, "# 16 色\n# palette = 0=#1C2128\n# palette = 1=#FF5F6D\npalette = 1=#040506\n\nfont-size = 10\n")
        // 別の番号は、その番号の見本の行の下
        out = try ConfigEditor.setPalette(0, RGB(7, 8, 9), in: out)
        XCTAssertEqual(out, "# 16 色\n# palette = 0=#1C2128\npalette = 0=#070809\n# palette = 1=#FF5F6D\npalette = 1=#040506\n\nfont-size = 10\n")
        let (c, d) = ConfigParser.parse(out)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.palette[0], RGB(7, 8, 9))
        XCTAssertEqual(c.palette[1], RGB(4, 5, 6))
        XCTAssertEqual(c.palette[2], TermConfig.defaultPalette[2])
    }

    func testSetPaletteWhereThereIsNoSample() throws {
        // 見本の行が無い番号は、最後の palette の行の下
        var out = try ConfigEditor.setPalette(3, RGB(1, 1, 1), in: "palette = 5=#050505\nfont-size = 10\n")
        XCTAssertEqual(out, "palette = 5=#050505\npalette = 3=#010101\nfont-size = 10\n")
        // palette の行が 1 つも無ければ、末尾
        out = try ConfigEditor.setPalette(3, RGB(1, 1, 1), in: "font-size = 10")
        XCTAssertEqual(out, "font-size = 10\n\npalette = 3=#010101\n")
        // 同じ番号が何度も書いてあれば、最後の 1 行を置き換える
        out = try ConfigEditor.setPalette(5, RGB(9, 9, 9), in: "palette = 5=#000000\npalette = 5=#111111\n")
        XCTAssertEqual(out, "palette = 5=#000000\npalette = 5=#090909\n")
    }

    func testSetPaletteRefusesOutOfRangeIndexes() {
        XCTAssertThrowsError(try ConfigEditor.setPalette(16, RGB(0, 0, 0), in: ""))
        XCTAssertThrowsError(try ConfigEditor.setPalette(-1, RGB(0, 0, 0), in: ""))
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
        c.minimumContrast = 4.5
        c.boldIsBright = true
        c.fontThicken = true
        c.colorSpace = .srgb
        let (back, d) = ConfigParser.parse(c.effectiveLines.joined(separator: "\n"))
        XCTAssertEqual(d, [])
        XCTAssertEqual(back, c)
    }
}
