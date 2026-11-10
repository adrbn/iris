import Foundation

/// Plain-text journal in Documents (readable from Files, or pulled with devicectl) to debug
/// what the glasses actually send. Capped at 2 MB.
enum Log {
    static let url = URL.documentsDirectory.appending(path: "iris-log.txt")
    private static let start = Date()

    static func line(_ text: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(text)\n".utf8)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { try? data.write(to: url); return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    static func hex(_ data: Data, limit: Int = 48) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined() + (data.count > limit ? "…(\(data.count))" : "")
    }
}
