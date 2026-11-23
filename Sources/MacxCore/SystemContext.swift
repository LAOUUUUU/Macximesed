import Darwin
import Foundation

// MARK: - Open files (libproc)

public struct OpenFile: Sendable, Equatable {
    public var path: String
    public var process: String
    public var pid: pid_t

    public init(path: String, process: String, pid: pid_t) {
        self.path = path
        self.process = process
        self.pid = pid
    }
}

/// Which files processes have open right now, read from the kernel. Without root this covers the
/// user's own processes, which are the ones that use the user's caches.
public enum OpenFiles {
    public static func snapshot() -> [OpenFile] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 16)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        var out: [OpenFile] = []
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.stride) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
            guard filled > 0 else { continue }
            let name = processName(pid)
            for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var info = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                guard r > 0 else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if !path.isEmpty { out.append(OpenFile(path: path, process: name, pid: pid)) }
            }
        }
        return out
    }

    /// The first process holding a file at or inside `dir`. Compares whole path components.
    public static func holder(of dir: URL, in open: [OpenFile]) -> OpenFile? {
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return open.first { file in
            let p = URL(fileURLWithPath: file.path).standardizedFileURL.resolvingSymlinksInPath().path
            return p == base || p.hasPrefix(prefix)
        }
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"
    }
}

// MARK: - Bundle index (Spotlight)

/// Every bundle ID on disk (apps, helpers, plug-ins), mapped to a display name.
public struct BundleIndex: Sendable, Equatable {
    var names: [String: String]

    public init(_ names: [String: String]) { self.names = names }

    public var count: Int { names.count }
    public var bundleIDs: Dictionary<String, String>.Keys { names.keys }
    public func name(of bundleID: String) -> String? { names[bundleID] }

    /// The bundle that owns a file or folder name: the name is exactly its bundle ID, or its
    /// bundle ID followed by a dot (`com.example.app.ShipIt`, `com.example.app.plist`). Longest
    /// match wins. Plain names ("Game") never match anything.
    public func owner(of entryName: String) -> (bundleID: String, name: String)? {
        var candidate = entryName
        while true {
            if let n = names[candidate] { return (candidate, n) }
            guard let dot = candidate.lastIndex(of: ".") else { return nil }
            candidate = String(candidate[..<dot])
            if !candidate.contains(".") { return nil }
        }
    }

    /// Parses `mdfind -attr kMDItemCFBundleIdentifier ...` output.
    public static func parse(spotlightOutput: String) -> BundleIndex {
        let marker = "   kMDItemCFBundleIdentifier = "
        var names: [String: String] = [:]
        for line in spotlightOutput.split(separator: "\n") {
            guard let r = line.range(of: marker) else { continue }
            let id = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id != "(null)" else { continue }
            let path = String(line[..<r.lowerBound])
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if names[id] == nil || path.hasPrefix("/Applications/") { names[id] = name }
        }
        return BundleIndex(names)
    }

    /// Asks Spotlight; if Spotlight is off or empty, reads Info.plists of the apps it can find.
    public static func current(runner: CommandRunner = ProcessRunner()) -> BundleIndex {
        if let out = try? runner.run("/usr/bin/mdfind", ["-attr", "kMDItemCFBundleIdentifier", "kMDItemCFBundleIdentifier == '*'"]) {
            let index = parse(spotlightOutput: out)
            if index.count > 0 { return index }
        }
        var names: [String: String] = [:]
        for app in AppScanner.scan(AppScanner.fallbackFolders + [URL(fileURLWithPath: "/System/Applications")], lastUsed: { _ in nil }) {
            names[app.bundleID] = app.name
        }
        return BundleIndex(names)
    }
}

public enum ReverseDNS {
    /// File-type endings apps add to their bundle ID when naming files.
    static let fileExtensions = ["plist", "savedState", "binarycookies", "db", "sqlite", "json", "lock", "log"]

    /// `com.example.app`, `io.github.user.tool`: at least three dot-separated parts, the first a
    /// lowercase domain-style label. No list of top-level domains is needed.
    public static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, first.count >= 2,
              first.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_$"))
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    public static func baseName(_ name: String) -> String {
        for ext in fileExtensions where name.hasSuffix("." + ext) {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }
}

// MARK: - Tool caches

public struct ToolCache: Sendable, Equatable {
    public var tool: String
    public var url: URL

    public init(tool: String, url: URL) {
        self.tool = tool
        self.url = url
    }

    /// Asks each installed tool where its cache is, instead of assuming a path.
    public static func current(runner: CommandRunner = ProcessRunner()) -> [ToolCache] {
        var out: [ToolCache] = []
        func ask(_ tool: String, _ args: [String], suffix: String? = nil) {
            guard let exe = ToolFinder.find(tool),
                  let raw = try? runner.run(exe, args).trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.hasPrefix("/") else { return }
            var url = URL(fileURLWithPath: raw, isDirectory: true)
            if let suffix { url = url.appendingPathComponent(suffix, isDirectory: true) }
            out.append(ToolCache(tool: tool, url: url))
        }
        ask("brew", ["--cache"])
        ask("npm", ["config", "get", "cache"], suffix: "_cacache")
        ask("pip3", ["cache", "dir"])
        ask("yarn", ["cache", "dir"])
        ask("pnpm", ["store", "path"])
        return out
    }
}

public enum ToolFinder {
    /// Searches PATH, then the standard Homebrew prefixes (a GUI-launched process may lack them).
    public static func find(_ tool: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Context

/// Facts about this Mac that cleanup decisions are based on. Collected once, injectable in tests.
public struct SystemContext: Sendable {
    public var home: URL
    public var bundles: BundleIndex
    public var runningBundleIDs: Set<String>
    public var openFiles: [OpenFile]
    public var toolCaches: [ToolCache]
    /// Xcode's custom DerivedData folder, when the user set one.
    public var derivedData: URL?

    public init(home: URL, bundles: BundleIndex, runningBundleIDs: Set<String>, openFiles: [OpenFile],
                toolCaches: [ToolCache], derivedData: URL?) {
        self.home = home
        self.bundles = bundles
        self.runningBundleIDs = runningBundleIDs
        self.openFiles = openFiles
        self.toolCaches = toolCaches
        self.derivedData = derivedData
    }

    public var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

    public static func current(runningBundleIDs: Set<String>) -> SystemContext {
        SystemContext(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundles: .current(),
            runningBundleIDs: runningBundleIDs,
            openFiles: OpenFiles.snapshot(),
            toolCaches: ToolCache.current(),
            derivedData: xcodeCustomDerivedData()
        )
    }

    /// Xcode > Settings > Locations > Derived Data, when set to a custom absolute folder.
    static func xcodeCustomDerivedData() -> URL? {
        let prefs = UserDefaults(suiteName: "com.apple.dt.Xcode")
        guard let path = prefs?.string(forKey: "IDECustomDerivedDataLocation"), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
