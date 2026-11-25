import Foundation
import Testing

@testable import MacxCore

/// The watch skips decoding file creates and renames that can't matter (most of eslogger's stream on a busy Mac).
@Suite("Watch prefilter")
struct WatchPrefilterTests {
    let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]))

    /// An eslogger-shaped line, slashes escaped the way eslogger writes them.
    func line(_ kind: String, dir: String, name: String, source: String? = nil) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "/", with: "\\/") }
        let src = source.map { #""source":{"path":"\#(esc($0))"},"# } ?? ""
        return
            #"{"process":{"executable":{"path":"\/usr\/bin\/touch"},"audit_token":{"pid":42},"is_platform_binary":false},"event":{"\#(kind)":{\#(src)"destination_type":1,"destination":{"new_path":{"dir":{"path":"\#(esc(dir))"},"filename":"\#(name)","mode":420}}}}}"#
    }

    @Test func launchItemsHiddenAppleFoldersAndDownloadsAreKept() {
        #expect(ESEvent.worthDecoding(line("create", dir: "/Users/v/Library/LaunchAgents", name: "x.plist")))
        #expect(ESEvent.worthDecoding(line("create", dir: "/Library/LaunchDaemons", name: "com.apple.x.plist")))
        #expect(ESEvent.worthDecoding(line("create", dir: "/Users/v/Library/Application Support", name: ".com.apple.x")))
        #expect(
            ESEvent.worthDecoding(
                line("rename", dir: "/Users/v/Downloads", name: "a.dmg", source: "/Users/v/Downloads/a.dmg.download/a.dmg")))
    }

    @Test func everydayFileCreatesAreSkipped() {
        #expect(!ESEvent.worthDecoding(line("create", dir: "/Users/v/Library/Caches/com.spotify.client", name: "data.0")))
        #expect(!ESEvent.worthDecoding(line("rename", dir: "/private/var/folders/x/T", name: "tmp", source: "/private/var/folders/x/T/a")))
    }

    @Test func otherEventsAreAlwaysKept() {
        #expect(ESEvent.worthDecoding(#"{"event":{"exec":{"target":{"executable":{"path":"\/bin\/sh"}}}}}"#))
        #expect(ESEvent.worthDecoding(#"{"event":{"deleteextattr":{"extattr":"com.apple.quarantine"}}}"#))
    }

    /// The safety property: a skipped line never raises an alert and is never a finished download.
    @Test func aSkippedLineCouldNeverHaveMattered() {
        let dirs = [
            "/Users/v/Library/Caches/x", "/private/tmp", "/Users/v/Documents", "/Users/v/.cargo/bin", "/Applications/X.app/Contents",
            "/Users/v/Library/Application Support/Foo", "/Users/v/Library/LaunchAgents", "/Library/LaunchDaemons", "/Users/v/Downloads",
            "/Users/v/Library/Application Support",
        ]
        let names = ["a.plist", "com.apple.a.plist", ".com.apple.a", "a.dmg", "b"]
        for kind in ["create", "rename"] {
            for d in dirs {
                for n in names {
                    let l = line(kind, dir: d, name: n, source: kind == "rename" ? "/Users/v/x/\(n)" : nil)
                    guard !ESEvent.worthDecoding(l) else { continue }
                    let e = ESEvent.parse(l)
                    #expect(e != nil)
                    if let e {
                        #expect(rules.evaluate(e).isEmpty, "\(kind) \(d)/\(n)")
                        #expect(DownloadWatch.finishedDownload(e, downloads: "/Users/v/Downloads") == nil)
                    }
                }
            }
        }
    }
}
