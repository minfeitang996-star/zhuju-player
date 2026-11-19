import Foundation
import Combine

struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let sizeText: String
    let note: String
}

final class ModelManager: ObservableObject {

    static let shared = ModelManager()

    static let catalog: [WhisperModelInfo] = [
        .init(id: "ggml-tiny.bin", title: "tiny", sizeText: "75 MB", note: "最快，准确度一般，适合先试"),
        .init(id: "ggml-base.bin", title: "base", sizeText: "142 MB", note: "推荐，速度与准确度平衡"),
        .init(id: "ggml-small.bin", title: "small", sizeText: "466 MB", note: "更准，慢一些，老机器慎用"),
    ]

    @Published var progress: [String: Double] = [:]
    @Published var activeDownload: String?

    let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func localURL(_ id: String) -> URL? {
        let url = dir.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 1_048_576 ? url : nil
    }

    func isDownloaded(_ id: String) -> Bool { localURL(id) != nil }

    func download(_ id: String) async throws -> URL {
        guard let remote = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(id)") else {
            throw NSError(domain: "ZhuJu", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型地址无效"])
        }

        await MainActor.run {
            self.activeDownload = id
            self.progress[id] = 0
        }

        let target = dir.appendingPathComponent(id)
        let tmp = dir.appendingPathComponent(id + ".part")
        try? FileManager.default.removeItem(at: tmp)

        let delegate = ModelDownloadDelegate(destination: tmp)
        delegate.onProgress = { value in
            DispatchQueue.main.async { self.progress[id] = value }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: remote)

        let result: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
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
            self.progress[id] = 1
        }
        return target
    }
}

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let destination: URL
    private var finished = false

    var onProgress: ((Double) -> Void)?
    var onFinish: ((URL?, Error?) -> Void)?

    init(destination: URL) {
        self.destination = destination
        super.init()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        finished = true
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish?(destination, nil)
        } catch {
            onFinish?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, let error else { return }
        finished = true
        onFinish?(nil, error)
    }
}
