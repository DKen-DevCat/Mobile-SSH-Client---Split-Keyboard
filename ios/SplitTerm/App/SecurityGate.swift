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
    private var cover: UIWindow?
    /// 確かめるまで保留している、守りを弱める変更
    private var pendingAppLock: Bool?
    private var pendingPrivacyBlur: Bool?
    private let defaults = UserDefaults.standard
    private static let appLockKey = "security.appLock"
    private static let privacyBlurKey = "security.privacyBlur"

    init(colors: KeyboardColors) {
        self.colors = colors
        // 初めては守る側（true）から始める
        appLock = defaults.object(forKey: Self.appLockKey) as? Bool ?? true
        privacyBlur = defaults.object(forKey: Self.privacyBlurKey) as? Bool ?? true
        isLocked = appLock
    }

    // MARK: config の値

    /// config の値を受け取る。強める変更はすぐに、弱める変更は本人を確かめてから効かせる
    func request(appLock wantLock: Bool, privacyBlur wantBlur: Bool) {
        if wantLock && !appLock { set(appLock: true) }
        if wantBlur && !privacyBlur { set(privacyBlur: true) }
        pendingAppLock = (!wantLock && appLock) ? false : nil
        pendingPrivacyBlur = (!wantBlur && privacyBlur) ? false : nil
        guard pendingAppLock != nil || pendingPrivacyBlur != nil else { return }
        // ロック中なら、ロックを解いたときにまとめて効かせる（ロックを解くこと自体が本人の確認）
        guard !isLocked, !authenticating else { return }
        authenticate(reason: "設定でロックや画面の保護を外す") { [weak self] ok in
            guard let self else { return }
            if ok {
                self.applyPending()
            } else {
                self.pendingAppLock = nil
                self.pendingPrivacyBlur = nil
                self.onNotice?("ロックや画面の保護を外す変更は、本人の確認ができなかったので効かせていません")
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
        // Face ID の画面でも呼ばれる。そのときは覆いを替えない
        guard !authenticating else { return }
        if privacyBlur || isLocked { showCover(locked: isLocked) }
    }

    func didEnterBackground() {
        if appLock { isLocked = true }
    }

    func didActivate() {
        guard !authenticating else { return }
        if isLocked {
            showCover(locked: true)
            unlock()
        } else {
            hideCover()
            onResume?()
        }
    }

    // MARK: ロックを解く

    func unlock() {
        guard !authenticating else { return }
        authenticate(reason: "ターミナルを開く") { [weak self] ok in
            guard let self else { return }
            guard ok else { return }  // 覆いは残る。覆いをタップでもう一度
            self.isLocked = false
            self.applyPending()
            self.hideCover()
            self.onResume?()
        }
    }

    private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        authenticating = true
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { [weak self] in
                self?.authenticating = false
                completion(ok)
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
