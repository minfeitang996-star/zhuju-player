import Foundation
import Combine

/// 离线日译中（Marian/ONNX）模型资产清单。首次开启离线翻译时下载，不打进 IPA。
final class MTModelManager: ObservableObject {

    static let shared = MTModelManager()

    struct Asset: Identifiable, Equatable {
        let id: String
        let file: String
        let label: String
        let sizeText: String
        let minSize: Int64
    }

    static let baseURL = "https://huggingface.co/ruozhi521/shiyin-mt-ja-zh-onnx/resolve/main"

    static let assets: [Asset] = [
        .init(id: "vocab", file: "vocab.json", label: "词表", sizeText: "1.9 MB", minSize: 1_000_000),
        .init(id: "encoder", file: "encoder_model.onnx", label: "编码器", sizeText: "100 MB", minSize: 50_000_000),
        .init(id: "decoder", file: "decoder_model.onnx", label: "解码器", sizeText: "113 MB", minSize: 50_000_000),
    ]

    @Published var progress: [String: Double] = [:]
    @Published var activeDownload: String?

    let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Models/mt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func localURL(_ file: String) -> URL? {
        let url = dir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func isDownloaded(_ asset: Asset) -> Bool {
        guard let url = localURL(asset.file) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= asset.minSize
    }

    var allDownloaded: Bool {
        Self.assets.allSatisfy { isDownloaded($0) }
    }

    func download(_ asset: Asset) async throws -> URL {
        guard let remote = URL(string: "\(Self.baseURL)/\(asset.file)") else {
            throw NSError(domain: "ZhuJu", code: 2, userInfo: [NSLocalizedDescriptionKey: "离线翻译模型地址无效"])
        }

        await MainActor.run {
            self.activeDownload = asset.id
            self.progress[asset.id] = 0
        }

        let target = dir.appendingPathComponent(asset.file)
        let tmp = dir.appendingPathComponent(asset.file + ".part")
        try? FileManager.default.removeItem(at: tmp)

        let delegate = ModelDownloadDelegate(destination: tmp)
        delegate.onProgress = { value in
            DispatchQueue.main.async { self.progress[asset.id] = value }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: remote)

        let result: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.onFinish = { file, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let file {
                    continuation.resume(returning: file)
                } else {
                    continuation.resume(throwing: NSError(domain: "ZhuJu", code: 3,
                                                          userInfo: [NSLocalizedDescriptionKey: "下载失败"]))
                }
            }
            task.resume()
        }

        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: result, to: target)
        session.invalidateAndCancel()

        await MainActor.run {
            self.activeDownload = nil
            self.progress[asset.id] = 1
        }
        return target
    }
}
