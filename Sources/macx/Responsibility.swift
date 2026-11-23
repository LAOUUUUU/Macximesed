import Darwin
import Foundation

/// macOS charges a command-line tool's privacy access to the app that started it (Terminal, iTerm,
/// an editor...). The installed `macx` re-launches itself as its own "responsible process" so it shows
/// up in System Settings > Privacy & Security as itself and keeps its own Full Disk Access.
///
/// Uses `responsibility_spawnattrs_setdisclaim`, the same private libSystem call LLDB uses to launch
/// debuggees. It's looked up at runtime: if it's ever missing, macx just runs normally.
enum Responsibility {
    static let markerVariable = "MACX_OWN_RESPONSIBILITY"

    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
    typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t

    static var executablePath: String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let raw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    /// Installed copies own their permissions; development builds (inside `.build/`) keep the terminal's.
    /// `MACX_OWN_RESPONSIBILITY=0` turns it off, `=1` forces it on.
    static var shouldDisclaim: Bool {
        switch ProcessInfo.processInfo.environment[markerVariable] {
        case "0", "done": return false
        case "1": return true
        default: return !(executablePath ?? "").contains("/.build/")
        }
    }

    /// True when this process is its own responsible process (macOS asks about macx, not its parent).
    static var isOwnResponsibleProcess: Bool {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return false
        }
        let f = unsafeBitCast(sym, to: ResponsibleFor.self)
        return f(getpid()) == getpid()
    }

    /// Re-executes this binary with responsibility disclaimed and exits with the child's status.
    /// Returns (and the caller just carries on) when it isn't needed or isn't possible.
    static func becomeOwnResponsibleProcessIfNeeded() {
        guard shouldDisclaim, !isOwnResponsibleProcess, let exe = executablePath,
            let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return }
        let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

        var attrs: posix_spawnattr_t?
        guard posix_spawnattr_init(&attrs) == 0 else { return }
        defer { posix_spawnattr_destroy(&attrs) }
        guard setDisclaim(&attrs, true) == 0 else { return }

        var env = ProcessInfo.processInfo.environment
        env[markerVariable] = "done"  // never loop
        let args = [exe] + CommandLine.arguments.dropFirst()
        var cArgs = args.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        guard posix_spawn(&pid, exe, nil, &attrs, &cArgs, &cEnv) == 0 else { return }

        // Ctrl-C reaches the child through the terminal's process group; the parent just waits.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM) { _ in }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let exited = (status & 0x7F) == 0
        exit(exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
    }
}
