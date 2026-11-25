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
            ZStack(alignment: .topLeading) {
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
                .id(model.section)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            .motion(Motion.page, value: model.section)
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(Motion.settle, value: model.adminError)
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel
    @Namespace private var selection

    func count(_ s: AppModel.Section) -> String {
        switch s {
        case .protection: model.unreadCritical > 0 ? "\(model.unreadCritical)" : ""
        case .startup: model.startupCount.map(String.init) ?? ""
        case .clean: model.cleanBytes.map(formatBytes) ?? ""
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
                            .contentTransition(.numericText())
                            .motion(value: count(s))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background {
                        if model.section == s {
                            HStack(spacing: 0) {
                                Rectangle().fill(Ink.text).frame(width: 2)
                                Ink.selected
                            }
                            .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowHover())
                .focusEffectDisabled()
                .accessibilityAddTraits(model.section == s ? .isSelected : [])
                .keyboardShortcut(KeyEquivalent(Character("\(AppModel.Section.allCases.firstIndex(of: s)! + 1)")), modifiers: .command)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if model.state.glyph == .watching { LiveMark(size: 5) }
                    Text(model.state.headline).font(Fonts.sans(11)).contentTransition(.opacity).motion(value: model.state.headline)
                }
                Text("Version \(BuildVersion.current.description)").font(Fonts.sans(11))
            }
            .foregroundStyle(Ink.grey)
            .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(width: 212)
        .background(Ink.side)
        .motion(Motion.settle, value: model.section)
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
                if model.state.glyph == .watching {
                    HStack(spacing: 7) {
                        LiveMark()
                        Text("live").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                    }
                    .padding(.trailing, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Watching live")
                }
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
                    .contentTransition(.numericText()).motion(value: critical)
                Text("critical today")
            }
            if let last = today.last { fact(WatchState.clock(last.time), "last", reversed: true) }
            Spacer()
            HStack(spacing: 6) {
                Text("Show:")
                filterButton("critical and high", on: model.seriousOnly) { Motion.animate { model.seriousOnly = true } }
                Text("·")
                filterButton("all", on: !model.seriousOnly) { Motion.animate { model.seriousOnly = false } }
            }
        }
        .font(Fonts.mono(11.5)).foregroundStyle(Ink.grey)
        .padding(.horizontal, 48).padding(.vertical, 14)
    }

    func fact(_ value: String, _ label: String, reversed: Bool = false) -> some View {
        HStack(spacing: 4) {
            if reversed { Text(label) }
            Text(value).foregroundStyle(Ink.text).contentTransition(.numericText()).motion(value: value)
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
                    .reveal()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in row(g).reveal(i) }
                    }
                }
            }
        }
    }

    func row(_ g: AlertGroup) -> some View {
        let isOpen = open == g.key
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Motion.animate(Motion.settle) { open = isOpen ? nil : g.key }
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
            if isOpen { detail(g).transition(.opacity.combined(with: .offset(y: -4))) }
        }
        .padding(.horizontal, 48)
        .background(isOpen ? Ink.rowOpen : Color.clear)
        .modifier(HoverFill(active: !isOpen))
        .background(alignment: .bottom) { Hairline().padding(.horizontal, 48) }
        .clipped()
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
    @State private var busy: UpdateBusy?
    @State private var report: UpdateReport?

    var allSet: Bool { model.fullDiskAccess && model.installed && model.state.glyph != .off }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(label: "Settings", headline: allSet ? "Everything is set up." : "Something needs setting up.") {}
            ScrollView {
                VStack(spacing: 0) {
                    section("Full Disk Access", 0) {
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
                    section("Background watch", 1) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 4) {
                                Text(watchSentence).font(Fonts.sans(14))
                                InfoButton(
                                    text:
                                        "Install, Restart, Uninstall and the two switches below each ask for your administrator password.",
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
                                .disabled(model.busy)
                                HStack(spacing: 4) {
                                    Text("Check finished downloads in ~/Downloads")
                                    InfoButton(
                                        text:
                                            "A download judged DON'T OPEN THIS is quarantined into an incident case and the undo folder. The switch is kept where only root can change it, so nothing running as you can turn it off.",
                                        detail: "sudo macx daemon downloads on|off")
                                    Spacer()
                                    TwoState(label: "Downloads watch", isOn: model.downloadsWatched) { on in
                                        if on != model.downloadsWatched { model.setDownloads(on) }
                                    }
                                }
                                .disabled(model.busy)
                            }
                        }
                    }
                    Hairline()
                    section("Updates", 2) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 4) {
                                Text(updateSentence).font(Fonts.sans(14))
                                    .foregroundStyle(isUrgent ? Ink.signal : Ink.text)
                                    .contentTransition(.opacity).motion(value: updateSentence)
                                InfoButton(text: updateInfo)
                                Spacer()
                                if busy != nil { HairlineProgress(width: 90).padding(.trailing, 8).transition(.opacity) }
                                switch report?.status {
                                case .available(let v), .urgent(let v, _):
                                    Button(busy == .installing ? "Installing…" : "Install \(v)") { runUpdate(install: true) }
                                        .buttonStyle(PlainButtonStyle()).disabled(busy != nil)
                                case .installed:
                                    Button("Restart the app") { relaunch() }.buttonStyle(PlainButtonStyle())
                                default:
                                    Button(busy == .checking ? "Checking…" : "Check now") { runUpdate(install: false) }
                                        .buttonStyle(PlainButtonStyle()).disabled(busy != nil)
                                }
                            }
                            HStack(spacing: 4) {
                                Text("Get beta builds").font(Fonts.sans(14))
                                InfoButton(text: betaInfo, detail: "macx update --channel beta|stable")
                                Spacer()
                                TwoState(label: "Beta builds", isOn: update.channel == .beta) { on in setChannel(on ? .beta : .stable) }
                            }
                            .disabled(UpdateKeys.beta.isEmpty && update.channel == .stable)
                        }
                        .motion(value: busy)
                    }
                    Hairline()
                    section("Problems", 3) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Ask after macx crashes").font(Fonts.sans(14))
                                InfoButton(
                                    text: "The app opens a report about the crash for you to look at. It's only sent if you press Send.")
                                Spacer()
                                TwoState(label: "Ask after a crash", isOn: model.askAfterCrash) { model.setAskAfterCrash($0) }
                            }
                            if model.reportOpen {
                                ReportPanel(model: model)
                            } else {
                                HStack {
                                    Text("Something not working?").font(Fonts.sans(14))
                                    Spacer()
                                    Button("Report a problem…") { model.reportOpen = true }.buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }
                    Hairline()
                    section("This app", 4) {
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

    func section<Content: View>(_ title: String, _ order: Int = 0, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 32) {
            SectionLabel(text: title).frame(width: 200, alignment: .leading).padding(.top, 3)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 22)
        .reveal(order)
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

    enum UpdateBusy { case checking, installing }

    var isUrgent: Bool {
        if case .urgent = report?.status { return true }
        return false
    }

    var updateSentence: String {
        switch report?.status {
        case nil: "Version \(BuildVersion.current)."
        case .upToDate: "Version \(BuildVersion.current), up to date."
        case .available(let v): "Version \(v) is out. You have \(BuildVersion.current)."
        case .urgent(let v, _): "Version \(BuildVersion.current) has a security problem. Install \(v)."
        case .installed(let v): "Updated to \(v). Restart the app to use it."
        case .failed(let why): why
        }
    }

    var updateInfo: String {
        var parts: [String] = []
        if case .urgent(_, let reason) = report?.status { parts.append("The problem: \(reason)") }
        if let last = update.lastCheck {
            parts.append("Checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())) on the signed channel.")
        }
        if let feed = report?.feed { parts.append(feed) }
        parts += report?.warnings ?? []
        parts.append(
            "Every update is checked against the Ed25519 key built into the app before it installs. "
                + "The old version is kept, Full Disk Access stays on, and the background watch restarts on the new version by itself.")
        return parts.joined(separator: " ")
    }

    var betaInfo: String {
        if UpdateKeys.beta.isEmpty && update.channel == .stable {
            return "Not open yet: beta builds need their own signing key, which hasn't been set up."
        }
        return "A build of every change, named by its commit, signed with its own key and published without a person checking each one. "
            + "Security updates from the stable channel still apply. Switching back keeps the beta build until the next release replaces it."
    }

    func setChannel(_ new: ReleaseChannel) {
        var s = UpdateState.load()
        do {
            try s.switchChannel(to: new)
            try s.save()
        } catch {
            model.adminError = "Couldn't switch the update channel: \(error)"
        }
        update = UpdateState.load()
        report = nil
    }

    /// Runs the app's own `macx update` (one code path with the CLI); with `install` it downloads and installs.
    func runUpdate(install: Bool) {
        busy = install ? .installing : .checking
        let exe = AppModel.executable
        Task.detached {
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
            let result = UpdateReport.parse(out, exitCode: code)
            await MainActor.run {
                busy = nil
                report = result
                update = UpdateState.load()
            }
        }
    }

    /// The new binary is already in the bundle; open the app again once this copy has quit.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// A soft fill under a row while the pointer is over it.
struct HoverFill: ViewModifier {
    var active = true
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .background(active && over ? Ink.rowOpen.opacity(0.6) : Color.clear)
            .motion(Motion.quick, value: over)
            .onHover { over = $0 }
    }
}
