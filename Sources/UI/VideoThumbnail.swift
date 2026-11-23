import SwiftUI
import AVFoundation

/// 列表视频首帧缩略图：异步生成，结果按文件名做内存缓存；生成失败回退默认图标。
struct VideoThumbnail: View {

    let url: URL
    @State private var image: UIImage?

    private static var cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(width: 46, height: 46)
        .onAppear { load() }
    }

    private func load() {
        let key = url.lastPathComponent as NSString
        if let hit = Self.cache.object(forKey: key) {
            image = hit
            return
        }
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 180)
            let candidates = [
                CMTime(seconds: 0.5, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600),
                .zero
            ]
            for time in candidates {
                if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                    let ui = UIImage(cgImage: cg)
                    Self.cache.setObject(ui, forKey: key)
                    await MainActor.run { image = ui }
                    return
                }
            }
        }
    }
}
