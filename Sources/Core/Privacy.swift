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

/// 验证结果：通过 / 设备不可用 / 失败带原因 / 用户取消 / 超时
enum AuthOutcome: Equatable {
    case passed
    case unavailable(String)
    case failed(String)
    case cancelled
    case timeout

    var message: String {
        switch self {
        case .passed: return "验证通过"
        case .unavailable(let m): return m
        case .failed(let m): return m
        case .cancelled: return "已取消验证"
        case .timeout: return "验证超时，请再试一次"
        }
    }
}

/// 面容 / 触控 / 设备密码，用系统的 deviceOwnerAuthentication：
/// 面容优先，识别不出来自动转成输入设备密码，不需要自己做密码界面
enum BiometricAuth {

    // 强引用当前正在验证的 LAContext，避免异步等待期间被释放导致系统面板不回调
    private static var retained: [LAContext] = []
    private static let retainedLock = NSLock()

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
        await authenticateDetailed(reason: reason) == .passed
    }

    static func authenticateDetailed(reason: String) async -> AuthOutcome {
        let context = LAContext()
        context.localizedFallbackTitle = "输入设备密码"
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            let msg = error?.localizedDescription ?? "这台设备还没设置面容或设备密码"
            Boot.mark("auth unavailable: \(msg)")
            return .unavailable(msg)
        }

        retainedLock.lock()
        retained.append(context)
        retainedLock.unlock()

        return await withCheckedContinuation { (continuation: CheckedContinuation<AuthOutcome, Never>) in
            var resumed = false
            let finish: (AuthOutcome) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                retainedLock.lock()
                retained.removeAll { $0 === context }
                retainedLock.unlock()
                context.invalidate()
                continuation.resume(returning: outcome)
            }

            Boot.mark("auth evaluate: \(reason)")
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
                if success {
                    Boot.mark("auth passed")
                    finish(.passed)
                } else {
                    let code = (err as? LAError)?.code ?? .unknown
                    let msg = err?.localizedDescription ?? "错误码 \(code.rawValue)"
                    Boot.mark("auth fail code=\(code.rawValue) \(msg)")
                    switch code {
                    case .userCancel, .appCancel, .systemCancel:
                        finish(.cancelled)
                    default:
                        finish(.failed(msg))
                    }
                }
            }

            // 兜底：验证回调万一迟迟不返回，20 秒后按超时返回，界面不会一直挂住
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                Boot.mark("auth timeout")
                finish(.timeout)
            }
        }
    }
}
