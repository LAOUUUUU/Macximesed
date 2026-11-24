import AppKit
import MacxCore
import ServiceManagement
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Ink.line).frame(width: 1)
            Group {
                switch model.section {
                case .protection: ProtectionView(model: model)
                case .startup: StartupView(model: model)
                case .check: CheckView()
                case .clean: CleanView(model: model)
                case .apps: AppsView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Ink.paper)
        .foregroundStyle(Ink.text)
        .font(Fonts.sans(13))
        .monospacedDigit()
        .frame(minWidth: 940, minHeight: 600)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let error = model.adminError {
                HStack(spacing: 12) {
                    Text(error).font(Fonts.sans(12.5)).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.adminError = nil }.buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 48).padding(.vertical, 12)
                .background(Ink.raised)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel

    func count(_ s: AppModel.Section) -> String {
        switch s {
        case .protection: model.unreadCritical > 0 ? "\(model.unreadCritical)" : ""
        case .startup: model.startupCount.map(String.init) ?? ""
        case .clean: model.cleanBytes.map(ByteCountFormatter.file) ?? ""
        case .apps: model.appCount.map(String.init) ?? ""
        case .check, .settings: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Macximesed").font(Fonts.serif(19)).tracking(-0.2)
                .padding(.horizontal, 18).padding(.top, 68).padding(.bottom, 18)
            ForEach(AppModel.Section.allCases) { s in
                Button {
                    model.section = s
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.rawValue).font(Fonts.sans(13, model.section == s ? .semibold : .regular))
                        Spacer()
                        Text(count(s)).font(Fonts.mono(11)).foregroundStyle(s == .protection ? Ink.signal : Ink.grey)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(model.section == s ? Ink.selected : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(model.section == s ? .isSelected : [])
                .keyboardShortcut(KeyEquivalent(Character("\(AppModel.Section.allCases.firstIndex(of: s)! + 1)")), modifiers: .command)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.headline).font(Fonts.sans(11))
                Text("Version \(macxVersion)").font(Fonts.sans(11))
            }
            .foregroundStyle(Ink.grey)
            .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(width: 212)
        .background(Ink.side)
    }
}

// MARK: Protection

struct ProtectionView: View {
    @Bindable var model: AppModel
    @State private var open: String?

    var headlineColor: Color {
        switch model.state.glyph {
        case .watching: Ink.text
        case .paused: Ink.paused
        case .off: Ink.signal
        }
    }

    var sentence: String {
        switch model.state {
        case .watching(let since):
            "Since \(WatchState.clock(since))\(Calendar.current.isDateInToday(since) ? " today" : "")."
                + (model.freezesOnCritical ? " A critical alert freezes the program behind it." : "")
        case .paused: "Alerts are still logged. Notifications and freezing are off until then."
        case .starting: "The background watch is starting eslogger."
        case .refused(let message): String(message.split(separator: "\n").first ?? "It was refused.")
        case .notRunning: "The background watch is installed but stopped."
        case .notInstalled: "Nothing is watching in the background. Install the watch to get alerts."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(label: "Protection", headline: model.state.headline, sentence: sentence, headlineColor: headlineColor) {
                switch model.state {
                case .watching, .starting:
                    Button("Pause for 1 hour…") { model.pause() }.buttonStyle(PlainButtonStyle())
                case .paused:
                    Button("Resume…") { model.resume() }.buttonStyle(PlainButtonStyle(kind: .primary))
                case .notRunning, .refused:
                    Button("Restart…") { model.restart() }.buttonStyle(PlainButtonStyle(kind: .primary))
                case .notInstalled:
                    Button("Install…") { model.install(suspend: true) }.buttonStyle(PlainButtonStyle(kind: .primary))
                }
            }
            .disabled(model.busy)
            facts
            Hairline()
            table
        }
        .onAppear { model.markSeen() }
    }

    var facts: some View {
        let today = model.today
        let critical = today.filter { $0.severity == .critical }.count
        return HStack(spacing: 28) {
            fact("\(today.count)", "alerts today")
            fact("\(model.groups.count)", "groups this week")
            HStack(spacing: 4) {
                Text("\(critical)").foregroundStyle(critical > 0 ? Ink.signal : Ink.text)
                Text("critical today")
            }
            if let last = today.last { fact(WatchState.clock(last.time), "last", reversed: true) }
            Spacer()
            HStack(spacing: 6) {
                Text("Show:")
                filterButton("critical and high", on: model.seriousOnly) { model.seriousOnly = true }
                Text("·")
                filterButton("all", on: !model.seriousOnly) { model.seriousOnly = false }
            }
        }
        .font(Fonts.mono(11.5)).foregroundStyle(Ink.grey)
        .padding(.horizontal, 48).padding(.vertical, 14)
    }

    func fact(_ value: String, _ label: String, reversed: Bool = false) -> some View {
        HStack(spacing: 4) {
            if reversed { Text(label) }
            Text(value).foregroundStyle(Ink.text)
            if !reversed { Text(label) }
        }
    }

    func filterButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(on ? Ink.text : Ink.grey).underline(on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    static let columns: [GridItem] = []

    var table: some View {
        let groups = model.visibleGroups
        return VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text("Severity").frame(width: 96, alignment: .leading)
                Text("What happened").frame(maxWidth: .infinity, alignment: .leading)
                Text("Rule").frame(width: 170, alignment: .leading)
                Text("Times").frame(width: 56, alignment: .trailing)
                Text("Last").frame(width: 84, alignment: .trailing)
            }
            .font(Fonts.sans(11.5, .medium).lowercaseSmallCaps()).tracking(1.3).foregroundStyle(Ink.grey)
            .padding(.horizontal, 48).padding(.top, 12).padding(.bottom, 8)
            Hairline().padding(.horizontal, 48)
            if groups.isEmpty {
                Text(model.seriousOnly ? "No critical or high alerts in the last 7 days." : "No alerts in the last 7 days.")
                    .font(Fonts.sans(14)).foregroundStyle(Ink.grey)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48).padding(.vertical, 24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { g in row(g) }
                    }
                }
            }
        }
    }

    func row(_ g: AlertGroup) -> some View {
        let isOpen = open == g.key
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                open = isOpen ? nil : g.key
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    SeverityWord(severity: g.severity).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.latest.title).font(Fonts.sans(13.5)).lineLimit(1)
                        Text(
                            g.process.isEmpty
                                ? "unknown program"
                                : Self.short(g.process) + (WatchAlert.isSystemPath(g.process) ? "  · part of macOS" : "")
                        )
                        .font(Fonts.mono(11)).foregroundStyle(Ink.grey).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(g.rule).font(Fonts.mono(11)).foregroundStyle(Ink.grey).lineLimit(1).frame(width: 170, alignment: .leading)
                    Text("\(g.count)").font(Fonts.mono(12)).frame(width: 56, alignment: .trailing)
                    Text(Self.when(g.last)).font(Fonts.mono(12)).lineLimit(1).frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(SeverityWord.word(g.severity)): \(g.latest.title), \(g.count) times")
            if isOpen { detail(g) }
        }
        .padding(.horizontal, 48)
        .background(isOpen ? Ink.rowOpen : Color.clear)
        .background(alignment: .bottom) { Hairline().padding(.horizontal, 48) }
        .zIndex(isOpen ? 1 : 0)
    }

    func detail(_ g: AlertGroup) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Color.clear.frame(width: 96, height: 1)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(g.latest.detail.split(separator: "\n").prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(String(line)).lineLimit(3)
                    }
                    Text("program  \(g.process.isEmpty ? "unknown" : g.process)").foregroundStyle(Ink.grey)
                    if WatchAlert.isSystemPath(g.process) {
                        // Never send people after /bin/zsh or dscl: the command they ran is what matters.
                        Text("         \(WatchAlert.systemProgramNote)").foregroundStyle(Ink.grey)
                    }
                    Text(
                        "seen     \(g.count == 1 ? "once" : "\(g.count) times"), first \(WatchState.clock(g.first)), last \(WatchState.clock(g.last))"
                    )
                    .foregroundStyle(Ink.grey)
                }
                .font(Fonts.mono(11.5)).textSelection(.enabled)
                HStack(spacing: 8) {
                    if g.severity == .critical {
                        Button("Incident cases") {
                            NSWorkspace.shared.open(IncidentRecorder.defaultRoot)
                        }
                        .buttonStyle(PlainButtonStyle(kind: .primary))
                    }
                    if !g.process.isEmpty, !WatchAlert.isSystemPath(g.process), FileManager.default.fileExists(atPath: g.process) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.process)])
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Button("Copy details") {
                        let text = "\(g.latest.title) [\(g.rule)]\n\(g.process)\n\(g.latest.detail)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(PlainButtonStyle())
                    if AlertGroups.canMarkExpected(g) {
                        Button("Expected") { model.markExpected(g) }.buttonStyle(PlainButtonStyle())
                        InfoButton(
                            text: "Hides this program's \(g.rule) alerts here. The background watch still logs them and still notifies you."
                        )
                    } else {
                        InfoButton(
                            text:
                                "Critical alerts can't be marked as expected. A stealer could use that to hide itself, so each one always shows."
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 18)
    }

    /// Short times for the table: 23:47 today, Mon 23:47 this week, 17 Nov before that.
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: d)
    }

    /// Home folder shown as ~ (the public screenshots never carry an account name).
    static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var update = UpdateState.load()
    @State private var checking = false
    @State private var updateNote: String?

    var allSet: Bool { model.fullDiskAccess && model.installed && model.state.glyph != .off }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(label: "Settings", headline: allSet ? "Everything is set up." : "Something needs setting up.") {}
            ScrollView {
                VStack(spacing: 0) {
                    section("Full Disk Access") {
                        HStack(spacing: 4) {
                            Text(model.fullDiskAccess ? "On for Macximesed.app." : "Off.").font(Fonts.sans(14))
                            InfoButton(
                                text: model.fullDiskAccess
                                    ? "The watch and the cleanup need it. It stays on across updates because the signature doesn’t change."
                                    : "Open Settings, press +, choose Macximesed in your home folder's Applications, and switch it on. On macOS 27.3 and later give it full access, not specific folders.",
                                detail: "dev.macximesed.macx · Macximesed Local Signing")
                            Spacer()
                            if !model.fullDiskAccess {
                                Button("Open Settings") {
                                    NSWorkspace.shared.open(
                                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                                }
                                .buttonStyle(PlainButtonStyle(kind: .primary))
                            }
                        }
                    }
                    Hairline()
                    section("Background watch") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 4) {
                                Text(watchSentence).font(Fonts.sans(14))
                                InfoButton(
                                    text: "Install, Restart and Uninstall each ask for your administrator password.",
                                    detail: DaemonPlan.plistPath.path + (model.pid.map { " · pid \($0)" } ?? ""))
                            }
                            HStack(spacing: 8) {
                                if model.installed {
                                    Button("Restart…") { model.restart() }.buttonStyle(PlainButtonStyle())
                                    Button("Uninstall…") { model.uninstall() }.buttonStyle(PlainButtonStyle(kind: .danger))
                                } else {
                                    Button("Install…") { model.install(suspend: true) }.buttonStyle(PlainButtonStyle(kind: .primary))
                                }
                            }
                            .disabled(model.busy)
                            if model.installed {
                                HStack {
                                    Text("Freeze the program behind a critical alert")
                                    Spacer()
                                    TwoState(label: "Freeze on critical", isOn: model.freezesOnCritical) { on in
                                        if on != model.freezesOnCritical { model.install(suspend: on) }
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }
                    }
                    Hairline()
                    section("Updates") {
                        HStack(spacing: 4) {
                            Text(updateNote ?? "Version \(macxVersion).").font(Fonts.sans(14))
                            InfoButton(
                                text: (update.lastCheck.map {
                                    "Checked \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())) on the signed channel. "
                                } ?? "")
                                    + "Every update is checked against the Ed25519 key built into the app before it installs.")
                            Spacer()
                            Button(checking ? "Checking…" : "Check now") { checkUpdates() }
                                .buttonStyle(PlainButtonStyle()).disabled(checking)
                        }
                    }
                    Hairline()
                    section("This app") {
                        // One row per setting: `section` lays its content out in an HStack, so two rows need a VStack.
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Open in the menu bar at login").font(Fonts.sans(14))
                                Spacer()
                                TwoState(label: "Open at login", isOn: loginItem) { on in setLogin(on) }
                            }
                            HStack {
                                Text("The first-run setup").font(Fonts.sans(14))
                                Spacer()
                                Button("Run setup again") { model.runSetup?() }.buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
            }
        }
    }

    var watchSentence: String {
        switch model.state {
        case .watching(let since): "Installed, watching since \(WatchState.clock(since))."
        case .paused(let until): "Installed, paused until \(WatchState.clock(until))."
        case .starting: "Installed, starting."
        case .refused: "Installed, but eslogger was refused."
        case .notRunning: "Installed, not running."
        case .notInstalled: "Not installed."
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 32) {
            SectionLabel(text: title).frame(width: 200, alignment: .leading).padding(.top, 3)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 22)
        .zIndex(1)
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.adminError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func checkUpdates() {
        checking = true
        let exe = AppModel.executable
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["update", "--check"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var out = ""
            if (try? p.run()) != nil {
                out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
            }
            let first = out.split(separator: "\n").first.map(String.init) ?? "Couldn't check."
            await MainActor.run {
                checking = false
                updateNote = first
                update = UpdateState.load()
            }
        }
    }
}
