import Foundation

/// A small on-device event log (`Documents/journal.jsonl`) for behaviour that only shows on a real iPhone, such as
/// what happens around leaving the app. Copy it off with `xcrun devicectl device copy from … --source Documents`.
nonisolated enum Journal {
    private static let url = URL.documentsDirectory.appending(path: "journal.jsonl")
    private static let lock = NSLock()

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    static func note(_ event: String, _ fields: [String: String] = [:]) {
        var record = fields
        record["event"] = event
        record["at"] = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
        // Keep it small: drop the older half past 512 KB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 512 * 1024,
            let data = try? Data(contentsOf: url)
        {
            try? data.suffix(256 * 1024).write(to: url, options: .atomic)
        }
    }
}
