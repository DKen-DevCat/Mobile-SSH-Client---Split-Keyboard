import Foundation

// メディアを送る（docs/design.md「メディアを送る」「動画を画像にして送る」）。ここは画面にも通信にも頼らない判断だけ

/// 送るものの種類（拡張子から）
public enum MediaSource: Equatable, Sendable {
    case image(ext: String)
    case video(ext: String)
    case audio(ext: String)
    case other(ext: String)

    public init(fileExtension: String) {
        let e = fileExtension.lowercased()
        switch e {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "dng", "bmp": self = .image(ext: e)
        case "mov", "mp4", "m4v", "hevc": self = .video(ext: e)
        case "m4a", "aac", "wav", "mp3", "caf", "aiff", "aif": self = .audio(ext: e)
        default: self = .other(ext: e)
        }
    }
}

/// 送る前にアプリがすること
public enum MediaStep: Equatable, Sendable {
    /// 原本をそのまま（位置情報だけ外すかは別に決める）
    case original
    /// 画像を JPEG に（エージェントが読めない形式）。大きさは変えない
    case convertToJPEG
    /// 動画をコンタクトシートと添え書きに
    case contactSheet
    /// 音声（動画の音声を含む）を端末の中で文字にする
    case transcript
}

public enum MediaPlan {
    /// 何を送るか。エージェントが読める種類と形式、config の送り方から決める
    public static func steps(for source: MediaSource, config: TermConfig) -> [MediaStep] {
        let readable = config.readableMedia
        switch source {
        case .image(let ext):
            if readable.contains(.image), config.agent.imageFormats.contains(ext) { return [.original] }
            return [.convertToJPEG]
        case .video:
            let canRead = readable.contains(.video)
            let sheet: [MediaStep] = config.videoTranscribe ? [.contactSheet, .transcript] : [.contactSheet]
            switch config.videoMode {
            case .auto: return canRead ? [.original] : sheet
            case .file: return [.original]
            case .frames: return sheet
            case .both: return [.original] + sheet
            }
        case .audio:
            let canRead = readable.contains(.audio)
            switch config.audioMode {
            case .auto: return canRead ? [.original] : [.transcript]
            case .file: return [.original]
            case .transcript: return [.transcript]
            case .both: return [.original, .transcript]
            }
        case .other:
            return [.original]
        }
    }
}

/// 受け取り箱の名前（アプリが付ける。日時と乱数だけで、人が入れた文字は入らない）
public struct InboxName: Equatable, Sendable {
    /// `20261030-101010-ab12`
    public let base: String

    public init(date: Date, random: UInt16, timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        base = String(format: "%04d%02d%02d-%02d%02d%02d-%04x", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, random)
    }

    /// 拡張子は英数だけ（無ければ bin）
    public func file(ext: String) -> String {
        let clean = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "\(base).\(clean.isEmpty ? "bin" : String(clean.prefix(8)))"
    }

    public var sheet: String { "\(base).sheet.jpg" }
    public var videoNotes: String { "\(base).video.md" }
    public var transcript: String { "\(base).transcript.md" }

    /// 受け取り箱の名前として正しいか（接続先のシェルに渡す前に必ず確かめる）
    public static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && !name.hasPrefix(".") && name.unicodeScalars.allSatisfy { u in
            ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || u == "." || u == "-" || u == "_"
        }
    }
}

/// 送るときに接続先で動かすコマンド（決まった文字列に、確かめた名前と場所だけを入れる）
public enum RemoteCommands {
    public struct UnsafeInput: Error, Equatable {}

    /// 受け取り箱の場所をシェルの書き方に。`~/x` は `"$HOME"/'x'`、`/x` は `'/x'`
    static func dir(_ mediaDir: String) throws -> String {
        guard ConfigParser.isRemotePath(mediaDir) else { throw UnsafeInput() }
        if mediaDir.hasPrefix("~/") { return "\"$HOME\"/'\(mediaDir.dropFirst(2))'" }
        return "'\(mediaDir)'"
    }

    /// 受け取り箱を作り、古いものを消し、途中まで届いている大きさと、受け取り箱の絶対パスを出す（2 行）
    public static func prepare(mediaDir: String, name: String, retentionDays: Int) throws -> String {
        guard InboxName.isSafe(name), retentionDays >= 0 else { throw UnsafeInput() }
        let d = try dir(mediaDir)
        let clean = retentionDays > 0
            ? "find . -maxdepth 1 -type f -mtime +\(retentionDays) -delete 2>/dev/null; " : ""
        return "umask 077; mkdir -p \(d) && cd \(d) && { \(clean)true; } && "
            + "if [ -f '\(name).part' ]; then wc -c < '\(name).part' | tr -d ' '; else echo 0; fi && pwd -P"
    }

    /// 標準入力を、途中まで届いているファイルの続きに書く
    public static func append(mediaDir: String, name: String) throws -> String {
        guard InboxName.isSafe(name) else { throw UnsafeInput() }
        return "umask 077; cat >> \(try dir(mediaDir))/'\(name).part'"
    }

    /// SHA-256 が合えば .part を外して ok を出す。合わなければ .part を消して ng（次は最初から送る）
    public static func finish(mediaDir: String, name: String, sha256: String) throws -> String {
        guard InboxName.isSafe(name), sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UnsafeInput()
        }
        let d = try dir(mediaDir)
        return "cd \(d) && s=$( (shasum -a 256 '\(name).part' 2>/dev/null || sha256sum '\(name).part') | cut -d' ' -f1 ) && "
            + "if [ \"$s\" = '\(sha256)' ]; then mv '\(name).part' '\(name)' && echo ok; else rm -f '\(name).part'; echo ng; fi"
    }

    /// 途中まで届いているものを捨てる（手元のファイルより大きいなど、続きから送れないとき）
    public static func discard(mediaDir: String, name: String) throws -> String {
        guard InboxName.isSafe(name) else { throw UnsafeInput() }
        return "rm -f \(try dir(mediaDir))/'\(name).part'"
    }

    /// prepare の出力を読む（届いている大きさ、受け取り箱の絶対パス）
    public static func parsePrepare(_ output: String) -> (offset: Int, directory: String)? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let offset = Int(lines[lines.count - 2]), offset >= 0,
              lines[lines.count - 1].hasPrefix("/") else { return nil }
        return (offset, lines[lines.count - 1])
    }
}

/// 送った後に入力行へ入れる文字（media-insert）。パスに決まった文字以外があれば引用符で囲む
public enum MediaInsert {
    public static func text(template: String, paths: [String]) -> String {
        let quoted = paths.map { p -> String in
            let safe = p.unicodeScalars.allSatisfy { u in
                ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || "./_-~".unicodeScalars.contains(u)
            }
            return safe ? p : "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return template.replacingOccurrences(of: "{paths}", with: quoted.joined(separator: " "))
    }
}

// MARK: - 動画のコンタクトシート

public enum ContactSheetPlanner {
    /// 下見で取る時刻（0.5 秒ごと、最大 240 枚。短い動画も 1 枚は取る）
    public static func probeTimes(duration: Double, maxSamples: Int = 240) -> [Double] {
        guard duration > 0 else { return [0] }
        let step = max(0.5, duration / Double(maxSamples))
        return stride(from: 0, to: duration, by: step).map { $0 }
    }

    /// 並べる枚数（10 秒未満なら半分、動画の下見の枚数より多くはしない）
    public static func frameCount(duration: Double, configured: Int, available: Int) -> Int {
        let n = duration < 10 ? max(1, (configured + 1) / 2) : configured
        return max(1, min(n, available))
    }

    /// 場面の変わり目を優先しつつ、時間が偏らないように `count` 枚を選ぶ（時刻順に返す）。
    /// `scores[i]` は時刻 `times[i]` の直前との違い（大きいほど変わった）。最初の 1 枚は必ず入れる
    public static func select(times: [Double], scores: [Double], count: Int) -> [Double] {
        precondition(times.count == scores.count)
        guard !times.isEmpty, count > 0 else { return [] }
        if times.count <= count { return times }
        // 時間を count 個の区間に分け、各区間で最も変わった時刻を選ぶ（区間の中で同点なら早い方）
        let start = times[0], end = times[times.count - 1]
        let span = max(end - start, 1e-9)
        var picked: [Double] = []
        for k in 0..<count {
            let lo = start + span * Double(k) / Double(count)
            let hi = k == count - 1 ? end + 1e-9 : start + span * Double(k + 1) / Double(count)
            let idx = times.indices.filter { times[$0] >= lo && times[$0] < hi }
            guard let first = idx.first else { continue }
            if k == 0 {
                picked.append(times[first])
                continue
            }
            let best = idx.max { a, b in scores[a] < scores[b] || (scores[a] == scores[b] && a > b) }!
            picked.append(times[best])
        }
        return picked
    }

    public struct Layout: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var tileWidth: Int
        public var tileHeight: Int
        public var width: Int { columns * tileWidth }
        public var height: Int { rows * tileHeight }
    }

    /// 並べ方。シートの長い辺を `longSide` に収め、タイルは動画の縦横比のまま。列と行は、シートが正方形から
    /// 離れすぎないように選ぶ（横長の動画 12 枚は 4×3、縦長の動画 12 枚は 6×2）
    public static func layout(count: Int, videoWidth: Double, videoHeight: Double, longSide: Int) -> Layout {
        let n = max(1, count)
        let aspect = videoWidth > 0 && videoHeight > 0 ? videoWidth / videoHeight : 16.0 / 9.0
        var best: (cols: Int, rows: Int, score: Double)?
        for cols in 1...n {
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            guard (cols - 1) * rows < n else { continue }  // 空の列ができない
            let sheetAspect = Double(cols) * aspect / Double(rows)
            // 16:9 前後のシートが、画面にも画像の入力にも収まりがよい。空きのタイルは減点
            let score = abs(log(sheetAspect / (16.0 / 9.0))) + Double(cols * rows - n) * 0.15
            // 同点なら列の多い方（横長のシート。同じ長い辺なら面積が小さく、トークンが少ない）
            if best == nil || score <= best!.score { best = (cols, rows, score) }
        }
        let cols = best!.cols, rows = best!.rows
        let sheetAspect = Double(cols) * aspect / Double(rows)
        let (w, h): (Double, Double) = sheetAspect >= 1
            ? (Double(longSide), Double(longSide) / sheetAspect)
            : (Double(longSide) * sheetAspect, Double(longSide))
        return Layout(columns: cols, rows: rows,
                      tileWidth: max(16, Int(w / Double(cols))), tileHeight: max(16, Int(h / Double(rows))))
    }

    /// 0:00 の形（1 時間を超えたら 1:02:03）
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 画像のトークンの目安（Claude: 幅×高さ÷750）
    public static func estimatedTokens(width: Int, height: Int) -> Int {
        Int((Double(width * height) / 750).rounded(.up))
    }
}

/// 動画の添え書き（Markdown）。シートの読み方と、各タイルの時刻、文字起こし
public enum VideoNotes {
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var text: String
        public init(start: Double, text: String) {
            self.start = start
            self.text = text
        }
    }

    public static func render(originalName: String?, duration: Double, width: Int, height: Int,
                              sheetName: String, layout: ContactSheetPlanner.Layout, times: [Double],
                              transcript: [Segment]?, transcriptNote: String? = nil) -> String {
        var lines = [
            "# 動画の要約（Mobile-SSH-Client---Split-Keyboard）",
            "",
            "- 長さ: \(ContactSheetPlanner.timestamp(duration))（\(String(format: "%.1f", duration)) 秒）",
            "- 解像度: \(width)×\(height)",
        ]
        if let originalName { lines.append("- 元の動画: \(originalName)") }
        lines += [
            "- シート: \(sheetName)（\(layout.columns)×\(layout.rows)、\(layout.width)×\(layout.height)px）",
            "",
            "シートは動画から選んだ \(times.count) 枚を、左上から右へ時刻順に並べたもの。各タイルの左下の数字が動画の中の時刻。",
            "",
            "| タイル | 時刻 |",
            "|---|---|",
        ]
        for (i, t) in times.enumerated() {
            lines.append("| \(i + 1)（\(i / layout.columns + 1) 行 \(i % layout.columns + 1) 列） | \(ContactSheetPlanner.timestamp(t)) |")
        }
        lines += ["", "## 文字起こし", ""]
        if let transcript, !transcript.isEmpty {
            for s in transcript {
                let text = s.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                lines.append("- [\(ContactSheetPlanner.timestamp(s.start))] \(text)")
            }
        } else {
            lines.append(transcriptNote ?? "（なし）")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
