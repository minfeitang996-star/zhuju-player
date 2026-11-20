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
    static var liveSource: String { UserDefaults.standard.string(forKey: "sourceLangPref") ?? "auto" }

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
