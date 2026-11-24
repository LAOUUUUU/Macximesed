import CryptoKit
import Foundation

// MARK: - Build versions

/// What a macx build is: a release (`0.3.0`) or a dev build named by its commit (`dev-1a2b3c4`), which also knows the
/// release it comes after. Which dev build is newest comes from the signed beta file's sequence, not from the name.
public enum BuildVersion: Sendable, Equatable, CustomStringConvertible {
    case release(SemVer)
    case dev(commit: String, base: SemVer)

    /// This build: a dev build when the beta workflow stamped a commit into BuildInfo.swift.
    public static var current: BuildVersion { current(commit: macxBuildCommit) }

    static func current(commit: String?) -> BuildVersion {
        let base = SemVer(macxVersion)!
        guard let c = commit.flatMap(normalizedCommit) else { return .release(base) }
        return .dev(commit: c, base: base)
    }

    /// Lowercase hex, 7 to 40 characters, or nil.
    static func normalizedCommit(_ text: String) -> String? {
        let c = text.lowercased()
        guard (7...40).contains(c.count), c.allSatisfy(\.isHexDigit) else { return nil }
        return c
    }

    /// `dev-<commit>` (with the base it was built after) or a release version.
    public static func parse(_ text: String, base: SemVer) -> BuildVersion? {
        if text.hasPrefix("dev-") {
            return normalizedCommit(String(text.dropFirst(4))).map { .dev(commit: $0, base: base) }
        }
        return SemVer(text).map { .release($0) }
    }

    public var description: String {
        switch self {
        case .release(let v): v.description
        case .dev(let c, _): "dev-" + c
        }
    }

    /// The release this build is at least: itself, or the one a dev build comes after. The security floor checks this.
    public var base: SemVer {
        switch self {
        case .release(let v), .dev(_, let v): v
        }
    }

    public var isDev: Bool {
        if case .dev = self { return true }
        return false
    }

    /// Whether installing this over `installed` moves forward:
    /// - a release replaces anything older than it (a dev build counts as its base);
    /// - a dev build replaces its own base release (or an older one) and any other commit on the same or an older base.
    public func replaces(_ installed: BuildVersion) -> Bool {
        switch (self, installed) {
        case (.release(let new), _): new > installed.base
        case (.dev(_, let base), .release(let old)): base >= old
        case (.dev(let c, let base), .dev(let oldC, let oldBase)): base >= oldBase && !Self.sameCommit(c, oldC)
        }
    }

    /// Whether `macx --version` from a download says it's this build.
    public func matches(reported: String) -> Bool {
        switch self {
        case .release(let v): SemVer(reported) == v && !reported.hasPrefix("dev-")
        case .dev(let c, _):
            reported.hasPrefix("dev-") && Self.normalizedCommit(String(reported.dropFirst(4))).map { Self.sameCommit($0, c) } == true
        }
    }

    /// Short and long names of one commit are the same commit.
    static func sameCommit(_ a: String, _ b: String) -> Bool { a.hasPrefix(b) || b.hasPrefix(a) }
}

// MARK: - The beta file

public enum ReleaseChannel: String, Codable, Sendable, CaseIterable {
    case stable, beta
}

/// The signed file that names the newest dev build. Its own key, its own sequence and a short expiry. It can't carry
/// the security floor or the malware feed: those only come from the stable file.
public struct BetaChannel: Codable, Sendable, Equatable {
    public struct Build: Codable, Sendable, Equatable {
        public var commit: String
        /// The release this build comes after (`macxVersion` at that commit).
        public var base: String
        public var url: String
        public var sha256: String
        public var notes: String?

        public init(commit: String, base: String, url: String, sha256: String, notes: String?) {
            self.commit = commit
            self.base = base
            self.url = url
            self.sha256 = sha256
            self.notes = notes
        }
    }

    public var schema: Int
    public var channel: String
    public var sequence: Int
    public var published: Date
    public var expires: Date
    public var build: Build

    public init(sequence: Int, published: Date, expires: Date, build: Build) {
        schema = 1
        channel = ReleaseChannel.beta.rawValue
        self.sequence = sequence
        self.published = published
        self.expires = expires
        self.build = build
    }

    /// The build this file names, or nil if its commit or base can't be read.
    public var version: BuildVersion? {
        guard let base = SemVer(build.base), let c = BuildVersion.normalizedCommit(build.commit) else { return nil }
        return .dev(commit: c, base: base)
    }
}

public struct BetaVerifier: Sendable {
    public var publicKeys: [Data]
    public init(publicKeys: [Data] = UpdateKeys.beta) { self.publicKeys = publicKeys }

    /// Fields only the stable file may carry. A beta file with any of them is refused, even when signed.
    static let stableOnly: Set<String> = ["minimumSafe", "hashFeed", "latest"]

    public func verify(json: Data, signature: Data) throws -> BetaChannel {
        guard ChannelVerifier.signed(json, signature, by: publicKeys) else { throw UpdateError.badSignature }
        guard let top = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            Self.stableOnly.isDisjoint(with: top.keys)
        else { throw UpdateError.badChannel }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let b = try? dec.decode(BetaChannel.self, from: json), b.schema == 1, b.channel == ReleaseChannel.beta.rawValue,
            b.version != nil
        else { throw UpdateError.badChannel }
        return b
    }
}
