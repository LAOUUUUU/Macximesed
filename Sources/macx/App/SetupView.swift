import AppKit
import Combine
import MacxCore
import ServiceManagement
import SwiftUI

/// The first-run setup (research/app-onboarding/RESEARCH.md): welcome, Full Disk Access, the background watch,
/// notifications, extras, ready. Every check is live; every step can be skipped and redone from Settings.
struct SetupView: View {
    @Bindable var model: AppModel
    let finish: () -> Void

    @State private var step = 0
    @State private var forward = true
    @State private var freeze = true
    @State private var login = true
    @State private var chamber = false
    @State private var updates = true
    @State private var updateNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var facts: SetupFacts { SetupFacts(fullDiskAccess: model.fullDiskAccess, watch: model.state, notifications: model.notifications) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                screen
                    .id(step)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
                                removal: .identity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 56).padding(.top, 56)
            footer
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(Ink.paper)
        .foregroundStyle(Ink.text)
        .font(Fonts.sans(13))
        .monospacedDigit()
        .ignoresSafeArea()
        .onReceive(ticker) { _ in model.refresh() }
        .onAppear {
            model.readNotificationStatus()
        }
    }

    @ViewBuilder var screen: some View {
        switch step {
        case 0: WelcomeScreen()
        case 1: fullDiskAccess
        case 2: watch
        case 3: notifications
        case 4: extras
        default: ready
        }
    }

    func go(_ to: Int) {
        forward = to > step
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.3)) { step = to }
    }

    // MARK: Steps

    var fullDiskAccess: some View {
        StepPage(
            label: "1 of 4 · Full Disk Access", headline: "Let it see the whole Mac.",
            reason: "The watch is built on Apple's eslogger, which only runs with Full Disk Access. It's used to watch, never to upload."
        ) {
            LiveCheck(
                state: facts.isDone(.fullDiskAccess) ? .done : .waiting,
                word: facts.isDone(.fullDiskAccess) ? "On. The watch can start." : "Off. This page notices when you switch it on.",
                trailing: "checks every second")
            if !facts.isDone(.fullDiskAccess) {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("1.  Open Settings.")
                        Text("2.  Press +, then choose Macximesed in Applications in your home folder.")
                        Text("3.  Switch it on.")
                        HStack(spacing: 4) {
                            Text("Switched on but still off here?").foregroundStyle(Ink.grey)
                            InfoButton(
                                text:
                                    "macOS keeps the signature an app had when it was first added. Remove Macximesed with −, add it again with +. On macOS 27.3 and later, choose full access, not specific folders: eslogger needs all of it."
                            )
                        }
                        .padding(.top, 6)
                    }
                    .font(Fonts.sans(13.5))
                    Spacer()
                    AppDragHandle()
                }
                .padding(.top, 22)
            }
        }
    }

    var watch: some View {
        StepPage(
            label: "2 of 4 · Background watch", headline: "Watch in the background.",
            reason:
                "A small service starts with your Mac and watches for pasted commands, fake password prompts and hidden launch items. About 1% CPU."
        ) {
            LiveCheck(state: watchCheck, word: watchWord)
            HStack {
                Text("Freeze the program behind a critical alert")
                Spacer()
                // Installed already: this is the real setting, and changing it reinstalls (password).
                TwoState(label: "Freeze on critical", isOn: model.installed ? model.freezesOnCritical : freeze) { on in
                    if model.installed {
                        if on != model.freezesOnCritical { model.install(suspend: on) }
                    } else {
                        freeze = on
                    }
                }
            }
            .padding(.vertical, 14)
            .background(alignment: .bottom) { Hairline() }
            if facts.watchNeedsFullDiskAccess {
                HStack(spacing: 12) {
                    Text("eslogger was refused. Full Disk Access needs doing first.").foregroundStyle(Ink.signal)
                    Button("Back to Full Disk Access") { go(1) }.buttonStyle(PlainButtonStyle())
                }
                .padding(.top, 14)
            }
        }
    }

    var watchCheck: LiveCheck.State {
        if facts.isDone(.watch) { return .done }
        if case .starting = model.state, model.installed { return .waiting }
        return model.busy ? .waiting : .idle
    }

    var watchWord: String {
        switch model.state {
        case .watching: "Watching."
        case .paused: "Installed, paused."
        case .starting: model.installed ? "Starting eslogger…" : "Not installed."
        case .refused: "Installed, but eslogger was refused."
        case .notRunning: "Installed, not running."
        case .notInstalled: model.busy ? "Waiting for your password…" : "Not installed."
        }
    }

    var notifications: some View {
        StepPage(
            label: "3 of 4 · Notifications", headline: "Tell you when it sees something.",
            reason: "Only high and critical alerts, at most one every 10 seconds. Everything else waits in the app."
        ) {
            LiveCheck(
                state: facts.isDone(.notifications) ? .done : .idle,
                word: notificationWord)
        }
    }

    var notificationWord: String {
        switch model.notifications {
        case .allowed: "Allowed."
        case .denied: "Turned off in System Settings."
        case .notAsked: "Not allowed yet."
        }
    }

    var extras: some View {
        StepPage(label: "4 of 4 · Extras", headline: "A few extras.", reason: "All of these can change later in Settings.") {
            VStack(spacing: 0) {
                Hairline()
                extraRow("Open in the menu bar at login", "your login items", isOn: login) { login = $0 }
                extraRow(
                    "Detonation chamber",
                    model.chamber == .ready ? "already set up" : "downloads 50 MB from Alpine Linux",
                    isOn: chamber || model.chamber == .ready,
                    info: "Runs a suspicious script in a tiny throwaway Linux machine with no network, and judges what it tried."
                ) { chamber = $0 }
                .disabled(model.chamber == .ready)
                extraRow("Check for updates and the hash feed now", "signed channel on GitHub Pages", isOn: updates) { updates = $0 }
            }
        }
    }

    func extraRow(_ label: String, _ note: String, isOn: Bool, info: String? = nil, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label).font(Fonts.sans(13.5))
                    if let info { InfoButton(text: info) }
                }
                Text(note).font(Fonts.mono(11)).foregroundStyle(Ink.grey)
            }
            Spacer()
            TwoState(label: label, isOn: isOn, set: set)
        }
        .padding(.vertical, 13)
        .background(alignment: .bottom) { Hairline() }
        .zIndex(info == nil ? 0 : 1)
    }

    var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Mark(drawn: true, size: 30)
                Text(facts.isDone(.watch) ? "Watching." : "Ready.").font(Fonts.serif(36)).tracking(-0.4)
            }
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 0) {
                    listHead("Set up")
                    ForEach(Array(summary.enumerated()), id: \.offset) { i, row in
                        listRow(row.0, row.1, mono: true, dim: !row.2, delay: 0.15 + Double(i) * 0.06)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    listHead("What else is in here")
                    ForEach(Array(Self.tour.enumerated()), id: \.offset) { i, row in
                        listRow(row.0, row.1, mono: true, dim: true, delay: 0.45 + Double(i) * 0.06)
                    }
                }
            }
            .padding(.top, 24)
        }
    }

    var summary: [(String, String, Bool)] {
        let chamberWord: String =
            switch model.chamber {
            case .ready: "ready"
            case .settingUp: "downloading"
            case .failed: "failed"
            default: "off"
            }
        return [
            ("Full Disk Access", facts.isDone(.fullDiskAccess) ? "on" : "skipped", facts.isDone(.fullDiskAccess)),
            ("Background watch", facts.isDone(.watch) ? "watching" : "skipped", facts.isDone(.watch)),
            ("Notifications", facts.isDone(.notifications) ? "on" : "skipped", facts.isDone(.notifications)),
            ("Open at login", SMAppService.mainApp.status == .enabled ? "on" : "off", SMAppService.mainApp.status == .enabled),
            ("Chamber", chamberWord, model.chamber == .ready || model.chamber == .settingUp),
            ("Updates", updateNote ?? (updates ? "checking" : "not checked"), updates),
        ]
    }

    static let tour: [(String, String)] = [
        ("Alerts, grouped", "menu bar"), ("Check a file first", "macx check"), ("What's using the Mac", "macx top"),
        ("Boost and Tune", "macx boost"), ("Games", "macx games"), ("Run it in the chamber", "macx chamber run"),
    ]

    func listHead(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: text)
            Hairline(color: Ink.text)
        }
        .frame(maxWidth: .infinity)
    }

    func listRow(_ label: String, _ value: String, mono: Bool, dim: Bool, delay: Double) -> some View {
        Rise(delay: delay) {
            HStack {
                Text(label)
                Spacer()
                Text(value).font(Fonts.mono(11.5)).foregroundStyle(dim ? Ink.grey : Ink.text)
            }
            .padding(.vertical, 8)
            .background(alignment: .bottom) { Hairline() }
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack {
            HStack(spacing: 18) {
                if step > 0 && step < 5 { textButton("Back") { go(step - 1) } }
                if step == 0 { textButton("Skip setup") { finish() } }
                if (1...3).contains(step), !stepDone { textButton("Skip for now") { go(step + 1) } }
            }
            .transaction { $0.animation = nil }
            Spacer()
            if step == 2, !facts.isDone(.watch), !model.installed {
                Text("macOS adds a line saying it couldn't verify the script. That's Apple's, on every script.")
                    .font(Fonts.sans(11.5)).foregroundStyle(Ink.grey).frame(maxWidth: 300, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 12)
            }
            primary.transaction { $0.animation = nil }
        }
        .padding(.horizontal, 56)
        .frame(height: 72)
        .overlay(alignment: .top) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Hairline()
                    Rectangle().fill(Ink.text).frame(width: g.size.width * CGFloat(step) / 5, height: 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: step)
                }
            }
            .frame(height: 2)
        }
    }

    var stepDone: Bool {
        switch step {
        case 1: facts.isDone(.fullDiskAccess)
        case 2: facts.isDone(.watch)
        case 3: facts.isDone(.notifications)
        default: false
        }
    }

    @ViewBuilder var primary: some View {
        switch step {
        case 0: Button("Set it up") { go(1) }.buttonStyle(PlainButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        case 1 where !stepDone:
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(PlainButtonStyle(kind: .primary))
        case 2 where !stepDone && !model.installed:
            Button(model.busy ? "Waiting…" : "Install…") { model.install(suspend: freeze) }
                .buttonStyle(PlainButtonStyle(kind: .primary)).disabled(model.busy)
        case 3 where !stepDone:
            Button(model.notifications == .denied ? "Open Settings" : "Allow…") { model.requestNotifications() }
                .buttonStyle(PlainButtonStyle(kind: .primary))
        case 4: Button("Continue") { applyExtras() }.buttonStyle(PlainButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        case 5: Button("Open Macximesed") { finish() }.buttonStyle(PlainButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        default: Button("Continue") { go(step + 1) }.buttonStyle(PlainButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
    }

    func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).foregroundStyle(Ink.grey) }.buttonStyle(.plain).focusEffectDisabled()
    }

    func applyExtras() {
        if login && SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if !login && SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        if chamber && model.chamber == .notSetUp { model.setUpChamber() }
        if updates {
            let exe = AppModel.executable
            Task.detached {
                let (_, out) = AppModel.runOwn(exe, ["update", "--check"])
                let line = out.split(separator: "\n").first.map(String.init) ?? "checked"
                await MainActor.run { updateNote = line.count > 28 ? "checked" : line }
            }
        }
        go(5)
    }
}

// MARK: Pieces

struct StepPage<Content: View>: View {
    let label: String
    let headline: String
    let reason: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            Text(headline).font(Fonts.serif(32)).tracking(-0.4).padding(.top, 10).accessibilityAddTraits(.isHeader)
            Text(reason).font(Fonts.sans(14)).foregroundStyle(Ink.grey).frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            VStack(alignment: .leading, spacing: 0) { content() }.padding(.top, 26)
        }
    }
}

/// A live check: a small square that breathes while it waits and fills when the check passes.
struct LiveCheck: View {
    enum State { case idle, waiting, done }
    let state: State
    let word: String
    var trailing: String?
    @SwiftUI.State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle().strokeBorder(Ink.text, lineWidth: 1.5)
                Rectangle().fill(Ink.text).opacity(state == .done ? 1 : 0)
            }
            .frame(width: 9, height: 9)
            .opacity(state == .waiting && !reduceMotion ? (breathe ? 1 : 0.4) : 1)
            .animation(.easeOut(duration: 0.25), value: state == .done)
            .onAppear { startBreathing() }
            .onChange(of: state) { startBreathing() }
            Text(word).font(Fonts.sans(14)).contentTransition(.opacity).animation(.easeOut(duration: 0.25), value: word)
            Spacer()
            if let trailing { Text(trailing).font(Fonts.mono(11)).foregroundStyle(Ink.grey) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    func startBreathing() {
        breathe = false
        guard state == .waiting, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathe = true }
    }
}

/// The menu bar mark, large: the outline traces round the square, then the centre fills.
struct Mark: View {
    var drawn = false
    var size: CGFloat = 64
    @State private var trace: CGFloat = 0
    @State private var fill = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = size / 16
        ZStack(alignment: .topLeading) {
            Path(CGRect(x: 2.75 * s, y: 2.75 * s, width: 10.5 * s, height: 10.5 * s))
                .trim(from: 0, to: drawn ? 1 : trace)
                .stroke(Ink.text, lineWidth: max(1.1 * s, 1.5))
            Rectangle().fill(Ink.text).frame(width: 5 * s, height: 5 * s).offset(x: 5.5 * s, y: 5.5 * s)
                .opacity(drawn || fill ? 1 : 0)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
        .onAppear {
            guard !drawn else { return }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) {
                    trace = 1
                    fill = true
                }
                return
            }
            withAnimation(.easeOut(duration: 0.6)) { trace = 1 }
            withAnimation(.easeOut(duration: 0.25).delay(0.6)) { fill = true }
        }
    }
}

/// Fades up 8 pt after a delay (or just fades in, with Reduce Motion).
struct Rise<Content: View>: View {
    let delay: Double
    @ViewBuilder var content: () -> Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(.easeOut(duration: 0.4).delay(reduceMotion ? 0 : delay)) { shown = true } }
    }
}

struct WelcomeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mark().padding(.top, 20)
            Rise(delay: 0.7) {
                Text("Macximesed").font(Fonts.serif(44)).tracking(-0.8).padding(.top, 28)
            }
            Rise(delay: 0.78) {
                Text("It watches for the tricks stealers use, and tells you when it sees one.")
                    .font(Fonts.sans(16)).frame(maxWidth: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            Rise(delay: 0.86) {
                Text("About 2 minutes · nothing leaves your Mac").font(Fonts.mono(11.5)).foregroundStyle(Ink.grey).padding(.top, 18)
            }
        }
    }
}

/// The app itself as a drag source, for dropping into the Full Disk Access list.
struct AppDragHandle: View {
    var body: some View {
        VStack(spacing: 6) {
            Mark(drawn: true, size: 28)
                .frame(width: 64, height: 64)
                .overlay(Rectangle().stroke(Ink.outline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag Macximesed into the Full Disk Access list")
                .accessibilityLabel("Macximesed.app, drag into the Full Disk Access list")
            Text("or drag this in").font(Fonts.sans(11.5)).foregroundStyle(Ink.grey)
        }
    }
}
