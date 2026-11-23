import AppKit
import ArgumentParser
import Foundation
import MacxCore

struct Guard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Catch pasted download-and-run commands (how AMOS and other ClickFix stealers get in).",
        subcommands: [History.self, Clipboard.self, CheckCommand.self, Install.self, Uninstall.self, Status.self],
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
            commandName: "check", abstract: "Check one command. Exit code 2 means dangerous (the zsh hook uses this).")

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
            }
            throw ExitCode(2)
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
