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
    public var keyboard: KeyboardKind = .english
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
    /// アプリを開いていない時間がこれ（秒）を超えたら、次に開くときに Face ID を求める。0 で毎回
    public var appLockAfter = 900.0
    public var privacyBlur = true
    /// アプリからコピーした内容を消すまでの秒数。0 で消さない
    public var clipboardClear = 60.0
    public var mouseReporting = true

    // MARK: メディア（docs/design.md「メディアを送る」）
    /// 送り先のエージェント。読める形式と、動画・音声の既定の送り方を決める
    public var agent: AgentKind = .claudeCode
    /// 読める種類の上書き（`agent-media`）。nil なら agent の既定
    public var agentMedia: Set<MediaKind>? = nil
    /// 接続先の受け取り箱。`~/` か `/` で始まる、英数と . _ - / だけ（接続先のシェルに渡すため）
    public var mediaDir = "~/.splitterm/inbox"
    /// 受け取り箱に残す日数。0 なら消さない
    public var mediaRetentionDays = 7
    public var mediaStripLocation = true
    /// 送った後に入力行へ入れる文字。`{paths}` が送ったファイルのパス（空白区切り）になる
    public var mediaInsert = "{paths} "
    public var videoMode: VideoMode = .auto
    public var videoFrames = 12
    public var videoSheetSize = 1568
    public var videoTranscribe = true
    public var audioMode: AudioMode = .auto

    public init() {}

    /// 送り先のエージェントが読める種類
    public var readableMedia: Set<MediaKind> { agentMedia ?? agent.media }

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

/// 送り先のエージェント（docs/design.md「エージェントの読める形式」）
public enum AgentKind: String, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case generic

    /// そのまま読める画像の形式（拡張子、小文字）
    public var imageFormats: Set<String> {
        switch self {
        case .claudeCode, .codex: return ["png", "jpg", "jpeg", "gif", "webp"]
        case .generic: return ["png", "jpg", "jpeg"]
        }
    }

    /// 既定で読める種類。動画・音声を読めるエージェントは `agent-media` で足す
    public var media: Set<MediaKind> { [.image] }
}

public enum MediaKind: String, Sendable, CaseIterable, Hashable {
    case image, video, audio
}

/// 動画の送り方
public enum VideoMode: String, Sendable, CaseIterable {
    /// エージェントが動画を読めれば原本、読めなければコンタクトシート（＋文字起こし）
    case auto
    case file
    case frames
    case both
}

/// 音声の送り方
public enum AudioMode: String, Sendable, CaseIterable {
    /// エージェントが音声を読めれば原本、読めなければ文字起こし
    case auto
    case file
    case transcript
    case both
}

public enum ColorSpace: String, Sendable, CaseIterable {
    /// テーマの値を Display P3 の座標として描く（sRGB より鮮やか）
    case displayP3 = "display-p3"
    case srgb
}

public enum CursorShape: String, Sendable, CaseIterable {
    case block, bar, underline
}

/// キーボードの種類（docs/design.md「入力設計」）。🌐 の長押しで選ぶ
public enum KeyboardKind: String, Sendable, CaseIterable {
    /// 分割キーボード（ローマ字）。Mac の JIS 配列で、英字をローマ字としてかなにする
    case romaji
    /// 分割キーボード（英語）。Mac の JIS 配列（日本語の刻印なし）
    case english
    /// 日本語フリック分割
    case kana
    /// 英語フリック分割（ローマ字）。英字のフリックを、ローマ字としてかなにする
    case flickRomaji = "flick-romaji"
    /// 英語フリック分割（英語）
    case flickEnglish = "flick-english"

    /// 🌐 の長押しのメニューの順
    public static let menuOrder: [KeyboardKind] = [.romaji, .english, .kana, .flickRomaji, .flickEnglish]

    public var title: String {
        switch self {
        case .romaji: return "分割キーボード（ローマ字）"
        case .english: return "分割キーボード（英語）"
        case .kana: return "日本語フリック分割"
        case .flickRomaji: return "英語フリック分割（ローマ字）"
        case .flickEnglish: return "英語フリック分割（英語）"
        }
    }

    /// シェルの右下のキーボード選択のボタンに出す短い名前
    public var shortTitle: String {
        switch self {
        case .romaji: return "ローマ字"
        case .english: return "英語"
        case .kana: return "かな"
        case .flickRomaji: return "abcローマ字"
        case .flickEnglish: return "abc"
        }
    }

    /// フリックの面
    public var isFlick: Bool { self == .kana || self == .flickRomaji || self == .flickEnglish }
    /// 英字をローマ字としてかなにする
    public var usesRomaji: Bool { self == .romaji || self == .flickRomaji }
    /// かな漢字変換を使う（候補バーを出す）
    public var isJapanese: Bool { self == .romaji || self == .kana || self == .flickRomaji }
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
    /// 接続時に `tmux new -A -s <名前>` を実行する（タブの 2 番からは `<名前>-2`…）。nil なら素のシェル
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

    /// tmux を探す場所。上から順に試し、最初に実行できたものを使う（見つからなければ、ログインシェルの PATH）。
    /// `$HOME` は接続先で展開する。アプリの起動コマンドと `splitterm doctor` が同じ一覧を使う
    public static let tmuxSearchPaths: [String] = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "$HOME/.nix-profile/bin/tmux",
        "/run/current-system/sw/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// タブの番号（slot）に対応する tmux のセッション名。1 番は `tmux=` の名前のまま、2 番からは `-2` `-3` を付ける。
    /// タブごとに別のセッションにするため。`tmux=none` なら nil
    public func tmuxSessionName(slot: Int) -> String? {
        guard let s = tmuxSession else { return nil }
        return slot <= 1 ? s : "\(s)-\(slot)"
    }

    /// 接続後に実行するコマンド（1 行）。nil なら shell を要求する。
    /// SSH の exec はログインシェルを通らず、Homebrew の PATH（.zprofile）が効かない。
    /// そこで外側は `/bin/sh` に任せ（ログインシェルが fish・tcsh でも壊れない）、`tmuxSearchPaths` を順に試し、
    /// 無ければログインシェルの `command -v tmux` で探す。tmux 自体はログインシェル経由で起動し、
    /// tmux のサーバーにログインの環境（PATH）を持たせる。見つからなければ、知らせて素のシェルを開く。
    /// true color を tmux の中まで届けるため（docs/design.md「色」①）、tmux のクライアントに `COLORTERM=truecolor` を渡す。
    /// tmux 3.2 以上（`-T RGB -V` が通る）なら、さらに `-T RGB`（この端末は true color）と、
    /// 新しいセッションへの `-e COLORTERM=truecolor` を付ける。通らなければ今までどおりの起動（256 色）
    public func startupCommand(slot: Int) -> String? {
        // 名前は parse で英数と - _ . に限っているので、引用符の中にそのまま入れてよい
        guard let name = tmuxSessionName(slot: slot) else { return nil }
        // $HOME を含む候補だけ二重引用符で囲む（展開は接続先の sh）
        let candidates = Self.tmuxSearchPaths.map { $0.contains("$") ? "\"" + $0 + "\"" : $0 }.joined(separator: " ")
        // 外側の単一引用符の中に単一引用符を入れない（sshd がログインシェルの -c に渡す 1 行にするため）。
        // `-T` は tmux 3.2 から。知らない版は使い方を出して失敗するので、その失敗で版を見分ける
        let script = [
            #"t=; for p in \#(candidates); do if [ -x "$p" ]; then t=$p; break; fi; done; "#,
            #"if [ -z "$t" ]; then t=$("$SHELL" -lc "command -v tmux" 2>/dev/null | tail -n 1); [ -x "$t" ] || t=; fi; "#,
            #"if [ -n "$t" ]; then "#,
            #"if "$t" -T RGB -V >/dev/null 2>&1; then exec "$SHELL" -lc "exec env COLORTERM=truecolor \"$t\" -u -T RGB new-session -A -e COLORTERM=truecolor -s \#(name)"; fi; "#,
            #"exec "$SHELL" -lc "exec env COLORTERM=truecolor \"$t\" -u new-session -A -s \#(name)"; "#,
            #"fi; "#,
            #"echo "tmux が見つかりません（Mac で brew install tmux を入れると、切れても作業が残ります）。素のシェルを開きます"; "#,
            #"exec "$SHELL" -l"#,
        ].joined()
        return "exec /bin/sh -c '" + script + "'"
    }

    /// 鍵の保存（ホスト鍵）に使う識別子
    public var endpointID: String { "\(address):\(port)" }
}
