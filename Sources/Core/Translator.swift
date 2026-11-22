import Foundation

struct TranslatorConfig {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var targetLanguage: String
    /// auto（有 Key 就用自己的，没有就走免费通道）/ free（只用免费通道）/ api（只用自配接口）
    var engine: String

    static func load() -> TranslatorConfig {
        let defaults = UserDefaults.standard
        return TranslatorConfig(
            enabled: defaults.object(forKey: "translateEnabled") as? Bool ?? true,
            baseURL: defaults.string(forKey: "apiBase") ?? "",
            apiKey: defaults.string(forKey: "apiKey") ?? "",
            model: defaults.string(forKey: "apiModel") ?? "deepseek-chat",
            targetLanguage: Prefs.translateTarget,
            engine: Prefs.translateEngine
        )
    }

    var isUsable: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 这次翻译走不走自配接口；不走就用内置免密钥通道（有道 / MyMemory）
    var useAPI: Bool {
        guard enabled, engine != "free" else { return false }
        return isUsable
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
                          onProgress: @escaping (Double) -> Void,
                          onNotice: ((String) -> Void)? = nil) async throws -> [SubtitleCue] {

        // 没配自配接口、或用户选了免费通道 → 走内置免密钥翻译，不报「未配置」
        if !config.useAPI {
            return await translateFree(cues, target: config.targetLanguage, onProgress: onProgress)
        }

        var output = cues
        let total = max(1, cues.count)
        let starts = stride(from: 0, to: cues.count, by: batchSize).map { $0 }
        guard !starts.isEmpty else { return output }

        var done = 0
        var failedBatches = 0
        var lastMessage = ""
        let maxParallel = 2

        try await withThrowingTaskGroup(of: (Int, Int, [String]?, String?).self) { group in
            var nextIndex = 0
            var active = 0

            while nextIndex < starts.count && active < maxParallel {
                let start = starts[nextIndex]
                let end = min(start + batchSize, cues.count)
                let slice = Array(cues[start..<end])
                group.addTask {
                    do {
                        let lines = try await request(slice, config: config)
                        return (start, end, lines, nil)
                    } catch {
                        return (start, end, nil, error.localizedDescription)
                    }
                }
                nextIndex += 1
                active += 1
            }

            while let (start, end, lines, message) = try await group.next() {
                active -= 1

                if let lines {
                    for (offset, text) in lines.enumerated() where start + offset < output.count {
                        if !text.isEmpty { output[start + offset].text = text }
                    }
                } else {
                    failedBatches += 1
                    lastMessage = message ?? "翻译接口没有返回结果"
                }

                done += (end - start)
                onProgress(Double(min(done, total)) / Double(total))

                if nextIndex < starts.count {
                    let nextStart = starts[nextIndex]
                    let nextEnd = min(nextStart + batchSize, cues.count)
                    let slice = Array(cues[nextStart..<nextEnd])
                    group.addTask {
                        do {
                            let lines = try await request(slice, config: config)
                            return (nextStart, nextEnd, lines, nil)
                        } catch {
                            return (nextStart, nextEnd, nil, error.localizedDescription)
                        }
                    }
                    nextIndex += 1
                    active += 1
                }
            }
        }

        if failedBatches == starts.count {
            throw TranslatorError.http(-1, lastMessage.isEmpty ? "全部批次都失败" : lastMessage)
        } else if failedBatches > 0 {
            onNotice?("有 \(failedBatches) 段没翻成，已保留原文：\(lastMessage)")
        }

        return output
    }

    /// 免密钥通道：逐条翻，单条失败保留原文，不中断整批
    private static func translateFree(_ cues: [SubtitleCue],
                                      target: String,
                                      onProgress: @escaping (Double) -> Void) async -> [SubtitleCue] {
        var output = cues
        let total = max(1, cues.count)
        var consecutiveFailures = 0

        for index in cues.indices {
            if Task.isCancelled { break }
            // 在线通道已经连续挂了就直接停，别让整批卡在超时里
            if consecutiveFailures >= 3 { break }
            let text = cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                do {
                    let translated = try await TranslationHub.shared.translate(text, source: "auto", target: LangCode.code(for: target))
                    if !translated.isEmpty {
                        output[index].text = translated
                        consecutiveFailures = 0
                    }
                } catch {
                    consecutiveFailures += 1
                }
            }
            onProgress(Double(index + 1) / Double(total))
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
