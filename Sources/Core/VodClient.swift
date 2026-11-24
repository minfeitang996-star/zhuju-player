import Foundation

/// 点播采集接口客户端：对接苹果 CMS V10 标准 provide/vod 接口
final class VodClient {

    static let shared = VodClient()
    private init() {}

    enum ClientError: LocalizedError {
        case badURL
        case badResponse(Int)
        case parseFailed
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址格式不对"
            case .badResponse(let code): return "接口返回异常（\(code)）"
            case .parseFailed: return "返回内容不是可用的 JSON"
            case .empty: return "没有解析到内容"
            }
        }
    }

    // MARK: - 分类

    func categories(site: VodSite) async throws -> [VodCategory] {
        let json = try await fetchJSON(site.api, query: ["ac": "list", "pagesize": "1"])
        var result: [VodCategory] = []

        if let classArray = json["class"] as? [[String: Any]] {
            for entry in classArray {
                let id = Self.anyString(entry["type_id"] ?? entry["id"])
                let name = Self.anyString(entry["type_name"] ?? entry["name"])
                guard !id.isEmpty, !name.isEmpty else { continue }
                result.append(VodCategory(typeID: id, name: name))
            }
        }

        // 兜底：部分站不返回 class，从首屏列表项里聚合出分类
        if result.isEmpty, let list = json["list"] as? [[String: Any]] {
            var seen = Set<String>()
            for entry in list {
                let id = Self.anyString(entry["type_id"] ?? entry["id"])
                let name = Self.anyString(entry["type_name"] ?? entry["type"])
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                result.append(VodCategory(typeID: id, name: name.isEmpty ? "分类 \(id)" : name))
            }
        }
        return result
    }

    // MARK: - 列表 / 搜索

    func list(site: VodSite, typeID: String?, page: Int, keyword: String?) async throws -> (items: [VodItem], pageCount: Int) {
        var query: [String: String] = ["ac": "list", "pg": "\(page)"]
        if let typeID, !typeID.isEmpty { query["t"] = typeID }
        if let keyword, !keyword.isEmpty { query["wd"] = keyword }

        let json = try await fetchJSON(site.api, query: query)
        let items = Self.parseItems(json["list"] as? [Any])
        let pageCount = Self.anyInt(json["pagecount"] ?? json["pageCount"])
        guard !items.isEmpty else { throw ClientError.empty }
        return (items, max(1, pageCount))
    }

    // MARK: - 详情

    func detail(site: VodSite, vodID: String) async throws -> VodDetail? {
        let json = try await fetchJSON(site.api, query: ["ac": "detail", "ids": vodID])
        guard let list = json["list"] as? [[String: Any]], let entry = list.first else {
            throw ClientError.empty
        }
        let item = Self.parseItem(entry) ?? VodItem(id: vodID, name: "未知影片", pic: nil,
                                                    remarks: nil, year: nil, area: nil,
                                                    typeName: nil, time: nil)
        let lines = Self.parseLines(playFrom: Self.anyString(entry["vod_play_from"]),
                                    playURL: Self.anyString(entry["vod_play_url"]))
        return VodDetail(
            item: item,
            content: Self.cleanHTML(Self.anyString(entry["vod_content"] ?? entry["content"] ?? entry["des"])),
            actor: Self.anyString(entry["vod_actor"] ?? entry["actor"]),
            director: Self.anyString(entry["vod_director"] ?? entry["director"]),
            lines: lines
        )
    }

    // MARK: - 请求

    private func fetchJSON(_ api: String, query: [String: String]) async throws -> [String: Any] {
        guard var comp = URLComponents(string: api.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ClientError.badURL
        }
        var items = comp.queryItems ?? []
        for (key, value) in query {
            items.append(URLQueryItem(name: key, value: value))
        }
        comp.queryItems = items.isEmpty ? nil : items
        guard let url = comp.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(-1) }
        guard http.statusCode == 200 else { throw ClientError.badResponse(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.parseFailed
        }
        return json
    }

    // MARK: - 解析

    private static func parseItems(_ array: [Any]?) -> [VodItem] {
        guard let array else { return [] }
        return array.compactMap { $0 as? [String: Any] }.compactMap(parseItem)
    }

    private static func parseItem(_ entry: [String: Any]) -> VodItem? {
        let id = anyString(entry["vod_id"] ?? entry["id"])
        let name = anyString(entry["vod_name"] ?? entry["name"] ?? entry["title"])
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return VodItem(
            id: id,
            name: name,
            pic: normalizePic(anyString(entry["vod_pic"] ?? entry["pic"])),
            remarks: anyString(entry["vod_remarks"] ?? entry["note"] ?? entry["remarks"]),
            year: anyString(entry["vod_year"] ?? entry["year"]),
            area: anyString(entry["vod_area"] ?? entry["area"]),
            typeName: anyString(entry["type_name"] ?? entry["type"]),
            time: anyString(entry["vod_time"] ?? entry["time"])
        )
    }

    /// 解析播放线路：`vod_play_from` 与 `vod_play_url` 都按 `$$$` 分段对齐
    private static func parseLines(playFrom: String?, playURL: String?) -> [VodLine] {
        guard let playURL, !playURL.isEmpty else { return [] }
        let froms = splitSegments(playFrom ?? "")
        let urls = splitSegments(playURL)
        var lines: [VodLine] = []

        for (index, episodeBlock) in urls.enumerated() {
            let lineName: String
            if index < froms.count, !froms[index].isEmpty {
                lineName = froms[index]
            } else {
                lineName = "线路 \(index + 1)"
            }
            let episodes = parseEpisodes(episodeBlock)
            if !episodes.isEmpty {
                lines.append(VodLine(name: lineName, episodes: episodes))
            }
        }
        return lines
    }

    private static func parseEpisodes(_ block: String) -> [VodEpisode] {
        let chunks = block.components(separatedBy: CharacterSet(charactersIn: "#\n\r"))
        var episodes: [VodEpisode] = []
        for chunk in chunks {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let url: String
            var name: String
            if let dollar = piece.lastIndex(of: "$") {
                name = String(piece[piece.startIndex..<dollar]).trimmingCharacters(in: .whitespacesAndNewlines)
                url = String(piece[piece.index(after: dollar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = ""
                url = piece
            }
            guard url.contains("://") else { continue }
            if name.isEmpty { name = "第 \(episodes.count + 1) 集" }
            episodes.append(VodEpisode(name: name, url: url))
        }
        return episodes
    }

    private static func splitSegments(_ text: String) -> [String] {
        text.components(separatedBy: "$$$").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func anyString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        if let d = value as? Double { return String(d) }
        return ""
    }

    private static func anyInt(_ value: Any?) -> Int {
        guard let value else { return 1 }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        return 1
    }

    private static func normalizePic(_ url: String?) -> String? {
        guard var url, !url.isEmpty else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    /// 去掉简介里的 HTML 标签与常见转义符
    private static func cleanHTML(_ text: String?) -> String? {
        guard var text, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
