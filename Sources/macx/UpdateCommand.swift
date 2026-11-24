import ArgumentParser
import Darwin
import Foundation
import MacxCore

/// The once-a-day check that runs before any command. Updating is up to you, except when the installed
/// version is below the signed security floor: then macx updates itself first and carries on.
enum UpdateCheck {
    static func runIfDue(arguments: [String]) {
        let env = ProcessInfo.processInfo.environment
        if env["MACX_NO_UPDATE_CHECK"] == "1" { return }
        // `update` does its own check; `--version`/`--help` and the zsh hook's `guard check` must stay instant.
        let first = arguments.first ?? ""
        if ["update", "--version", "-h", "--help", "help", ""].contains(first) { return }
        if first == "guard", arguments.dropFirst().first == "check" { return }

        var state = UpdateState.load()
        let now = Date()
        guard state.isCheckDue(now: now) else {
            Log.trace("update", "daily check not due")
            return
        }
        state.lastCheck = now  // even on failure: don't retry on every command
        defer { try? state.save() }

        let channel: UpdateChannel
        do { channel = try UpdateClient.fetchChannel(timeout: 4) } catch {
            Log.warning("update", "daily check failed: \(error)")
            return
        }
        do { _ = try HashFeed.refresh(from: channel) } catch { Log.warning("update", "hash feed not refreshed: \(error)") }
        let decision = UpdateDecision.decide(channel, installed: SemVer(macxVersion)!, state: state, now: now)
        Log.info("update", "daily check: channel \(channel.sequence), latest \(channel.latest.version), \(decision.action)")
        state.lastSequence = max(state.lastSequence, channel.sequence)
        // Only the rollback warning here; "out of date" is shown by `macx update`, not before every command.
        decision.warnings.filter { !$0.contains("out of date") }.forEach { note("macx: \($0)") }

        switch decision.action {
        case .none:
            break
        case .notify(let version):
            if !state.noticesOff { note("macx \(version) is out (you have \(macxVersion)). Update with: macx update") }
        case .force(let version, let reason):
            note("macx: version \(macxVersion) has a security problem: \(reason)")
            if let a = channel.minimumSafe?.advisory { note("      Details: \(a)") }
            do {
                try Update.install(channel, quiet: false)
                note("macx: updated to \(version). Running your command with the new version.")
                try? state.save()
                reexec()
            } catch {
                Log.error("update", "security update failed: \(error)")
                note("macx: couldn't update automatically (\(error)). Run `macx update` as soon as you can.")
            }
        }
    }

    static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Starts the new binary with the same arguments, replacing this process.
    static func reexec() -> Never {
        guard let exe = Responsibility.executablePath else { exit(0) }
        setenv("MACX_NO_UPDATE_CHECK", "1", 1)
        var args = ([exe] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
        execv(exe, &args)
        exit(0)  // only reached if exec failed; the update itself already succeeded
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update macx from the signed release channel (or just check).",
        discussion: """
            macx checks once a day for a new version and tells you; updating is up to you. The exception is a
            version with a known security problem: if the signed channel marks yours as unsafe, macx updates itself
            before running the next command. That check can't be turned off; the "new version" notices can.
            Every update is signed by the project's release key, its SHA-256 is checked, and the old binary is kept
            as macx.previous next to it.
            """
    )

    @Flag(help: "Only check and report; don't install.")
    var check = false

    @Option(help: "Turn the daily \"new version\" notices on or off (security updates still happen).")
    var notices: String?

    func run() throws {
        var state = UpdateState.load()
        if let notices {
            guard ["on", "off"].contains(notices) else { throw UserError("Use --notices on or --notices off.") }
            state.noticesOff = notices == "off"
            try state.save()
            print("Update notices \(notices). Security updates still install automatically.")
            return
        }

        let channel: UpdateChannel
        do { channel = try UpdateClient.fetchChannel(timeout: 15) } catch {
            throw UserError("Couldn't get the update channel: \(error)")
        }
        state.lastCheck = Date()
        state.lastSequence = max(state.lastSequence, channel.sequence)
        try? state.save()
        let decision = UpdateDecision.decide(channel, installed: SemVer(macxVersion)!, state: state, now: Date())
        decision.warnings.forEach { print($0) }
        if let feed = try? HashFeed.refresh(from: channel) { print(HashFeedLine.text(count: feed.count)) }

        switch decision.action {
        case .none:
            print("macx \(macxVersion) is up to date.")
        case .notify(let v), .force(let v, _):
            if case .force(_, let reason) = decision.action { print("Your version has a security problem: \(reason)") }
            print("macx \(v) is available (you have \(macxVersion)).")
            guard !check else { return }
            try Update.install(channel, quiet: false)
            print("Updated to \(v). The previous version is kept as macx.previous.")
            if (Responsibility.executablePath ?? "").contains("/.local/bin/") || Responsibility.isOwnResponsibleProcess {
                print("If macx had Full Disk Access, switch it off and on again for the new version (macx privacy --open).")
            }
        }
    }

    static func install(_ channel: UpdateChannel, quiet: Bool) throws {
        guard let exe = Responsibility.executablePath else { throw UserError("Can't tell where macx is installed.") }
        if exe.contains("/.build/") {
            throw UserError("This is a development build; update it with git pull and swift build instead.")
        }
        if geteuid() == 0 {
            throw UserError("Not updating while running as root (it would leave a root-owned file). Run `macx update` without sudo.")
        }
        guard FileManager.default.isWritableFile(atPath: (exe as NSString).deletingLastPathComponent) else {
            throw UserError("Can't write to \((exe as NSString).deletingLastPathComponent). Reinstall with scripts/install.sh.")
        }
        guard let url = URL(string: channel.latest.url), url.scheme == "https" else { throw UpdateError.download("not an https link") }
        if !quiet { FileHandle.standardError.write(Data("Downloading macx \(channel.latest.version)…\n".utf8)) }
        Log.info("update", "installing \(channel.latest.version) over \(macxVersion)")
        let data = try UpdateClient.get(url, timeout: 30)
        do {
            try UpdateInstaller().install(
                data, sha256: channel.latest.sha256, version: channel.latest.version, over: URL(fileURLWithPath: exe),
                installed: SemVer(macxVersion)!)
        } catch {
            Log.error("update", "install of \(channel.latest.version) failed: \(error)")
            throw error
        }
        Log.info("update", "installed \(channel.latest.version)")
    }
}
