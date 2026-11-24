import Darwin
import Foundation

/// Builds the light chamber's initramfs for one run: the unpacked Alpine system, a fake Mac home with bait
/// files, stand-ins for Mac-only commands, the start-up script (the agent) and the pinned sample.
public enum ChamberImage {
    public static let guestHome = "/Users/chamber"
    /// What the stand-in password boxes "type", so a stealer carries on and shows what it does with it.
    public static let canaryPassword = "macx-canary-password"

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case cantRunHere(String)

        public var description: String {
            switch self {
            case .cantRunHere(let what): "\(what) can't run in the light chamber (it runs scripts, in Linux). The file checks still apply."
            }
        }
    }

    public enum Kind: Equatable, Sendable { case script(interpreter: String) }

    /// Shell scripts run; Mac programs, compiled AppleScript and languages the chamber doesn't have don't.
    public static func kind(of data: Data) throws -> Kind {
        let b = [UInt8](data.prefix(8))
        let machO: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xFE, 0xED, 0xFA, 0xCF]]
        if b.count >= 4, machO.contains(Array(b.prefix(4))) { throw Problem.cantRunHere("A Mac program (Mach-O)") }
        if data.starts(with: Data("FasdUAS".utf8)) { throw Problem.cantRunHere("Compiled AppleScript") }
        let firstLine = String(decoding: data.prefix(256), as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard firstLine.hasPrefix("#!") else { return .script(interpreter: "/bin/zsh") }
        let words = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        var program = (words.first ?? "") as NSString
        if program.lastPathComponent == "env", words.count > 1 { program = words[1] as NSString }
        switch program.lastPathComponent {
        case "sh": return .script(interpreter: "/bin/sh")
        case "bash": return .script(interpreter: "/bin/bash")
        case "zsh": return .script(interpreter: "/bin/zsh")
        default: throw Problem.cantRunHere("A \(program.lastPathComponent) script")
        }
    }

    public static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = String(base.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "_" }).prefix(80)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "sample" : String(cleaned)
    }

    public static func build(rootfs: URL, sample: ChamberSample, seconds: Int) throws -> Data {
        try sample.verifyUnchanged()
        let data = try Data(contentsOf: sample.url)
        guard case .script(let interpreter) = try kind(of: data) else { throw Problem.cantRunHere("This file") }
        var archive = CPIOArchive()
        try addTree(rootfs, to: &archive)
        for dir in [
            "proc", "sys", "dev", "tmp", "Applications", "Library/LaunchDaemons", "Library/LaunchAgents", "\(home)/Library/LaunchAgents",
        ] {
            archive.addDirectory(dir)
        }
        for (path, body) in bait { archive.addFile(path, data: Data(body.utf8)) }
        for (name, script) in standIns {
            for dir in standInPaths(name) { archive.addFile("\(dir)/\(name)", data: Data(script.utf8), mode: 0o755) }
        }
        let name = safeName(sample.url.lastPathComponent)
        archive.addFile("\(home)/Downloads/\(name)", data: data, mode: 0o755)
        archive.addFile("init", data: Data(initScript(sample: name, interpreter: interpreter, seconds: seconds).utf8), mode: 0o755)
        return archive.data()
    }

    static var home: String { String(guestHome.dropFirst()) }

    /// Adds a folder tree as it is: files with their modes, folders, and symlinks as symlinks (never followed).
    static func addTree(_ root: URL, to archive: inout CPIOArchive) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { return }
        for case let rel as String in walker {
            let full = root.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let mode = UInt32(st.st_mode) & 0o7777
            switch st.st_mode & S_IFMT {
            case S_IFDIR: archive.addDirectory(rel, mode: mode)
            case S_IFLNK:
                if let target = try? fm.destinationOfSymbolicLink(atPath: full) { archive.addSymlink(rel, target: target) }
            case S_IFREG:
                if let d = fm.contents(atPath: full) { archive.addFile(rel, data: d, mode: mode) }
            default: continue
            }
        }
    }

    static func standInPaths(_ name: String) -> [String] {
        switch name {
        case "system_profiler", "sysctl", "ioreg", "spctl", "diskutil", "scutil", "networksetup": ["usr/sbin", "sbin", "usr/bin"]
        case "launchctl", "uname": ["bin", "usr/bin"]
        default: ["usr/bin"]
        }
    }

    static func initScript(sample: String, interpreter: String, seconds: Int) -> String {
        """
        #!/bin/sh
        # macx light chamber agent: run the sample once under strace, print the trace, power off.
        mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev; mount -t tmpfs tmp /tmp
        export HOME=\(guestHome) USER=chamber LOGNAME=chamber SHELL=/bin/zsh LANG=en_US.UTF-8
        export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        echo "==MACX-READY=="
        cd \(guestHome)/Downloads
        strace -f -ttt -qq -s 4096 -e trace=\(StraceLog.traceSyscalls) -o /tmp/trace \\
            timeout -s KILL \(seconds) \(interpreter) ./\(sample) > /tmp/out 2>&1 < /dev/null
        echo "==MACX-TRACE=="; cat /tmp/trace; echo "==MACX-END=="
        echo "==MACX-OUTPUT=="; head -c 65536 /tmp/out; echo; echo "==MACX-OUTPUT-END=="
        poweroff -f

        """
    }

    /// Files a stealer goes for. Opening any of them shows up in the trace.
    static let bait: [String: String] = [
        "\(home)/Library/Keychains/login.keychain-db": "macx chamber bait keychain\n",
        "\(home)/Library/Application Support/Google/Chrome/Default/Login Data": "bait\n",
        "\(home)/Library/Application Support/Google/Chrome/Default/Cookies": "bait\n",
        "\(home)/Library/Application Support/Google/Chrome/Default/Web Data": "bait\n",
        "\(home)/Library/Application Support/Google/Chrome/Local State": "{}\n",
        "\(home)/Library/Application Support/Firefox/Profiles/macx.default/logins.json": "{}\n",
        "\(home)/Library/Application Support/Firefox/Profiles/macx.default/key4.db": "bait\n",
        "\(home)/Library/Application Support/Firefox/Profiles/macx.default/cookies.sqlite": "bait\n",
        "\(home)/Library/Application Support/Exodus/exodus.wallet/seed.seco": "bait\n",
        "\(home)/Library/Cookies/Cookies.binarycookies": "bait\n",
        "\(home)/Documents/notes.txt": "nothing here\n",
        "\(home)/Desktop/todo.txt": "nothing here\n",
        "System/Library/CoreServices/SystemVersion.plist":
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ProductName</key><string>macOS</string><key>ProductVersion</key><string>27.0.1</string><key>ProductBuildVersion</key><string>26A434</string></dict></plist>\n",
    ]

    /// Stand-ins for Mac-only commands. strace records each call; these just answer like a Mac so the script
    /// carries on. Nothing here talks to the network (there isn't one).
    static let standIns: [String: String] = {
        func sh(_ body: String) -> String { "#!/bin/sh\n# macx chamber stand-in\n\(body)\n" }
        let quiet = sh("exit 0")
        return [
            "osascript": sh(
                """
                case "$*" in
                  *"text returned"*|*"hidden answer"*|*assword*) echo "\(canaryPassword)" ;;
                  *"display dialog"*) echo "button returned:OK" ;;
                esac
                exit 0
                """),
            "security": sh(
                """
                case "$1" in
                  find-generic-password|find-internet-password|dump-keychain|export|unlock-keychain)
                    cat "$HOME/Library/Keychains/login.keychain-db" > /dev/null 2>&1; echo "macx-canary-secret" ;;
                esac
                exit 0
                """),
            "dscl": sh("exit 0  # -authonly: every password \"works\", so the script keeps going"),
            "system_profiler": sh(
                """
                cat <<'EOF'
                Hardware:

                    Hardware Overview:

                      Model Name: MacBook Pro
                      Model Identifier: Mac15,3
                      Chip: Apple M3
                      Total Number of Cores: 8 (4 performance and 4 efficiency)
                      Memory: 16 GB
                      Serial Number (system): C02MACXCHMBR
                      Hardware UUID: 6D1F3E2A-0B4C-4E59-9A7D-2C8F1B3E4D5A
                EOF
                """),
            "sw_vers": sh(
                """
                case "$1" in
                  -productName) echo macOS ;; -productVersion) echo 27.0.1 ;; -buildVersion) echo 26A434 ;;
                  *) printf 'ProductName:\\t\\tmacOS\\nProductVersion:\\t\\t27.0.1\\nBuildVersion:\\t\\t26A434\\n' ;;
                esac
                """),
            "uname": sh(
                """
                case "$1" in
                  -m|-p) echo arm64 ;; -r) echo 26.0.0 ;; -n) echo Chambers-MacBook-Pro.local ;;
                  -a) echo "Darwin Chambers-MacBook-Pro.local 26.0.0 Darwin Kernel Version 26.0.0 arm64" ;;
                  *) echo Darwin ;;
                esac
                """),
            "sysctl": sh(
                """
                case "$*" in
                  *hw.model*) echo Mac15,3 ;; *hw.memsize*) echo 17179869184 ;; *hw.ncpu*) echo 8 ;;
                  *machdep.cpu.brand_string*) echo "Apple M3" ;; *) exit 0 ;;
                esac
                """),
            "ioreg": sh("echo '  \"model\" = <\"Mac15,3\">'; echo '  \"IOPlatformSerialNumber\" = \"C02MACXCHMBR\"'"),
            "sudo": sh(
                """
                while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
                exec "$@"
                """),
            "curl": sh(
                """
                # No network here: note where it wanted to go (strace has the arguments) and give back nothing.
                while [ $# -gt 0 ]; do case "$1" in -o|--output) shift; : > "$1" 2>/dev/null ;; esac; shift; done
                exit 0
                """),
            "wget": sh(
                """
                while [ $# -gt 0 ]; do case "$1" in -O) shift; [ "$1" != "-" ] && : > "$1" 2>/dev/null ;; esac; shift; done
                exit 0
                """),
            "launchctl": quiet, "xattr": quiet, "codesign": quiet, "spctl": quiet, "open": quiet, "killall": quiet,
            "defaults": quiet, "ditto": quiet, "hdiutil": quiet, "csrutil": sh("echo 'System Integrity Protection status: enabled.'"),
            "diskutil": quiet, "pbcopy": quiet, "pbpaste": quiet, "say": quiet, "scutil": quiet, "networksetup": quiet,
            "mdfind": quiet, "plutil": quiet, "softwareupdate": quiet, "pmset": quiet, "caffeinate": quiet,
        ]
    }()
}
