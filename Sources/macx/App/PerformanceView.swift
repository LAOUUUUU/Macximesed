import AppKit
import MacxCore
import SwiftUI

/// Performance: what's using the Mac and whether it's throttling, Boost, the reversible tweaks, and games.
/// Every action runs the app's own `macx` (the same code as `macx top`, `boost`, `tune` and `games`).
struct PerformanceView: View {
    @Bindable var model: AppModel
    @State private var uses: [CPUUse] = []
    @State private var level = ThermalLevel.current
    @State private var pressure = ThermalPressure.current()
    @State private var memory = MemoryState.current()
    @State private var allUses: [CPUUse] = []
    @State private var byMemory = false
    @State private var boostOn = TweakLedger.load(at: Boost.defaultLedger) != nil
    @State private var applied = Set(Tune.applied())
    @State private var games: [GameEntry]?
    @State private var busy: String?
    @State private var note: String?
    @State private var hooks = GameHooks.load()
    @State private var jitter: String?
    @State private var socdPermitted = SOCDController.permitted

    /// Serious or critical: macOS is slowing the chip down to cool it.
    var hot: Bool { level == .serious || level == .critical }

    var headline: String {
        switch level {
        case .nominal: "Running cool."
        case .fair: "Warm."
        case .serious: "Throttling."
        case .critical: "Throttling hard."
        }
    }

    var sentence: String {
        let total = uses.reduce(0) { $0 + $1.cpuPercent }
        var s = "CPU \(Int(total))% across all cores (100% = one core)."
        if let p = pressure { s += " Heat: \(p.label)." }
        if hot { s += " macOS is slowing the chip down to cool it: less load or a cooler spot helps." }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { s += " Low Power Mode is on, which caps the CPU." }
        if let m = memory {
            s += " \(m.pressure.label)"
            s += m.swapUsedBytes > 0 ? ", \(formatMemory(m.swapUsedBytes)) swapped to disk." : "."
            if m.pressure != .normal { s += " Quitting the biggest memory users below will help more than Boost." }
        }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(label: "Performance", headline: headline, sentence: sentence, headlineColor: hot ? Ink.signal : Ink.text) {
                if boostOn {
                    Button("Boost off") { boostOff() }.buttonStyle(PlainButtonStyle(kind: .primary)).disabled(busy != nil)
                } else {
                    Menu {
                        ForEach(Self.runningApps(), id: \.self) { name in
                            Button(name) { boostOn(name) }
                        }
                    } label: {
                        Text("Boost an app…")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(busy != nil)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note { Text(note).font(Fonts.sans(13)).foregroundStyle(Ink.grey).padding(.top, 18).transition(.opacity) }
                    live.reveal(0)
                    tune.reveal(1)
                    whilePlaying.reveal(2)
                    gamesSection.reveal(3)
                }
                .padding(.horizontal, 48).padding(.bottom, 32)
            }
        }
        .motion(value: note)
        .task { await sample() }
        .task { if games == nil { loadGames() } }
    }

    // MARK: Live

    var live: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                "Busiest right now",
                info:
                    "CPU: real time on a core over the last 2 seconds (100% is one core), not Activity Monitor's percentage. Memory: each program's footprint, as Activity Monitor's Memory column."
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    sortButton("CPU", on: !byMemory) { byMemory = false }
                    Text("·").foregroundStyle(Ink.grey)
                    sortButton("Memory", on: byMemory) { byMemory = true }
                }
                .font(Fonts.mono(11.5)).padding(.top, 30)
            }
            if uses.isEmpty && allUses.isEmpty {
                HairlineProgress().padding(.vertical, 14)
            }
            ForEach(Array((byMemory ? CPUUse.byMemory(allUses) : uses).prefix(8).enumerated()), id: \.element.pid) { i, u in
                HStack(spacing: 20) {
                    Text((u.path as NSString).lastPathComponent).font(Fonts.sans(13.5)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if getpriority(PRIO_DARWIN_PROCESS, id_t(u.pid)) == PRIO_DARWIN_BG {
                        Text("background").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                    }
                    Text(byMemory ? formatMemory(u.memoryBytes) : "\(Int(u.cpuPercent))%").font(Fonts.mono(12))
                        .frame(width: 84, alignment: .trailing)
                        .contentTransition(.numericText()).motion(value: byMemory ? Int(u.memoryBytes >> 20) : Int(u.cpuPercent))
                }
                .padding(.vertical, 8)
                .background(alignment: .bottom) { Hairline() }
                .reveal(i, rise: 3)
            }
        }
    }

    // MARK: Tune

    var tune: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Lighter macOS", info: "Each one stores the value it replaced; Off puts it back. Nothing here needs your password.")
            ForEach(Tune.catalog, id: \.id) { t in
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(Fonts.sans(13.5))
                        Text(t.why).font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                    }
                    Spacer()
                    TwoState(label: t.title, isOn: applied.contains(t.id)) { on in setTweak(t.id, on: on) }
                        .disabled(busy != nil)
                }
                .padding(.vertical, 9)
                .background(alignment: .bottom) { Hairline() }
            }
        }
    }

    // MARK: Games

    var gamesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                "Games",
                info:
                    "Play turns Boost on, starts the game, records heat and load while you play, and turns Boost off when it quits. Game Mode turns on by itself when a supported game goes full screen."
            )
            if let games {
                if games.isEmpty {
                    Text("No games found. Add one in Terminal: macx games add PATH").font(Fonts.sans(13)).foregroundStyle(Ink.grey)
                        .padding(.vertical, 12)
                }
                ForEach(Array(games.enumerated()), id: \.element.url) { i, g in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(Fonts.sans(13.5))
                            Text(g.advice).font(Fonts.sans(12)).foregroundStyle(Ink.grey).lineLimit(2)
                        }
                        Spacer()
                        if let id = g.bundleID {
                            HStack(spacing: 6) {
                                Text("SOCD").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                                TwoState(label: "SOCD for \(g.name)", isOn: hooks.socdApps.contains(id)) { on in
                                    save { h in
                                        h.socdApps.removeAll { $0 == id }
                                        if on { h.socdApps.append(id) }
                                    }
                                }
                            }
                        }
                        Button("Play") { play(g) }.buttonStyle(PlainButtonStyle()).disabled(busy != nil)
                    }
                    .padding(.vertical, 10)
                    .background(alignment: .bottom) { Hairline() }
                    .reveal(i, rise: 3)
                }
            } else {
                HairlineProgress().padding(.vertical, 14)
            }
        }
    }

    // MARK: While playing

    var whilePlaying: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                "While playing", info: "For games started with Play (here or macx games play). Everything is put back when the game quits.")
            row(
                "No mouse acceleration",
                "Your mouse moves the same distance however fast you move it. The trackpad is left as it is.",
                on: hooks.rawMouse
            ) { on in save { $0.rawMouse = on } }
            row(
                "Game network",
                "Turns off AirDrop's radio (AWDL), which stalls Wi-Fi for about 90 ms every second or two. AirDrop and AirPlay are off until the game quits. Needs the background watch.",
                on: hooks.gameNetwork
            ) { on in save { $0.gameNetwork = on } }
            HStack(spacing: 10) {
                Button(busy == "jitter" ? "Measuring…" : "Measure Wi-Fi lag") { measureJitter() }.buttonStyle(PlainButtonStyle())
                    .disabled(busy != nil)
                if let jitter { Text(jitter).font(Fonts.mono(11.5)).foregroundStyle(Ink.grey).transition(.opacity) }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Do Not Disturb").font(Fonts.sans(13.5))
                    Text("Shortcuts to run when a game starts and ends (make them in the Shortcuts app with Set Focus).")
                        .font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                }
                Spacer()
                TextField("Start shortcut", text: binding(\.focusStart)).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("End shortcut", text: binding(\.focusEnd)).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("SOCD (snap tap)").font(Fonts.sans(13.5))
                    InfoButton(
                        text:
                            "Of A and D (or W and S) held together, the game only sees the one pressed last. Switch it on per game below. CS2 kicks players for it on official servers and ESL bans it, so only use it where it's allowed. Macximesed sees your key presses only while that game is in front, and keeps nothing."
                    )
                }
                if socdPermitted {
                    Text("Allowed. It's active only while a game you switched it on for is in front.").font(Fonts.sans(12)).foregroundStyle(
                        Ink.grey)
                } else {
                    HStack(spacing: 10) {
                        Text("Needs Input Monitoring and Accessibility for Macximesed.").font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                        Button("Allow…") {
                            SOCDController.requestPermissions()
                            Task {
                                try? await Task.sleep(for: .seconds(3))
                                socdPermitted = SOCDController.permitted
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
        }
    }

    func row(_ title: String, _ why: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.sans(13.5))
                Text(why).font(Fonts.sans(12)).foregroundStyle(Ink.grey).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            TwoState(label: title, isOn: on, set: set)
        }
        .padding(.vertical, 9)
        .background(alignment: .bottom) { Hairline() }
    }

    func save(_ change: (inout GameHooks) -> Void) {
        change(&hooks)
        try? hooks.save()
        SOCDController.shared.update()
    }

    func binding(_ key: WritableKeyPath<GameHooks, String?>) -> Binding<String> {
        Binding(get: { hooks[keyPath: key] ?? "" }, set: { v in save { $0[keyPath: key] = v.isEmpty ? nil : v } })
    }

    func measureJitter() {
        busy = "jitter"
        let job = model.begin("Measuring Wi-Fi lag", "30 pings to your router")
        Task.detached {
            let j = Jitter.measure()
            await MainActor.run {
                busy = nil
                let text = j.map { String(format: "average %.0f ms, worst %.0f ms, %.0f%% lost", $0.average, $0.worst, $0.lossPercent) }
                Motion.animate { jitter = text ?? "Couldn't reach your router." }
                model.end(job, "Wi-Fi lag: " + (text ?? "couldn't measure"))
            }
        }
    }

    func sortButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Motion.animate { action() }
        } label: {
            Text(title).foregroundStyle(on ? Ink.text : Ink.grey).underline(on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func header(_ title: String, info: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SectionLabel(text: title)
                InfoButton(text: info)
                Spacer()
            }
            .padding(.top, 28).padding(.bottom, 6)
            Hairline(color: Ink.text)
        }
    }

    // MARK: Actions

    /// Every 2 s while the page is open: CPU time per process, and the thermal state.
    func sample() async {
        while !Task.isCancelled {
            let before = CPUSampler.snapshot()
            let started = Date()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let found = CPUSampler.uses(before: before, after: CPUSampler.snapshot(), interval: Date().timeIntervalSince(started))
            Motion.animate {
                uses = found.filter { $0.cpuPercent >= 0.5 }
                level = .current
                pressure = ThermalPressure.current()
                memory = MemoryState.current()
                allUses = found
                boostOn = TweakLedger.load(at: Boost.defaultLedger) != nil
            }
        }
    }

    func run(_ title: String, _ args: [String], then done: @escaping (Int32, String) -> Void = { _, _ in }) {
        busy = title
        let job = model.begin(title)
        Task {
            let (code, out) = await AppModel.runMacx(args)
            busy = nil
            model.end(job, code == 0 ? title.replacingOccurrences(of: "…", with: "") + ": done" : title + ": didn't work")
            if code != 0 { Motion.animate { note = out.split(separator: "\n").last.map(String.init) ?? "It didn't work." } }
            done(code, out)
        }
    }

    func boostOn(_ app: String) {
        run("Boosting \(app)", ["boost", "on", "--app", app]) { _, _ in
            boostOn = TweakLedger.load(at: Boost.defaultLedger) != nil
        }
    }

    func boostOff() {
        run("Turning Boost off", ["boost", "off"]) { _, _ in boostOn = TweakLedger.load(at: Boost.defaultLedger) != nil }
    }

    func setTweak(_ id: String, on: Bool) {
        run(on ? "Turning on \(id)" : "Putting back \(id)", ["tune", on ? "apply" : "undo", id]) { _, _ in
            Motion.animate { applied = Set(Tune.applied()) }
        }
    }

    func loadGames() {
        let job = model.begin("Finding games", "App Store category, Steam, CrossOver bottles, launchers")
        Task.detached(priority: .userInitiated) {
            let found = GameScanner.standard().scan()
            await MainActor.run {
                Motion.animate(Motion.settle) { games = found }
                model.end(job, "\(found.count) games found")
            }
        }
    }

    /// `macx games play` waits for the game to quit, so it runs on its own; the status bar shows it until then.
    func play(_ g: GameEntry) {
        let job = model.begin("Playing \(g.name) with Boost", "heat and load are being recorded")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: AppModel.executable)
        p.arguments = ["games", "play", g.name]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in Task { @MainActor in model.end(job, "Finished playing \(g.name); Boost is off") } }
        do { try p.run() } catch { model.end(job, "Couldn't start \(g.name)") }
    }

    /// Apps you could boost: regular apps that are running, except this one.
    static func runningApps() -> [String] {
        let mine = Bundle.main.bundleIdentifier
        return Array(
            Set(
                NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != mine }
                    .compactMap(\.localizedName))
        ).sorted()
    }
}
