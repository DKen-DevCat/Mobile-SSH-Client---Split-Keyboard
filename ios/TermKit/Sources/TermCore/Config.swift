import Foundation

/// 設定ファイル 1 枚の中身（docs/design.md「設定ファイル」）。Ghostty と同じく `key = value` を 1 行に 1 つ書く。
/// 書かなかった項目は既定値。秘密（鍵・パスワード）はここに置かない（キーチェーン）
public struct TermConfig: Equatable, Sendable {
    // MARK: 表示
    /// `system-mono` は iOS の等幅（SF Mono）
    public var fontFamily = "system-mono"
    public var fontFamilyCJK = "Hiragino Sans"
    /// 100% 表示のときの文字の大きさ（pt）
    public var fontSize = 10.0
    /// 表示倍率の段（%）。ピンチと倍率ボタンはこの段で止まる。先頭が起動時
    public var zoomSteps: [Int] = [85, 100]
    public var background = RGB(hex: "#07090D")!
    public var foreground = RGB(hex: "#E6EDF3")!
    public var cursorColor = RGB(hex: "#2F81F7")!
    public var accent = RGB(hex: "#2F81F7")!
    public var selectionBackground = RGB(hex: "#264F78")!
    public var palette: [RGB] = TermConfig.defaultPalette
    /// 文字と背景のコントラスト比の下限（1 で補正しない）
    public var minimumContrast = 4.5
    public var colorSpace: ColorSpace = .displayP3
    public var cursorStyle: CursorShape = .block
    public var cursorBlink = false
    public var scrollbackLimit = 10_000

    // MARK: キーボード
    public var keyboard: KeyboardKind = .us
    /// キーの基準の大きさ（pt）。nil なら画面から算出する
    public var keyboardPitch: Double? = nil
    public var keyRepeatDelay = 0.40
    public var keyRepeatInterval = 0.05
    public var optionAsMeta = true
    public var haptics = true
    public var newline: NewlineMode = .auto
    /// ハードウェアキーボードがつながっていても、画面のキーボードを出し続けるか
    public var softKeyboardWithHardware = false

    // MARK: 接続
    public var hosts: [HostEntry] = []
    /// 起動時につなぐ接続先（`host` の名前）。空なら最初の 1 つ。`none` ならつながない
    public var autoConnect = ""
    public var term = "xterm-256color"
    /// TCP の keepalive の間隔（秒）。0 で使わない
    public var keepalive = 15.0
    public var reconnect = true
    public var passwordAuth = false

    // MARK: 安全
    public var appLock = true
    public var privacyBlur = true
    /// アプリからコピーした内容を消すまでの秒数。0 で消さない
    public var clipboardClear = 60.0
    public var mouseReporting = true

    public init() {}

    public static let defaultPalette: [RGB] = [
        "#1C2128", "#FF5F6D", "#3FE08A", "#FFB454", "#2F81F7", "#FF6AC1", "#5CE1E6", "#C9D1D9",
        "#545D68", "#FF8A94", "#7BF0B0", "#FFCC85", "#6CA6FF", "#FF9AD6", "#8EEFF2", "#FFFFFF",
    ].map { RGB(hex: $0)! }

    /// 起動時の倍率（%）
    public var initialZoom: Int { zoomSteps.first ?? 100 }

    /// 名前で接続先を探す
    public func host(named name: String) -> HostEntry? {
        hosts.first { $0.name == name }
    }

    /// 起動時につなぐ接続先
    public var autoConnectHost: HostEntry? {
        if autoConnect == "none" { return nil }
        if autoConnect.isEmpty { return hosts.first }
        return host(named: autoConnect)
    }
}

public enum ColorSpace: String, Sendable, CaseIterable {
    /// テーマの値を Display P3 の座標として描く（sRGB より鮮やか）
    case displayP3 = "display-p3"
    case srgb
}

public enum CursorShape: String, Sendable, CaseIterable {
    case block, bar, underline
}

public enum KeyboardKind: String, Sendable, CaseIterable {
    case us, kana
}

/// 改行キーが送るもの（docs/design.md「改行と送信」）
public enum NewlineMode: String, Sendable, CaseIterable {
    /// 接続先が括弧付きペーストを有効にしていれば、改行 1 文字を貼り付けとして送る。無効なら ESC+CR
    case auto
    case paste
    case escCR = "esc-cr"
    case ctrlJ = "ctrl-j"
}

/// `host = <名前> <ユーザー>@<アドレス>[:<ポート>] [tmux=<セッション名>|none] [auth=key|password]`
public struct HostEntry: Equatable, Sendable, Hashable {
    public var name: String
    public var user: String
    public var address: String
    public var port: Int = 22
    /// 接続時に `tmux new -A -s <名前>` を実行する。nil なら素のシェル
    public var tmuxSession: String? = "main"
    public var auth: AuthKind = .key

    public init(name: String, user: String, address: String, port: Int = 22,
                tmuxSession: String? = "main", auth: AuthKind = .key) {
        self.name = name
        self.user = user
        self.address = address
        self.port = port
        self.tmuxSession = tmuxSession
        self.auth = auth
    }

    public enum AuthKind: String, Sendable, CaseIterable {
        case key, password
    }

    /// 接続後に実行するコマンド。nil なら shell を要求する。
    /// SSH の exec はログインシェルを通らず、Homebrew の PATH（.zprofile）が効かないので、ログインシェルで包む。
    /// tmux が無ければ、知らせて素のシェルを開く
    public var startupCommand: String? {
        guard let s = tmuxSession else { return nil }
        // 名前は parse で英数と - _ . に限っているので、引用符の中にそのまま入れてよい
        return "exec \"$SHELL\" -lc 'if command -v tmux >/dev/null 2>&1; then exec tmux -u new-session -A -s \(s); "
            + "else echo \"tmux が見つかりません。素のシェルを開きます\"; exec \"$SHELL\" -l; fi'"
    }

    /// 鍵の保存（ホスト鍵）に使う識別子
    public var endpointID: String { "\(address):\(port)" }
}
