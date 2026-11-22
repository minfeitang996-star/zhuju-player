import Foundation

/// 离线日译中模型的本地分词器。
/// 词表来自模型自带的 vocab.json；分词采用归一化后的贪心最长匹配，
/// 与 SentencePiece 的 Unigram 切分在常用日语字幕上对齐，未知字回退到 <unk>。
final class MTTokenizer {

    static let eosID: Int64 = 0
    static let unkID: Int64 = 1
    static let padID: Int64 = 65000

    private var pieceToID: [String: Int] = [:]
    private var idToPiece: [Int: String] = [:]

    init?(vocabURL: URL) {
        guard let data = try? Data(contentsOf: vocabURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return nil
        }
        pieceToID = json
        for (piece, id) in json { idToPiece[id] = piece }
    }

    // MARK: - 编码

    func encode(_ text: String) -> [Int64] {
        let surface = Self.normalize(text)
        var ids: [Int64] = []
        var i = surface.startIndex
        while i < surface.endIndex {
            var j = surface.endIndex
            var matched: String?
            while j > i {
                let candidate = String(surface[i..<j])
                if pieceToID[candidate] != nil {
                    matched = candidate
                    break
                }
                j = surface.index(before: j)
            }
            if let piece = matched, let id = pieceToID[piece] {
                ids.append(Int64(id))
                i = j
            } else {
                ids.append(Self.unkID)
                i = surface.index(after: i)
            }
        }
        ids.append(Self.eosID)
        return ids
    }

    // MARK: - 解码

    func decode(_ ids: [Int]) -> String {
        var pieces: [String] = []
        for id in ids {
            if Int64(id) == Self.eosID || Int64(id) == Self.unkID || Int64(id) == Self.padID { continue }
            guard let piece = idToPiece[id] else { continue }
            pieces.append(piece)
        }
        var text = pieces.joined().replacingOccurrences(of: "▁", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - 归一化

    /// 全角 ASCII / 全角空格转半角，折叠空白，空格换成 ▁，句首补 ▁（dummy prefix）。
    static func normalize(_ text: String) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(text.count)
        for ch in text {
            guard let scalar = ch.unicodeScalars.first else { chars.append(ch); continue }
            let value = scalar.value
            if value >= 0xFF01 && value <= 0xFF5E {
                if let converted = UnicodeScalar(value - 0xFEE0) {
                    chars.append(Character(converted))
                    continue
                }
            } else if value == 0x3000 {
                chars.append(" ")
                continue
            }
            chars.append(ch)
        }
        let collapsed = String(chars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "▁" + collapsed.replacingOccurrences(of: " ", with: "▁")
    }

    /// 粗判是否含日文（平假名 / 片假名），用于 auto 语种下决定能否走离线日译中。
    static func looksJapanese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) { return true }
        }
        return false
    }
}
