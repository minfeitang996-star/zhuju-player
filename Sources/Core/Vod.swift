import Foundation
import Combine

// MARK: - 点播模型

/// 一个点播采集源（苹果 CMS V10 接口）
struct VodSite: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// 采集站接口根地址，例如 https://xxx/api.php/provide/vod/
    var api: String
    var searchable: Bool
    var createdAt: Date
}

/// 影片分类
struct VodCategory: Identifiable, Equatable, Hashable {
    let typeID: String
    let name: String
    var id: String { typeID }
}

/// 影片列表项
struct VodItem: Identifiable, Equatable {
    let id: String
    var name: String
    var pic: String?
    var remarks: String?
    var year: String?
    var area: String?
    var typeName: String?
    var time: String?
}

/// 一集
struct VodEpisode: Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url + "|" + name }
}

/// 一条播放线路（一个站点源可能有多条线路）
struct VodLine: Identifiable, Equatable {
    let name: String
    var episodes: [VodEpisode]
    var id: String { name }
}

/// 影片详情
struct VodDetail: Equatable {
    let item: VodItem
    var content: String?
    var actor: String?
    var director: String?
    var lines: [VodLine]
}

/// 历史 / 收藏快照：不依赖源是否还在，删掉源后仍可回看
struct VodHistoryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var pic: String?
    var url: String
    var episodeName: String
    var siteName: String
    var playedAt: Date
}

/// 从 TVBox / 影视仓配置 JSON 里解析出来的待导入站点
struct ImportedSite: Equatable {
    let name: String
    let api: String
    let searchable: Bool
}

// MARK: - 点播源清单（本地持久化）

final class VodStore: ObservableObject {

    @Published var sites: [VodSite] = []
    @Published var activeSiteID: UUID?
    @Published var history: [VodHistoryItem] = []
    @Published var favorites: [VodHistoryItem] = []

    private let sitesKey = "vodSitesV1"
    private let activeKey = "vodActiveSite"
    private let historyKey = "vodHistory"
    private let favKey = "vodFavorites"
    private let maxHistory = 30
    private let maxFavorites = 200

    static let shared = VodStore()

    private init() {
        loadSites()
        loadHistory()
        loadFavorites()
        loadActive()
        ensureActive()
    }

    // MARK: 加载 / 保存

    private func loadSites() {
        guard let data = UserDefaults.standard.data(forKey: sitesKey),
              let decoded = try? JSONDecoder().decode([VodSite].self, from: data) else { return }
        sites = decoded
    }

    private func saveSites() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: sitesKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([VodHistoryItem].self, from: data) else { return }
        history = decoded.sorted { $0.playedAt > $1.playedAt }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favKey),
              let decoded = try? JSONDecoder().decode([VodHistoryItem].self, from: data) else { return }
        favorites = decoded.sorted { $0.playedAt > $1.playedAt }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favKey)
        }
    }

    private func loadActive() {
        if let data = UserDefaults.standard.data(forKey: activeKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            activeSiteID = id
        }
    }

    private func saveActive() {
        if let activeSiteID {
            if let data = try? JSONEncoder().encode(activeSiteID) {
                UserDefaults.standard.set(data, forKey: activeKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    private func ensureActive() {
        if let activeSiteID, sites.contains(where: { $0.id == activeSiteID }) { return }
        activeSiteID = sites.first?.id
        saveActive()
    }

    var activeSite: VodSite? {
        if let activeSiteID, let found = sites.first(where: { $0.id == activeSiteID }) {
            return found
        }
        return sites.first
    }

    // MARK: 站点操作

    func selectSite(_ id: UUID) {
        activeSiteID = id
        saveActive()
    }

    @discardableResult
    func addSite(name: String, api: String, searchable: Bool) -> VodSite? {
        let trimmedAPI = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmedAPI) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 同一接口地址去重
        if let idx = sites.firstIndex(where: { normalizeAPI($0.api) == normalizeAPI(trimmedAPI) }) {
            sites[idx].searchable = searchable
            if !trimmedName.isEmpty { sites[idx].name = trimmedName }
            saveSites()
            activeSiteID = sites[idx].id
            saveActive()
            return sites[idx]
        }

        let site = VodSite(id: UUID(),
                           name: trimmedName.isEmpty ? Self.host(of: trimmedAPI) : trimmedName,
                           api: trimmedAPI,
                           searchable: searchable,
                           createdAt: Date())
        sites.append(site)
        saveSites()
        activeSiteID = site.id
        saveActive()
        return site
    }

    func deleteSite(_ id: UUID) {
        sites.removeAll { $0.id == id }
        if let current = activeSiteID, !sites.contains(where: { $0.id == current }) {
            activeSiteID = sites.first?.id
            saveActive()
        }
        saveSites()
    }

    func renameSite(_ id: UUID, name: String) {
        guard let idx = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSites()
    }

    /// 解析 TVBox / 影视仓配置 JSON，把可用的直采站点批量加入。
    /// - Returns: 新加入数量与跳过数量（type=3 的 JS 爬虫源在原生端跑不了，跳过）
    static func parseConfig(data: Data) -> (added: [ImportedSite], skipped: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], 0)
        }
        var added: [ImportedSite] = []
        var skipped = 0

        // 兼容多个配置键：sites / urls / site
        let candidates: [[String: Any]] =
            (json["sites"] as? [[String: Any]] ?? []) +
            (json["urls"] as? [[String: Any]] ?? []) +
            (json["site"] as? [[String: Any]] ?? [])

        for entry in candidates {
            let api = (entry["api"] as? String) ?? (entry["url"] as? String) ?? ""
            let name = (entry["name"] as? String) ?? (entry["title"] as? String) ?? ""
            let type = entry["type"] as? Int ?? (entry["type"] as? Double).map { Int($0) }
            // type 3 是依赖 JS 引擎的 CSP 爬虫源，iOS 原生无法执行，跳过
            if type == 3 { skipped += 1; continue }
            let trimmedAPI = api.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidURL(trimmedAPI) else { skipped += 1; continue }
            let searchable = (entry["searchable"] as? Int ?? 1) != 0
            added.append(ImportedSite(name: name, api: trimmedAPI, searchable: searchable))
        }
        return (added, skipped)
    }

    // MARK: 历史

    func recordHistory(name: String, pic: String?, url: String, episodeName: String, siteName: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        history.removeAll { $0.url == trimmed }
        let item = VodHistoryItem(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : name,
            pic: pic,
            url: trimmed,
            episodeName: episodeName,
            siteName: siteName,
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

    // MARK: 收藏

    func toggleFavorite(_ item: VodHistoryItem) {
        let trimmed = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        if let idx = favorites.firstIndex(where: { $0.url == trimmed }) {
            favorites.remove(at: idx)
        } else {
            var fav = item
            fav.id = UUID()
            fav.playedAt = Date()
            favorites.insert(fav, at: 0)
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

    // MARK: 工具

    static func isValidURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") else { return false }
        return URLComponents(string: trimmed)?.url != nil
    }

    private func normalizeAPI(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "https://")
            .lowercased()
    }

    private static func host(of urlString: String) -> String {
        URLComponents(string: urlString)?.host ?? urlString
    }
}
