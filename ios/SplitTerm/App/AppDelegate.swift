import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 前の起動で送りかけたメディアの写しを消す（送る途中で止められたもの）
        MediaPicker.cleanWorkDir()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

extension UIInterfaceOrientationMask {
    /// アプリの向き（横持ちと縦持ち。docs/design.md「画面構成」）。iPhone は逆さまの縦持ちを除く（Face ID の iPhone は
    /// 逆さまにならない）。画面とロックの覆いは同じ値を使う（覆いだけ違うと、覆いが出たときに画面ごと回る）。
    /// Info.plist の向き（ios/Config/Base.xcconfig）と合わせる
    static func app(for traits: UITraitCollection) -> UIInterfaceOrientationMask {
        traits.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = RootViewController()
        w.makeKeyAndVisible()
        window = w
        // 横持ちと縦持ちの両方（docs/design.md「画面構成」）。向きは端末に任せ、窓の大きさで作りを決める
    }
}
