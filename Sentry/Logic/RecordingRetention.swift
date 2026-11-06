import Foundation

struct RecordingEntry {
    let url: URL
    let modified: Date
    let bytes: Int64
}

enum RecordingRetention {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let byteLimit: Int64 = 5_000_000_000

    // 先清理过期片段，再按时间清理超额片段，正在写入的文件始终受保护，喵~
    static func removals(from entries: [RecordingEntry], protected: Set<URL>, now: Date,
                         limit: Int64 = byteLimit) -> [URL] {
        let sorted = entries.sorted { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var result: [URL] = []
        for entry in sorted where !protected.contains(entry.url) {
            if entry.modified <= now.addingTimeInterval(-lifetime) || total > limit {
                result.append(entry.url)
                total -= entry.bytes
            }
        }
        return result
    }
}
