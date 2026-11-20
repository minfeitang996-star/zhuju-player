import Foundation
import AVFoundation
import Combine

struct LiveCue: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var original: String
    var translated: String?
}

/// 边看边译：直接读视频文件的音轨，边读边识别翻译，按播放进度显示字幕。
/// 不走麦克风，音质是文件原始音轨，没有回声。
final class LiveSubtitleEngine: ObservableObject {

    @Published var cues: [LiveCue] = []
    @Published var status = ""
    @Published var running = false

    private var stopFlag = false
    private var playhead: () -> Double = { 0 }
    private let queue = DispatchQueue(label: "zhuju.livesub.pipe", qos: .userInitiated)

    private let chunkSeconds: Double = 6

    private var startOffset: Double = 0

    func start(videoURL: URL, modelPath: String, from: Double = 0, playhead: @escaping () -> Double) {
        guard !running else { return }
        running = true
        stopFlag = false
        cues = []
        status = "准备中…"
        startOffset = max(0, from - 2)
        self.playhead = playhead

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let engine = try WhisperEngine.shared(modelPath: modelPath, fastMode: true)
                DispatchQueue.main.async { self.status = "边看边译中" }
                try self.pipeline(engine: engine, url: videoURL)
                DispatchQueue.main.async {
                    if !self.stopFlag {
                        self.status = self.cues.isEmpty
                            ? "跑完了但没识别到语音（这段可能是纯音乐）"
                            : "本片已全部译完"
                    }
                    self.running = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = error.localizedDescription
                    self.running = false
                }
            }
        }
    }

    func stop() {
        stopFlag = true
        running = false
    }

    // MARK: - 主流程

    private func pipeline(engine: WhisperEngine, url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioError.unreadable("这个容器的音轨系统解不了，实时翻译只支持 mp4 / mov / m4v。mkv、avi 请用「生成字幕」。")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let begin = max(0, startOffset)
        if begin > 1 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: begin, preferredTimescale: 1000),
                                           duration: .positiveInfinity)
        }
        reader.startReading()

        let windowSamples = Int(chunkSeconds * 16_000)
        var buffer: [Float] = []
        var windowStart: Double = begin

        while reader.status == .reading && !stopFlag {
            // 只跑到播放位置后面 40 秒，不提前把整部片算完；
            // 播放位置拿不到时（head<=1）不阻塞，先继续读
            var guardCount = 0
            while !stopFlag {
                let head = playhead()
                if head <= 1 || head + 40 >= windowStart { break }
                guardCount += 1
                if guardCount > 400 { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if stopFlag { reader.cancelReading(); return }

            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let floats = AudioExtractor.floats(from: sampleBuffer) {
                buffer.append(contentsOf: floats)
            }

            while buffer.count >= windowSamples {
                let slice = Array(buffer[0..<windowSamples])
                buffer.removeFirst(windowSamples)
                let start = windowStart
                windowStart += chunkSeconds
                if AudioExtractor.isSilent(slice) { continue }
                if stopFlag { reader.cancelReading(); return }
                recognize(engine: engine, slice: slice, start: start)
            }
        }

        if reader.status == .failed {
            throw AudioError.failed(reader.error?.localizedDescription ?? "音轨读取失败")
        }
    }

    private func recognize(engine: WhisperEngine, slice: [Float], start: Double) {
        var parts: [SubtitleCue] = []
        let lock = NSLock()
        engine.transcribe(samples: slice, offset: start, language: nil) { cue in
            lock.lock()
            parts.append(cue)
            lock.unlock()
        }

        lock.lock()
        let recognized = parts
        lock.unlock()
        guard !recognized.isEmpty else { return }

        let original = recognized.map { $0.text }.joined(separator: " ")
        let begin = recognized.first?.start ?? start
        let finish = max(recognized.last?.end ?? start + chunkSeconds, begin + 1.6)
        let cue = LiveCue(start: begin, end: finish, original: original, translated: nil)

        DispatchQueue.main.async {
            self.cues.append(cue)
        }

        let config = TranslatorConfig.load()
        guard config.isUsable else {
            DispatchQueue.main.async { self.status = "没配翻译接口，只显示原文" }
            return
        }

        // 原片就是中文、目标也是中文，就不用再翻译一遍，省时间也更干净
        if engine.lastLanguage == "zh" && Prefs.translateTarget.contains("中文") {
            DispatchQueue.main.async { self.status = "原片是中文，直接显示原文" }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await SubtitleTranslator.translate(recognized, config: config, onProgress: { _ in })
                let joined = translated.map { $0.text }.joined(separator: " ")
                DispatchQueue.main.async {
                    if let index = self.cues.firstIndex(where: { $0.id == cue.id }) {
                        self.cues[index].translated = joined
                    }
                }
            } catch {
                // 翻译失败就保留原文，不影响观看
            }
        }
    }
}
