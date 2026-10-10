import StraitSDK
import SwiftUI
import UIKit

/// UIKit lifecycle with SwiftUI screens: the scene delegate sees the link that
/// launched the app from closed (`connectionOptions`), so a cold start is
/// labelled `closed` exactly. (The pure SwiftUI lifecycle can't tell; see the
/// SDK README, "SwiftUI".)
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ReferenceConfig.resetIfAsked()
        StraitTheme.applyAppearance()
        return true
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let model = StraitModel.shared
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: RootView(model: model))
        self.window = window
        window.makeKeyAndVisible()

        // The link that launched the app from closed: a Universal Link arrives as
        // a browsing-web user activity, the custom scheme as a URL context.
        let universal = options.userActivities
            .first { $0.activityType == NSUserActivityTypeBrowsingWeb }?.webpageURL
        model.start(launchURL: universal ?? options.urlContexts.first?.url)
    }

    /// Universal Link while running (background or foreground).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        StraitModel.shared.handle(userActivity: userActivity)
    }

    /// Custom-scheme link while running.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { StraitModel.shared.handle(url: context.url) }
    }
}
