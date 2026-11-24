import CryptoKit
import Foundation
import Testing

@testable import MacxCore

// MARK: - Helpers

func beta(
    sequence: Int = 7, commit: String = "1a2b3c4", base: String = "0.3.0", expires: Date = Date().addingTimeInterval(30 * 86400)
) -> BetaChannel {
    BetaChannel(
        sequence: sequence, published: Date(), expires: expires,
        build: .init(
            commit: commit, base: base, url: "https://github.com/x/y/releases/download/dev/macx-dev-\(commit)-macos-universal.tar.gz",
            sha256: "def", notes: nil))
}

extension TestSigner {
    func sign(_ b: BetaChannel) throws -> (Data, Data) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let json = try enc.encode(b)
        return (json, try key.signature(for: json))
    }

    func sign(json: String) throws -> (Data, Data) {
        let data = Data(json.utf8)
        return (data, try key.signature(for: data))
    }
}

let v030 = SemVer("0.3.0")!

// MARK: - Build versions

@Suite("Build versions")
struct BuildVersionTests {
    @Test func semVerIgnoresBuildMetadata() throws {
        #expect(try #require(SemVer("0.3.1+g1a2b3c4")) == #require(SemVer("0.3.1")))
        #expect(try #require(SemVer("1.0.0-dev.100+gabc")) > #require(SemVer("1.0.0-dev.99+gdef")))
    }

    @Test func parsesDevAndReleaseNames() {
        #expect(BuildVersion.parse("dev-1a2b3c4", base: v030) == .dev(commit: "1a2b3c4", base: v030))
        #expect(BuildVersion.parse("0.3.0", base: v030) == .release(v030))
        #expect(BuildVersion.parse("dev-", base: v030) == nil)
        #expect(BuildVersion.parse("dev-xyz1234", base: v030) == nil)
        #expect(BuildVersion.parse("dev-1a2b", base: v030) == nil)  // too short to name a commit
        #expect(BuildVersion.dev(commit: "1a2b3c4", base: v030).description == "dev-1a2b3c4")
        #expect(BuildVersion.release(v030).description == "0.3.0")
    }

    @Test func theCurrentBuildIsAReleaseUnlessStamped() {
        #expect(BuildVersion.current(commit: nil) == .release(SemVer(macxVersion)!))
        #expect(BuildVersion.current(commit: "1A2B3C4") == .dev(commit: "1a2b3c4", base: SemVer(macxVersion)!))
        #expect(BuildVersion.current(commit: "") == .release(SemVer(macxVersion)!))
    }

    @Test func aNewerStableReplacesADevBuildAndAnEqualOneDoesnt() throws {
        let dev = BuildVersion.dev(commit: "1a2b3c4", base: v030)
        #expect(BuildVersion.release(try #require(SemVer("0.4.0"))).replaces(dev))
        #expect(!BuildVersion.release(v030).replaces(dev))
        #expect(!BuildVersion.release(try #require(SemVer("0.2.0"))).replaces(dev))
    }

    @Test func aDevBuildReplacesItsBaseAndOtherCommitsButNotItself() throws {
        let dev = BuildVersion.dev(commit: "1a2b3c4", base: v030)
        #expect(dev.replaces(.release(v030)))
        #expect(!dev.replaces(.release(try #require(SemVer("0.3.1")))))
        #expect(dev.replaces(.dev(commit: "9f9f9f9", base: v030)))
        #expect(!dev.replaces(.dev(commit: "1a2b3c4", base: v030)))
        #expect(!dev.replaces(.dev(commit: "1a2b3c4d5e6f", base: v030)))  // same commit, longer name
        #expect(!dev.replaces(.dev(commit: "9f9f9f9", base: try #require(SemVer("0.4.0")))))
    }

    @Test func matchesWhatTheDownloadReports() {
        let dev = BuildVersion.dev(commit: "1a2b3c4", base: v030)
        #expect(dev.matches(reported: "dev-1a2b3c4"))
        #expect(dev.matches(reported: "dev-1a2b3c4d5"))
        #expect(!dev.matches(reported: "dev-9f9f9f9"))
        #expect(!dev.matches(reported: "0.3.0"))
        #expect(BuildVersion.release(v030).matches(reported: "0.3.0"))
        #expect(!BuildVersion.release(v030).matches(reported: "dev-1a2b3c4"))
    }
}

// MARK: - Verifier roles

@Suite("Beta channel signature")
struct BetaSignatureTests {
    @Test func verifiesWithTheBetaKey() throws {
        let s = TestSigner()
        let (json, sig) = try s.sign(beta())
        let b = try BetaVerifier(publicKeys: [s.publicKey]).verify(json: json, signature: sig)
        #expect(b.build.commit == "1a2b3c4")
        #expect(b.sequence == 7)
    }

    @Test func aStableFileSignedWithTheBetaKeyIsRejected() throws {
        let betaKey = TestSigner()
        let (json, sig) = try betaKey.sign(channel())
        // The stable verifier never trusts the beta key, and the beta verifier won't read a stable file.
        #expect(throws: UpdateError.badSignature) {
            try ChannelVerifier(publicKeys: UpdateKeys.trusted).verify(json: json, signature: sig)
        }
        #expect(throws: UpdateError.badChannel) { try BetaVerifier(publicKeys: [betaKey.publicKey]).verify(json: json, signature: sig) }
    }

    @Test func aBetaFileSignedWithTheStableKeyIsRejected() throws {
        let stableKey = TestSigner()
        let (json, sig) = try stableKey.sign(beta())
        #expect(throws: UpdateError.badSignature) {
            try BetaVerifier(publicKeys: [TestSigner().publicKey]).verify(json: json, signature: sig)
        }
        // Even if one key were somehow in both lists, the stable verifier refuses a file that says it's beta.
        #expect(throws: UpdateError.badChannel) {
            try ChannelVerifier(publicKeys: [stableKey.publicKey]).verify(json: json, signature: sig)
        }
    }

    @Test func theKeyListsNeverOverlap() {
        #expect(Set(UpdateKeys.trusted).isDisjoint(with: Set(UpdateKeys.beta)))
    }

    @Test func aBetaFileCarryingAFloorOrTheHashFeedIsRejected() throws {
        let s = TestSigner()
        let v = BetaVerifier(publicKeys: [s.publicKey])
        let body =
            #""build":{"base":"0.3.0","commit":"1a2b3c4","sha256":"def","url":"https://x/y"},"channel":"beta","#
            + #""expires":"2099-01-01T00:00:00Z","published":"2026-11-24T00:00:00Z","schema":1,"sequence":7"#
        let (ok, okSig) = try s.sign(json: "{\(body)}")
        #expect(try v.verify(json: ok, signature: okSig).build.base == "0.3.0")
        for extra in [#""minimumSafe":{"version":"9.9.9","reason":"x"}"#, #""hashFeed":{"url":"https://x","sha256":"a"}"#] {
            let (json, sig) = try s.sign(json: "{\(body),\(extra)}")
            #expect(throws: UpdateError.badChannel) { try v.verify(json: json, signature: sig) }
        }
        let (wrongRole, wrongSig) = try s.sign(json: "{\(body.replacingOccurrences(of: #""beta""#, with: #""stable""#))}")
        #expect(throws: UpdateError.badChannel) { try v.verify(json: wrongRole, signature: wrongSig) }
    }

    @Test func aBetaFileWithABadCommitOrBaseIsRejected() throws {
        let s = TestSigner()
        let v = BetaVerifier(publicKeys: [s.publicKey])
        for b in [beta(commit: "not-hex!"), beta(base: "latest")] {
            let (json, sig) = try s.sign(b)
            #expect(throws: UpdateError.badChannel) { try v.verify(json: json, signature: sig) }
        }
    }
}

// MARK: - State

@Suite("Update state per channel")
struct ChannelStateTests {
    @Test func oldStateFilesReadAsStable() throws {
        let old = #"{"lastCheck":"2026-11-24T00:00:00Z","lastSequence":9,"noticesOff":true}"#
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("update-state.json")
        try Data(old.utf8).write(to: file)
        let s = UpdateState.load(from: file)
        #expect(s.lastSequence == 9)
        #expect(s.noticesOff)
        #expect(s.channel == .stable)
        #expect(s.betaSequence == 0)
    }

    @Test func channelAndBetaSequenceRoundTrip() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("s.json")
        var s = UpdateState(lastSequence: 4)
        s.channel = .beta
        s.betaSequence = 12
        try s.save(to: file)
        #expect(UpdateState.load(from: file) == s)
    }

    @Test func switchingToBetaNeedsABetaKey() throws {
        var s = UpdateState()
        #expect(throws: UpdateError.betaNotOpen) { try s.switchChannel(to: .beta, betaKeys: []) }
        #expect(s.channel == .stable)
        try s.switchChannel(to: .beta, betaKeys: [TestSigner().publicKey])
        #expect(s.channel == .beta)
        try s.switchChannel(to: .stable, betaKeys: [])
        #expect(s.channel == .stable)
    }
}

// MARK: - Decisions with both files

@Suite("Update decisions with the beta channel")
struct BetaDecisionTests {
    func state(_ channel: ReleaseChannel, betaSequence: Int = 0) -> UpdateState {
        var s = UpdateState()
        s.channel = channel
        s.betaSequence = betaSequence
        return s
    }

    @Test func aStableMacIgnoresTheBetaFile() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(), installed: .release(v030), state: state(.stable), now: Date())
        #expect(d.action == .none)
    }

    @Test func aBetaMacGetsTheNewestDevBuild() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(commit: "1a2b3c4"), installed: .release(v030), state: state(.beta), now: Date())
        #expect(d.action == .notify("dev-1a2b3c4"))
        #expect(d.target?.beta == true)
        #expect(d.target?.sha256 == "def")
    }

    @Test func theSameCommitIsUpToDate() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(commit: "1a2b3c4"), installed: .dev(commit: "1a2b3c4", base: v030),
            state: state(.beta), now: Date())
        #expect(d.action == .none)
    }

    @Test func aNewerStableBeatsADevBuildOnAnOlderBase() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.4.0"), beta: beta(base: "0.3.0"), installed: .dev(commit: "9f9f9f9", base: v030),
            state: state(.beta), now: Date())
        #expect(d.action == .notify("0.4.0"))
        #expect(d.target?.beta == false)
    }

    @Test func aDevBuildOnTheNewStableBeatsThatStable() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.4.0"), beta: beta(base: "0.4.0"), installed: .dev(commit: "9f9f9f9", base: v030),
            state: state(.beta), now: Date())
        #expect(d.action == .notify("dev-1a2b3c4"))
    }

    @Test func aMacThatLeftBetaStaysUntilTheNextStable() {
        let dev = BuildVersion.dev(commit: "9f9f9f9", base: v030)
        let same = UpdateDecision.decide(stable: channel(latest: "0.3.0"), beta: beta(), installed: dev, state: state(.stable), now: Date())
        #expect(same.action == .none)
        let newer = UpdateDecision.decide(
            stable: channel(latest: "0.3.1"), beta: beta(), installed: dev, state: state(.stable), now: Date())
        #expect(newer.action == .notify("0.3.1"))
    }

    @Test func theStableFloorStillAppliesToBetaMacs() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.1", minimumSafe: "0.3.1"), beta: beta(base: "0.3.0"),
            installed: .dev(commit: "9f9f9f9", base: v030), state: state(.beta), now: Date())
        #expect(d.action == .force("0.3.1", reason: "a security bug"))
        #expect(d.target?.beta == false)
    }

    @Test func aBetaFileCanNeverForce() {
        // Even far below the floor's version, the beta file only ever produces a notice.
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(base: "0.3.0"), installed: .release(SemVer("0.2.0")!), state: state(.beta),
            now: Date())
        if case .force = d.action { Issue.record("a beta file forced an update") }
    }

    @Test func anOlderBetaFileIsARollback() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(sequence: 3), installed: .release(v030), state: state(.beta, betaSequence: 4),
            now: Date())
        #expect(d.action == .none)
        #expect(d.warnings.contains { $0.contains("rollback attempt") })
    }

    @Test func anExpiredBetaFileOffersNothing() {
        let d = UpdateDecision.decide(
            stable: channel(latest: "0.3.0"), beta: beta(expires: Date().addingTimeInterval(-60)), installed: .release(v030),
            state: state(.beta), now: Date())
        #expect(d.action == .none)
        #expect(d.warnings.contains { $0.contains("beta") && $0.contains("out of date") })
    }

    @Test func aStableRollbackStillLetsTheBetaBuildThrough() {
        var s = state(.beta)
        s.lastSequence = 10
        let d = UpdateDecision.decide(stable: channel(sequence: 5), beta: beta(), installed: .release(v030), state: s, now: Date())
        #expect(d.action == .notify("dev-1a2b3c4"))
        #expect(d.warnings.contains { $0.contains("rollback attempt") })
    }

    @Test func theOldStableOnlyDecisionIsUnchanged() {
        let d = UpdateDecision.decide(channel(latest: "0.4.0"), installed: v030, state: UpdateState(), now: Date())
        #expect(d.action == .notify("0.4.0"))
    }
}

// MARK: - Installing a dev build

@Suite("Installing a dev build")
struct DevInstallTests {
    @Test func installsADevBuildThatReportsItsCommit() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let data = try UpdateInstallTests().tarball(tmp)
        try UpdateInstaller(versionOf: { _ in "dev-1a2b3c4" }).install(
            data, sha256: sha256(data), expecting: .dev(commit: "1a2b3c4", base: v030), over: target, installed: .release(v030))
        #expect(try Data(contentsOf: target) == Data(contentsOf: URL(fileURLWithPath: "/bin/ls")))
    }

    @Test func refusesADevBuildThatReportsAnotherCommitOrTheSameOne() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let data = try UpdateInstallTests().tarball(tmp)
        #expect(throws: UpdateError.versionMismatch) {
            try UpdateInstaller(versionOf: { _ in "dev-9f9f9f9" }).install(
                data, sha256: sha256(data), expecting: .dev(commit: "1a2b3c4", base: v030), over: target, installed: .release(v030))
        }
        #expect(throws: UpdateError.notNewer) {
            try UpdateInstaller(versionOf: { _ in "dev-1a2b3c4" }).install(
                data, sha256: sha256(data), expecting: .dev(commit: "1a2b3c4", base: v030), over: target,
                installed: .dev(commit: "1a2b3c4", base: v030))
        }
        #expect(try tmp.read("bin/macx") == "old binary")
    }

    @Test func theBundleKeepsANumericShortVersion() {
        let info = UpdateInstaller.updatedInfo([:], version: BuildVersion.dev(commit: "1a2b3c4", base: v030))
        #expect(info["CFBundleShortVersionString"] as? String == "0.3.0")
        #expect(info["CFBundleVersion"] as? String == "dev-1a2b3c4")
    }
}
