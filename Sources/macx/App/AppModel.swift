import AppKit
import MacxCore
import Observation
import UserNotifications

/// What the window and the menu bar show, read from the real daemon: launchd's answer, the daemon's status file,
/// the root-owned pause file and the alert log. Nothing here needs root; changes go through `runAdmin`.
@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case protection = "Protection"
        case startup = "Startup items"
        case check = "Check a file"
        case clean = "Clean"
        case apps = "Apps"
        case settings = "Settings"
        var id: String { rawValue }
    }

    var section: Section = .protection
    var state: WatchState = .starting
    var pid: Int?
    var installed = false
    var freezesOnCritical = false
    var downloadsWatched = true
    var daemonLogLevel: LogLevel = .info
    var fullDiskAccess = false
    var records: [AlertRecord] = []
    var expected = ExpectedPrograms()
    var seriousOnly = true
    var lastSeenCritical: Date
    var adminError: String?
    var busy = false
    var notifications: SetupFacts.Notifications = .notAsked
    var chamber: ChamberJob = .unknown

    enum ChamberJob: Equatable {
        case unknown, notSetUp, settingUp, ready
        case failed(String)
    }

    @ObservationIgnored var runSetup: (() -> Void)?
    @ObservationIgnored private var notifier = AppNotifications(started: Date())

    // Scan results, kept while the app runs so going back to a screen doesn't scan again ("Scan again" does).
    var startupItems: [PersistenceItem]?
    var startupFindings: [Finding] = []
    var startupAdded: Set<String> = []
    var startupHasBaseline = false
    var cleanItems: [CleanupItem]?
    var cleanChosen: Set<String> = []
    var apps: [AppInfo]?
    var appsSkipped = 0

    // Counts the sidebar shows once a screen has scanned.
    var startupCount: Int?
    var cleanBytes: UInt64?
    var appCount: Int?

    @ObservationIgnored private var tail = AlertTail(file: AppModel.alertFile)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let defaults = UserDefaults.standard

    static var alertFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Macximesed/watch.jsonl")
    }

    /// This app's own binary: root actions run it as `macx daemon …`.
    static var executable: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    init() {
        lastSeenCritical = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "lastSeenCritical"))
        records = tail.readNew().suffix(20_000).map { $0 }
        refresh()
        readNotificationStatus()
        readChamber()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-reads everything. launchctl runs off the main thread; the files are small.
    func refresh() {
        let new = tail.readNew()
        if !new.isEmpty { records = Array((records + new).suffix(20_000)) }
        if !new.isEmpty, notifications == .allowed { post(notifier.offer(new)) }
        Task.detached(priority: .utility) {
            let snapshot = DaemonSnapshot.take()
            await MainActor.run { self.apply(snapshot) }
        }
    }

    private func apply(_ s: DaemonSnapshot) {
        installed = s.installed
        pid = s.info.pid
        freezesOnCritical = s.suspend
        downloadsWatched = s.downloads
        daemonLogLevel = s.logLevel
        fullDiskAccess = s.fullDiskAccess
        let next = WatchState.derive(
            installed: s.installed, running: s.info.state == "running", status: s.status, pausedUntil: s.pausedUntil, now: Date())
        if next != state { state = next }
    }

    // MARK: Alerts

    /// The last 7 days, grouped; most severe and most recent first.
    var groups: [AlertGroup] {
        let week = Date().addingTimeInterval(-7 * 86_400)
        return AlertGroups.make(records.filter { $0.time >= week }, expected: expected.keys)
    }

    var visibleGroups: [AlertGroup] { AlertGroups.filter(groups, seriousOnly: seriousOnly) }

    var today: [AlertRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return records.filter { $0.time >= start && $0.rule != "frozen" }
    }

    var unreadCritical: Int { records.filter { $0.severity == .critical && $0.time > lastSeenCritical }.count }

    func markSeen() {
        guard let last = records.last(where: { $0.severity == .critical })?.time, last > lastSeenCritical else { return }
        lastSeenCritical = last
        defaults.set(last.timeIntervalSince1970, forKey: "lastSeenCritical")
    }

    func markExpected(_ g: AlertGroup) {
        try? expected.add(g)
    }

    // MARK: Notifications (shown by the app while it's open; the daemon uses osascript only when it isn't)

    func readNotificationStatus() {
        Task { notifications = Self.map(await Self.authorizationStatus()) }
    }

    func requestNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            notifications = Self.map(await Self.authorizationStatus())
            if notifications == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
    }

    /// Only the status crosses back: UNNotificationSettings isn't Sendable in the macOS 15 SDK, and the async
    /// `notificationSettings()` would hand it across actors (a build error there, fine on 26).
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus) }
        }
    }

    static func map(_ s: UNAuthorizationStatus) -> SetupFacts.Notifications {
        switch s {
        case .authorized, .provisional: .allowed
        case .denied: .denied
        default: .notAsked
        }
    }

    private func post(_ notes: [AppNotifications.Note]) {
        for n in notes {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Extras

    func readChamber() {
        Task.detached(priority: .utility) {
            let ready = (try? ChamberManifest.bundled()).map { ChamberStore().isInstalled(for: $0) } ?? false
            await MainActor.run { if self.chamber == .unknown || self.chamber == .notSetUp { self.chamber = ready ? .ready : .notSetUp } }
        }
    }

    /// `macx chamber setup --yes` as you (no root): about 50 MB from Alpine Linux, every file checked.
    func setUpChamber() {
        chamber = .settingUp
        let exe = Self.executable
        Task.detached(priority: .utility) {
            let (status, out) = Self.runOwn(exe, ["chamber", "setup", "--yes"])
            let last = out.split(separator: "\n").last.map(String.init) ?? ""
            await MainActor.run { self.chamber = status == 0 ? .ready : .failed(last) }
        }
    }

    nonisolated static func runOwn(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "Couldn't start macx.") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    // MARK: Root actions (each asks for the administrator password)

    func pause(_ duration: String = "1h") {
        runAdmin(["daemon", "pause", "--for", duration], why: "pause the background watch")
    }
    func resume() { runAdmin(["daemon", "resume"], why: "turn the background watch back on") }
    /// Also how the Freeze switch changes freezing: a reinstall, which keeps a switched-off Downloads watch off.
    func install(suspend: Bool) {
        let current = installed ? DaemonSettings(suspend: freezesOnCritical, downloads: downloadsWatched, logLevel: daemonLogLevel) : nil
        runAdmin(DaemonSettings.installArguments(suspend: suspend, keeping: current), why: "install the background watch")
    }
    /// The setting lives in the root-owned launchd plist, so changing it takes the administrator password.
    func setDownloads(_ on: Bool) {
        runAdmin(["daemon", "downloads", on ? "on" : "off"], why: "turn the Downloads watch \(on ? "on" : "off")")
    }
    func uninstall() { runAdmin(["daemon", "uninstall"], why: "remove the background watch") }
    func restart() { runAdmin(["daemon", "restart"], why: "restart the background watch") }

    func runAdmin(_ arguments: [String], why: String) {
        busy = true
        adminError = nil
        let script = AdminCommand.appleScript(
            executable: Self.executable, arguments: arguments, user: NSUserName(), prompt: "Macximesed needs your password to \(why).")
        Log.info("app", "admin action: \(LogRole.commandName(arguments))")
        Task.detached(priority: .userInitiated) {
            let result = OsaScript.run(script)
            if let result { Log.warning("app", "admin action \(LogRole.commandName(arguments)) ended: \(result)") }
            await MainActor.run {
                self.busy = false
                // -128: the user pressed Cancel on the password prompt. Not an error.
                if let error = result, !error.contains("-128") { self.adminError = error }
                self.refresh()
            }
        }
    }
}

/// One read of the daemon's state, taken off the main thread.
struct DaemonSnapshot: Sendable {
    var installed: Bool
    var info: LaunchdInfo
    var status: DaemonStatus?
    var pausedUntil: Date?
    var suspend: Bool
    var downloads: Bool
    var logLevel: LogLevel
    var fullDiskAccess: Bool

    static func take() -> DaemonSnapshot {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(DaemonPlan.label)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var info = LaunchdInfo()
        if (try? p.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if p.terminationStatus == 0 { info = LaunchdInfo.parse(out) }
        }
        let plist = (try? Data(contentsOf: DaemonPlan.plistPath))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let settings = plist.flatMap(DaemonSettings.init(plist:))
        return DaemonSnapshot(
            installed: plist != nil, info: info, status: DaemonStatus.read(), pausedUntil: WatchPause.activeUntil(),
            suspend: settings?.suspend ?? false, downloads: settings?.downloads ?? true, logLevel: settings?.logLevel ?? .info,
            fullDiskAccess: PrivacyPolicy.probeFullDiskAccess())
    }
}

enum OsaScript {
    /// Runs AppleScript through osascript (so the password prompt never blocks the app); returns the error text.
    static func run(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "Couldn't run osascript." }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
