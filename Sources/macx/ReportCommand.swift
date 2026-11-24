import AppKit
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacxCore
import SystemConfiguration

/// Gathers what goes into a bug report on this Mac: facts macx works out itself, macx's crash reports, the last
/// alerts and the ends of macx's own logs. Shared by `macx report` and the app.
enum ReportCollector {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func redactor(keepFileNames: Bool = false, keepProgramNames: Bool = false) -> ReportRedactor {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let local = SCDynamicStoreCopyLocalHostName(nil) as String?
        var r = ReportRedactor(
            homes: Array(Set([home.path, home.resolvingSymlinksInPath().path])), names: [NSUserName(), NSFullUserName()],
            hosts: [computer, local, local.map { $0 + ".local" }].compactMap { $0 })
        r.keepFileNames = keepFileNames
        r.keepProgramNames = keepProgramNames
        return r
    }

    static func machine() -> String {
        var u = utsname()
        uname(&u)
        let arch = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return arch + (rosetta ? " (under Rosetta)" : "")
    }

    static func facts() -> [(String, String)] {
        let exe = Responsibility.executablePath ?? ""
        let installed =
            exe.contains("/.build/")
            ? "development build"
            : (UpdateInstaller.enclosingApp(of: URL(fileURLWithPath: exe)) != nil ? "Macximesed.app" : "command-line tool")
        var out: [(String, String)] = [
            ("macx", macxVersion), ("macOS", ProcessInfo.processInfo.operatingSystemVersionString), ("Chip", machine()),
            ("Installed as", installed), ("Full Disk Access", PrivacyPolicy.probeFullDiskAccess() ? "on" : "off"),
        ]
        if let settings = DaemonSettings.read() {
            let state = DaemonStatus.read().map { "\($0.state.rawValue)" } ?? "no status yet"
            out.append(("Background watch", "installed, \(state), freeze \(settings.suspend ? "on" : "off")"))
            out.append(("Downloads watch", settings.downloads ? "on" : "off"))
            out.append(("Watch log level", settings.logLevel.name))
        } else {
            out.append(("Background watch", "not installed"))
        }
        return out
    }

    static func tail(_ url: URL, lines: Int = 300) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
    }

    static func logs() -> [(String, [String])] {
        let mine = home.appendingPathComponent("Library/Logs/Macximesed")
        return [
            ("cli.log", mine.appendingPathComponent("cli.log")), ("app.log", mine.appendingPathComponent("app.log")),
            ("watch.log", LogFile.rootFolder.appendingPathComponent("watch.log")),
            ("cli-root.log", LogFile.rootFolder.appendingPathComponent("cli-root.log")),
        ].compactMap { name, url in
            let lines = tail(url)
            return lines.isEmpty ? nil : (name, lines)
        }
    }

    /// The person's own crashes from the last week, and the background watch's waiting in its queue.
    static func input(description: String) -> BugReportInput {
        let week = Date().addingTimeInterval(-7 * 86_400)
        let alerts = AlertRecord.parse(
            (try? String(contentsOf: home.appendingPathComponent("Library/Logs/Macximesed/watch.jsonl"), encoding: .utf8)) ?? ""
        ).filter { $0.rule != "frozen" }.suffix(20)
        return BugReportInput(
            description: description, facts: facts(),
            crashes: CrashReports.summaries(in: CrashReports.userFolder(home: home), since: week),
            queuedCrashes: CrashQueue().waiting(), alerts: Array(alerts), logs: logs())
    }

    static func build(description: String, keepFileNames: Bool, keepProgramNames: Bool) -> (text: String, redactions: Int) {
        let report = BugReport.build(
            input(description: description), redactor: redactor(keepFileNames: keepFileNames, keepProgramNames: keepProgramNames),
            created: Date())
        var state = ReportState.load()
        state.lastCrashSeen = Date()
        try? state.save()
        return report
    }
}

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a bug report from macx's logs and crashes, see all of it, then save, copy or send it.",
        discussion: """
            The report is built on this Mac: versions, whether the watch is on, macx's own crashes, the last alerts \
            (time, severity and rule only) and the end of macx's logs. Your home folder, account and full name, \
            computer name, file names in your folders, app names, IP and MAC addresses, emails and file hashes are \
            taken out first. You see the whole report before anything else happens, and nothing is sent unless you \
            say yes.
            """
    )

    @Option(name: .shortAndLong, help: "What went wrong, in your own words.") var message: String = ""
    @Option(help: "Save the report to this file.", completion: .file()) var save: String?
    @Flag(help: "Copy the report to the clipboard.") var copy = false
    @Flag(help: "Keep file names in your folders (they're shortened by default).") var fileNames = false
    @Flag(help: "Keep app names (they're hidden by default).") var programNames = false
    @Option(help: "Ask after macx crashes (on) or never (off). The app asks when it next opens.") var askAfterCrash: String?

    func run() throws {
        if let askAfterCrash {
            guard ["on", "off"].contains(askAfterCrash) else { throw UserError("Use --ask-after-crash on or off.") }
            var state = ReportState.load()
            state.askAfterCrash = askAfterCrash == "on"
            try state.save()
            print(
                state.askAfterCrash ? "macx will ask after a crash." : "macx won't ask after a crash. `macx report` still works any time.")
            return
        }
        let (text, removed) = ReportCollector.build(description: message, keepFileNames: fileNames, keepProgramNames: programNames)
        Log.info("report", "built a report (\(text.utf8.count) bytes, \(removed) details removed)")
        print(text)
        print("────────")
        if let save {
            let url = URL(fileURLWithPath: (save as NSString).expandingTildeInPath)
            try Data(text.utf8).write(to: url, options: .atomic)
            print("Saved to \(url.path).")
        }
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            print("Copied to the clipboard.")
        }
        guard save == nil, !copy else { return }
        let sending = ReportSending()
        guard sending.isAvailable else {
            print("That's the whole report. Sending isn't set up in this version yet.")
            print("Save it: macx report --save FILE    Copy it: macx report --copy")
            print("To post it yourself: https://github.com/LAOUUUUU/Macximesed/issues/new (public, needs a GitHub account)")
            return
        }
        print("That's the whole report, exactly as it would be sent. It's encrypted on this Mac to the maintainer's key,")
        print("so the relay in between can't read it. No name, email or ID of this Mac goes with it.")
        guard askYes("Send it?") else {
            print("Not sent. Save it: macx report --save FILE    Copy it: macx report --copy")
            return
        }
        do {
            let id = try sending.send(text)
            Log.info("report", "sent, report ID \(id)")
            print("Sent. Report ID: \(id)")
            print("Mention it in a GitHub issue if you'd like a reply, or to have the report deleted.")
        } catch {
            Log.warning("report", "sending failed: \(error)")
            throw UserError("\(error)")
        }
    }
}

/// Maintainer tool: makes the report key pair. The private half goes to a file only you can read; keep it in
/// your password manager and delete the file. The public half is printed, for `ReportKey.current`.
struct ReportKeygen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report-keygen", abstract: "Make the maintainer's report key pair.", shouldDisplay: false)
    @Option(help: "Where to write the private key (it must not exist yet).") var out: String

    func run() throws {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw UserError("\(url.path) already exists.") }
        let key = Curve25519.KeyAgreement.PrivateKey()
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
        else { throw UserError("Couldn't write \(url.path).") }
        print("Private key written to \(url.path) (only you can read it). Put it in your password manager, then delete the file.")
        print("Public key, for ReportKey.current: \(key.publicKey.rawRepresentation.base64EncodedString())")
    }
}

/// Maintainer tool: decrypts a received report (`.mxr`) with the private key.
struct ReportOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report-open", abstract: "Decrypt a received bug report.", shouldDisplay: false)
    @Argument(help: "The .mxr file.", completion: .file()) var file: String
    @Option(help: "File holding the private key (base64).") var key: String
    @Option(help: "Key id the report should name.") var id: UInt8 = 1

    func run() throws {
        let raw = try String(contentsOf: URL(fileURLWithPath: (key as NSString).expandingTildeInPath), encoding: .utf8)
        guard let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let secret = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { throw UserError("That isn't a report private key.") }
        let sealed = try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
        do {
            print(String(decoding: try ReportEnvelope.open(sealed, with: secret, id: id), as: UTF8.self))
        } catch {
            throw UserError("Couldn't open it: \(error). Wrong key or id, or the file was changed.")
        }
    }
}
