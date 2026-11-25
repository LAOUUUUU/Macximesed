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
    @State private var boostOn = TweakLedger.load(at: Boost.defaultLedger) != nil
    @State private var applied = Set(Tune.applied())
    @State private var games: [GameEntry]?
    @State private var busy: String?
    @State private var note: String?

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
                    gamesSection.reveal(2)
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
            header("Busiest right now", info: "Real CPU time over the last 2 seconds, not Activity Monitor's percentage. 100% is one core.")
            if uses.isEmpty {
                HairlineProgress().padding(.vertical, 14)
            }
            ForEach(Array(uses.prefix(8).enumerated()), id: \.element.pid) { i, u in
                HStack(spacing: 20) {
                    Text((u.path as NSString).lastPathComponent).font(Fonts.sans(13.5)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if getpriority(PRIO_DARWIN_PROCESS, id_t(u.pid)) == PRIO_DARWIN_BG {
                        Text("background").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                    }
                    Text("\(Int(u.cpuPercent))%").font(Fonts.mono(12)).frame(width: 64, alignment: .trailing)
                        .contentTransition(.numericText()).motion(value: Int(u.cpuPercent))
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
