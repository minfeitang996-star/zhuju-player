import Foundation
import Combine

// MARK: - 字幕条目

struct SubtitleCue: Identifiable, Equatable {
    let id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

// MARK: - SRT 读写

enum SubtitleFile {

    static func timecode(_ t: TimeInterval) -> String {
        let total = max(0, Int((t * 1000).rounded()))
        let h = total / 3_600_000
        let m = (total % 3_600_000) / 60_000
        let s = (total % 60_000) / 1_000
        let ms = total % 1_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "\(index + 1)\r\n"
            out += "\(timecode(cue.start)) --> \(timecode(cue.end))\r\n"
            out += "\(text)\r\n\r\n"
        }
        return out
    }

    static func write(_ cues: [SubtitleCue], to url: URL) throws {
        try srt(cues).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 片库

struct MediaItem: Identifiable, Equatable {
    let url: URL
    /// 扫描时一次性读好的大小与修改时间，避免列表每次重绘都重复走磁盘 stat
    let size: Int64
    let modified: Date?

    init(url: URL) {
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        self.modified = attrs?[.modificationDate] as? Date
    }

    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var subtitleURL: URL? {
        let candidate = url.deletingPathExtension().appendingPathExtension("srt")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var hasSubtitle: Bool { subtitleURL != nil }

    var fileSize: Int64 { size }

    var modifiedDate: Date? { modified }

    var sizeText: String {
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576)
    }
}

// MARK: - 本地列表条目（文件夹 / 视频）

enum LibraryEntry: Identifiable {
    case folder(URL, Int)
    case video(MediaItem)

    var id: String {
        switch self {
        case .folder(let url, _): return "f:" + url.path
        case .video(let item): return "v:" + item.url.path
        }
    }
}

final class MediaLibrary: ObservableObject {
    @Published var items: [MediaItem] = []

    let root: URL

    /// 文件夹视频数缓存：主页每次重绘都要取计数，不缓存会递归反复扫磁盘
    private var countCache: [String: Int] = [:]

    /// VLC 能解码的常见容器格式，全部支持播放。
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "ts", "m2ts", "mts",
        "webm", "rmvb", "rm", "mpg", "mpeg", "3gp", "ogv", "vob", "asf",
        "divx", "f4v", "dat", "iso", "mxf", "dv"
    ]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Boot.mark("B library.init")
        reload()
    }

    func reload() {
        countCache.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        items = files
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { MediaItem(url: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> [String] {
        var failures: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let destination = uniqueDestination(for: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        return failures
    }

    func uniqueDestination(for fileName: String) -> URL {
        uniqueDestination(for: fileName, in: root)
    }

    func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        var target = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: target.path) { return target }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            target = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) { return target }
            index += 1
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL], into folder: URL) -> [String] {
        var failures: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let destination = uniqueDestination(for: url.lastPathComponent, in: folder)
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        return failures
    }

    func delete(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        if let sub = item.subtitleURL { try? FileManager.default.removeItem(at: sub) }
        reload()
    }

    func subtitleDestination(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }

    // MARK: - 文件夹浏览

    func folders(in parent: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return all
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func videos(in folder: URL) -> [MediaItem] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return all
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { MediaItem(url: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func videoCount(in folder: URL) -> Int {
        let key = folder.path
        if let cached = countCache[key] { return cached }
        var total = videos(in: folder).count
        for sub in folders(in: folder) {
            total += videoCount(in: sub)
        }
        countCache[key] = total
        return total
    }

    func entries(in folder: URL) -> [LibraryEntry] {
        let folderEntries = folders(in: folder).map {
            LibraryEntry.folder($0, videoCount(in: $0))
        }
        let videoEntries = videos(in: folder).map { LibraryEntry.video($0) }
        return folderEntries + videoEntries
    }

    func allVideos(in folder: URL? = nil) -> [MediaItem] {
        let target = folder ?? root
        var result = videos(in: target)
        for sub in folders(in: target) {
            result += allVideos(in: sub)
        }
        return result
    }

    @discardableResult
    func createFolder(named name: String, in parent: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let target = parent.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        } catch {
            return nil
        }
    }

    @discardableResult
    func move(_ item: MediaItem, to folder: URL) -> Bool {
        let destination = folder.appendingPathComponent(item.url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            if let sub = item.subtitleURL {
                let subDestination = folder.appendingPathComponent(sub.lastPathComponent)
                try? FileManager.default.moveItem(at: sub, to: subDestination)
            }
            reload()
            return true
        } catch {
            return false
        }
    }

    func deleteFolder(_ url: URL) {
        guard url.standardizedFileURL.path != root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// 重命名视频（保留原扩展名），同名配对字幕一起改名
    @discardableResult
    func renameVideo(_ item: MediaItem, to newBase: String) -> Bool {
        let base = newBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        let ext = item.url.pathExtension.lowercased()
        let folder = item.url.deletingLastPathComponent()
        let candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        guard candidate.path != item.url.path else { return true }
        let dest = uniqueDestination(for: candidate.lastPathComponent, in: folder)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            if let sub = item.subtitleURL {
                let newSub = dest.deletingPathExtension().appendingPathExtension("srt")
                try? FileManager.default.moveItem(at: sub, to: newSub)
            }
            reload()
            return true
        } catch {
            return false
        }
    }

    /// 重命名文件夹（根目录不允许改名）
    @discardableResult
    func renameFolder(_ url: URL, to newName: String) -> Bool {
        guard url.standardizedFileURL.path != root.standardizedFileURL.path else { return false }
        let base = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        let parent = url.deletingLastPathComponent()
        let dest = parent.appendingPathComponent(base)
        guard dest.path != url.path else { return true }
        guard !FileManager.default.fileExists(atPath: dest.path) else { return false }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            reload()
            return true
        } catch {
            return false
        }
    }

    /// 同文件夹里按名称排在当前视频后面的那一个，用来「自动播下一集」
    /// 同文件夹里按名称排在当前视频前面的那一个
    func previousVideo(before item: MediaItem) -> MediaItem? {
        let folder = item.url.deletingLastPathComponent()
        let list = videos(in: folder)
        guard let index = list.firstIndex(where: { $0.url.path == item.url.path }), index > 0 else { return nil }
        return list[index - 1]
    }

    func nextVideo(after item: MediaItem) -> MediaItem? {
        let folder = item.url.deletingLastPathComponent()
        let list = videos(in: folder)
        guard let index = list.firstIndex(where: { $0.url.path == item.url.path }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < list.count else { return nil }
        return list[nextIndex]
    }
}
