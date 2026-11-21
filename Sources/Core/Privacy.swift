import Foundation
import LocalAuthentication

/// 文件夹加密：以 Media 根目录下的相对路径为键，记在 UserDefaults 里
enum FolderLock {

    static let enabledKey = "privacyLockEnabled"
    private static let prefix = "lock:"

    private static var mediaRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Media", isDirectory: true).standardizedFileURL
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func relativePath(_ url: URL) -> String {
        let rootPath = mediaRoot.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    static func key(for url: URL) -> String { prefix + relativePath(url) }

    static func isLocked(_ url: URL) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: url))
    }

    static func setLocked(_ url: URL, _ locked: Bool) {
        if locked {
            UserDefaults.standard.set(true, forKey: key(for: url))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: url))
        }
    }

    static var lockedFolders: [(name: String, url: URL)] {
        let entries = UserDefaults.standard.dictionaryRepresentation()
        var result: [(String, URL)] = []
        for (key, value) in entries where key.hasPrefix(prefix) {
            guard (value as? Bool) == true else { continue }
            let rel = String(key.dropFirst(prefix.count))
            result.append((rel, mediaRoot.appendingPathComponent(rel, isDirectory: true)))
        }
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}

/// 面容 / 触控 / 设备密码，用系统的 deviceOwnerAuthentication：
/// 面容优先，识别不出来自动转成输入设备密码，不需要自己做密码界面
enum BiometricAuth {

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        default: return "设备密码"
        }
    }

    static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "输入设备密码"
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
