import Foundation

/// 语言名 / 代码互转，翻译通道内部统一用代码。
enum LangCode {

    static func code(for name: String) -> String {
        switch name {
        case "简体中文": return "zh-CHS"
        case "繁体中文": return "zh-CHT"
        case "英语": return "en"
        case "日语": return "ja"
        case "韩语": return "ko"
        case "俄语": return "ru"
        case "法语": return "fr"
        case "德语": return "de"
        case "西班牙语", "西语": return "es"
        case "阿拉伯语": return "ar"
        case "泰语": return "th"
        case "越南语": return "vi"
        case "意语", "意大利语": return "it"
        case "葡语", "葡萄牙语": return "pt"
        default: return "zh-CHS"
        }
    }

    static func base(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw != "auto" else { return "auto" }
        if raw.hasPrefix("zh") { return "zh" }
        return String(raw.prefix(2))
    }

    static func name(_ raw: String?) -> String {
        switch base(raw) {
        case "zh": return "中文"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "ru": return "俄语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西语"
        case "it": return "意语"
        case "pt": return "葡语"
        case "ar": return "阿拉伯语"
        case "th": return "泰语"
        case "vi": return "越南语"
        default: return "自动"
        }
    }

    static func isSame(_ a: String?, _ b: String?) -> Bool {
        let baseA = base(a)
        let baseB = base(b)
        guard baseA != "auto", baseB != "auto" else { return false }
        return baseA == baseB
    }
}

enum FreeTranslationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// 免密钥在线翻译：必应（edge 免鉴权 token，国内可直连）→ MyMemory → 有道旧接口 → Google。
/// 每个通道独立冷却，失败自动换下一个；译文写本地缓存，重复台词不再发请求。
actor TranslationHub {

    static let shared = TranslationHub()

    private var cache: [String: String] = [:]
    private var cacheLoaded = false
    private var lastRequestAt = Date.distantPast
    private var cooldown: [String: Date] = [:]
    private(set) var lastEngine = ""
    private(set) var lastErrorText = ""

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("zhuju-translate-cache.json")
    }

    func currentEngine() -> String { lastEngine }
    func currentError() -> String { lastErrorText }

    func cacheCount() -> Int {
        loadCacheIfNeeded()
        return cache.count
    }

    func clearCache() {
        cache.removeAll()
        cacheLoaded = true
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// 在线免密钥通道这两年陆续失效，连续失败后整体熔断，避免拖住识别/生成字幕
    private var failStreak = 0
    private var disabledUntil = Date.distantPast

    func translate(_ text: String, source: String, target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if LangCode.isSame(source, target) { return trimmed }

        if Date() < disabledUntil {
            throw FreeTranslationError.failed("在线翻译暂时不可用，已切到原文显示。要长期稳定请在设置里填 Azure 或自配接口的 Key")
        }

        loadCacheIfNeeded()
        let key = "\(source)|\(target)|\(trimmed)"
        if let hit = cache[key] { return hit }

        // 离线日译中优先：模型已下载、原文像日语时完全本机翻译，不联网、不要 Key。
        if LangCode.base(target).hasPrefix("zh") {
            let sourceIsJa = LangCode.base(source) == "ja"
            let looksJa = sourceIsJa || (LangCode.base(source) == "auto" && MTTokenizer.looksJapanese(trimmed))
            if looksJa, OfflineMT.shared.isReady {
                do {
                    let offline = try await OfflineMT.shared.translate(trimmed)
                    cache[key] = offline
                    lastEngine = "离线日译中"
                    lastErrorText = ""
                    saveCacheIfNeeded()
                    return offline
                } catch {
                    // 离线没翻出来就继续走下面的在线通道
                }
            }
        }

        let engine = UserDefaults.standard.string(forKey: "translateEngine") ?? "auto"
        let hasAzure = !(UserDefaults.standard.string(forKey: "azureKey") ?? "").isEmpty
        let hasAPI = !((UserDefaults.standard.string(forKey: "apiKey") ?? "").trimmingCharacters(in: .whitespaces)).isEmpty
            && !((UserDefaults.standard.string(forKey: "apiBase") ?? "").trimmingCharacters(in: .whitespaces)).isEmpty
        var order: [String]
        switch engine {
        case "api": order = hasAPI ? ["api"] : []
        case "azure": order = hasAzure ? ["azure"] : []
        case "free": order = ["mymemory", "google"]
        default:
            order = []
            if hasAPI { order.append("api") }
            if hasAzure { order.append("azure") }
            order += ["mymemory", "google"]
        }
        if order.isEmpty {
            throw FreeTranslationError.failed("所选通道还没配置：填自配接口的 Base URL/Key，或 Azure 密钥")
        }

        var errors: [String] = []
        let deadline = Date().addingTimeInterval(12)

        for name in order {
            if Date() >= deadline { errors.append("\(displayName(name)): 超出本次预算跳过"); continue }
            if let until = cooldown[name], Date() < until { continue }
            do {
                let result: String
                switch name {
                case "azure": result = try await azure(trimmed, from: source, to: target)
                case "api": result = try await api(trimmed, from: source, to: target)
                case "mymemory": result = try await myMemory(trimmed, from: source, to: target)
                default: result = try await google(trimmed, from: source, to: target)
                }
                let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw FreeTranslationError.failed("\(name) 没返回译文") }
                cache[key] = clean
                lastEngine = displayName(name)
                lastErrorText = ""
                failStreak = 0
                saveCacheIfNeeded()
                return clean
            } catch {
                errors.append("\(displayName(name)): \(error.localizedDescription)")
                let msg = error.localizedDescription
                let long = msg.contains("429") || msg.contains("403") || msg.contains("额度") || msg.contains("quota")
                cooldown[name] = Date().addingTimeInterval(long ? 900 : 120)
            }
        }

        lastErrorText = errors.joined(separator: " / ")
        failStreak += 1
        if failStreak >= 5 {
            disabledUntil = Date().addingTimeInterval(600)
            failStreak = 0
        }
        throw FreeTranslationError.failed(lastErrorText.isEmpty ? "翻译通道暂时不可用" : lastErrorText)
    }

    // MARK: - 通道实现

    private func displayName(_ name: String) -> String {
        switch name {
        case "azure": return "Azure"
        case "api": return "自配接口"
        case "mymemory": return "MyMemory"
        case "youdao": return "有道"
        default: return "Google"
        }
    }

    /// Azure 翻译：官方免费层每月 200 万字符，国内可直连，key 在设置里填
    private func azure(_ text: String, from source: String, to target: String) async throws -> String {
        let key = (UserDefaults.standard.string(forKey: "azureKey") ?? "").trimmingCharacters(in: .whitespaces)
        let region = (UserDefaults.standard.string(forKey: "azureRegion") ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw FreeTranslationError.failed("没填 Azure Key") }

        await waitGap(0.4)
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")
        var items = [URLQueryItem(name: "api-version", value: "3.0"),
                     URLQueryItem(name: "to", value: azureTarget(target))]
        if source != "auto" { items.append(URLQueryItem(name: "from", value: LangCode.base(source))) }
        components?.queryItems = items
        guard let url = components?.url else { throw FreeTranslationError.failed("Azure 链接拼装失败") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !region.isEmpty {
            request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FreeTranslationError.failed("Azure 无响应") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FreeTranslationError.failed("Azure Key 无效或 Region 不对")
        }
        if http.statusCode == 429 {
            throw FreeTranslationError.failed("Azure 频率超限 429")
        }
        guard http.statusCode == 200 else {
            throw FreeTranslationError.failed("Azure HTTP \(http.statusCode)")
        }
        guard
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = list.first,
            let trans = first["translations"] as? [[String: Any]],
            let out = trans.first?["text"] as? String
        else { throw FreeTranslationError.failed("Azure 返回无法解析") }
        return out
    }

    /// 自配 OpenAI 兼容接口（DeepSeek / 月之暗面 / 通义 / 硅基流动 / OpenAI 等）
    private func api(_ text: String, from source: String, to target: String) async throws -> String {
        let base = (UserDefaults.standard.string(forKey: "apiBase") ?? "").trimmingCharacters(in: .whitespaces)
        let key = (UserDefaults.standard.string(forKey: "apiKey") ?? "").trimmingCharacters(in: .whitespaces)
        let model = (UserDefaults.standard.string(forKey: "apiModel") ?? "deepseek-chat").trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { throw FreeTranslationError.failed("自配接口没填 Base URL") }

        var urlString = base
        if !urlString.hasSuffix("/chat/completions") {
            if urlString.hasSuffix("/") { urlString.removeLast() }
            urlString += "/chat/completions"
        }
        guard let url = URL(string: urlString) else { throw FreeTranslationError.failed("自配接口链接拼装失败") }

        let targetName = LangCode.name(target)
        let sourceName = source == "auto" ? "源语言" : LangCode.name(source)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let system = "你是专业影视字幕翻译。把下面的\(sourceName)句子翻译成\(targetName)，只输出译文本身，不要解释、不要加引号、不要保留原文。"
        let body: [String: Any] = [
            "model": model.isEmpty ? "deepseek-chat" : model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FreeTranslationError.failed("自配接口无响应") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FreeTranslationError.failed("自配接口 Key 无效或没有权限")
        }
        if http.statusCode == 429 {
            throw FreeTranslationError.failed("自配接口频率超限 429")
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            throw FreeTranslationError.failed("自配接口 HTTP \(http.statusCode) \(snippet)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw FreeTranslationError.failed("自配接口返回无法解析") }

        var clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'『』「」"))
        guard !clean.isEmpty else { throw FreeTranslationError.failed("自配接口没返回译文") }
        return clean
    }

    private func azureTarget(_ raw: String) -> String {
        if raw.hasPrefix("zh") { return raw == "zh-CHT" ? "zh-Hant" : "zh-Hans" }
        return LangCode.base(raw)
    }

    private func myMemory(_ text: String, from source: String, to target: String) async throws -> String {
        await waitGap(1.0)
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(memoryCode(source))|\(memoryCode(target))")
        ]
        guard let url = components?.url else { throw FreeTranslationError.failed("MyMemory 链接拼装失败") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeTranslationError.failed("MyMemory HTTP 异常")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["responseData"] as? [String: Any],
            let translated = payload["translatedText"] as? String
        else { throw FreeTranslationError.failed("MyMemory 返回无法解析") }
        if let quota = json["quotaFinished"] as? Bool, quota {
            throw FreeTranslationError.failed("MyMemory 今日额度用完")
        }
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.lowercased() != text.lowercased() else {
            throw FreeTranslationError.failed("MyMemory 没有有效译文")
        }
        return cleaned
    }

    /// 有道网页版旧接口（不依赖 aidemo 演示服务）
    private func youdaoWeb(_ text: String, from source: String, to target: String) async throws -> String {
        await waitGap(1.4)
        var components = URLComponents(string: "https://fanyi.youdao.com/translate")
        components?.queryItems = [
            URLQueryItem(name: "doctype", value: "json"),
            URLQueryItem(name: "type", value: youdaoType(source, target)),
            URLQueryItem(name: "i", value: text)
        ]
        guard let url = components?.url else { throw FreeTranslationError.failed("有道链接拼装失败") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeTranslationError.failed("有道 HTTP 异常")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["translateResult"] as? [[[String: Any]]]
        else { throw FreeTranslationError.failed("有道返回无法解析") }
        let parts = rows.flatMap { $0 }.compactMap { $0["tgt"] as? String }
        let joined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw FreeTranslationError.failed("有道没返回译文") }
        return joined
    }

    private func youdaoType(_ source: String, _ target: String) -> String {
        guard source != "auto" else { return "AUTO" }
        let from = LangCode.base(source).uppercased()
        let to = target.hasPrefix("zh")
            ? (target == "zh-CHT" || target == "繁体中文" ? "ZH_TW" : "ZH_CN")
            : LangCode.base(target).uppercased()
        return "\(from)2\(to)"
    }

    /// Google 免 key 端点（需要网络能直连 Google）
    private func google(_ text: String, from source: String, to target: String) async throws -> String {
        await waitGap(1.0)
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source == "auto" ? "auto" : LangCode.base(source)),
            URLQueryItem(name: "tl", value: memoryCode(target)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else { throw FreeTranslationError.failed("Google 链接拼装失败") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeTranslationError.failed("Google HTTP 异常")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [Any],
            let sentences = root.first as? [Any]
        else { throw FreeTranslationError.failed("Google 返回无法解析") }
        var joined = ""
        for item in sentences {
            if let row = item as? [Any], let piece = row.first as? String { joined += piece }
        }
        let clean = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw FreeTranslationError.failed("Google 没返回译文") }
        return clean
    }

    // MARK: - 缓存 / 小工具

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = saved
        }
    }

    private func saveCacheIfNeeded() {
        guard !cache.isEmpty else { return }
        if cache.count > 3000 {
            cache = Dictionary(uniqueKeysWithValues: Array(cache).suffix(2000))
        }
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL)
        }
    }

    private func waitGap(_ seconds: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < seconds {
            let wait = UInt64((seconds - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: wait)
        }
        lastRequestAt = Date()
    }

    private func memoryCode(_ raw: String) -> String {
        if raw == "auto" { return "auto" }
        if raw.hasPrefix("zh") {
            return raw == "zh-CHT" ? "zh-TW" : "zh-CN"
        }
        return LangCode.base(raw)
    }
}
