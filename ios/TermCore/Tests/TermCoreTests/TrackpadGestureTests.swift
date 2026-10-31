import CoreGraphics
import XCTest
@testable import TermCore

/// 縦持ちのシェルのトラックパッド（docs/design.md「縦持ち：シェルはトラックパッド」）
final class TrackpadGestureTests: XCTestCase {
    typealias Out = TrackpadGesture.Output

    let origin = CGPoint(x: 150, y: 200)

    func p(_ dx: CGFloat, _ dy: CGFloat = 0, from o: CGPoint? = nil) -> CGPoint {
        let o = o ?? origin
        return CGPoint(x: o.x + dx, y: o.y + dy)
    }

    func tap(_ g: inout TrackpadGesture, id: Int, down: TimeInterval, up: TimeInterval, at q: CGPoint? = nil) -> [Out] {
        _ = g.touchDown(id, at: q ?? origin, time: down)
        return g.touchUp(id, at: q ?? origin, time: up)
    }

    /// 出力のポインタの動きの合計
    func moved(_ out: [Out]) -> CGPoint {
        out.reduce(.zero) { acc, o in
            if case .movePointer(let dx, let dy) = o { return CGPoint(x: acc.x + dx, y: acc.y + dy) }
            return acc
        }
    }

    func scrolled(_ out: [Out]) -> CGFloat {
        out.reduce(0) { acc, o in
            if case .scroll(let dy) = o { return acc + dy }
            return acc
        }
    }

    func testConstantsAreSharedWithTheLandscapePointer() {
        XCTAssertEqual(TrackpadGesture.slop, SpacePointerGesture.slop)
        XCTAssertEqual(TrackpadGesture.tapTime, 0.3)
        XCTAssertEqual(TrackpadGesture.doubleClickInterval, 0.5)
        // ドラッグの窓はダブルクリックより短い（クリックしてすぐ動かす操作と取り違えない）
        XCTAssertLessThan(TrackpadGesture.dragInterval, TrackpadGesture.doubleClickInterval)
    }

    // MARK: 1 本指

    func testTapIsALeftClick() {
        var g = TrackpadGesture()
        XCTAssertEqual(g.touchDown(1, at: origin, time: 0), [])
        XCTAssertTrue(g.isTouching)
        // 6pt 以内のぶれは動かしたことにならない（ポインタも動かない）
        XCTAssertEqual(g.touchMoved(1, to: p(4, 3), time: 0.05), [])
        XCTAssertEqual(g.touchUp(1, at: p(4, 3), time: 0.2), [.click(count: 1)])
        XCTAssertFalse(g.isTouching)
    }

    /// 動かさずに長く触れていた（指を置いただけ）なら、何もしない
    func testRestingFingerDoesNothing() {
        var g = TrackpadGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 0.31), [])
        // 次のタップは 1 回目から
        XCTAssertEqual(tap(&g, id: 2, down: 0.4, up: 0.5), [.click(count: 1)])
    }

    /// 6pt を超えたら、触れた点からの動きをまとめて、加速を掛けて動かす。その後は前の点からの差
    func testMovingMovesThePointerWithAcceleration() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        XCTAssertEqual(g.touchMoved(1, to: p(5), time: 0.1), [])
        // 0.2 秒で 10pt（50pt/秒。ゆっくり）→ 倍率は最小
        let first = g.touchMoved(1, to: p(10), time: 0.2)
        XCTAssertEqual(first, [.movePointer(dx: 10 * PointerCurve.minGain, dy: 0)])
        // 速く（0.01 秒で 20pt = 2000pt/秒）→ 倍率は最大
        let fast = g.touchMoved(1, to: p(30), time: 0.21)
        XCTAssertEqual(fast, [.movePointer(dx: 20 * PointerCurve.maxGain, dy: 0)])
        // 動かした指を離してもクリックにしない
        XCTAssertEqual(g.touchUp(1, at: p(30), time: 0.25), [])
    }

    func testMovingThenTappingStartsANewClickChain() {
        var g = TrackpadGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 0.1), [.click(count: 1)])
        // ポインタを動かした（ドラッグの窓の外で触れる）
        _ = g.touchDown(2, at: origin, time: 0.45)
        XCTAssertFalse(g.touchMoved(2, to: p(40), time: 0.5).isEmpty)
        _ = g.touchUp(2, at: p(40), time: 0.55)
        // 次のタップはダブルクリックにならない
        XCTAssertEqual(tap(&g, id: 3, down: 0.6, up: 0.7), [.click(count: 1)])
    }

    // MARK: ダブルクリック

    func testDoubleAndTripleClick() {
        var g = TrackpadGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 0.1), [.click(count: 1)])
        // 離してから 0.5 秒以内に触れたタップは回数を足す
        XCTAssertEqual(tap(&g, id: 2, down: 0.55, up: 0.65), [.click(count: 2)])
        XCTAssertEqual(tap(&g, id: 3, down: 0.8, up: 0.9), [.click(count: 3)])
        // 0.5 秒を過ぎたら 1 回目から
        XCTAssertEqual(tap(&g, id: 4, down: 1.41, up: 1.5), [.click(count: 1)])
    }

    /// 1 回目のタップはすぐクリック（ダブルクリックを待たない）
    func testFirstClickIsNotDelayed() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.05), [.click(count: 1)])
    }

    // MARK: ドラッグ

    /// タップしてから 0.3 秒以内に触れ直して動かす → ドラッグ（ポインタの動きはドラッグの間も出す）。離したら終わり
    func testTapThenTouchAndMoveDrags() {
        var g = TrackpadGesture()
        XCTAssertEqual(tap(&g, id: 1, down: 0, up: 0.1), [.click(count: 1)])
        XCTAssertEqual(g.touchDown(2, at: origin, time: 0.3), [])
        XCTAssertEqual(g.touchMoved(2, to: p(3), time: 0.35), [])
        let start = g.touchMoved(2, to: p(0, 12), time: 0.5)
        XCTAssertEqual(start.first, .dragBegan)
        XCTAssertEqual(moved(start).y, 12 * PointerCurve.minGain, accuracy: 0.001)
        let more = g.touchMoved(2, to: p(0, 20), time: 0.6)
        XCTAssertEqual(more.count, 1)
        XCTAssertGreaterThan(moved(more).y, 0)
        XCTAssertEqual(g.touchUp(2, at: p(0, 20), time: 0.7), [.dragEnded(cancelled: false)])
        // ドラッグの後はクリックの続きにならない
        XCTAssertEqual(tap(&g, id: 3, down: 0.8, up: 0.9), [.click(count: 1)])
    }

    /// ドラッグの窓（0.3 秒）を過ぎて触れ直して動かすのは、ただのポインタの移動
    func testLateSecondTouchMovesThePointer() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        _ = g.touchDown(2, at: origin, time: 0.41)
        let out = g.touchMoved(2, to: p(20), time: 0.5)
        XCTAssertFalse(out.contains(.dragBegan))
        XCTAssertGreaterThan(moved(out).x, 0)
        XCTAssertEqual(g.touchUp(2, at: p(20), time: 0.6), [])
    }

    /// ドラッグの窓の中で触れ直しても、動かさずに離せばダブルクリック
    func testQuickSecondTapWithoutMovingIsADoubleClick() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        XCTAssertEqual(tap(&g, id: 2, down: 0.2, up: 0.3), [.click(count: 2)])
    }

    /// 触れ直したまま長く止めてから動かしても、ドラッグ（Mac と同じ）
    func testHoldingTheSecondTouchThenMovingStillDrags() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        _ = g.touchDown(2, at: origin, time: 0.2)
        let out = g.touchMoved(2, to: p(30), time: 1.5)
        XCTAssertEqual(out.first, .dragBegan)
        XCTAssertEqual(g.touchUp(2, at: p(30), time: 1.6), [.dragEnded(cancelled: false)])
    }

    func testCancelledDragDoesNotCopy() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        _ = g.touchDown(2, at: origin, time: 0.2)
        _ = g.touchMoved(2, to: p(30), time: 0.3)
        XCTAssertEqual(g.touchCancelled(2), [.dragEnded(cancelled: true)])
        XCTAssertFalse(g.isTouching)
        // 取り消しの後はクリックの続きにならない
        XCTAssertEqual(tap(&g, id: 3, down: 0.35, up: 0.4), [.click(count: 1)])
    }

    func testResetEndsADragAsCancelled() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        _ = g.touchDown(2, at: origin, time: 0.2)
        _ = g.touchMoved(2, to: p(30), time: 0.3)
        XCTAssertEqual(g.reset(), [.dragEnded(cancelled: true)])
        XCTAssertFalse(g.isTouching)
        XCTAssertEqual(g.reset(), [])
        // 捨てた指が離れても何も出さない
        XCTAssertEqual(g.touchUp(2, at: p(30), time: 0.4), [])
    }

    // MARK: 2 本指

    func testTwoFingerTapIsARightClick() {
        var g = TrackpadGesture()
        XCTAssertEqual(g.touchDown(1, at: origin, time: 0), [])
        XCTAssertEqual(g.touchDown(2, at: p(40), time: 0.03), [])
        XCTAssertEqual(g.touchUp(1, at: origin, time: 0.15), [])
        XCTAssertEqual(g.touchUp(2, at: p(40), time: 0.2), [.rightClick])
        XCTAssertFalse(g.isTouching)
        // 右クリックの後のタップは 1 回目
        XCTAssertEqual(tap(&g, id: 3, down: 0.3, up: 0.4), [.click(count: 1)])
    }

    /// 2 本指を長く置いていた・動かしたなら、右クリックにしない
    func testSlowOrMovedTwoFingerTouchIsNotARightClick() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        _ = g.touchDown(2, at: p(40), time: 0.03)
        _ = g.touchUp(1, at: origin, time: 0.2)
        XCTAssertEqual(g.touchUp(2, at: p(40), time: 0.4), [])
        _ = g.touchDown(3, at: origin, time: 1)
        _ = g.touchDown(4, at: p(40), time: 1.02)
        _ = g.touchUp(3, at: origin, time: 1.1)
        _ = g.touchMoved(4, to: p(40, 10), time: 1.12)
        XCTAssertEqual(g.touchUp(4, at: p(40, 10), time: 1.15), [])
    }

    /// 2 本指で動かす → スクロール（中点の縦の動き。指に付いて動く向きで、下へ正）。離したら止まる
    func testTwoFingerDragScrolls() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        _ = g.touchDown(2, at: p(40), time: 0.01)
        var out: [Out] = []
        // 2 本とも下へ 30pt（中点も 30pt）
        for i in 1...6 {
            let dy = CGFloat(i) * 5
            out += g.touchMoved(1, to: p(0, dy), time: 0.01 + Double(i) * 0.02)
            out += g.touchMoved(2, to: p(40, dy), time: 0.02 + Double(i) * 0.02)
        }
        XCTAssertEqual(out.filter { $0 == .scrollBegan }.count, 1)
        XCTAssertEqual(scrolled(out), 30, accuracy: 0.001)
        XCTAssertEqual(moved(out), .zero)
        XCTAssertFalse(out.contains { if case .zoom = $0 { return true } else { return false } })
        // 1 本を離したら、残りの指は離すまで何もしない
        XCTAssertEqual(g.touchUp(1, at: p(0, 30), time: 0.2), [])
        XCTAssertEqual(g.touchMoved(2, to: p(40, 80), time: 0.25), [])
        XCTAssertEqual(g.touchUp(2, at: p(40, 80), time: 0.3), [])
        // 上へ動かすと負
        _ = g.touchDown(3, at: origin, time: 1)
        _ = g.touchDown(4, at: p(40), time: 1.01)
        let up = g.touchMoved(3, to: p(0, -20), time: 1.05) + g.touchMoved(4, to: p(40, -20), time: 1.06)
        XCTAssertEqual(scrolled(up), -20, accuracy: 0.001)
    }

    func testPinchZoomsOneStepPerGesture() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: p(-50), time: 0)
        _ = g.touchDown(2, at: p(50), time: 0.01)
        // 100pt → 120pt（1.2 倍）で 1 段大きく。中点は動かない
        var out = g.touchMoved(1, to: p(-60), time: 0.05)
        out += g.touchMoved(2, to: p(60), time: 0.06)
        XCTAssertEqual(out, [.zoom(in: true)])
        // 同じ操作の間はもう出さない（さらに開いても、スクロールにもならない）
        XCTAssertEqual(g.touchMoved(1, to: p(-100, 30), time: 0.1), [])
        _ = g.touchUp(1, at: p(-100, 30), time: 0.2)
        _ = g.touchUp(2, at: p(60), time: 0.2)
        // 閉じる → 1 段小さく
        _ = g.touchDown(3, at: p(-50), time: 1)
        _ = g.touchDown(4, at: p(50), time: 1.01)
        let pinchIn = g.touchMoved(3, to: p(-40), time: 1.05) + g.touchMoved(4, to: p(40), time: 1.06)
        XCTAssertEqual(pinchIn, [.zoom(in: false)])
    }

    /// 1 本指でポインタを動かしている途中に 2 本目が触れたら、ポインタは止まり、2 本指の操作になる
    func testSecondFingerWhilePointingSwitchesToTwoFingers() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        XCTAssertFalse(g.touchMoved(1, to: p(20), time: 0.1).isEmpty)
        _ = g.touchDown(2, at: p(60), time: 0.15)
        let out = g.touchMoved(1, to: p(20, 15), time: 0.2) + g.touchMoved(2, to: p(60, 15), time: 0.21)
        XCTAssertEqual(moved(out), .zero)
        XCTAssertEqual(scrolled(out), 15, accuracy: 0.001)
        _ = g.touchUp(1, at: p(20, 15), time: 0.3)
        _ = g.touchUp(2, at: p(60, 15), time: 0.3)
        XCTAssertFalse(g.isTouching)
        // 動かしていた指を含むので、右クリックにはしない
        _ = g.touchDown(3, at: origin, time: 1)
        XCTAssertFalse(g.touchMoved(3, to: p(20), time: 1.1).isEmpty)
        _ = g.touchDown(4, at: p(60), time: 1.12)
        _ = g.touchUp(3, at: p(20), time: 1.14)
        XCTAssertEqual(g.touchUp(4, at: p(60), time: 1.16), [])
    }

    /// ドラッグの途中に 2 本目が触れたら、ドラッグを終えて（コピーして）から 2 本指
    func testSecondFingerEndsADrag() {
        var g = TrackpadGesture()
        _ = tap(&g, id: 1, down: 0, up: 0.1)
        _ = g.touchDown(2, at: origin, time: 0.2)
        XCTAssertEqual(g.touchMoved(2, to: p(30), time: 0.3).first, .dragBegan)
        XCTAssertEqual(g.touchDown(3, at: p(80), time: 0.4), [.dragEnded(cancelled: false)])
        // 離しても、もう 1 度ドラッグを終えない
        XCTAssertEqual(g.touchUp(2, at: p(30), time: 0.5), [])
        XCTAssertEqual(g.touchUp(3, at: p(80), time: 0.55), [])
    }

    // MARK: 3 本指

    func testThreeFingersDoNothingUntilAllAreLifted() {
        var g = TrackpadGesture()
        _ = g.touchDown(1, at: origin, time: 0)
        _ = g.touchDown(2, at: p(30), time: 0.01)
        XCTAssertEqual(g.touchDown(3, at: p(60), time: 0.02), [])
        XCTAssertEqual(g.touchMoved(1, to: p(0, 40), time: 0.1), [])
        XCTAssertEqual(g.touchMoved(2, to: p(30, 40), time: 0.1), [])
        XCTAssertEqual(g.touchUp(1, at: p(0, 40), time: 0.12), [])
        XCTAssertEqual(g.touchUp(2, at: p(30, 40), time: 0.13), [])
        XCTAssertEqual(g.touchUp(3, at: p(60), time: 0.14), [])
        XCTAssertFalse(g.isTouching)
        // すべて離したら元どおり
        XCTAssertEqual(tap(&g, id: 4, down: 1, up: 1.1), [.click(count: 1)])
    }

    /// 知らない指（取り消した後など）の動き・離しは何も出さない
    func testUnknownFingersAreIgnored() {
        var g = TrackpadGesture()
        XCTAssertEqual(g.touchMoved(9, to: origin, time: 0), [])
        XCTAssertEqual(g.touchUp(9, at: origin, time: 0), [])
        XCTAssertEqual(g.touchCancelled(9), [])
    }
}
