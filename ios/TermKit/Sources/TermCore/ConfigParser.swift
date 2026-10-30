import Foundation

/// 設定ファイルの読み方（Ghostty と同じ形）
/// - 1 行に `key = value`。`#` で始まる行と空行は読み飛ばす
/// - 値は前後の空白を除く。空白を残したいときは `"..."` で囲む
/// - 値を空にする（`key =`）と既定値に戻す
/// - `palette`（番号ごとに上書き）と `host`（書いた順に足す）は何度でも書ける
/// - 読めない行は飛ばして、行番号付きの指摘（diagnostics）を返す。1 行の誤りで全体を捨てない
public struct ConfigDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "\(line) 行目: \(message)" }
}

public enum ConfigParser {
    public static func parse(_ text: String) -> (config: TermConfig, diagnostics: [ConfigDiagnostic]) {
        var config = TermConfig()
        var diags: [ConfigDiagnostic] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                diags.append(.init(line: lineNo, message: "`key = value` の形ではありません"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            do {
                try apply(key: key, value: value, to: &config)
            } catch let e as ConfigError {
                diags.append(.init(line: lineNo, message: e.message))
            } catch {
                diags.append(.init(line: lineNo, message: "\(error)"))
            }
        }
        return (config, diags)
    }

    struct ConfigError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    static func apply(key: String, value: String, to c: inout TermConfig) throws {
        let d = TermConfig()
        let reset = value.isEmpty
        switch key {
        case "font-family": c.fontFamily = reset ? d.fontFamily : value
        case "font-family-cjk": c.fontFamilyCJK = reset ? d.fontFamilyCJK : value
        case "font-size": c.fontSize = reset ? d.fontSize : try number(value, in: 4...40)
        case "zoom-steps":
            if reset { c.zoomSteps = d.zoomSteps; return }
            let steps = try value.split(separator: ",").map { s -> Int in
                let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                guard let v = Int(t), (50...200).contains(v) else {
                    throw ConfigError("zoom-steps は 50〜200 の整数（%）をカンマで並べます")
                }
                return v
            }
            guard !steps.isEmpty else { throw ConfigError("zoom-steps が空です") }
            c.zoomSteps = steps
        case "background": c.background = reset ? d.background : try color(value)
        case "foreground": c.foreground = reset ? d.foreground : try color(value)
        case "cursor-color": c.cursorColor = reset ? d.cursorColor : try color(value)
        case "accent": c.accent = reset ? d.accent : try color(value)
        case "selection-background":
            c.selectionBackground = reset ? d.selectionBackground : try color(value)
        case "palette":
            if reset { c.palette = d.palette; return }
            // `palette = 1=#FF5F6D`（Ghostty と同じ）
            let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i) else {
                throw ConfigError("palette は `palette = 番号(0〜15)=#RRGGBB` の形です")
            }
            c.palette[i] = try color(parts[1])
        case "minimum-contrast": c.minimumContrast = reset ? d.minimumContrast : try number(value, in: 1...21)
        case "color-space": c.colorSpace = reset ? d.colorSpace : try choice(value, key: key)
        case "cursor-style": c.cursorStyle = reset ? d.cursorStyle : try choice(value, key: key)
        case "cursor-blink": c.cursorBlink = reset ? d.cursorBlink : try bool(value)
        case "scrollback-limit":
            c.scrollbackLimit = reset ? d.scrollbackLimit : Int(try number(value, in: 0...200_000))

        case "keyboard": c.keyboard = reset ? d.keyboard : try choice(value, key: key)
        case "keyboard-pitch":
            c.keyboardPitch = reset || value == "auto" ? nil : try number(value, in: 20...80)
        case "key-repeat-delay": c.keyRepeatDelay = reset ? d.keyRepeatDelay : try duration(value, defaultUnit: .ms)
        case "key-repeat-interval":
            c.keyRepeatInterval = reset ? d.keyRepeatInterval : try duration(value, defaultUnit: .ms)
        case "option-as-meta": c.optionAsMeta = reset ? d.optionAsMeta : try bool(value)
        case "haptics": c.haptics = reset ? d.haptics : try bool(value)
        case "newline": c.newline = reset ? d.newline : try choice(value, key: key)
        case "soft-keyboard-with-hardware":
            c.softKeyboardWithHardware = reset ? d.softKeyboardWithHardware : try bool(value)

        case "host":
            if reset { c.hosts = []; return }
            let h = try host(value)
            if c.hosts.contains(where: { $0.name == h.name }) {
                throw ConfigError("host の名前 `\(h.name)` が重なっています")
            }
            c.hosts.append(h)
        case "auto-connect": c.autoConnect = reset ? d.autoConnect : value
        case "term": c.term = reset ? d.term : value
        case "keepalive": c.keepalive = reset ? d.keepalive : try duration(value, defaultUnit: .s)
        case "reconnect": c.reconnect = reset ? d.reconnect : try bool(value)
        case "password-auth": c.passwordAuth = reset ? d.passwordAuth : try bool(value)

        case "app-lock": c.appLock = reset ? d.appLock : try bool(value)
        case "privacy-blur": c.privacyBlur = reset ? d.privacyBlur : try bool(value)
        case "clipboard-clear": c.clipboardClear = reset ? d.clipboardClear : try duration(value, defaultUnit: .s)
        case "mouse-reporting": c.mouseReporting = reset ? d.mouseReporting : try bool(value)
        default:
            throw ConfigError("知らない項目 `\(key)` です")
        }
    }

    static func number(_ s: String, in range: ClosedRange<Double>) throws -> Double {
        guard let v = Double(s), range.contains(v) else {
            throw ConfigError("`\(s)` は \(fmt(range.lowerBound))〜\(fmt(range.upperBound)) の数ではありません")
        }
        return v
    }

    static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    static func bool(_ s: String) throws -> Bool {
        switch s.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw ConfigError("`\(s)` は true か false で書きます")
        }
    }

    static func color(_ s: String) throws -> RGB {
        guard let c = RGB(hex: s) else { throw ConfigError("`\(s)` は #RRGGBB の色ではありません") }
        return c
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ s: String, key: String) throws -> T
    where T.RawValue == String {
        guard let v = T(rawValue: s.lowercased()) else {
            let all = T.allCases.map(\.rawValue).joined(separator: " / ")
            throw ConfigError("\(key) は \(all) のどれかです（`\(s)`）")
        }
        return v
    }

    enum Unit { case ms, s }

    /// `400ms`・`1.5s`・`60`（単位を省くと項目ごとの単位）。秒で返す
    static func duration(_ s: String, defaultUnit: Unit) throws -> Double {
        let t = s.lowercased()
        let (num, unit): (Substring, Unit) =
            t.hasSuffix("ms") ? (t.dropLast(2), .ms) :
            t.hasSuffix("s") ? (t.dropLast(1), .s) : (Substring(t), defaultUnit)
        guard let v = Double(num.trimmingCharacters(in: .whitespaces)), v.isFinite, v >= 0 else {
            throw ConfigError("`\(s)` は時間（例 400ms、60s）ではありません")
        }
        let seconds = unit == .ms ? v / 1000 : v
        // 1 日を上限にする（大きすぎる値で整数への変換が落ちないように）
        guard seconds <= 86_400 else { throw ConfigError("`\(s)` は長すぎます（1 日まで）") }
        return seconds
    }

    /// 英数と . _ - だけ（tmux のセッション名としてそのままコマンドに渡すため）
    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { u in
            ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u)
                || u == "." || u == "_" || u == "-"
        }
    }

    /// `mac dken@mac.example.ts.net:22 tmux=main auth=key`
    static func host(_ value: String) throws -> HostEntry {
        let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2 else {
            throw ConfigError("host は `host = 名前 ユーザー@アドレス[:ポート] [tmux=名前|none] [auth=key|password]` です")
        }
        let name = fields[0]
        guard isName(name) else { throw ConfigError("host の名前 `\(name)` は英数と . _ - だけで書きます") }
        guard let at = fields[1].lastIndex(of: "@") else {
            throw ConfigError("`\(fields[1])` に ユーザー@ がありません")
        }
        let user = String(fields[1][..<at])
        var rest = String(fields[1][fields[1].index(after: at)...])
        var port = 22
        if rest.hasPrefix("[") {
            // IPv6: [::1]:22
            guard let close = rest.firstIndex(of: "]") else { throw ConfigError("`\(rest)` の ] が閉じていません") }
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = Int(after.dropFirst()), (1...65535).contains(p) else {
                    throw ConfigError("ポート `\(after.dropFirst())` が正しくありません")
                }
                port = p
            }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if let colon = rest.lastIndex(of: ":"), rest.filter({ $0 == ":" }).count == 1 {
            guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else {
                throw ConfigError("ポート `\(rest[rest.index(after: colon)...])` が正しくありません")
            }
            port = p
            rest = String(rest[..<colon])
        }
        guard !user.isEmpty, !rest.isEmpty else { throw ConfigError("ユーザーかアドレスが空です") }
        var entry = HostEntry(name: name, user: user, address: rest, port: port)
        for opt in fields.dropFirst(2) {
            let kv = opt.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { throw ConfigError("`\(opt)` は key=value の形ではありません") }
            switch kv[0] {
            case "tmux":
                if kv[1] == "none" {
                    entry.tmuxSession = nil
                } else {
                    guard isName(kv[1]) else { throw ConfigError("tmux のセッション名は英数と . _ - だけで書きます") }
                    entry.tmuxSession = kv[1]
                }
            case "auth":
                guard let a = HostEntry.AuthKind(rawValue: kv[1]) else {
                    throw ConfigError("auth は key か password です")
                }
                entry.auth = a
            default:
                throw ConfigError("host の知らない指定 `\(kv[0])` です")
            }
        }
        return entry
    }
}
