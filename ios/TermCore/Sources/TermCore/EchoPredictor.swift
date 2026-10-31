import Foundation

/// 先行表示（docs/design.md「先行表示」）。直接送る文字を、接続先の返事を待たずにカーソルの位置へ出す（mosh の考え方）。
/// 出し方は `Mode`（config の `echo-prediction`）:
/// - `instant`（既定）: 最初の 1 文字から、押した瞬間に出す。確かめる前に出すのは最初の 1 文字だけで、続けて打った文字は
///   それが返ってくるのを見て（確かめて）から出す。外れたら「疑う」状態にし、確かめるまで出さない。
///   Enter などは出ている予測を消し、その行はまた確かめ直す（疑っている状態は保つ）
/// - `confirmed`: 前の版の出し方。確かめた後だけ出し、外れたら・Enter などのたびに確かめ直す。返らない入力（パスワード）では決して出ない
/// - `off`: 出さない
/// 確かめる = 打った文字が、打った時のカーソルの位置に実際に返ってきた（画面のその位置の文字が同じになり、カーソルが進んだ）。
/// 秘密の入力らしい行（`looksLikeSecretPrompt`）では、どのモードでも出さない。
/// 画面にも通信にも頼らない純粋な値（アプリ側が、打ったキーと描いた画面を知らせる）
public struct EchoPredictor: Sendable {
    /// 出し方（config の `echo-prediction`）
    public enum Mode: String, Sendable, CaseIterable {
        case instant
        case confirmed
        case off
    }

    /// 打ってから、まだ画面に返っていない文字と、その位置（見えている画面の桁と行）
    public struct Pending: Equatable, Sendable {
        public var char: Character
        public var col: Int
        public var row: Int
        public var sent: TimeInterval

        public init(char: Character, col: Int, row: Int, sent: TimeInterval) {
            self.char = char
            self.col = col
            self.row = row
            self.sent = sent
        }
    }

    /// 予測してはいけない場面。どれかが立っていれば、予測を消して何もしない。
    /// カーソルが隠れていても止めない（Claude Code はカーソルを隠す。端末の持つカーソルの位置に出し、違えば外れて止まる）。
    /// 代替画面・マウス報告も止めない（tmux は外側の端末を代替画面にし、mouse on ならマウス報告も使う）。
    /// vim の通常モードなどは、返る文字が予測と合わないので外れて止まる
    public struct Context: Equatable, Sendable {
        /// スクロールバックを見ている
        public var scrolledBack: Bool
        /// かな漢字変換の読みがある
        public var composing: Bool
        /// 範囲を選んでいる
        public var selecting: Bool
        /// カーソルの行が秘密の入力らしい（`looksLikeSecretPrompt`）
        public var secretPrompt: Bool

        public init(scrolledBack: Bool = false, composing: Bool = false, selecting: Bool = false,
                    secretPrompt: Bool = false) {
            self.scrolledBack = scrolledBack
            self.composing = composing
            self.selecting = selecting
            self.secretPrompt = secretPrompt
        }

        var blocked: Bool {
            scrolledBack || composing || selecting || secretPrompt
        }
    }

    /// 秘密の入力らしい行の言葉（小文字で比べる）。行頭からカーソルの手前までに 1 つでもあれば出さない
    public static let secretWords: [String] = [
        "password", "passwd", "passphrase", "passcode", "pin:", "secret", "token", "api key", "apikey", "api_key",
        "otp", "one-time", "verification code", "2fa", "パスワード", "暗証", "認証コード", "確認コード", "ワンタイム",
    ]

    /// カーソルの行（行頭からカーソルの手前まで）が、秘密の入力らしいか（大文字・小文字は問わない）
    public static func looksLikeSecretPrompt(_ lineBeforeCursor: String) -> Bool {
        let text = lineBeforeCursor.lowercased()
        return secretWords.contains { text.contains($0) }
    }

    /// 文字以外のキー
    public enum KeyKind: Equatable, Sendable {
        /// 送信・改行。行が変わる（確かめ直し）
        case enter
        case escape
        case tab
        /// control・option 付き（制御文字・meta。何が起きるか分からない）
        case modified
        /// 貼り付け・メディアのパスの挿入
        case paste
        case backspace
        /// 矢印・home・end・page（カーソルが動くだけ）
        case arrow
    }

    /// 先頭がこれ（秒）より古くても返っていなければ、外れとして消す
    public static let timeout: TimeInterval = 1.0

    public var mode: Mode
    /// 打った文字が返ってくるのを 1 度見たか（Enter などで確かめ直す）。confirmed のモードはこれが立つまで出さず、
    /// instant のモードはこれが立つまで最初の 1 文字だけ出す
    public private(set) var confirmed = false
    /// 外れてから、まだ確かめていない（instant のモードは、これが立っている間は出さない）
    public private(set) var doubtful = false
    public private(set) var pending: [Pending] = []

    public init(mode: Mode = .instant) {
        self.mode = mode
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// 予測を全部消して、初めの状態へ戻る（タブを替えた・出し方を替えた）
    public mutating func reset() {
        pending.removeAll()
        confirmed = false
        doubtful = false
    }

    /// 外れた: 予測を消し、確かめ直す（confirmed）・疑う（instant）
    mutating func miss() {
        pending.removeAll()
        confirmed = false
        doubtful = true
    }

    /// 出している予測を消して、確かめ直しへ戻る（外れではないので、疑う状態にはしない）
    mutating func clear() {
        pending.removeAll()
        confirmed = false
    }

    /// 返ってくるのを見た
    mutating func confirm() {
        confirmed = true
        doubtful = false
    }

    /// 文字を接続先へ送った。cursor はその時の端末のカーソル（見えている画面の桁と行）
    public mutating func typed(_ text: String, cursor: (col: Int, row: Int), now: TimeInterval, context: Context) {
        if mode == .off || context.blocked {
            clear()
            return
        }
        // 予測するのは ASCII の印字できる 1 文字（0x20〜0x7E）だけ。かな・全角・結合文字・制御文字・複数文字は消す
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let u = scalars.first, (0x20...0x7E).contains(u.value) else {
            clear()
            return
        }
        let at = pending.last.map { (col: $0.col + 1, row: $0.row) } ?? cursor
        pending.append(Pending(char: Character(u), col: at.col, row: at.row, sent: now))
    }

    /// 文字以外のキーを送った
    public mutating func key(_ kind: KeyKind) {
        switch kind {
        case .enter, .escape, .tab, .modified, .paste:
            // 何が起きるか分からない。出ている予測を消して確かめ直す（疑っている状態は保つ）
            clear()
        case .backspace:
            // 打ったばかりの文字の取り消しは、接続先でもそうなる。予測の最後の 1 文字だけ消す。
            // 予測が無いときの ⌫（画面にある文字を消す）は先に見せない（返事を待つ）
            _ = pending.popLast()
        case .arrow:
            // 返る画面は予測と違う形になる。出ているものだけ消す（確かめた状態は保つ）
            pending.removeAll()
        }
    }

    /// 画面が描かれるたびに呼ぶ。cellText は画面のその位置の文字（空のセルは ""、画面の外は nil）。
    /// cursor は描いた画面のカーソル（見えている画面の桁と行）
    public mutating func reconcile(cellText: (_ col: Int, _ row: Int) -> String?, cursor: (col: Int, row: Int),
                                   now: TimeInterval) {
        guard let first = pending.first else { return }
        // 待ちすぎ（返事が来ない）。返らない入力（パスワード）もここで消える
        if now - first.sent > Self.timeout {
            miss()
            return
        }
        while let head = pending.first {
            guard let shown = cellText(head.col, head.row) else {
                miss()
                return
            }
            // 空白は、返ってきても画面のセルは空のまま。カーソルが同じ行でその桁より先へ進んでいれば、返ってきたとみなす
            if head.char == " ", shown.isEmpty || shown == " ", cursor.row == head.row, cursor.col > head.col {
                pending.removeFirst()
                confirm()
                continue
            }
            // まだ返っていない。待つのはカーソルが先頭の位置にあるあいだだけ（動いていたら返るはずの文字が来なかった）
            if shown.isEmpty {
                if cursor.row != head.row || cursor.col != head.col { miss() }
                return
            }
            // 違う文字になった（予測が外れた）
            guard shown == String(head.char) else {
                miss()
                return
            }
            // 同じ文字でも、カーソルが進むまでは確かめたことにしない（もとからそこにあった同じ文字かもしれない）
            guard cursor.row == head.row, cursor.col > head.col else { break }
            pending.removeFirst()
            confirm()
        }
        // カーソルが先頭より手前・別の行へ動いた（行の編集・画面の書き換え）
        if let head = pending.first, cursor.row != head.row || cursor.col < head.col { miss() }
    }

    /// 出す文字と、その先頭の位置。返っていない文字があるときだけ。
    /// instant: 疑っている間は出さない。確かめる前は最初の 1 文字だけ（返らない入力で、続けて打った文字を出さない）。
    /// confirmed: 確かめた後だけ
    public var display: (text: String, at: (col: Int, row: Int))? {
        guard let first = pending.first else { return nil }
        let shown: [Pending]
        switch mode {
        case .instant:
            guard !doubtful else { return nil }
            shown = confirmed ? pending : [first]
        case .confirmed:
            guard confirmed else { return nil }
            shown = pending
        case .off:
            return nil
        }
        return (String(shown.map(\.char)), (col: first.col, row: first.row))
    }
}
