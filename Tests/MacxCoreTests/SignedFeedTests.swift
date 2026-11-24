import CryptoKit
import Foundation
import Testing

@testable import MacxCore

/// The root watch reads the feed from the user's folder, which anything running as the user can write. It only
/// trusts a feed it can check against the signed channel file saved next to it.
@Suite("Signed feed cache for the root watch")
struct SignedFeedTests {
    static func feedData(_ hashes: [String]) -> Data {
        let entries = hashes.map { #"{"sha256":"\#($0)","family":"AMOS","source":"test"}"# }.joined(separator: ",")
        return Data(#"{"schema":1,"generated":"2026-11-24T00:00:00Z","entries":[\#(entries)]}"#.utf8)
    }

    let amos = String(repeating: "a", count: 64)
    let banshee = String(repeating: "b", count: 64)

    /// Writes feed + signed channel into `dir` the way `refresh` saves them.
    func save(_ feed: Data, sequence: Int, signer: TestSigner, in dir: URL, sha: String? = nil) throws -> URL {
        var c = channel(sequence: sequence)
        c.hashFeed = .init(url: "https://x/feed/v1.json", sha256: sha ?? sha256(feed), count: nil)
        let (json, sig) = try signer.sign(c)
        let file = dir.appendingPathComponent("hashfeed.json")
        try HashFeed.store(feed, signedChannel: json, signature: sig, to: file)
        return file
    }

    @Test func acceptsTheFeedTheSignedChannelNames() throws {
        let tmp = try TempDir()
        let s = TestSigner()
        let file = try save(Self.feedData([amos]), sequence: 4, signer: s, in: tmp.url)
        let loaded = try #require(HashFeed.loadSigned(from: file, verifier: ChannelVerifier(publicKeys: [s.publicKey])))
        #expect(loaded.feed.count == 1)
        #expect(loaded.sequence == 4)
    }

    @Test func refusesAFeedSwappedAfterSaving() throws {
        let tmp = try TempDir()
        let s = TestSigner()
        let file = try save(Self.feedData([amos]), sequence: 4, signer: s, in: tmp.url)
        try Self.feedData([]).write(to: file)  // a stealer empties it to blind the watch
        #expect(HashFeed.loadSigned(from: file, verifier: ChannelVerifier(publicKeys: [s.publicKey])) == nil)
    }

    @Test func refusesAChannelNotSignedByTheReleaseKey() throws {
        let tmp = try TempDir()
        let file = try save(Self.feedData([]), sequence: 9, signer: TestSigner(), in: tmp.url)
        #expect(HashFeed.loadSigned(from: file, verifier: ChannelVerifier(publicKeys: [TestSigner().publicKey])) == nil)
    }

    @Test func refusesAnOldCacheWithNoSignedChannel() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("hashfeed.json")
        try HashFeed.store(Self.feedData([amos]), to: file)
        #expect(HashFeed.loadSigned(from: file, verifier: ChannelVerifier(publicKeys: [TestSigner().publicKey])) == nil)
    }

    @Test func theWatchPicksUpANewerFeedWithoutARestart() throws {
        let tmp = try TempDir()
        let s = TestSigner()
        let v = ChannelVerifier(publicKeys: [s.publicKey])
        let file = try save(Self.feedData([amos]), sequence: 4, signer: s, in: tmp.url)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = HashFeedSource(file: file, verifier: v, interval: 60, clock: { now })
        #expect(try source.current?.lookup(sha256: banshee) == nil)

        _ = try save(Self.feedData([amos, banshee]), sequence: 5, signer: s, in: tmp.url)
        #expect(try source.current?.lookup(sha256: banshee) == nil)  // not looked at again within the minute
        now += 61
        #expect(try source.current?.lookup(sha256: banshee) != nil)
    }

    @Test func anOlderSignedFeedCantReplaceANewerOne() throws {
        let tmp = try TempDir()
        let s = TestSigner()
        let v = ChannelVerifier(publicKeys: [s.publicKey])
        let file = try save(Self.feedData([amos, banshee]), sequence: 5, signer: s, in: tmp.url)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = HashFeedSource(file: file, verifier: v, interval: 60, clock: { now })
        #expect(source.current?.count == 2)
        _ = try save(Self.feedData([amos]), sequence: 3, signer: s, in: tmp.url)  // replayed older pair
        now += 61
        #expect(source.current?.count == 2)
    }

    @Test func aFeedThatGoesBadKeepsTheLastGoodOne() throws {
        let tmp = try TempDir()
        let s = TestSigner()
        let file = try save(Self.feedData([amos]), sequence: 5, signer: s, in: tmp.url)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = HashFeedSource(file: file, verifier: ChannelVerifier(publicKeys: [s.publicKey]), interval: 60, clock: { now })
        #expect(source.current?.count == 1)
        try Data("junk".utf8).write(to: file)
        now += 61
        #expect(source.current?.count == 1)
    }
}

/// `MACX_FEED_INTEGRATION=1 swift test --filter RealSignedFeed`: the cache `macx update` saved verifies with the
/// real release key, as the root watch will check it.
@Suite("Real signed feed cache", .enabled(if: ProcessInfo.processInfo.environment["MACX_FEED_INTEGRATION"] == "1"))
struct RealSignedFeedTests {
    @Test func theSavedCacheVerifiesWithTheReleaseKey() throws {
        let loaded = try #require(HashFeed.loadSigned())
        #expect(loaded.feed.count >= 1)
        #expect(loaded.sequence >= 1)
    }
}
