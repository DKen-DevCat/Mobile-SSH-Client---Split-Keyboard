import CoreGraphics
import Foundation

/// 縦持ちのシェルの面のトラックパッド（docs/design.md「縦持ち：シェルはトラックパッド」）。Mac のトラックパッド（タップでクリック）と
/// 同じ手つきで、行き先は触れた位置ではなくポインタの位置（行き先を決めるのは受け手）。画面にも時計にも頼らない状態機械で、
/// 入力は触れた・動いた・離れた・取り消された（指 ID・位置・時刻）、出力はポインタを動かす・クリック・右クリック・ドラッグ・
/// スクロール・倍率。
///
/// - 1 本指で `slop`（6pt）を超えて動かす → ポインタを動かす（`PointerCurve` の加速。触れた点からの動きをまとめて渡す）
/// - 1 本指のタップ（`tapTime` 以内に、`slop` 以内で離す）→ 左クリック。前のタップを離してから `doubleClickInterval` 以内に触れた
///   タップは回数を足す（2 回目がダブルクリック）。間にほかの操作をしたら 1 回目から
/// - タップを離してから `dragInterval` 以内に触れ直し、そのまま動かす → ドラッグ（始め・ポインタの動き・終わり）
/// - 2 本指で動かす → スクロール（指に付いて動く向き。下へ正）。2 本指のタップ → 右クリック。2 本指を開く・閉じる → 倍率を 1 段
/// - 3 本指以上 → すべて離すまで何もしない
///
/// 位置はシェルの座標（どの座標でも、同じ尺度ならよい）。時刻は `UITouch.timestamp` と同じ秒
public struct TrackpadGesture: Sendable {
    /// 動かしたとみなす距離（pt）。横持ちの空白兼ポインタ・トラックパッドと同じ
    public static let slop: CGFloat = SpacePointerGesture.slop
    /// タップとみなす、触れていた時間の上限（秒）。横持ちのトラックパッド（`PointerStick.tapTime`）も同じ値を使う
    public static let tapTime: TimeInterval = 0.3
    /// 前のタップを離してから、次のタップに触れるまでの上限（秒）。Mac の既定のダブルクリックの速さ
    public static let doubleClickInterval: TimeInterval = 0.5
    /// タップを離してから、触れ直してドラッグにできる上限（秒）。クリックしてすぐポインタを動かす操作と取り違えないよう短く
    public static let dragInterval: TimeInterval = 0.3
    /// 2 本指の間がこの比を超えて開く・閉じると、倍率を 1 段（横持ちのピンチと同じ）
    public static let zoomInRatio: CGFloat = 1.15
    public static let zoomOutRatio: CGFloat = 0.87

    public enum Output: Equatable, Sendable {
        /// ポインタを動かす（指の速さに応じた倍率を掛けた後の pt）
        case movePointer(dx: CGFloat, dy: CGFloat)
        /// 左クリック。count は続けて何回目か（2 がダブルクリック）
        case click(count: Int)
        /// 右クリック（2 本指のタップ）
        case rightClick
        /// ドラッグを始めた（この後のポインタの動きはドラッグ）
        case dragBegan
        /// ドラッグを終えた。cancelled なら指が取り消された（コピーしない）
        case dragEnded(cancelled: Bool)
        /// 2 本指のスクロールを始めた（行にそろえる端数を捨てる）
        case scrollBegan
        /// 2 本指の中点の縦の動き（pt。下へ正）
        case scroll(dy: CGFloat)
        /// 倍率を 1 段。in なら大きく
        case zoom(in: Bool)
    }

    private struct Finger: Sendable {
        let start: CGPoint
        var current: CGPoint
        let began: TimeInterval
        /// 前の動きの時刻（最初は触れた時刻）と、そこでの指の速さ（pt/秒）
        var lastTime: TimeInterval
        var speed: CGFloat = 0

        var movedBeyondSlop: Bool { hypot(current.x - start.x, current.y - start.y) > TrackpadGesture.slop }
    }

    private enum TwoFingerKind: Sendable {
        case undecided, scroll, zoom
    }

    private enum Phase: Sendable {
        case idle
        /// 1 本指で、まだ動かしていない。dragCandidate: タップを離してから `dragInterval` 以内に触れた（動かせばドラッグ）
        case touching(Int, dragCandidate: Bool)
        /// 1 本指でポインタを動かしている
        case pointing(Int)
        /// 1 本指でドラッグしている
        case dragging(Int)
        /// 2 本指。tapPossible: 2 本とも動かしていない（1 本目がポインタを動かしていた・ドラッグしていたなら false）
        case twoFinger(a: Int, b: Int, began: TimeInterval, startCentroid: CGPoint, lastCentroid: CGPoint,
                       startDistance: CGFloat, kind: TwoFingerKind, tapPossible: Bool)
        /// 2 本指のタップの途中で 1 本を離した。残りの指がタップの時間内に動かさずに離れたら右クリック
        case twoFingerLifting(remaining: Int, began: TimeInterval)
        /// すべての指を離すまで何もしない
        case ignoring
    }

    private var fingers: [Int: Finger] = [:]
    private var phase = Phase.idle
    /// 最後のタップを離した時刻と、続けて何回目のクリックだったか。ほかの操作をしたら nil
    private var lastTap: (time: TimeInterval, count: Int)?

    public init() {}

    /// 触れている指があるか
    public var isTouching: Bool { !fingers.isEmpty }

    public mutating func touchDown(_ id: Int, at p: CGPoint, time: TimeInterval) -> [Output] {
        fingers[id] = Finger(start: p, current: p, began: time, lastTime: time)
        switch phase {
        case .idle:
            let drag = lastTap.map { time - $0.time <= Self.dragInterval } ?? false
            phase = .touching(id, dragCandidate: drag)
            return []
        case .touching(let a, _):
            lastTap = nil
            phase = twoFinger(a, id, time: time, tapPossible: true)
            return []
        case .pointing(let a):
            // ポインタを動かしている途中の 2 本目。ポインタは止まり、2 本指の操作になる
            phase = twoFinger(a, id, time: time, tapPossible: false)
            return []
        case .dragging(let a):
            // ドラッグを終えて（コピーして）から 2 本指の操作
            phase = twoFinger(a, id, time: time, tapPossible: false)
            return [.dragEnded(cancelled: false)]
        case .twoFinger, .twoFingerLifting, .ignoring:
            // 3 本目から: すべて離すまで何もしない
            lastTap = nil
            phase = .ignoring
            return []
        }
    }

    public mutating func touchMoved(_ id: Int, to p: CGPoint, time: TimeInterval) -> [Output] {
        guard var f = fingers[id] else { return [] }
        let previous = f.current
        f.current = p
        switch phase {
        case .touching(let a, let drag) where a == id:
            guard f.movedBeyondSlop else {
                fingers[id] = f
                return []
            }
            // 動かし始め。触れた点からここまでの動きを、まとめて動かす
            let dx = p.x - f.start.x, dy = p.y - f.start.y
            Self.updateSpeed(&f, distance: hypot(dx, dy), time: time)
            fingers[id] = f
            lastTap = nil
            if drag {
                phase = .dragging(id)
                return [.dragBegan, Self.move(dx: dx, dy: dy, speed: f.speed)]
            }
            phase = .pointing(id)
            return [Self.move(dx: dx, dy: dy, speed: f.speed)]
        case .pointing(let a) where a == id, .dragging(let a) where a == id:
            let dx = p.x - previous.x, dy = p.y - previous.y
            let distance = hypot(dx, dy)
            Self.updateSpeed(&f, distance: distance, time: time)
            fingers[id] = f
            return distance > 0 ? [Self.move(dx: dx, dy: dy, speed: f.speed)] : []
        case .twoFinger(let a, let b, let began, let c0, let last, let d0, let kind, var tap) where id == a || id == b:
            fingers[id] = f
            if f.movedBeyondSlop { tap = false }
            let c = centroid(a, b), d = distance(a, b)
            var next = kind
            var out: [Output] = []
            switch kind {
            case .undecided:
                // 広がりが先にしきい値を超えれば倍率、中点の動きが 6pt を超えて広がりの変化より大きければスクロール
                let ratio = d0 > 0 ? d / d0 : 1
                if ratio >= Self.zoomInRatio || ratio <= Self.zoomOutRatio {
                    next = .zoom
                    tap = false
                    out = [.zoom(in: ratio > 1)]
                } else {
                    let shift = hypot(c.x - c0.x, c.y - c0.y)
                    if shift > Self.slop && shift > abs(d - d0) {
                        next = .scroll
                        tap = false
                        out = [.scrollBegan, .scroll(dy: c.y - c0.y)]
                    }
                }
            case .scroll:
                if c.y != last.y { out = [.scroll(dy: c.y - last.y)] }
            case .zoom:
                // 1 回の操作で 1 段
                break
            }
            phase = .twoFinger(a: a, b: b, began: began, startCentroid: c0, lastCentroid: c, startDistance: d0,
                               kind: next, tapPossible: tap)
            return out
        case .twoFingerLifting(let remaining, _) where remaining == id:
            fingers[id] = f
            if f.movedBeyondSlop { phase = .ignoring }
            return []
        default:
            fingers[id] = f
            return []
        }
    }

    public mutating func touchUp(_ id: Int, at p: CGPoint, time: TimeInterval) -> [Output] {
        // 離した位置までの動きを先に渡す
        var out = touchMoved(id, to: p, time: time)
        guard let f = fingers.removeValue(forKey: id) else { return out }
        switch phase {
        case .touching(let a, _) where a == id:
            phase = .idle
            if time - f.began <= Self.tapTime {
                var count = 1
                if let last = lastTap, f.began - last.time <= Self.doubleClickInterval { count = last.count + 1 }
                lastTap = (time, count)
                out.append(.click(count: count))
            } else {
                // 動かさずに長く触れていた（指を置いただけ）。何もしない
                lastTap = nil
            }
        case .pointing(let a) where a == id:
            phase = .idle
        case .dragging(let a) where a == id:
            phase = .idle
            out.append(.dragEnded(cancelled: false))
        case .twoFinger(let a, let b, let began, _, _, _, _, let tap) where id == a || id == b:
            let other = id == a ? b : a
            phase = tap && time - began <= Self.tapTime ? .twoFingerLifting(remaining: other, began: began) : .ignoring
        case .twoFingerLifting(let remaining, let began) where remaining == id:
            phase = .idle
            if !f.movedBeyondSlop && time - began <= Self.tapTime { out.append(.rightClick) }
        default:
            break
        }
        if fingers.isEmpty, case .ignoring = phase { phase = .idle }
        return out
    }

    /// 指が取り消された（電話・回転など）。ドラッグは止めるがコピーしない。クリックの続きも終わる
    public mutating func touchCancelled(_ id: Int) -> [Output] {
        guard fingers.removeValue(forKey: id) != nil else { return [] }
        lastTap = nil
        var out: [Output] = []
        if case .dragging(let a) = phase, a == id { out.append(.dragEnded(cancelled: true)) }
        phase = fingers.isEmpty ? .idle : .ignoring
        return out
    }

    /// 状態を捨てる（向きを替えた・トラックパッドでなくなった）。ドラッグの途中なら、取り消しとして終える
    public mutating func reset() -> [Output] {
        var out: [Output] = []
        if case .dragging = phase { out.append(.dragEnded(cancelled: true)) }
        fingers.removeAll()
        phase = .idle
        lastTap = nil
        return out
    }

    private func twoFinger(_ a: Int, _ b: Int, time: TimeInterval, tapPossible: Bool) -> Phase {
        let c = centroid(a, b)
        return .twoFinger(a: a, b: b, began: time, startCentroid: c, lastCentroid: c, startDistance: distance(a, b),
                          kind: .undecided, tapPossible: tapPossible)
    }

    private func centroid(_ a: Int, _ b: Int) -> CGPoint {
        guard let p = fingers[a]?.current, let q = fingers[b]?.current else { return .zero }
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    private func distance(_ a: Int, _ b: Int) -> CGFloat {
        guard let p = fingers[a]?.current, let q = fingers[b]?.current else { return 0 }
        return hypot(p.x - q.x, p.y - q.y)
    }

    /// 時刻が進んでいないとき（dt が 0）は、前の速さのまま
    private static func updateSpeed(_ f: inout Finger, distance: CGFloat, time: TimeInterval) {
        let dt = time - f.lastTime
        if dt > 0 { f.speed = distance / CGFloat(dt) }
        f.lastTime = max(f.lastTime, time)
    }

    private static func move(dx: CGFloat, dy: CGFloat, speed: CGFloat) -> Output {
        let gain = PointerCurve.gain(speed: speed)
        return .movePointer(dx: dx * gain, dy: dy * gain)
    }
}
