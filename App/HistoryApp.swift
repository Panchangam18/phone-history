import UIKit
import WidgetKit

@main
@MainActor
final class HistoryAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        // Control Center caches its label independently of the app. Refresh once
        // after an upgrade even if the capture state itself has not changed.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "control-label-build") != version {
            ControlCenter.shared.reloadControls(ofKind: CaptureControlState.kind)
            defaults.set(version, forKey: "control-label-build")
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name:"Default Configuration",sessionRole:session.role)
        configuration.delegateClass = HistorySceneDelegate.self
        configuration.sceneClass = UIWindowScene.self
        return configuration
    }
}

@MainActor
final class HistorySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene:scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = HistoryController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
