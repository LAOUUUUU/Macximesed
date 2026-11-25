import Darwin
import Foundation

/// The background watch runs as root, but what it writes in someone's home folder (cases, the undo folder) must be
/// theirs: a root-owned `~/Library/Application Support/Macximesed` locks the user's own macx out of it.
public enum HomeOwnership {
    /// The folders from just below `home` down to `folder` (included) that root owns, top first. Nothing outside
    /// `home`, and never `home` itself.
    public static func rootOwnedFolders(upTo folder: URL, home: URL, owner: (String) -> uid_t?) -> [String] {
        let h = home.standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        guard f.hasPrefix(h + "/") else { return [] }
        var out: [String] = []
        var path = h
        for part in f.dropFirst(h.count + 1).split(separator: "/") {
            path += "/" + part
            if owner(path) == 0 { out.append(path) }
        }
        return out
    }

    /// Hands every root-owned folder from `home` down to `folder` to the user. Only as root; otherwise nothing.
    public static func handOverParents(of folder: URL, home: URL, uid: uid_t, gid: gid_t) {
        guard geteuid() == 0 else { return }
        let paths = rootOwnedFolders(upTo: folder, home: home) { p in
            var st = stat()
            return lstat(p, &st) == 0 ? st.st_uid : nil
        }
        for p in paths { lchown(p, uid, gid) }
    }
}
