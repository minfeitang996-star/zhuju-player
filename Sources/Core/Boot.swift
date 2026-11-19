import Foundation

/// 启动阶段留痕：每走一步就往 Documents/boot.txt 追加一行。
/// 闪退时把「文件 → 我的 iPhone → 逐句 → boot.txt」打开看一眼，
/// 最后一行就是它撑到的那一步。
enum Boot {

    static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("boot.txt")
    }()

    static func mark(_ tag: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "[\(stamp)] \(tag)\n"
        guard let newData = line.data(using: .utf8) else { return }

        if let old = try? Data(contentsOf: url) {
            var merged = old
            merged.append(newData)
            try? merged.write(to: url)
        } else {
            try? newData.write(to: url)
        }
    }
}
