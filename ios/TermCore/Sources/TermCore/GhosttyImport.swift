import Foundation

/// Mac の Ghostty が使っている配色を、config に移すための読み取りと変換（`splitterm theme import`。
/// docs/design.md「Get Started と MCP」）。ファイルにも外のプログラムにも触らない。文字を受け取って、
/// 取り込む値と書く行を返すだけなので、Mac の `swift test` で固定できる
public enum GhosttyImport {
    /// Ghostty の値のうち、取り込むもの。読めた分だけが入る
    public struct Settings: Equatable, Sendable {
        public var background: RGB?
        public var foreground: RGB?
        public var cursorColor: RGB?
        public var selectionBackground: RGB?
        /// 0〜255。取り込むのは 0〜15 だけで、16〜255 は標準との違いを警告するために持つ
        public var palette: [Int: RGB] = [:]
        public var minimumContrast: Double?
        public var boldIsBright: Bool?
        public var fontThicken: Bool?
        public var colorSpace: ColorSpace?
        /// `theme = …` の値（そのまま。最後に書かれたもの）
        public var theme: String?
        /// `config-file = …`（別のファイルを読み込む指定）の値。ファイルを直接読む道では読まないので、知らせるのに使う
        public var includes: [String] = []
        /// 読めなかった値の知らせ（同じものは重ねない）
        public var warnings: [String] = []

        public init() {}

        /// Ghostty の既定値。ファイルを直接読む道では、書いていない色以外の項目はこの値と見なす
        public static func withGhosttyDefaults() -> Settings {
            var s = Settings()
            s.minimumContrast = 1
            s.boldIsBright = false
            s.fontThicken = false
            s.colorSpace = .srgb
            return s
        }
    }

    // MARK: 読む

    /// `key = value` の行を順に（`#` で始まる行と空行、`=` の無い行は飛ばす。値の前後の空白と、全体を囲む `"` は除く）。
    /// `ghostty +show-config` の出力も Ghostty の config ファイルも、テーマのファイルも同じ形
    public static func entries(in text: String) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if key.isEmpty { continue }
            out.append((key: key, value: value))
        }
        return out
    }

    /// 文字を読んで、取り込む項目だけを `s` に重ねる（後の行が先の行に勝つ。知らない行は飛ばす）。
    /// 値が空の行は「未設定」で、前の値を消す（Ghostty の `key =` と同じ）
    public static func apply(_ text: String, to s: inout Settings) {
        for (key, value) in entries(in: text) {
            apply(key: key, value: value, to: &s)
        }
    }

    static func apply(key: String, value: String, to s: inout Settings) {
        switch key {
        case "background": assign(color(value, key, &s.warnings), to: &s.background)
        case "foreground": assign(color(value, key, &s.warnings), to: &s.foreground)
        case "cursor-color": assign(color(value, key, &s.warnings), to: &s.cursorColor)
        case "selection-background": assign(color(value, key, &s.warnings), to: &s.selectionBackground)
        case "palette":
            // `palette = 3=#FFB454`
            let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let i = Int(parts[0]), (0..<256).contains(i) else {
                warn("palette の `\(value)` は `番号=#RRGGBB` の形ではないので読みません", &s.warnings)
                return
            }
            if let c = parseColor(parts[1]) {
                s.palette[i] = c
            } else {
                warn("palette \(i) の色 `\(parts[1])` は #RRGGBB の形ではないので書きません（色の名前などは読めません）", &s.warnings)
            }
        case "minimum-contrast":
            if value.isEmpty { s.minimumContrast = nil; return }
            if let v = Double(value), (1.0...21.0).contains(v) {
                s.minimumContrast = v
            } else {
                warn("minimum-contrast の `\(value)` は 1〜21 の数ではないので書きません", &s.warnings)
            }
        case "bold-is-bright": assign(bool(value, key, &s.warnings), to: &s.boldIsBright)
        case "font-thicken": assign(bool(value, key, &s.warnings), to: &s.fontThicken)
        case "window-colorspace":
            if value.isEmpty { s.colorSpace = nil; return }
            if let c = ColorSpace(rawValue: value.lowercased()) {
                s.colorSpace = c
            } else {
                warn("window-colorspace の `\(value)` は srgb / display-p3 のどちらでもないので書きません", &s.warnings)
            }
        case "theme": s.theme = value.isEmpty ? nil : value
        case "config-file": if !value.isEmpty { s.includes.append(value) }
        default: break
        }
    }

    /// 値が空（未設定）／読めた／読めなかった（警告を出して、前の値のまま）
    enum Read<T> {
        case unset, value(T), invalid
    }

    static func assign<T>(_ read: Read<T>, to field: inout T?) {
        switch read {
        case .unset: field = nil
        case .value(let v): field = v
        case .invalid: break
        }
    }

    static func color(_ raw: String, _ key: String, _ warnings: inout [String]) -> Read<RGB> {
        if raw.isEmpty { return .unset }
        if let c = parseColor(raw) { return .value(c) }
        warn("\(key) の色 `\(raw)` は #RRGGBB の形ではないので書きません（色の名前などは読めません）", &warnings)
        return .invalid
    }

    static func bool(_ raw: String, _ key: String, _ warnings: inout [String]) -> Read<Bool> {
        if raw.isEmpty { return .unset }
        if let v = try? ConfigParser.bool(raw) { return .value(v) }
        warn("\(key) の `\(raw)` は true か false ではないので書きません", &warnings)
        return .invalid
    }

    static func warn(_ message: String, _ warnings: inout [String]) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    /// `#RRGGBB`・`RRGGBB`（`#RGB` は `#` があるときだけ）。それ以外（X11 の色の名前など）は nil
    public static func parseColor(_ raw: String) -> RGB? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        let hadHash = s.hasPrefix("#")
        if hadHash { s = s.dropFirst() }
        guard s.allSatisfy(\.isHexDigit), s.count == 6 || (hadHash && s.count == 3) else { return nil }
        return RGB(hex: String(s))
    }

    static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }

    // MARK: テーマ

    /// 使うテーマ。`light:A,dark:B` のような明暗 2 つの指定なら、暗い方（アプリは暗い画面だけ）
    public struct ThemeChoice: Equatable, Sendable {
        public var name: String
        /// 明暗 2 つの指定だった
        public var isPair: Bool
    }

    public static func themeChoice(_ value: String) -> ThemeChoice? {
        let v = unquote(value.trimmingCharacters(in: .whitespaces))
        guard !v.isEmpty else { return nil }
        var light: String?, dark: String?
        for token in v.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("light:") { light = unquote(String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("dark:") { dark = unquote(String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        if light != nil || dark != nil {
            guard let name = dark ?? light, !name.isEmpty else { return nil }
            return ThemeChoice(name: name, isPair: true)
        }
        return ThemeChoice(name: v, isPair: false)
    }

    /// テーマのファイル名として読んでよい名前か（フォルダをたどる文字を含まない。絶対パスは読まない）
    public static func isSafeThemeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    // MARK: 書く

    /// config に書く 1 項目
    public enum Item: Equatable, Sendable {
        case value(key: String, value: String)
        case palette(Int, RGB)

        public var key: String {
            switch self {
            case .value(let key, _): return key
            case .palette: return "palette"
            }
        }

        /// config の 1 行
        public var line: String {
            switch self {
            case .value(let key, let value): return "\(key) = \(value)"
            case .palette(let i, let c): return "palette = \(i)=\(c)"
            }
        }
    }

    /// 書く項目。順は config.example と同じ。読めなかった・未設定のものは入らない。palette は 0〜15 だけ
    public static func items(for s: Settings) -> [Item] {
        var out: [Item] = []
        func add(_ key: String, _ value: String?) {
            if let value { out.append(.value(key: key, value: value)) }
        }
        add("color-space", s.colorSpace?.rawValue)
        add("background", s.background?.description)
        add("foreground", s.foreground?.description)
        add("cursor-color", s.cursorColor?.description)
        add("selection-background", s.selectionBackground?.description)
        for i in 0..<16 {
            if let c = s.palette[i] { out.append(.palette(i, c)) }
        }
        add("minimum-contrast", s.minimumContrast.map { $0 == $0.rounded() ? String(Int($0)) : String($0) })
        add("bold-is-bright", s.boldIsBright.map { $0 ? "true" : "false" })
        add("font-thicken", s.fontThicken.map { $0 ? "true" : "false" })
        return out
    }

    /// config の文字に書く（`ConfigEditor` で、コメントと並びを残す。読めなくなる書き換えは断る）
    public static func write(_ items: [Item], into text: String) throws -> String {
        var out = text
        for item in items {
            switch item {
            case .value(let key, let value): out = try ConfigEditor.set(key, value, in: out)
            case .palette(let i, let c): out = try ConfigEditor.setPalette(i, c, in: out)
            }
        }
        return out
    }

    // MARK: 取り込まないものの知らせ

    /// 16〜255 のうち、xterm の標準と違う番号（昇順）。取り込まないので、アプリでは標準の色になる
    public static func nonStandardPalette(_ s: Settings) -> [Int] {
        s.palette.filter { $0.key >= 16 && XTerm256.standard($0.key) != $0.value }.map { $0.key }.sorted()
    }

    /// 値が分からず書かない色の項目（`background`・`foreground`・`cursor-color`・`selection-background`・`palette`）
    public static func missingColors(_ s: Settings) -> [String] {
        var out: [String] = []
        if s.background == nil { out.append("background") }
        if s.foreground == nil { out.append("foreground") }
        if s.cursorColor == nil { out.append("cursor-color") }
        if s.selectionBackground == nil { out.append("selection-background") }
        let missing = (0..<16).filter { s.palette[$0] == nil }
        if missing.count == 16 {
            out.append("palette 0〜15")
        } else if !missing.isEmpty {
            out.append("palette " + missing.map(String.init).joined(separator: "・"))
        }
        return out
    }

    /// 取り込めなかった値と、取り込まないものの知らせ（読む途中の警告に、16〜255 の違いを足す）
    public static func warnings(for s: Settings) -> [String] {
        var out = s.warnings
        let diff = nonStandardPalette(s)
        if !diff.isEmpty {
            let shown = diff.prefix(8).map(String.init).joined(separator: "・") + (diff.count > 8 ? "…" : "")
            out.append("palette の 16〜255 のうち、xterm の標準と違う色が \(diff.count) 個あります（\(shown)）。16〜255 は取り込まないので、アプリでは標準の色になります")
        }
        return out
    }
}
