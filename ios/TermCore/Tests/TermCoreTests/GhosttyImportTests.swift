import XCTest
@testable import TermCore

/// Ghostty の配色の読み取りと変換（`splitterm theme import` の純粋な部分。docs/design.md「Ghostty の配色の取り込み」）
final class GhosttyImportTests: XCTestCase {
    /// Ghostty の 0〜15 の見本（Ghostty の既定に近い色）
    static let base16 = [
        "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
        "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ]

    /// `ghostty +show-config --changes-only=false` の出力の見本（行の順や知らない項目は版で変わりうる）。
    /// 16〜255 は xterm の標準
    static func showConfig(extra: String = "", paletteOverrides: [Int: String] = [:]) -> String {
        var lines = [
            "font-family = JetBrains Mono",
            "font-size = 13",
            "background = #282c34",
            "foreground = #ffffff",
            "selection-foreground =",
            "selection-background = #3e4451",
            "cursor-color =",
            "cursor-style = block",
        ]
        for (i, hex) in base16.enumerated() { lines.append("palette = \(i)=\(paletteOverrides[i] ?? hex)") }
        for i in 16..<256 { lines.append("palette = \(i)=\(paletteOverrides[i] ?? XTerm256.standard(i)!.description.lowercased())") }
        lines += [
            "minimum-contrast = 1",
            "window-colorspace = srgb",
            "bold-is-bright = false",
            "font-thicken = false",
            "theme = Catppuccin Mocha",
            "config-file =",
            "keybind = ctrl+a=select_all",
            "this line has no equals sign",
        ]
        return lines.joined(separator: "\n") + "\n" + extra
    }

    private func settings(_ text: String) -> GhosttyImport.Settings {
        var s = GhosttyImport.Settings()
        GhosttyImport.apply(text, to: &s)
        return s
    }

    // MARK: +show-config の見本

    func testReadsTheShowConfigSample() {
        let s = settings(Self.showConfig())
        XCTAssertEqual(s.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(s.foreground, RGB(0xff, 0xff, 0xff))
        XCTAssertEqual(s.selectionBackground, RGB(0x3e, 0x44, 0x51))
        XCTAssertNil(s.cursorColor, "未設定（空）の色は書かない")
        XCTAssertEqual(s.minimumContrast, 1)
        XCTAssertEqual(s.boldIsBright, false)
        XCTAssertEqual(s.fontThicken, false)
        XCTAssertEqual(s.colorSpace, .srgb)
        XCTAssertEqual(s.theme, "Catppuccin Mocha")
        XCTAssertEqual(s.palette.count, 256)
        XCTAssertEqual(s.palette[1], RGB(0xcc, 0x66, 0x66))
        XCTAssertEqual(s.warnings, [])
        XCTAssertEqual(s.includes, [])
    }

    func testItemsAreTheDocumentedOnesInConfigExampleOrder() {
        let items = GhosttyImport.items(for: settings(Self.showConfig()))
        var expected = [
            "color-space = srgb",
            "background = #282C34",
            "foreground = #FFFFFF",
            "selection-background = #3E4451",
        ]
        for (i, hex) in Self.base16.enumerated() { expected.append("palette = \(i)=\(hex.uppercased())") }
        expected += ["minimum-contrast = 1", "bold-is-bright = false", "font-thicken = false"]
        XCTAssertEqual(items.map(\.line), expected)
        // cursor-color（空）と palette 16〜255 は書かない
        XCTAssertFalse(items.contains { $0.key == "cursor-color" })
        XCTAssertEqual(items.filter { $0.key == "palette" }.count, 16)
    }

    func testAllValuesAreRead() {
        let s = settings("""
        background = #101010
        foreground = eeeeee
        cursor-color = #ff8800
        selection-background = #333333
        minimum-contrast = 4.5
        bold-is-bright = true
        font-thicken = true
        window-colorspace = display-p3
        """)
        XCTAssertEqual(GhosttyImport.items(for: s).map(\.line), [
            "color-space = display-p3", "background = #101010", "foreground = #EEEEEE", "cursor-color = #FF8800",
            "selection-background = #333333", "minimum-contrast = 4.5", "bold-is-bright = true", "font-thicken = true",
        ])
    }

    func testUnknownLinesCommentsAndQuotesAreSkippedOrHandled() {
        let s = settings("""
        # コメント
        keybind = ctrl+a=select_all
        unknown-future-key = 1
        no equals sign here
        =
        background = "#112233"
        """)
        XCTAssertEqual(s.background, RGB(0x11, 0x22, 0x33))
        XCTAssertEqual(s.warnings, [])
        XCTAssertEqual(GhosttyImport.entries(in: "a = 1\n# x = 2\n\n  b =   \"q r\"  \nc").map { "\($0.key)=\($0.value)" },
                       ["a=1", "b=q r"])
    }

    func testLaterLinesWinAndEmptyValuesReset() {
        let s = settings("background = #111111\nbackground = #222222\nforeground = #333333\nforeground =\npalette = 1=#010101\npalette = 1=#020202")
        XCTAssertEqual(s.background, RGB(0x22, 0x22, 0x22))
        XCTAssertNil(s.foreground)
        XCTAssertEqual(s.palette[1], RGB(2, 2, 2))
    }

    // MARK: 色の書き方

    func testColorForms() {
        XCTAssertEqual(GhosttyImport.parseColor("#FFAA00"), RGB(0xff, 0xaa, 0x00))
        XCTAssertEqual(GhosttyImport.parseColor("ffaa00"), RGB(0xff, 0xaa, 0x00))
        XCTAssertEqual(GhosttyImport.parseColor("#fa0"), RGB(0xff, 0xaa, 0x00))
        for bad in ["", "#", "red", "Dark Slate Gray", "rgb(1,2,3)", "fa0", "#12345", "#1234567", "#GGGGGG", "+12345", "#ff aa00"] {
            XCTAssertNil(GhosttyImport.parseColor(bad), bad)
        }
    }

    /// X11 の色の名前などは書かずに警告に出す
    func testNonHexColorsAreNotWrittenAndAreWarnedAbout() {
        let s = settings("background = red\nforeground = #112233\ncursor-color = cell-foreground\npalette = 3=orange\npalette = 4=#445566")
        XCTAssertNil(s.background)
        XCTAssertEqual(s.foreground, RGB(0x11, 0x22, 0x33))
        XCTAssertNil(s.cursorColor)
        XCTAssertNil(s.palette[3])
        XCTAssertEqual(s.palette[4], RGB(0x44, 0x55, 0x66))
        XCTAssertEqual(s.warnings.count, 3)
        XCTAssertTrue(s.warnings[0].contains("background") && s.warnings[0].contains("red"), s.warnings[0])
        XCTAssertTrue(s.warnings[1].contains("cursor-color"), s.warnings[1])
        XCTAssertTrue(s.warnings[2].contains("palette 3"), s.warnings[2])
        let keys = GhosttyImport.items(for: s).map(\.key)
        XCTAssertFalse(keys.contains("background"))
        XCTAssertTrue(keys.contains("foreground"))
        XCTAssertEqual(GhosttyImport.warnings(for: s), s.warnings)
    }

    func testInvalidNonColorValuesAreWarnedAbout() {
        let s = settings("minimum-contrast = 30\nbold-is-bright = maybe\nwindow-colorspace = rec2020\nfont-thicken = true\npalette = x=#000000\npalette = 300=#000000")
        XCTAssertNil(s.minimumContrast)
        XCTAssertNil(s.boldIsBright)
        XCTAssertNil(s.colorSpace)
        XCTAssertEqual(s.fontThicken, true)
        XCTAssertEqual(s.warnings.count, 5)
        // 同じ警告は重ねない
        let twice = settings("bold-is-bright = maybe\nbold-is-bright = maybe")
        XCTAssertEqual(twice.warnings.count, 1)
    }

    // MARK: 明暗 2 つのテーマ

    private func choice(_ name: String, _ isPair: Bool) -> GhosttyImport.ThemeChoice {
        GhosttyImport.ThemeChoice(name: name, isPair: isPair)
    }

    func testThemeChoicePrefersTheDarkOne() {
        XCTAssertEqual(GhosttyImport.themeChoice("Dracula"), choice("Dracula", false))
        XCTAssertEqual(GhosttyImport.themeChoice("Catppuccin Mocha"), choice("Catppuccin Mocha", false))
        XCTAssertEqual(GhosttyImport.themeChoice("light:Rose Pine Dawn,dark:Rose Pine"),
                       choice("Rose Pine", true))
        XCTAssertEqual(GhosttyImport.themeChoice("dark:Night,light:Day"), choice("Night", true))
        XCTAssertEqual(GhosttyImport.themeChoice("light: Day , dark: Night "), choice("Night", true))
        XCTAssertEqual(GhosttyImport.themeChoice("light:\"Day\",dark:\"Night\""), choice("Night", true))
        // 明るい方しか無ければ、それを使う
        XCTAssertEqual(GhosttyImport.themeChoice("light:Day"), choice("Day", true))
        XCTAssertNil(GhosttyImport.themeChoice(""))
        XCTAssertNil(GhosttyImport.themeChoice("dark:"))
    }

    func testSafeThemeNames() {
        for ok in ["Dracula", "Catppuccin Mocha", "rose-pine", "Builtin Dark"] {
            XCTAssertTrue(GhosttyImport.isSafeThemeName(ok), ok)
        }
        for bad in ["", "../x", "a/b", "/etc/passwd", ".hidden", "..", "a\0b"] {
            XCTAssertFalse(GhosttyImport.isSafeThemeName(bad), bad)
        }
    }

    // MARK: palette の 16〜255

    func testStandardPaletteGivesNoWarning() {
        let s = settings(Self.showConfig())
        XCTAssertEqual(GhosttyImport.nonStandardPalette(s), [])
        XCTAssertEqual(GhosttyImport.warnings(for: s), [])
    }

    func testNonStandardPaletteIsOnlyWarnedAbout() {
        let s = settings(Self.showConfig(paletteOverrides: [17: "#123456", 240: "#abcdef", 5: "#ff00ff"]))
        XCTAssertEqual(GhosttyImport.nonStandardPalette(s), [17, 240])
        let w = GhosttyImport.warnings(for: s)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("2 個") && w[0].contains("17") && w[0].contains("240"), w[0])
        // 取り込まない: 書く項目に 16 以上の palette は無く、0〜15 の 5 番は書く
        let items = GhosttyImport.items(for: s)
        XCTAssertEqual(items.filter { $0.key == "palette" }.count, 16)
        XCTAssertTrue(items.contains(.palette(5, RGB(0xff, 0x00, 0xff))))
        XCTAssertFalse(items.map(\.line).contains { $0.contains("#123456") || $0.contains("#ABCDEF") })
    }

    func testManyNonStandardPaletteEntriesAreAbbreviated() {
        var overrides: [Int: String] = [:]
        for i in 16..<40 { overrides[i] = "#000001" }
        let w = GhosttyImport.warnings(for: settings(Self.showConfig(paletteOverrides: overrides)))
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("24 個") && w[0].contains("…"), w[0])
    }

    // MARK: 値が分からない色

    func testMissingColors() {
        XCTAssertEqual(GhosttyImport.missingColors(GhosttyImport.Settings()),
                       ["background", "foreground", "cursor-color", "selection-background", "palette 0〜15"])
        XCTAssertEqual(GhosttyImport.missingColors(settings(Self.showConfig())), ["cursor-color"])
        var s = settings(Self.showConfig())
        s.palette[2] = nil
        s.palette[9] = nil
        XCTAssertEqual(GhosttyImport.missingColors(s), ["cursor-color", "palette 2・9"])
    }

    func testGhosttyDefaultsAreTheNonColorOnes() {
        let s = GhosttyImport.Settings.withGhosttyDefaults()
        XCTAssertEqual(s.minimumContrast, 1)
        XCTAssertEqual(s.boldIsBright, false)
        XCTAssertEqual(s.fontThicken, false)
        XCTAssertEqual(s.colorSpace, .srgb)
        XCTAssertNil(s.background)
        XCTAssertTrue(s.palette.isEmpty)
    }

    func testConfigFileIncludesAreRemembered() {
        let s = settings("config-file = ~/more.conf\nconfig-file =\nconfig-file = ?optional")
        XCTAssertEqual(s.includes, ["~/more.conf", "?optional"])
    }

    // MARK: config に書く

    func testWriteKeepsCommentsAndOrder() throws {
        let base = """
        # 設定
        # font-size = 10

        # 色
        # color-space = display-p3
        # background = #07090D

        # 16 色のパレット（番号=色）
        # palette = 0=#1C2128
        # palette = 1=#FF5F6D
        palette = 2=#00FF00

        font-size = 12
        # minimum-contrast = 4.5
        # 最後のコメント
        """
        let items = GhosttyImport.items(for: settings(Self.showConfig()))
        let out = try GhosttyImport.write(items, into: base + "\n")
        let (c, d) = ConfigParser.parse(out)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c.colorSpace, .srgb)
        XCTAssertEqual(c.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(c.foreground, RGB(0xff, 0xff, 0xff))
        XCTAssertEqual(c.selectionBackground, RGB(0x3e, 0x44, 0x51))
        XCTAssertEqual(c.cursorColor, TermConfig().cursorColor, "書かなかった項目は既定のまま")
        XCTAssertEqual(c.palette.map(\.description), Self.base16.map { $0.uppercased() })
        XCTAssertEqual(c.minimumContrast, 1)
        XCTAssertEqual(c.fontSize, 12, "ほかの行は変えない")
        // 元の行はすべて残る（コメントも、有効な行を置き換えた palette 2 以外）
        let kept = out.components(separatedBy: "\n")
        for line in base.components(separatedBy: "\n") where line != "palette = 2=#00FF00" {
            XCTAssertTrue(kept.contains(line), line)
        }
        XCTAssertFalse(kept.contains("palette = 2=#00FF00"))
        // 見本の行の下に、書いた行が入る
        let lines = out.components(separatedBy: "\n")
        let i = try XCTUnwrap(lines.firstIndex(of: "# background = #07090D"))
        XCTAssertEqual(lines[i + 1], "background = #282C34")
        let j = try XCTUnwrap(lines.firstIndex(of: "# palette = 1=#FF5F6D"))
        XCTAssertEqual(lines[j + 1], "palette = 1=#CC6666")
    }

    /// 同梱の config.example（全項目の説明付き）へ書いても、コメントは 1 行も消えず、読めない行ができない
    func testWritingIntoTheBundledExampleKeepsEveryComment() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/SplitTerm/Resources/config.example")
        let example = try String(contentsOf: url, encoding: .utf8)
        let items = GhosttyImport.items(for: settings(Self.showConfig()))
        let out = try GhosttyImport.write(items, into: example)
        XCTAssertEqual(ConfigParser.parse(out).diagnostics, [])
        let kept = Set(out.components(separatedBy: "\n"))
        for line in example.components(separatedBy: "\n") {
            XCTAssertTrue(kept.contains(line), line)
        }
        let c = ConfigParser.parse(out).config
        XCTAssertEqual(c.background, RGB(0x28, 0x2c, 0x34))
        XCTAssertEqual(c.palette[1], RGB(0xcc, 0x66, 0x66))
        XCTAssertEqual(c.colorSpace, .srgb)
        XCTAssertEqual(c.minimumContrast, 1)
        XCTAssertFalse(c.boldIsBright)
        XCTAssertFalse(c.fontThicken)
        // 書き込みを 2 回しても同じ（行が増えない）
        XCTAssertEqual(try GhosttyImport.write(items, into: out), out)
    }

    func testWriteRefusesWhatWouldNotParse() {
        XCTAssertThrowsError(try GhosttyImport.write([.value(key: "minimum-contrast", value: "abc")], into: ""))
        XCTAssertThrowsError(try GhosttyImport.write([.palette(16, RGB(0, 0, 0))], into: ""))
        XCTAssertThrowsError(try GhosttyImport.write([.value(key: "background", value: "#112233\napp-lock = false")], into: ""))
    }
}
