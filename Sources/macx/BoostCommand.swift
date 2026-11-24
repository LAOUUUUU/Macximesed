import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Top: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Live view: what's using the CPU, and whether the Mac is getting hot and slowing down.",
        discussion: """
            CPU is real time on a core over the last interval (100% = one core), not Activity Monitor's percentage. Thermal state is macOS's own (Nominal, Fair, Serious, Critical); Serious and Critical mean it's throttling. There's no public way to read temperatures on Apple silicon. "bg" marks processes on background priority. Ctrl-C stops.
            """
    )

    @Flag(help: "Print once and stop.") var once = false
    @Option(help: "Seconds between refreshes.") var interval: Double = 1
    @Option(name: .shortAndLong, help: "How many processes to show.") var count: Int = 12

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard interval >= 0.5 else { throw UserError("--interval must be at least 0.5.") }
        var timeline = HeatTimeline()
        var before = CPUSampler.snapshot()
        var last = Date()
        repeat {
            Thread.sleep(forTimeInterval: interval)
            let now = Date()
            let after = CPUSampler.snapshot()
            let uses = CPUSampler.uses(before: before, after: after, interval: now.timeIntervalSince(last))
            before = after
            last = now
            let level = ThermalLevel.current
            let pressure = ThermalPressure.current()
            timeline.add(
                HeatTimeline.Sample(time: now, level: level, pressure: pressure, cpuPercent: uses.reduce(0) { $0 + $1.cpuPercent }))
            if !once { print("\u{1B}[H\u{1B}[2J", terminator: "") }
            Self.render(uses: uses, level: level, pressure: pressure, timeline: timeline, count: count)
        } while !once
    }

    static func render(uses: [CPUUse], level: ThermalLevel, pressure: ThermalPressure?, timeline: HeatTimeline, count: Int) {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on (CPU capped)" : "off"
        let boost = TweakLedger.load(at: Boost.defaultLedger) != nil ? "ON" : "off"
        let total = uses.reduce(0) { $0 + $1.cpuPercent }
        print(
            "Thermal: \(level.rawValue.capitalized)\(level.isThrottling ? " (THROTTLING)" : "")\(pressure.map { "  pressure \($0.label)" } ?? "")    Low Power Mode: \(lowPower)    Boost: \(boost)"
        )
        if timeline.samples.count > 1 {
            print("Heat  \(timeline.levelStrip(width: 60))")
            print("Load  \(timeline.loadStrip(width: 60))")
        }
        print(String(format: "Total CPU: %.0f%% (%d cores)\n", total, ProcessInfo.processInfo.activeProcessorCount))
        print("  PID     CPU    PRI  PROCESS")
        for u in uses.prefix(count) {
            let bg = getpriority(PRIO_DARWIN_PROCESS, UInt32(u.pid)) == PRIO_DARWIN_BG ? "bg" : "  "
            print(String(format: "%6d  %5.0f%%  %@   %@", u.pid, u.cpuPercent, bg, u.name))
        }
    }
}

struct BoostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boost",
        abstract: "Give one app (a game, say) more of the Mac; undone with `macx boost off`.",
        discussion: """
            Boost can't raise clock speeds (Apple silicon doesn't allow it). It takes work away from everything else: your busiest other apps go on background priority (efficiency cores, throttled disk and network), App Nap is turned off for the focus app, Reduce Transparency and Reduce Motion are turned on, and the Mac is kept awake. Apple's own processes and other users' are never touched. Every change is written down before it's made, so `macx boost off` puts back exactly what was there, even after a crash. Run `macx boost measure` to see whether it helps on your Mac.
            """,
        subcommands: [On.self, Off.self, Status.self, Measure.self],
        defaultSubcommand: Status.self
    )

    static func refuseRoot() throws {
        guard geteuid() != 0 else {
            throw UserError("Run Boost without sudo: it changes your settings, and under sudo they'd be root's.")
        }
    }

    /// The processes that started this macx (the terminal and shell) aren't demoted.
    static func ancestors() -> Set<Int32> {
        Set(ProcessTree.ancestry(of: Int(getpid()), in: ProcessTree.snapshot()).map { Int32($0.pid) })
    }

    static func plan(app: String?) throws -> BoostPlan {
        var focus: URL?
        if let app {
            guard let url = AppLocator.find(app) else { throw UserError("Can't find an app called \(app) in Applications.") }
            focus = url
        }
        print("Looking at what's busy (2 s)...")
        let samples = CPUSampler.sample(interval: 2)
        return Boost.plan(
            focus: focus, focusBundleID: focus.flatMap(AppLocator.bundleID), samples: samples, uid: getuid(), selfPID: getpid(),
            protected: ancestors())
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn Boost on.")
        @Option(help: "The app to give the Mac to (name or path).") var app: String?

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            try refuseRoot()
            let plan = try BoostCommand.plan(app: app)
            let ledger: TweakLedger
            do { ledger = try Boost.apply(plan) } catch Boost.Problem.alreadyOn {
                throw UserError("Boost is already on. Turn it off first: macx boost off")
            }
            print("Boost on\(plan.focus.map { " for \($0.deletingPathExtension().lastPathComponent)" } ?? ""):")
            for c in ledger.changes { print("  \(BoostCommand.describe(c, plan: plan))") }
            let skipped = plan.settings.filter { s in
                !ledger.changes.contains {
                    if case .setting(let d, let k, _, _) = $0 { return d == s.domain && k == s.key } else { return false }
                }
            }
            for s in skipped where RealSystem().read(domain: s.domain, key: s.key) != s.value {
                print("  (couldn't change \(s.key): skipped)")
            }
            if plan.demote.isEmpty { print("  Nothing else was busy enough to move aside.") }
            print("Undo everything: macx boost off")
        }
    }

    static func describe(_ c: TweakLedger.Change, plan: BoostPlan) -> String {
        switch c {
        case .background(let pid, _):
            let name = plan.demote.first { $0.pid == pid }?.name ?? "pid \(pid)"
            return "\(name) (pid \(pid)) on background priority"
        case .setting(_, let k, _, _):
            let why = plan.settings.first { $0.key == k }?.why ?? ""
            return "\(k) on\(why.isEmpty ? "" : ": \(why)")"
        default: return c.label
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn Boost off and put everything back.")
        func run() throws {
            try refuseRoot()
            guard let ledger = TweakLedger.load(at: Boost.defaultLedger) else {
                print("Boost isn't on.")
                return
            }
            let report = ledger.restore(system: RealSystem())
            print("Boost off: \(report.restored.count) change\(report.restored.count == 1 ? "" : "s") put back.")
            if report.restored.contains(where: { if case .background = $0 { true } else { false } }) {
                print("  Note: threads an app moved to low priority itself stay there; that's the app's own choice.")
            }
            for (c, why) in report.failed { print("  Couldn't put back \(c.label): \(why). Try again: macx boost off") }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Is Boost on, and what did it change?")
        func run() throws {
            guard let ledger = TweakLedger.load(at: Boost.defaultLedger) else {
                print("Boost is off. Turn it on: macx boost on --app NAME")
                return
            }
            let when = DateFormatter.localizedString(from: ledger.created, dateStyle: .short, timeStyle: .short)
            print("Boost is on (since \(when)):")
            for c in ledger.changes { print("  \(c.label)") }
            print("Undo: macx boost off")
        }
    }

    struct Measure: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Measure whether Boost helps on this Mac right now.")
        @Option(help: "Seconds per run (5-60).") var seconds: Double = 10

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            try refuseRoot()
            guard (5...60).contains(seconds) else { throw UserError("--seconds must be 5 to 60.") }
            guard TweakLedger.load(at: Boost.defaultLedger) == nil else { throw UserError("Turn Boost off first: macx boost off") }
            let threads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
            print(
                "Benchmark: \(threads) busy threads for \(Int(seconds)) s, without and then with Boost. Leave your other apps as they are.")
            let base = BoostMeasurement.run(seconds: seconds, threads: threads)
            let plan = try BoostCommand.plan(app: nil)
            let ledger = try Boost.apply(plan)
            defer { _ = ledger.restore(system: RealSystem()) }
            let boosted = BoostMeasurement.run(seconds: seconds, threads: threads)
            let m = BoostMeasurement(baseline: base, boosted: boosted)
            print(String(format: "Without Boost: %.0f   With Boost: %.0f   (%+.1f%%)", base, boosted, m.percent))
            switch m.verdict {
            case .faster: print("Boost helped here: the apps it moved aside were taking real CPU time.")
            case .slower: print("Slower with Boost. Something else changed during the run; try again.")
            case .noise:
                print(
                    "No real difference (within ±\(Int(BoostMeasurement.noiseBand))%): nothing busy enough was competing. Boost helps when other apps are busy."
                )
            }
            print(
                "Moved aside during the test: \(plan.demote.isEmpty ? "nothing" : plan.demote.map(\.name).joined(separator: ", ")). Everything is back as it was."
            )
        }
    }
}
