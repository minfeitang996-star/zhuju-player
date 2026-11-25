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

        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        // 遍历所有窗口及其 present 链上的控制器刷新方向约束；
        // 直播是 sheet 上再叠 fullScreenCover，只刷 keyWindow 根控制器经常触达不到。
        func refreshOrientations() {
            for scene in scenes {
                for window in scene.windows {
                    var vc: UIViewController? = window.rootViewController
                    while let current = vc {
                        current.setNeedsUpdateOfSupportedInterfaceOrientations()
                        vc = current.presentedViewController
                    }
                }
            }
        }

        refreshOrientations()

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        for scene in scenes {
            scene.requestGeometryUpdate(preferences) { error in
                NSLog("ZhuJu orientation failed: \(error)")
            }
        }

        // cover / sheet 转场期间几何更新可能被系统忽略，隔两拍再刷新一次方向约束兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { refreshOrientations() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refreshOrientations() }
    }
}
