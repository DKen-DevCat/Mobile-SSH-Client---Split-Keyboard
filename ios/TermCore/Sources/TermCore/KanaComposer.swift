import Foundation

/// かな入力の変換中の文字（docs/design.md「かなフリック」）。
/// フリックとトグル入力（同じキーの連打）で読みを作り、候補バーに候補を出す。
/// 漢字の変換エンジンは `KanaConverter` で差し替える（アプリは AzooKey、テストと辞書の読み込み中はひらがな・カタカナだけ）

/// 変換の候補。`consumed` は候補が読みの先頭の何文字ぶんか（文節ごとの候補は読みの一部だけを使う）
public struct KanaCandidate: Equatable, Sendable {
    public var text: String
    public var consumed: Int

    public init(text: String, consumed: Int) {
        self.text = text
        self.consumed = consumed
    }
}

public protocol KanaConverter {
    /// 読みの候補。重い処理なので、呼ぶ側がメインスレッドの外で呼ぶ
    func candidates(for reading: String) -> [KanaCandidate]
    /// 変換を区切った（確定・取り消し）。変換器の中の途中結果を捨てる
    func reset()
}

/// 漢字の辞書を持たない変換（ひらがなとカタカナ）
public struct PassthroughConverter: KanaConverter, Sendable {
    public init() {}

    public func candidates(for reading: String) -> [KanaCandidate] {
        Self.kanaCandidates(for: reading)
    }

    public func reset() {}

    /// 読みそのままと、カタカナ。どの変換器でも最後に足す（辞書に無い語でも打てるように）
    public static func kanaCandidates(for reading: String) -> [KanaCandidate] {
        guard !reading.isEmpty else { return [] }
        let n = reading.count
        let kata = KanaComposer.katakana(reading)
        return kata == reading ? [.init(text: reading, consumed: n)]
            : [.init(text: reading, consumed: n), .init(text: kata, consumed: n)]
    }
}

public struct KanaComposer: Sendable {
    public private(set) var reading = ""
    /// トグル入力の続き: 直前に押したキーと、その巡りの位置
    var toggle: (id: String, index: Int, at: TimeInterval)?
    /// 連打をトグル入力とみなす間隔
    public var toggleWindow: TimeInterval = 1.0

    public init() {}

    public var isComposing: Bool { !reading.isEmpty }

    /// フリックのキーを離した。中央のタップは、同じキーの連打ならトグル入力で文字を進める
    public mutating func input(keyID: String, set: FlickSet, direction: FlickDirection, now: TimeInterval) {
        if direction == .center, let t = toggle, t.id == keyID, now - t.at <= toggleWindow, !reading.isEmpty {
            let cycle = set.cycle
            let next = (t.index + 1) % cycle.count
            reading.removeLast()
            reading.append(cycle[next])
            toggle = (keyID, next, now)
            return
        }
        reading.append(set.character(direction))
        toggle = direction == .center ? (keyID, 0, now) : nil
    }

    /// 「→」。トグル入力を区切る
    public mutating func breakToggle() { toggle = nil }

    /// 「゛゜小」。直前の文字を順に変える
    public mutating func modifyLast() {
        guard let last = reading.last else { return }
        reading.removeLast()
        reading.append(Self.nextVariant(of: last))
        toggle = nil
    }

    /// ⌫。変換中なら 1 文字消して true。変換中でなければ false（接続先へ送る）
    public mutating func deleteBackward() -> Bool {
        guard !reading.isEmpty else { return false }
        reading.removeLast()
        toggle = nil
        return true
    }

    /// 確定して読みを空にする。確定した文字を返す
    public mutating func commit(_ text: String? = nil) -> String {
        let out = text ?? reading
        reading = ""
        toggle = nil
        return out
    }

    /// 候補を選んだ。候補が読みの一部だけ（文節）なら、その分を確定して残りは変換中のままにする
    public mutating func commit(_ candidate: KanaCandidate) -> String {
        let n = min(max(candidate.consumed, 0), reading.count)
        if n >= reading.count { return commit(candidate.text) }
        reading.removeFirst(n)
        toggle = nil
        return candidate.text
    }

    /// 文字を直接足す（空白など、変換中の読みに入れるもの）
    public mutating func append(_ s: String) {
        reading.append(s)
        toggle = nil
    }

    // MARK: 文字の変換

    /// 「゛゜小」で巡る順。表に無い文字はそのまま
    static let variants: [[Character]] = [
        ["あ", "ぁ"], ["い", "ぃ"], ["う", "ぅ", "ゔ"], ["え", "ぇ"], ["お", "ぉ"],
        ["か", "が"], ["き", "ぎ"], ["く", "ぐ"], ["け", "げ"], ["こ", "ご"],
        ["さ", "ざ"], ["し", "じ"], ["す", "ず"], ["せ", "ぜ"], ["そ", "ぞ"],
        ["た", "だ"], ["ち", "ぢ"], ["つ", "っ", "づ"], ["て", "で"], ["と", "ど"],
        ["は", "ば", "ぱ"], ["ひ", "び", "ぴ"], ["ふ", "ぶ", "ぷ"], ["へ", "べ", "ぺ"], ["ほ", "ぼ", "ぽ"],
        ["や", "ゃ"], ["ゆ", "ゅ"], ["よ", "ょ"], ["わ", "ゎ"],
    ]

    static let variantIndex: [Character: (row: Int, pos: Int)] = {
        var m: [Character: (row: Int, pos: Int)] = [:]
        for (r, row) in variants.enumerated() {
            for (p, c) in row.enumerated() { m[c] = (row: r, pos: p) }
        }
        return m
    }()

    public static func nextVariant(of c: Character) -> Character {
        guard let v = variantIndex[c] else { return c }
        let row = variants[v.row]
        return row[(v.pos + 1) % row.count]
    }

    /// ひらがなをカタカナに（ー などはそのまま）
    public static func katakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0x3041...0x3096).contains(u.value) ? Unicode.Scalar(u.value + 0x60)! : u
        }))
    }
}
