import Foundation
import Combine

/// 点播剧集离线下载：把 HLS(m3u8) 分片按顺序拼接成单个 .ts，或把直连视频文件直接存入本地片库。
/// 下载完成后文件进入 Documents/Media，本地播放器可直接离线播放。
@MainActor
final class VodDownloadManager: ObservableObject {

    enum Status: Equatable {
        case idle
        case downloading
        case done
        case failed(String)
    }

    struct TaskState: Equatable {
        var status: Status
        /// 0...1
        var progress: Double
        var done: Int
        var total: Int
        var fileName: String?
    }

    /// 一条已登记的下载记录（下载管理页用）
    struct DownloadRecord: Codable, Equatable, Identifiable {
        var url: String
        var title: String
        var episodeName: String
        var fileName: String
        var addedAt: Date
        var id: String { url }
    }

    static let shared = VodDownloadManager()

    @Published private(set) var tasks: [String: TaskState] = [:]

    private let registryKey = "vodDownloadsV2"
    private let legacyKey = "vodDownloadsV1"

    private var records: [String: DownloadRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: registryKey),
                  let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: registryKey)
            }
        }
    }

    private var cancelFlags = Set<String>()
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 可直接整文件下载的容器后缀
    private static let directExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv",
        "mpg", "mpeg", "3gp", "ogv", "rmvb", "rm", "f4v", "vob"
    ]

    private init() {
        migrateLegacy()
        // 启动时把已完成的登记恢复成 done；文件若已被手动删除则回退 idle
        var restored: [String: TaskState] = [:]
        for rec in records.values where fileExists(rec) {
            restored[rec.url] = TaskState(status: .done, progress: 1, done: 1, total: 1, fileName: rec.fileName)
        }
        tasks = restored
    }

    // MARK: - 下载记录（下载管理页）

    /// 全部下载记录，新的在前
    var allRecords: [DownloadRecord] {
        records.values.sorted { $0.addedAt > $1.addedAt }
    }

    func record(for url: String) -> DownloadRecord? { records[url] }

    func fileURL(for record: DownloadRecord) -> URL {
        MediaLibrary.shared.root.appendingPathComponent(record.fileName)
    }

    func fileExists(_ record: DownloadRecord) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: record).path)
    }

    /// 删除一条记录：先取消进行中的任务，再删本地文件并清登记
    func removeRecord(_ url: String) {
        cancelFlags.insert(url)
        var reg = records
        if let rec = reg.removeValue(forKey: url) {
            let target = fileURL(for: rec)
            try? FileManager.default.removeItem(at: target)
        }
        records = reg
        tasks.removeValue(forKey: url)
        MediaLibrary.shared.reload()
    }

    // MARK: - 对外接口

    /// 查询某一集（以播放地址为唯一标识）的下载状态
    func state(for key: String) -> TaskState {
        if let cached = tasks[key] { return cached }
        if let rec = records[key], fileExists(rec) {
            let restored = TaskState(status: .done, progress: 1, done: 1, total: 1, fileName: rec.fileName)
            tasks[key] = restored
            return restored
        }
        return TaskState(status: .idle, progress: 0, done: 0, total: 0, fileName: nil)
    }

    /// 开始下载；已在下载或已完成时直接返回
    func download(title: String, episodeName: String, sourceURL: String) {
        guard !sourceURL.isEmpty else { return }
        let current = state(for: sourceURL)
        if case .downloading = current.status { return }
        if case .done = current.status { return }
        cancelFlags.remove(sourceURL)
        upsertRecord(url: sourceURL, title: title, episodeName: episodeName,
                     fileName: records[sourceURL]?.fileName ?? "")
        Task { await run(title: title, episodeName: episodeName, sourceURL: sourceURL) }
    }

    /// 取消进行中的下载（保留半成品清理由任务内负责）
    func cancel(_ key: String) {
        cancelFlags.insert(key)
    }

    // MARK: - 下载流程

    private func run(title: String, episodeName: String, sourceURL: String) async {
        let baseName = Self.fileBase(title: title, episodeName: episodeName)

        let data: Data
        do {
            data = try await fetchBytes(sourceURL)
        } catch {
            markFailed(sourceURL, message: "连不上下载地址", done: 0, total: 1)
            return
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // HLS 播放列表（无论 URL 有没有 .m3u8 后缀，按内容识别）
        if trimmed.hasPrefix("#EXTM3U") || trimmed.contains("#EXT-X-STREAM-INF") || trimmed.contains("#EXTINF") {
            await downloadHLS(key: sourceURL, baseName: baseName, playlistURL: sourceURL, seedBody: body)
            return
        }

        // 网页播放页：从 HTML 里提取内嵌的 m3u8 / mp4 地址，再跟一层
        if looksLikeHTML(body) {
            guard let extracted = Self.extractVideoURL(body, base: sourceURL) else {
                markFailed(sourceURL, message: "网页里没解析到可下载的视频地址", done: 0, total: 1)
                return
            }
            await resolveAndDownload(url: extracted, key: sourceURL, baseName: baseName,
                                      title: title, episodeName: episodeName)
            return
        }

        // 二进制视频 / 直连文件
        let ext = Self.directExtension(from: sourceURL) ?? (dataIsVideo(data) ? "mp4" : nil)
        if let ext {
            await downloadSingleFile(key: sourceURL, baseName: baseName, ext: ext,
                                     url: sourceURL, seed: data)
        } else {
            markFailed(sourceURL, message: "无法识别该播放地址的格式", done: 0, total: 1)
        }
    }

    /// 网页提取出的地址再走一层判定（直连视频或二次播放列表）
    private func resolveAndDownload(url: String, key: String, baseName: String,
                                    title: String, episodeName: String) async {
        let data: Data
        do {
            data = try await fetchBytes(url)
        } catch {
            markFailed(key, message: "连不上解析后的地址", done: 0, total: 1)
            return
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("#EXTM3U") || trimmed.contains("#EXTINF") {
            await downloadHLS(key: key, baseName: baseName, playlistURL: url, seedBody: body)
            return
        }

        let ext = Self.directExtension(from: url) ?? (dataIsVideo(data) ? "mp4" : nil)
        if let ext {
            await downloadSingleFile(key: key, baseName: baseName, ext: ext, url: url, seed: data)
        } else {
            markFailed(key, message: "解析后的地址仍不是可下载视频", done: 0, total: 1)
        }
    }

    /// 直连整文件下载
    private func downloadSingleFile(key: String, baseName: String, ext: String,
                                    url: String, seed: Data? = nil) async {
        setState(key, status: .downloading, progress: 0, done: 0, total: 1, fileName: nil)

        var data = seed
        if data == nil {
            for attempt in 0..<2 {
                do {
                    data = try await fetchBytes(url)
                    break
                } catch {
                    if attempt == 1 { break }
                }
            }
        }
        guard let data else {
            markFailed(key, message: "连不上下载地址", done: 0, total: 1)
            return
        }

        let dest = MediaLibrary.shared.uniqueDestination(for: "\(baseName).\(ext)")
        do {
            try data.write(to: dest, options: .atomic)
            register(key, fileName: dest.lastPathComponent)
            setState(key, status: .done, progress: 1, done: 1, total: 1, fileName: dest.lastPathComponent)
        } catch {
            markFailed(key, message: "写入本地失败", done: 0, total: 1)
        }
    }

    /// HLS 下载：主播放列表 → 变体列表 → 分片顺序拼接为 .ts（含 AES-128 解密）
    private func downloadHLS(key: String, baseName: String, playlistURL: String, seedBody: String? = nil) async {
        setState(key, status: .downloading, progress: 0, done: 0, total: 0, fileName: nil)

        // 1. 拉取播放列表
        let masterRaw: String
        if let seedBody {
            masterRaw = seedBody
        } else {
            do {
                masterRaw = try await fetchText(playlistURL)
            } catch {
                markFailed(key, message: "连不上播放地址", done: 0, total: 0)
                return
            }
        }

        // 2. 若是主列表，取第一条变体地址再拉一次
        var variantBase = playlistURL
        let variantRaw: String
        if masterRaw.contains("EXT-X-STREAM-INF"),
           let variant = firstVariant(masterRaw, base: playlistURL) {
            variantBase = variant
            do {
                variantRaw = try await fetchText(variant)
            } catch {
                markFailed(key, message: "播放线路解析失败", done: 0, total: 0)
                return
            }
        } else {
            variantRaw = masterRaw
        }

        // 3. 加密信息（AES-128 取密钥并在分片落地前解密；NONE 明文直接拼接）
        let keyInfo: KeyInfo?
        do {
            keyInfo = try await parseKey(variantRaw, base: variantBase)
        } catch {
            markFailed(key, message: "加密密钥获取失败，该线路无法下载", done: 0, total: 0)
            return
        }

        let segments = segmentURLs(variantRaw, base: variantBase)
        guard !segments.isEmpty else {
            markFailed(key, message: "没有可下载的分片", done: 0, total: 0)
            return
        }

        let mediaSeq = parseMediaSequence(variantRaw)
        let total = segments.count
        let tempURL = MediaLibrary.shared.root
            .appendingPathComponent(".\(UUID().uuidString).downloading.ts")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            markFailed(key, message: "无法写入本地存储", done: 0, total: total)
            return
        }

        var completed = 0
        do {
            for (index, segment) in segments.enumerated() {
                if cancelFlags.contains(key) {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    setState(key, status: .idle, progress: 0, done: 0, total: 0, fileName: nil)
                    return
                }

                var segmentData: Data?
                for attempt in 0..<2 {
                    do {
                        segmentData = try await fetchBytes(segment)
                        break
                    } catch {
                        if attempt == 1 { break }
                    }
                }
                guard var segmentData else { throw DownloadError.segmentFailed(index + 1) }

                if let keyInfo {
                    let iv = keyInfo.iv(forSeq: mediaSeq + index)
                    guard let decrypted = Self.decrypt(segment: segmentData, key: keyInfo.keyData, iv: iv) else {
                        throw DownloadError.decryptFailed(index + 1)
                    }
                    segmentData = decrypted
                }

                try handle.write(contentsOf: segmentData)
                completed = index + 1
                setState(key, status: .downloading,
                         progress: Double(completed) / Double(total),
                         done: completed, total: total, fileName: nil)
            }

            try handle.close()
            let dest = MediaLibrary.shared.uniqueDestination(for: "\(baseName).ts")
            try FileManager.default.moveItem(at: tempURL, to: dest)
            register(key, fileName: dest.lastPathComponent)
            setState(key, status: .done, progress: 1, done: total, total: total, fileName: dest.lastPathComponent)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            markFailed(key, message: "分片下载中断，已清理半成品", done: completed, total: total)
        }
    }

    // MARK: - 网络

    private func fetchText(_ urlString: String) async throws -> String {
        let data = try await fetchBytes(urlString)
        guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.parseFailed }
        return text
    }

    private func fetchBytes(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw DownloadError.badURL }
        var request = URLRequest(url: url)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw DownloadError.badResponse }
        return data
    }

    // MARK: - 播放列表解析

    private func firstVariant(_ playlist: String, base: String) -> String? {
        for rawLine in playlist.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            return Self.resolve(line, base: base)
        }
        return nil
    }

    private func segmentURLs(_ playlist: String, base: String) -> [String] {
        playlist.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { Self.resolve($0, base: base) }
    }

    private func parseMediaSequence(_ playlist: String) -> Int {
        for line in playlist.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#EXT-X-MEDIA-SEQUENCE") else { continue }
            let n = t.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
            return Int(n ?? "0") ?? 0
        }
        return 0
    }

    private static func resolve(_ reference: String, base: String) -> String {
        guard let baseURL = URL(string: base),
              let resolved = URL(string: reference, relativeTo: baseURL) else {
            return reference
        }
        return resolved.absoluteString
    }

    // MARK: - AES-128 解密

    private struct KeyInfo {
        let keyData: Data
        let explicitIV: Data?

        func iv(forSeq seq: Int) -> Data {
            if let explicitIV { return explicitIV }
            // 未显式给 IV 时，用媒体序列号作为 16 字节大端 IV（HLS 规范）
            var iv = Data(count: 16)
            var seqBE = UInt64(seq).bigEndian
            let seqData = withUnsafeBytes(of: &seqBE) { Data($0) }
            iv.replaceSubrange(8..<16, with: seqData)
            return iv
        }
    }

    private func parseKey(_ playlist: String, base: String) async throws -> KeyInfo? {
        for rawLine in playlist.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-KEY") else { continue }

            if line.contains("METHOD=AES-128") {
                guard let uri = Self.attribute("URI", in: line),
                      let baseURL = URL(string: base),
                      let keyURL = URL(string: uri, relativeTo: baseURL)?.absoluteString else {
                    throw DownloadError.keyMissing
                }
                let keyData: Data
                do {
                    keyData = try await fetchBytes(keyURL)
                } catch {
                    throw DownloadError.keyFetchFailed
                }
                guard keyData.count == 16 else { throw DownloadError.keyInvalid }
                let ivHex = Self.attribute("IV", in: line)
                let explicitIV = ivHex.flatMap { Self.ivData(hex: $0) }
                return KeyInfo(keyData: keyData, explicitIV: explicitIV)
            }

            // METHOD=NONE 或其他明文方式：无加密
            return nil
        }
        return nil
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let quoted = "\(name)=\"([^\"]*)\""
        if let r = line.range(of: quoted, options: .regularExpression) {
            let s = line[r]
            return String(s.dropFirst(name.count + 2).dropLast())
        }
        let plain = "\(name)=([^,]+)"
        if let r = line.range(of: plain, options: .regularExpression) {
            let s = line[r]
            return String(s.dropFirst(name.count + 1))
        }
        return nil
    }

    private static func ivData(hex: String) -> Data? {
        var clean = hex.lowercased()
        if clean.hasPrefix("0x") { clean.removeFirst(2) }
        guard clean.count == 32, let bytes = hexToBytes(clean) else { return nil }
        return Data(bytes)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard j <= hex.endIndex, let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        return bytes
    }

    private static func decrypt(segment: Data, key: Data, iv: Data) -> Data? {
        AESHelper.aes128CbcDecrypt(segment, key: key, iv: iv)
    }

    // MARK: - 内容识别

    private func looksLikeHTML(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.hasPrefix("<!doctype") || lower.contains("<html") ||
            lower.contains("<head") || lower.contains("<body")
    }

    private func dataIsVideo(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = Array(data.prefix(12))
        if b[0] == 0x47 { return true }                       // MPEG-TS 同步字
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true } // ftyp
        return false
    }

    private static func directExtension(from url: String) -> String? {
        let ext = (url as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, directExtensions.contains(ext) else { return nil }
        return ext
    }

    /// 从网页 HTML / JSONP 里提取第一个内嵌视频地址（绝对或相对路径）
    private static func extractVideoURL(_ html: String, base: String) -> String? {
        let absolutePatterns = [
            #"https?://[^""'\s<>\\]+\.m3u8[^""'\s<>\\]*"#,
            #"https?://[^""'\s<>\\]+\.(?:mp4|m4v|mov|webm|mkv|avi|flv|ts|m4s)[^""'\s<>\\]*"#
        ]
        for pattern in absolutePatterns {
            if let r = html.range(of: pattern, options: .regularExpression) {
                return Self.resolve(String(html[r]), base: base)
            }
        }
        let relativePatterns = [
            #"[^""'\s<>\\]+\.m3u8[^""'\s<>\\]*"#,
            #"[^""'\s<>\\]+\.(?:mp4|m4v|mov|webm)[^""'\s<>\\]*"#
        ]
        for pattern in relativePatterns {
            if let r = html.range(of: pattern, options: .regularExpression) {
                let ref = String(html[r])
                if !ref.contains("://") { return Self.resolve(ref, base: base) }
            }
        }
        return nil
    }

    // MARK: - 状态与登记

    private func setState(_ key: String, status: Status, progress: Double,
                          done doneCount: Int, total totalCount: Int, fileName: String?) {
        let state = TaskState(status: status, progress: progress, done: doneCount,
                              total: totalCount, fileName: fileName)
        tasks[key] = state
    }

    private func markFailed(_ key: String, message: String, done: Int, total: Int) {
        setState(key, status: .failed(message), progress: 0, done: done, total: total, fileName: nil)
    }

    private func upsertRecord(url: String, title: String, episodeName: String, fileName: String) {
        var reg = records
        if var existing = reg[url] {
            existing.title = title
            existing.episodeName = episodeName
            if !fileName.isEmpty { existing.fileName = fileName }
            reg[url] = existing
        } else {
            reg[url] = DownloadRecord(url: url, title: title, episodeName: episodeName,
                                      fileName: fileName, addedAt: Date())
        }
        records = reg
    }

    private func register(_ key: String, fileName: String) {
        var reg = records
        if var rec = reg[key] {
            rec.fileName = fileName
            reg[key] = rec
        }
        records = reg
        MediaLibrary.shared.reload()
    }

    private func migrateLegacy() {
        guard let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String] else { return }
        var reg = records
        for (url, fileName) in legacy where reg[url] == nil {
            reg[url] = DownloadRecord(url: url, title: "", episodeName: "",
                                      fileName: fileName, addedAt: Date())
        }
        records = reg
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // MARK: - 文件名

    static func fileBase(title: String, episodeName: String) -> String {
        let cleanTitle = sanitize(title)
        let cleanEpisode = sanitize(episodeName)
        if cleanEpisode.isEmpty || cleanEpisode == cleanTitle { return cleanTitle }
        return "\(cleanTitle) - \(cleanEpisode)"
    }

    private static func sanitize(_ text: String) -> String {
        var out = text
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            out = out.replacingOccurrences(of: bad, with: " ")
        }
        out = out.components(separatedBy: .newlines).joined(separator: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DownloadError: Error {
    case badURL
    case badResponse
    case parseFailed
    case segmentFailed(Int)
    case decryptFailed(Int)
    case keyMissing
    case keyFetchFailed
    case keyInvalid
}
