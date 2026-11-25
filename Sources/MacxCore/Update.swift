import CryptoKit
import Foundation

// MARK: - Version

public let macxVersion = "0.4.0"

/// Semantic version: MAJOR.MINOR.PATCH with an optional -pre.release part (sorted before the release). A `+build`
/// part is ignored, as SemVer says: it never changes the order.
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var pre: [String]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
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
        /// The whole app, signed on CI with the release certificate (`Macximesed-X.Y.Z-app.tar.gz`). Installs from
        /// the .pkg or .dmg update with it; older clients ignore it.
        public var app: Asset?
    }

    public struct Asset: Codable, Sendable, Equatable {
        public var url: String
        public var sha256: String
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
    /// Absent in stable files. A file that says anything else (a beta file) is never read as the stable channel.
    public var channel: String?

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
    case needsUser, signingIdentityMissing, identityChanged, appSignatureInvalid, betaNotOpen
    case download(String)

    public var description: String {
        switch self {
        case .badSignature: "the update file's signature didn't check out, so it was ignored"
        case .badChannel: "the update file couldn't be read"
        case .hashMismatch: "the download didn't match the signed SHA-256"
        case .notAProgram: "the download wasn't a macx program"
        case .versionMismatch: "the downloaded macx reports a different version than the signed file says"
        case .notNewer: "the download isn't newer than what's installed"
        case .needsUser: "updates install as you, not as root (run `macx update` without sudo)"
        case .signingIdentityMissing:
            "the identity Macximesed.app is signed with isn't available, so the update was held back (installing it would cost the app its Full Disk Access)"
        case .identityChanged: "after the update macOS would have seen a different app, so the previous version was put back"
        case .appSignatureInvalid: "the downloaded app's signature didn't check out, so it wasn't installed"
        case .betaNotOpen: "the beta channel isn't open yet (its signing key hasn't been set up), so you stay on stable"
        case .download(let m): "the download failed: \(m)"
        }
    }
}

/// Public keys whose signatures macx accepts. The private key lives only in the repo's protected
/// `release` environment (and Lao's offline backup). Listing two keys here is how a key is rotated.
public enum UpdateKeys {
    public static let trusted: [Data] = ["yhabe5LDBMXnyr53BMKFv2RThR7fnng6MvI3ZmJQJgs="].compactMap { Data(base64Encoded: $0) }
    /// Keys for the beta file only. Its private key signs dev builds automatically in the `beta` environment, so it is
    /// never trusted for stable files (a test checks the lists don't overlap). Empty until that key exists.
    public static let beta: [Data] = ["XaJLgtPPlhTYNgmwnZk8bwhJGV0QPwXMdkG7V5adkyE="].compactMap { Data(base64Encoded: $0) }
}

public struct ChannelVerifier: Sendable {
    public var publicKeys: [Data]
    public init(publicKeys: [Data] = UpdateKeys.trusted) { self.publicKeys = publicKeys }

    public func verify(json: Data, signature: Data) throws -> UpdateChannel {
        guard Self.signed(json, signature, by: publicKeys) else { throw UpdateError.badSignature }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(UpdateChannel.self, from: json), c.schema == 1, c.channel == nil || c.channel == "stable" else {
            throw UpdateError.badChannel
        }
        return c
    }

    static func signed(_ json: Data, _ signature: Data, by keys: [Data]) -> Bool {
        keys.contains { key in
            (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(signature, for: json) ?? false
        }
    }
}

/// A channel file that passed verification, with the bytes that were signed.
public struct SignedChannel: Sendable {
    public var channel: UpdateChannel
    public var json: Data
    public var signature: Data
}

// MARK: - State and decisions

public struct UpdateState: Codable, Sendable, Equatable {
    public var lastCheck: Date?
    /// The highest stable sequence seen.
    public var lastSequence: Int
    /// Turns off the "new version" notices. The security-floor check can't be turned off.
    public var noticesOff: Bool
    /// Which builds this Mac takes. The stable file (floor, hash feed) is read on both.
    public var channel: ReleaseChannel
    /// The highest beta sequence seen: kept apart from the stable one, since the two files count separately.
    public var betaSequence: Int

    public init(lastCheck: Date? = nil, lastSequence: Int = 0, noticesOff: Bool = false) {
        self.lastCheck = lastCheck
        self.lastSequence = lastSequence
        self.noticesOff = noticesOff
        channel = .stable
        betaSequence = 0
    }

    // State files written before the beta channel have no channel or beta sequence: they read as stable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastSequence = try c.decodeIfPresent(Int.self, forKey: .lastSequence) ?? 0
        noticesOff = try c.decodeIfPresent(Bool.self, forKey: .noticesOff) ?? false
        channel = (try? c.decodeIfPresent(ReleaseChannel.self, forKey: .channel)) ?? .stable
        betaSequence = try c.decodeIfPresent(Int.self, forKey: .betaSequence) ?? 0
    }

    /// Beta needs a beta key to check its file against; without one there's nothing it could install.
    public mutating func switchChannel(to new: ReleaseChannel, betaKeys: [Data] = UpdateKeys.beta) throws {
        if new == .beta, betaKeys.isEmpty { throw UpdateError.betaNotOpen }
        channel = new
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

/// The build an update would install, from whichever signed file named it.
public struct UpdateTarget: Sendable, Equatable {
    public var version: BuildVersion
    public var url: String
    public var sha256: String
    /// From the beta file. A beta target is only ever offered, never forced.
    public var beta: Bool
    /// The whole signed app, for release-signed installs (stable releases only).
    public var app: UpdateChannel.Asset? = nil
}

public struct UpdateDecision: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case notify(String)
        case force(String, reason: String)
    }

    public var action: Action
    public var warnings: [String]
    public var target: UpdateTarget? = nil

    /// Stable only, for a release build.
    public static func decide(_ c: UpdateChannel, installed: SemVer, state: UpdateState, now: Date) -> UpdateDecision {
        var s = state
        s.channel = .stable
        return decide(stable: c, beta: nil, installed: .release(installed), state: s, now: now)
    }

    /// The stable file always counts (its security floor applies on beta too); the beta file only on beta Macs.
    /// A newer stable wins over a dev build on an older base; otherwise a beta Mac gets the newest dev build.
    public static func decide(stable c: UpdateChannel?, beta b: BetaChannel?, installed: BuildVersion, state: UpdateState, now: Date)
        -> UpdateDecision
    {
        var warnings: [String] = []
        var stableTarget: UpdateTarget?
        var floorReason: String?
        if let c {
            if c.sequence < state.lastSequence {
                warnings.append("The update file is older than one macx has already seen, so it was ignored (a rollback attempt?).")
            } else {
                let stale = now > c.expires
                if stale {
                    warnings.append(
                        "The update file is out of date (it expired \(ISO8601DateFormatter().string(from: c.expires))), so it can't force an update."
                    )
                }
                if let latest = SemVer(c.latest.version), BuildVersion.release(latest).replaces(installed) {
                    stableTarget = UpdateTarget(
                        version: .release(latest), url: c.latest.url, sha256: c.latest.sha256, beta: false, app: c.latest.app)
                    if !stale, let floor = c.minimumSafe, let f = SemVer(floor.version), installed.base < f { floorReason = floor.reason }
                }
            }
        }
        if let stableTarget, let floorReason {
            return UpdateDecision(
                action: .force(stableTarget.version.description, reason: floorReason), warnings: warnings, target: stableTarget)
        }

        var betaTarget: UpdateTarget?
        if state.channel == .beta, let b {
            if b.sequence < state.betaSequence {
                warnings.append("The beta file is older than one macx has already seen, so it was ignored (a rollback attempt?).")
            } else if now > b.expires {
                warnings.append(
                    "The beta file is out of date (it expired \(ISO8601DateFormatter().string(from: b.expires))), so no beta build is offered."
                )
            } else if let v = b.version, v.replaces(installed) {
                betaTarget = UpdateTarget(version: v, url: b.build.url, sha256: b.build.sha256, beta: true)
            }
        }

        let pick: UpdateTarget? =
            switch (stableTarget, betaTarget) {
            case (let s?, let d?): s.version.base > d.version.base ? s : d
            case (let s, let d): s ?? d
            }
        guard let pick else { return UpdateDecision(action: .none, warnings: warnings) }
        return UpdateDecision(action: .notify(pick.version.description), warnings: warnings, target: pick)
    }
}

// MARK: - Installing

/// Checks a downloaded update and swaps it in. The old binary is kept as `macx.previous`.
public struct UpdateInstaller: Sendable {
    /// What version a binary reports (`macx --version`). Injected so tests don't need a real macx.
    var versionOf: @Sendable (URL) -> String?
    var signer: AppSigner
    var isRoot: Bool
    /// Where the previous binary of an app bundle is kept (it can't sit inside the bundle).
    var previousFolder: URL

    public init(
        versionOf: @escaping @Sendable (URL) -> String? = UpdateInstaller.reportedVersion, signer: AppSigner = RealAppSigner(),
        isRoot: Bool = geteuid() == 0,
        previousFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Macximesed")
    ) {
        self.versionOf = versionOf
        self.signer = signer
        self.isRoot = isRoot
        self.previousFolder = previousFolder
    }

    /// Signed with a real identity (its requirement names a certificate), so Full Disk Access survives re-signing
    /// with the same identity. An ad-hoc requirement is a cdhash: it changes with every build anyway.
    public static func isStable(_ requirement: String?) -> Bool {
        guard let r = requirement else { return false }
        return r.contains("certificate leaf") || r.contains("anchor apple")
    }

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
        guard let v = SemVer(version) else { throw UpdateError.notNewer }
        try install(tarball, sha256: expected, expecting: .release(v), over: target, installed: .release(installed))
    }

    public func install(_ tarball: Data, sha256 expected: String, expecting v: BuildVersion, over target: URL, installed: BuildVersion)
        throws
    {
        // As root, the user's signing identity (in their login keychain) isn't reachable and files would end up
        // root-owned: the update would cost the app its Full Disk Access. It waits for the user.
        guard !isRoot else { throw UpdateError.needsUser }
        guard sha256(tarball) == expected.lowercased() else { throw UpdateError.hashMismatch }
        guard v.replaces(installed) else { throw UpdateError.notNewer }
        // Inside the app: check the identity is here *before* touching anything.
        let bundleBefore = Self.enclosingApp(of: target)
        let requirementBefore = bundleBefore.flatMap(signer.designatedRequirement(of:))
        let identity = signer.preferredIdentity()
        if Self.isStable(requirementBefore), identity == nil { throw UpdateError.signingIdentityMissing }

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
        guard let reported = versionOf(binary), v.matches(reported: reported) else { throw UpdateError.versionMismatch }

        // Copy next to the target, then rename over it: the swap is atomic, and on any failure the old binary stays.
        let dir = target.deletingLastPathComponent()
        let staged = dir.appendingPathComponent(".macx.new-\(UUID().uuidString)")
        try fm.copyItem(at: binary, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let bundle = Self.enclosingApp(of: target)
        if fm.fileExists(atPath: target.path) {
            // Inside an app the previous binary can't sit next to the new one (it would break the bundle's seal).
            let previousDir = bundle == nil ? dir : previousFolder
            try? fm.createDirectory(at: previousDir, withIntermediateDirectories: true)
            let previous = previousDir.appendingPathComponent("macx.previous")
            try? fm.removeItem(at: previous)
            try? fm.copyItem(at: target, to: previous)
        }
        guard rename(staged.path, target.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError.download("couldn't replace \(target.path)")
        }
        guard let bundle else { return }
        try Self.reseal(bundle, version: v, identity: identity, signer: signer)
        // macOS ties Full Disk Access to this requirement. If it moved, put the previous version back.
        if Self.isStable(requirementBefore), signer.designatedRequirement(of: bundle) != requirementBefore {
            let previous = previousFolder.appendingPathComponent("macx.previous")
            let back = dir.appendingPathComponent(".macx.back-\(UUID().uuidString)")
            if (try? fm.copyItem(at: previous, to: back)) != nil, rename(back.path, target.path) == 0 {
                try? Self.reseal(bundle, version: installed, identity: identity, signer: signer)
            }
            throw UpdateError.identityChanged
        }
    }

    /// The update for an app signed with the release certificate (from the .pkg or .dmg): the user doesn't have
    /// that certificate, so the binary can't be re-signed here. CI's signed app is swapped in whole instead, and
    /// only if macOS would see the same app (same designated requirement), so Full Disk Access carries over and
    /// an app signed by anyone else never gets in.
    public func installApp(_ archive: Data, sha256 expected: String, version: String, over app: URL, installed: SemVer) throws {
        guard !isRoot else { throw UpdateError.needsUser }
        guard sha256(archive) == expected.lowercased() else { throw UpdateError.hashMismatch }
        guard let v = SemVer(version), v > installed else { throw UpdateError.notNewer }
        let requirementBefore = signer.designatedRequirement(of: app)
        guard Self.isStable(requirementBefore) else { throw UpdateError.identityChanged }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macx-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let tgz = work.appendingPathComponent("update.tar.gz")
        try archive.write(to: tgz)

        // Only Macximesed.app at the top, no absolute paths, no "..".
        let listing = (try? ProcessRunner().run("/usr/bin/tar", ["-tzf", tgz.path])) ?? ""
        let names = listing.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }.filter { !$0.isEmpty }
        let name = app.lastPathComponent
        guard !names.isEmpty,
            names.allSatisfy({ ($0 == name || $0 == name + "/" || $0.hasPrefix(name + "/")) && !$0.split(separator: "/").contains("..") })
        else { throw UpdateError.notAProgram }
        let out = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        _ = try? ProcessRunner().run("/usr/bin/tar", ["-xzf", tgz.path, "-C", out.path])
        let new = out.appendingPathComponent(name)
        // Plain files and folders only: a link could point anywhere.
        guard let walk = fm.enumerator(at: new, includingPropertiesForKeys: nil) else { throw UpdateError.notAProgram }
        for case let item as URL in walk {
            let type = (try? fm.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { throw UpdateError.notAProgram }
        }
        let exe = new.appendingPathComponent("Contents/MacOS/macx")
        guard (try? fm.attributesOfItem(atPath: exe.path))?[.type] as? FileAttributeType == .typeRegular,
            let head = try? FileHandle(forReadingFrom: exe).read(upToCount: 4096), !MachO.architectures(of: head).isEmpty
        else { throw UpdateError.notAProgram }
        guard signer.verifies(new) else { throw UpdateError.appSignatureInvalid }
        guard signer.designatedRequirement(of: new) == requirementBefore else { throw UpdateError.identityChanged }
        guard let reported = versionOf(exe), SemVer(reported) == v else { throw UpdateError.versionMismatch }

        // Copy next to the app (same volume), then swap the two in one step: on any failure the old app stays.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".\(name).new-\(UUID().uuidString)")
        try fm.copyItem(at: new, to: staged)
        guard renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError.download("couldn't replace \(app.path)")
        }
        // `staged` now holds the old app: keep it as the previous version.
        try? fm.createDirectory(at: previousFolder, withIntermediateDirectories: true)
        let previous = previousFolder.appendingPathComponent("\(name).previous")
        try? fm.removeItem(at: previous)
        if (try? fm.moveItem(at: staged, to: previous)) == nil { try? fm.removeItem(at: staged) }
    }

    /// `…/Macximesed.app` when the binary is the app's main executable (`Contents/MacOS/...`).
    public static func enclosingApp(of exe: URL) -> URL? {
        let macos = exe.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return macos.lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents" && app.pathExtension == "app" ? app : nil
    }

    /// The new Info.plist: the new version, and the switch that opens the Mac app from Finder (`LSEnvironment
    /// MACX_APP=1`), which bundles installed before the app existed don't have.
    static func updatedInfo(_ info: [String: Any], version: String) -> [String: Any] {
        updatedInfo(info, version: SemVer(version).map { BuildVersion.release($0) } ?? .release(SemVer(macxVersion)!))
    }

    /// A dev build keeps its base as the short version (Finder expects numbers) and its commit as the build.
    static func updatedInfo(_ info: [String: Any], version: BuildVersion) -> [String: Any] {
        var info = info
        info["CFBundleShortVersionString"] = version.base.description
        info["CFBundleVersion"] = version.description
        var env = info["LSEnvironment"] as? [String: String] ?? [:]
        env["MACX_APP"] = "1"
        info["LSEnvironment"] = env
        return info
    }

    /// After swapping the executable, update the bundle's version and sign the bundle again (ad-hoc), so
    /// its signature covers the new binary and Info.plist.
    static func reseal(_ app: URL, version: BuildVersion, identity: SigningIdentity?, signer: AppSigner) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
            var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            info = updatedInfo(info, version: version)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
        }
        let id =
            (try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])?[
                "CFBundleIdentifier"] as? String ?? "dev.macximesed.macx"
        // Same identity install.sh used, so the app keeps its Full Disk Access after the update. Keep the entitlements
        // too, or an update would take the chamber's Virtualization permission away.
        let entitlements = FileManager.default.temporaryDirectory.appendingPathComponent("macx-\(UUID().uuidString).entitlements")
        try Data(SigningIdentity.entitlementsPlist.utf8).write(to: entitlements)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        try signer.sign(app, identity: identity, bundleID: id, entitlements: entitlements)
    }

}

// MARK: - Fetching

public enum UpdateClient {
    public static let channelURL = URL(string: "https://laouuuuu.github.io/Macximesed/channel/v1.json")!
    /// The beta file sits on the rolling `dev` prerelease, never on the Pages site the stable channel lives on.
    public static let betaURL = URL(string: "https://github.com/LAOUUUUU/Macximesed/releases/download/dev/beta-v1.json")!

    /// Fetches the channel file and its signature, and verifies it. Short timeout: this runs before commands.
    public static func fetchChannel(timeout: TimeInterval = 5, verifier: ChannelVerifier = ChannelVerifier()) throws -> UpdateChannel {
        try fetchSignedChannel(timeout: timeout, verifier: verifier).channel
    }

    /// The verified channel with the exact bytes and signature, so they can be saved and checked again later.
    public static func fetchSignedChannel(timeout: TimeInterval = 5, verifier: ChannelVerifier = ChannelVerifier()) throws
        -> SignedChannel
    {
        let json = try get(channelURL, timeout: timeout)
        let sig = try get(channelURL.appendingPathExtension("sig"), timeout: timeout)
        return SignedChannel(channel: try verifier.verify(json: json, signature: sig), json: json, signature: sig)
    }

    public static func fetchBeta(timeout: TimeInterval = 5, verifier: BetaVerifier = BetaVerifier()) throws -> BetaChannel {
        let json = try get(betaURL, timeout: timeout)
        let sig = try get(betaURL.appendingPathExtension("sig"), timeout: timeout)
        return try verifier.verify(json: json, signature: sig)
    }

    public static func get(_ url: URL, timeout: TimeInterval) throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 120)
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        var req = URLRequest(url: url)
        req.setValue("macx/\(BuildVersion.current)", forHTTPHeaderField: "User-Agent")
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

/// codesign, behind a seam so tests don't sign anything.
public protocol AppSigner: Sendable {
    /// `codesign -d -r-`: the requirement macOS ties Full Disk Access to.
    func designatedRequirement(of app: URL) -> String?
    func preferredIdentity() -> SigningIdentity?
    func sign(_ app: URL, identity: SigningIdentity?, bundleID: String, entitlements: URL) throws
    /// `codesign --verify --strict --deep`.
    func verifies(_ app: URL) -> Bool
    /// The leaf certificate's name (`codesign -dvv`, first `Authority=`), nil when ad-hoc.
    func authority(of app: URL) -> String?
}

extension AppSigner {
    public func verifies(_ app: URL) -> Bool { true }
    public func authority(of app: URL) -> String? { nil }
}

/// How to update: release-signed installs (.pkg, .dmg) get CI's whole signed app; installs signed on this Mac
/// (`install.sh`, with the user's own certificate) get the binary and are re-signed here.
public enum UpdateMethod: Sendable, Equatable {
    case binary, wholeApp

    public static let releaseAuthority = "Macximesed Release Signing"

    public static func choose(app: URL?, authority: String?, hasAppAsset: Bool) -> UpdateMethod {
        app != nil && hasAppAsset && authority == releaseAuthority ? .wholeApp : .binary
    }
}

public struct RealAppSigner: AppSigner {
    public init() {}

    public func designatedRequirement(of app: URL) -> String? {
        guard let out = ProcessRunner.capture("/usr/bin/codesign", ["-d", "-r-", app.path]) else { return nil }
        let text = out.stdout + out.stderr
        return text.split(separator: "\n").first { $0.hasPrefix("designated => ") }.map { String($0.dropFirst("designated => ".count)) }
    }

    public func preferredIdentity() -> SigningIdentity? { SigningIdentity.preferred() }

    public func verifies(_ app: URL) -> Bool {
        ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])?.status == 0
    }

    public func authority(of app: URL) -> String? {
        guard let out = ProcessRunner.capture("/usr/bin/codesign", ["-dvv", app.path]) else { return nil }
        return (out.stdout + out.stderr).split(separator: "\n").first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    public func sign(_ app: URL, identity: SigningIdentity?, bundleID: String, entitlements: URL) throws {
        let args = SigningIdentity.resealArguments(
            sign: SigningIdentity.codesignArgument(identity), id: bundleID, app: app, entitlements: entitlements)
        guard ProcessRunner.capture("/usr/bin/codesign", args)?.status == 0 else {
            throw UpdateError.download("updated, but couldn't re-sign \(app.path)")
        }
    }
}

/// The identity of a file on disk (inode, size, change time). The updater swaps the binary by renaming a new file
/// over it, so a long-running macx (the background watch) can tell it's been updated and restart.
public struct BinaryStamp: Sendable, Equatable {
    var inode: UInt64
    var size: Int64
    var mtime: Int

    public let path: String

    public init?(of url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        inode = st.st_ino
        size = st.st_size
        mtime = st.st_mtimespec.tv_sec
        path = url.path
    }

    public func changed() -> Bool {
        guard let now = BinaryStamp(of: URL(fileURLWithPath: path)) else { return true }
        return now.inode != inode || now.size != size || now.mtime != mtime
    }
}
