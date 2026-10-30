import CryptoKit
import Foundation

/// ホスト鍵の指紋（OpenSSH の `ssh-keygen -lf` と同じ `SHA256:` 形式）
public enum HostKeyFingerprint {
    /// `ssh-ed25519 AAAA...` の形の公開鍵から。読めなければ nil
    public static func sha256(openSSHPublicKey: String) -> String? {
        let parts = openSSHPublicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = SHA256.hash(data: blob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }
}

/// ホスト鍵の照合の結果（docs/design.md「セキュリティ要件」: 初回は指紋を確かめて保存、変わっていたら止める）
public enum HostKeyVerdict: Equatable, Sendable {
    case trusted
    /// 初めての接続先。指紋を見せて確かめてもらう
    case unknown(fingerprint: String)
    /// 保存した鍵と違う。接続を止めて警告する
    case changed(expected: String, actual: String)

    public static func judge(stored: String?, presented: String) -> HostKeyVerdict {
        let fp = HostKeyFingerprint.sha256(openSSHPublicKey: presented) ?? "?"
        guard let stored else { return .unknown(fingerprint: fp) }
        if stored == presented { return .trusted }
        return .changed(expected: HostKeyFingerprint.sha256(openSSHPublicKey: stored) ?? "?", actual: fp)
    }
}

/// 自動の再接続の間隔（docs/design.md「接続の安定性」）。最初はすぐ、続けて失敗したら延ばす
public struct ReconnectPolicy: Sendable, Equatable {
    public var delays: [TimeInterval] = [0, 0.5, 1, 2, 4, 8]
    public var cap: TimeInterval = 15

    public init() {}

    /// `attempt` 回目（0 始まり）の再接続を始めるまでの秒数
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        attempt < delays.count ? delays[attempt] : cap
    }
}

/// 接続の状態。環境バーのタブに出す
public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    /// 切れた。`willRetry` なら自動で再接続する
    case disconnected(reason: String, willRetry: Bool)
    /// 人の判断が要る（ホスト鍵の違い・認証の失敗など）。自動で再接続しない
    case failed(reason: String)
}
