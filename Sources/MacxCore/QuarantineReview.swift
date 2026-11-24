import Foundation

/// A second look at "the quarantine flag was removed", once Gatekeeper has answered.
///
/// Removing the flag only helps an attacker when the file wouldn't pass Gatekeeper on its own: that's AMOS's move
/// (`xattr -d com.apple.quarantine` on an ad-hoc payload). Package managers do it too, on apps Apple has notarized:
/// Homebrew's own Ruby isn't signed, so `brew upgrade` used to raise a high alert per app and start network following.
/// The rule never trusts a program by its path (`/opt/homebrew` is yours to write to); this looks at the file instead.
///
/// `spctl` takes 0.5-2 s on a large app, so the watch runs this off its event loop and reports the alert afterwards.
public enum QuarantineReview {
    public static func needsReview(_ a: WatchAlert) -> Bool {
        a.rule == "quarantine-removed" && a.severity == .high && !(a.detail ?? "").isEmpty
    }

    /// Which Gatekeeper check fits the file: installers are assessed as installs, apps and programs as programs,
    /// everything else (disk images, documents, scripts) as files that are opened.
    public static func kind(for path: String) -> GatekeeperKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "pkg", "mpkg": .install
        case "app", "": .execute
        default: .open
        }
    }

    public static func review(_ a: WatchAlert, gatekeeper g: GatekeeperResult) -> WatchAlert {
        var out = a
        let path = a.detail ?? ""
        if g.accepted, g.isNotarized || g.isApple {
            out.severity = .low
            out.title = "The download flag was cleared on software Apple notarized (Gatekeeper would allow it anyway)"
            out.detail = path + "\n  Gatekeeper: allowed, \(g.source ?? "notarized")" + (g.origin.map { "\n  \($0)" } ?? "")
        } else if g.accepted {
            out.detail =
                path + "\n  Gatekeeper: allowed, but not notarized (\(g.source ?? "unknown source"))" + (g.origin.map { "\n  \($0)" } ?? "")
        } else {
            out.title = "The download flag was removed from something Gatekeeper would block"
            out.detail = path + "\n  Gatekeeper: " + (g.error ?? g.source ?? "rejected")
        }
        return out
    }
}
