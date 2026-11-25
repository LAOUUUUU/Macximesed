import AppKit
import MacxCore
import SwiftUI
import UserNotifications

/// What the app is doing right now, for the status bar: scans, file checks, chamber stages, updates.
struct Activity: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String?
    let started = Date()
}

/// The last thing that finished, shown in the status bar until something else starts.
struct Finished: Equatable {
    var text: String
    var at: Date
}

extension AppModel {
    @discardableResult
    func begin(_ title: String, _ detail: String? = nil) -> UUID {
        let a = Activity(title: title, detail: detail)
        Motion.animate { activities.append(a) }
        return a.id
    }

    func step(_ id: UUID, _ title: String, _ detail: String? = nil) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        Motion.animate {
            activities[i].title = title
            if let detail { activities[i].detail = detail }
        }
    }

    func end(_ id: UUID, _ result: String? = nil) {
        Motion.animate {
            activities.removeAll { $0.id == id }
            if let result { finished = Finished(text: result, at: Date()) }
        }
    }
}

// MARK: - Updates: check now and then, ask, install now or at the chosen moment

extension AppModel {
    static let scheduleKey = "updateSchedule"

    var schedule: UpdateSchedule {
        get {
            (defaults.data(forKey: Self.scheduleKey)).flatMap { try? JSONDecoder().decode(UpdateSchedule.self, from: $0) } ?? .none
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.scheduleKey) }
    }

    /// Runs the app's own `macx` with these arguments, off the main thread: (exit code, output).
    nonisolated static func runMacx(_ args: [String]) async -> (Int32, String) {
        let exe = await AppModel.executable
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (1, "macx couldn't start") }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, out)
        }.value
    }

    /// Runs the app's own `macx update` (one code path with the CLI and Settings).
    nonisolated static func macxUpdate(install: Bool) async -> UpdateReport {
        let exe = await AppModel.executable
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = install ? ["update"] : ["update", "--check"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var out = ""
            var code: Int32 = 1
            if (try? p.run()) != nil {
                out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                code = p.terminationStatus
            }
            return UpdateReport.parse(out, exitCode: code)
        }.value
    }

    /// Quietly asks the update channel. A new version brings up the pop-up (or a notification when no window is open).
    func checkForUpdate() {
        guard !updating, !AppModel.executable.contains("/.build/") else { return }
        let id = begin("Checking for updates")
        Task {
            let report = await Self.macxUpdate(install: false)
            end(id)
            switch report.status {
            case .available(let v), .urgent(let v, _):
                updateAvailable = v
                updateUrgent = { if case .urgent = report.status { return true } else { return false } }()
                if schedule.shouldAsk(about: v, now: Date()) {
                    Motion.animate(Motion.settle) { updatePrompt = v }
                    if !windowOpen { notifyUpdate(v) }
                }
            default:
                updateAvailable = nil
            }
        }
    }

    func choose(_ timing: UpdateSchedule.Timing) {
        guard let v = updatePrompt ?? updateAvailable else { return }
        schedule = UpdateSchedule(version: v, timing: timing, chosen: Date())
        Motion.animate(Motion.settle) { updatePrompt = nil }
        if timing == .now { installUpdate(restart: true) }
    }

    /// Screen asleep, Mac awake again: install if that's what was chosen. After waking, wait for the network.
    func handle(_ event: UpdateSchedule.Event) {
        guard updateAvailable != nil, schedule.installs(on: event, now: Date()) else { return }
        let delay: TimeInterval = event == .woke ? 30 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.installUpdate(restart: true) }
    }

    func installUpdate(restart: Bool) {
        guard !updating, let v = updateAvailable else { return }
        updating = true
        let id = begin("Updating Macximesed", "downloading and checking \(v)")
        Task {
            let report = await Self.macxUpdate(install: true)
            updating = false
            switch report.status {
            case .installed(let installed):
                end(id, "Updated to \(installed)")
                schedule = .none
                updateAvailable = nil
                if restart { Self.relaunch() }
            case .failed(let why):
                end(id, "The update didn't install: \(why)")
            default:
                end(id)
            }
        }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func notifyUpdate(_ v: String) {
        guard notifications == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Macximesed \(v) is out"
        content.body = "Open Macximesed to install it now, or when your screen next sleeps."
        NotificationCenterGuard.center?.add(UNNotificationRequest(identifier: "update-\(v)", content: content, trigger: nil))
    }
}

// MARK: - The bar along the bottom of the window

struct StatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                if let a = model.activities.last {
                    HairlineProgress(width: 56)
                    Text(a.title).font(Fonts.sans(12))
                        .contentTransition(.opacity)
                    if let d = a.detail {
                        Text(d).font(Fonts.mono(11)).foregroundStyle(Ink.grey).lineLimit(1).truncationMode(.middle)
                            .contentTransition(.opacity)
                    }
                    if model.activities.count > 1 {
                        Text("+\(model.activities.count - 1) more").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                    }
                } else {
                    if model.state.glyph == .watching { LiveMark(size: 5) }
                    Text(idle).font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                    if let f = model.finished {
                        Text("·").foregroundStyle(Ink.grey)
                        Text("\(f.text), \(WatchState.clock(f.at))").font(Fonts.sans(12)).foregroundStyle(Ink.grey).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if let v = model.updateAvailable, model.updatePrompt == nil, !model.updating {
                    Button {
                        Motion.animate(Motion.settle) { model.updatePrompt = v }
                    } label: {
                        Text("Update \(v)").font(Fonts.sans(12)).foregroundStyle(model.updateUrgent ? Ink.signal : Ink.text).underline()
                    }
                    .buttonStyle(.plain)
                }
                Text("Version \(BuildVersion.current.description)").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
            }
            .padding(.horizontal, 20)
            .frame(height: 30)
            .background(Ink.side)
            .motion(value: model.activities.map(\.id))
        }
        .accessibilityElement(children: .combine)
    }

    var idle: String {
        switch model.state {
        case .watching(let since): "Watching since \(WatchState.clock(since))"
        case .paused(let until): "Paused until \(WatchState.clock(until))"
        case .starting: "The watch is starting"
        case .refused: "The watch was refused"
        case .notRunning: "The watch isn't running"
        case .notInstalled: "Nothing is watching in the background"
        }
    }
}

/// The update pop-up: a card above the status bar, in the window's own style.
struct UpdatePrompt: View {
    @Bindable var model: AppModel
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: model.updateUrgent ? "Security update" : "Update")
            Text("Macximesed \(version) is out.").font(Fonts.serif(20))
            Text(
                model.updateUrgent
                    ? "The version you have has a security problem. Install it as soon as you can."
                    : "It downloads, checks its signature and installs in a few seconds, then the app restarts. The background watch moves to it by itself."
            )
            .font(Fonts.sans(12.5)).foregroundStyle(Ink.grey).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Button("Install now") { model.choose(.now) }.buttonStyle(PlainButtonStyle(kind: .primary))
                Button("When the screen goes to sleep") { model.choose(.whenScreenSleeps) }.buttonStyle(PlainButtonStyle())
                Button("When the Mac wakes up") { model.choose(.whenMacWakes) }.buttonStyle(PlainButtonStyle())
                Button("Not now") { model.choose(.notNow) }.buttonStyle(.plain).font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                    .padding(.top, 4)
            }
            .fixedSize()
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(Ink.raised)
        .overlay(Rectangle().stroke(Ink.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .transition(.opacity.combined(with: .offset(y: 12)))
    }
}

/// `UNUserNotificationCenter.current()` aborts the whole process (an NSAssertion inside UserNotifications) when macx
/// isn't running from inside its app bundle, e.g. `macx app` from a development build. Crash report 2026-11-24.
enum NotificationCenterGuard {
    static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }
}
