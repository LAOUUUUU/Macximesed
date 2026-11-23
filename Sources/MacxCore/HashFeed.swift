import Foundation

/// Known macOS malware by SHA-256, published on GitHub Pages next to the update channel. The signed
/// channel carries the feed's own SHA-256, so the feed is only accepted byte-for-byte as signed. Lookups
/// are local: no file or hash ever leaves the Mac.
public struct HashFeed: HashLookup, Sendable {
    public struct Entry: Codable, Sendable {
        public var sha256: String
        public var family: String
        public var source: String
    }

    struct File: Codable {
        var schema: Int
        var generated: String
        var entries: [Entry]
    }

    let byHash: [String: Entry]
    public var count: Int { byHash.count }

    public static func parse(_ data: Data) throws -> HashFeed {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.schema == 1 else { throw UpdateError.badChannel }
        var map: [String: Entry] = [:]
        for e in file.entries {
            let h = e.sha256.lowercased()
            guard h.count == 64, h.allSatisfy({ $0.isHexDigit }) else { throw UpdateError.badChannel }
            map[h] = e
        }
        return HashFeed(byHash: map)
    }

    /// Only the exact bytes the signed channel names.
    public static func verified(_ data: Data, expectedSHA256: String) throws -> HashFeed {
        guard MacxCore.sha256(data) == expectedSHA256.lowercased() else { throw UpdateError.hashMismatch }
        return try parse(data)
    }

    public func lookup(sha256: String) throws -> String? {
        byHash[sha256.lowercased()].map { "\($0.family) (\($0.source))" }
    }

    // MARK: Cache

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/hashfeed.json")
    }

    public static func store(_ data: Data, to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    public static func loadCached(from file: URL = defaultFile) -> HashFeed? {
        (try? Data(contentsOf: file)).flatMap { try? parse($0) }
    }

    /// Downloads the feed when the signed channel names a different one than the cached copy.
    @discardableResult
    public static func refresh(from channel: UpdateChannel, file: URL = defaultFile) throws -> HashFeed? {
        guard let feed = channel.hashFeed, let url = URL(string: feed.url), url.scheme == "https" else { return loadCached(from: file) }
        if let cached = try? Data(contentsOf: file), MacxCore.sha256(cached) == feed.sha256.lowercased() {
            return try parse(cached)
        }
        let data = try UpdateClient.get(url, timeout: 20)
        let parsed = try verified(data, expectedSHA256: feed.sha256)
        try store(data, to: file)
        return parsed
    }
}
