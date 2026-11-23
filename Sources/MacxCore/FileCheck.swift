import CryptoKit
import Foundation

// MARK: - Gatekeeper

public enum GatekeeperKind: String, Sendable {
    case execute, install, open
}

/// Gatekeeper's own decision (`spctl --assess`), which is what macOS uses when you open the file.
public struct GatekeeperResult: Sendable, Equatable {
    public var accepted: Bool
    public var source: String?
    public var origin: String?
    public var error: String?

    public init(accepted: Bool, source: String? = nil, origin: String? = nil, error: String? = nil) {
        self.accepted = accepted
        self.source = source
        self.origin = origin
        self.error = error
    }

    public var isNotarized: Bool { source?.contains("Notarized") ?? false }
    public var isApple: Bool { source.map { $0.hasPrefix("Apple") } ?? false }

    /// `spctl -vv` writes `path: accepted|rejected`, then `source=` and `origin=` lines; anything else is an error.
    public static func parse(_ output: String, status: Int32) -> GatekeeperResult {
        var r = GatekeeperResult(accepted: status == 0)
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("source=") {
                r.source = String(line.dropFirst(7))
            } else if line.hasPrefix("origin=") {
                r.origin = String(line.dropFirst(7))
            } else if let colon = line.range(of: ": ", options: .backwards) {
                let verdict = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                if verdict == "accepted" {
                    r.accepted = true
                } else if verdict == "rejected" {
                    r.accepted = false
                } else if r.error == nil {
                    r.error = verdict
                    r.accepted = false
                }
            }
        }
        return r
    }
}

public protocol GatekeeperAssessing: Sendable {
    func assess(_ path: String, kind: GatekeeperKind) -> GatekeeperResult
}

public struct SpctlAssessor: GatekeeperAssessing {
    public init() {}
    public func assess(_ path: String, kind: GatekeeperKind) -> GatekeeperResult {
        var args = ["--assess", "--type", kind.rawValue, "-vv"]
        if kind == .open { args += ["--context", "context:primary-signature"] }
        guard let out = ProcessRunner.capture("/usr/sbin/spctl", args + [path]) else {
            return GatekeeperResult(accepted: false, error: "spctl could not run")
        }
        return .parse(out.stderr + out.stdout, status: out.status)
    }
}

// MARK: - Quarantine

/// The `com.apple.quarantine` flag macOS puts on downloads: `flags;hex time;downloading app;UUID`.
/// Flags are shown as they are; their bits aren't documented, so they aren't interpreted.
public struct QuarantineInfo: Sendable, Equatable {
    public var flags: String
    public var date: Date?
    public var agent: String?
    public var raw: String

    public static func parse(_ value: String) -> QuarantineInfo? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].count == 4, UInt32(parts[0], radix: 16) != nil else { return nil }
        let date = UInt32(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuarantineInfo(flags: parts[0], date: date, agent: parts[2].isEmpty ? nil : parts[2], raw: value)
    }

    public static func read(_ path: String) -> QuarantineInfo? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, "com.apple.quarantine", &buf, size, 0, 0) == size else { return nil }
        return parse(String(decoding: buf, as: UTF8.self))
    }
}

// MARK: - Disk images

public protocol DiskImageMounting: Sendable {
    /// Mounts read-only and hidden from Finder; returns the mount point.
    func mount(_ image: URL) -> URL?
    func unmount(_ mountPoint: URL)
}

/// `diskutil image attach` on macOS 26 and later, `hdiutil attach` before that.
public struct SystemDiskImageMounter: DiskImageMounting {
    public init() {}

    public func mount(_ image: URL) -> URL? {
        let mp = FileManager.default.temporaryDirectory.appendingPathComponent("macx-dmg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: mp, withIntermediateDirectories: true)
        if let r = ProcessRunner.capture(
            "/usr/sbin/diskutil", ["image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mp.path, image.path]),
            r.status == 0, isMounted(mp)
        {
            return mp
        }
        if let r = ProcessRunner.capture(
            "/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mp.path, image.path]),
            r.status == 0, isMounted(mp)
        {
            return mp
        }
        try? FileManager.default.removeItem(at: mp)
        return nil
    }

    public func unmount(_ mountPoint: URL) {
        if ProcessRunner.capture("/usr/bin/hdiutil", ["detach", mountPoint.path])?.status != 0 {
            _ = ProcessRunner.capture("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
        }
        try? FileManager.default.removeItem(at: mountPoint)
    }

    func isMounted(_ mp: URL) -> Bool {
        var a = statfs()
        var b = statfs()
        guard statfs(mp.path, &a) == 0, statfs(mp.deletingLastPathComponent().path, &b) == 0 else { return false }
        return a.f_fsid.val.0 != b.f_fsid.val.0 || a.f_fsid.val.1 != b.f_fsid.val.1
    }
}

// MARK: - Hash lookup

public protocol HashLookup: Sendable {
    /// The malware family or signature name, or nil if the hash isn't known.
    func lookup(sha256: String) throws -> String?
}

/// abuse.ch MalwareBazaar. Only the SHA-256 is sent, never the file. Needs a free Auth-Key.
public struct MalwareBazaarLookup: HashLookup {
    public var authKey: String
    public init(authKey: String) { self.authKey = authKey }

    public func lookup(sha256: String) throws -> String? {
        var req = URLRequest(url: URL(string: "https://mb-api.abuse.ch/api/v1/")!)
        req.httpMethod = "POST"
        req.setValue(authKey, forHTTPHeaderField: "Auth-Key")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("query=get_info&hash=\(sha256)".utf8)
        req.timeoutInterval = 15

        nonisolated(unsafe) var result: Result<Data, Error> = .failure(URLError(.unknown))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, error in
            result = data.map { .success($0) } ?? .failure(error ?? URLError(.badServerResponse))
            done.signal()
        }.resume()
        done.wait()
        let json = try JSONSerialization.jsonObject(with: result.get()) as? [String: Any]
        guard json?["query_status"] as? String == "ok", let first = (json?["data"] as? [[String: Any]])?.first else { return nil }
        return (first["signature"] as? String) ?? (first["file_name"] as? String) ?? "known malware sample"
    }
}

// MARK: - Report

public enum FileKind: String, Sendable {
    case app, package, diskImage, machO, script, appleScript, text, folder, other

    public var label: String {
        switch self {
        case .app: "app"
        case .package: "installer package"
        case .diskImage: "disk image"
        case .machO: "program (Mach-O)"
        case .script: "script"
        case .appleScript: "compiled AppleScript"
        case .text: "text file"
        case .folder: "folder"
        case .other: "file"
        }
    }

    static let scriptExtensions: Set<String> = ["command", "sh", "zsh", "bash", "tool", "py", "rb", "pl", "applescript"]

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if ext == "app" { return .app }
        if ext == "pkg" || ext == "mpkg" { return .package }
        if ["dmg", "sparseimage", "sparsebundle"].contains(ext) { return .diskImage }
        if exists, isDir.boolValue { return .folder }
        if ext == "scpt" || ext == "scptd" { return .appleScript }
        if scriptExtensions.contains(ext) { return .script }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if !MachO.architectures(of: head).isEmpty { return .machO }
        if head.starts(with: Data("#!".utf8)) { return .script }
        if !head.isEmpty, String(data: head, encoding: .utf8) != nil, !head.contains(0) { return .text }
        return .other
    }
}

public enum Verdict: String, Sendable, Comparable {
    case ok, caution, dangerous

    static func from(_ findings: [CheckFinding]) -> Verdict {
        switch findings.map(\.severity).max() {
        case .critical?, .high?: .dangerous
        case .medium?: .caution
        default: .ok
        }
    }

    public static func < (a: Verdict, b: Verdict) -> Bool {
        let order: [Verdict] = [.ok, .caution, .dangerous]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

public struct CheckFinding: Sendable, Equatable {
    public var rule: String
    public var id: String { rule }
    public var severity: Severity
    public var title: String
    public var detail: String?
}

/// Something the file will set up to run by itself once installed or opened.
public struct InstallItem: Sendable, Equatable {
    public var label: String
    public var path: String?
}

public struct FileReport: Sendable {
    public var path: URL
    public var kind: FileKind
    public var signature: SignatureInfo?
    public var gatekeeper: GatekeeperResult?
    public var quarantine: QuarantineInfo?
    public var sha256: String?
    public var findings: [CheckFinding] = []
    public var installs: [InstallItem] = []
    /// Contents of a disk image or folder, each checked on its own.
    public var inner: [FileReport] = []

    public var verdict: Verdict { Verdict.from(findings) }
}

public enum FileCheckError: Error, Equatable {
    case notFound(String)
}

// MARK: - Checker

public struct FileChecker: Sendable {
    var gatekeeper: GatekeeperAssessing
    var signatures: SignatureChecking
    var mounter: DiskImageMounting
    var lookup: HashLookup?

    public init(
        gatekeeper: GatekeeperAssessing = SpctlAssessor(), signatures: SignatureChecking = CodeSignatureChecker(),
        mounter: DiskImageMounting = SystemDiskImageMounter(), lookup: HashLookup? = nil
    ) {
        self.gatekeeper = gatekeeper
        self.signatures = signatures
        self.mounter = mounter
        self.lookup = lookup
    }

    public func check(_ url: URL) throws -> FileReport {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileCheckError.notFound(url.path) }
        return check(url, depth: 0)
    }

    func check(_ url: URL, depth: Int) -> FileReport {
        let kind = FileKind.of(url)
        var r = FileReport(path: url, kind: kind, quarantine: QuarantineInfo.read(url.path))
        func add(_ rule: String, _ severity: Severity, _ title: String, _ detail: String? = nil) {
            r.findings.append(CheckFinding(rule: rule, severity: severity, title: title, detail: detail))
        }

        switch kind {
        case .app:
            r.signature = signatures.check(url.path)
            r.gatekeeper = gatekeeper.assess(url.path, kind: .execute)
            r.sha256 = mainExecutable(of: url).flatMap(Self.hashFile)
            r.installs = appInstalls(url)
        case .machO:
            r.signature = signatures.check(url.path)
            r.sha256 = Self.hashFile(url)
        case .package:
            r.gatekeeper = gatekeeper.assess(url.path, kind: .install)
            r.sha256 = Self.hashFile(url)
            let (installs, scriptFindings) = packageContents(url)
            r.installs = installs
            r.findings += scriptFindings
        case .diskImage:
            r.gatekeeper = gatekeeper.assess(url.path, kind: .open)
            r.sha256 = Self.hashFile(url)
            if depth < 2, let mp = mounter.mount(url) {
                r.inner = folderContents(mp).map { check($0, depth: depth + 1) }
                mounter.unmount(mp)
            } else if depth < 2 {
                add("not-mounted", .info, "Couldn't open the disk image to look inside")
            }
        case .folder:
            if depth < 2 { r.inner = folderContents(url).map { check($0, depth: depth + 1) } }
        case .script, .text:
            r.sha256 = Self.hashFile(url)
            if let text = try? String(contentsOf: url, encoding: .utf8) { r.findings += scan(text: text) }
            if kind == .script, ["command", "tool"].contains(url.pathExtension.lowercased()) {
                add("opens-terminal", .low, "Runs in Terminal as soon as it's double-clicked")
            }
        case .appleScript:
            r.sha256 = Self.hashFile(url)
            if let out = ProcessRunner.capture("/usr/bin/osadecompile", [url.path]), out.status == 0 {
                r.findings += scan(text: out.stdout)
            }
        case .other:
            r.sha256 = Self.hashFile(url)
        }

        // Signatures and Gatekeeper.
        let downloaded = r.quarantine != nil
        switch r.signature {
        case .adHoc?:
            add(
                downloaded ? "adhoc-downloaded" : "adhoc", downloaded ? .high : .medium,
                "Ad-hoc signed (no developer identity)\(downloaded ? ", and it was downloaded" : "")")
        case .unsigned?:
            add(
                downloaded ? "unsigned-downloaded" : "unsigned", downloaded ? .high : .medium,
                "Not signed\(downloaded ? ", and it was downloaded" : "")")
        default: break
        }
        if let g = r.gatekeeper, kind == .app || kind == .package || kind == .diskImage {
            if !g.accepted {
                let why = g.error ?? g.source ?? "rejected"
                if kind == .package, why.contains("no usable signature") {
                    add("unsigned-package", .high, "Installer package isn't signed. Installers run as root.", why)
                } else if kind == .diskImage, why.contains("no usable signature") {
                    add("unsigned-disk-image", .low, "Disk image isn't signed (common; the apps inside are what count)")
                } else {
                    add("gatekeeper-rejected", .high, "macOS's Gatekeeper would block this", why)
                }
            } else if !g.isNotarized, !g.isApple, kind == .app {
                add("not-notarized", .medium, "Signed but not notarized by Apple", g.source)
            }
        }
        if !r.installs.isEmpty {
            add(
                "installs-background-items", .low, "Sets things up to run by itself",
                r.installs.map(\.label).joined(separator: "; "))
        }

        // Things inside a disk image or folder count for the whole file.
        for child in r.inner {
            for f in child.findings where f.severity >= .medium {
                var g = f
                g.detail = "in \(child.path.lastPathComponent): \(f.detail ?? f.title)"
                r.findings.append(g)
            }
        }

        if let lookup, let hash = r.sha256, let name = try? lookup.lookup(sha256: hash) {
            add("known-malware", .critical, "This exact file is a known malware sample", name)
        }
        r.findings.sort { $0.severity > $1.severity }
        return r
    }

    // MARK: Helpers

    /// Pattern matches in a script or text file: one finding per pattern, with the line and any decoded payload.
    func scan(text: String) -> [CheckFinding] {
        var out: [CheckFinding] = []
        var seen: Set<CommandPattern> = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for p in CommandPatterns.match(line).sorted(by: { $0.rawValue < $1.rawValue }) where !seen.contains(p) {
                seen.insert(p)
                var detail = "line \(i + 1): \(String(line.prefix(200)))"
                let decoded = CommandPatterns.decodedPayloads(in: line)
                if !decoded.isEmpty { detail += "\n  decodes to: " + decoded.joined(separator: "\n  decodes to: ") }
                let severity: Severity = p == .quarantineStrip ? .high : .critical
                out.append(CheckFinding(rule: p.rawValue, severity: severity, title: p.title, detail: detail))
            }
        }
        return out
    }

    func mainExecutable(of app: URL) -> URL? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let exe = plist["CFBundleExecutable"] as? String
        else { return nil }
        return app.appendingPathComponent("Contents/MacOS/\(exe)")
    }

    func appInstalls(_ app: URL) -> [InstallItem] {
        var out: [InstallItem] = []
        let lib = app.appendingPathComponent("Contents/Library")
        for (dir, what) in [("LaunchDaemons", "launch daemon (root)"), ("LaunchAgents", "launch agent")] {
            for f in CleanupCatalog.children(of: lib.appendingPathComponent(dir)) where f.pathExtension == "plist" {
                out.append(InstallItem(label: "\(what) \(f.deletingPathExtension().lastPathComponent)", path: f.path))
            }
        }
        for f in CleanupCatalog.children(of: lib.appendingPathComponent("LoginItems")) {
            out.append(InstallItem(label: "login item \(f.deletingPathExtension().lastPathComponent)", path: f.path))
        }
        for f in CleanupCatalog.children(of: lib.appendingPathComponent("SystemExtensions")) {
            out.append(InstallItem(label: "system extension \(f.lastPathComponent)", path: f.path))
        }
        for f in CleanupCatalog.children(of: lib.appendingPathComponent("LaunchServices")) {
            out.append(InstallItem(label: "privileged helper \(f.lastPathComponent)", path: f.path))
        }
        if let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let helpers = plist["SMPrivilegedExecutables"] as? [String: Any]
        {
            for id in helpers.keys.sorted() { out.append(InstallItem(label: "privileged helper \(id) (runs as root)", path: nil)) }
        }
        return out
    }

    /// Expands the package into a temp folder, reads its install scripts and looks for launch items in its payload.
    func packageContents(_ pkg: URL) -> ([InstallItem], [CheckFinding]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macx-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard ProcessRunner.capture("/usr/sbin/pkgutil", ["--expand-full", pkg.path, dir.path])?.status == 0 else {
            return ([], [CheckFinding(rule: "not-expanded", severity: .info, title: "Couldn't open the package to look inside")])
        }
        var installs: [InstallItem] = []
        var findings: [CheckFinding] = []
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return ([], [])
        }
        for case let f as URL in walker {
            let rel = String(f.path.dropFirst(dir.path.count))
            if rel.contains("/Scripts/"), (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                installs.append(InstallItem(label: "install script \(f.lastPathComponent) (runs as root)", path: rel))
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    findings += scan(text: text).map {
                        var x = $0
                        x.detail = "\(f.lastPathComponent) \(x.detail ?? "")"
                        return x
                    }
                }
            }
            if rel.contains("/Payload/"), f.pathExtension == "plist",
                rel.contains("/Library/LaunchDaemons/") || rel.contains("/Library/LaunchAgents/")
            {
                installs.append(InstallItem(label: "launch item \(f.deletingPathExtension().lastPathComponent)", path: rel))
            }
        }
        return (installs, findings)
    }

    func folderContents(_ dir: URL) -> [URL] {
        CleanupCatalog.children(of: dir).filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    static func hashFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256Stream()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
        return hasher.finish()
    }
}

// MARK: - Base64 payloads

extension CommandPatterns {
    /// Decodes `echo '<base64>' | base64 -D` style payloads so the hidden command can be shown.
    public static func decodedPayloads(in text: String) -> [String] {
        guard !match(text).isDisjoint(with: [.base64ToShell]) || text.contains("base64") else { return [] }
        let regex = try? NSRegularExpression(pattern: #"['"]?([A-Za-z0-9+/]{16,}={0,2})['"]?"#)
        let range = NSRange(text.startIndex..., in: text)
        return (regex?.matches(in: text, range: range) ?? []).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text), let data = Data(base64Encoded: String(text[r])),
                let s = String(data: data, encoding: .utf8), s.allSatisfy({ !$0.isASCII || $0.isPrintable })
            else { return nil }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension Character {
    var isPrintable: Bool { isLetter || isNumber || isPunctuation || isSymbol || self == " " || self == "\t" || self == "\n" }
}

/// SHA-256 over a stream of chunks, so big files are never read into memory at once.
struct SHA256Stream {
    var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finish() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
