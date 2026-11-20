import Foundation
import AVFoundation

/// 后台保活：循环播放一段静音，让 App 在后台不被挂起，识别任务得以继续跑。
final class BackgroundKeeper {

    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var running = false

    func start() {
        guard !running else { return }
        guard let url = Self.silentFileURL() else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            running = true
            NSLog("ZhuJu bg.keeper.start")
        } catch {
            NSLog("ZhuJu bg.keeper.start failed \(error)")
        }
    }

    func stop() {
        guard running else { return }
        player?.stop()
        player = nil
        running = false
        NSLog("ZhuJu bg.keeper.stop")
    }

    private static func silentFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zhuju_keeper.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let rate: UInt32 = 8000
        let dataSize = Int(rate) * 2

        var data = Data()
        data.append(ascii("RIFF"))
        data.append(uint32(UInt32(36 + dataSize)))
        data.append(ascii("WAVE"))
        data.append(ascii("fmt "))
        data.append(uint32(16))
        data.append(uint16(1))
        data.append(uint16(1))
        data.append(uint32(rate))
        data.append(uint32(rate * 2))
        data.append(uint16(2))
        data.append(uint16(16))
        data.append(ascii("data"))
        data.append(uint32(UInt32(dataSize)))
        data.append(Data(count: dataSize))

        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("ZhuJu bg.keeper.wav failed \(error)")
            return nil
        }
    }

    private static func ascii(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF),
              UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF),
              UInt8((value >> 24) & 0xFF)])
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
