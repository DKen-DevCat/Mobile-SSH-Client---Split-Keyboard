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
    private var connection: SSHConnection? {
        didSet { connectionBox.set(connection) }
    }
    /// 解析のキューから今の接続へ応答を送るための箱（接続を差し替えるたびに engine の閉包を書き換えない）
    private let connectionBox = ConnectionBox()
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
        let box = connectionBox
        engine.onResponse = { bytes in box.get()?.send(bytes) }
        engine.onBacklog = { pause in box.get()?.setReading(!pause) }
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
        let key: SSHAuthKey
        do {
            key = try DeviceKeyStore.loadOrCreate()
        } catch {
            // 鍵が読めないのに繋ぐと「認証に失敗」に見えて原因が隠れる。原因を出して止める（タブのタップで繋ぎ直す）
            Perf.log.error("鍵を読めません: \(error.localizedDescription, privacy: .public)")
            Perf.end(.reconnect, perf)
            state = .failed(reason: "端末の鍵を読めません（\(error.localizedDescription)）。ロックを解いてから、タブをタップして繋ぎ直してください")
            return
        }
        let allowPassword = config.passwordAuth || host.auth == .password
        // 閉包の型を先に決める（async の閉包を三項演算子に入れると、型を推し量れない）
        let hostKeyCheck: SSHConnection.HostKeyCheck = { [weak self] presented in
            let stored: String?
            do {
                stored = try HostKeyStore.load(for: host.endpointID)
            } catch {
                // 読めないのを「鍵が変わった」と取り違えない。繋がずに止める
                return false
            }
            let verdict = HostKeyVerdict.judge(stored: stored, presented: presented)
            if verdict == .trusted { return true }
            guard let presenter = await self?.presenter else { return false }
            let ok = await presenter.confirmHostKey(host: host, verdict: verdict)
            guard ok, case .unknown = verdict else { return false }
            // 確かめている間に、別の接続が鍵を保存したかもしれない。まだ無いときだけ保存し、あれば照合し直す
            if let now = try? HostKeyStore.load(for: host.endpointID) { return now == presented }
            do {
                try HostKeyStore.save(presented, for: host.endpointID)
                return true
            } catch {
                return false
            }
        }
        var passwordPrompt: SSHConnection.PasswordPrompt?
        if allowPassword {
            passwordPrompt = { [weak self] in
                guard let presenter = await self?.presenter else { return nil }
                return await presenter.askPassword(host: host)
            }
        }
        let conn = SSHConnection(target: target, key: key, hostKeyCheck: hostKeyCheck, passwordPrompt: passwordPrompt)
        let engine = self.engine
        conn.onData = { bytes in engine.feed(bytes) }
        // conn を強く持たない（持つと onClose → conn の循環で、接続ごとに NIO のチャンネルが残る）
        conn.onClose = { [weak self, weak conn] (reason: SSHCloseReason) in
            DispatchQueue.main.async { [weak self, weak conn] in
                guard let conn else { return }
                self?.connectionClosed(reason, conn)
            }
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
                // 前の接続で解析待ちが溜まって受信を止めていたら、新しい接続も止めておく（解析が追いつけば再開する）
                if self.engine.isBacklogged { conn.setReading(false) }
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
        if let e = error as? SSHError {
            if e.needsHuman {
                // ホスト鍵の拒否・認証の失敗は、繋ぎ直しても同じ。人が直すまで止める（タブのタップで繋ぎ直す）
                state = .failed(reason: message)
                return
            }
            if case .cancelled = e {
                state = .idle
                return
            }
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
        case .rejected(let message):
            state = .failed(reason: message)
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

    /// メディアを送るのに使う接続（端末を開いて繋がっているときだけ）
    var uploadConnection: SSHConnection? {
        guard isConnected, let c = connection, c.isOpen else { return nil }
        return c
    }

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
        if s.contains("timeout") || s.contains("Timeout") { return "接続できませんでした（時間切れ）" }
        return s
    }
}

/// 今の接続を、どのスレッドからでも読めるように持つ
final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: SSHConnection?

    func set(_ c: SSHConnection?) { lock.withLock { value = c } }
    func get() -> SSHConnection? { lock.withLock { value } }
}
