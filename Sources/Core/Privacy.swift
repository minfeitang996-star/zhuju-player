import Foundation
import LocalAuthentication

/// 文件夹加密：以 Media 根目录下的相对路径为键，记在 UserDefaults 里
enum FolderLock {

    static let enabledKey = "privacyLockEnabled"
    private static let prefix = "lock:"

    private static var mediaRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Media", isDirectory: true)
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 相对路径：/var 与 /private/var 两种写法都归一，避免同一个文件夹算出两个键
    static func relativePath(_ url: URL) -> String {
        let candidates = [
            (mediaRoot.standardizedFileURL.pathComponents, url.standardizedFileURL.pathComponents),
            (mediaRoot.resolvingSymlinksInPath().pathComponents, url.resolvingSymlinksInPath().pathComponents)
        ]
        for (rootComps, comps) in candidates {
            if comps.count >= rootComps.count,
               Array(comps.prefix(rootComps.count)) == rootComps {
                let tail = comps.dropFirst(rootComps.count)
                if tail.isEmpty { return "" }
                return tail.joined(separator: "/")
            }
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

    /// 往上找最近一个加密且还没解锁的上级文件夹，没找到返回 nil
    static func firstLockedAncestor(of url: URL, excluding unlocked: Set<String>) -> URL? {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let root = mediaRoot.standardizedFileURL
        var guardCount = 0
        while guardCount < 10 {
            guardCount += 1
            if current.pathComponents.count <= root.pathComponents.count { return nil }
            if isLocked(current), !unlocked.contains(relativePath(current)) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    /// 这个视频是不是躺在某个还没解锁的加密文件夹里
    static func isVideoProtected(_ url: URL, excluding unlocked: Set<String>) -> Bool {
        firstLockedAncestor(of: url, excluding: unlocked) != nil
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
        await MainActor.run {
            let context = LAContext()
            context.localizedFallbackTitle = "输入设备密码"
            context.localizedCancelTitle = "取消"
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return false
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                let resumeOnce: (Bool) -> Void = { value in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    resumeOnce(success)
                }
                // 兜底：验证回调万一迟迟不返回，12 秒后按失败返回，界面不会一直挂住
                Task {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    resumeOnce(false)
                }
            }
        }
    }
}
