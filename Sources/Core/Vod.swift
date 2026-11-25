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
    /// 播放进度 0...1；旧记录没有这个字段，解码时按 nil 处理
    var progress: Double? = nil
    /// 影片总时长（秒），用来在记录里显示看到的位置
    var duration: Double? = nil
}

/// 从 TVBox / 影视仓配置 JSON 里解析出来的待导入站点
struct ImportedSite: Equatable {
    let name: String
    let api: String
    let searchable: Bool
}

/// 配置导入结果：分别统计可导入站点、被跳过的 JS 爬虫源、无效地址
struct ConfigImportResult: Equatable {
    let added: [ImportedSite]
    let crawlerSkipped: Int
    let invalidSkipped: Int
}

// MARK: - 点播源清单（本地持久化）

final class VodStore: ObservableObject {

    @Published var sites: [VodSite] = []
    @Published var activeSiteID: UUID?
    @Published var history: [VodHistoryItem] = []
    @Published var favorites: [VodHistoryItem] = []
    @Published var searchHistory: [String] = []

    private let sitesKey = "vodSitesV1"
    private let activeKey = "vodActiveSite"
    private let historyKey = "vodHistory"
    private let favKey = "vodFavorites"
    private let searchKey = "vodSearchHistory"
    private let seededKey = "vodSeededV1"
    private let maxHistory = 30
    private let maxFavorites = 200
    private let maxSearch = 12

    /// 内置默认源：经纯直连实测可达的苹果 CMS 采集站；公开源会失效，失效后可在 App 内换源
    private static let builtinSites: [(name: String, api: String)] = [
        ("360资源", "https://360zy.com/api.php/provide/vod/"),
        ("豪华资源", "https://hhzyapi.com/api.php/provide/vod/")
    ]

    static let shared = VodStore()

    private init() {
        loadSites()
        loadHistory()
        loadFavorites()
        loadSearchHistory()
        loadActive()
        seedBuiltins()
        ensureActive()
    }

    /// 首次启动写入内置默认源；只种子一次，之后用户删除不再自动恢复
    private func seedBuiltins() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        for entry in Self.builtinSites {
            _ = addSite(name: entry.name, api: entry.api, searchable: true)
        }
        UserDefaults.standard.set(true, forKey: seededKey)
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

    // MARK: 搜索历史

    private func loadSearchHistory() {
        guard let saved = UserDefaults.standard.array(forKey: searchKey) as? [String] else { return }
        searchHistory = Array(saved.prefix(maxSearch))
    }

    private func saveSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: searchKey)
    }

    /// 记一条搜索关键词：重复的提到最前，最多留 12 条
    func addSearchKeyword(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        searchHistory.insert(t, at: 0)
        if searchHistory.count > maxSearch { searchHistory.removeLast(searchHistory.count - maxSearch) }
        saveSearchHistory()
    }

    func removeSearchKeyword(_ text: String) {
        searchHistory.removeAll { $0 == text }
        saveSearchHistory()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
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
    /// - Parameters:
    ///   - data: 配置原文（允许带 `//`、`/* */` 注释的 JSONC）
    ///   - baseURL: 配置链接本身，用于把 `./xxx` 这类相对接口地址补成绝对地址
    static func parseConfig(data: Data, baseURL: URL?) -> ConfigImportResult {
        guard let cleaned = stripJSONComments(data: data),
              let json = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any] else {
            return ConfigImportResult(added: [], crawlerSkipped: 0, invalidSkipped: 0)
        }

        // 兼容多个配置键：sites / urls / site
        let candidates: [[String: Any]] =
            (json["sites"] as? [[String: Any]] ?? []) +
            (json["urls"] as? [[String: Any]] ?? []) +
            (json["site"] as? [[String: Any]] ?? [])

        var added: [ImportedSite] = []
        var crawlerSkipped = 0
        var invalidSkipped = 0

        for entry in candidates {
            let rawAPI = (entry["api"] as? String) ?? (entry["url"] as? String) ?? ""
            let name = (entry["name"] as? String) ?? (entry["title"] as? String) ?? ""
            let type = entry["type"] as? Int ?? (entry["type"] as? Double).map { Int($0) }

            // type 3 是依赖 JS 引擎的 CSP / drpy 爬虫源，iOS 原生无法执行，跳过
            if type == 3 { crawlerSkipped += 1; continue }

            guard let api = Self.resolveAPI(rawAPI, base: baseURL), Self.isValidURL(api) else {
                invalidSkipped += 1
                continue
            }
            let searchable = (entry["searchable"] as? Int ?? 1) != 0
            added.append(ImportedSite(name: name, api: api, searchable: searchable))
        }
        return ConfigImportResult(added: added, crawlerSkipped: crawlerSkipped, invalidSkipped: invalidSkipped)
    }

    /// 把配置里的相对接口地址（`./xxx`、`//host/xxx`）补成绝对地址；无法识别返回 nil
    private static func resolveAPI(_ raw: String, base: URL?) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("//") { return "https:" + t }
        if t.contains("://") { return t }
        guard let base else { return nil }
        guard let rel = URL(string: t, relativeTo: base) else { return nil }
        let abs = rel.absoluteString
        return abs.contains("://") ? abs : nil
    }

    /// 剥离 JSONC 的行注释 `//`、块注释 `/* */` 与尾随逗号；字符串字面量内的内容原样保留
    private static func stripJSONComments(data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let chars = Array(text)
        var out: [Character] = []
        var i = 0
        var inString = false
        var escape = false

        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i < chars.count {
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { i += 2; break }
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }

        var cleaned = String(out)
        cleaned = cleaned.replacingOccurrences(of: ",(?=\\s*[}\\]])", with: "", options: .regularExpression)
        return cleaned.data(using: .utf8)
    }

    // MARK: 历史

    func recordHistory(name: String, pic: String?, url: String, episodeName: String, siteName: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        // 重新打开同一集时要沿用上次看到的进度，不能清掉
        let savedProgress = history.first { $0.url == trimmed }?.progress
        let savedDuration = history.first { $0.url == trimmed }?.duration
        history.removeAll { $0.url == trimmed }
        let item = VodHistoryItem(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : name,
            pic: pic,
            url: trimmed,
            episodeName: episodeName,
            siteName: siteName,
            playedAt: Date(),
            progress: savedProgress,
            duration: savedDuration
        )
        history.insert(item, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        saveHistory()
    }

    /// 播放中回写进度：更新对应历史记录的百分比、总时长与观看时间，并提到最前
    func updateProgress(url: String, progress: Double, duration: Double) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidURL(trimmed) else { return }
        guard let idx = history.firstIndex(where: { $0.url == trimmed }) else { return }
        let clamped = min(max(0, progress), 1)
        // 已经看到 98% 以上按看完处理，下次从头开始
        history[idx].progress = clamped >= 0.98 ? nil : clamped
        history[idx].duration = duration > 1 ? duration : history[idx].duration
        history[idx].playedAt = Date()
        if idx > 0 {
            let item = history.remove(at: idx)
            history.insert(item, at: 0)
        }
        saveHistory()
    }

    /// 上次看到的位置：只有 2%~98% 之间才算有可续播的进度
    func resumeProgress(for url: String) -> (progress: Double, duration: Double?)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = history.first(where: { $0.url == trimmed }),
              let p = item.progress, p > 0.02, p < 0.98 else { return nil }
        return (p, item.duration)
    }

    /// 最近在看的记录（有进度的那部分，新的在前）
    var continueWatching: [VodHistoryItem] {
        history.filter { item in
            guard let p = item.progress else { return false }
            return p > 0.02 && p < 0.98
        }
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
