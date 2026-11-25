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
        var items = Self.parseItems(json["list"] as? [Any])
        let pageCount = Self.anyInt(json["pagecount"] ?? json["pageCount"])
        // 搜索无结果属于正常空态，不再当成失败抛错；解析 / 网络错误才由上层展示重试
        items = await fillMissingCovers(site: site, items: items)
        return (items, max(1, pageCount))
    }

    /// 部分采集站（360资源、豪华资源等）的 list 接口不返回 vod_pic，
    /// 用 detail&ids= 批量补一次封面；补不到就保持原样，不影响浏览和播放
    private func fillMissingCovers(site: VodSite, items: [VodItem]) async -> [VodItem] {
        let missing = items.filter { ($0.pic ?? "").isEmpty }.map(\.id).filter { !$0.isEmpty }
        guard !missing.isEmpty else { return items }
        let ids = missing.prefix(40).joined(separator: ",")
        guard let json = try? await fetchJSON(site.api, query: ["ac": "detail", "ids": ids]),
              let list = json["list"] as? [[String: Any]] else { return items }

        var pics: [String: String] = [:]
        for entry in list {
            let id = Self.anyString(entry["vod_id"] ?? entry["id"])
            guard !id.isEmpty,
                  let pic = Self.normalizePic(Self.anyString(entry["vod_pic"] ?? entry["pic"])) else { continue }
            pics[id] = pic
        }
        guard !pics.isEmpty else { return items }

        return items.map { item in
            guard (item.pic ?? "").isEmpty, let pic = pics[item.id] else { return item }
            var copy = item
            copy.pic = pic
            return copy
        }
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
        let candidates = Self.apiCandidates(api)
        var lastError: Error = ClientError.parseFailed
        for candidate in candidates {
            for attempt in 0..<3 {
                do {
                    return try await requestJSON(candidate, query: query)
                } catch ClientError.badResponse(let code) where code >= 400 && code < 500 {
                    // 4xx 是地址 / 参数问题，重试无意义，直接记为最后错误换下一个候选
                    lastError = ClientError.badResponse(code)
                    break
                } catch {
                    lastError = error
                    // 网络抖动 / 超时 / 5xx / 解析失败：短退避后再试一次，降低偶发刷不出来的概率
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: attempt == 0 ? 300_000_000 : 700_000_000)
                    }
                }
            }
        }
        throw lastError
    }

    /// 请求候选：先用原始地址；若只是裸域名 / 站点首页，再补 `api.php/provide/vod/` 试一次
    private static func apiCandidates(_ api: String) -> [String] {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result = [trimmed]
        if let supplemented = supplementAPI(trimmed), !result.contains(supplemented) {
            result.append(supplemented)
        }
        return result
    }

    /// 已带接口路径则不补；否则按 scheme://host 拼标准 CMS V10 接口根路径
    private static func supplementAPI(_ api: String) -> String? {
        guard var comp = URLComponents(string: api), let host = comp.host, !host.isEmpty else { return nil }
        if comp.path.contains("api.php") || comp.path.contains("provide/vod") { return nil }
        comp.path = "/api.php/provide/vod/"
        comp.queryItems = nil
        return comp.url?.absoluteString
    }

    private func requestJSON(_ api: String, query: [String: String]) async throws -> [String: Any] {
        guard var comp = URLComponents(string: api) else {
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
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(-1) }
        guard http.statusCode == 200 else { throw ClientError.badResponse(http.statusCode) }
        guard let json = Self.parseJSON(data) else {
            throw ClientError.parseFailed
        }
        return json
    }

    /// 宽松解析 JSON：去 BOM / 前导空白，剥离注释与尾随逗号，必要时截取首尾花括号；兼容个别采集站返回的不规范正文
    private static func parseJSON(_ data: Data) -> [String: Any]? {
        var body = data
        if body.count >= 3, body[0] == 0xEF, body[1] == 0xBB, body[2] == 0xBF {
            body = body.subdata(in: 3..<body.count)
        }
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { return obj }
        if let cleaned = stripComments(body),
           let obj = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any] { return obj }
        if let text = String(data: body, encoding: .utf8),
           let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start,
           let d = String(text[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
        return nil
    }

    /// 轻量剥离 // 行注释、/* */ 块注释与尾随逗号（字符串字面量内原样保留）
    private static func stripComments(_ data: Data) -> Data? {
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
