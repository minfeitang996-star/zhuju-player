import Foundation
import Combine

/// 一条直播线路（同一个频道可以有一源、二源、三源…）
struct LiveSource: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var url: String
}

/// 一个网络直播频道
struct LiveChannel: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sources: [LiveSource]
    var group: String?
    /// 来源：builtin 内置示例 / manual 手动添加 / imported 订阅导入
    var kind: String
    var lastPlayed: Date?

    var primaryURL: String { sources.first?.url ?? "" }
    var sourceCount: Int { sources.count }

    enum CodingKeys: String, CodingKey {
        case id, name, sources, group, url, kind, lastPlayed
    }

    init(id: UUID, name: String, sources: [LiveSource], group: String?,
         kind: String = "imported", lastPlayed: Date? = nil) {
        self.id = id
        self.name = name
        self.sources = sources
        self.group = group
        self.kind = kind
        self.lastPlayed = lastPlayed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "imported"
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)

        if let sources = try? container.decode([LiveSource].self, forKey: .sources),
           !sources.isEmpty {
            self.sources = sources
        } else if let url = try? container.decode(String.self, forKey: .url), !url.isEmpty {
            self.sources = [LiveSource(id: UUID(), label: "一源", url: url)]
        } else {
            self.sources = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try container.encode(primaryURL, forKey: .url)
    }

    /// 分类文件夹：优先用 m3u 带过来的分组标题，没有就按名称推断央视 / 卫视 / 地区 / 其他
    var category: String {
        if let group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.classify(name)
    }

    static func classify(_ name: String) -> String {
        let n = name
        if n.localizedCaseInsensitiveContains("CCTV")
            || n.contains("央视") || n.contains("中央电视台") {
            return "央视"
        }
        if n.contains("卫视") { return "卫视" }

        let regionKeywords: [(label: String, keywords: [String])] = [
            ("北京", ["北京"]),
            ("上海", ["上海"]),
            ("天津", ["天津"]),
            ("重庆", ["重庆"]),
            ("江苏", ["江苏", "南京", "苏州", "无锡", "常州", "南通", "徐州", "扬州"]),
            ("浙江", ["浙江", "杭州", "宁波", "温州", "金华", "台州"]),
            ("安徽", ["安徽", "合肥", "芜湖", "蚌埠"]),
            ("福建", ["福建", "福州", "厦门", "泉州", "漳州"]),
            ("江西", ["江西", "南昌", "赣州", "九江"]),
            ("山东", ["山东", "济南", "青岛", "烟台", "潍坊", "临沂"]),
            ("河南", ["河南", "郑州", "洛阳", "开封"]),
            ("湖北", ["湖北", "武汉", "宜昌", "襄阳"]),
            ("湖南", ["湖南", "长沙", "株洲", "湘潭", "岳阳"]),
            ("广东", ["广东", "广州", "深圳", "佛山", "东莞", "珠海", "中山"]),
            ("广西", ["广西", "南宁", "柳州", "桂林"]),
            ("海南", ["海南", "海口", "三亚", "儋州"]),
            ("河北", ["河北", "石家庄", "唐山", "保定", "邯郸", "廊坊"]),
            ("山西", ["山西", "太原", "大同", "临汾"]),
            ("内蒙古", ["内蒙古", "呼和浩特", "包头", "鄂尔多斯"]),
            ("辽宁", ["辽宁", "沈阳", "大连", "鞍山", "抚顺"]),
            ("吉林", ["吉林", "长春", "吉林市", "延边"]),
            ("黑龙江", ["黑龙江", "哈尔滨", "齐齐哈尔", "大庆", "牡丹江"]),
            ("四川", ["四川", "成都", "绵阳", "宜宾", "泸州", "德阳"]),
            ("贵州", ["贵州", "贵阳", "遵义", "六盘水"]),
            ("云南", ["云南", "昆明", "大理", "丽江", "曲靖"]),
            ("西藏", ["西藏", "拉萨", "日喀则"]),
            ("陕西", ["陕西", "西安", "宝鸡", "咸阳", "延安"]),
            ("甘肃", ["甘肃", "兰州", "天水", "酒泉"]),
            ("青海", ["青海", "西宁", "海东"]),
            ("宁夏", ["宁夏", "银川", "石嘴山", "吴忠"]),
            ("新疆", ["新疆", "乌鲁木齐", "喀什", "伊犁", "昌吉"]),
        ]
        for item in regionKeywords {
            if item.keywords.contains(where: { n.contains($0) }) {
                return item.label
            }
        }
        return "其他"
    }
}

/// 一条快照记录（历史 / 收藏通用）：不依赖频道是否还在配置里，删掉后仍可回看
struct LiveHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var label: String
    var playedAt: Date
}

/// 一个直播配置（订阅源 / 本地连接组）：点配置即切换到这套频道
struct LivePlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// 订阅地址；nil 表示本地配置（手动添加 / 内置示例）
    var feedURL: String?
    var channels: [LiveChannel]
    var createdAt: Date
    var updatedAt: Date
    var isBuiltin: Bool
}

/// 直播源清单：本地存 UserDefaults，不联网刮削
final class LiveSourceStore: ObservableObject {

    @Published var playlists: [LivePlaylist] = []
    @Published var activePlaylistID: UUID?
    @Published var history: [LiveHistoryItem] = []
    @Published var favorites: [LiveHistoryItem] = []

    private let playlistsKey = "livePlaylistsV2"
    private let oldChannelsKey = "liveChannels"
    private let historyKey = "liveHistory"
    private let favoriteKey = "liveFavorites"
    private let activeKey = "liveActivePlaylist"
    private let migrateKey = "liveMigratedV2"
    private let maxHistory = 30
    private let maxFavorites = 200
    static let shared = LiveSourceStore()

    private init() {
        loadPlaylists()
        loadHistory()
        loadFavorites()
        loadActive()
        migrateIfNeeded()
        seedIfNeeded()
        ensureActive()
    }

    // MARK: - 加载 / 保存

    private func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: playlistsKey),
              let decoded = try? JSONDecoder().decode([LivePlaylist].self, from: data) else { return }
        playlists = decoded
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: playlistsKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([LiveHistoryItem].self, from: data) else { return }
        history = decoded.sorted { $0.playedAt > $1.playedAt }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoriteKey),
              let decoded = try? JSONDecoder().decode([LiveHistoryItem].self, from: data) else { return }
        favorites = decoded.sorted { $0.playedAt > $1.playedAt }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoriteKey)
        }
    }

    private func loadActive() {
        if let data = UserDefaults.standard.data(forKey: activeKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            activePlaylistID = id
        }
    }

    private func saveActive() {
        if let activePlaylistID {
            if let data = try? JSONEncoder().encode(activePlaylistID) {
                UserDefaults.standard.set(data, forKey: activeKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    // MARK: - 迁移与内置示例

    /// 旧版扁平频道池迁移到配置：内置 / 手动 / 已导入各归一个配置
    private func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrateKey) else { return }
        UserDefaults.standard.set(true, forKey: migrateKey)
        guard let data = UserDefaults.standard.data(forKey: oldChannelsKey),
              let old = try? JSONDecoder().decode([LiveChannel].self, from: data),
              !old.isEmpty else { return }

        let builtin = old.filter { $0.kind == "builtin" }
        let manual = old.filter { $0.kind == "manual" }
        let imported = old.filter { $0.kind != "builtin" && $0.kind != "manual" }

        if !builtin.isEmpty {
            playlists.append(LivePlaylist(id: UUID(), title: "示例频道", feedURL: nil,
                                           channels: builtin, createdAt: Date(), updatedAt: Date(), isBuiltin: true))
        }
        if !manual.isEmpty {
            playlists.append(LivePlaylist(id: UUID(), title: "我的连接", feedURL: nil,
                                           channels: manual, createdAt: Date(), updatedAt: Date(), isBuiltin: false))
        }
        if !imported.isEmpty {
            playlists.append(LivePlaylist(id: UUID(), title: "已导入", feedURL: nil,
                                           channels: imported, createdAt: Date(), updatedAt: Date(), isBuiltin: false))
        }
        savePlaylists()
    }

    /// 全新安装：内置少量实测可达的示例频道 + 一个空的「我的连接」本地配置
    private func seedIfNeeded() {
        guard playlists.isEmpty else { return }
        let samples: [(name: String, url: String)] = [
            ("CCTV+ 综合", "https://cd-live-stream.news.cctvplus.com/live/smil:CHANNEL1.smil/playlist.m3u8"),
            ("广州综合", "https://tencentplaybusiness.gztv.com/live/zonghes.m3u8"),
            ("哈尔滨影视", "https://stream.hrbtv.net/yspd/playlist.m3u8"),
            ("河北卫视", "https://event.pull.hebtv.com/live/live101.m3u8"),
            ("青岛 QTV-2", "http://video10.qtv.com.cn/drm/qtv2at/manifest.m3u8"),
            ("浙江国际", "https://ali-m-l.cztv.com/channels/lantian/channel10/1080p.m3u8"),
            ("安徽卫视", "https://restream.pdtvhd.com/memfs/c1cd2ed0-3b2b-4c25-af98-a7fb0b1eb130.m3u8")
        ]
        let sampleChannels = samples.map {
            LiveChannel(id: UUID(), name: $0.name,
                        sources: [LiveSource(id: UUID(), label: "一源", url: $0.url)],
                        group: "示例频道", kind: "builtin")
        }
        let builtin = LivePlaylist(id: UUID(), title: "示例频道", feedURL: nil,
                                   channels: sampleChannels, createdAt: Date(), updatedAt: Date(), isBuiltin: true)
        let mine = LivePlaylist(id: UUID(), title: "我的连接", feedURL: nil,
                                channels: [], createdAt: Date(), updatedAt: Date(), isBuiltin: false)
        playlists = [builtin, mine]
        savePlaylists()
    }

    private func ensureActive() {
        if let activePlaylistID, playlists.contains(where: { $0.id == activePlaylistID }) { return }
        activePlaylistID = playlists.first?.id
        saveActive()
    }

    // MARK: - 当前配置

    var activePlaylist: LivePlaylist? {
        if let activePlaylistID, let found = playlists.first(where: { $0.id == activePlaylistID }) {
            return found
        }
        return playlists.first
    }

    var activeChannels: [LiveChannel] { activePlaylist?.channels ?? [] }

    /// 全部配置里的频道，用于全局搜索
    var allChannels: [LiveChannel] { playlists.flatMap { $0.channels } }

    // MARK: - 配置操作

    func selectPlaylist(_ id: UUID) {
        activePlaylistID = id
        saveActive()
    }

    @discardableResult
    func addPlaylist(title: String, feedURL: String?, channels: [LiveChannel], isBuiltin: Bool = false) -> LivePlaylist {
        let pl = LivePlaylist(id: UUID(), title: title, feedURL: feedURL, channels: channels,
                              createdAt: Date(), updatedAt: Date(), isBuiltin: isBuiltin)
        playlists.append(pl)
        savePlaylists()
        activePlaylistID = pl.id
        saveActive()
        return pl
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if activePlaylistID == id {
            activePlaylistID = playlists.first?.id
            saveActive()
        }
        savePlaylists()
    }

    /// 批量删除多套配置；若当前激活配置被删，自动回退到第一套
    func deletePlaylists(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        playlists.removeAll { ids.contains($0.id) }
        if let activePlaylistID, !playlists.contains(where: { $0.id == activePlaylistID }) {
            activePlaylistID = playlists.first?.id
            saveActive()
        }
        savePlaylists()
    }

    func renamePlaylist(_ id: UUID, title: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        savePlaylists()
    }

    /// 按订阅地址重新拉取并替换整套频道
    func refreshPlaylist(_ id: UUID) async throws {
        guard let idx = playlists.firstIndex(where: { $0.id == id }),
              let feedURL = playlists[idx].feedURL,
              let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "live", code: -1, userInfo: [NSLocalizedDescriptionKey: "这个配置没有订阅地址"])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "live", code: -2, userInfo: [NSLocalizedDescriptionKey: "列表返回异常"])
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let entries = M3UParser.parse(text)
        guard !entries.isEmpty else {
            throw NSError(domain: "live", code: -3, userInfo: [NSLocalizedDescriptionKey: "没解析到可用频道"])
        }
        let channels = entries.map {
            LiveChannel(id: UUID(), name: $0.name,
                        sources: [LiveSource(id: UUID(), label: "一源", url: $0.url)],
                        group: $0.group, kind: "imported")
        }
        await MainActor.run {
            playlists[idx].channels = channels
            playlists[idx].updatedAt = Date()
            savePlaylists()
        }
    }

    // MARK: - 频道操作（在所属配置内）

    private func locate(channelID: UUID) -> (playlistIdx: Int, channelIdx: Int)? {
        for p in playlists.indices {
            if let c = playlists[p].channels.firstIndex(where: { $0.id == channelID }) {
                return (p, c)
            }
        }
        return nil
    }

    @discardableResult
    func addChannel(to playlistID: UUID, name: String, url: String) -> LiveChannel? {
        guard let p = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmedURL) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 同名频道：把新地址追加成下一条线路
        if let c = playlists[p].channels.firstIndex(where: {
            $0.name.localizedStandardCompare(trimmedName) == .orderedSame
        }) {
            appendSource(to: playlists[p].channels[c].id, url: trimmedURL)
            return playlists[p].channels[c]
        }

        let channel = LiveChannel(
            id: UUID(),
            name: trimmedName.isEmpty ? trimmedURL : trimmedName,
            sources: [LiveSource(id: UUID(), label: Self.sourceLabel(index: 0), url: trimmedURL)],
            group: nil,
            kind: "manual"
        )
        playlists[p].channels.append(channel)
        playlists[p].updatedAt = Date()
        savePlaylists()
        return channel
    }

    func updateChannel(_ channelID: UUID, name: String, url: String) {
        guard let (p, c) = locate(channelID: channelID) else { return }
        playlists[p].channels[c].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if playlists[p].channels[c].sources.isEmpty {
            playlists[p].channels[c].sources = [LiveSource(id: UUID(), label: "一源", url: trimmedURL)]
        } else {
            playlists[p].channels[c].sources[0].url = trimmedURL
        }
        playlists[p].updatedAt = Date()
        savePlaylists()
    }

    func deleteChannel(_ channelID: UUID) {
        guard let (p, c) = locate(channelID: channelID) else { return }
        playlists[p].channels.remove(at: c)
        playlists[p].updatedAt = Date()
        savePlaylists()
    }

    @discardableResult
    func appendSource(to channelID: UUID, url: String) -> LiveSource? {
        guard let (p, c) = locate(channelID: channelID) else { return nil }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmedURL),
              !playlists[p].channels[c].sources.contains(where: { $0.url == trimmedURL }) else { return nil }
        let label = Self.sourceLabel(index: playlists[p].channels[c].sources.count)
        let source = LiveSource(id: UUID(), label: label, url: trimmedURL)
        playlists[p].channels[c].sources.append(source)
        playlists[p].updatedAt = Date()
        savePlaylists()
        return source
    }

    func deleteSource(channelID: UUID, sourceID: UUID) {
        guard let (p, c) = locate(channelID: channelID) else { return }
        playlists[p].channels[c].sources.removeAll { $0.id == sourceID }
        if playlists[p].channels[c].sources.isEmpty {
            playlists[p].channels.remove(at: c)
        }
        playlists[p].updatedAt = Date()
        savePlaylists()
    }

    // MARK: - 历史

    /// 最近看过：同一条地址去重置顶，最多保留 maxHistory 条
    func recordHistory(name: String, url: String, label: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        history.removeAll { $0.url == trimmed }
        let item = LiveHistoryItem(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : name,
            url: trimmed,
            label: label,
            playedAt: Date()
        )
        history.insert(item, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        saveHistory()
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: - 收藏（跨配置快照）

    func toggleFavorite(name: String, url: String, label: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        if let idx = favorites.firstIndex(where: { $0.url == trimmed }) {
            favorites.remove(at: idx)
        } else {
            let item = LiveHistoryItem(
                id: UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : name,
                url: trimmed,
                label: label,
                playedAt: Date()
            )
            favorites.insert(item, at: 0)
            if favorites.count > maxFavorites { favorites.removeLast(favorites.count - maxFavorites) }
        }
        saveFavorites()
    }

    func isFavorited(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return favorites.contains { $0.url == trimmed }
    }

    func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    // MARK: - 工具

    static func isValidURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") else { return false }
        return URLComponents(string: trimmed)?.url != nil
    }

    private static func sourceLabel(index: Int) -> String {
        let labels = ["一源", "二源", "三源", "四源", "五源"]
        if index < labels.count { return labels[index] }
        return "源\(index + 1)"
    }

    /// 预设公开订阅列表：点一下拉取建成配置，源由上游维护，比写死直链耐用
    static let presetFeeds: [(title: String, url: String)] = [
        ("央视 / 卫视聚合", "http://live.fanmingming.cn/tv/m3u/index.m3u"),
        ("iptv-org 中国频道", "https://iptv-org.github.io/iptv/countries/cn.m3u")
    ]
}

/// m3u / m3u8 / txt 播放列表解析：只取频道名、分组和流地址，不做网络请求
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

            // txt 订阅格式：名称,http://...
            if let comma = line.lastIndex(of: ","),
               line[comma...].dropFirst().contains("://") {
                let rawURL = String(line[line.index(after: comma)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawName = String(line[..<comma])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if LiveSourceStore.isValidURL(rawURL) {
                    result.append(Entry(name: rawName.isEmpty ? rawURL : rawName,
                                        url: rawURL, group: pendingGroup))
                }
                pendingTitle = nil
                pendingGroup = nil
                continue
            }

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
