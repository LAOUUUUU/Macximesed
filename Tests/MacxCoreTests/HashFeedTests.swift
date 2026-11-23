import Foundation
import Testing

@testable import MacxCore

@Suite("Malware hash feed")
struct HashFeedTests {
    let feedJSON = Data(
        #"{"schema":1,"generated":"2026-11-23T20:00:00Z","entries":[{"sha256":"94a1f42cc5c7eab17b00c19887d6f4fa83f57a6c5c02f05d245030424eea4f0b","family":"AMOS","source":"observed in the wild (2026)"},{"sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","family":"Test","source":"x"}]}"#
            .utf8)

    @Test func parsesAndLooksUpCaseInsensitively() throws {
        let feed = try HashFeed.parse(feedJSON)
        #expect(feed.count == 2)
        #expect(
            try feed.lookup(sha256: "94A1F42CC5C7EAB17B00C19887D6F4FA83F57A6C5C02F05D245030424EEA4F0B")
                == "AMOS (observed in the wild (2026))")
        #expect(try feed.lookup(sha256: String(repeating: "b", count: 64)) == nil)
    }

    @Test func acceptsOnlyTheBytesTheSignedChannelVouchesFor() throws {
        let good = sha256(feedJSON)
        #expect(throws: Never.self) { try HashFeed.verified(feedJSON, expectedSHA256: good) }
        var tampered = feedJSON
        tampered[10] ^= 1
        #expect(throws: UpdateError.hashMismatch) { try HashFeed.verified(tampered, expectedSHA256: good) }
    }

    @Test func rejectsJunkEntries() {
        let bad = Data(#"{"schema":1,"generated":"2026-11-23T20:00:00Z","entries":[{"sha256":"nothex","family":"x","source":"y"}]}"#.utf8)
        #expect(throws: (any Error).self) { try HashFeed.parse(bad) }
    }

    @Test func cachedFeedRoundTrips() throws {
        let tmp = try TempDir()
        let f = tmp.url.appendingPathComponent("hashfeed.json")
        try HashFeed.store(feedJSON, to: f)
        let loaded = try #require(HashFeed.loadCached(from: f))
        #expect(loaded.count == 2)
        #expect(HashFeed.loadCached(from: tmp.url.appendingPathComponent("missing")) == nil)
    }

    @Test func channelCarriesTheFeedEntry() throws {
        let json = Data(
            #"{"expires":"2027-02-21T20:20:00Z","hashFeed":{"count":2,"sha256":"abc","url":"https://laouuuuu.github.io/Macximesed/feed/v1.json"},"latest":{"sha256":"abc","url":"https://x/macx.tar.gz","version":"0.2.0"},"published":"2026-11-23T20:20:00Z","schema":1,"sequence":3}"#
                .utf8)
        let s = TestSigner()
        let c = try ChannelVerifier(publicKeys: [s.publicKey]).verify(json: json, signature: try s.key.signature(for: json))
        #expect(c.hashFeed?.count == 2)
        #expect(c.hashFeed?.url == "https://laouuuuu.github.io/Macximesed/feed/v1.json")
    }

    @Test func fileCheckUsesTheFeedOffline() throws {
        let tmp = try TempDir()
        let f = try tmp.file("payload.bin", "pretend payload")
        let hash = sha256(try Data(contentsOf: f))
        let json = Data(
            #"{"schema":1,"generated":"2026-11-23T20:00:00Z","entries":[{"sha256":"\#(hash)","family":"AMOS","source":"test"}]}"#.utf8)
        let feed = try HashFeed.parse(json)
        let report = try checker(lookup: feed).check(f)
        #expect(report.findings.contains { $0.rule == "known-malware" && ($0.detail ?? "").contains("AMOS") })
    }
}
