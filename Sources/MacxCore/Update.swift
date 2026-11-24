import CryptoKit
import Foundation

// MARK: - Version

public let macxVersion = "0.2.0"

/// Semantic version: MAJOR.MINOR.PATCH with an optional -pre.release part (sorted before the release).
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var pre: [String]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = parts.first?.split(separator: ".").map { Int($0) } ?? []
        guard nums.count == 3, let a = nums[0], let b = nums[1], let c = nums[2] else { return nil }
        major = a
        minor = b
        patch = c
        pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    public var description: String { "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }

    public static func == (a: SemVer, b: SemVer) -> Bool { (a.major, a.minor, a.patch, a.pre) == (b.major, b.minor, b.patch, b.pre) }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        if a.pre.isEmpty != b.pre.isEmpty { return !a.pre.isEmpty }  // 1.0.0-beta < 1.0.0
        for (x, y) in zip(a.pre, b.pre) where x != y {
            if let i = Int(x), let j = Int(y) { return i < j }
            return x < y
        }
        return a.pre.count < b.pre.count
    }
}

// MARK: - Channel

/// The signed file on GitHub Pages that says what the latest version is and which versions are no longer safe.
public struct UpdateChannel: Codable, Sendable, Equatable {
    public struct Release: Codable, Sendable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String
        public var notes: String?
    }

    public struct Floor: Codable, Sendable, Equatable {
        public var version: String
        public var reason: String
        public var advisory: String?
    }

    /// The malware hash feed: its SHA-256 here is what makes the separately downloaded feed trustworthy.
    public struct Feed: Codable, Sendable, Equatable {
        public var url: String
        public var sha256: String
        public var count: Int?
    }

    public var schema: Int
    /// Goes up with every published file. A lower number than one already seen is a rollback attempt.
    public var sequence: Int
    public var published: Date
    /// After this the file counts as stale: still shown, but it can't force anything (protects against replays).
    public var expires: Date
    public var latest: Release
    public var minimumSafe: Floor?
    public var hashFeed: Feed?

    public init(schema: Int, sequence: Int, published: Date, expires: Date, latest: Release, minimumSafe: Floor?, hashFeed: Feed? = nil) {
        self.schema = schema
        self.sequence = sequence
        self.published = published
        self.expires = expires
        self.latest = latest
        self.minimumSafe = minimumSafe
        self.hashFeed = hashFeed
    }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case badSignature, badChannel, hashMismatch, notAProgram, versionMismatch, notNewer
    case download(String)

    public var description: String {
        switch self {
        case .badSignature: "the update file's signature didn't check out, so it was ignored"
        case .badChannel: "the update file couldn't be read"
        case .hashMismatch: "the download didn't match the signed SHA-256"
        case .notAProgram: "the download wasn't a macx program"
        case .versionMismatch: "the downloaded macx reports a different version than the signed file says"
        case .notNewer: "the download isn't newer than what's installed"
        case .download(let m): "the download failed: \(m)"
        }
    }
}

/// Public keys whose signatures macx accepts. The private key lives only in the repo's protected
/// `release` environment (and Lao's offline backup). Listing two keys here is how a key is rotated.
public enum UpdateKeys {
    public static let trusted: [Data] = ["yhabe5LDBMXnyr53BMKFv2RThR7fnng6MvI3ZmJQJgs="].compactMap { Data(base64Encoded: $0) }
}

public struct ChannelVerifier: Sendable {
    public var publicKeys: [Data]
    public init(publicKeys: [Data] = UpdateKeys.trusted) { self.publicKeys = publicKeys }

    public func verify(json: Data, signature: Data) throws -> UpdateChannel {
        let ok = publicKeys.contains { key in
            (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(signature, for: json) ?? false
        }
        guard ok else { throw UpdateError.badSignature }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(UpdateChannel.self, from: json), c.schema == 1 else { throw UpdateError.badChannel }
        return c
    }
}

// MARK: - State and decisions

public struct UpdateState: Codable, Sendable, Equatable {
    public var lastCheck: Date?
    public var lastSequence: Int
    /// Turns off the "new version" notices. The security-floor check can't be turned off.
    public var noticesOff: Bool

    public init(lastCheck: Date? = nil, lastSequence: Int = 0, noticesOff: Bool = false) {
        self.lastCheck = lastCheck
        self.lastSequence = lastSequence
        self.noticesOff = noticesOff
    }

    public func isCheckDue(now: Date) -> Bool { lastCheck.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/update-state.json")
    }

    public static func load(from file: URL = defaultFile) -> UpdateState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode(UpdateState.self, from: $0) } ?? UpdateState()
    }

    public func save(to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: file, options: .atomic)
    }
}

public struct UpdateDecision: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case notify(String)
        case force(String, reason: String)
    }

    public var action: Action
    public var warnings: [String]

    public static func decide(_ c: UpdateChannel, installed: SemVer, state: UpdateState, now: Date) -> UpdateDecision {
        var warnings: [String] = []
        if c.sequence < state.lastSequence {
            warnings.append("The update file is older than one macx has already seen, so it was ignored (a rollback attempt?).")
            return UpdateDecision(action: .none, warnings: warnings)
        }
        let stale = now > c.expires
        if stale {
            warnings.append(
                "The update file is out of date (it expired \(ISO8601DateFormatter().string(from: c.expires))), so it can't force an update."
            )
        }
        guard let latest = SemVer(c.latest.version), latest > installed else { return UpdateDecision(action: .none, warnings: warnings) }
        if !stale, let floor = c.minimumSafe, let f = SemVer(floor.version), installed < f {
            return UpdateDecision(action: .force(c.latest.version, reason: floor.reason), warnings: warnings)
        }
        return UpdateDecision(action: .notify(c.latest.version), warnings: warnings)
    }
}

// MARK: - Installing

/// Checks a downloaded update and swaps it in. The old binary is kept as `macx.previous`.
public struct UpdateInstaller: Sendable {
    /// What version a binary reports (`macx --version`). Injected so tests don't need a real macx.
    var versionOf: @Sendable (URL) -> String?

    public init(versionOf: @escaping @Sendable (URL) -> String? = UpdateInstaller.reportedVersion) { self.versionOf = versionOf }

    public static func reportedVersion(_ binary: URL) -> String? {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--version"]
        var env = ProcessInfo.processInfo.environment
        env["MACX_NO_UPDATE_CHECK"] = "1"
        env["MACX_OWN_RESPONSIBILITY"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func install(_ tarball: Data, sha256 expected: String, version: String, over target: URL, installed: SemVer) throws {
        guard sha256(tarball) == expected.lowercased() else { throw UpdateError.hashMismatch }
        guard let v = SemVer(version), v > installed else { throw UpdateError.notNewer }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macx-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let tgz = work.appendingPathComponent("update.tar.gz")
        try tarball.write(to: tgz)

        // Only a top-level regular file called macx is taken: no paths, no links, nothing else.
        let listing = (try? ProcessRunner().run("/usr/bin/tar", ["-tzf", tgz.path])) ?? ""
        let names = listing.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        guard names.contains("macx") else { throw UpdateError.notAProgram }
        let out = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        let member = listing.split(separator: "\n").map(String.init).first { $0 == "macx" || $0 == "./macx" } ?? "macx"
        _ = try? ProcessRunner().run("/usr/bin/tar", ["-xzf", tgz.path, "-C", out.path, member])
        let binary = out.appendingPathComponent("macx")
        let attrs = try? fm.attributesOfItem(atPath: binary.path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular,
            let head = try? FileHandle(forReadingFrom: binary).read(upToCount: 4096), !MachO.architectures(of: head).isEmpty
        else { throw UpdateError.notAProgram }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard let reported = versionOf(binary), SemVer(reported) == v else { throw UpdateError.versionMismatch }

        // Copy next to the target, then rename over it: the swap is atomic, and on any failure the old binary stays.
        let dir = target.deletingLastPathComponent()
        let staged = dir.appendingPathComponent(".macx.new-\(UUID().uuidString)")
        try fm.copyItem(at: binary, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let bundle = Self.enclosingApp(of: target)
        if fm.fileExists(atPath: target.path) {
            // Inside an app the previous binary can't sit next to the new one (it would break the bundle's seal).
            let previousDir =
                bundle == nil ? dir : fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed")
            try? fm.createDirectory(at: previousDir, withIntermediateDirectories: true)
            let previous = previousDir.appendingPathComponent("macx.previous")
            try? fm.removeItem(at: previous)
            try? fm.copyItem(at: target, to: previous)
        }
        guard rename(staged.path, target.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError.download("couldn't replace \(target.path)")
        }
        if let bundle { try Self.reseal(bundle, version: version) }
    }

    /// `…/Macximesed.app` when the binary is the app's main executable (`Contents/MacOS/...`).
    public static func enclosingApp(of exe: URL) -> URL? {
        let macos = exe.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return macos.lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents" && app.pathExtension == "app" ? app : nil
    }

    /// After swapping the executable, update the bundle's version and sign the bundle again (ad-hoc), so
    /// its signature covers the new binary and Info.plist.
    static func reseal(_ app: URL, version: String) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
            var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            info["CFBundleShortVersionString"] = version
            info["CFBundleVersion"] = version
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
        }
        let id =
            (try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])?[
                "CFBundleIdentifier"] as? String ?? "dev.macximesed.macx"
        // Same identity install.sh used, so the app keeps its Full Disk Access after the update.
        let sign = SigningIdentity.codesignArgument(SigningIdentity.preferred())
        // Keep the entitlements too, or an update would take the chamber's Virtualization permission away.
        let entitlements = FileManager.default.temporaryDirectory.appendingPathComponent("macx-\(UUID().uuidString).entitlements")
        try Data(SigningIdentity.entitlementsPlist.utf8).write(to: entitlements)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        let args = SigningIdentity.resealArguments(sign: sign, id: id, app: app, entitlements: entitlements)
        guard ProcessRunner.capture("/usr/bin/codesign", args)?.status == 0 else {
            throw UpdateError.download("updated, but couldn't re-sign \(app.path)")
        }
    }
}

// MARK: - Fetching

public enum UpdateClient {
    public static let channelURL = URL(string: "https://laouuuuu.github.io/Macximesed/channel/v1.json")!

    /// Fetches the channel file and its signature, and verifies it. Short timeout: this runs before commands.
    public static func fetchChannel(timeout: TimeInterval = 5, verifier: ChannelVerifier = ChannelVerifier()) throws -> UpdateChannel {
        let json = try get(channelURL, timeout: timeout)
        let sig = try get(channelURL.appendingPathExtension("sig"), timeout: timeout)
        return try verifier.verify(json: json, signature: sig)
    }

    public static func get(_ url: URL, timeout: TimeInterval) throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 120)
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        var req = URLRequest(url: url)
        req.setValue("macx/\(macxVersion)", forHTTPHeaderField: "User-Agent")
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(UpdateError.download("no answer"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, (200..<300).contains(status) {
                result = .success(data)
            } else {
                result = .failure(UpdateError.download(error?.localizedDescription ?? "HTTP \(status)"))
            }
            done.signal()
        }.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return try result.get()
    }
}

// MARK: - Signing identity

/// The code-signing identity macx is signed with. An "Apple Development" certificate (free from Xcode)
/// gives macOS a stable identity, so privacy permissions like Full Disk Access survive rebuilds and
/// updates; ad-hoc signing doesn't. install.sh and the updater must use the same one.
public struct SigningIdentity: Sendable, Equatable {
    /// The app's entitlements: the Virtualization framework, for the detonation chamber. Kept identical to
    /// scripts/macx.entitlements (a test checks), so install.sh and the updater sign the same way.
    public static let entitlementsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>com.apple.security.virtualization</key>
        \t<true/>
        </dict>
        </plist>

        """

    static func resealArguments(sign: String, id: String, app: URL, entitlements: URL) -> [String] {
        ["--force", "--sign", sign, "--identifier", id, "--entitlements", entitlements.path, app.path]
    }

    public var hash: String
    public var name: String

    public init(hash: String, name: String) {
        self.hash = hash
        self.name = name
    }

    /// The identity to sign with, from `security find-identity -p codesigning` output: a valid "Apple
    /// Development" identity first, otherwise the local self-signed "Macximesed Local Signing" one. That one
    /// is never "trusted" (it's self-signed), which doesn't matter: its certificate still gives a stable
    /// designated requirement. Expired or revoked identities are skipped.
    public static func parse(findIdentityOutput: String) -> SigningIdentity? {
        guard let re = try? NSRegularExpression(pattern: #"^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"\s*(\(([A-Z_]+)\))?\s*$"#) else {
            return nil
        }
        var development: SigningIdentity?
        var local: SigningIdentity?
        for line in findIdentityOutput.split(separator: "\n").map(String.init) {
            guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                let h = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line)
            else { continue }
            let problem = Range(m.range(at: 4), in: line).map { String(line[$0]) }
            let id = SigningIdentity(hash: String(line[h]), name: String(line[n]))
            if id.name.hasPrefix("Apple Development: "), problem == nil, development == nil { development = id }
            if id.name == "Macximesed Local Signing", problem == nil || problem == "CSSMERR_TP_NOT_TRUSTED", local == nil { local = id }
        }
        return development ?? local
    }

    /// `MACX_SIGN_IDENTITY` if set, else the first Apple Development identity in the keychain, else nil (ad-hoc).
    public static func preferred(runner: CommandRunner = ProcessRunner(timeout: 15)) -> SigningIdentity? {
        if let forced = ProcessInfo.processInfo.environment["MACX_SIGN_IDENTITY"], !forced.isEmpty {
            return forced == "-" ? nil : SigningIdentity(hash: forced, name: forced)
        }
        guard let out = try? runner.run("/usr/bin/security", ["find-identity", "-p", "codesigning"]) else { return nil }
        return parse(findIdentityOutput: out)
    }

    /// What to pass to `codesign --sign`.
    public static func codesignArgument(_ identity: SigningIdentity?) -> String { identity?.hash ?? "-" }
}
