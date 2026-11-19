import UIKit

/// 界面方向锁：默认竖屏，只有播放页允许横屏全屏。
final class AppDelegate: NSObject, UIApplicationDelegate {

    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

enum OrientationHelper {

    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene.windows.first?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)

        scene.requestGeometryUpdate(preferences) { error in
            NSLog("ZhuJu orientation failed: \(error)")
        }
    }
}
