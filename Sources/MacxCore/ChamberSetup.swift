import Foundation

/// The files `macx chamber setup` downloads, each pinned by SHA-256 in a reviewed commit
/// (`data/chamber/manifest-ARCH.json`, made by `scripts/chamber/make-manifest.py`).
public struct ChamberManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var role: String  // rootfs, kernel or package
        public var name: String
        public var version: String
        public var url: String
        public var sha256: String
        public var bytes: Int
    }

    public var schema: Int
    public var alpine: String
    public var arch: String
    public var files: [File]

    public static var hostArch: String {
        #if arch(arm64)
            "aarch64"
        #else
            "x86_64"
        #endif
    }

    public enum Problem: Error, Equatable { case unsupportedArch(String) }

    public static func bundled(arch: String = hostArch) throws -> ChamberManifest {
        guard let json = ChamberManifestData.json[arch] else { throw Problem.unsupportedArch(arch) }
        return try JSONDecoder().decode(ChamberManifest.self, from: Data(json.utf8))
    }
}

/// Where the chamber lives once set up: the unpacked Alpine system and the raw kernel. About 60 MB.
public struct ChamberStore: Sendable {
    public var root: URL

    public init(root: URL = ChamberStore.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/Chamber")
    }

    public var rootfs: URL { root.appendingPathComponent("rootfs", isDirectory: true) }
    public var kernel: URL { root.appendingPathComponent("Image") }
    var stamp: URL { root.appendingPathComponent("installed.json") }

    struct Stamp: Codable {
        var alpine: String
        var arch: String
    }

    public func isInstalled(for manifest: ChamberManifest) -> Bool {
        guard let data = try? Data(contentsOf: stamp), let s = try? JSONDecoder().decode(Stamp.self, from: data) else { return false }
        let fm = FileManager.default
        return s.alpine == manifest.alpine && s.arch == manifest.arch && fm.fileExists(atPath: kernel.path)
            && fm.fileExists(atPath: rootfs.path)
    }
}

public protocol ChamberDownloading: Sendable {
    func fetch(_ url: URL) throws -> Data
}

/// Plain HTTPS download, one file at a time.
public struct URLSessionChamberDownloader: ChamberDownloading {
    public init() {}
    public func fetch(_ url: URL) throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("macx/\(macxVersion)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(URLError(.timedOut))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                result = .failure(err)
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(URLError(.badServerResponse))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

/// Reads the files from a local folder by name instead of downloading them (MACX_CHAMBER_MIRROR): offline
/// setups and tests. The SHA-256 checks are exactly the same.
public struct LocalMirrorDownloader: ChamberDownloading {
    public var folder: URL
    public init(folder: URL) { self.folder = folder }
    public func fetch(_ url: URL) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(url.lastPathComponent)) }
}

/// Downloads the pinned files, checks every SHA-256, unpacks the Alpine system and unwraps the kernel.
/// Nothing is used unless its hash matches the manifest.
public struct ChamberSetup: Sendable {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notEnoughSpace(needed: Int, free: Int)
        case hashMismatch(String)
        case unpackFailed(String)
        case kernelFormat(String)

        public var description: String {
            switch self {
            case .notEnoughSpace(let n, let f):
                "Not enough free disk space: the chamber needs about \(n / 1_000_000) MB while setting up, and \(f / 1_000_000) MB are free."
            case .hashMismatch(let name): "\(name) didn't match its pinned SHA-256, so it wasn't used. Nothing was installed."
            case .unpackFailed(let name): "Couldn't unpack \(name)."
            case .kernelFormat(let why): "The kernel isn't in a format the chamber can boot (\(why))."
            }
        }
    }

    public struct Plan: Sendable {
        public var files: [ChamberManifest.File]
        public var downloadBytes: Int
        public var neededBytes: Int
        public var freeBytes: Int
    }

    public var manifest: ChamberManifest
    public var store: ChamberStore
    public var downloader: ChamberDownloading
    public var freeBytes: @Sendable () -> Int

    public init(
        manifest: ChamberManifest, store: ChamberStore = ChamberStore(), downloader: ChamberDownloading = URLSessionChamberDownloader(),
        freeBytes: @escaping @Sendable () -> Int = ChamberSetup.freeSpace
    ) {
        self.manifest = manifest
        self.store = store
        self.downloader = downloader
        self.freeBytes = freeBytes
    }

    public static func freeSpace() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    public func plan() -> Plan {
        let download = manifest.files.reduce(0) { $0 + $1.bytes }
        // Downloads, the unpacked system (about twice the packages) and the kernel, plus room to spare.
        return Plan(files: manifest.files, downloadBytes: download, neededBytes: download * 4 + 100_000_000, freeBytes: freeBytes())
    }

    public func run(progress: (String) -> Void = { _ in }) throws {
        let p = plan()
        guard p.freeBytes >= p.neededBytes else { throw Problem.notEnoughSpace(needed: p.neededBytes, free: p.freeBytes) }
        let fm = FileManager.default
        let downloads = store.root.appendingPathComponent("downloads", isDirectory: true)
        let staging = store.root.appendingPathComponent(".staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: downloads)
            try? fm.removeItem(at: staging)
        }

        // 1. Download and verify everything before unpacking anything.
        var local: [(ChamberManifest.File, URL)] = []
        for f in manifest.files {
            guard let url = URL(string: f.url) else { throw Problem.hashMismatch(f.name) }
            progress("Downloading \(f.name) \(f.version) (\(max(1, f.bytes / 1_000_000)) MB)")
            let data = try downloader.fetch(url)
            guard sha256(data) == f.sha256 else { throw Problem.hashMismatch(f.name) }
            let dest = downloads.appendingPathComponent(url.lastPathComponent)
            try data.write(to: dest)
            local.append((f, dest))
        }

        // 2. Unpack: the base system first, then the packages; the kernel package only gives the kernel.
        let rootfs = staging.appendingPathComponent("rootfs")
        var kernel: Data?
        for (f, file) in local.sorted(by: { order($0.0.role) < order($1.0.role) }) {
            progress("Unpacking \(f.name)")
            if f.role == "kernel" {
                let kdir = staging.appendingPathComponent("kernel")
                try fm.createDirectory(at: kdir, withIntermediateDirectories: true)
                try Self.untar(file, into: kdir, name: f.name)
                guard let raw = try? Data(contentsOf: kdir.appendingPathComponent("boot/vmlinuz-virt")) else {
                    throw Problem.kernelFormat("no boot/vmlinuz-virt in \(f.name)")
                }
                do {
                    kernel = try ChamberKernel.prepare(raw, arch: manifest.arch)
                } catch {
                    throw Problem.kernelFormat("\(error)")
                }
            } else {
                try Self.untar(file, into: rootfs, name: f.name)
            }
        }
        guard let kernel else { throw Problem.kernelFormat("the manifest has no kernel") }

        // 3. Swap the new chamber in.
        try? fm.removeItem(at: store.rootfs)
        try fm.moveItem(at: rootfs, to: store.rootfs)
        try kernel.write(to: store.kernel, options: .atomic)
        try JSONEncoder().encode(ChamberStore.Stamp(alpine: manifest.alpine, arch: manifest.arch)).write(to: store.stamp, options: .atomic)
        progress("Chamber ready: Alpine \(manifest.alpine) (\(manifest.arch))")
    }

    func order(_ role: String) -> Int { role == "rootfs" ? 0 : role == "package" ? 1 : 2 }

    /// macOS's tar refuses `..`, absolute paths and writing through symlinks by default. Alpine's package
    /// metadata (dot files at the top) is left out.
    static func untar(_ file: URL, into dir: URL, name: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = [
            "-xzf", file.path, "-C", dir.path, "--no-same-owner", "--exclude", ".SIGN*", "--exclude", ".PKGINFO", "--exclude", ".*-install",
            "--exclude", ".*-upgrade", "--exclude", ".*-deinstall", "--exclude", ".trigger",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Problem.unpackFailed(name) }
    }
}
