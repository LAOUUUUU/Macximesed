import CryptoKit
import Foundation
import Security

// MARK: - Code signatures

public enum SignatureInfo: Codable, Sendable, Equatable {
    /// Signed by Apple (passes `anchor apple`).
    case apple
    /// Signed with a real certificate; the team ID identifies the developer.
    case developerID(team: String)
    /// Signed with no identity (`codesign -s -`). Anyone can make these: AMOS payloads were ad-hoc.
    case adHoc
    case unsigned
    case missing
    /// The file exists but this user can't read it (root-only helpers), so its signature is unknown.
    case unreadable

    public var label: String {
        switch self {
        case .apple: "Apple"
        case .developerID(let team): "signed, team \(team)"
        case .adHoc: "ad-hoc (no identity)"
        case .unsigned: "unsigned"
        case .missing: "file missing"
        case .unreadable: "can't read (root only, or in a privacy-guarded folder)"
        }
    }
}

public protocol SignatureChecking: Sendable {
    func check(_ path: String) -> SignatureInfo
}

/// Reads signatures with the Security framework, so nothing depends on parsing `codesign` output.
public struct CodeSignatureChecker: SignatureChecking {
    public init() {}

    public func check(_ path: String) -> SignatureInfo {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard FileManager.default.isReadableFile(atPath: path) else { return .unreadable }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return .unsigned
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return .unsigned }
        // No signature at all: the dictionary has no identifier.
        guard dict[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }

        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        {
            return .apple
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & 0x2 != 0 { return .adHoc }  // kSecCodeSignatureAdhoc
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return .developerID(team: team) }
        return .adHoc
    }
}

// MARK: - Items

public enum PersistenceKind: String, Codable, Sendable, CaseIterable {
    case launchDaemon, launchAgent, userLaunchAgent, loginItem, backgroundTask, cron, shellStartup, hiddenFolder
    case appExtension, authorizationPlugin, periodicScript, sudoersFile, pamModule, atJob, loginHook
    case systemExtension, kernelExtension, browserExtension, configurationProfile

    public var label: String {
        switch self {
        case .launchDaemon: "Launch daemon (root)"
        case .launchAgent: "Launch agent (all users)"
        case .userLaunchAgent: "Launch agent (you)"
        case .loginItem: "Login item"
        case .backgroundTask: "Background task"
        case .cron: "Cron job"
        case .shellStartup: "Shell startup line"
        case .hiddenFolder: "Hidden support folder"
        case .appExtension: "App extension"
        case .authorizationPlugin: "Authorization plugin (runs at login)"
        case .periodicScript: "Periodic script (runs as root on a schedule)"
        case .sudoersFile: "sudoers rule file"
        case .pamModule: "Login (PAM) module"
        case .atJob: "at job"
        case .loginHook: "Login or logout hook"
        case .systemExtension: "System extension"
        case .kernelExtension: "Kernel extension"
        case .browserExtension: "Browser extension"
        case .configurationProfile: "Configuration profile"
        }
    }
}

/// Something that makes code run without you starting it.
public struct PersistenceItem: Codable, Sendable, Equatable {
    public var kind: PersistenceKind
    public var path: String
    public var label: String?
    public var program: String?
    public var arguments: [String]
    public var runsAsRoot: Bool
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var signature: SignatureInfo?
    public var teamID: String?
    /// SHA-256 of the file (or line) that defines it, so a baseline can tell when it changes.
    public var contentHash: String
    public var unreadable: Bool = false
    /// For shell lines: the text that matched.
    public var detail: String?
    /// Libraries forced into the program with DYLD_* environment variables (launch plists).
    public var injectedLibraries: [String]?
    /// Configuration profiles: what their payloads can do, and whether an MDM manages this Mac.
    public var profileCapabilities: [ProfileCapability]?
    public var managedByMDM: Bool?

    public init(
        kind: PersistenceKind, path: String, label: String?, program: String?, arguments: [String], runsAsRoot: Bool,
        runAtLoad: Bool, keepAlive: Bool, signature: SignatureInfo?, teamID: String?, contentHash: String,
        unreadable: Bool = false, detail: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.label = label
        self.program = program
        self.arguments = arguments
        self.runsAsRoot = runsAsRoot
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.signature = signature
        self.teamID = teamID
        self.contentHash = contentHash
        self.unreadable = unreadable
        self.detail = detail
    }

    /// Identity for baselines: the same file (or the same line of a file) is the same item.
    public var key: String { "\(kind.rawValue)|\(path)|\(label ?? "")" }

    public static func hiddenFolder(_ path: String) -> PersistenceItem {
        PersistenceItem(
            kind: .hiddenFolder, path: path, label: (path as NSString).lastPathComponent, program: nil, arguments: [],
            runsAsRoot: false, runAtLoad: false, keepAlive: false, signature: nil, teamID: nil, contentHash: sha256(path))
    }

    public static func shellLine(_ path: String, line: Int, text: String) -> PersistenceItem {
        PersistenceItem(
            kind: .shellStartup, path: path, label: "line \(line)", program: nil, arguments: [], runsAsRoot: false,
            runAtLoad: true, keepAlive: false, signature: nil, teamID: nil, contentHash: sha256(text), detail: text)
    }
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

// MARK: - launchd

public enum LaunchdParser {
    public static func parse(_ file: URL, kind: PersistenceKind, signatures: SignatureChecking) -> PersistenceItem? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return PersistenceItem(
                kind: kind, path: file.path, label: nil, program: nil, arguments: [], runsAsRoot: kind == .launchDaemon,
                runAtLoad: false, keepAlive: false, signature: nil, teamID: nil, contentHash: sha256(data),
                unreadable: true)
        }
        let args = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let program = (dict["Program"] as? String) ?? args.first
        let user = dict["UserName"] as? String
        let keepAlive: Bool =
            switch dict["KeepAlive"] {
            case let b as Bool: b
            case is [String: Any]: true
            default: false
            }
        return PersistenceItem(
            kind: kind, path: file.path, label: dict["Label"] as? String, program: program, arguments: args,
            runsAsRoot: kind == .launchDaemon && (user == nil || user == "root"),
            runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false, keepAlive: keepAlive,
            signature: program.map { signatures.check($0) }, teamID: nil, contentHash: sha256(data)
        )
        .with { item in
            let env = dict["EnvironmentVariables"] as? [String: Any] ?? [:]
            let injected = env.filter { $0.key.hasPrefix("DYLD_") }.compactMap { $0.value as? String }
                .flatMap { $0.split(separator: ":").map(String.init) }
            item.injectedLibraries = injected.isEmpty ? nil : injected.sorted()
        }
    }
}

extension PersistenceItem {
    func with(_ change: (inout PersistenceItem) -> Void) -> PersistenceItem {
        var copy = self
        change(&copy)
        return copy
    }
}

// MARK: - Background Task Management

public struct BTMRecord: Sendable, Equatable {
    public var fields: [String: String]

    public var name: String? { value("Name") }
    /// "login item", "legacy daemon", ... without the hex code.
    public var type: String? {
        value("Type").map { $0.replacingOccurrences(of: #"\s*\(0x[0-9a-fA-F]+\)$"#, with: "", options: .regularExpression) }
    }
    public var teamID: String? { value("Team Identifier") }
    public var bundleID: String? { value("Bundle Identifier") }
    public var url: String? { value("URL") }
    public var executablePath: String? { value("Executable Path") }
    public var disposition: String { fields["Disposition"] ?? "" }
    public var enabled: Bool { disposition.contains("enabled") }
    public var allowed: Bool { disposition.contains(" allowed") || disposition.contains("[allowed") }

    func value(_ key: String) -> String? {
        guard let v = fields[key], v != "(null)", !v.isEmpty else { return nil }
        return v
    }
}

/// Parses `sfltool dumpbtm`. The format is undocumented, so unknown keys and types are kept and
/// anything unexpected is skipped instead of failing.
public enum BTMParser {
    public static func parse(_ text: String) -> [BTMRecord] {
        var records: [BTMRecord] = []
        var current: [String: String]?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^#\d+:$"#, options: .regularExpression) != nil {
                if let c = current, !c.isEmpty { records.append(BTMRecord(fields: c)) }
                current = [:]
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Embedded identifier lists ("#1: 16.com...") belong to the record above; skip them.
            if key.hasPrefix("#") || key.isEmpty { continue }
            if current?[key] == nil { current?[key] = value }
        }
        if let c = current, !c.isEmpty { records.append(BTMRecord(fields: c)) }
        return records
    }

    /// Login items and background tasks. Launch daemons and agents come from their plists instead.
    public static func items(from records: [BTMRecord]) -> [PersistenceItem] {
        records.compactMap { r in
            let kind: PersistenceKind
            switch r.type {
            case "login item": kind = .loginItem
            case "background tasks", "background app refresh": kind = .backgroundTask
            default: return nil
            }
            let id = [r.name, r.bundleID, r.url, r.executablePath, r.disposition].compactMap { $0 }.joined(separator: "|")
            return PersistenceItem(
                kind: kind, path: r.url ?? r.bundleID ?? r.name ?? "?", label: r.name, program: r.executablePath,
                arguments: [], runsAsRoot: false, runAtLoad: r.enabled, keepAlive: false, signature: nil,
                teamID: r.teamID, contentHash: sha256(id))
        }
    }

    public static func current(runner: CommandRunner = ProcessRunner(timeout: 8)) -> [BTMRecord] {
        currentWithNote(runner: runner).0
    }

    /// `sfltool dumpbtm` asks for the `system.privilege.admin` right before it dumps anything. Without root
    /// that puts up an admin-password dialog and waits on it: a few seconds with Touch ID, forever on a Mac
    /// with nobody at the screen (CI), and the dialogs queue when several run at once. As root it answers
    /// straight away with no dialog. So it only runs as root; the 8 s limit stays as a guard.
    public static func currentWithNote(
        runner: CommandRunner = ProcessRunner(timeout: 8), isRoot: Bool = geteuid() == 0
    ) -> ([BTMRecord], String?) {
        guard isRoot else {
            return ([], "login items and background tasks need sudo (sfltool asks for an admin password otherwise): sudo macx persist")
        }
        do {
            return (parse(try runner.run("/usr/bin/sfltool", ["dumpbtm"])), nil)
        } catch CommandError.timedOut {
            return ([], "sfltool didn't answer within 8 s, so login items and background tasks weren't checked this time.")
        } catch {
            return ([], "sfltool couldn't list login items and background tasks (\(error)).")
        }
    }
}

// MARK: - Command patterns

/// Behaviour patterns from how AMOS and similar stealers get in. Shared by the persistence scan
/// (shell startup files, cron) and, later, the paste-to-shell guard.
public enum CommandPattern: String, Codable, Sendable, CaseIterable {
    case downloadToShell = "download-to-shell"
    case base64ToShell = "base64-to-shell"
    case quarantineStrip = "quarantine-strip"
    case passwordPrompt = "password-prompt"
    case passwordCheck = "password-check"

    public var title: String {
        switch self {
        case .downloadToShell: "Downloads code and runs it straight away"
        case .base64ToShell: "Decodes hidden (base64) code and runs it"
        case .quarantineStrip: "Removes macOS's download-safety (quarantine) flag"
        case .passwordPrompt: "Shows a script-made password box"
        case .passwordCheck: "Checks a password with dscl (how stealers verify a stolen password)"
        }
    }
}

public enum CommandPatterns {
    static let shells = #"(?:ba|z|k|da|fi)?sh|python3?|perl|ruby|osascript"#
    static let rules: [(CommandPattern, String)] = [
        (.downloadToShell, #"\b(?:curl|wget)\b[^|;&\n]*\|\s*(?:sudo\s+)?(?:/\S*/)?(?:\#(shells))\b"#),
        (.downloadToShell, #"(?:\#(shells))\s+<\(\s*(?:curl|wget)\b"#),
        (.downloadToShell, #"\beval\s+["']?\$\(\s*(?:curl|wget)\b"#),
        (.base64ToShell, #"\bbase64\s+(?:-[dD]\b|--decode\b)[^|;\n]*\|\s*(?:sudo\s+)?(?:/\S*/)?(?:\#(shells))\b"#),
        (.quarantineStrip, #"\bxattr\b[^;|\n]*(?:-[a-z]*d[a-z]*\s+com\.apple\.quarantine|-[a-z]*c[a-z]*r|-[a-z]*r[a-z]*c)\b"#),
        (.passwordPrompt, #"\bosascript\b.*\bdisplay dialog\b.*\bhidden answer\b"#),
        (.passwordCheck, #"\bdscl\s+\.\s+-authonly\b"#),
    ]

    static let compiled: [(CommandPattern, NSRegularExpression)] = rules.compactMap { pattern, regex in
        (try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])).map { (pattern, $0) }
    }

    public static func match(_ text: String) -> Set<CommandPattern> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(compiled.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0))
    }
}

// MARK: - Scanning

public struct PersistenceRoots: Sendable {
    /// Where `/Library` lives (the real root is `/`; tests use a temp folder).
    public var system: URL
    public var home: URL

    public init(system: URL, home: URL) {
        self.system = system
        self.home = home
    }

    public static var current: PersistenceRoots {
        PersistenceRoots(system: URL(fileURLWithPath: "/"), home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

public enum PersistenceScanner {
    /// Shell files read at login or when a terminal opens.
    static let shellFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]

    public static func scan(
        _ roots: PersistenceRoots, signatures: SignatureChecking = GuardedSignatureChecker(),
        btm: [BTMRecord], cron: String?
    ) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        let folders: [(URL, PersistenceKind)] = [
            (roots.system.appendingPathComponent("Library/LaunchDaemons"), .launchDaemon),
            (roots.system.appendingPathComponent("Library/LaunchAgents"), .launchAgent),
            (roots.home.appendingPathComponent("Library/LaunchAgents"), .userLaunchAgent),
        ]
        for (dir, kind) in folders {
            for f in CleanupCatalog.children(of: dir) where f.pathExtension == "plist" {
                if let item = LaunchdParser.parse(f, kind: kind, signatures: signatures) { items.append(item) }
            }
        }
        items += BTMParser.items(from: btm)
        if let cron { items += cronItems(cron) }

        for name in shellFiles {
            let f = roots.home.appendingPathComponent(name)
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("#") || CommandPatterns.match(l).isEmpty { continue }
                items.append(.shellLine(f.path, line: i + 1, text: l))
            }
        }

        let support = roots.home.appendingPathComponent("Library/Application Support")
        for child in CleanupCatalog.children(of: support) where child.lastPathComponent.hasPrefix(".") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                items.append(.hiddenFolder(child.path))
            }
        }
        return items
    }

    /// One item per crontab line. The command is everything after the five time fields (or `@reboot` etc.).
    public static func cronItems(_ crontab: String) -> [PersistenceItem] {
        crontab.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.first?.contains("=") == true { return nil }  // VAR=value
            let command = Array(parts.dropFirst(parts.first?.hasPrefix("@") == true ? 1 : 5))
            guard !command.isEmpty else { return nil }
            return PersistenceItem(
                kind: .cron, path: "crontab", label: line, program: command.first, arguments: command,
                runsAsRoot: false, runAtLoad: true, keepAlive: false, signature: nil, teamID: nil,
                contentHash: sha256(line), detail: line)
        }
    }

    /// Everything, from the real Mac. Login items and background tasks need root; the rest doesn't.
    public static func current(runner: CommandRunner = ProcessRunner()) -> [PersistenceItem] {
        let cron = try? runner.run("/usr/bin/crontab", ["-l"])
        let (btm, note) = BTMParser.currentWithNote()
        if let note { FileHandle.standardError.write(Data("macx: \(note)\n".utf8)) }
        let profiles = ConfigurationProfiles.current()
        if let note = profiles.note { FileHandle.standardError.write(Data("macx: \(note)\n".utf8)) }
        return scan(.current, btm: btm, cron: cron) + OtherPersistence.scan(.current)
            + ConfigurationProfiles.items(profiles.profiles, managedByMDM: profiles.managedByMDM)
    }
}

// MARK: - Rules

public enum Severity: Int, Codable, Sendable, Comparable, CaseIterable {
    case info, low, medium, high, critical
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String { String(describing: self).uppercased() }
}

public struct Finding: Sendable, Equatable {
    public var rule: String
    public var severity: Severity
    public var title: String
    public var item: PersistenceItem
}

public enum PersistenceRules {
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish", "python", "python3", "perl", "ruby", "osascript", "node",
    ]

    /// `ownProgram`: the running macx. Macximesed's own background watch is listed as such only when its
    /// plist runs exactly that program; anything else under the same label is judged like any other item.
    public static func evaluate(_ items: [PersistenceItem], home: URL, ownProgram: String? = nil) -> [Finding] {
        var out: [Finding] = []
        let homePath = home.standardizedFileURL.path
        for item in items {
            func add(_ rule: String, _ severity: Severity, _ title: String) {
                out.append(Finding(rule: rule, severity: severity, title: title, item: item))
            }
            if item.kind == .launchDaemon, item.label == DaemonPlan.label, let own = ownProgram, item.program == own {
                add("macximesed-background-watch", .info, "Macximesed's own background watch (macx daemon)")
                continue
            }
            switch item.kind {
            case .hiddenFolder:
                let name = (item.path as NSString).lastPathComponent
                if name.hasPrefix(".com.apple.") {
                    add("fake-apple-folder", .critical, "Hidden folder named like Apple's, in your Application Support (AMOS hides here)")
                } else {
                    add("hidden-support-folder", .medium, "Hidden folder in your Application Support")
                }
                continue
            case .shellStartup, .cron, .periodicScript:
                if item.kind == .periodicScript {
                    add("periodic-script", .medium, "A script that runs as root every day, week or month (rarely added by apps)")
                }
                for p in CommandPatterns.match(item.detail ?? item.label ?? "").sorted(by: { $0.rawValue < $1.rawValue }) {
                    add(p.rawValue, .high, "\(item.kind.label): \(p.title)")
                }
                if item.kind != .cron { continue }
            case .authorizationPlugin:
                add("authorization-plugin", .high, "A plugin that runs at login and can see your password")
                continue
            case .sudoersFile:
                add("sudoers-file", .medium, "Changes who can use sudo, or how (contents need root to read)")
                continue
            case .pamModule:
                add("non-apple-pam-module", .high, "A login module that isn't one of macOS's own (it sees passwords)")
                continue
            case .atJob:
                add("at-job", .low, "A one-off scheduled job")
                continue
            case .loginHook:
                add("login-hook", .high, "A login or logout hook (old mechanism, runs as root; rarely used except by malware)")
            case .configurationProfile:
                if item.managedByMDM == true {
                    add("profile-managed", .info, "Configuration profile on a Mac your organisation manages (MDM)")
                    continue
                }
                add("profile-installed-by-hand", .low, "Configuration profile installed by hand (no MDM here): make sure you know it")
                for c in item.profileCapabilities ?? [] { add(c.rule, c.severity, c.title) }
                continue
            case .systemExtension, .kernelExtension, .browserExtension:
                continue  // listed so the baseline can show new ones; not judged on their own
            default: break
            }

            let program = item.program ?? ""
            let tool = (program as NSString).lastPathComponent
            let isInterpreter = interpreters.contains(tool)
            let allText = ([program] + item.arguments).joined(separator: " ")
            let autostarts = item.runAtLoad || item.keepAlive

            // Apple's own daemons live on the sealed system volume. A com.apple.* item anywhere else
            // that runs a script or a non-Apple program is the AMOS disguise.
            let fileName = (item.path as NSString).lastPathComponent
            let appleLabel = (item.label ?? "").hasPrefix("com.apple.") || fileName.hasPrefix("com.apple.")
            if appleLabel, [.launchDaemon, .launchAgent, .userLaunchAgent].contains(item.kind) {
                if isInterpreter || (item.signature != nil && item.signature != .apple) {
                    add("fake-apple-label", .critical, "Named like an Apple service but runs a script or a non-Apple program")
                } else {
                    add("apple-label-outside-system", .low, "Apple-named item outside the system volume")
                }
            }

            if isInterpreter, item.arguments.contains(where: { $0 == "-c" || $0 == "-e" }) {
                let loops = allText.range(of: #"\bwhile\b|\bsleep\b"#, options: .regularExpression) != nil
                add(
                    loops ? "shell-loop" : "inline-script", loops ? .high : .medium,
                    loops ? "Runs a shell loop that keeps restarting a program" : "Runs inline script code")
            }

            if let hidden = hiddenComponent(in: allText) {
                let inLibrary = hidden.range(of: "/Library/") != nil
                add(
                    "hidden-folder", inLibrary ? .high : .medium,
                    inLibrary ? "Runs something from a hidden folder inside a Library folder" : "Runs something from a hidden folder")
            }

            let temp = ["/tmp/", "/private/tmp/", "/private/var/tmp/", "/var/tmp/", "/Users/Shared/", homePath + "/Downloads/"]
            if temp.contains(where: { program.hasPrefix($0) }) {
                add("temp-location", .high, "Runs a program from a temporary or shared folder")
            }

            switch item.signature {
            case .missing?:
                add(
                    "missing-program", item.runsAsRoot && autostarts ? .high : .medium,
                    "Starts a program that no longer exists (left behind, or its payload was removed)")
            case .unsigned? where !isInterpreter:
                add("unsigned-program", item.runsAsRoot ? .high : .medium, "Runs an unsigned program")
            case .adHoc?:
                add("adhoc-program", item.runsAsRoot ? .high : .medium, "Runs an ad-hoc signed program (no developer identity)")
            case .unreadable?:
                add(
                    "unreadable-program", .info,
                    "Program can't be read (root only, or in a privacy-guarded folder), so its signature wasn't checked")
            default: break
            }

            if item.unreadable { add("unreadable-plist", .medium, "Launch file can't be read as a property list") }
            if let libs = item.injectedLibraries, !libs.isEmpty {
                add("dyld-injection", .high, "Forces a library into the program (DYLD_* variables): \(libs.joined(separator: ", "))")
            }
        }
        return out.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.item.path < $1.item.path }
    }

    /// The path leading up to the first hidden component (`/.name`), ignoring `.` and `..`. Paths
    /// may contain spaces ("Application Support"), so the path start is the nearest quote or " /".
    static func hiddenComponent(in text: String) -> String? {
        guard let r = text.range(of: #"/\.[A-Za-z0-9_]"#, options: .regularExpression) else { return nil }
        let before = text[..<r.lowerBound]
        let starts = [before.lastIndex(of: "\""), before.lastIndex(of: "'"), before.range(of: " /", options: .backwards)?.upperBound]
            .compactMap { $0 }
        let start = starts.max().map { before[$0] == "/" ? $0 : before.index(after: $0) } ?? before.startIndex
        let end = text[r.upperBound...].firstIndex { $0 == "/" || $0 == "\"" || $0 == "'" } ?? text.endIndex
        return String(text[start..<end])
    }
}

// MARK: - Baseline

public struct PersistenceDiff: Sendable, Equatable {
    public var added: [PersistenceItem]
    public var removed: [PersistenceItem]
    public var changed: [PersistenceItem]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

public enum PersistenceBaseline {
    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Macximesed/persistence-baseline.json")
    }

    public static func save(_ items: [PersistenceItem], to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(items).write(to: file, options: .atomic)
    }

    public static func load(from file: URL = defaultFile) throws -> [PersistenceItem] {
        try JSONDecoder().decode([PersistenceItem].self, from: Data(contentsOf: file))
    }

    public static func diff(old: [PersistenceItem], new: [PersistenceItem]) -> PersistenceDiff {
        let o = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let sort: ([PersistenceItem]) -> [PersistenceItem] = { $0.sorted { $0.path < $1.path } }
        return PersistenceDiff(
            added: sort(n.filter { o[$0.key] == nil }.map(\.value)),
            removed: sort(o.filter { n[$0.key] == nil }.map(\.value)),
            changed: sort(n.compactMap { k, v in o[k].map { $0.contentHash != v.contentHash ? v : nil } ?? nil }))
    }
}
