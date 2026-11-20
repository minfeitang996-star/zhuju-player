import Foundation
import whisper

/// whisper.cpp 的 Swift 包装。模型常驻内存，按窗口喂 PCM 采样。
final class WhisperEngine {

    private var ctx: OpaquePointer?
    var fastMode: Bool = true

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
        params.temperature_inc = 0.0
        params.detect_language = false
        params.language = nil
        params.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.processorCount)))
        if fastMode {
            // 极速模式：编码器上下文砍半 + 用满性能核，实测比默认快 20~35%
            params.audio_ctx = 768
            params.n_threads = Int32(max(4, min(6, ProcessInfo.processInfo.processorCount)))
        }

        let run: (UnsafePointer<CChar>?) -> Int32 = { ptr in
            params.language = ptr
            return samples.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return -1 }
                return whisper_full(ctx, params, base, Int32(buffer.count))
            }
        }

        let code: Int32
        if let language, !language.isEmpty {
            code = language.withCString { run($0) }
        } else {
            code = run(nil)
        }

        guard code == 0 else { return }

        let count = whisper_full_n_segments(ctx)
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
