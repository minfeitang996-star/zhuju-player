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

        // 横屏播放页退出后，窗口/根视图可能还停留在旧的横屏几何，回到竖屏页面时
        // 布局按旧宽度算，导致内容挤窄、比例错乱。这里把窗口和根视图 frame 同步成
        // 当前 scene 边界并强制重排，分拍兜底。
        func relayoutWindows() {
            for scene in scenes {
                let bounds = scene.coordinateSpace.bounds
                for window in scene.windows {
                    if window.frame != bounds {
                        window.frame = bounds
                    }
                    if let vc = window.rootViewController {
                        vc.view.frame = bounds
                        vc.view.setNeedsLayout()
                        vc.view.layoutIfNeeded()
                    }
                }
            }
        }

        refreshOrientations()
        relayoutWindows()

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        for scene in scenes {
            scene.requestGeometryUpdate(preferences) { error in
                NSLog("ZhuJu orientation failed: \(error)")
            }
        }

        // cover / sheet 转场期间几何更新可能被系统忽略，隔两拍再刷新方向约束并重排兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            refreshOrientations(); relayoutWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            refreshOrientations(); relayoutWindows()
        }
    }
}
