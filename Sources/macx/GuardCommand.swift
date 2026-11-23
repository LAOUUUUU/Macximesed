import AppKit
import ArgumentParser
import Foundation
import MacxCore

struct Guard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Catch pasted download-and-run commands (how AMOS and other ClickFix stealers get in).",
        subcommands: [History.self, Clipboard.self, CheckCommand.self, Inspect.self, Install.self, Uninstall.self, Status.self],
        defaultSubcommand: History.self
    )

    static func describe(_ r: GuardResult) -> [String] {
        var lines = r.patterns.sorted { $0.rawValue < $1.rawValue }.map { "- \($0.title)  [\($0.rawValue)]" }
        lines += r.decoded.map { "- Hidden command (decoded from base64): \($0)" }
        return lines
    }

    struct History: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scan your shell histories (zsh, Terminal's per-tab zsh sessions, bash, fish) for dangerous commands.")

        func run() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let files = ShellHistory.files(home: home)
            let hits = PasteGuard.scanHistory(home: home)
            print("Checked \(files.count) history files.")
            if hits.isEmpty {
                print("No download-and-run, hidden base64, quarantine-stripping or password-prompt commands found.")
                return
            }
            print("")
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .medium
            for h in hits {
                let when = h.entry.date.map { df.string(from: $0) } ?? "unknown time"
                let file = (h.entry.file as NSString).abbreviatingWithTildeInPath
                print("\(when)  \(file):\(h.entry.line)")
                print("  $ \(h.entry.command.prefix(300))")
                Guard.describe(h.result).forEach { print("    \($0)") }
                print("")
            }
            print("\(hits.count) dangerous commands in your history. If you didn't mean to run one, check `macx persist`,")
            print("and from a different, clean device change the passwords that were on this Mac.")
        }
    }

    struct Clipboard: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check what's on the clipboard before you paste it into Terminal.")

        func run() throws {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                print("The clipboard has no text.")
                return
            }
            let r = PasteGuard.check(text)
            guard r.isDangerous else {
                print("Clipboard text looks fine (\(text.count) characters).")
                return
            }
            print("DON'T PASTE THIS into Terminal:")
            print("  \(text.prefix(300))")
            Guard.describe(r).forEach { print("  \($0)") }
            print("Websites that tell you to paste commands to \"fix\" or \"verify\" something are a common way Macs get infected.")
            throw ExitCode(2)
        }
    }

    struct CheckCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Check one command. Exit code 2 means dangerous, 3 means it downloads code to run (use guard inspect).")

        @Flag(help: "One short message (for the zsh hook).")
        var short = false

        @Argument(parsing: .captureForPassthrough, help: "The command, after --.")
        var command: [String] = []

        func run() throws {
            let text = command.first == "--" ? command.dropFirst().joined(separator: " ") : command.joined(separator: " ")
            let r = PasteGuard.check(text)
            guard r.isDangerous else {
                if !short { print("Looks fine.") }
                return
            }
            if short {
                print("macx: stopped. " + r.patterns.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: "; ") + ".")
                if let d = r.decoded.first { print("Hidden command: \(d.prefix(160))") }
            } else {
                print("Dangerous:")
                Guard.describe(r).forEach { print("  \($0)") }
                if r.needsInspection { print("Read what it would run first: macx guard inspect -- '<the command>'") }
            }
            throw ExitCode(r.needsInspection ? 3 : 2)
        }
    }

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download and read what a pasted command would run, then optionally run that exact copy.",
            discussion: """
                For commands like `curl URL | sh`, `bash <(curl URL)`, `sh -c "$(curl URL)"` or `curl -o f URL && sh f`
                (including disguised or base64-hidden ones), macx downloads the script the way curl would, without
                running it, and reads it. It reports what the script does (password prompts, keychain or browser data,
                uploads, launch items, more downloads, which are followed one level) and facts about where it came from
                (bare IP, plain http, a redirect, a site you've never used before, a program instead of a script).
                If you choose to run it, macx runs the copy it inspected, so the server can't swap it.
                """
        )

        @Flag(name: [.short, .long], help: "Run the inspected copy without asking when nothing dangerous was found.")
        var yes = false

        @Flag(help: "Only report; never offer to run.")
        var noRun = false

        @Argument(parsing: .captureForPassthrough, help: "The command, after --.")
        var command: [String] = []

        func run() throws {
            let text = command.first == "--" ? command.dropFirst().joined(separator: " ") : command.joined(separator: " ")
            guard !text.isEmpty else {
                throw UserError("Give the command after --, for example: macx guard inspect -- 'curl -fsSL https://… | sh'")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let history = ShellHistory.files(home: home).flatMap(ShellHistory.read).map(\.command).filter { $0 != text }
            let inspector = PasteInspector(knownHosts: ScriptInspector.hosts(inHistory: history))
            let report = inspector.inspect(command: text)

            guard !report.runs.isEmpty else {
                let r = PasteGuard.check(text)
                if r.isDangerous {
                    print("This doesn't download a script to run, but:")
                    Guard.describe(r).forEach { print("  \($0)") }
                    throw ExitCode(2)
                }
                print("This command doesn't download anything to run.")
                return
            }

            for (i, run) in report.runs.enumerated() {
                if i > 0 { print("") }
                printRun(run)
            }
            let otherPatterns = report.guardResult.patterns.subtracting([.downloadToShell])
            if !otherPatterns.isEmpty {
                print("\nThe command itself also:")
                otherPatterns.sorted { $0.rawValue < $1.rawValue }.forEach { print("  - \($0.title)  [\($0.rawValue)]") }
            }

            let verdict: String =
                switch report.verdict {
                case .ok: "Nothing dangerous found"
                case .partlyUnknown: "Nothing dangerous in what could be read, but parts couldn't be checked (see Can't tell)"
                case .caution: "Be careful"
                case .dangerous: "DON'T RUN THIS"
                }
            print("\nVerdict: \(verdict)")
            guard !noRun else { throw report.verdict == .dangerous ? ExitCode(2) : ExitCode.success }

            let runnable = report.runs.filter { $0.savedCopy != nil && ($0.inspection?.kind == .script || $0.inspection?.kind == .binary) }
            guard !runnable.isEmpty else { throw ExitCode(2) }
            if report.runs.count > 1 || ShellWords.commands(ShellNormalizer.normalize(text)).count > 1 {
                print("Note: only the downloaded script\(runnable.count > 1 ? "s run" : " runs"), not the rest of your command.")
            }

            let go: Bool
            if report.verdict == .dangerous {
                go = askTyped("Type RUN to run the inspected copy anyway (anything else cancels):", expected: "RUN")
            } else {
                go = yes || askYes("Run the inspected copy?")
            }
            guard go else {
                print("Not run.")
                throw report.verdict == .dangerous ? ExitCode(2) : ExitCode.success
            }
            for r in runnable { try execute(r) }
        }

        func printRun(_ r: InspectedRun) {
            print("Download: \(r.run.url)")
            print("  Run by: \(r.run.interpreter ?? "itself") (\(r.run.form.rawValue))")
            if let e = r.error {
                print("  Couldn't download it: \(e). Without seeing it, don't run it.")
                return
            }
            guard let i = r.inspection else { return }
            if i.finalURL != i.url { print("  Ends up at: \(i.finalURL.absoluteString)") }
            print("  Got: \(i.kind.rawValue), \(formatBytes(UInt64(i.bytes))), SHA-256 \(i.sha256)")
            if let saved = r.savedCopy { print("  Saved copy: \(saved.path)") }
            printFindings("What it does", i.behaviours)
            printFindings("Where it's from", i.facts)
            printFindings("Can't tell (not checked, never treated as safe)", i.unknowns)
            if i.behaviours.isEmpty, i.kind == .script { print("  What it does: nothing on the watch list") }
            for n in i.nested {
                print("  It also downloads: \(n.url.absoluteString)  (\(n.kind.rawValue), \(formatBytes(UInt64(n.bytes))))")
                printFindings("    What that does", n.behaviours)
                printFindings("    Where that's from", n.facts)
            }
            let unfetched = i.nestedDownloads.count - i.nested.count
            if unfetched > 0 { print("  \(unfetched) further download(s) couldn't be fetched to check.") }
        }

        func printFindings(_ title: String, _ list: [CheckFinding]) {
            guard !list.isEmpty else { return }
            print("  \(title):")
            for f in list.sorted(by: { $0.severity > $1.severity }) {
                print("    \(f.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f.title)  [\(f.rule)]")
                if let d = f.detail { d.split(separator: "\n").prefix(3).forEach { print("             \($0)") } }
            }
        }

        /// Runs the exact bytes that were inspected: with the named interpreter, the script's own `#!`, or directly for a program.
        /// The bytes are read once and their SHA-256 checked against the inspection. A script is then
        /// fed to its interpreter on stdin, as `curl … | sh` does, so there's no file to swap. Anything
        /// that has to be a file (a program, or an interpreter with no stdin mode) is written to a fresh
        /// private folder, run, and deleted.
        func execute(_ r: InspectedRun) throws {
            guard let saved = r.savedCopy, let inspection = r.inspection else { return }
            let bytes: Data
            do { bytes = try VerifiedCopy.bytes(at: saved, sha256: inspection.sha256) } catch let e as VerifiedCopy.Mismatch {
                throw UserError("Not run: \(e.description). Inspect it again.")
            }
            let fm = FileManager.default
            let p = Process()
            var stdinData: Data?
            var scratch: URL?
            defer { if let scratch { try? fm.removeItem(at: scratch) } }

            func privateFile(mode: Int) throws -> URL {
                let dir = fm.temporaryDirectory.appendingPathComponent("macx-run-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                scratch = dir
                let f = dir.appendingPathComponent(saved.lastPathComponent)
                guard fm.createFile(atPath: f.path, contents: bytes, attributes: [.posixPermissions: mode]) else {
                    throw UserError("Couldn't prepare the copy to run.")
                }
                return f
            }

            if inspection.kind == .binary {
                p.executableURL = try privateFile(mode: 0o500)
                p.arguments = r.run.arguments
            } else {
                let named = r.run.interpreter.flatMap { ["source", ".", "eval"].contains($0) ? nil : $0 }
                let interpreter = named ?? shebang(bytes) ?? "sh"
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                if let stdinArgs = VerifiedCopy.stdinArguments(for: interpreter, scriptArgs: r.run.arguments), r.run.form == .pipe {
                    p.arguments = [interpreter] + stdinArgs
                    stdinData = bytes
                } else {
                    p.arguments = [interpreter, try privateFile(mode: 0o400).path] + r.run.arguments
                }
            }

            let input = Pipe()
            if stdinData != nil { p.standardInput = input }
            print("\nRunning the inspected copy (SHA-256 \(inspection.sha256.prefix(12))… verified)…\n")
            fflush(stdout)  // so the report comes before the script's own output
            try p.run()
            if let stdinData {
                input.fileHandleForWriting.write(stdinData)
                try? input.fileHandleForWriting.close()
            }
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
        }

        func shebang(_ bytes: Data) -> String? {
            let first = String(decoding: bytes.prefix(200), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            guard first.hasPrefix("#!") else { return nil }
            let parts = first.dropFirst(2).split(separator: " ").map(String.init)
            if let p = parts.first, (p as NSString).lastPathComponent == "env" { return parts.dropFirst().first }
            return parts.first.map { ($0 as NSString).lastPathComponent }
        }

        func askTyped(_ question: String, expected: String) -> Bool {
            guard isatty(STDIN_FILENO) != 0 else { return false }
            print(question + " ", terminator: "")
            return readLine()?.trimmingCharacters(in: .whitespaces) == expected
        }
    }

    static func hook() -> GuardHook {
        let exe = Responsibility.executablePath ?? CommandLine.arguments[0]
        let env = ProcessInfo.processInfo.environment
        let zdot = env["ZDOTDIR"].map { URL(fileURLWithPath: $0) }
        // Shell config follows $HOME, like the shell itself does.
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return GuardHook(home: home, macxPath: exe, zdotdir: zdot)
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add the paste guard to zsh: dangerous commands are stopped once before they run.")

        func run() throws {
            let hook = Guard.hook()
            if (Responsibility.executablePath ?? "").contains("/.build/") {
                print(
                    "Note: this is a development build. Install macx first (scripts/install.sh) so the hook keeps working after rebuilds.")
            }
            try hook.install()
            print("Installed. Open a new terminal tab to use it.")
            print("  Hook:   \(hook.script.path)")
            print("  Loaded from one marked block in \(hook.zshrc.path)")
            print("Remove it any time with: macx guard uninstall")
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the zsh paste guard.")
        func run() throws {
            let hook = Guard.hook()
            try hook.uninstall()
            print("Removed. Open a new terminal tab for it to take effect.")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the zsh paste guard is installed.")
        func run() throws {
            let hook = Guard.hook()
            print(hook.isInstalled ? "Installed (\(hook.zshrc.path))." : "Not installed. Add it with: macx guard install")
        }
    }
}
