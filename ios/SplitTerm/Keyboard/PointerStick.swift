import TermCore
import UIKit

/// ポインタの動きとクリックを受け取る（動ける範囲・クリックの行き先は受け手が決める）
@MainActor
protocol PointerOutput: AnyObject {
    /// ポインタを動かす（pt）
    func pointerMove(dx: CGFloat, dy: CGFloat)
    /// クリック。right なら右クリック
    func pointerClick(right: Bool)
}

/// ポインタ（docs/design.md「ポインタ」）への出口。ノートパソコンのトラックパッドのように、指の動いた分だけポインタが動き、
/// 速く動かすほど遠くへ届く（指の速さに応じた倍率 `PointerCurve.gain`）。止めれば止まる
/// - 空白兼ポインタ（左右の空白キー）の判定は TermCore の `SpacePointerGesture`。その出力のポインタの移動（`move`）と
///   クリック（`click(right:)`）をここから受け手へ渡す。クリックには、押し込んだ手応えの振動を返す（3D Touch のような感触）
/// - フリックの「空白」の長押しでキーボードをトラックパッドにした間は、その指の動き（`down`・`moved`・`up`）を受け持ち、
///   別の指のタップは左クリック（`click(right:)`。ノートパソコンのトラックパッドと同じ）
@MainActor
final class PointerStick {
    weak var output: PointerOutput?
    var haptics = true

    /// タップとみなす、ずれと時間の上限。ずれは空白兼ポインタが動かしたとみなす距離と同じ
    static let tapSlop: CGFloat = SpacePointerGesture.slop
    static let tapTime: TimeInterval = 0.3

    private struct Touch {
        let id: ObjectIdentifier
        let start: CGPoint
        var current: CGPoint
        let began: TimeInterval
        /// 前の動きの時刻と、そこでの指の速さ（pt/秒）
        var lastTime: TimeInterval
        var speed: CGFloat = 0
        /// ずれがタップの範囲を超えた（離してもクリックにしない）
        var moved = false
    }

    private var primary: Touch?
    private var secondary: ObjectIdentifier?
    /// 両方を押して右クリックにした（そのあと離しても左クリックにしない）
    private var suppressClick = false
    private let clickHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let deepHaptic = UIImpactFeedbackGenerator(style: .heavy)

    /// トラックパッドの指が触れているか（空白の長押しでトラックパッドに入るのを止めるのに使う）
    var isActive: Bool { primary != nil }

    /// ポインタを動かす（空白兼ポインタの指の動き。倍率は `SpacePointerGesture` が掛けた後の pt）
    func move(dx: CGFloat, dy: CGFloat) {
        output?.pointerMove(dx: dx, dy: dy)
    }

    func down(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        if primary == nil {
            primary = Touch(id: id, start: p, current: p, began: time, lastTime: time)
            suppressClick = false
            if haptics { clickHaptic.prepare() }
        } else if secondary == nil, primary?.id != id {
            // 両方を同時に押した → 右クリック（1 回）
            secondary = id
            suppressClick = true
            click(right: true)
        }
    }

    /// クリック（手応えの振動つき）。right なら右クリック。タップの判定は呼び手がする
    /// （この中の `down`・`up` と、トラックパッドの間の別の指のタップ）
    func click(right: Bool) {
        if haptics {
            if right {
                deepHaptic.impactOccurred(intensity: 1)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    self?.clickHaptic.impactOccurred(intensity: 0.7)
                }
            } else {
                clickHaptic.impactOccurred(intensity: 1)
            }
        }
        output?.pointerClick(right: right)
    }

    /// 指が動いた。前の点と時刻から指の速さを出し、その速さの倍率を掛けた分だけポインタを動かす
    func moved(_ id: ObjectIdentifier, to p: CGPoint, time: TimeInterval) {
        guard var t = primary, t.id == id else { return }
        let dx = p.x - t.current.x, dy = p.y - t.current.y
        let distance = hypot(dx, dy)
        // 時刻が進んでいないとき（dt が 0）は、前の速さのまま
        let dt = time - t.lastTime
        if dt > 0 { t.speed = distance / CGFloat(dt) }
        t.current = p
        t.lastTime = max(t.lastTime, time)
        if hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapSlop { t.moved = true }
        primary = t
        if distance > 0 {
            let gain = PointerCurve.gain(speed: t.speed)
            output?.pointerMove(dx: dx * gain, dy: dy * gain)
        }
    }

    func up(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        if secondary == id {
            secondary = nil
            return
        }
        guard let t = primary, t.id == id else { return }
        primary = nil
        let distance = hypot(p.x - t.start.x, p.y - t.start.y)
        if !suppressClick && !t.moved && distance <= Self.tapSlop && time - t.began <= Self.tapTime {
            click(right: false)
        }
        if secondary == nil { suppressClick = false }
    }

    func cancel(_ id: ObjectIdentifier) {
        if secondary == id { secondary = nil }
        if primary?.id == id { primary = nil }
    }

    func reset() {
        primary = nil
        secondary = nil
        suppressClick = false
    }
}
