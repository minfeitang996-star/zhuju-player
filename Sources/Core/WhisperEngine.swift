import Foundation
import whisper

/// whisper.cpp 的 Swift 包装。模型常驻内存，按窗口喂 PCM 采样。
final class WhisperEngine {

    private var ctx: OpaquePointer?
    var fastMode: Bool = true
    /// 上一次识别时 whisper 判定的语种（zh / en / ja …）
    private(set) var lastLanguage: String?
    /// 上一次 whisper_full 的返回码（0 成功）与出段数，用于把「识别不出内容」的原因说清楚
    private(set) var lastRunCode: Int32 = -1
    private(set) var lastSegmentCount = 0

    private static var cachePath: String?
    private static var cacheEngine: WhisperEngine?

    /// 同一个模型常驻内存，第二次转不用再加载（省 2~8 秒）
    static func shared(modelPath: String, fastMode: Bool) throws -> WhisperEngine {
        if let engine = cacheEngine, cachePath == modelPath, engine.isLoaded {
            engine.fastMode = fastMode
            return engine
        }
        let engine = WhisperEngine()
        engine.fastMode = fastMode
        try engine.load(modelPath: modelPath)
        cacheEngine = engine
        cachePath = modelPath
        return engine
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func load(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        if let existing = ctx {
            whisper_free(existing)
            ctx = nil
        }
        ctx = whisper_init_from_file_with_params(modelPath, params)
        guard ctx != nil else {
            throw NSError(domain: "ZhuJu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "模型加载失败：\(modelPath)"])
        }
    }

    var isLoaded: Bool { ctx != nil }

    /// language 传 nil 表示自动检测（每窗检测一次）。
    func transcribe(samples: [Float],
                    offset: TimeInterval,
                    language: String?,
                    onCue: (SubtitleCue) -> Void) {

        guard let ctx else { return }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.no_context = true
        params.suppress_blank = true
        params.temperature = 0.0
        // 温度回退必须保留（默认 0.2）：遇到音乐/口音重/音量低的段落时，whisper 会升温度重试，
        // 设成 0 等于「一次不行就放弃」，表现出来就是整段识别为空
        params.temperature_inc = 0.2
        params.detect_language = false
        params.language = nil
        params.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.processorCount)))
        // 注意：不能砍 audio_ctx（曾经设成 768，等于只编码半个窗口，日语直接丢段甚至整段空白）。
        // 提速只靠线程数 + greedy，不用牺牲上下文。
        if fastMode {
            params.n_threads = Int32(max(4, min(6, ProcessInfo.processInfo.processorCount)))
        }
        params.audio_ctx = 0

        let run: (UnsafePointer<CChar>?) -> Int32 = { ptr in
            params.language = ptr
            return samples.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return -1 }
                return whisper_full(ctx, params, base, Int32(buffer.count))
            }
        }

        // 「自动检测」必须真的打开检测：detect_language=false 且 language=nil 时，
        // whisper 会退回按英语识别，日语片就会大量空段甚至整段识别失败。
        // 首窗检测成功后记住语种，后续窗口直接复用，省掉每窗的检测开销（更快）。
        let effectiveLanguage: String?
        if let language, !language.isEmpty {
            effectiveLanguage = language
        } else if let cached = lastLanguage, !cached.isEmpty, lastSegmentCount > 0 {
            effectiveLanguage = cached
        } else {
            effectiveLanguage = nil
        }
        params.detect_language = (effectiveLanguage == nil)

        let code: Int32
        if let effectiveLanguage {
            code = effectiveLanguage.withCString { run($0) }
        } else {
            code = run(nil)
        }

        lastRunCode = code
        guard code == 0 else { return }

        let languageID = whisper_full_lang_id(ctx)
        if languageID >= 0, let name = whisper_lang_str(languageID) {
            lastLanguage = String(cString: name)
        }

        let count = whisper_full_n_segments(ctx)
        lastSegmentCount = count
        guard count > 0 else { return }

        for index in 0..<count {
            let t0 = whisper_full_get_segment_t0(ctx, index)
            let t1 = whisper_full_get_segment_t1(ctx, index)
            guard let cString = whisper_full_get_segment_text(ctx, index) else { continue }
            let text = String(cString: cString)
                .replacingOccurrences(of: "[_BEG_]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count > 1 else { continue }

            let start = offset + Double(t0) / 100.0
            let end = max(start + 0.4, offset + Double(t1) / 100.0)
            onCue(SubtitleCue(start: start, end: end, text: text))
        }
    }
}
