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
        let beta = Update.fetchBetaIfChosen(state: state, timeout: 4)
        let installed = BuildVersion.current
        let decision = UpdateDecision.decide(stable: channel, beta: beta, installed: installed, state: state, now: now)
        Log.info(
            "update",
            "daily check: channel \(channel.sequence), latest \(channel.latest.version), beta \(beta.map { "\($0.sequence) dev-\($0.build.commit)" } ?? "-"), \(decision.action)"
        )
        Update.remember(channel, beta, in: &state)
        // Only the rollback warning here; "out of date" is shown by `macx update`, not before every command.
        decision.warnings.filter { !$0.contains("out of date") }.forEach { note("macx: \($0)") }

        switch decision.action {
        case .none:
            break
        case .notify(let version):
            if !state.noticesOff { note("macx \(version) is out (you have \(installed)). Update with: macx update") }
        case .force(let version, let reason):
            note("macx: version \(installed) has a security problem: \(reason)")
            if let a = channel.minimumSafe?.advisory { note("      Details: \(a)") }
            guard let target = decision.target else { return }
            do {
                try Update.install(target, quiet: false)
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

    @Option(help: "Which builds to get: stable (releases) or beta (a build of every change, named by its commit).")
    var channel: String?

    func run() throws {
        var state = UpdateState.load()
        if let channel {
            guard let new = ReleaseChannel(rawValue: channel) else { throw UserError("Use --channel stable or --channel beta.") }
            do { try state.switchChannel(to: new) } catch { throw UserError("Can't switch: \(error).") }
            try state.save()
            switch new {
            case .beta:
                print("You're on the beta channel: a build of every change to dev, named by its commit (macx --version).")
                print("Beta builds are signed with their own key and published automatically, without a person checking each one.")
                print("Security updates from the stable channel still apply. Run `macx update` to get the newest beta now.")
            case .stable:
                print("You're on the stable channel.")
                if BuildVersion.current.isDev {
                    print("You keep this dev build (\(BuildVersion.current)) until the next release replaces it.")
                }
            }
            return
        }
        if let notices {
            guard ["on", "off"].contains(notices) else { throw UserError("Use --notices on or --notices off.") }
            state.noticesOff = notices == "off"
            try state.save()
            print("Update notices \(notices). Security updates still install automatically.")
            return
        }

        let stable: UpdateChannel
        do { stable = try UpdateClient.fetchChannel(timeout: 15) } catch {
            throw UserError("Couldn't get the update channel: \(error)")
        }
        let beta = Self.fetchBetaIfChosen(state: state, timeout: 15)
        let installed = BuildVersion.current
        let decision = UpdateDecision.decide(stable: stable, beta: beta, installed: installed, state: state, now: Date())
        state.lastCheck = Date()
        Self.remember(stable, beta, in: &state)
        try? state.save()
        decision.warnings.forEach { print($0) }
        if state.channel == .beta, beta == nil { print("Warning: the beta file couldn't be read, so only stable releases were checked.") }
        if let feed = try? HashFeed.refresh(from: stable) { print(HashFeedLine.text(count: feed.count)) }

        switch decision.action {
        case .none:
            print("macx \(installed) is up to date\(state.channel == .beta ? " (beta channel)" : "").")
        case .notify(let v), .force(let v, _):
            if case .force(_, let reason) = decision.action { print("Your version has a security problem: \(reason)") }
            print("macx \(v) is available (you have \(installed)).")
            guard !check, let target = decision.target else { return }
            try Update.install(target, quiet: false)
            print("Updated to \(v). The previous version is kept as macx.previous.")
            if (Responsibility.executablePath ?? "").contains("/.local/bin/") || Responsibility.isOwnResponsibleProcess {
                print("If macx had Full Disk Access, switch it off and on again for the new version (macx privacy --open).")
            }
        }
    }

    /// The beta file, only on Macs that chose beta. A beta file that fails to download or verify is skipped: the
    /// stable check still runs.
    static func fetchBetaIfChosen(state: UpdateState, timeout: TimeInterval) -> BetaChannel? {
        guard state.channel == .beta else { return nil }
        do { return try UpdateClient.fetchBeta(timeout: timeout) } catch {
            Log.warning("update", "beta file not read: \(error)")
            return nil
        }
    }

    /// Raises the rollback marks to what was just seen, each channel on its own.
    static func remember(_ stable: UpdateChannel, _ beta: BetaChannel?, in state: inout UpdateState) {
        state.lastSequence = max(state.lastSequence, stable.sequence)
        if let beta { state.betaSequence = max(state.betaSequence, beta.sequence) }
    }

    static func install(_ target: UpdateTarget, quiet: Bool) throws {
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
        guard let url = URL(string: target.url), url.scheme == "https" else { throw UpdateError.download("not an https link") }
        let name = target.version.description
        if !quiet { FileHandle.standardError.write(Data("Downloading macx \(name)\(target.beta ? " (beta)" : "")…\n".utf8)) }
        Log.info("update", "installing \(name) over \(BuildVersion.current)")
        let data = try UpdateClient.get(url, timeout: 30)
        do {
            try UpdateInstaller().install(
                data, sha256: target.sha256, expecting: target.version, over: URL(fileURLWithPath: exe), installed: .current)
        } catch {
            Log.error("update", "install of \(name) failed: \(error)")
            throw error
        }
        Log.info("update", "installed \(name)")
    }
}
