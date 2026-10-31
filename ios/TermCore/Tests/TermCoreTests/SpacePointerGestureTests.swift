import CoreGraphics
import XCTest
@testable import TermCore

final class SpacePointerGestureTests: XCTestCase {
    typealias Out = SpacePointerGesture.Output

    let origin = CGPoint(x: 100, y: 300)

    func p(_ dx: CGFloat, _ dy: CGFloat = 0) -> CGPoint { CGPoint(x: origin.x + dx, y: origin.y + dy) }

    /// 指 1 本のタップ（動かさずに離す）
    func tap(_ g: inout SpacePointerGesture, id: Int, side: PointerSide = .left, down: TimeInterval, up: TimeInterval) -> [Out] {
        _ = g.touchDown(id, side: side, at: origin, time: down)
        return g.touchUp(id, at: origin, time: up)
    }

    /// 指 1 本でポインタを動かして離す（離した時刻を返す）。動かした分の出力は捨てる
    @discardableResult
    func drag(_ g: inout SpacePointerGesture, id: Int, side: PointerSide = .left, down: TimeInterval,
              up: TimeInterval, by dx: CGFloat = 40) -> [Out] {
        _ = g.touchDown(id, side: side, at: origin, time: down)
        var out = g.touchMoved(id, to: p(dx), time: (down + up) / 2)
        out += g.touchUp(id, at: p(dx), time: up)
        return out
    }

    // MARK: 空白

    func testTapWithoutMovingTypesASpace() {
        var g = SpacePointerGesture()
        XCTAssertEqual(g.touchDown(1, side: .left, at: origin, time: 0), [])
        XCTAssertTrue(g.isTouching)
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.1), [.space])
        XCTAssertFalse(g.isTouching)
        // 右の面でも同じ
        XCTAssertEqual(tap(&g, id: 2, side: .right, down: 5, up: 5.1), [.space])
    }

    /// 長く押していても（トラックパッドにはならない）、動かさなければ離したときに空白
    func testLongPressStillTypesASpace() {
        var g = SpacePointerGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 2.5), [.space])
    }

    /// 6pt までのずれは動かしたことにしない（ちょうど 6pt は動かしていない。6pt より大きいと動かした）
    func testSlopBoundary() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        XCTAssertEqual(g.touchMoved(1, to: p(6), time: 0.05), [])
        XCTAssertEqual(g.touchMoved(1, to: p(-3, 5), time: 0.1), [])
        XCTAssertEqual(g.touchUp(1, at: p(3, 3), time: 0.2), [.space])
        _ = g.touchDown(2, side: .left, at: origin, time: 1)
        let out = g.touchMoved(2, to: p(6.5), time: 1.05)
        XCTAssertEqual(out.count, 1)
        if case .movePointer = out[0] {} else { XCTFail("\(out)") }
    }

    // MARK: ポインタ

    /// 6pt より動かしたら、その指はポインタを動かす。離しても空白を打たない
    func testMovingFingerMovesThePointerAndTypesNoSpace() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        let first = g.touchMoved(1, to: p(25, 0), time: 0.25)
        // 触れた点からの動きをまとめて動かす。指の速さ 100pt/秒の倍率
        XCTAssertEqual(first, [.movePointer(dx: 25 * PointerCurve.gain(speed: 100), dy: 0)])
        // 以降は前の点からの差分（0.25 秒で 50pt = 200pt/秒の倍率）
        let second = g.touchMoved(1, to: p(25, 50), time: 0.5)
        XCTAssertEqual(second, [.movePointer(dx: 0, dy: 50 * PointerCurve.gain(speed: 200))])
        XCTAssertEqual(g.touchMoved(1, to: p(25, 50), time: 0.75), [])  // 動いていない
        XCTAssertEqual(g.touchUp(1, at: p(25, 50), time: 1), [])
    }

    /// 速く動かすほど遠くへ届く（PointerCurve の倍率）。ゆっくりなら最小の倍率
    func testSpeedScalesTheMovement() {
        var slow = SpacePointerGesture()
        _ = slow.touchDown(1, side: .left, at: origin, time: 0)
        XCTAssertEqual(slow.touchMoved(1, to: p(10), time: 1), [.movePointer(dx: 10 * PointerCurve.minGain, dy: 0)])
        var fast = SpacePointerGesture()
        _ = fast.touchDown(1, side: .right, at: origin, time: 0)
        // 100pt を 0.0625 秒（1600pt/秒。900pt/秒以上なので最大の倍率）
        XCTAssertEqual(fast.touchMoved(1, to: p(100), time: 0.0625), [.movePointer(dx: 100 * PointerCurve.gain(speed: 1600), dy: 0)])
        XCTAssertEqual(PointerCurve.gain(speed: 1600), PointerCurve.gain(speed: 900))
        XCTAssertGreaterThan(PointerCurve.gain(speed: 1600), PointerCurve.minGain * 3)
    }

    /// 指を戻しても、動かした指のまま（離しても空白は打たない）
    func testMovingThenReturningStaysAPointerFinger() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        _ = g.touchMoved(1, to: p(30), time: 0.1)
        _ = g.touchMoved(1, to: origin, time: 0.2)
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.3), [])
    }

    /// 離した位置までの動きも出す（動きの通知が来ずに離れても取りこぼさない）
    func testTheMovementUpToTheReleasePointIsNotLost() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        let out = g.touchUp(1, at: p(20), time: 0.25)
        XCTAssertEqual(out, [.movePointer(dx: 20 * PointerCurve.gain(speed: 80), dy: 0)])
    }

    /// ポインタを動かす指は同時に 1 本。ほかの指の大きな動きは捨てる（離しても何も出さない）
    func testOnlyOneFingerMovesThePointer() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        _ = g.touchMoved(1, to: p(20), time: 0.1)
        _ = g.touchDown(2, side: .left, at: origin, time: 0.15)  // 同じ側の 2 本目（右クリックではない）
        XCTAssertEqual(g.touchMoved(2, to: p(40), time: 0.2), [])
        XCTAssertEqual(g.touchUp(2, at: p(40), time: 0.25), [])
        // 1 本目は動かし続けられる
        XCTAssertEqual(g.touchMoved(1, to: p(30), time: 0.3).count, 1)
    }

    // MARK: 1 秒の猶予とクリック

    /// ポインタを動かした指を離してから 1 秒以内に、動かさずに離した → 左クリック（空白ではない）
    func testTapWithinTheGraceTimeClicks() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&g, id: 2, down: 10.3, up: 10.5), [.click(right: false)])
    }

    /// 猶予は離した時刻から。ちょうど 1.0 秒は猶予の中、1 秒を過ぎたら空白
    func testTapAfterTheGraceTimeTypesASpace() {
        var inside = SpacePointerGesture()
        drag(&inside, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&inside, id: 2, down: 10.5, up: 11.0), [.click(right: false)])

        var outside = SpacePointerGesture()
        drag(&outside, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&outside, id: 2, down: 10.5, up: 11.01), [.space])
        XCTAssertEqual(SpacePointerGesture.graceTime, 1.0)

        // 触れたのは猶予の中でも、離したのが猶予を過ぎたら空白
        var late = SpacePointerGesture()
        drag(&late, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&late, id: 2, down: 10.9, up: 11.5), [.space])
    }

    /// 猶予が過ぎたあとの空白は、普通の空白（その後ろで猶予が復活したりしない）
    func testGraceDoesNotComeBack() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&g, id: 2, down: 12, up: 12.1), [.space])
        XCTAssertEqual(tap(&g, id: 3, down: 12.2, up: 12.3), [.space])
    }

    /// ポインタを動かしていなければ猶予は無い（最初のタップは空白）
    func testNoGraceWithoutMovingFirst() {
        var g = SpacePointerGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 0.1), [.space])
        XCTAssertEqual(tap(&g, id: 2, down: 0.2, up: 0.3), [.space])
    }

    /// クリックしたら 1 秒を数え直す（続けて叩けばダブルクリック）。数え直しは、前のクリックの時刻から
    func testClickRenewsTheGraceTime() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        XCTAssertEqual(tap(&g, id: 2, down: 10.8, up: 10.9), [.click(right: false)])
        // 動かした指を離してからは 1.8 秒。数え直したので、前のクリックから 0.9 秒でクリック
        XCTAssertEqual(tap(&g, id: 3, down: 11.7, up: 11.8), [.click(right: false)])
        XCTAssertEqual(tap(&g, id: 4, down: 12.5, up: 12.7), [.click(right: false)])
        // 前のクリックから 1 秒を過ぎたら空白
        XCTAssertEqual(tap(&g, id: 5, down: 13.8, up: 13.9), [.space])
        XCTAssertEqual(tap(&g, id: 6, down: 13.95, up: 14.0), [.space])
    }

    /// 動かした指をまた動かして離せば、そこから 1 秒を数え直す
    func testMovingAgainRestartsTheGraceTime() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        drag(&g, id: 2, down: 10.5, up: 11.5)
        XCTAssertEqual(tap(&g, id: 3, down: 12.0, up: 12.4), [.click(right: false)])
    }

    /// 間にほかのキーを打ったら猶予は終わる（その後のタップは空白）
    func testTypingAnotherKeyEndsTheGraceTime() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        g.keyTyped()
        XCTAssertEqual(tap(&g, id: 2, down: 10.2, up: 10.3), [.space])
        // 打ったあとにまた動かせば、また猶予が付く
        drag(&g, id: 3, down: 11, up: 12)
        XCTAssertEqual(tap(&g, id: 4, down: 12.2, up: 12.3), [.click(right: false)])
    }

    /// ほかのキーを打ったのが、動かした指を離す前なら、猶予は離した時刻から（離したあとに打てば終わる）
    func testKeyTypedWhileTheFingerIsStillDownDoesNotEndTheGraceTime() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        _ = g.touchMoved(1, to: p(40), time: 0.1)
        g.keyTyped()
        _ = g.touchUp(1, at: p(40), time: 0.5)
        XCTAssertEqual(tap(&g, id: 2, down: 0.6, up: 0.7), [.click(right: false)])
    }

    /// 取り消された指は何も出さず、猶予にも関わらない
    func testCancelledFingerDoesNothing() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        _ = g.touchMoved(1, to: p(40), time: 0.1)
        g.touchCancelled(1)
        XCTAssertFalse(g.isTouching)
        XCTAssertEqual(g.touchUp(1, at: p(40), time: 0.2), [])
        XCTAssertEqual(tap(&g, id: 2, down: 0.3, up: 0.4), [.space])
        // 取り消された指（動かしていない）は空白も出さない
        _ = g.touchDown(3, side: .right, at: origin, time: 1)
        g.touchCancelled(3)
        XCTAssertEqual(g.touchUp(3, at: origin, time: 1.1), [])
    }

    // MARK: 左右同時押し

    /// 2 本目が触れた時、1 本目がまだ触れている → 右クリック。どちらも空白を打たない
    func testPressingBothSidesRightClicksAndTypesNoSpace() {
        var g = SpacePointerGesture()
        XCTAssertEqual(g.touchDown(1, side: .left, at: origin, time: 0), [])
        XCTAssertEqual(g.touchDown(2, side: .right, at: p(300), time: 0.05), [.click(right: true)])
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.2), [])
        XCTAssertEqual(g.touchUp(2, at: p(300), time: 0.25), [])
        XCTAssertFalse(g.isTouching)
        // 右が先でも、離す順が逆でも同じ
        XCTAssertEqual(g.touchDown(3, side: .right, at: p(300), time: 1), [])
        XCTAssertEqual(g.touchDown(4, side: .left, at: origin, time: 1.02), [.click(right: true)])
        XCTAssertEqual(g.touchUp(3, at: p(300), time: 1.1), [])
        XCTAssertEqual(g.touchUp(4, at: origin, time: 1.2), [])
        // 両押しのあと、1 本ずつのタップは普通に空白
        XCTAssertEqual(tap(&g, id: 5, down: 3, up: 3.1), [.space])
    }

    /// 1 本目が離れていたら（触れていなければ）右クリックではない
    func testSequentialTapsOnBothSidesAreSpaces() {
        var g = SpacePointerGesture()
        XCTAssertEqual(tap(&g, id: 1, side: .left, down: 0, up: 0.1), [.space])
        XCTAssertEqual(tap(&g, id: 2, side: .right, down: 0.12, up: 0.2), [.space])
    }

    /// 同じ側の 2 本は右クリックではない
    func testTwoFingersOnTheSameSideAreNotARightClick() {
        var g = SpacePointerGesture()
        XCTAssertEqual(g.touchDown(1, side: .left, at: origin, time: 0), [])
        XCTAssertEqual(g.touchDown(2, side: .left, at: origin, time: 0.05), [])
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.1), [.space])
        XCTAssertEqual(g.touchUp(2, at: origin, time: 0.15), [.space])
    }

    /// 1 本目がポインタを動かしている途中でも、2 本目が触れたら右クリック。2 本目は空白を打たず、1 本目は動かし続けられる
    func testRightClickWhileMovingThePointer() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        XCTAssertEqual(g.touchMoved(1, to: p(30), time: 0.1).count, 1)
        XCTAssertEqual(g.touchDown(2, side: .right, at: p(300), time: 0.15), [.click(right: true)])
        XCTAssertEqual(g.touchUp(2, at: p(300), time: 0.2), [])
        XCTAssertEqual(g.touchMoved(1, to: p(40), time: 0.3).count, 1)
        XCTAssertEqual(g.touchUp(1, at: p(40), time: 0.4), [])
    }

    /// 右クリックの 2 本は、あとで動かしてもポインタを動かさない
    func testRightClickFingersDoNotMoveThePointerLater() {
        var g = SpacePointerGesture()
        _ = g.touchDown(1, side: .left, at: origin, time: 0)
        _ = g.touchDown(2, side: .right, at: p(300), time: 0.05)
        XCTAssertEqual(g.touchMoved(1, to: p(60), time: 0.1), [])
        XCTAssertEqual(g.touchMoved(2, to: p(360), time: 0.1), [])
        XCTAssertEqual(g.touchUp(1, at: p(60), time: 0.2), [])
        XCTAssertEqual(g.touchUp(2, at: p(360), time: 0.2), [])
        // 動かした扱いにならないので、猶予は付かない
        XCTAssertEqual(tap(&g, id: 3, down: 0.3, up: 0.4), [.space])
    }

    /// 右クリックは猶予に関わらない（猶予の途中の両押しは右クリックで、猶予はそのまま）
    func testRightClickDoesNotChangeTheGraceTime() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        _ = g.touchDown(2, side: .left, at: origin, time: 10.2)
        XCTAssertEqual(g.touchDown(3, side: .right, at: p(300), time: 10.25), [.click(right: true)])
        _ = g.touchUp(2, at: origin, time: 10.3)
        _ = g.touchUp(3, at: p(300), time: 10.35)
        XCTAssertEqual(tap(&g, id: 4, down: 10.6, up: 10.7), [.click(right: false)])
        var late = SpacePointerGesture()
        drag(&late, id: 1, down: 0, up: 10)
        _ = late.touchDown(2, side: .left, at: origin, time: 10.2)
        _ = late.touchDown(3, side: .right, at: p(300), time: 10.25)
        _ = late.touchUp(2, at: origin, time: 10.3)
        _ = late.touchUp(3, at: p(300), time: 10.35)
        XCTAssertEqual(tap(&late, id: 4, down: 11.0, up: 11.1), [.space])
    }

    func testResetForgetsEverything() {
        var g = SpacePointerGesture()
        drag(&g, id: 1, down: 0, up: 10)
        _ = g.touchDown(2, side: .left, at: origin, time: 10.1)
        g.reset()
        XCTAssertFalse(g.isTouching)
        XCTAssertEqual(tap(&g, id: 3, down: 10.2, up: 10.3), [.space])
    }
}
