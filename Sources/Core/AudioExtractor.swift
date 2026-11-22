import Foundation
import AVFoundation
import MobileVLCKit

enum AudioError: LocalizedError {
    case noAudioTrack
    case unreadable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "这个文件里没有可识别的音轨"
        case .unreadable(let detail):
            return detail
        case .failed(let detail):
            return detail
        }
    }
}

/// 音轨抽取统计：总时长 / 真正送进识别的时长 / 被静音门限跳过的时长
struct AudioStreamStats {
    var totalSeconds: Double = 0
    var sentSeconds: Double = 0
    var skippedSeconds: Double = 0

    var skippedRatio: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1.0, skippedSeconds / totalSeconds)
    }
}

/// 把视频音轨解码成 16k 单声道 Float PCM，按窗口回调给识别引擎。
enum AudioExtractor {

    static let sampleRate: Double = 16_000

    /// 轻量探测：AVFoundation 能不能直接读到音轨。
    static func probe(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return !asset.tracks(withMediaType: .audio).isEmpty
    }

    /// 直接用 AVFoundation 读取（mp4/mov/m4v/3gp/mp3 等），速度快。
    @discardableResult
    static func stream(from url: URL,
                       window: Double = 30,
                       skipSilence: Bool = true,
                       onWindow: ([Float], TimeInterval) -> Void,
                       onProgress: (Double) -> Void) throws -> AudioStreamStats {

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioError.noAudioTrack
        }

        let totalSeconds = CMTimeGetSeconds(asset.duration)
        let reader = try AVAssetReader(asset: asset)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let windowSamples = Int(window * sampleRate)
        var buffer: [Float] = []
        var windowStart: TimeInterval = 0
        var stats = AudioStreamStats(totalSeconds: max(0, totalSeconds))

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let floats = floats(from: sampleBuffer) {
                buffer.append(contentsOf: floats)
            }
            while buffer.count >= windowSamples {
                let slice = Array(buffer[0..<windowSamples])
                buffer.removeFirst(windowSamples)
                if !(skipSilence && isSilent(slice)) {
                    onWindow(slice, windowStart)
                    stats.sentSeconds += window
                } else {
                    stats.skippedSeconds += window
                }
                windowStart += Double(windowSamples) / sampleRate
                if totalSeconds > 0 {
                    onProgress(min(1.0, windowStart / totalSeconds))
                }
            }
        }

        if !buffer.isEmpty {
            let tailSeconds = Double(buffer.count) / sampleRate
            if !(skipSilence && isSilent(buffer)) {
                onWindow(buffer, windowStart)
                stats.sentSeconds += tailSeconds
            } else {
                stats.skippedSeconds += tailSeconds
            }
            windowStart += tailSeconds
        }

        if reader.status == .failed {
            throw AudioError.failed(reader.error?.localizedDescription ?? "音频读取失败")
        }
        if totalSeconds > 0 {
            onProgress(1.0)
        }
        return stats
    }

    /// 静音/纯底噪：低于 -54 dBFS 就不送识别了，能省掉大段无对白的计算。
    /// 门限别调高：不少片子整体音量小，门限一高会把整段对白当静音丢掉（曾经就是这样整片识别为空）。
    static func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var energy: Float = 0
        for value in samples { energy += value * value }
        let rms = (energy / Float(samples.count)).squareRoot()
        return rms < 0.002
    }

    /// 峰值是否低到不像有声音（中文/日语片偶尔整体音量极低）
    static func peak(_ samples: [Float]) -> Float {
        var maxValue: Float = 0
        for value in samples { maxValue = max(maxValue, abs(value)) }
        return maxValue
    }

    static func floats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        return data.withUnsafeBytes { raw -> [Float] in
            let count = length / MemoryLayout<Float>.size
            let pointer = raw.bindMemory(to: Float.self)
            return Array(pointer.prefix(count))
        }
    }
}

private var activeRipper: VLCAudioRipper?

/// MKV / AVI / RMVB 这类容器 AVFoundation 打不开，
/// 用 VLC 内核把音轨转成 m4a 再交给识别引擎。转码按播放速度进行，耗时约等于片长。
final class VLCAudioRipper: NSObject {


    private let source: URL
    private let destination: URL
    private let player = VLCMediaPlayer()
    private var timer: Timer?
    private var started = false
    private var completion: ((Error?) -> Void)?
    private var progressHandler: ((Double) -> Void)?

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
        super.init()
    }

    func start(onProgress: @escaping (Double) -> Void,
               completion: @escaping (Error?) -> Void) {
        self.progressHandler = onProgress
        self.completion = completion
        activeRipper = self

        try? FileManager.default.removeItem(at: destination)

        let media = VLCMedia(url: source)
        media.addOption(":sout=#transcode{acodec=mp4a,ab=64,channels=1,samplerate=16000,vcodec=none}:std{access=file,mux=mp4,dst=\(destination.path)}")
        media.addOption(":sout-keep")
        player.media = media
        player.play()

        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.player.isPlaying {
                self.started = true
                let length = self.player.media?.length.intValue ?? 0
                let current = self.player.time.intValue
                if length > 0 {
                    self.progressHandler?(min(1.0, Double(current) / Double(length)))
                }
            } else if self.started {
                self.finish(nil)
            }
        }
    }

    func cancel() {
        finish(NSError(domain: "ZhuJu", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "已取消转码"]))
    }

    private func finish(_ error: Error?) {
        timer?.invalidate()
        timer = nil
        player.stop()

        var producedSize: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let number = attributes[FileAttributeKey.size] as? NSNumber {
            producedSize = number.int64Value
        }

        let callback = completion
        completion = nil
        progressHandler = nil
        activeRipper = nil

        guard let callback = callback else { return }

        if let error = error {
            callback(error)
        } else if producedSize > 0 {
            callback(nil)
        } else {
            callback(AudioError.failed("VLC 没能导出音轨，这个文件可能没有可用音频"))
        }
    }
}
