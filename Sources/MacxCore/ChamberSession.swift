import Foundation

/// One chamber run, the same for `macx chamber run` and the app's Check page: pin the file, check the malware feed,
/// build the image, run the VM and judge what it did. Blocks until the VM is done (seconds + 30 at most), so the app
/// calls it off the main thread.
public enum ChamberSession {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notSetUp
        case unreadable
        case knownMalware(String)
        case cantRun(String)
        case vm(String)
        case didNotStart(seconds: Int)

        public var description: String {
            switch self {
            case .notSetUp: "The chamber isn't set up yet. Run: macx chamber setup"
            case .unreadable: "The file can't be read."
            case .knownMalware(let name): "Known malware (\(name)). It doesn't need the chamber: don't open it."
            case .cantRun(let why): why
            case .vm(let why): why
            case .didNotStart(let s): "The chamber didn't get as far as running the script (it stopped after \(s) s)."
            }
        }
    }

    /// Where a run is, for the app's status bar.
    public enum Stage: Sendable, Equatable {
        case preparing
        case building
        case booting
        case running(limit: Int)
        case judging

        public var label: String {
            switch self {
            case .preparing: "Pinning the file and checking the malware list"
            case .building: "Building the throwaway VM"
            case .booting: "Starting the VM (no network)"
            case .running(let limit): "Running the script (\(limit) s at most)"
            case .judging: "Reading what it did"
            }
        }
    }

    public struct Outcome: Sendable {
        public var sample: ChamberSample
        public var report: ChamberReport
        public var run: ChamberVM.Run
    }

    /// Whether the chamber can take this file at all: a script it has an interpreter for.
    public static func canRun(_ url: URL) -> Bool {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 512) else { return false }
        return (try? ChamberImage.kind(of: head)) != nil
    }

    public static func isSetUp(store: ChamberStore = ChamberStore()) -> Bool {
        guard let manifest = try? ChamberManifest.bundled() else { return false }
        return store.isInstalled(for: manifest)
    }

    public static func run(
        _ url: URL, seconds: Int = 60, store: ChamberStore = ChamberStore(), feed: HashLookup? = HashFeed.loadCached(),
        progress: @escaping @Sendable (Stage) -> Void = { _ in }
    ) throws -> Outcome {
        guard isSetUp(store: store) else { throw Problem.notSetUp }
        progress(.preparing)
        let sample: ChamberSample
        do { sample = try ChamberSample(pinning: url) } catch { throw Problem.unreadable }
        if let feed, let name = try? feed.lookup(sha256: sample.sha256) { throw Problem.knownMalware(name) }
        let image: Data
        progress(.building)
        do {
            image = try ChamberImage.build(rootfs: store.rootfs, sample: sample, seconds: seconds)
        } catch let p as ChamberImage.Problem {
            throw Problem.cantRun(p.description)
        }
        let run: ChamberVM.Run
        do {
            progress(.booting)
            run = try ChamberVM.run(
                kernel: store.kernel, initramfs: image, timeLimit: TimeInterval(seconds + 30),
                onReady: { progress(.running(limit: seconds)) })
        } catch let p as ChamberVM.Problem {
            throw Problem.vm(p.description)
        }
        guard run.console.ready else { throw Problem.didNotStart(seconds: Int(run.seconds)) }
        progress(.judging)
        let parsed = StraceLog.parse(run.console.trace)
        let report = ChamberJudge(guestHome: URL(fileURLWithPath: ChamberImage.guestHome)).judge(
            events: parsed.events, samplePID: parsed.events.first?.process?.pid, skipped: parsed.skipped,
            truncated: !run.console.complete)
        return Outcome(sample: sample, report: report, run: run)
    }
}
