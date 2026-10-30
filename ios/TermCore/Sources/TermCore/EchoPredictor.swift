import Foundation

/// 先行表示（docs/design.md「先行表示」）。直接送る文字を、接続先の返事を待たずにカーソルの位置へ薄く出す（mosh の考え方）。
/// 出すのは「確かめられた」ときだけ: 打った文字が、打った時のカーソルの位置に実際に返ってきた（画面のその位置の文字が同じになり、
/// カーソルが進んだ）のを 1 度見てから。最初の 1 文字は確かめる前なので出さない。パスワードの入力では文字が返らないので、決して出ない。
/// 画面にも通信にも頼らない純粋な値（アプリ側が、打ったキーと描いた画面を知らせる）
public struct EchoPredictor: Sendable {
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
    /// 代替画面・マウス報告は止めない（tmux は外側の端末を代替画面にし、mouse on ならマウス報告も使う）。
    /// vim の通常モードなどは、返る文字が予測と合わないので、確かめが通らず出ない
    public struct Context: Equatable, Sendable {
        public var cursorHidden: Bool
        /// スクロールバックを見ている
        public var scrolledBack: Bool
        /// かな漢字変換の読みがある
        public var composing: Bool
        /// 範囲を選んでいる
        public var selecting: Bool

        public init(cursorHidden: Bool = false, scrolledBack: Bool = false, composing: Bool = false,
                    selecting: Bool = false) {
            self.cursorHidden = cursorHidden
            self.scrolledBack = scrolledBack
            self.composing = composing
            self.selecting = selecting
        }

        var blocked: Bool {
            cursorHidden || scrolledBack || composing || selecting
        }
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

    /// 打った文字が返ってくるのを 1 度見たか
    public private(set) var confirmed = false
    public private(set) var pending: [Pending] = []

    public init() {}

    public var hasPending: Bool { !pending.isEmpty }

    /// 予測を全部消して、確かめ直しへ戻る
    public mutating func reset() {
        pending.removeAll()
        confirmed = false
    }

    /// 文字を接続先へ送った。cursor はその時の端末のカーソル（見えている画面の桁と行）
    public mutating func typed(_ text: String, cursor: (col: Int, row: Int), now: TimeInterval, context: Context) {
        if context.blocked {
            reset()
            return
        }
        // 予測するのは ASCII の印字できる 1 文字（0x20〜0x7E）だけ。かな・全角・結合文字・制御文字・複数文字は消す
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let u = scalars.first, (0x20...0x7E).contains(u.value) else {
            reset()
            return
        }
        let at = pending.last.map { (col: $0.col + 1, row: $0.row) } ?? cursor
        pending.append(Pending(char: Character(u), col: at.col, row: at.row, sent: now))
    }

    /// 文字以外のキーを送った
    public mutating func key(_ kind: KeyKind) {
        switch kind {
        case .enter, .escape, .tab, .modified, .paste:
            reset()
        case .backspace, .arrow:
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
            reset()
            return
        }
        while let head = pending.first {
            guard let shown = cellText(head.col, head.row) else {
                reset()
                return
            }
            // 空白は、返ってきても画面のセルは空のまま。カーソルが同じ行でその桁より先へ進んでいれば、返ってきたとみなす
            if head.char == " ", shown.isEmpty || shown == " ", cursor.row == head.row, cursor.col > head.col {
                pending.removeFirst()
                confirmed = true
                continue
            }
            // まだ返っていない。待つのはカーソルが先頭の位置にあるあいだだけ（動いていたら返るはずの文字が来なかった）
            if shown.isEmpty {
                if cursor.row != head.row || cursor.col != head.col { reset() }
                return
            }
            // 違う文字になった（予測が外れた）
            guard shown == String(head.char) else {
                reset()
                return
            }
            // 同じ文字でも、カーソルが進むまでは確かめたことにしない（もとからそこにあった同じ文字かもしれない）
            guard cursor.row == head.row, cursor.col > head.col else { break }
            pending.removeFirst()
            confirmed = true
        }
        // カーソルが先頭より手前・別の行へ動いた（行の編集・画面の書き換え）
        if let head = pending.first, cursor.row != head.row || cursor.col < head.col { reset() }
    }

    /// 出す文字と、その先頭の位置。確かめた後で、返っていない文字があるときだけ
    public var display: (text: String, at: (col: Int, row: Int))? {
        guard confirmed, let first = pending.first else { return nil }
        return (String(pending.map(\.char)), (col: first.col, row: first.row))
    }
}
