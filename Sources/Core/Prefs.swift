import Foundation
import CoreGraphics

/// 播放 / 视频相关偏好，统一读写，默认值写死在这里。
enum Prefs {

    // 播放
    static var autoHideMenu: Bool { UserDefaults.standard.bool(forKey: "autoHideMenu") }
    static var autoHideDelay: Double { UserDefaults.standard.object(forKey: "autoHideDelay") as? Double ?? 5 }
    static var showElapsed: Bool { UserDefaults.standard.object(forKey: "showElapsed") as? Bool ?? true }
    static var showClock: Bool { UserDefaults.standard.bool(forKey: "showClock") }
    static var orientation: String { UserDefaults.standard.string(forKey: "orientationPref") ?? "landscape" }
    static var skipBack: Double { UserDefaults.standard.object(forKey: "skipBack") as? Double ?? 10 }
    static var skipForward: Double { UserDefaults.standard.object(forKey: "skipForward") as? Double ?? 15 }
    static var resumeEnabled: Bool { UserDefaults.standard.object(forKey: "resumeEnabled") as? Bool ?? true }
    static var keepRate: Bool { UserDefaults.standard.object(forKey: "keepRate") as? Bool ?? true }
    static var backgroundAudio: Bool { UserDefaults.standard.bool(forKey: "bgAudio") }
    static var bgConvert: Bool { UserDefaults.standard.object(forKey: "bgConvert") as? Bool ?? true }
    static var fastASR: Bool { UserDefaults.standard.object(forKey: "fastASR") as? Bool ?? true }
    static var translateTarget: String { UserDefaults.standard.string(forKey: "translateTarget") ?? "简体中文" }
    static var translateEngine: String { UserDefaults.standard.string(forKey: "translateEngine") ?? "auto" }
    static var translateEnabled: Bool { UserDefaults.standard.object(forKey: "translateEnabled") as? Bool ?? true }
    static var liveSource: String { UserDefaults.standard.string(forKey: "sourceLangPref") ?? "auto" }

    // 手势与操作
    static var gestureEnabled: Bool { UserDefaults.standard.object(forKey: "gestureEnabled") as? Bool ?? true }
    static var gestureDoubleTap: Bool { UserDefaults.standard.object(forKey: "gestureDoubleTap") as? Bool ?? true }
    static var gestureDoubleTapPlay: Bool { UserDefaults.standard.object(forKey: "gestureDoubleTapPlay") as? Bool ?? true }
    static var gestureDoubleTapSeek: Bool { UserDefaults.standard.object(forKey: "gestureDoubleTapSeek") as? Bool ?? true }
    static var doubleTapSeconds: Double { UserDefaults.standard.object(forKey: "doubleTapSeconds") as? Double ?? 10 }
    static var autoNext: Bool { UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true }
    static var repeatOne: Bool { UserDefaults.standard.object(forKey: "repeatOne") as? Bool ?? false }
    static var longPressSkip: Bool { UserDefaults.standard.object(forKey: "longPressSkip") as? Bool ?? true }
    static var longPressSeconds: Double { UserDefaults.standard.object(forKey: "longPressSeconds") as? Double ?? 10 }
    static var showOrientationLock: Bool { UserDefaults.standard.object(forKey: "showOrientationLock") as? Bool ?? true }
    static var liveSubLevel: String { UserDefaults.standard.string(forKey: "liveSubSize") ?? "small" }
    static var liveSubPosition: String { UserDefaults.standard.string(forKey: "liveSubPos") ?? "low" }
    /// 手动拖拉模式下的字幕离底距离（0...360）
    static var liveSubManualPad: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "liveSubManualPad") as? Double ?? 60)
    }
    static func setLiveSubManualPad(_ value: CGFloat) {
        let clamped = max(0, min(360, value))
        UserDefaults.standard.set(Double(clamped), forKey: "liveSubManualPad")
    }
    /// 外挂字幕延时（秒，正数字幕往后，负数往前）
    static var subDelay: Double { UserDefaults.standard.object(forKey: "subDelay") as? Double ?? 0 }
    /// 横滑满一屏对应的秒数
    static var scrubSeconds: Double { UserDefaults.standard.object(forKey: "scrubSeconds") as? Double ?? 240 }
    /// 片库排序：name / size / date
    static var librarySort: String { UserDefaults.standard.string(forKey: "librarySort") ?? "name" }

    static var liveSubSize: CGFloat {
        switch liveSubLevel {
        case "large": return 21
        case "medium": return 18
        default: return 15
        }
    }

    // 视频
    static var hwDecode: String { UserDefaults.standard.string(forKey: "hwDecode") ?? "auto" }
    static var deinterlace: Bool { UserDefaults.standard.bool(forKey: "deinterlace") }
    static var aspectUpdateToken: String { UserDefaults.standard.string(forKey: "aspectOverride") ?? "default" }

    static var aspectRatio: CGFloat? {
        switch aspectUpdateToken {
        case "16:9": return 16.0 / 9.0
        case "4:3": return 4.0 / 3.0
        case "1:1": return 1.0
        case "21:9": return 21.0 / 9.0
        default: return nil
        }
    }

    /// 1.2.0 起：点开视频默认横屏满屏 + 填充铺满，老用户也强制刷一次
    static func migrateLayoutDefaults() {
        let key = "prefsLayoutVersion"
        guard UserDefaults.standard.string(forKey: key) != "1.2.0" else { return }
        UserDefaults.standard.set("fill", forKey: "videoMode")
        UserDefaults.standard.set(false, forKey: "videoSafeArea")
        UserDefaults.standard.set("landscape", forKey: "orientationPref")
        UserDefaults.standard.set("1.2.0", forKey: key)
    }

    static func clearHistory() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("resume:") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
