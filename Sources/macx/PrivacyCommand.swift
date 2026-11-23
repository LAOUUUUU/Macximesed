import ArgumentParser
import Foundation
import MacxCore

struct Privacy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether macx has Full Disk Access and what it skips without it. --open opens the Settings pane.",
        discussion: """
            Without Full Disk Access, macx never looks inside folders macOS guards (Documents, Desktop, Downloads,
            Pictures, Movies, Music, other apps' containers, iCloud Drive, external disks), so it never causes a
            privacy popup. Install it with scripts/install.sh and give that one binary Full Disk Access to include them.
            """
    )

    @Flag(help: "Open System Settings > Privacy & Security > Full Disk Access.")
    var open = false

    func run() throws {
        let policy = PrivacyPolicy.current
        let exe = Responsibility.executablePath ?? CommandLine.arguments[0]
        // What to add to Full Disk Access: the app when macx runs from inside it (needed on macOS 27).
        let grantee = UpdateInstaller.enclosingApp(of: URL(fileURLWithPath: exe))?.path ?? exe
        print("macx binary:       \(exe)")
        if grantee != exe { print("Inside app:        \(grantee)") }
        print(
            "Permissions owner: \(Responsibility.isOwnResponsibleProcess ? "macx itself" : "the app that started it (terminal or editor)")")
        print("Full Disk Access:  \(policy.fullDiskAccess ? "yes" : "no")")
        if !policy.fullDiskAccess {
            print("\nSkipped so macOS never asks:")
            policy.guardedRoots.forEach { print("  \(($0 as NSString).abbreviatingWithTildeInPath)") }
            print("\nTo include them:")
            if Responsibility.isOwnResponsibleProcess {
                print("  1. Run `macx privacy --open`.")
                print("  2. Click +, press Cmd-Shift-G, paste \(grantee), then Open, and switch it on.")
                print("  Reinstalling macx makes a new binary, so switch it off and on again after an update.")
            } else {
                print("  Install one stable copy with scripts/install.sh, then run `macx privacy --open` from that copy.")
                print("  (This copy runs under your terminal, so macOS would credit the terminal instead.)")
            }
        }
        if open {
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            _ = try? ProcessRunner().run("/usr/bin/open", [url])
        }
    }
}
