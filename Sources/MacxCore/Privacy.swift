import Foundation

/// Folders macOS guards with privacy prompts ("would like to access your Documents folder",
/// "...data from other apps", "...files on a removable volume"). Macximesed stays out of them unless it
/// already has Full Disk Access, so it never triggers a prompt.
public struct PrivacyPolicy: Sendable, Equatable {
    public var home: URL
    public var fullDiskAccess: Bool

    public init(home: URL, fullDiskAccess: Bool) {
        self.home = home
        self.fullDiskAccess = fullDiskAccess
    }

    /// Checked once per run.
    public static let current = PrivacyPolicy(
        home: FileManager.default.homeDirectoryForCurrentUser, fullDiskAccess: probeFullDiskAccess())

    /// Home folders with their own privacy prompt, relative to the home folder.
    static let guardedInHome = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
        "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
    ]

    public var guardedRoots: [String] {
        let h = home.standardizedFileURL.path
        return Self.guardedInHome.map { "\(h)/\($0)" } + ["/Volumes"]
    }

    /// True when reading this path can't cause a privacy prompt.
    public func allows(_ url: URL) -> Bool {
        if fullDiskAccess { return true }
        let p = url.standardizedFileURL.path
        return !guardedRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Full Disk Access is the only thing that can open the TCC database. Without it the open just
    /// fails with "Operation not permitted". There's no prompt, so this is safe to ask every run.
    public static func probeFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let db = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(db, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }
}

/// Doesn't look inside guarded folders; reports their programs as unreadable instead.
public struct GuardedSignatureChecker: SignatureChecking {
    public var inner: SignatureChecking
    public var policy: PrivacyPolicy

    public init(inner: SignatureChecking = CodeSignatureChecker(), policy: PrivacyPolicy = .current) {
        self.inner = inner
        self.policy = policy
    }

    public func check(_ path: String) -> SignatureInfo {
        policy.allows(URL(fileURLWithPath: path)) ? inner.check(path) : .unreadable
    }
}
