import AppKit

/// The last app you were in that isn't Macximesed, so "Why it's slow" doesn't call the game you just left a
/// background hog because you clicked over to look at this window.
@MainActor
final class FrontApp {
    static let shared = FrontApp()
    private(set) var lastPath: String?
    private var observer: NSObjectProtocol?

    private init() {
        note(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { FrontApp.shared.note(app) }
        }
    }

    private func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != getpid(), let url = app.bundleURL else { return }
        lastPath = url.path
    }

    /// An ordinary quit (the app can save its work), never a force quit. False if it isn't running.
    static func quit(appAt path: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
        apps.forEach { $0.terminate() }
        return !apps.isEmpty
    }
}
