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
    /// 通信の問題（繋ぎ直せば続きから送れる）
    case failed(String)
    /// 接続先がはっきり断った（もう一度試しても同じ。人が直す）
    case refused(String)
    /// 決まった時間、何も進まなかった
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "接続していません"
        case .failed(let s), .refused(let s): return s
        case .timedOut(let t): return "接続先が \(Int(t)) 秒応えませんでした"
        }
    }
}

extension SSHConnection {
    /// コマンドを走らせ、終わるまで待つ。`input` があれば、その範囲を標準入力に流して EOF を送る。
    /// `timeout` は「何も進まない時間」の上限（入力を流している間は、書けるたびに数え直す）。
    /// Task を取り消すと、チャンネルを閉じて止める
    public func exec(_ command: String, input: FileInputRange? = nil, timeout: TimeInterval = 60,
                     progress: (@Sendable (Int) -> Void)? = nil) async throws -> ExecResult {
        guard let root = currentRoot else { throw ExecError.notConnected }
        let done = root.eventLoop.makePromise(of: ExecResult.self)
        let started = root.eventLoop.makePromise(of: Void.self)
        let handler = ExecHandler(command: command, started: started, done: done)
        // チャンネルを開く。接続先が黙っていても、取り消しても、時間で見切る
        // （見切った後に開いたチャンネルでは、コマンドを走らせずに閉じる。ExecHandler.abandon）
        let opened = root.eventLoop.makePromise(of: Channel.self)
        let openTimeout = root.eventLoop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            handler.abandon()
            opened.fail(ExecError.timedOut(timeout))
        }
        root.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .success(let ssh):
                ssh.createChannel(opened, channelType: .session) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelRejected) }
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                        try child.pipeline.syncOperations.addHandler(handler)
                    }
                }
            case .failure(let error):
                opened.fail(error)
            }
        }
        let child: Channel
        do {
            child = try await withTaskCancellationHandler {
                try await opened.futureResult.get()
            } onCancel: {
                root.eventLoop.execute { handler.abandon() }
                opened.fail(CancellationError())
            }
            openTimeout.cancel()
        } catch {
            openTimeout.cancel()
            // チャンネルを開けなかった。待っている約束を片付ける（ExecHandler が付いていれば、外すときにも片付く）
            started.fail(error)
            done.fail(error)
            throw error
        }
        let watchdog = Watchdog(channel: child, seconds: timeout)
        watchdog.arm()
        return try await withTaskCancellationHandler {
            defer { watchdog.cancel() }
            do {
                try await started.futureResult.get()
                if let input {
                    try await stream(input, to: child, watchdog: watchdog, progress: progress)
                }
                // 標準入力の終わり（EOF）。接続先の cat が終わる。
                // すぐ終わるコマンドでは、接続先が先にチャンネルを閉じていることがある（その失敗は気にしない）
                let eof: EventLoopFuture<Void> = child.close(mode: .output)
                try? await eof.get()
            } catch {
                child.close(promise: nil)
                if watchdog.fired { throw ExecError.timedOut(timeout) }
                throw error
            }
            let result = try await done.futureResult.get()
            if watchdog.fired { throw ExecError.timedOut(timeout) }
            if Task.isCancelled { throw CancellationError() }
            return result
        } onCancel: {
            child.close(promise: nil)
        }
    }

    /// ファイルの範囲を 256KB ずつ送る。1 つ書き終わるのを待ってから次を読む（メモリに溜めない。SSH の窓が流れを決める）
    private func stream(_ input: FileInputRange, to child: Channel, watchdog: Watchdog,
                        progress: (@Sendable (Int) -> Void)?) async throws {
        let handle = try FileHandle(forReadingFrom: input.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(input.offset))
        var sent = 0
        while true {
            try Task.checkCancellation()
            // 数 GB を読み続けても、読み取りの一時のメモリを溜めない
            let data = try autoreleasepool { try handle.read(upToCount: 256 * 1024) } ?? Data()
            if data.isEmpty { break }
            var buf = child.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let written: EventLoopFuture<Void> = child.writeAndFlush(buf)
            try await written.get()
            watchdog.arm()
            sent += data.count
            progress?(sent)
        }
    }
}

/// 決まった時間、何も進まなければチャンネルを閉じる
final class Watchdog: @unchecked Sendable {
    private let channel: Channel
    private let seconds: TimeInterval
    private let lock = NSLock()
    private var scheduled: Scheduled<Void>?
    private var didFire = false

    init(channel: Channel, seconds: TimeInterval) {
        self.channel = channel
        self.seconds = seconds
    }

    var fired: Bool { lock.withLock { didFire } }

    /// 数え直す
    func arm() {
        let next = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.didFire = true }
            self.channel.close(promise: nil)
        }
        let previous = lock.withLock { () -> Scheduled<Void>? in
            let p = scheduled
            scheduled = next
            return p
        }
        previous?.cancel()
    }

    func cancel() {
        lock.withLock { scheduled }?.cancel()
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

    /// 待つのをやめた（時間切れ・取り消し）。この後に開いても、コマンドは走らせない。イベントループの上で呼ぶ
    private var abandoned = false
    func abandon() {
        abandoned = true
    }

    func channelActive(context: ChannelHandlerContext) {
        guard !abandoned else {
            context.close(promise: nil)
            return
        }
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

    /// 送って、接続先の絶対パスを返す。`sha256` は `digest(of:)` で 1 度だけ計ったもの。`progress` は 0〜1
    public static func upload(_ file: URL, as name: String, sha256 digest: String, to target: Target,
                              over conn: SSHConnection, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let dir = target.mediaDir
        for attempt in 0..<2 {
            let prep = try await conn.exec(try RemoteCommands.prepare(mediaDir: dir, name: name,
                                                                       retentionDays: target.retentionDays), timeout: 120)
            try refuseIfRemoteSaidNo(prep, mediaDir: dir)
            guard prep.status == 0, let p = RemoteCommands.parsePrepare(prep.stdout) else {
                throw ExecError.failed("受け取り箱を用意できませんでした（\(dir)）")
            }
            var offset = p.offset
            if offset > size {
                let r = try await conn.exec(try RemoteCommands.discard(mediaDir: dir, name: name))
                try refuseIfRemoteSaidNo(r, mediaDir: dir)
                offset = 0
            }
            if offset < size {
                let base = offset
                let r = try await conn.exec(try RemoteCommands.append(mediaDir: dir, name: name),
                                            input: FileInputRange(url: file, offset: offset)) { sent in
                    progress?(size > 0 ? Double(base + sent) / Double(size) : 1)
                }
                try refuseIfRemoteSaidNo(r, mediaDir: dir)
                guard r.status == 0 else { throw ExecError.failed("送れませんでした（\(r.stdout)）") }
            }
            // 数 GB でも接続先で計り終えるまで待つ
            let fin = try await conn.exec(try RemoteCommands.finish(mediaDir: dir, name: name, sha256: digest), timeout: 900)
            if RemoteCommands.finished(status: fin.status, stdout: fin.stdout) {
                progress?(1)
                return p.directory + "/" + name
            }
            // 中身が合わない（途中までの残りが別物だった など）。.part は消えているので、もう 1 度だけ最初から
            if fin.status == RemoteCommands.Exit.mismatch {
                if attempt == 0 { continue }
                throw ExecError.refused("送ったファイルの中身が 2 度とも合いませんでした")
            }
            try refuseIfRemoteSaidNo(fin, mediaDir: dir)
            throw ExecError.failed("送り終わりを確かめられませんでした")
        }
        throw ExecError.refused("送ったファイルの中身が合いませんでした")
    }

    /// 接続先のコマンドが決まった終了コードで断ったら、繋ぎ直しても同じなので、そのことを知らせる
    static func refuseIfRemoteSaidNo(_ r: ExecResult, mediaDir: String) throws {
        switch r.status {
        case .some(RemoteCommands.Exit.noDirectory):
            throw ExecError.refused("受け取り箱 \(mediaDir) を作れないか、入れません")
        case .some(RemoteCommands.Exit.notOwner):
            throw ExecError.refused("受け取り箱 \(mediaDir) は自分の持ち物ではないので使いません")
        case .some(RemoteCommands.Exit.noHashTool):
            throw ExecError.refused("接続先に SHA-256 を計る道具（shasum・sha256sum・sha256・openssl）がありません")
        case .some(RemoteCommands.Exit.moveFailed):
            throw ExecError.refused("受け取り箱で名前を付け替えられませんでした")
        default:
            return
        }
    }

    /// ファイルの SHA-256（16 進の小文字）。裏で 1MB ずつ読む
    public static func digest(of file: URL) async throws -> String {
        try sha256(of: file)
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try h.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
