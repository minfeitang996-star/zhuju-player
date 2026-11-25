import Foundation
import Combine

/// 点播剧集离线下载：把 HLS(m3u8) 分片按顺序拼接成单个 .ts，或把直连视频文件直接存入本地片库。
/// 下载完成后文件进入 Documents/Media，本地播放器可直接离线播放。
@MainActor
final class VodDownloadManager: ObservableObject {

    enum Status: Equatable {
        case idle
        case downloading
        case done
        case failed(String)
    }

    struct TaskState: Equatable {
        var status: Status
        /// 0...1
        var progress: Double
        var done: Int
        var total: Int
        var fileName: String?
    }

    static let shared = VodDownloadManager()

    @Published private(set) var tasks: [String: TaskState] = [:]

    private let registryKey = "vodDownloadsV1"
    private var registry: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: registryKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: registryKey) }
    }

    private var cancelFlags = Set<String>()
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 可直接整文件下载的容器后缀
    private static let directExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv",
        "mpg", "mpeg", "3gp", "ogv", "rmvb", "rm", "f4v", "vob"
    ]

    private init() {
        // 启动时把已完成的登记恢复成 done；文件若已被手动删除则回退 idle
        var restored: [String: TaskState] = [:]
        for (url, fileName) in registry {
            if fileExists(fileName) {
                restored[url] = TaskState(status: .done, progress: 1, done: 1, total: 1, fileName: fileName)
            }
        }
        tasks = restored
    }

    // MARK: - 对外接口

    /// 查询某一集（以播放地址为唯一标识）的下载状态
    func state(for key: String) -> TaskState {
        if let cached = tasks[key] { return cached }
        if let name = registry[key], fileExists(name) {
            let restored = TaskState(status: .done, progress: 1, done: 1, total: 1, fileName: name)
            tasks[key] = restored
            return restored
        }
        return TaskState(status: .idle, progress: 0, done: 0, total: 0, fileName: nil)
    }

    /// 开始下载；已在下载或已完成时直接返回
    func download(title: String, episodeName: String, sourceURL: String) {
        guard !sourceURL.isEmpty else { return }
        let current = state(for: sourceURL)
        if case .downloading = current.status { return }
        if case .done = current.status { return }
        cancelFlags.remove(sourceURL)
        Task { await run(title: title, episodeName: episodeName, sourceURL: sourceURL) }
    }

    /// 取消进行中的下载（保留半成品清理由任务内负责）
    func cancel(_ key: String) {
        cancelFlags.insert(key)
    }

    // MARK: - 下载流程

    private func run(title: String, episodeName: String, sourceURL: String) async {
        let baseName = Self.fileBase(title: title, episodeName: episodeName)
        let ext = (sourceURL as NSString).pathExtension.lowercased()

        if Self.directExtensions.contains(ext) {
            await downloadSingleFile(key: sourceURL, baseName: baseName, ext: ext, url: sourceURL)
        } else {
            await downloadHLS(key: sourceURL, baseName: baseName, playlistURL: sourceURL)
        }
    }

    /// 直连整文件下载
    private func downloadSingleFile(key: String, baseName: String, ext: String, url: String) async {
        setState(key, status: .downloading, progress: 0, done: 0, total: 1, fileName: nil)

        var data: Data?
        for attempt in 0..<2 {
            do {
                data = try await fetchBytes(url)
                break
            } catch {
                if attempt == 1 { break }
            }
        }
        guard let data else {
            markFailed(key, message: "连不上下载地址", done: 0, total: 1)
            return
        }

        let dest = MediaLibrary.shared.uniqueDestination(for: "\(baseName).\(ext)")
        do {
            try data.write(to: dest, options: .atomic)
            register(key, fileName: dest.lastPathComponent)
            setState(key, status: .done, progress: 1, done: 1, total: 1, fileName: dest.lastPathComponent)
        } catch {
            markFailed(key, message: "写入本地失败", done: 0, total: 1)
        }
    }

    /// HLS 下载：主播放列表 → 变体列表 → 分片顺序拼接为 .ts
    private func downloadHLS(key: String, baseName: String, playlistURL: String) async {
        setState(key, status: .downloading, progress: 0, done: 0, total: 0, fileName: nil)

        // 1. 拉取播放列表
        let masterRaw: String
        do {
            masterRaw = try await fetchText(playlistURL)
        } catch {
            markFailed(key, message: "连不上播放地址", done: 0, total: 0)
            return
        }

        // 2. 若是主列表，取第一条变体地址再拉一次
        var variantBase = playlistURL
        let variantRaw: String
        if masterRaw.contains("EXT-X-STREAM-INF"),
           let variant = firstVariant(masterRaw, base: playlistURL) {
            variantBase = variant
            do {
                variantRaw = try await fetchText(variant)
            } catch {
                markFailed(key, message: "播放线路解析失败", done: 0, total: 0)
                return
            }
        } else {
            variantRaw = masterRaw
        }

        // 3. 加密检查：AES-128 暂不支持
        for line in variantRaw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-KEY"), trimmed.contains("METHOD=AES-128") {
                markFailed(key, message: "该线路有加密，暂不支持下载", done: 0, total: 0)
                return
            }
        }

        let segments = segmentURLs(variantRaw, base: variantBase)
        guard !segments.isEmpty else {
            markFailed(key, message: "没有可下载的分片", done: 0, total: 0)
            return
        }

        let total = segments.count
        let tempURL = MediaLibrary.shared.root
            .appendingPathComponent(".\(UUID().uuidString).downloading.ts")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            markFailed(key, message: "无法写入本地存储", done: 0, total: total)
            return
        }

        var completed = 0
        do {
            for (index, segment) in segments.enumerated() {
                if cancelFlags.contains(key) {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    setState(key, status: .idle, progress: 0, done: 0, total: 0, fileName: nil)
                    return
                }

                var segmentData: Data?
                for attempt in 0..<2 {
                    do {
                        segmentData = try await fetchBytes(segment)
                        break
                    } catch {
                        if attempt == 1 { break }
                    }
                }
                guard let segmentData else { throw DownloadError.segmentFailed(index + 1) }

                try handle.write(contentsOf: segmentData)
                completed = index + 1
                setState(key, status: .downloading,
                         progress: Double(completed) / Double(total),
                         done: completed, total: total, fileName: nil)
            }

            try handle.close()
            let dest = MediaLibrary.shared.uniqueDestination(for: "\(baseName).ts")
            try FileManager.default.moveItem(at: tempURL, to: dest)
            register(key, fileName: dest.lastPathComponent)
            setState(key, status: .done, progress: 1, done: total, total: total, fileName: dest.lastPathComponent)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            markFailed(key, message: "分片下载中断，已清理半成品", done: completed, total: total)
        }
    }

    // MARK: - 网络

    private func fetchText(_ urlString: String) async throws -> String {
        let data = try await fetchBytes(urlString)
        guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.parseFailed }
        return text
    }

    private func fetchBytes(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw DownloadError.badURL }
        var request = URLRequest(url: url)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw DownloadError.badResponse }
        return data
    }

    // MARK: - 播放列表解析

    private func firstVariant(_ playlist: String, base: String) -> String? {
        for rawLine in playlist.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            return resolve(line, base: base)
        }
        return nil
    }

    private func segmentURLs(_ playlist: String, base: String) -> [String] {
        playlist.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { resolve($0, base: base) }
    }

    private func resolve(_ reference: String, base: String) -> String {
        guard let baseURL = URL(string: base),
              let resolved = URL(string: reference, relativeTo: baseURL) else {
            return reference
        }
        return resolved.absoluteString
    }

    // MARK: - 状态与登记

    private func setState(_ key: String, status: Status, progress: Double, done doneCount: Int, total totalCount: Int, fileName: String?) {
        let state = TaskState(status: status, progress: progress, done: doneCount, total: totalCount, fileName: fileName)
        tasks[key] = state
    }

    private func markFailed(_ key: String, message: String, done: Int, total: Int) {
        setState(key, status: .failed(message), progress: 0, done: done, total: total, fileName: nil)
    }

    private func register(_ key: String, fileName: String) {
        var reg = registry
        reg[key] = fileName
        registry = reg
        MediaLibrary.shared.reload()
    }

    private func fileExists(_ fileName: String) -> Bool {
        let url = MediaLibrary.shared.root.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 文件名

    static func fileBase(title: String, episodeName: String) -> String {
        let cleanTitle = sanitize(title)
        let cleanEpisode = sanitize(episodeName)
        if cleanEpisode.isEmpty || cleanEpisode == cleanTitle { return cleanTitle }
        return "\(cleanTitle) - \(cleanEpisode)"
    }

    private static func sanitize(_ text: String) -> String {
        var out = text
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            out = out.replacingOccurrences(of: bad, with: " ")
        }
        out = out.components(separatedBy: .newlines).joined(separator: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DownloadError: Error {
    case badURL
    case badResponse
    case parseFailed
    case segmentFailed(Int)
}
