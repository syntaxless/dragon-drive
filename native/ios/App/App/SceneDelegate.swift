import UIKit
import Capacitor
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    // The "Start drive" Quick Action (long-press the app icon). The page may still be loading, so ask it every
    // 0.3 s, for up to 20 s, until window.ddQuick (app.html) answers true.
    private var quickAction: String?
    private var quickTimer: Timer?
    private var quickTries = 0

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = CAPBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)

        if let item = connectionOptions.shortcutItem {
            runQuickAction(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(runQuickAction(shortcutItem))
    }

    @discardableResult
    private func runQuickAction(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type.hasSuffix(".start-drive") else { return false }
        quickAction = "start"
        quickTries = 0
        quickTimer?.invalidate()
        quickTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self, let action = self.quickAction, self.quickTries < 66 else {
                timer.invalidate()
                self?.quickAction = nil
                return
            }
            self.quickTries += 1
            guard let webView = (self.window?.rootViewController as? CAPBridgeViewController)?.webView else { return }
            webView.evaluateJavaScript("window.ddQuick ? window.ddQuick('\(action)') : false") { result, _ in
                if (result as? Bool) == true {
                    self.quickAction = nil
                    self.quickTimer?.invalidate()
                    self.quickTimer = nil
                }
            }
        }
        return true
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
