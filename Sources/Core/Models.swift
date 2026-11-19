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

    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var subtitleURL: URL? {
        let candidate = url.deletingPathExtension().appendingPathExtension("srt")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var hasSubtitle: Bool { subtitleURL != nil }

    var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576)
    }
}

final class MediaLibrary: ObservableObject {

    @Published var items: [MediaItem] = []

    let root: URL

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
        reload()
    }

    func reload() {
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
        var target = root.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: target.path) { return target }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            target = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) { return target }
            index += 1
        }
    }

    func delete(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        if let sub = item.subtitleURL { try? FileManager.default.removeItem(at: sub) }
        reload()
    }

    func subtitleDestination(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }
}
