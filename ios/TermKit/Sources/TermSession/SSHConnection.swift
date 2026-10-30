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
    /// 人の判断が要る失敗（ホスト鍵を受け入れなかった・認証に失敗した）。自動で再接続しない
    case rejected(String)
}

public enum SSHError: LocalizedError {
    case hostKeyRejected
    case authenticationFailed
    case channelRejected
    case timedOut
    case cancelled
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected: return "ホスト鍵を受け入れませんでした"
        case .authenticationFailed: return "認証に失敗しました（公開鍵が接続先に登録されているか確かめてください）"
        case .channelRejected: return "接続先が端末を開きませんでした"
        case .timedOut: return "接続できませんでした（時間切れ）"
        case .cancelled: return "接続をやめました"
        case .notConnected: return "接続していません"
        }
    }

    /// 繋ぎ直しても同じ結果になる失敗（人の判断が要る）
    public var needsHuman: Bool {
        switch self {
        case .hostKeyRejected, .authenticationFailed: return true
        default: return false
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

    /// 受信。NIO のスレッドから呼ぶ。connect の前に 1 度だけ設定する（切れた後は外す）
    public var onData: (@Sendable ([UInt8]) -> Void)?
    /// 切れた。1 回だけ、NIO のスレッドから呼ぶ。connect の前に 1 度だけ設定する
    public var onClose: (@Sendable (SSHCloseReason) -> Void)?

    private let lock = NSLock()
    private var root: Channel?
    private var session: Channel?
    private var closedByUser = false
    private var exitStatus: Int?
    private var exited = false
    private var reported = false
    /// 最初に起きたエラー（ホスト鍵の拒否・認証の失敗を、後に続く EOF などで上書きしない）
    private var firstError: Error?
    /// 人に聞いている間（ホスト鍵の確認・パスワード）は、握手の時間切れを数えない
    private var waitingForHuman = 0
    /// 握手（TCP・鍵交換・認証・PTY）の時間切れ。人に聞いている時間は含めない
    static let handshakeTimeout: TimeInterval = 20

    public init(target: SSHTarget, key: SSHAuthKey?, hostKeyCheck: @escaping HostKeyCheck,
                passwordPrompt: PasswordPrompt?) {
        self.target = target
        self.key = key
        self.hostKeyCheck = hostKeyCheck
        self.passwordPrompt = passwordPrompt
    }

    /// つないで、端末を開くまで待つ
    public func connect(size: PTYSize) async throws {
        // 人に聞いている間（ホスト鍵の確認・パスワード）は、握手の時間切れを止める
        let hostKeyCheck = self.hostKeyCheck
        let passwordPrompt = self.passwordPrompt
        let userAuth = UserAuthDelegate(
            user: target.user, key: key?.nio,
            passwordPrompt: passwordPrompt.map { prompt -> PasswordPrompt in
                { [weak self] in
                    self?.humanBegan()
                    defer { self?.humanEnded() }
                    return await prompt()
                }
            })
        let serverAuth = HostKeyDelegate(check: { [weak self] presented in
            self?.humanBegan()
            defer { self?.humanEnded() }
            return await hostKeyCheck(presented)
        })

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        if target.keepalive > 0 {
            // config の値は読むときに上限で切っているが、ここでも整数に収める
            let interval = Int(min(max(target.keepalive, 1), 3600))
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = interval
            tcp.keepaliveInterval = interval
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
                    try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler { [weak self] error in
                        self?.record(error)
                    })
                }
            }

        let root = try await bootstrap.connect(host: target.host, port: target.port).get()
        let cancelled: Bool = lock.withLock {
            self.root = root
            return closedByUser
        }
        // つないでいる間にタブを閉じた。ここで止める（止めないと、閉じたタブの tmux のクライアントが残る）
        if cancelled {
            lock.withLock { reported = true }
            root.close(promise: nil)
            clearCallbacks()
            throw SSHError.cancelled
        }
        root.closeFuture.whenComplete { [weak self] _ in self?.reportClose() }
        scheduleHandshakeTimeout(root, after: Self.handshakeTimeout)

        let ready = root.eventLoop.makePromise(of: Void.self)
        let handler = SessionHandler(
            target: target, size: size, ready: ready,
            onData: { [weak self] bytes in
                guard let self else { return }
                let cb = self.lock.withLock { self.onData }
                cb?(bytes)
            },
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
            let stop: Bool = lock.withLock {
                handshakeDone = true
                return closedByUser
            }
            if stop {
                lock.withLock { reported = true }
                root.close(promise: nil)
                throw SSHError.cancelled
            }
        } catch {
            // 後に続く EOF などではなく、最初の原因（ホスト鍵の拒否・認証の失敗）を返す
            let cause: Error = lock.withLock {
                reported = true
                return closedByUser ? SSHError.cancelled : (firstError ?? error)
            }
            root.close(promise: nil)
            clearCallbacks()
            throw cause
        }
    }

    private var handshakeDone = false
    /// 時間切れの見張りの世代。人に聞き終わるたびに新しい 20 秒を始め、古い見張りは何もしない
    private var deadlineGeneration = 0

    private func humanBegan() { lock.withLock { waitingForHuman += 1 } }

    /// 人に聞き終わった。残りの握手に、改めて 20 秒を与える（聞いていた時間を数えない）
    private func humanEnded() {
        let root: Channel? = lock.withLock {
            waitingForHuman -= 1
            return waitingForHuman == 0 ? self.root : nil
        }
        if let root { scheduleHandshakeTimeout(root, after: Self.handshakeTimeout) }
    }

    private func record(_ error: Error) {
        lock.withLock { if firstError == nil { firstError = error } }
    }

    /// 握手が終わらなければ閉じる。人に聞いている間は数えない（聞き終わったら humanEnded が新しく始める）
    private func scheduleHandshakeTimeout(_ root: Channel, after seconds: TimeInterval) {
        let generation: Int = lock.withLock {
            deadlineGeneration += 1
            return deadlineGeneration
        }
        root.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) { [weak self] in
            guard let self else { return }
            let expired: Bool = self.lock.withLock {
                guard generation == self.deadlineGeneration, !self.handshakeDone, !self.reported,
                      self.waitingForHuman == 0 else { return false }
                if self.firstError == nil { self.firstError = SSHError.timedOut }
                return true
            }
            if expired { root.close(promise: nil) }
        }
    }

    private func clearCallbacks() {
        lock.withLock {
            onData = nil
            onClose = nil
        }
    }

    /// 受信を止める・再開する（解析が追いつかないときに、接続先からの送信を待たせる）
    public func setReading(_ on: Bool) {
        guard let s = lock.withLock({ session }) else { return }
        s.setOption(ChannelOptions.autoRead, value: on).whenComplete { _ in
            if on { s.read() }
        }
    }

    /// 端末を開き終えた接続の根のチャンネル（別のチャンネルでコマンドを走らせるのに使う）
    var currentRoot: Channel? {
        lock.withLock { handshakeDone && !reported ? root : nil }
    }

    /// 端末を開き終えて、まだ切れていないか
    public var isOpen: Bool { currentRoot?.isActive ?? false }

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

    private func reportClose() {
        let (reason, callback): (SSHCloseReason?, (@Sendable (SSHCloseReason) -> Void)?) = lock.withLock {
            guard !reported else { return (nil, nil) }
            reported = true
            let cb = onClose
            if closedByUser { return (.user, cb) }
            if exited { return (.remoteExit(status: exitStatus), cb) }
            if let e = firstError as? SSHError, e.needsHuman { return (.rejected(e.localizedDescription), cb) }
            return (.failure(firstError?.localizedDescription ?? "接続が切れました"), cb)
        }
        if let reason { callback?(reason) }
        clearCallbacks()
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
                    nextChallengePromise.fail(SSHError.authenticationFailed)
                }
            }
            return
        }
        // 試せるものが尽きた。nil を返すと swift-nio-ssh は何もせず、接続先の時間切れまで待たされるので、失敗にする
        nextChallengePromise.fail(SSHError.authenticationFailed)
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

/// パイプラインのエラーを記録して閉じる（最初の原因を接続に残す）
final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
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
