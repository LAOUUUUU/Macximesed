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

    /// The signed channel file saved next to the feed (`hashfeed-channel.json` and `.sig`).
    static func channelFiles(for file: URL) -> (json: URL, sig: URL) {
        let json = file.deletingLastPathComponent().appendingPathComponent("hashfeed-channel.json")
        return (json, json.appendingPathExtension("sig"))
    }

    /// Saves the feed with the signed channel that vouches for it, so a reader that doesn't trust this folder (the
    /// root watch) can check both again. The channel goes first: a half-finished save never pairs a feed with a
    /// channel that doesn't name it in a way that passes.
    public static func store(_ data: Data, signedChannel json: Data, signature: Data, to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let c = channelFiles(for: file)
        try json.write(to: c.json, options: .atomic)
        try signature.write(to: c.sig, options: .atomic)
        try data.write(to: file, options: .atomic)
    }

    /// The cached feed, only if the saved channel's signature checks out with the release key and it names this exact
    /// feed. The folder is the user's, so anything running as them could otherwise empty or replace the feed.
    public static func loadSigned(from file: URL = defaultFile, verifier: ChannelVerifier = ChannelVerifier()) -> (
        feed: HashFeed, sequence: Int
    )? {
        let c = channelFiles(for: file)
        guard let json = try? Data(contentsOf: c.json), let sig = try? Data(contentsOf: c.sig),
            let channel = try? verifier.verify(json: json, signature: sig), let named = channel.hashFeed,
            let data = try? Data(contentsOf: file), let feed = try? verified(data, expectedSHA256: named.sha256)
        else { return nil }
        return (feed, channel.sequence)
    }

    /// Downloads the feed when the signed channel names a different one than the cached copy, and keeps the signed
    /// channel next to it either way.
    @discardableResult
    public static func refresh(from signed: SignedChannel, file: URL = defaultFile) throws -> HashFeed? {
        let channel = signed.channel
        guard let feed = channel.hashFeed, let url = URL(string: feed.url), url.scheme == "https" else { return loadCached(from: file) }
        if let cached = try? Data(contentsOf: file), MacxCore.sha256(cached) == feed.sha256.lowercased() {
            let parsed = try parse(cached)
            try store(cached, signedChannel: signed.json, signature: signed.signature, to: file)
            return parsed
        }
        let data = try UpdateClient.get(url, timeout: 20)
        let parsed = try verified(data, expectedSHA256: feed.sha256)
        try store(data, signedChannel: signed.json, signature: signed.signature, to: file)
        return parsed
    }
}

/// The feed for a long-running watch: re-read from the signed cache at most once a `interval`, when the files changed,
/// and never replaced by an older signed feed (a replayed pair) or by one that doesn't check out.
public final class HashFeedSource: @unchecked Sendable {
    let file: URL
    let verifier: ChannelVerifier
    let interval: TimeInterval
    let clock: () -> Date
    private let lock = NSLock()
    private var feed: HashFeed?
    private var sequence = Int.min
    private var lastLook: Date?
    private var lastStamp: String?

    public init(
        file: URL, verifier: ChannelVerifier = ChannelVerifier(), interval: TimeInterval = 60, clock: @escaping () -> Date = Date.init
    ) {
        self.file = file
        self.verifier = verifier
        self.interval = interval
        self.clock = clock
    }

    /// A fixed feed, for `macx watch` started with one and for tests.
    public init(fixed: HashFeed?) {
        file = URL(fileURLWithPath: "/dev/null")
        verifier = ChannelVerifier(publicKeys: [])
        interval = .infinity
        clock = Date.init
        feed = fixed
        lastLook = .distantFuture
    }

    public var current: HashFeed? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if let last = lastLook, now.timeIntervalSince(last) < interval { return feed }
        lastLook = now
        let stamp = stampOfFiles()
        guard stamp != lastStamp else { return feed }
        lastStamp = stamp
        if let loaded = HashFeed.loadSigned(from: file, verifier: verifier), loaded.sequence >= sequence {
            feed = loaded.feed
            sequence = loaded.sequence
        }
        return feed
    }

    private func stampOfFiles() -> String {
        let c = HashFeed.channelFiles(for: file)
        return [file, c.json, c.sig].map { url in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(mtime)"
        }.joined(separator: " ")
    }
}
