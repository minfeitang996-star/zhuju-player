import SwiftUI
import AVFoundation

/// 单条视频的异步元信息：时长、分辨率；按路径内存缓存。
struct VideoMeta: Equatable {
    var duration: Double?
    var width: Int
    var height: Int
}

final class VideoMetaStore: ObservableObject {
    static let shared = VideoMetaStore()

    @Published var cache: [String: VideoMeta] = [:]
    private var loading = Set<String>()

    private init() {}

    func load(_ url: URL) {
        let key = url.path
        guard cache[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)

        let asset = AVURLAsset(url: url)
        Task {
            var duration: Double?
            var width = 0
            var height = 0

            if let d = try? await asset.load(.duration) {
                duration = d.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                width = Int(abs(size.width))
                height = Int(abs(size.height))
            }

            let meta = VideoMeta(duration: duration, width: width, height: height)
            await MainActor.run {
                self.cache[key] = meta
                self.loading.remove(key)
            }
        }
    }

    static func durationText(_ sec: Double) -> String {
        let total = max(0, Int(sec.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func resolutionText(w: Int, h: Int) -> String? {
        guard h > 0 else { return nil }
        switch h {
        case 2160...: return "4K"
        case 1440...: return "2K"
        case 1080...: return "1080P"
        case 720...: return "720P"
        case 480...: return "480P"
        default: return "\(w)×\(h)"
        }
    }
}
