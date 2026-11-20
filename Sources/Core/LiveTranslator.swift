import Foundation
import AVFoundation
import Combine

struct LiveLine: Identifiable {
    let id = UUID()
    var original: String
    var translated: String?
}

/// 实时同传：麦克风拾音 → 分段送 whisper → 翻译 → 滚动显示。
/// 延迟约 4~8 秒一段，这是离线识别的物理下限。
final class LiveTranslator: ObservableObject {

    @Published var lines: [LiveLine] = []
    @Published var running = false
    @Published var status = "点开始，把手机对着外放或者放进兜里都行"
    @Published var level: Double = 0

    private let engine = AVAudioEngine()
    private var chunkQueue = DispatchQueue(label: "zhuju.live.chunk", qos: .userInitiated)

    private let targetRate: Double = 16_000
    private let chunkSeconds: Double = 8
    private let hopSeconds: Double = 6

    private var pending: [Float] = []
    private let lock = NSLock()
    private var consumed: Double = 0          // 已处理到第几秒
    private var busy = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private var whisper: WhisperEngine?
    private var language: String?

    func start(modelPath: String, language: String?) {
        guard !running else { return }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1) else {
            status = "音频格式初始化失败"
            return
        }
        targetFormat = format

        requestMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "没给麦克风权限，去设置里打开" }
                return
            }
            self.bootstrap(modelPath: modelPath, language: language, format: format)
        }
    }

    private func requestMic(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    private func bootstrap(modelPath: String, language: String?, format: AVAudioFormat) {
        lock.lock()
        pending.removeAll()
        consumed = 0
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let engine: WhisperEngine
            do {
                engine = try WhisperEngine.shared(modelPath: modelPath, fastMode: true)
            } catch {
                DispatchQueue.main.async { self.status = "模型加载失败：\(error.localizedDescription)" }
                return
            }
            self.whisper = engine
            self.language = language
            DispatchQueue.main.async { self.beginAudio(format: format) }
        }
    }

    private func beginAudio(format: AVAudioFormat) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let inFormat = input.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else {
                status = "没找到可用的麦克风"
                return
            }
            converter = AVAudioConverter(from: inFormat, to: format)

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                self?.handleInput(buffer)
            }

            engine.prepare()
            try engine.start()

            running = true
            status = "正在听，说话吧（每 6 秒出一段）"
        } catch {
            status = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        status = "已停止"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clear() {
        lines.removeAll()
    }

    // MARK: - 音频处理

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: out, error: &error) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if let error {
            NSLog("ZhuJu live.convert failed \(error)")
            return
        }
        guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)

        var energy: Float = 0
        for index in 0..<count {
            let value = channel[index]
            energy += value * value
        }
        let rms = Double((energy / Float(count)).squareRoot())
        DispatchQueue.main.async { self.level = rms }

        lock.lock()
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        let chunkSamples = Int(chunkSeconds * targetRate)
        let enough = pending.count >= chunkSamples
        let slice: [Float]
        let offset: Double
        if enough {
            slice = Array(pending[0..<chunkSamples])
            let hopSamples = Int(hopSeconds * targetRate)
            pending.removeFirst(min(hopSamples, pending.count))
            offset = consumed
            consumed += hopSeconds
        } else {
            slice = []
            offset = 0
        }
        lock.unlock()

        guard enough, !slice.isEmpty else { return }
        guard !AudioExtractor.isSilent(slice) else { return }

        lock.lock()
        let alreadyBusy = busy
        if !alreadyBusy { busy = true }
        lock.unlock()
        guard !alreadyBusy else { return }

        chunkQueue.async { [weak self] in
            self?.process(slice: slice, offset: offset)
        }
    }

    private func process(slice: [Float], offset: Double) {
        defer {
            lock.lock()
            busy = false
            lock.unlock()
        }
        guard let whisper else { return }

        var cues: [SubtitleCue] = []
        let collectLock = NSLock()
        whisper.transcribe(samples: slice, offset: offset, language: language) { cue in
            collectLock.lock()
            cues.append(cue)
            collectLock.unlock()
        }

        let text = cues.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count > 1 else { return }

        DispatchQueue.main.async {
            self.status = "识别中…"
        }

        let config = TranslatorConfig.load()
        if config.isUsable {
            Task { [weak self] in
                guard let self else { return }
                var translated: String?
                do {
                    let translatedCues = try await SubtitleTranslator.translate(cues, config: config, onProgress: { _ in })
                    let joined = translatedCues.map { $0.text }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    translated = joined.isEmpty ? nil : joined
                } catch {
                    translated = nil
                }
                DispatchQueue.main.async {
                    self.lines.append(LiveLine(original: text, translated: translated))
                    if self.lines.count > 40 { self.lines.removeFirst(self.lines.count - 40) }
                    self.status = "正在听，说话吧（每 6 秒出一段）"
                }
            }
        } else {
            DispatchQueue.main.async {
                self.lines.append(LiveLine(original: text, translated: nil))
                if self.lines.count > 40 { self.lines.removeFirst(self.lines.count - 40) }
                self.status = "没配翻译接口，只显示原文"
            }
        }
    }
}
