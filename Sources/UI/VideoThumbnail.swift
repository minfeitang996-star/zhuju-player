import SwiftUI
import AVFoundation

/// 列表/网格视频首帧缩略图：异步生成，结果按文件名做内存缓存；生成失败回退默认图标。
/// width 传 nil 时按可用宽度铺满（网格封面墙用），高度固定；外层统一裁剪，图片不会溢出盒子。
struct VideoThumbnail: View {

    let url: URL
    var width: CGFloat? = 62
    var height: CGFloat = 46
    var cornerRadius: CGFloat = 12
    @State private var image: UIImage?

    private static var cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// 正在抽帧的文件名，避免列表滚动/重组时同一个视频重复起后台任务
    private static var inFlight = Set<NSString>()
    private static let inFlightLock = NSLock()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .modifier(ThumbnailBox(width: width, height: height))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onAppear { load() }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private func load() {
        let key = url.lastPathComponent as NSString
        if let hit = Self.cache.object(forKey: key) {
            image = hit
            return
        }
        Self.inFlightLock.lock()
        if Self.inFlight.contains(key) {
            Self.inFlightLock.unlock()
            return
        }
        Self.inFlight.insert(key)
        Self.inFlightLock.unlock()

        // 抽帧放到后台线程，避免一进文件夹几十条缩略图一起在主线程同步解码把界面卡死
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let candidates = [
                CMTime(seconds: 0.5, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600),
                .zero
            ]
            var result: UIImage?
            for time in candidates {
                if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                    result = UIImage(cgImage: cg)
                    break
                }
            }
            if let result {
                await MainActor.run {
                    Self.cache.setObject(result, forKey: key)
                    image = result
                }
            }
            Self.inFlightLock.lock()
            _ = Self.inFlight.remove(key)
            Self.inFlightLock.unlock()
        }
    }
}

private struct ThumbnailBox: ViewModifier {
    let width: CGFloat?
    let height: CGFloat

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: height)
        } else {
            content.frame(maxWidth: .infinity, minHeight: height, idealHeight: height, maxHeight: height)
        }
    }
}
