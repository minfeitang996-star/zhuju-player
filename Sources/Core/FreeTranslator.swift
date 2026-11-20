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

/// 免密钥在线翻译：有道（国内直连，优先）+ MyMemory（备用）。
/// 不需要用户填任何 API Key，装上就能把日语/英语片译成中文。
actor TranslationHub {

    static let shared = TranslationHub()

    private var cache: [String: String] = [:]
    private var lastRequestAt = Date.distantPast
    private var youdaoCooldownUntil = Date.distantPast
    private(set) var lastEngine = ""

    func currentEngine() -> String { lastEngine }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if LangCode.isSame(source, target) { return trimmed }

        let key = "\(source)|\(target)|\(trimmed)"
        if let hit = cache[key] { return hit }

        var lastError: Error = FreeTranslationError.failed("翻译通道暂时不可用")

        if Date() >= youdaoCooldownUntil {
            do {
                let result = try await youdao(trimmed, from: source, to: target)
                cache[key] = result
                lastEngine = "有道"
                return result
            } catch {
                lastError = error
                // 有道有频率限制，出错后冷却 90 秒，期间全走备用通道
                youdaoCooldownUntil = Date().addingTimeInterval(90)
            }
        }

        do {
            let result = try await myMemory(trimmed, from: source, to: target)
            cache[key] = result
            lastEngine = "MyMemory"
            return result
        } catch {
            lastError = error
        }

        throw lastError
    }

    // MARK: - 通道实现

    private func youdao(_ text: String, from source: String, to target: String) async throws -> String {
        await waitGap(1.4)

        var components = URLComponents(string: "https://aidemo.youdao.com/trans")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: youdaoCode(source)),
            URLQueryItem(name: "to", value: youdaoCode(target))
        ]
        guard let url = components?.url else {
            throw FreeTranslationError.failed("有道链接拼装失败")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeTranslationError.failed("有道返回异常")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FreeTranslationError.failed("有道返回无法解析")
        }

        let code = String(describing: json["errorCode"] ?? "")
        guard code == "0" || code == "Optional(0)" else {
            throw FreeTranslationError.failed("有道 errorCode=\(code)")
        }

        var parts: [String] = []
        if let list = json["translation"] as? [String] {
            parts = list
        } else if let single = json["translation"] as? String {
            parts = [single]
        }
        let joined = parts.joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw FreeTranslationError.failed("有道没返回译文")
        }
        return joined
    }

    private func myMemory(_ text: String, from source: String, to target: String) async throws -> String {
        await waitGap(1.0)

        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(memoryCode(source))|\(memoryCode(target))")
        ]
        guard let url = components?.url else {
            throw FreeTranslationError.failed("备用通道链接拼装失败")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeTranslationError.failed("备用通道返回异常")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["responseData"] as? [String: Any],
            let translated = payload["translatedText"] as? String
        else {
            throw FreeTranslationError.failed("备用通道返回无法解析")
        }
        if let quota = json["quotaFinished"] as? Bool, quota {
            throw FreeTranslationError.failed("备用通道今日额度用完")
        }
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.lowercased() != text.lowercased() else {
            throw FreeTranslationError.failed("备用通道没有返回有效译文")
        }
        return cleaned
    }

    // MARK: - 小工具

    private func waitGap(_ seconds: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < seconds {
            let wait = UInt64((seconds - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: wait)
        }
        lastRequestAt = Date()
    }

    private func youdaoCode(_ raw: String) -> String {
        if raw == "auto" { return "auto" }
        if raw.hasPrefix("zh") {
            return raw == "zh-CHT" || raw == "繁体中文" ? "zh-CHT" : "zh-CHS"
        }
        return LangCode.base(raw)
    }

    private func memoryCode(_ raw: String) -> String {
        if raw == "auto" { return "auto" }
        if raw.hasPrefix("zh") {
            return raw == "zh-CHT" ? "zh-TW" : "zh-CN"
        }
        return LangCode.base(raw)
    }
}
