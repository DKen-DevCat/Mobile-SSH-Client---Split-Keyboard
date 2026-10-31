/// 向きを替えたときのキーボードの種類（docs/design.md「JIS の一体型（縦持ち）」の「向きとキーボードの種類」）。
/// 縦持ちは JIS の一体型（英語・ローマ字）だけなので、フリックは同じ言葉の JIS に替え、横持ちに戻ったら元のフリックに戻す
///
/// - 縦持ちに入る: フリックなら同じ言葉の JIS（日本語 → ローマ字、英語 → 英語）。替えたら元のフリックを覚える
/// - 横持ちに戻る: 覚えたフリックがあり、縦持ちの間に言葉を替えていなければ、そのフリック。替えていれば縦持ちで選んだ JIS のまま。
///   どちらでも覚えたものは捨てる
public struct KeyboardOrientationMemory: Equatable, Sendable {
    /// 縦持ちに入るときに覚えた、横持ちのフリックの種類
    public private(set) var savedFlick: KeyboardKind?

    public init() {}

    /// 縦持ちに入った。縦持ちで使う種類を返す
    public mutating func enterPortrait(current: KeyboardKind) -> KeyboardKind {
        let next = current.portraitEquivalent
        savedFlick = next == current ? nil : current
        return next
    }

    /// 横持ちに戻った。横持ちで使う種類を返す
    public mutating func enterLandscape(current: KeyboardKind) -> KeyboardKind {
        defer { savedFlick = nil }
        guard let saved = savedFlick, saved.portraitEquivalent == current else { return current }
        return saved
    }
}
