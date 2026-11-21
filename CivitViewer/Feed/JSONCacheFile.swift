import Foundation

/// File I/O for disposable JSON caches. The caller owns validity and eviction.
struct JSONCacheFile<Value: Codable> {
    let url: URL
    let maximumBytes: Int

    func read() -> Value? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              !data.isEmpty, data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// An oversized value leaves the existing file intact and returns false.
    func write(_ value: Value) throws -> Bool {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}
