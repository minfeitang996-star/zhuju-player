import Foundation
import Combine

final class SubtitleJob: ObservableObject {

    @Published var status: String = "准备中…"
    @Published var progress: Double = 0
    @Published var errorText: String?
    @Published var finished = false
    @Published var cueCount = 0
    @Published var notice: String?

    private var isRunning = false

    // 所有 UI 状态只在主线程更新
    private func apply(status: String? = nil,
                       progress: Double? = nil,
                       errorText: String? = nil,
                       notice: String? = nil,
                       cueCount: Int? = nil,
                       finished: Bool? = nil) {
        DispatchQueue.main.async {
            if let status = status { self.status = status }
            if let progress = progress { self.progress = progress }
            if let errorText = errorText { self.errorText = errorText }
            if let notice = notice { self.notice = notice }
            if let cueCount = cueCount { self.cueCount = cueCount }
            if let finished = finished { self.finished = finished }
        }
    }

    private func reset() {
        DispatchQueue.main.async {
            self.status = "准备中…"
            self.progress = 0
            self.errorText = nil
            self.notice = nil
            self.finished = false
            self.cueCount = 0
        }
    }

    func run(videoURL: URL,
             modelID: String,
             language: String?,
             translate: Bool) async {

        guard !isRunning else { return }
        isRunning = true

        reset()
        if Prefs.bgConvert {
            BackgroundKeeper.shared.start()
        }
        defer {
            BackgroundKeeper.shared.stop()
            isRunning = false
        }

        do {
            guard let modelURL = ModelManager.shared.localURL(modelID) else {
                apply(status: "模型还没下载", errorText: "先去设置里下载识别模型（推荐 base）")
                return
            }

            apply(status: "加载识别模型…", progress: 0.02)
            let engine = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WhisperEngine, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let shared = try WhisperEngine.shared(modelPath: modelURL.path, fastMode: Prefs.fastASR)
                        continuation.resume(returning: shared)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            var workingURL = videoURL

            apply(status: "检查音轨…", progress: 0.05)
            if !AudioExtractor.probe(url: videoURL) {
                apply(status: "该容器需要先转码音轨…",
                      progress: 0.06,
                      notice: "这格式系统框架打不开，正在用 VLC 内核导出音轨，耗时大致等于视频时长。建议插电放着跑。")
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zhuju_audio.m4a")
                try await transcode(source: videoURL, destination: tmp)
                workingURL = tmp
            }

            apply(status: "识别语音…", progress: 0.15)
            var cues: [SubtitleCue] = []
            var stats = AudioStreamStats()
            (cues, stats) = try await transcribe(videoURL: workingURL,
                                                 engine: engine,
                                                 language: language,
                                                 base: 0.15,
                                                 span: 0.7,
                                                 window: 30,
                                                 skipSilence: true)

            // 第一遍为空，或者绝大部分音轨被静音门限吃掉 → 不跳静音、标准参数整条重跑一次
            if cues.isEmpty || stats.skippedRatio > 0.85 {
                let reason = cues.isEmpty
                    ? "第一遍没出字幕"
                    : "静音过滤跳过了 \(Int(stats.skippedRatio * 100))% 的音轨"
                apply(status: "\(reason)，改用完整音轨重试…", progress: 0.4)
                let fullEngine = (try? WhisperEngine.shared(modelPath: modelURL.path, fastMode: false)) ?? engine
                (cues, stats) = try await transcribe(videoURL: workingURL,
                                                     engine: fullEngine,
                                                     language: language,
                                                     base: 0.4,
                                                     span: 0.42,
                                                     window: 30,
                                                     skipSilence: false)
            }

            guard !cues.isEmpty else {
                let seconds = Int(max(stats.totalSeconds, stats.sentSeconds))
                apply(status: "没识别出内容",
                      errorText: "音轨 \(seconds) 秒已整条送识别，whisper 返回码 \(engine.lastRunCode)、出段数 \(engine.lastSegmentCount)。要么这段确实没人声，要么模型撑不住（建议换 small 再试），要么音轨本身是坏的。")
                return
            }

            apply(cueCount: cues.count)
            var finalCues = Self.dedupe(cues)

            if translate {
                let config = TranslatorConfig.load()
                if config.isUsable {
                    apply(status: "翻译成中文…", progress: 0.85)
                    do {
                        finalCues = try await SubtitleTranslator.translate(
                            finalCues,
                            config: config,
                            onProgress: { value in
                                self.apply(progress: 0.85 + 0.14 * value)
                            },
                            onNotice: { message in
                                self.apply(notice: message)
                            })
                    } catch {
                        apply(notice: "翻译没成功，已先生成原文对照字幕：\(error.localizedDescription)")
                    }
                } else {
                    apply(notice: "没配置翻译接口，已生成原文对照字幕。去设置里填接口就能出中文。")
                }
            }

            apply(status: "写入字幕…", progress: 0.99)
            let destination = videoURL.deletingPathExtension().appendingPathExtension("srt")
            try SubtitleFile.write(finalCues, to: destination)

            apply(status: "完成，共 \(finalCues.count) 条字幕", progress: 1, finished: true)
        } catch {
            apply(status: "失败", errorText: error.localizedDescription)
        }
    }

    // MARK: - 内部步骤

    private func transcode(source: URL, destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ripper = VLCAudioRipper(source: source, destination: destination)
            ripper.start(onProgress: { value in
                self.apply(progress: 0.06 + 0.09 * value)
            }, completion: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func transcribe(videoURL: URL,
                            engine: WhisperEngine,
                            language: String?,
                            base: Double,
                            span: Double,
                            window: Double,
                            skipSilence: Bool) async throws -> ([SubtitleCue], AudioStreamStats) {

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([SubtitleCue], AudioStreamStats), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var cues: [SubtitleCue] = []
                let lock = NSLock()
                do {
                    let stats = try AudioExtractor.stream(from: videoURL, window: window, skipSilence: skipSilence, onWindow: { samples, offset in
                        engine.transcribe(samples: samples, offset: offset, language: language) { cue in
                            lock.lock()
                            cues.append(cue)
                            lock.unlock()
                        }
                    }, onProgress: { value in
                        self.apply(progress: base + span * value)
                    })
                    lock.lock()
                    let snapshot = cues.sorted { $0.start < $1.start }
                    lock.unlock()
                    continuation.resume(returning: (snapshot, stats))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 去掉空段和相邻重复段：whisper 常会把同一句话在相邻窗口里重复输出，
    /// 合并时间轴，避免字幕里出现一堆一模一样的行。
    private static func dedup(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last,
               last.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == text.lowercased() {
                out[out.count - 1].end = max(last.end, cue.end)
                continue
            }
            out.append(SubtitleCue(start: cue.start, end: max(cue.end, cue.start + 0.4), text: text))
        }
        return out
    }
}
