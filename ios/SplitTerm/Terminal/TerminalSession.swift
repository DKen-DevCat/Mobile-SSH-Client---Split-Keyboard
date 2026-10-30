import Foundation
import TermCore
import TermSession

/// 人の判断が要る場面（ホスト鍵の確認・パスワード）を画面に出す役
protocol SessionPresenter: AnyObject {
    func confirmHostKey(host: HostEntry, verdict: HostKeyVerdict) async -> Bool
    func askPassword(host: HostEntry) async -> String?
}

/// 1 つの接続タブ。端末（スクロールバックはメモリの上だけ）と SSH の接続を持ち、切れたら自動で繋ぎ直す
/// （docs/design.md「接続の安定性」: SSH＋tmux＋自動再接続）
final class TerminalSession {
    let host: HostEntry
    let engine: TerminalEngine
    private(set) var state: ConnectionState = .idle { didSet { onStateChange?() } }
    private(set) var title: String
    var onStateChange: (() -> Void)?
    /// 画面が変わった（どのスレッドからも呼ぶ）
    var onDisplayNeeded: (@Sendable () -> Void)? {
        didSet { engine.onDisplayNeeded = onDisplayNeeded }
    }
    weak var presenter: SessionPresenter?

    var config: TermConfig
    private var connection: SSHConnection?
    private var size = PTYSize(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
    private var attempt = 0
    private var retryWork: DispatchWorkItem?
    private let policy = ReconnectPolicy()
    /// 画面に出ているか（裏にいる間は再接続しない。iOS が止めるので）
    var appActive = true

    /// スクロールバックを見ているときの先頭行（通し番号）。nil なら最下部
    var scrollTop: Int?
    var selection: TextSelection?

    init(host: HostEntry, config: TermConfig, cols: Int, rows: Int) {
        self.host = host
        self.config = config
        self.title = host.name
        engine = TerminalEngine(cols: cols, rows: rows, scrollback: config.scrollbackLimit, termName: config.term)
        size.cols = cols
        size.rows = rows
        engine.onTitle = { [weak self] t in
            guard let self else { return }
            // tmux の題名は長いので、接続先の名前を先に
            self.title = t.isEmpty ? self.host.name : "\(self.host.name) · \(t)"
            self.onStateChange?()
        }
    }

    // MARK: 接続

    func connect() {
        retryWork?.cancel()
        connection?.close()
        connection = nil
        state = .connecting(attempt: attempt)
        let perf = Perf.begin(.reconnect)
        let host = self.host
        let config = self.config
        let target = SSHTarget(host: host.address, port: host.port, user: host.user, term: config.term,
                               command: host.startupCommand, keepalive: config.keepalive)
        let key: SSHAuthKey?
        do {
            key = try DeviceKeyStore.loadOrCreate()
        } catch {
            key = nil
            Perf.log.error("鍵を読めません: \(error.localizedDescription, privacy: .public)")
        }
        let allowPassword = config.passwordAuth || host.auth == .password
        let conn = SSHConnection(
            target: target, key: key,
            hostKeyCheck: { [weak self] presented in
                let verdict = HostKeyStore.verdict(for: host.endpointID, presented: presented)
                if verdict == .trusted { return true }
                guard let presenter = await self?.presenter else { return false }
                let ok = await presenter.confirmHostKey(host: host, verdict: verdict)
                if ok, case .unknown = verdict { try? HostKeyStore.save(presented, for: host.endpointID) }
                return ok
            },
            passwordPrompt: allowPassword ? { [weak self] in
                guard let presenter = await self?.presenter else { return nil }
                return await presenter.askPassword(host: host)
            } : nil)
        let engine = self.engine
        conn.onData = { bytes in engine.feed(bytes) }
        engine.onResponse = { [weak conn] bytes in conn?.send(bytes) }
        conn.onClose = { [weak self] reason in
            DispatchQueue.main.async { self?.connectionClosed(reason, conn) }
        }
        connection = conn
        let size = self.size
        Task { @MainActor [weak self] in
            do {
                try await conn.connect(size: size)
                Perf.end(.reconnect, perf)
                guard let self, self.connection === conn else { return }
                self.attempt = 0
                self.state = .connected
                Perf.log.info("接続しました: \(host.name, privacy: .public)")
                // つないでいる間に窓の大きさが変わっていたら知らせる
                if self.size != size { conn.resize(self.size) }
            } catch {
                Perf.end(.reconnect, perf)
                guard let self, self.connection === conn else { return }
                self.connection = nil
                self.handleFailure(error)
            }
        }
    }

    private func handleFailure(_ error: Error) {
        let message = Self.describe(error)
        if case SSHError.hostKeyRejected = error {
            state = .failed(reason: message)
            return
        }
        if message.contains("認証") {
            state = .failed(reason: message)
            return
        }
        scheduleRetry(reason: message)
    }

    private func connectionClosed(_ reason: SSHCloseReason, _ conn: SSHConnection) {
        guard connection === conn else { return }
        connection = nil
        switch reason {
        case .user:
            state = .idle
        case .remoteExit(let status):
            state = .disconnected(reason: "シェルが終わりました（\(status.map(String.init) ?? "-")）", willRetry: false)
        case .failure(let message):
            Perf.log.info("切れました: \(message, privacy: .public)")
            scheduleRetry(reason: message)
        }
    }

    private func scheduleRetry(reason: String) {
        guard config.reconnect else {
            state = .disconnected(reason: reason, willRetry: false)
            return
        }
        state = .disconnected(reason: reason, willRetry: true)
        guard appActive else { return }
        let delay = policy.delay(forAttempt: attempt)
        attempt += 1
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 前面に戻った。切れていればすぐ繋ぎ直す
    func becameActive() {
        appActive = true
        switch state {
        case .disconnected(_, true), .idle:
            attempt = 0
            connect()
        default:
            break
        }
    }

    func resignedActive() {
        appActive = false
        retryWork?.cancel()
    }

    /// 回線が変わった（Wi-Fi ⇄ 5G）。TCP は続かないので、待たずに繋ぎ直す
    func networkChanged() {
        guard appActive else { return }
        if case .connected = state {
            Perf.log.info("回線が変わったので繋ぎ直します")
            attempt = 0
            connect()
        }
    }

    func close() {
        retryWork?.cancel()
        connection?.close()
        connection = nil
        state = .idle
    }

    // MARK: 入出力

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection?.send(bytes)
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        let new = PTYSize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard new != size else { return }
        size = new
        engine.resize(cols: cols, rows: rows)
        connection?.resize(new)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let s = String(describing: error)
        if s.contains("allAuthenticationOptionsFailed") || s.contains("userAuth") { return "認証に失敗しました（鍵が登録されているか確かめてください）" }
        if s.contains("timeout") || s.contains("Timeout") { return "接続できませんでした（時間切れ）" }
        return s
    }
}
