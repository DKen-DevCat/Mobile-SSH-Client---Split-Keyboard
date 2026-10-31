import XCTest
@testable import TermCore

final class ClipboardLeaseTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func lease(_ text: String = "https://example.com", changeCount: Int = 10) -> ClipboardLease {
        var l = ClipboardLease()
        l.placed(text, changeCount: changeCount)
        return l
    }

    /// 前面にいる間は何も起きない（期限を付けるのは離れたとき）
    func testNothingHappensWhileInTheForeground() {
        var l = ClipboardLease()
        XCTAssertFalse(l.holdsText)
        XCTAssertEqual(l.didEnterBackground(changeCount: 5, now: t0, clearAfter: 60), .none)
        XCTAssertEqual(l.didActivate(changeCount: 5, now: t0), .none)
        l.placed("abc", changeCount: 5)
        XCTAssertTrue(l.holdsText)
        // 前面に戻っただけ（期限は付いていない）なら、載せ直さない
        XCTAssertEqual(l.didActivate(changeCount: 5, now: t0), .none)
    }

    /// 離れたら、同じ文字を clipboard-clear の期限付きで載せ直す
    func testLeavingRewritesWithAnExpirationDate() {
        var l = lease()
        XCTAssertEqual(l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60),
                       .rewrite(text: "https://example.com", expiresAt: t0.addingTimeInterval(60)))
        var other = lease()
        XCTAssertEqual(other.didEnterBackground(changeCount: 10, now: t0, clearAfter: 15),
                       .rewrite(text: "https://example.com", expiresAt: t0.addingTimeInterval(15)))
    }

    /// 0 は消さない（期限を付けない）
    func testZeroNeverClears() {
        var l = lease()
        XCTAssertEqual(l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 0), .none)
        XCTAssertEqual(l.didActivate(changeCount: 10, now: t0), .none)
        XCTAssertEqual(l.didEnterBackground(changeCount: 10, now: t0, clearAfter: -5), .none)
    }

    /// 別の物がクリップボードに載っていたら（changeCount が違う）触れない。覚えた文字も捨てる
    func testSomeoneElseCopiedSomething() {
        var l = lease()
        XCTAssertEqual(l.didEnterBackground(changeCount: 11, now: t0, clearAfter: 60), .none)
        XCTAssertFalse(l.holdsText)
        // 捨てたので、同じ値に戻っても載せ直さない
        XCTAssertEqual(l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60), .none)
    }

    /// 戻ったとき、期限がまだなら期限を外して載せ直す
    func testReturningBeforeTheDeadlineRemovesIt() {
        var l = lease()
        guard case .rewrite(_, let expires?) = l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60) else {
            return XCTFail("期限付きで載せ直すはず")
        }
        l.rewritten(changeCount: 11, expiresAt: expires)
        XCTAssertEqual(l.didActivate(changeCount: 11, now: t0.addingTimeInterval(59)),
                       .rewrite(text: "https://example.com", expiresAt: nil))
        l.rewritten(changeCount: 12, expiresAt: nil)
        // 外したあとは、また前面の状態（もう一度離れれば、また期限が付く）
        XCTAssertEqual(l.didActivate(changeCount: 12, now: t0.addingTimeInterval(59)), .none)
        XCTAssertEqual(l.didEnterBackground(changeCount: 12, now: t0.addingTimeInterval(100), clearAfter: 60),
                       .rewrite(text: "https://example.com", expiresAt: t0.addingTimeInterval(160)))
    }

    /// 期限を過ぎて戻ったら、何もせず、覚えていた文字を捨てる
    func testReturningAfterTheDeadlineDoesNothingAndForgets() {
        var l = lease()
        _ = l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60)
        l.rewritten(changeCount: 11, expiresAt: t0.addingTimeInterval(60))
        XCTAssertEqual(l.didActivate(changeCount: 11, now: t0.addingTimeInterval(60)), .none)
        XCTAssertFalse(l.holdsText)
        // 捨てたので、続けて呼んでも載せ直さない
        XCTAssertEqual(l.didActivate(changeCount: 11, now: t0.addingTimeInterval(1)), .none)
        XCTAssertEqual(l.didEnterBackground(changeCount: 11, now: t0, clearAfter: 60), .none)
    }

    /// 離れている間に別の物が載った（期限が来て消えた、ほかのアプリがコピーした）なら、戻っても載せ直さない
    func testReturningAfterSomeoneElseCopied() {
        var l = lease()
        _ = l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60)
        l.rewritten(changeCount: 11, expiresAt: t0.addingTimeInterval(60))
        XCTAssertEqual(l.didActivate(changeCount: 13, now: t0.addingTimeInterval(5)), .none)
        XCTAssertFalse(l.holdsText)
    }

    /// 離れる知らせが続けて来ても、期限は延ばさない
    func testTheDeadlineIsNotExtendedByARepeatedNotification() {
        var l = lease()
        _ = l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60)
        l.rewritten(changeCount: 11, expiresAt: t0.addingTimeInterval(60))
        XCTAssertEqual(l.didEnterBackground(changeCount: 11, now: t0.addingTimeInterval(30), clearAfter: 60), .none)
    }

    /// 新しくコピーしたら、新しい文字と changeCount に替わり、期限は付いていない
    func testANewCopyReplacesTheOldOne() {
        var l = lease("old", changeCount: 10)
        _ = l.didEnterBackground(changeCount: 10, now: t0, clearAfter: 60)
        l.rewritten(changeCount: 11, expiresAt: t0.addingTimeInterval(60))
        l.placed("new", changeCount: 20)
        XCTAssertEqual(l.didActivate(changeCount: 20, now: t0), .none)
        XCTAssertEqual(l.didEnterBackground(changeCount: 20, now: t0, clearAfter: 30),
                       .rewrite(text: "new", expiresAt: t0.addingTimeInterval(30)))
    }
}
