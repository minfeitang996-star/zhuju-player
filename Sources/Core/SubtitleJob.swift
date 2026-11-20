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
            let cues = try await transcribe(videoURL: workingURL,
                                            engine: engine,
                                            language: language,
                                            base: 0.15,
                                            span: 0.7)

            guard !cues.isEmpty else {
                apply(status: "没识别出内容",
                      errorText: "这段视频里没有可识别的语音，或者模型太小没撑住，换个更大的模型再试")
                return
            }

            apply(cueCount: cues.count)
            var finalCues = cues

            if translate {
                let config = TranslatorConfig.load()
                if config.isUsable {
                    apply(status: "翻译成中文…", progress: 0.85)
                    do {
                        finalCues = try await SubtitleTranslator.translate(cues, config: config) { value in
                            self.apply(progress: 0.85 + 0.14 * value)
                        }
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
                            span: Double) async throws -> [SubtitleCue] {

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SubtitleCue], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var cues: [SubtitleCue] = []
                let lock = NSLock()
                do {
                    try AudioExtractor.stream(from: videoURL, window: 50, skipSilence: true, onWindow: { samples, offset in
                        engine.transcribe(samples: samples, offset: offset, language: language) { cue in
                            lock.lock()
                            cues.append(cue)
                            lock.unlock()
                        }
                    }, onProgress: { value in
                        self.apply(progress: base + span * value)
                    })
                    lock.lock()
                    let snapshot = cues
                    lock.unlock()
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
