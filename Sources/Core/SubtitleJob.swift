import Foundation
import Combine

@MainActor
final class SubtitleJob: ObservableObject {

    @Published var status: String = "准备中…"
    @Published var progress: Double = 0
    @Published var errorText: String?
    @Published var finished = false
    @Published var cueCount = 0
    @Published var notice: String?

    private var isRunning = false

    func run(videoURL: URL,
             modelID: String,
             language: String?,
             translate: Bool) async {

        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        errorText = nil
        notice = nil
        finished = false
        cueCount = 0
        progress = 0

        do {
            guard let modelURL = ModelManager.shared.localURL(modelID) else {
                status = "模型还没下载"
                errorText = "先去设置里下载识别模型（推荐 base）"
                return
            }

            status = "加载识别模型…"
            let engine = WhisperEngine()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try engine.load(modelPath: modelURL.path)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            var workingURL = videoURL

            status = "检查音轨…"
            if !AudioExtractor.probe(url: videoURL) {
                status = "该容器需要先转码音轨…"
                notice = "这格式 AVFoundation 打不开，正在用 VLC 内核导出音轨，耗时大致等于视频时长。建议插电放着跑。"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zhuju_audio.m4a")
                try await transcode(source: videoURL, destination: tmp)
                workingURL = tmp
            }

            status = "识别语音…"
            let cues = try await transcribe(videoURL: workingURL,
                                            engine: engine,
                                            language: language,
                                            base: 0.15,
                                            span: 0.7)

            guard !cues.isEmpty else {
                status = "没识别出内容"
                errorText = "这段视频里没有可识别的语音，或者模型太小没撑住，换个更大的模型再试"
                return
            }

            cueCount = cues.count
            var finalCues = cues

            if translate {
                let config = TranslatorConfig.load()
                if config.isUsable {
                    status = "翻译成中文…"
                    do {
                        finalCues = try await SubtitleTranslator.translate(cues, config: config) { value in
                            Task { @MainActor in
                                self.progress = 0.85 + 0.14 * value
                            }
                        }
                    } catch {
                        notice = "翻译没成功，已先生成原文对照字幕：\(error.localizedDescription)"
                    }
                } else {
                    notice = "没配置翻译接口，已生成原文对照字幕。去设置填接口就能出中文。"
                }
            }

            status = "写入字幕…"
            let destination = videoURL.deletingPathExtension().appendingPathExtension("srt")
            try SubtitleFile.write(finalCues, to: destination)

            progress = 1
            finished = true
            status = "完成，共 \(finalCues.count) 条字幕"
        } catch {
            status = "失败"
            errorText = error.localizedDescription
        }
    }

    // MARK: - 内部步骤

    private func transcode(source: URL, destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ripper = VLCAudioRipper(source: source, destination: destination)
            ripper.start(onProgress: { value in
                Task { @MainActor in
                    self.progress = 0.05 + 0.10 * value
                }
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
                    try AudioExtractor.stream(from: videoURL, window: 50, onWindow: { samples, offset in
                        engine.transcribe(samples: samples, offset: offset, language: language) { cue in
                            lock.lock()
                            cues.append(cue)
                            lock.unlock()
                        }
                    }, onProgress: { value in
                        Task { @MainActor in
                            self.progress = base + span * value
                        }
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
