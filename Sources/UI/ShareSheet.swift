import SwiftUI
import UIKit

/// 系统分享面板：把本地视频文件发给「文件」或其他 App。
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 供 `.sheet(item:)` 包装本地分享文件
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}
