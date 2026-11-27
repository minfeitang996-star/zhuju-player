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

        // 只有回到竖屏（退出播放页）才需要把窗口 / 根视图几何强制校正回竖屏 bounds。
        // 横屏方向切换期间，scene bounds 正处在新旧方向交替的过渡值，此时手动覆盖
        // HostingController 根视图 frame，SwiftUI 布局引擎还没按新方向重算，视图会被
        // 塞进错误几何，整套界面连同播放器一起横躺 90°。横屏几何交给系统几何更新即可。
        let forceFrame = mask == .portrait
        func relayoutWindows() {
            for scene in scenes {
                let bounds = scene.coordinateSpace.bounds
                for window in scene.windows {
                    if forceFrame, window.frame != bounds {
                        window.frame = bounds
                    }
                    if let vc = window.rootViewController {
                        if forceFrame {
                            vc.view.frame = bounds
                        }
                        vc.view.setNeedsLayout()
                        vc.view.layoutIfNeeded()
                    }
                }
            }
        }

        func requestGeometry() {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            for scene in scenes {
                scene.requestGeometryUpdate(preferences) { error in
                    NSLog("ZhuJu orientation failed: \(error)")
                }
            }
        }

        refreshOrientations()
        relayoutWindows()
        requestGeometry()

        // cover / sheet 转场期间几何更新可能被系统忽略，隔两拍再刷新方向约束、补发几何请求并重排兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            refreshOrientations(); relayoutWindows(); requestGeometry()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            refreshOrientations(); relayoutWindows(); requestGeometry()
        }
    }
}
