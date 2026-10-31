import Foundation
import SwiftTerm
import TermCore

/// 描画に渡す 1 セル。色はテーマを当てた後の値
public struct ScreenCell: Equatable, Sendable {
    /// 空のセル・全角の続きは ""
    public var text: String
    /// 全角（2 セル幅）の先頭
    public var wide: Bool
    public var fg: RGB
    public var bg: RGB
    public var flags: Flags

    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let bold = Flags(rawValue: 1)
        public static let italic = Flags(rawValue: 2)
        public static let underline = Flags(rawValue: 4)
        public static let strike = Flags(rawValue: 8)
    }

    public static func blank(_ theme: Theme) -> ScreenCell {
        ScreenCell(text: "", wide: false, fg: theme.foreground, bg: theme.background, flags: [])
    }
}

/// 画面 1 枚ぶん（行 × 桁）
public struct ScreenFrame: Sendable {
    public var cols: Int
    public var rows: Int
    /// rows × cols。行ごとに並ぶ
    public var cells: [ScreenCell]
    /// 見えているカーソル（隠れているなら nil）
    public var cursor: Cursor?
    /// カーソルの位置（隠れていても。見えている範囲の外なら nil）。先行表示の突き合わせに使う
    /// （Claude Code はカーソルを隠し、入力欄に自分でカーソルを描く。docs/design.md「先行表示」）
    public var caret: Cursor?
    /// 表示している先頭行（スクロールバックを含めた通し番号）
    public var topRow: Int
    /// 最下部（入力位置）を見ているか
    public var atBottom: Bool

    public struct Cursor: Equatable, Sendable {
        public var col: Int
        public var row: Int
        public var shape: CursorShape
    }

    public func cell(col: Int, row: Int) -> ScreenCell { cells[row * cols + col] }
}

/// 接続先の状態のうち、入力ルータがモードを決めるのに使うもの（docs/design.md「3 つのモード」）
public struct TerminalModes: Equatable, Sendable {
    public var applicationCursor = false
    public var bracketedPaste = false
    public var mouseReporting = false
    public var alternateScreen = false
    public init() {}
}

/// テーマ（設定から作る）。色を決める規則は TermCore の `CellColorRules`（純粋な関数）で、
/// ここは SwiftTerm のセルをその入力に直して呼び、コントラストの補正の結果を覚える
public final class Theme: @unchecked Sendable {
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    public let selection: RGB
    public let minimumContrast: Double
    let rules: CellColorRules
    private var contrastCache: [UInt64: RGB] = [:]
    private let lock = NSLock()

    public init(config: TermConfig) {
        foreground = config.foreground
        background = config.background
        cursor = config.cursorColor
        selection = config.selectionBackground
        minimumContrast = config.minimumContrast
        rules = CellColorRules(config: config)
    }

    /// SwiftTerm の色の指定を、規則の入力に直す
    static func cellColor(_ c: Attribute.Color) -> CellColor {
        switch c {
        case .ansi256(let code): return .palette(Int(code))
        case .trueColor(let r, let g, let b): return .rgb(RGB(r, g, b))
        case .defaultColor: return .defaultColor
        case .defaultInvertedColor: return .defaultInverted
        }
    }

    /// 文字色を、背景とのコントラスト比の下限まで補正する（結果は覚えておく）
    func readable(_ fg: RGB, on bg: RGB) -> RGB {
        guard minimumContrast > 1 else { return fg }
        let key = UInt64(fg.r) << 40 | UInt64(fg.g) << 32 | UInt64(fg.b) << 24
            | UInt64(bg.r) << 16 | UInt64(bg.g) << 8 | UInt64(bg.b)
        lock.lock()
        defer { lock.unlock() }
        if let hit = contrastCache[key] { return hit }
        let out = Contrast.adjusted(foreground: fg, background: bg, minimum: minimumContrast)
        if contrastCache.count > 4096 { contrastCache.removeAll(keepingCapacity: true) }
        contrastCache[key] = out
        return out
    }

    func cell(text: String, width: Int8, attribute a: Attribute) -> ScreenCell {
        let style = a.style
        var colorFlags: CellColorFlags = []
        if style.contains(.inverse) { colorFlags.insert(.inverse) }
        if style.contains(.dim) { colorFlags.insert(.dim) }
        if style.contains(.invisible) { colorFlags.insert(.invisible) }
        if style.contains(.bold) { colorFlags.insert(.bold) }
        let (fg, bg) = rules.resolve(fg: Self.cellColor(a.fg), bg: Self.cellColor(a.bg), flags: colorFlags) {
            readable($0, on: $1)
        }
        var flags: ScreenCell.Flags = []
        if style.contains(.bold) { flags.insert(.bold) }
        if style.contains(.italic) { flags.insert(.italic) }
        if style.contains(.underline) { flags.insert(.underline) }
        if style.contains(.crossedOut) { flags.insert(.strike) }
        return ScreenCell(text: width == 0 ? "" : text, wide: width == 2, fg: fg, bg: bg, flags: flags)
    }
}

/// 端末の解釈（SwiftTerm の解釈と画面バッファの部分だけを使う。描画は Metal で自前）。
/// 受信したバイト列の解釈は専用のキューで行い、メインスレッドは描くときに短くロックして写しを取る
/// （docs/design.md「メインスレッドを空ける」）
public final class TerminalEngine: TerminalDelegate, @unchecked Sendable {
    public private(set) var terminal: Terminal!
    let queue = DispatchQueue(label: "splitterm.terminal.parse", qos: .userInteractive)
    /// 1 回のロックで解釈する最大のバイト数。大きいと描画と入力が待たされる
    static let chunk = 16 * 1024

    /// 端末から接続先への応答（DA など）。解釈のキューから呼ぶ
    public var onResponse: (@Sendable ([UInt8]) -> Void)?
    /// 画面が変わった。解釈のキューから呼ぶ（描画側は次のフレームで描く）
    public var onDisplayNeeded: (@Sendable () -> Void)?
    /// 題名・ベル・モードの変化。メインスレッドで呼ぶ
    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onModesChanged: (() -> Void)?
    /// 解析待ちが多すぎる（true）／減った（false）。受信を止める・再開するのに使う。解析のキューか受信のスレッドから呼ぶ
    public var onBacklog: (@Sendable (Bool) -> Void)?

    /// 解析待ちのバイト数と、受信を止めているか（state で守る）
    private let state = NSLock()
    private var pendingBytes = 0
    private var paused = false
    /// 受信を止めているか（接続を替えたとき、新しい接続も止めておくのに使う）
    public var isBacklogged: Bool { state.withLock { paused } }
    static let backlogHigh = 8 * 1024 * 1024
    static let backlogLow = 1 * 1024 * 1024
    // 題名・ベル・モードの知らせは、接続先が連打してもメインスレッドへは 1 回にまとめる
    private var pendingTitle: String?
    private var mainNoticeScheduled = false
    private var pendingBell = false
    private var pendingModes = false

    public init(cols: Int, rows: Int, scrollback: Int, termName: String) {
        var options = TerminalOptions.default
        options.cols = max(1, cols)
        options.rows = max(1, rows)
        options.scrollback = scrollback
        options.termName = termName
        // 画像は描かない。kitty の画像は受け取らない（接続先が 1 画面あたり最大 10MB を置けてしまうのを防ぐ）。
        // sixel は対応していると答えない。ただし SwiftTerm に解釈を止める公開の口が無いので、送られれば SwiftTerm の上限の中で解釈される
        options.kittyGraphics.storageLimitBytesPerScreen = 0
        options.enableSixelReported = false
        terminal = Terminal(delegate: self, options: options)
    }

    // MARK: 受信

    /// 接続先からのバイト列。どのスレッドからでもよい。順番どおりに解釈する
    public func feed(_ bytes: [UInt8]) {
        let pause: Bool = state.withLock {
            pendingBytes += bytes.count
            if !paused && pendingBytes > Self.backlogHigh {
                paused = true
                return true
            }
            return false
        }
        if pause { onBacklog?(true) }
        queue.async { [self] in
            var i = 0
            while i < bytes.count {
                let end = min(i + Self.chunk, bytes.count)
                terminal.terminalLock.withLock { terminal.feed(buffer: bytes[i..<end]) }
                i = end
            }
            let resume: Bool = state.withLock {
                pendingBytes -= bytes.count
                if paused && pendingBytes < Self.backlogLow {
                    paused = false
                    return true
                }
                return false
            }
            if resume { onBacklog?(false) }
            onDisplayNeeded?()
        }
    }

    public func resize(cols: Int, rows: Int) {
        terminal.terminalLock.withLock { terminal.resize(cols: max(1, cols), rows: max(1, rows)) }
        onDisplayNeeded?()
    }

    // MARK: 読む（メインスレッド）

    public func modes() -> TerminalModes {
        terminal.terminalLock.withLock {
            var m = TerminalModes()
            m.applicationCursor = terminal.applicationCursor
            m.bracketedPaste = terminal.bracketedPasteMode
            m.mouseReporting = terminal.mouseMode != .off
            m.alternateScreen = terminal.isCurrentBufferAlternate
            return m
        }
    }

    /// 最下部の画面の先頭行の通し番号と、遡れる最も古い行の通し番号
    public func scrollBounds() -> (oldest: Int, bottomTop: Int) {
        terminal.terminalLock.withLock {
            let oldest = terminal.buffer.totalLinesTrimmed
            return (oldest, oldest + terminal.buffer.yDisp)
        }
    }

    /// 画面を読む。`scrollTop` が nil なら最下部（入力位置）、値があればその通し番号の行から
    public func readScreen(theme: Theme, scrollTop: Int?, cursorShape: CursorShape) -> ScreenFrame {
        if scrollTop == nil {
            return readBottom(theme: theme, cursorShape: cursorShape)
        }
        return terminal.terminalLock.withLock {
            let t = terminal!
            let cols = t.cols, rows = t.rows
            let oldest = t.buffer.totalLinesTrimmed
            let bottomTop = oldest + t.buffer.yDisp
            let top = min(max(scrollTop!, oldest), bottomTop)
            var cells = [ScreenCell](repeating: .blank(theme), count: cols * rows)
            for r in 0..<rows {
                guard let line = t.getScrollInvariantLine(row: top + r) else { continue }
                let n = min(cols, line.count)
                for c in 0..<n {
                    let cd = line[c]
                    cells[r * cols + c] = theme.cell(text: t.getText(for: cd), width: cd.width, attribute: cd.attribute)
                }
            }
            let cursorAbs = bottomTop + t.buffer.y
            var cursor: ScreenFrame.Cursor? = nil
            if cursorAbs >= top && cursorAbs < top + rows {
                cursor = .init(col: min(t.buffer.x, cols - 1), row: cursorAbs - top, shape: cursorShape)
            }
            return ScreenFrame(cols: cols, rows: rows, cells: cells, cursor: cursor, caret: cursor, topRow: top,
                               atBottom: top == bottomTop)
        }
    }

    func readBottom(theme: Theme, cursorShape: CursorShape) -> ScreenFrame {
        // 行ごとの写しは SwiftTerm の中で使い回されるので、変わっていない行は安い
        let snap = terminal.makeRenderSnapshot(scope: .full)
        let top = scrollBounds().bottomTop
        let cols = snap.cols, rows = snap.rows
        var cells = [ScreenCell](repeating: .blank(theme), count: cols * rows)
        for line in snap.lines where line.y >= 0 && line.y < rows {
            let n = min(cols, line.cells.count)
            for c in 0..<n {
                let cell = line.cells[c]
                cells[line.y * cols + c] = theme.cell(text: cell.text, width: cell.width, attribute: cell.attribute)
            }
        }
        let caret: ScreenFrame.Cursor? = snap.cursor.y >= 0 && snap.cursor.y < rows
            ? .init(col: min(max(0, snap.cursor.x), max(0, cols - 1)), row: snap.cursor.y, shape: cursorShape) : nil
        let cursor: ScreenFrame.Cursor? = snap.cursor.hidden ? nil
            : .init(col: min(snap.cursor.x, cols - 1), row: snap.cursor.y, shape: cursorShape)
        return ScreenFrame(cols: cols, rows: rows, cells: cells, cursor: cursor, caret: caret, topRow: top, atBottom: true)
    }

    /// 通し番号で指定した範囲の文字（選択のコピー）。終わりの桁を含む
    public func text(from start: (row: Int, col: Int), to end: (row: Int, col: Int)) -> String {
        terminal.terminalLock.withLock {
            let t = terminal!
            var (a, b) = (start, end)
            if (b.row, b.col) < (a.row, a.col) { swap(&a, &b) }
            var out: [String] = []
            for row in a.row...b.row {
                guard let line = t.getScrollInvariantLine(row: row) else { continue }
                let s = row == a.row ? a.col : 0
                let e = row == b.row ? b.col + 1 : line.count
                let text = line.translateToString(trimRight: true, startCol: s, endCol: min(e, line.count),
                                                  skipNullCellsFollowingWide: true)
                // 折り返しの続きの行は前の行につなげる
                if row > a.row, line.isWrapped, !out.isEmpty {
                    out[out.count - 1] += text
                } else {
                    out.append(text)
                }
            }
            return out.joined(separator: "\n")
        }
    }

    /// カーソルのある行の各セルの幅（全角の先頭は 2、続きは 0）と、カーソルの桁。入力行のタップに使う
    public func cursorLine() -> (widths: [Int], col: Int, row: Int) {
        terminal.terminalLock.withLock {
            let t = terminal!
            let y = t.buffer.y
            guard let line = t.getLine(row: y) else { return ([], t.buffer.x, y) }
            var widths: [Int] = []
            widths.reserveCapacity(line.count)
            for c in 0..<line.count { widths.append(Int(line[c].width)) }
            return (widths, t.buffer.x, y)
        }
    }

    /// カーソルの行の、行頭からカーソルの手前までの文字（折り返しの続きなら前の行からつなげる。3 行まで）。
    /// 先行表示が、秘密の入力らしい行（`EchoPredictor.looksLikeSecretPrompt`）を見分けるのに使う
    public func cursorLinePrefix() -> String {
        terminal.terminalLock.withLock {
            let t = terminal!
            let y = t.buffer.y
            guard let line = t.getLine(row: y) else { return "" }
            var text = line.translateToString(trimRight: false, startCol: 0, endCol: min(t.buffer.x, line.count),
                                              skipNullCellsFollowingWide: true)
            var row = y, wrapped = line.isWrapped
            while wrapped, row > 0, y - row < 2, let prev = t.getLine(row: row - 1) {
                text = prev.translateToString(trimRight: false, startCol: 0, endCol: prev.count,
                                              skipNullCellsFollowingWide: true) + text
                wrapped = prev.isWrapped
                row -= 1
            }
            return text
        }
    }

    /// 見えている画面（最下部）の中のカーソルの位置（桁と行）。カーソルが隠れていても返す。
    /// 変換中の読みと先行表示を重ねる位置で、カーソルを隠す画面（Claude Code など）でも出せるようにする
    public func cursorPosition() -> (col: Int, row: Int) {
        terminal.terminalLock.withLock {
            let t = terminal!
            // 行の終わりに書いた直後は、桁が幅と同じになる（次の文字で折り返す）。画面の中に収める
            return (col: min(t.buffer.x, max(0, t.cols - 1)), row: min(t.buffer.y, max(0, t.rows - 1)))
        }
    }

    /// ダブルタップで選ぶ、つながっている文字列（通し番号の行と桁）。範囲と、改行を入れずにつなげた文字は、
    /// 画面にも SwiftTerm にも頼らない `ConnectedText.select` が決める。ここはロックの中で行を読んで渡すだけ
    public func connectedText(row: Int, col: Int) -> ConnectedText.Selection? {
        terminal.terminalLock.withLock {
            let t = terminal!
            return ConnectedText.select(row: row, col: col) { r in
                guard let line = t.getScrollInvariantLine(row: r) else { return nil }
                var cells: [ConnectedText.Cell] = []
                cells.reserveCapacity(line.count)
                // 全角の先頭は幅 2、その続きと、行末で全角が折り返した隙間は幅 0
                for c in 0..<line.count {
                    let cd = line[c]
                    cells.append(ConnectedText.Cell(t.getText(for: cd), width: Int(cd.width)))
                }
                return ConnectedText.Line(cells: cells, isWrapped: line.isWrapped)
            }
        }
    }

    // MARK: TerminalDelegate（解釈のキューで、ロックを持ったまま呼ばれる。端末の API は呼ばない）

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        onResponse?(Array(data))
    }

    /// 接続先を「信頼しない」。SwiftTerm の既定（信頼する）のままだと、画面の中身のチェックサムを接続先へ返す
    /// （DECRQCRA。画面の内容を少しずつ読み出す道になる）。作業ディレクトリの通知（OSC 6・7）も使わない
    public func isProcessTrusted(source: Terminal) -> Bool { false }

    // クリップボードの読み書き（OSC 52）と窓の操作（題名の送り返しなど）は、SwiftTerm の既定（何もしない）のまま

    public func setTerminalTitle(source: Terminal, title: String) {
        let clean = Self.sanitizeTitle(title)
        state.withLock { pendingTitle = clean }
        scheduleMainNotice()
    }

    /// 溜まった知らせをメインスレッドで 1 回にまとめて渡す
    private func scheduleMainNotice() {
        let schedule: Bool = state.withLock {
            if mainNoticeScheduled { return false }
            mainNoticeScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (title, bell, modes): (String?, Bool, Bool) = self.state.withLock {
                defer {
                    self.pendingTitle = nil
                    self.pendingBell = false
                    self.pendingModes = false
                    self.mainNoticeScheduled = false
                }
                return (self.pendingTitle, self.pendingBell, self.pendingModes)
            }
            if let title { self.onTitle?(title) }
            if bell { self.onBell?() }
            if modes { self.onModesChanged?() }
        }
    }

    /// 題名は接続先が自由に決める。制御文字と双方向の書式文字を除き、タブに収まる長さに切る
    public static func sanitizeTitle(_ title: String) -> String {
        let scalars = title.unicodeScalars.filter { u in
            !(u.value < 0x20 || (0x7F...0x9F).contains(u.value) || (0x200E...0x200F).contains(u.value)
              || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value))
        }
        let s = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return s.count > 40 ? String(s.prefix(39)) + "…" : s
    }

    public func bell(source: Terminal) {
        state.withLock { pendingBell = true }
        scheduleMainNotice()
    }

    public func mouseModeChanged(source: Terminal) {
        state.withLock { pendingModes = true }
        scheduleMainNotice()
    }

    public func bufferActivated(source: Terminal) {
        state.withLock { pendingModes = true }
        scheduleMainNotice()
    }
}
