import CoreGraphics
import Foundation

/// 空白兼ポインタ（左右の空白キー）の触れ方の判定（docs/design.md「ポインタ」）。画面にも時計にも頼らない状態機械で、
/// 入力は触れた・動いた・離れた（指 ID・左右・位置・時刻）とほかのキーを打ったこと、出力は空白・クリック・ポインタを動かす。
///
/// - 動かさずに離す → 空白
/// - 触れた点から `slop`（6pt）より動かす → その指はポインタを動かす（トラックパッド式の加速 `PointerCurve`）。空白は打たない
/// - ポインタを動かした指を離してから `graceTime`（1.0 秒）以内に、動かさずに離した → 空白ではなく左クリック。
///   クリックしたら 1.0 秒を数え直す（続けて叩けばダブルクリック）。間にほかのキーを打ったら猶予は終わる
/// - 左右の空白兼ポインタを同時に押す（2 本目が触れた時、1 本目がまだ触れている）→ 右クリック。2 本の指はどちらも空白を打たない
///
/// 位置は、左右の面をまたいでも同じ尺度になるよう、ウィンドウの座標で渡す。時刻は `UITouch.timestamp` と同じ秒
public struct SpacePointerGesture: Sendable {
    /// 動かしたとみなす距離（pt）。`PointerStick.tapSlop` と同じ
    public static let slop: CGFloat = 6
    /// ポインタを動かした指を離してから、動かさずに離した指をクリックにする時間（秒）
    public static let graceTime: TimeInterval = 1.0

    public enum Output: Equatable, Sendable {
        /// 空白を打つ（修飾キー・ローマ字の変換・先行表示は、普通の空白キーと同じ道）
        case space
        /// クリック。right なら右クリック
        case click(right: Bool)
        /// ポインタを動かす（指の速さに応じた倍率を掛けた後の pt）
        case movePointer(dx: CGFloat, dy: CGFloat)
    }

    private struct Finger: Sendable {
        let side: PointerSide
        let start: CGPoint
        var current: CGPoint
        /// 前の動きの時刻（最初は触れた時刻）と、そこでの指の速さ（pt/秒）
        var lastTime: TimeInterval
        var speed: CGFloat = 0
        /// 触れた点から `slop` を超えて動かした（ポインタを動かす指）
        var moving = false
        /// 左右同時押しの右クリックに使った、または 2 本目の動き。離しても空白もクリックも出さない
        var consumed = false
    }

    private var fingers: [Int: Finger] = [:]
    /// ポインタを動かした指を離した時刻（クリックしたら、その指を離した時刻）。nil なら猶予なし
    private var graceFrom: TimeInterval?

    public init() {}

    /// 空白兼ポインタに触れている指があるか（空白の長押しでトラックパッドに入るのを止めるのに使う）
    public var isTouching: Bool { !fingers.isEmpty }

    public mutating func touchDown(_ id: Int, side: PointerSide, at p: CGPoint, time: TimeInterval) -> [Output] {
        var f = Finger(side: side, start: p, current: p, lastTime: time)
        // 反対側の空白兼ポインタに触れている指があれば、両押しの右クリック（今までの両押しと同じ）
        let opposite = fingers.filter { $0.key != id && $0.value.side != side }.map(\.key)
        guard opposite.isEmpty else {
            for k in opposite { fingers[k]?.consumed = true }
            f.consumed = true
            fingers[id] = f
            return [.click(right: true)]
        }
        fingers[id] = f
        return []
    }

    public mutating func touchMoved(_ id: Int, to p: CGPoint, time: TimeInterval) -> [Output] {
        guard var f = fingers[id] else { return [] }
        var out: [Output] = []
        if f.moving {
            let dx = p.x - f.current.x, dy = p.y - f.current.y
            let distance = hypot(dx, dy)
            // 時刻が進んでいないとき（dt が 0）は、前の速さのまま
            let dt = time - f.lastTime
            if dt > 0 { f.speed = distance / CGFloat(dt) }
            f.current = p
            f.lastTime = max(f.lastTime, time)
            if distance > 0 { out.append(Self.move(dx: dx, dy: dy, speed: f.speed)) }
        } else if !f.consumed, hypot(p.x - f.start.x, p.y - f.start.y) > Self.slop {
            if fingers.contains(where: { $0.key != id && $0.value.moving }) {
                // ポインタを動かす指は同時に 1 本。2 本目の動きは捨てる（離しても空白もクリックも出さない）
                f.consumed = true
            } else {
                // 動かし始め。触れた点からここまでの動きを、まとめて動かす
                f.moving = true
                let dx = p.x - f.start.x, dy = p.y - f.start.y
                let dt = time - f.lastTime
                if dt > 0 { f.speed = hypot(dx, dy) / CGFloat(dt) }
                f.current = p
                f.lastTime = max(f.lastTime, time)
                out.append(Self.move(dx: dx, dy: dy, speed: f.speed))
            }
        }
        fingers[id] = f
        return out
    }

    public mutating func touchUp(_ id: Int, at p: CGPoint, time: TimeInterval) -> [Output] {
        // 離した位置までの動きを先に渡す
        var out = touchMoved(id, to: p, time: time)
        guard let f = fingers.removeValue(forKey: id) else { return out }
        if f.moving {
            // ポインタを動かした指。離した時刻から猶予を数える
            graceFrom = time
            return out
        }
        if f.consumed { return out }
        if let from = graceFrom, time - from <= Self.graceTime {
            graceFrom = time
            out.append(.click(right: false))
        } else {
            out.append(.space)
        }
        return out
    }

    /// 触れていた指が取り消された。何も出さず、猶予にも関わらない
    public mutating func touchCancelled(_ id: Int) {
        fingers.removeValue(forKey: id)
    }

    /// ほかのキーを打った（文字・矢印・修飾キーなど）。猶予は終わる
    public mutating func keyTyped() {
        graceFrom = nil
    }

    public mutating func reset() {
        fingers.removeAll()
        graceFrom = nil
    }

    private static func move(dx: CGFloat, dy: CGFloat, speed: CGFloat) -> Output {
        let gain = PointerCurve.gain(speed: speed)
        return .movePointer(dx: dx * gain, dy: dy * gain)
    }
}
