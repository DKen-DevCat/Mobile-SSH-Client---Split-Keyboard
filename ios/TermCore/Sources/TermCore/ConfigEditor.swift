import Foundation

/// config の文字を、コメントと並びを残したまま書き換える（`splitterm config set`・`host add`、MCP の道具）。
/// 書き換えた後に読み直し、新しい指摘が出る書き換えは断る（壊れた config を端末へ送らない）
public enum ConfigEditor {
    public struct EditError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// 何度でも書ける項目（set では使えない）
    static let repeatable: Set<String> = ["host", "palette"]

    /// 1 項目を書き換える。有効な行があれば最後の 1 行を置き換え、無ければ見本の行（`# key = ...`）の下に足し、
    /// それも無ければ末尾に足す。値を空にすると既定値に戻る（Ghostty と同じ）
    public static func set(_ key: String, _ value: String, in text: String) throws -> String {
        let key = key.lowercased()
        guard !repeatable.contains(key) else {
            throw EditError("\(key) は何度でも書ける項目です。host は host add / host remove を使います")
        }
        let line = try render(key, value)
        var lines = split(text)
        if let i = lines.lastIndex(where: { activeKey($0) == key }) {
            lines[i] = line
        } else if let i = lines.lastIndex(where: { documentedKey($0) == key }) {
            lines.insert(line, at: i + 1)
        } else {
            appendWithSpacing(line, to: &lines)
        }
        return try validated(join(lines), original: text)
    }

    /// 接続先を足す（同じ名前があれば断る）。最後の host の下、無ければ見本の host の下に置く
    public static func addHost(_ entry: HostEntry, in text: String) throws -> String {
        let (config, _) = ConfigParser.parse(text)
        if config.host(named: entry.name) != nil {
            throw EditError("host `\(entry.name)` はもうあります（先に host remove）")
        }
        let line = "host = " + hostValue(entry)
        // 書いた行を読み直して、同じ接続先になること（変な文字が混じっていないこと）を確かめる
        let reparsed = ConfigParser.parse(line).config.hosts
        guard reparsed == [entry] else { throw EditError("host の値を書けません: \(line)") }
        var lines = split(text)
        if let i = lines.lastIndex(where: { activeKey($0) == "host" }) {
            lines.insert(line, at: i + 1)
        } else if let i = lines.lastIndex(where: { documentedKey($0) == "host" }) {
            lines.insert(line, at: i + 1)
        } else {
            appendWithSpacing(line, to: &lines)
        }
        return try validated(join(lines), original: text)
    }

    /// 接続先を消す。無ければ断る
    public static func removeHost(named name: String, in text: String) throws -> String {
        var lines = split(text)
        let before = lines.count
        lines.removeAll { line in
            guard activeKey(line) == "host" else { return false }
            let value = line[line.index(after: line.firstIndex(of: "=")!)...].trimmingCharacters(in: .whitespaces)
            return value.split(separator: " ").first.map(String.init) == name
        }
        guard lines.count < before else { throw EditError("host `\(name)` はありません") }
        return try validated(join(lines), original: text)
    }

    /// config の書き方の 1 行。値に改行は入れられない（別の行として読まれ、別の項目を書き込めてしまう）
    static func render(_ key: String, _ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline }) else { throw EditError("値に改行は入れられません") }
        guard key.allSatisfy({ $0.isLowercase || $0 == "-" }), !key.isEmpty else {
            throw EditError("項目の名前 `\(key)` が正しくありません")
        }
        if value.isEmpty { return "\(key) =" }
        let needsQuotes = value != value.trimmingCharacters(in: .whitespaces)
        return "\(key) = " + (needsQuotes ? "\"\(value)\"" : value)
    }

    static func hostValue(_ h: HostEntry) -> String {
        let address = h.address.contains(":") ? "[\(h.address)]" : h.address
        var s = "\(h.name) \(h.user)@\(address)"
        if h.port != 22 { s += ":\(h.port)" }
        if h.tmuxSession != "main" { s += " tmux=\(h.tmuxSession ?? "none")" }
        if h.auth != .key { s += " auth=\(h.auth.rawValue)" }
        return s
    }

    /// 書き換えで新しく読めない行が増えたら断る（元から読めない行は責めない）
    static func validated(_ text: String, original: String) throws -> String {
        let before = Set(ConfigParser.parse(original).diagnostics.map(\.message))
        let after = ConfigParser.parse(text).diagnostics
        if let bad = after.first(where: { !before.contains($0.message) }) {
            throw EditError("書き換えると読めない行ができます: \(bad)")
        }
        return text
    }

    /// 有効な行（`key = value`）の項目の名前
    static func activeKey(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 見本の行（`# key = value`）の項目の名前
    static func documentedKey(_ line: String) -> String? {
        guard line.hasPrefix("# ") else { return nil }
        let k = activeKey(String(line.dropFirst(2)))
        return k.flatMap { $0.allSatisfy({ $0.isLowercase || $0 == "-" }) && !$0.isEmpty ? $0 : nil }
    }

    static func split(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func join(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    static func appendWithSpacing(_ line: String, to lines: inout [String]) {
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(line)
    }
}

extension TermConfig {
    /// 今効いている値をすべて、config の書き方で（`splitterm config show`）。既定値のままの項目も含む
    public var effectiveLines: [String] {
        func b(_ v: Bool) -> String { v ? "true" : "false" }
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        func dur(_ v: Double) -> String { v < 1 && v > 0 ? "\(Int((v * 1000).rounded()))ms" : "\(n(v))s" }
        var out: [String] = []
        out += hosts.map { "host = " + ConfigEditor.hostValue($0) }
        out += [
            "auto-connect = \(autoConnect)", "term = \(term)", "keepalive = \(dur(keepalive))",
            "reconnect = \(b(reconnect))", "password-auth = \(b(passwordAuth))",
            "font-family = \(fontFamily)", "font-family-cjk = \(fontFamilyCJK)", "font-size = \(n(fontSize))",
            "zoom-steps = \(zoomSteps.map(String.init).joined(separator: ", "))",
            "color-space = \(colorSpace.rawValue)", "background = \(background)", "foreground = \(foreground)",
            "cursor-color = \(cursorColor)", "accent = \(accent)", "selection-background = \(selectionBackground)",
        ]
        out += palette.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        out += [
            "minimum-contrast = \(n(minimumContrast))", "bold-is-bright = \(b(boldIsBright))",
            "font-thicken = \(b(fontThicken))", "cursor-style = \(cursorStyle.rawValue)",
            "cursor-blink = \(b(cursorBlink))", "scrollback-limit = \(scrollbackLimit)",
            "keyboard = \(keyboard.rawValue)", "keyboard-pitch = \(keyboardPitch.map(n) ?? "auto")",
            "key-repeat-delay = \(dur(keyRepeatDelay))", "key-repeat-interval = \(dur(keyRepeatInterval))",
            "option-as-meta = \(b(optionAsMeta))", "haptics = \(b(haptics))", "newline = \(newline.rawValue)",
            "soft-keyboard-with-hardware = \(b(softKeyboardWithHardware))", "mouse-reporting = \(b(mouseReporting))",
            "agent = \(agent.rawValue)",
            "agent-media = \(agentMedia.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "")",
            "media-dir = \(mediaDir)", "media-retention = \(mediaRetentionDays)d",
            "media-strip-location = \(b(mediaStripLocation))", "media-insert = \"\(mediaInsert)\"",
            "video-mode = \(videoMode.rawValue)", "video-frames = \(videoFrames)",
            "video-sheet-size = \(videoSheetSize)", "video-transcribe = \(b(videoTranscribe))",
            "audio-mode = \(audioMode.rawValue)",
            "app-lock = \(b(appLock))", "privacy-blur = \(b(privacyBlur))", "clipboard-clear = \(dur(clipboardClear))",
        ]
        return out
    }
}
