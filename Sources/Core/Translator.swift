import Foundation

struct TranslatorConfig {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var targetLanguage: String

    static func load() -> TranslatorConfig {
        let defaults = UserDefaults.standard
        return TranslatorConfig(
            enabled: defaults.object(forKey: "translateEnabled") as? Bool ?? true,
            baseURL: defaults.string(forKey: "apiBase") ?? "",
            apiKey: defaults.string(forKey: "apiKey") ?? "",
            model: defaults.string(forKey: "apiModel") ?? "deepseek-chat",
            targetLanguage: Prefs.translateTarget
        )
    }

    var isUsable: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum TranslatorError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没配置翻译接口，去设置里填 Base URL、模型名和 API Key"
        case .http(let code, let body):
            return "翻译接口返回 \(code)：\(body.prefix(120))"
        case .badResponse:
            return "翻译接口返回内容无法解析"
        }
    }
}

enum SubtitleTranslator {

    private static let batchSize = 8

    static func translate(_ cues: [SubtitleCue],
                          config: TranslatorConfig,
                          onProgress: @escaping (Double) -> Void) async throws -> [SubtitleCue] {

        guard config.isUsable else { throw TranslatorError.notConfigured }

        var output = cues
        let total = max(1, cues.count)
        var done = 0

        while done < cues.count {
            let end = min(done + batchSize, cues.count)
            let batch = Array(cues[done..<end])
            let translated = try await request(batch, config: config)

            for (offset, text) in translated.enumerated() where done + offset < output.count {
                if !text.isEmpty {
                    output[done + offset].text = text
                }
            }

            done = end
            onProgress(Double(done) / Double(total))
        }

        return output
    }

    private static func request(_ cues: [SubtitleCue], config: TranslatorConfig) async throws -> [String] {

        var urlString = config.baseURL.trimmingCharacters(in: .whitespaces)
        if !urlString.hasSuffix("/chat/completions") {
            if urlString.hasSuffix("/") { urlString.removeLast() }
            urlString += "/chat/completions"
        }
        guard let url = URL(string: urlString) else { throw TranslatorError.badResponse }

        let system = """
        你是专业影视字幕翻译。把用户给出的字幕逐条翻译成\(config.targetLanguage)。\
        保持条数与编号一一对应，不要合并、不要拆分、不要解释。\
        只输出结果，每行格式：编号|译文。不要输出任何多余文字。
        """

        let user = cues.enumerated().map { "\($0.offset + 1)|\($0.element.text)" }.joined(separator: "\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = TranslatorError.badResponse
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw TranslatorError.badResponse }
                if http.statusCode != 200 {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    lastError = TranslatorError.http(http.statusCode, text)
                    if http.statusCode == 429 || http.statusCode >= 500 {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    }
                    throw lastError
                }

                guard
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let message = choices.first?["message"] as? [String: Any],
                    let content = message["content"] as? String
                else { throw TranslatorError.badResponse }

                let lines = parse(content)
                if lines.count >= cues.count { return Array(lines.prefix(cues.count)) }
                if lines.count < cues.count, !lines.isEmpty { return lines }
                throw TranslatorError.badResponse
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        throw lastError
    }

    private static func parse(_ content: String) -> [String] {
        var map: [Int: String] = [:]
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            var digits = ""
            var index = line.startIndex
            while index < line.endIndex, line[index].isNumber {
                digits.append(line[index])
                index = line.index(after: index)
            }
            guard let number = Int(digits), number > 0 else { continue }

            var rest = String(line[index...])
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t|｜:：.、)】"))
            guard !rest.isEmpty else { continue }
            map[number - 1] = rest
        }

        guard let maxIndex = map.keys.max() else { return [] }
        return (0...maxIndex).map { map[$0] ?? "" }
    }
}
