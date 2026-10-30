import LocalAuthentication
import TermCore
import UIKit

/// アプリのロックと画面の保護（docs/design.md「セキュリティ要件」）。
/// - 覆いは最前面の別のウィンドウに出す（アラートや「調べる」の画面より上。キー入力も覆いのウィンドウが受ける）
/// - ロック中は、入力ルータがすべての入力を捨てる（`isLocked`）
/// - config で守りを弱める変更（app-lock・privacy-blur を false に）は、本人の確認（Face ID かパスコード）の後でだけ効かせる。
///   config は「ファイル」アプリから書き換えられるので、ロックを解かずに守りを外せないようにする
final class SecurityGate {
    /// 今効いている値（本人が確かめた値）。config の値とは別に、端末の中に覚えておく
    private(set) var appLock: Bool
    private(set) var privacyBlur: Bool
    /// ロックを解く必要がある
    private(set) var isLocked: Bool

    var colors: KeyboardColors
    /// 覆いを出すシーン
    var scene: () -> UIWindowScene? = { nil }
    /// ロックを解いた、またはロックの無いまま前面に戻った
    var onResume: (() -> Void)?
    /// 利用者に知らせること
    var onNotice: ((String) -> Void)?

    private var authenticating = false
    /// 前面に戻ったら、Face ID を自分から出す（起動時と、裏から戻ったときだけ。やめた後は覆いのタップで）
    private var promptOnActivate: Bool
    /// 確かめている間に前面に戻った（その知らせを、確かめ終わってから扱う）
    private var activationPending = false
    private var cover: UIWindow?
    /// 確かめるまで保留している、守りを弱める変更
    private var pendingAppLock: Bool?
    private var pendingPrivacyBlur: Bool?
    private var toldNoPasscode = false
    private let defaults = UserDefaults.standard
    private static let appLockKey = "security.appLock"
    private static let privacyBlurKey = "security.privacyBlur"

    init(colors: KeyboardColors) {
        self.colors = colors
        // 初めては守る側（true）から始める
        appLock = defaults.object(forKey: Self.appLockKey) as? Bool ?? true
        privacyBlur = defaults.object(forKey: Self.privacyBlurKey) as? Bool ?? true
        isLocked = appLock
        promptOnActivate = appLock
    }

    /// 端末にパスコードが無いと、本人を確かめる手段が無い（ロックすると二度と開けない）
    private var canAuthenticate: Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if !ok, (error as? LAError)?.code == .passcodeNotSet { return false }
        // それ以外の失敗（一時的に使えない など）は、確かめられるものとして扱い、評価で失敗させる
        return true
    }

    private func tellNoPasscode() {
        guard !toldNoPasscode else { return }
        toldNoPasscode = true
        onNotice?("端末にパスコードが無いので、アプリのロックは効きません。設定 > Face ID とパスコード で設定してください")
    }

    // MARK: config の値

    /// config の値を受け取る。強める変更はすぐに、弱める変更は本人を確かめてから効かせる
    func request(appLock wantLock: Bool, privacyBlur wantBlur: Bool) {
        if wantLock && !appLock { set(appLock: true) }
        if wantBlur && !privacyBlur { set(privacyBlur: true) }
        pendingAppLock = (!wantLock && appLock) ? false : nil
        pendingPrivacyBlur = (!wantBlur && privacyBlur) ? false : nil
        // ロック中・確かめている途中なら、ロックを解いた後に、変更の名前を出して別に確かめる
        guard !isLocked, !authenticating else { return }
        confirmPending()
    }

    /// 保留している弱める変更を、何を外すかを示して確かめる
    private func confirmPending() {
        guard pendingAppLock != nil || pendingPrivacyBlur != nil else { return }
        if !canAuthenticate {
            applyPending()
            return
        }
        var what: [String] = []
        if pendingAppLock != nil { what.append("アプリのロック") }
        if pendingPrivacyBlur != nil { what.append("画面の保護（ぼかし）") }
        authenticate(reason: "config の変更で\(what.joined(separator: "と"))を外す") { [weak self] ok in
            guard let self else { return }
            if ok {
                self.applyPending()
            } else {
                self.pendingAppLock = nil
                self.pendingPrivacyBlur = nil
                self.onNotice?("\(what.joined(separator: "と"))を外す config の変更は、本人の確認ができなかったので効かせていません")
            }
        }
    }

    private func applyPending() {
        if let v = pendingAppLock { set(appLock: v) }
        if let v = pendingPrivacyBlur { set(privacyBlur: v) }
        pendingAppLock = nil
        pendingPrivacyBlur = nil
    }

    private func set(appLock v: Bool) {
        appLock = v
        defaults.set(v, forKey: Self.appLockKey)
    }

    private func set(privacyBlur v: Bool) {
        privacyBlur = v
        defaults.set(v, forKey: Self.privacyBlurKey)
    }

    // MARK: 前面・裏

    func willDeactivate() {
        // Face ID の画面でも呼ばれる。そのときは覆いを替えない（裏に回るときは didEnterBackground で覆う）
        guard !authenticating else { return }
        if privacyBlur || isLocked { showCover(locked: isLocked) }
    }

    func didEnterBackground() {
        if appLock && canAuthenticate {
            isLocked = true
            promptOnActivate = true
        }
        // アプリスイッチャーの写しの前に、必ず覆う（Face ID の途中でも）
        if privacyBlur || isLocked { showCover(locked: isLocked) }
    }

    func didActivate() {
        if authenticating {
            // Face ID の画面が閉じたときの知らせか、確かめている間に前面に戻ったか。確かめ終わってから扱う
            activationPending = true
            return
        }
        if isLocked && !canAuthenticate {
            // パスコードが無い端末では、ロックを解く手段が無い。開いて知らせる
            isLocked = false
            tellNoPasscode()
        }
        if isLocked {
            showCover(locked: true)
            if promptOnActivate { unlock() }
        } else {
            hideCover()
            onResume?()
        }
    }

    // MARK: ロックを解く

    /// Face ID かパスコードで解く。やめたら覆いが残り、覆いのタップでもう一度
    func unlock() {
        guard !authenticating else { return }
        promptOnActivate = false
        authenticate(reason: "ターミナルを開く") { [weak self] ok in
            guard let self else { return }
            guard ok else { return }
            self.isLocked = false
            self.hideCover()
            self.onResume?()
            // ロックの間に届いた、守りを弱める変更は、何を外すかを示して別に確かめる
            self.confirmPending()
        }
    }

    private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        authenticating = true
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authenticating = false
                completion(ok)
                // 確かめている間に前面に戻っていたら、ここで扱う（覆いを外し忘れない）
                if self.activationPending && !self.authenticating {
                    self.activationPending = false
                    self.didActivate()
                }
            }
        }
    }

    // MARK: 覆い

    private func showCover(locked: Bool) {
        guard let scene = scene() else { return }
        let w: UIWindow
        if let c = cover {
            w = c
        } else {
            w = UIWindow(windowScene: scene)
            // アラート（.alert）より上
            w.windowLevel = .alert + 1
            cover = w
        }
        w.rootViewController = CoverViewController(locked: locked, colors: colors) { [weak self] in
            self?.unlock()
        }
        w.isHidden = false
        // ハードウェアキーボードの入力を、後ろのターミナルではなく覆いが受けるように
        w.makeKey()
    }

    private func hideCover() {
        guard let c = cover else { return }
        c.isHidden = true
        c.rootViewController = nil
        cover = nil
        scene()?.windows.first { $0.windowLevel == .normal }?.makeKey()
    }
}

/// 覆いの画面。ロック中は鍵の印と、タップでもう一度ロックを解く
private final class CoverViewController: UIViewController {
    let locked: Bool
    let colors: KeyboardColors
    let onTap: () -> Void

    init(locked: Bool, colors: KeyboardColors, onTap: @escaping () -> Void) {
        self.locked = locked
        self.colors = colors
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if locked {
            view.backgroundColor = colors.background
            let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
            icon.tintColor = colors.subText
            icon.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        } else {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            blur.frame = view.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(blur)
        }
    }

    @objc private func tapped() { onTap() }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    // 覆いが受けたキーは捨てる
    override var canBecomeFirstResponder: Bool { true }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
}
