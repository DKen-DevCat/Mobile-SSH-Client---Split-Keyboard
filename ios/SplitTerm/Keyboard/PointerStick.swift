import QuartzCore
import TermCore
import UIKit

/// ポインタの動きとクリックを受け取る（シェルの中だけで効かせるのは受け手）
@MainActor
protocol PointerOutput: AnyObject {
    /// ポインタを動かす（pt）
    func pointerMove(dx: CGFloat, dy: CGFloat)
    /// クリック。right なら右クリック
    func pointerClick(right: Bool)
}

/// スペースの横の赤い丸（docs/design.md「ポインタ」）。指を動かした分だけすぐに動き（細かい動きに付いてくる）、
/// 大きくずらしたままにすると、ThinkPad の TrackPoint のようにずれの向きと大きさで進み続ける（`PointerCurve`）。
/// - 左右どちらでも、先に触れた方がポインタを動かす
/// - 片方だけを軽くタップするとクリック、両方を同時に押すと右クリック
/// - クリックには、押し込んだ手応えの振動を返す（3D Touch のような感触）
@MainActor
final class PointerStick {
    weak var output: PointerOutput?
    var haptics = true

    /// タップとみなす、ずれと時間の上限
    static let tapSlop: CGFloat = 6
    static let tapTime: TimeInterval = 0.3

    private struct Touch {
        let id: ObjectIdentifier
        let start: CGPoint
        var current: CGPoint
        let began: TimeInterval
        /// ずれがタップの範囲を超えた（離してもクリックにしない）
        var moved = false
    }

    private var primary: Touch?
    private var secondary: ObjectIdentifier?
    /// 両方を押して右クリックにした（そのあと離しても左クリックにしない）
    private var suppressClick = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    private let deep = UIImpactFeedbackGenerator(style: .heavy)

    /// 触れているか（キーの見た目に使う）
    var isActive: Bool { primary != nil }

    func down(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        if primary == nil {
            primary = Touch(id: id, start: p, current: p, began: time)
            suppressClick = false
            if haptics { click.prepare() }
            startLink()
        } else if secondary == nil, primary?.id != id {
            // 両方を同時に押した → 右クリック（1 回）
            secondary = id
            suppressClick = true
            if haptics {
                deep.impactOccurred(intensity: 1)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    self?.click.impactOccurred(intensity: 0.7)
                }
            }
            output?.pointerClick(right: true)
        }
    }

    func moved(_ id: ObjectIdentifier, to p: CGPoint) {
        guard var t = primary, t.id == id else { return }
        // 指を動かした分だけ、すぐに動かす（細かい動きにそのまま付いてくる）
        let dx = p.x - t.current.x, dy = p.y - t.current.y
        t.current = p
        if hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapSlop { t.moved = true }
        primary = t
        if dx != 0 || dy != 0 {
            output?.pointerMove(dx: dx * PointerCurve.directGain, dy: dy * PointerCurve.directGain)
        }
    }

    func up(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        if secondary == id {
            secondary = nil
            return
        }
        guard let t = primary, t.id == id else { return }
        primary = nil
        stopLink()
        let distance = hypot(p.x - t.start.x, p.y - t.start.y)
        if !suppressClick && !t.moved && distance <= Self.tapSlop && time - t.began <= Self.tapTime {
            if haptics { click.impactOccurred(intensity: 1) }
            output?.pointerClick(right: false)
        }
        if secondary == nil { suppressClick = false }
    }

    func cancel(_ id: ObjectIdentifier) {
        if secondary == id { secondary = nil }
        if primary?.id == id {
            primary = nil
            stopLink()
        }
    }

    func reset() {
        primary = nil
        secondary = nil
        suppressClick = false
        stopLink()
    }

    // MARK: 動かす（画面の更新ごとに、ずれの向きへ速さ × 時間だけ進める）

    private final class LinkTarget: NSObject {
        weak var stick: PointerStick?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { stick?.tick(link) }
        }
    }

    private func startLink() {
        stopLink()
        let target = LinkTarget()
        target.stick = self
        let l = CADisplayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func tick(_ link: CADisplayLink) {
        guard let t = primary else { return }
        let now = link.timestamp
        let dt = min(0.05, max(0, now - lastTick))
        lastTick = now
        let dx = t.current.x - t.start.x, dy = t.current.y - t.start.y
        let d = hypot(dx, dy)
        let v = PointerCurve.speed(for: d)
        guard v > 0, d > 0, dt > 0 else { return }
        output?.pointerMove(dx: dx / d * v * dt, dy: dy / d * v * dt)
    }
}
