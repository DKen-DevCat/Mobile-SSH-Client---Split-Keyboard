import Foundation

/// アプリがクリップボードに載せた文字と、その期限の規則（docs/design.md「選択とコピー」「セキュリティ要件」）。
/// 画面にも UIPasteboard にも時計にも頼らない。クリップボードの `changeCount` と今の時刻は、呼び手が渡す。
///
/// - 前面にいる間は期限を付けない（`placed`）
/// - アプリを離れたとき、中身がまだアプリの載せたもの（`changeCount` が覚えた値と同じ）で、期限の長さが 0 より大きければ、
///   同じ文字を期限（今 + 期限の長さ）付きで載せ直す。期限は OS が管理するので、アプリが止められても効く
/// - 前面に戻ったとき、まだアプリの載せたもので期限が来ていなければ、期限を外して載せ直す。期限を過ぎていたら何もせず、
///   覚えていた文字を捨てる
/// - 中身は読まない（iOS の「ペーストの許可」が出る）。比べるのは `changeCount` だけ。文字はメモリにだけ持つ
public struct ClipboardLease: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// 同じ文字を載せ直す。expiresAt が nil なら期限なし。載せ直したら `rewritten` で新しい `changeCount` を知らせる
        case rewrite(text: String, expiresAt: Date?)
    }

    /// アプリの載せた文字（載せ直し用。メモリにだけ持つ）
    private var text: String?
    /// 載せた直後のクリップボードの `changeCount`
    private var changeCount: Int?
    /// 付けた期限（nil は期限なし）
    private var expiresAt: Date?

    public init() {}

    /// 覚えている文字があるか（アプリの載せたものが、まだクリップボードにあるとは限らない）
    public var holdsText: Bool { text != nil }

    /// アプリがクリップボードに載せた。前面なので期限は付けない。changeCount は載せた後の値
    public mutating func placed(_ text: String, changeCount: Int) {
        self.text = text
        self.changeCount = changeCount
        self.expiresAt = nil
    }

    /// 載せ直した（`Action.rewrite` を実行した）。changeCount は載せ直した後の値
    public mutating func rewritten(changeCount: Int, expiresAt: Date?) {
        self.changeCount = changeCount
        self.expiresAt = expiresAt
    }

    /// アプリを離れた。clearAfter は `clipboard-clear`（秒。0 以下は消さない）
    public mutating func didEnterBackground(changeCount: Int, now: Date, clearAfter: TimeInterval) -> Action {
        guard let text else { return .none }
        // 別の物がクリップボードに載った（アプリの載せたものではない）。もう触れない
        guard changeCount == self.changeCount else {
            forget()
            return .none
        }
        guard clearAfter > 0 else { return .none }
        // 離れる知らせが続けて来ても、期限は延ばさない
        guard expiresAt == nil else { return .none }
        return .rewrite(text: text, expiresAt: now.addingTimeInterval(clearAfter))
    }

    /// 前面に戻った
    public mutating func didActivate(changeCount: Int, now: Date) -> Action {
        guard let text else { return .none }
        guard changeCount == self.changeCount else {
            forget()
            return .none
        }
        // 期限を付けていない（前面のまま止まって戻っただけ）
        guard let limit = expiresAt else { return .none }
        // 期限を過ぎた。OS が消している（消す途中）ので、載せ直さずに捨てる
        guard now < limit else {
            forget()
            return .none
        }
        return .rewrite(text: text, expiresAt: nil)
    }

    private mutating func forget() {
        text = nil
        changeCount = nil
        expiresAt = nil
    }
}
