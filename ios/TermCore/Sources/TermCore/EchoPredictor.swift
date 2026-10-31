import Foundation

/// 先行表示（docs/design.md「先行表示」）。直接送る文字を、接続先の返事を待たずにカーソルの位置へ出す（mosh の考え方）。
/// 出し方は `Mode`（config の `echo-prediction`）:
/// - `instant`（既定）: 押した瞬間に出す。確かめる前に出すのは、1 つの行で最初の 1 文字だけ（⌫ で消しても、もう 1 文字は出さない）。
///   続けて打った文字は、返ってくるのを見て（確かめて）から出す。外れたら「疑う」状態にし、確かめるまで出さない
/// - `confirmed`: 確かめた後だけ出す。返らない入力（パスワード）では決して出ない
/// - `off`: 出さない
/// どちらのモードも:
/// - 確かめる = 打った文字が、打った時のカーソルの位置に実際に返ってきた（画面のその位置の文字が同じになり、カーソルが進んだ）
/// - Enter・Esc・Tab・control／option・貼り付け・矢印のあとは確かめ直し。画面でカーソルが動く（返事が届く）までは予測しない
///   （先打ち。`sudo …⏎` の直後のパスワードを、問いかけが届く前に出さない）
/// - カーソルが隠れている画面では、確かめる前の 1 文字も出さない（隠れたカーソルが入力欄にあるとは限らない）
/// - 秘密の入力らしい行（`looksLikeSecretPrompt`）では出さない
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

    /// 打った時の場面。止める場面（blocked）が 1 つでも立っていれば、予測を消して何もしない。
    /// 代替画面・マウス報告は止めない（tmux は外側の端末を代替画面にし、mouse on ならマウス報告も使う）。
    /// vim の通常モードなどは、返る文字が予測と合わないので外れて止まる
    public struct Context: Equatable, Sendable {
        /// スクロールバックを見ている
        public var scrolledBack: Bool
        /// かな漢字変換の読みがある
        public var composing: Bool
        /// 範囲を選んでいる
        public var selecting: Bool
        /// カーソルの行（と前の行）が秘密の入力らしい（`looksLikeSecretPrompt`）
        public var secretPrompt: Bool
        /// カーソルが隠れている（Claude Code など）。止めはしないが、確かめる前の 1 文字は出さない
        public var cursorHidden: Bool

        public init(scrolledBack: Bool = false, composing: Bool = false, selecting: Bool = false,
                    secretPrompt: Bool = false, cursorHidden: Bool = false) {
            self.scrolledBack = scrolledBack
            self.composing = composing
            self.selecting = selecting
            self.secretPrompt = secretPrompt
            self.cursorHidden = cursorHidden
        }

        var blocked: Bool {
            scrolledBack || composing || selecting || secretPrompt
        }
    }

    /// 秘密の入力らしい行の言葉（小文字で比べる。文字列のどこにあってもよい）
    public static let secretWords: [String] = [
        "password", "passwd", "passphrase", "pass phrase", "passcode", "secret", "token", "api key", "apikey", "api_key",
        "encryption key", "one-time", "verification code", "パスワード", "暗証", "認証コード", "確認コード", "ワンタイム",
    ]

    /// 秘密の入力らしい行の短い言葉。前後が英数字でないときだけ（ping・footprint などに当てない）
    public static let secretWholeWords: [String] = ["pin", "otp", "2fa", "mfa"]

    /// カーソルの行（行頭からカーソルの手前まで。アプリは前の行もつなげて渡す）が、秘密の入力らしいか（大文字・小文字は問わない）
    public static func looksLikeSecretPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        if secretWords.contains(where: { lower.contains($0) }) { return true }
        return secretWholeWords.contains { containsWholeWord(lower, $0) }
    }

    static func containsWholeWord(_ text: String, _ word: String) -> Bool {
        var searchStart = text.startIndex
        while let r = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let isWordChar: (Character?) -> Bool = { c in c.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWordChar(before) && !isWordChar(after) { return true }
            searchStart = r.upperBound
        }
        return false
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
        /// ⌫（カーソルの手前を消す）
        case backspace
        /// 前方削除（カーソルの後ろを消す。カーソルは動かない）
        case delete
        /// 矢印・home・end・page（カーソルが動く）
        case arrow
    }

    /// 先頭がこれ（秒）より古くても返っていなければ、外れとして消す
    public static let timeout: TimeInterval = 1.0

    public var mode: Mode
    /// 打った文字が返ってくるのを 1 度見たか（Enter などで確かめ直す）。confirmed のモードはこれが立つまで出さず、
    /// instant のモードはこれが立つまで、その行の最初の 1 文字だけ出す
    public private(set) var confirmed = false
    /// 外れてから、まだ確かめていない（instant のモードは、これが立っている間は出さない）
    public private(set) var doubtful = false
    public private(set) var pending: [Pending] = []
    /// 最後に描いた画面のカーソル（隠れていても）
    public private(set) var lastCaret: (col: Int, row: Int)?
    /// Enter などを送った時のカーソル。画面でカーソルがここから動いて行の途中（桁 > 0）に来るまでは予測しない（先打ち）
    public private(set) var awaitingMoveFrom: (col: Int, row: Int)?
    /// この行で、確かめる前の 1 文字をもう使ったか（⌫ で消しても戻さない）
    private var allowanceUsed = false
    /// 先頭の予測（確かめる前の 1 文字）を出してよいか
    private var firstVisible = false

    public init(mode: Mode = .instant) {
        self.mode = mode
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// 予測を全部消して、初めの状態へ戻る（タブを替えた・スクロールバックへ移った）
    public mutating func reset() {
        pending.removeAll()
        confirmed = false
        doubtful = false
        allowanceUsed = false
        firstVisible = false
        lastCaret = nil
        awaitingMoveFrom = nil
    }

    /// 外れた: 予測を消し、確かめ直す（confirmed）・疑う（instant）
    mutating func miss() {
        pending.removeAll()
        confirmed = false
        doubtful = true
        firstVisible = false
    }

    /// 行が変わったかもしれない: 予測を消して、その行は確かめ直し（確かめる前の 1 文字をまた使える）。疑う状態は保つ
    mutating func newLine() {
        pending.removeAll()
        confirmed = false
        allowanceUsed = false
        firstVisible = false
    }

    /// 予測できない打ち方（止める場面・ASCII 以外）: 予測を消して確かめ直す。確かめる前の 1 文字は戻さない
    mutating func drop() {
        pending.removeAll()
        confirmed = false
        firstVisible = false
    }

    /// 返ってくるのを見た
    mutating func confirm() {
        confirmed = true
        doubtful = false
    }

    /// 文字を接続先へ送った。cursor はその時のカーソル（最後に描いた画面の。見えている画面の桁と行）
    public mutating func typed(_ text: String, cursor: (col: Int, row: Int), now: TimeInterval, context: Context) {
        // 先打ち: Enter などの返事（カーソルの動き）が、まだ画面に来ていない
        if mode == .off || context.blocked || awaitingMoveFrom != nil {
            drop()
            return
        }
        // 予測するのは ASCII の印字できる 1 文字（0x20〜0x7E）だけ。かな・全角・結合文字・制御文字・複数文字は消す
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let u = scalars.first, (0x20...0x7E).contains(u.value) else {
            drop()
            return
        }
        if pending.isEmpty && !confirmed {
            // 確かめる前の 1 文字は、1 つの行で 1 回だけ。カーソルが隠れている画面では使わない
            firstVisible = !allowanceUsed && !context.cursorHidden
            allowanceUsed = true
        }
        let at = pending.last.map { (col: $0.col + 1, row: $0.row) } ?? cursor
        pending.append(Pending(char: Character(u), col: at.col, row: at.row, sent: now))
    }

    /// 文字以外のキーを送った
    public mutating func key(_ kind: KeyKind) {
        switch kind {
        case .enter, .escape, .tab, .modified, .paste, .arrow:
            // 行やカーソルが変わる。確かめ直し、画面でカーソルが動くまで待つ
            newLine()
            awaitingMoveFrom = lastCaret
        case .backspace:
            // 打ったばかりの文字の取り消しは、接続先でもそうなる。予測の最後の 1 文字だけ消す。
            // 予測が無いときの ⌫（画面にある文字を消す）は先に見せない（返事を待つ）
            _ = pending.popLast()
            if pending.isEmpty { firstVisible = false }
        case .delete:
            // カーソルの後ろが消える。予測は消す（カーソルは動かないので、確かめた状態は保つ）
            pending.removeAll()
            firstVisible = false
        }
    }

    /// 画面が描かれるたびに呼ぶ（予測が無くても。カーソルの動きを見るため）。cellText は画面のその位置の文字
    /// （空のセルは ""、画面の外は nil）。cursor は描いた画面のカーソル（隠れていても。見えている画面の桁と行。
    /// 行の終わりに書いた直後は桁 = 幅のこともある）
    public mutating func reconcile(cellText: (_ col: Int, _ row: Int) -> String?, cursor: (col: Int, row: Int),
                                   now: TimeInterval) {
        lastCaret = cursor
        if let from = awaitingMoveFrom, (cursor.col, cursor.row) != (from.col, from.row), cursor.col > 0 {
            awaitingMoveFrom = nil
        }
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
    /// instant: 疑っている間は出さない。確かめる前は、出してよい最初の 1 文字だけ。confirmed: 確かめた後だけ
    public var display: (text: String, at: (col: Int, row: Int))? {
        guard let first = pending.first else { return nil }
        let shown: [Pending]
        switch mode {
        case .instant:
            guard !doubtful else { return nil }
            if confirmed {
                shown = pending
            } else {
                guard firstVisible else { return nil }
                shown = [first]
            }
        case .confirmed:
            guard confirmed else { return nil }
            shown = pending
        case .off:
            return nil
        }
        return (String(shown.map(\.char)), (col: first.col, row: first.row))
    }
}
