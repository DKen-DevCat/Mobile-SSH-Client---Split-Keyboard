import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices
import TermCore

/// 接続先と、接続のしかた
public struct SSHTarget: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var term: String
    /// nil なら shell を要求する
    public var command: String?
    /// TCP の keepalive の間隔（秒）。0 で使わない
    public var keepalive: TimeInterval

    public init(host: String, port: Int, user: String, term: String, command: String?, keepalive: TimeInterval) {
        self.host = host
        self.port = port
        self.user = user
        self.term = term
        self.command = command
        self.keepalive = keepalive
    }
}

public struct PTYSize: Equatable, Sendable {
    public var cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int
    public init(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        self.cols = cols
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum SSHCloseReason: Sendable {
    /// こちらから閉じた
    case user
    /// 接続先のシェル（tmux）が終わった（exit・tmux の detach）。自動で再接続しない
    case remoteExit(status: Int?)
    /// 通信の失敗（回線の切り替え・バックグラウンドで止められた など）。自動で再接続する
    case failure(String)
}

public enum SSHError: LocalizedError {
    case hostKeyRejected
    case channelRejected
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected: return "ホスト鍵を受け入れませんでした"
        case .channelRejected: return "接続先が端末を開きませんでした"
        case .notConnected: return "接続していません"
        }
    }
}

/// SSH の 1 本の接続（swift-nio-ssh を Network.framework の上で動かす）。
/// 端末（PTY）を 1 つ開き、tmux を起動する（docs/design.md「接続の安定性」）
public final class SSHConnection: @unchecked Sendable {
    public typealias HostKeyCheck = @Sendable (_ openSSHKey: String) async -> Bool
    public typealias PasswordPrompt = @Sendable () async -> String?

    /// 1 本のスレッドで足りる（暗号の処理は小さい）。入力を最優先にする
    static let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .userInteractive)

    let target: SSHTarget
    let key: SSHAuthKey?
    let hostKeyCheck: HostKeyCheck
    let passwordPrompt: PasswordPrompt?

    /// 受信。NIO のスレッドから呼ぶ
    public var onData: (@Sendable ([UInt8]) -> Void)?
    /// 切れた。1 回だけ、NIO のスレッドから呼ぶ
    public var onClose: (@Sendable (SSHCloseReason) -> Void)?

    private let lock = NSLock()
    private var root: Channel?
    private var session: Channel?
    private var closedByUser = false
    private var exitStatus: Int?
    private var exited = false
    private var reported = false

    public init(target: SSHTarget, key: SSHAuthKey?, hostKeyCheck: @escaping HostKeyCheck,
                passwordPrompt: PasswordPrompt?) {
        self.target = target
        self.key = key
        self.hostKeyCheck = hostKeyCheck
        self.passwordPrompt = passwordPrompt
    }

    /// つないで、端末を開くまで待つ
    public func connect(size: PTYSize) async throws {
        let userAuth = UserAuthDelegate(user: target.user, key: key?.nio, passwordPrompt: passwordPrompt)
        let serverAuth = HostKeyDelegate(check: hostKeyCheck)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        if target.keepalive > 0 {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = max(1, Int(target.keepalive))
            tcp.keepaliveInterval = max(1, Int(target.keepalive))
            tcp.keepaliveCount = 3
        }

        let bootstrap = NIOTSConnectionBootstrap(group: Self.group)
            .connectTimeout(.seconds(10))
            .tcpOptions(tcp)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
                }
            }

        let root = try await bootstrap.connect(host: target.host, port: target.port).get()
        lock.withLock { self.root = root }
        root.closeFuture.whenComplete { [weak self] _ in self?.reportClose(nil) }

        let ready = root.eventLoop.makePromise(of: Void.self)
        let handler = SessionHandler(
            target: target, size: size, ready: ready,
            onData: { [weak self] bytes in self?.onData?(bytes) },
            onExit: { [weak self] status in
                guard let self else { return }
                self.lock.withLock {
                    self.exited = true
                    self.exitStatus = status
                }
            })

        do {
            let session = try await root.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
                let p = root.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(p, channelType: .session) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelRejected) }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(handler)
                    }
                }
                return p.futureResult
            }.get()
            lock.withLock { self.session = session }
            // シェル（tmux）が終わったら、接続ごと閉じる。終わり方（exit か通信の失敗か）は exit-status の有無で見分ける
            session.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.root }?.close(promise: nil)
            }
            try await ready.futureResult.get()
        } catch {
            lock.withLock { reported = true }
            root.close(promise: nil)
            throw error
        }
    }

    /// 送信。どのスレッドからでもよい
    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let s = lock.withLock({ session }) else { return }
        var buf = s.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        s.writeAndFlush(buf, promise: nil)
    }

    /// 接続先へ窓の大きさの変更を知らせる（SSH の window-change）
    public func resize(_ size: PTYSize) {
        guard let s = lock.withLock({ session }) else { return }
        let req = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth, terminalPixelHeight: size.pixelHeight)
        s.triggerUserOutboundEvent(req, promise: nil)
    }

    public func close() {
        let r: Channel? = lock.withLock {
            closedByUser = true
            return root
        }
        r?.close(promise: nil)
    }

    private func reportClose(_ error: Error?) {
        let reason: SSHCloseReason? = lock.withLock {
            guard !reported else { return nil }
            reported = true
            if closedByUser { return .user }
            if exited { return .remoteExit(status: exitStatus) }
            return .failure(error?.localizedDescription ?? "接続が切れました")
        }
        if let reason { onClose?(reason) }
    }
}

/// 鍵 → パスワードの順に試す。パスワードは設定で許したときだけ、聞いて使う（保存しない）
final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let user: String
    let key: NIOSSHPrivateKey?
    let passwordPrompt: SSHConnection.PasswordPrompt?
    var triedKey = false
    var passwordTries = 0

    init(user: String, key: NIOSSHPrivateKey?, passwordPrompt: SSHConnection.PasswordPrompt?) {
        self.user = user
        self.key = key
        self.passwordPrompt = passwordPrompt
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if let key, !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
            return
        }
        if let prompt = passwordPrompt, passwordTries < 3, availableMethods.contains(.password) {
            passwordTries += 1
            let user = self.user
            Task {
                if let pw = await prompt() {
                    nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .password(.init(password: pw))))
                } else {
                    nextChallengePromise.succeed(nil)
                }
            }
            return
        }
        // 試せるものが尽きた。接続は認証の失敗で終わる
        nextChallengePromise.succeed(nil)
    }
}

/// ホスト鍵の照合は呼び出し側（キーチェーンと画面）に任せる
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let check: SSHConnection.HostKeyCheck

    init(check: @escaping SSHConnection.HostKeyCheck) {
        self.check = check
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let check = self.check
        Task {
            if await check(presented) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyRejected)
            }
        }
    }
}

final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// 端末（PTY）を開いてコマンドかシェルを起動し、データを受け渡す
final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let target: SSHTarget
    let size: PTYSize
    var ready: EventLoopPromise<Void>?
    let onData: ([UInt8]) -> Void
    /// 接続先がシェルの終了コード（exit-status）を送ってきた
    let onExit: (Int) -> Void
    /// 返事を待っている要求の数（PTY と、コマンドかシェル）
    var pendingReplies = 0

    init(target: SSHTarget, size: PTYSize, ready: EventLoopPromise<Void>,
         onData: @escaping ([UInt8]) -> Void, onExit: @escaping (Int) -> Void) {
        self.target = target
        self.size = size
        self.ready = ready
        self.onData = onData
        self.onExit = onExit
    }

    func channelActive(context: ChannelHandlerContext) {
        // 日本語を通すため UTF-8 のロケールを頼む（接続先の sshd が AcceptEnv で許していれば効く）
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            promise: nil)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: target.term,
            terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth, terminalPixelHeight: size.pixelHeight,
            terminalModes: SSHTerminalModes([:]))
        pendingReplies = 2
        context.triggerUserOutboundEvent(pty, promise: nil)
        if let command = target.command {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                                             promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies -= 1
            if pendingReplies == 0 {
                ready?.succeed(())
                ready = nil
            }
        case is ChannelFailureEvent:
            ready?.fail(SSHError.channelRejected)
            ready = nil
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            onExit(status.exitStatus)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = message.data else { return }
        switch message.type {
        case .channel, .stdErr:
            onData(Array(buf.readableBytesView))
        default:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready?.fail(SSHError.channelRejected)
        ready = nil
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        ready?.fail(SSHError.channelRejected)
        ready = nil
    }
}
