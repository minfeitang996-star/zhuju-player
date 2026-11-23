import Foundation
import Combine

/// 一条自定义网络直播频道
struct LiveChannel: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var group: String?

    /// 分类分组：优先用 m3u 带过来的分组标题，没有就按名称推断央视 / 卫视 / 其他
    var category: String {
        if let group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let n = name
        if n.localizedCaseInsensitiveContains("CCTV")
            || n.contains("央视") || n.contains("中央电视台") {
            return "央视"
        }
        if n.contains("卫视") { return "卫视" }
        return "其他"
    }
}

/// 直播源清单：本地存 UserDefaults，不联网刮削
final class LiveSourceStore: ObservableObject {

    @Published var channels: [LiveChannel] = []

    private let key = "liveChannels"
    static let shared = LiveSourceStore()

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LiveChannel].self, from: data) else { return }
        channels = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 链接是否像一个可用的流地址（http/https/rtsp/rtmp/udp/mms 等）
    static func isValidURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") else { return false }
        return URLComponents(string: trimmed)?.url != nil
    }

    @discardableResult
    func add(name: String, url: String, group: String? = nil) -> LiveChannel? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmedURL) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = LiveChannel(
            id: UUID(),
            name: trimmedName.isEmpty ? trimmedURL : trimmedName,
            url: trimmedURL,
            group: group
        )
        channels.append(channel)
        save()
        return channel
    }

    func add(_ list: [LiveChannel]) {
        channels.append(contentsOf: list)
        save()
    }

    func delete(_ id: UUID) {
        channels.removeAll { $0.id == id }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        channels.removeAll { ids.contains($0.id) }
        save()
    }

    func update(_ id: UUID, name: String, url: String) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        channels[idx].url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }
}

/// m3u / m3u8 播放列表解析：只取频道名、分组和流地址，不做网络请求
enum M3UParser {

    struct Entry: Equatable {
        let name: String
        let url: String
        let group: String?
    }

    static func parse(_ text: String) -> [Entry] {
        var result: [Entry] = []
        var pendingTitle: String?
        var pendingGroup: String?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF") {
                if let comma = line.lastIndex(of: ",") {
                    let title = String(line[line.index(after: comma)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingTitle = title.isEmpty ? nil : title
                } else {
                    pendingTitle = nil
                }
                if let range = line.range(of: "group-title=\"") {
                    let rest = line[range.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        pendingGroup = String(rest[..<end])
                    }
                } else {
                    pendingGroup = nil
                }
                continue
            }

            if line.hasPrefix("#") { continue }

            guard LiveSourceStore.isValidURL(line) else {
                pendingTitle = nil
                pendingGroup = nil
                continue
            }
            result.append(Entry(name: pendingTitle ?? line, url: line, group: pendingGroup))
            pendingTitle = nil
            pendingGroup = nil
        }
        return result
    }
}
