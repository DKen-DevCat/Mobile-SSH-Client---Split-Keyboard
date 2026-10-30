import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import TermCore

/// 同じ SSH の接続で、端末とは別のチャンネルにコマンドを走らせる（メディアの送信。docs/design.md「メディアを送る」）。
/// 端末（PTY）は開かない。標準入力にファイルの中身を流せる
public struct ExecResult: Sendable {
    public var status: Int?
    public var stdout: String
}

public enum ExecError: LocalizedError {
    case notConnected
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "接続していません"
        case .failed(let s): return s
        }
    }
}

extension SSHConnection {
    /// コマンドを走らせ、終わるまで待つ。`input` があれば、その範囲を標準入力に流して EOF を送る
    public func exec(_ command: String, input: FileInputRange? = nil,
                     progress: (@Sendable (Int) -> Void)? = nil) async throws -> ExecResult {
        guard let root = currentRoot else { throw ExecError.notConnected }
        let done = root.eventLoop.makePromise(of: ExecResult.self)
        let started = root.eventLoop.makePromise(of: Void.self)
        let handler = ExecHandler(command: command, started: started, done: done)
        let child = try await root.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
            let p = root.eventLoop.makePromise(of: Channel.self)
            ssh.createChannel(p, channelType: .session) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelRejected) }
                return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            return p.futureResult
        }.get()
        do {
            try await started.futureResult.get()
            if let input {
                try await stream(input, to: child, progress: progress)
            }
            // 標準入力の終わり（EOF）。接続先の cat が終わる
            let eof: EventLoopFuture<Void> = child.close(mode: .output)
            try await eof.get()
        } catch {
            child.close(promise: nil)
            throw error
        }
        return try await done.futureResult.get()
    }

    /// ファイルの範囲を 256KB ずつ送る。1 つ書き終わるのを待ってから次を読む（メモリに溜めない。SSH の窓が流れを決める）
    private func stream(_ input: FileInputRange, to child: Channel, progress: (@Sendable (Int) -> Void)?) async throws {
        let handle = try FileHandle(forReadingFrom: input.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(input.offset))
        var sent = 0
        while true {
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            var buf = child.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let written: EventLoopFuture<Void> = child.writeAndFlush(buf)
            try await written.get()
            sent += data.count
            progress?(sent)
        }
    }
}

/// 標準入力に流すファイルの範囲（続きから送るときは offset から）
public struct FileInputRange: Sendable {
    public var url: URL
    public var offset: Int
    public init(url: URL, offset: Int) {
        self.url = url
        self.offset = offset
    }
}

/// exec の要求を送り、標準出力（64KB まで）と終了コードを集める
final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let command: String
    var started: EventLoopPromise<Void>?
    var done: EventLoopPromise<ExecResult>?
    var stdout = ByteBuffer()
    var status: Int?
    static let maxOutput = 64 * 1024

    init(command: String, started: EventLoopPromise<Void>, done: EventLoopPromise<ExecResult>) {
        self.command = command
        self.started = started
        self.done = done
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            started?.succeed(())
            started = nil
        case is ChannelFailureEvent:
            started?.fail(ExecError.failed("接続先がコマンドを受け付けませんでした"))
            started = nil
            context.close(promise: nil)
        case let s as SSHChannelRequestEvent.ExitStatus:
            status = s.exitStatus
        case let e as ChannelEvent where e == .inputClosed:
            // 接続先の出力の終わり。閉じるのは接続先に任せる
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = message.data, message.type == .channel else { return }
        let room = Self.maxOutput - stdout.readableBytes
        if room > 0 { stdout.writeBuffer(&buf) }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        started?.fail(ExecError.failed("コマンドを始める前に切れました"))
        started = nil
        let text = stdout.readString(length: stdout.readableBytes) ?? ""
        done?.succeed(ExecResult(status: status, stdout: text))
        done = nil
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        started?.fail(ExecError.failed("切れました"))
        started = nil
        done?.fail(ExecError.failed("切れました"))
        done = nil
    }
}

/// ファイルを受け取り箱へ送る。切れても続きから送り、最後に SHA-256 を比べる
public enum MediaUploader {
    public struct Target: Sendable {
        public var mediaDir: String
        public var retentionDays: Int
        public init(mediaDir: String, retentionDays: Int) {
            self.mediaDir = mediaDir
            self.retentionDays = retentionDays
        }
    }

    /// 送って、接続先の絶対パスを返す。`progress` は 0〜1
    public static func upload(_ file: URL, as name: String, to target: Target, over conn: SSHConnection,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let digest = try sha256(of: file)
        for attempt in 0..<2 {
            let prep = try await conn.exec(try RemoteCommands.prepare(mediaDir: target.mediaDir, name: name,
                                                                       retentionDays: target.retentionDays))
            guard prep.status == 0, let p = RemoteCommands.parsePrepare(prep.stdout) else {
                throw ExecError.failed("受け取り箱を用意できませんでした（\(target.mediaDir)）")
            }
            var offset = p.offset
            if offset > size {
                _ = try await conn.exec(try RemoteCommands.discard(mediaDir: target.mediaDir, name: name))
                offset = 0
            }
            if offset < size {
                let base = offset
                let r = try await conn.exec(try RemoteCommands.append(mediaDir: target.mediaDir, name: name),
                                            input: FileInputRange(url: file, offset: offset)) { sent in
                    progress?(size > 0 ? Double(base + sent) / Double(size) : 1)
                }
                guard r.status == 0 else { throw ExecError.failed("送れませんでした（\(r.stdout)）") }
            }
            let fin = try await conn.exec(try RemoteCommands.finish(mediaDir: target.mediaDir, name: name, sha256: digest))
            if fin.stdout.contains("ok") {
                progress?(1)
                return p.directory + "/" + name
            }
            // 中身が合わない（途中までの残りが別物だった など）。.part は消えているので、もう 1 度だけ最初から
            if attempt == 1 { break }
        }
        throw ExecError.failed("送ったファイルの中身が合いませんでした")
    }

    /// ファイルの SHA-256（16 進の小文字）。1MB ずつ読む
    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
