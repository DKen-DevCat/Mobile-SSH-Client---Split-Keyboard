import os

/// 性能目標の計測ポイント（docs/design.md「設計原則と性能目標」）。Instruments の Points of Interest で見る。
/// 端末の中だけに記録し、外へは送らない
enum Perf {
    enum Interval: String {
        /// キーを離してから、送信を NIO に渡すまで（目標 16ms 以内）
        case keyToSend
        /// 受信してから、描画を頼むまで
        case receive
        /// 1 フレームを組んで GPU に渡すまで
        case frame
        /// 復帰を検知してから、端末が開くまで（目標 1 秒以内、ネットワーク往復を除く）
        case reconnect
    }

    static let signposter = OSSignposter(subsystem: "io.github.dken-devcat.splitterm", category: .pointsOfInterest)
    static let log = Logger(subsystem: "io.github.dken-devcat.splitterm", category: "session")

    static func begin(_ i: Interval) -> OSSignpostIntervalState {
        signposter.beginInterval("interval", id: signposter.makeSignpostID(), "\(i.rawValue, privacy: .public)")
    }

    static func end(_ i: Interval, _ state: OSSignpostIntervalState) {
        signposter.endInterval("interval", state)
    }
}
