import Foundation

/// 完全离线的日语 → 简体中文翻译。模型首次启用前在设置页下载，之后不联网、不需要 Key。
actor OfflineMT {

    static let shared = OfflineMT()

    private var tokenizer: MTTokenizer?
    private var engine: MTTranslator?
    private var loadFailure: String?

    /// 三份资产是否都已下载（不代表已加载进内存）。
    nonisolated var isReady: Bool { MTModelManager.shared.allDownloaded }

    func translate(_ text: String) throws -> String {
        try ensureLoaded()
        guard let tokenizer, let engine else {
            throw FreeTranslationError.failed("离线翻译模型没加载成功")
        }
        let sourceIds = tokenizer.encode(text)
        let targetIds: [NSNumber]
        let translated: [Int]

        targetIds = sourceIds.withUnsafeBufferPointer { buffer in
            engine.translateSourceIds(buffer.baseAddress, count: sourceIds.count, error: nil) ?? []
        }
        translated = targetIds.map { $0.intValue }
        let result = tokenizer.decode(translated)
        guard !result.isEmpty else { throw FreeTranslationError.failed("离线翻译没返回译文") }
        return result
    }

    private func ensureLoaded() throws {
        if engine != nil, tokenizer != nil { return }
        if let failure = loadFailure {
            throw FreeTranslationError.failed(failure)
        }
        guard MTModelManager.shared.allDownloaded else {
            throw FreeTranslationError.failed("离线翻译模型还没下载")
        }

        let dir = MTModelManager.shared.dir
        guard let tokenizer = MTTokenizer(vocabURL: dir.appendingPathComponent("vocab.json")) else {
            loadFailure = "词表文件损坏，请到设置里重新下载离线翻译模型"
            throw FreeTranslationError.failed(loadFailure!)
        }

        var error: NSError?
        let engine = MTTranslator(
            encoderPath: dir.appendingPathComponent("encoder_model.onnx").path,
            decoderPath: dir.appendingPathComponent("decoder_model.onnx").path,
            error: &error)
        guard let engine else {
            loadFailure = error?.localizedDescription ?? "离线翻译模型加载失败"
            throw FreeTranslationError.failed(loadFailure!)
        }

        self.tokenizer = tokenizer
        self.engine = engine
    }
}
