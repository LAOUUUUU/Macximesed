import Foundation
import IOKit.ps

/// "Why it's slow" (research/performance-v3/RESEARCH.md): plain-words explanations of what's slowing the Mac, from
/// the live CPU list and a few system facts. Apple's processes are recognised by their exact path under /System,
/// never by name, and macx never stops them: the advice says what actually helps.
public enum SlowdownAdvisor {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case photosAnalysis, spotlight, windowServer, webPage, videoDecoding, backgroundApp, memoryTight, onBattery, diskNearlyFull
    }

    public struct Insight: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var title: String
        public var advice: String
        /// For a background app: the .app it belongs to, so the page can offer Quit.
        public var appPath: String?
        public var id: String { kind.rawValue + (appPath ?? "") }
    }

    /// CPU (100% = one core) above which a known process is worth explaining, and a background app worth naming.
    static let busy: Double = 15

    static let known: [(Kind, [String], String, String)] = [
        (
            .photosAnalysis,
            [
                "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd",
                "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd",
            ],
            "Photos is analysing your library",
            "It recognises faces, objects and text, and can run for hours after an update. Leave the Mac plugged in overnight and it finishes; quitting it doesn't help, macOS restarts it."
        ),
        (
            .spotlight,
            [
                "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores",
                "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds",
            ],
            "Spotlight is indexing",
            "Usually after an update or copying lots of files. It settles by itself; plugged in, it's done sooner."
        ),
        (
            .windowServer,
            ["/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"],
            "macOS's window drawing is busy",
            "One app is usually behind it (many windows, an animated wallpaper, a paused virtual machine). Quit the busiest app and watch whether it drops."
        ),
        (
            .webPage,
            [
                "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
            ],
            "A web page is busy",
            "A Safari tab, or a web view in an app, is doing a lot (video, ads, a heavy site). Closing that tab cools the Mac fastest."
        ),
        (
            .videoDecoding,
            [
                "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService"
            ],
            "Video is playing somewhere",
            "A video still running in a tab or app, or a moving (Aerial) wallpaper. A still wallpaper saves GPU work all the time."
        ),
    ]

    /// The outermost `.app` a path belongs to (helpers count towards their app), or nil.
    public static func appBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func isApple(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    public static func explain(
        uses: [CPUUse], front: String?, memory: MemoryState? = nil, onBattery: Bool = false, diskFreeFraction: Double? = nil
    ) -> [Insight] {
        var out: [Insight] = []
        for (kind, paths, title, advice) in known {
            let cpu = uses.filter { paths.contains($0.path) }.reduce(0) { $0 + $1.cpuPercent }
            if cpu >= busy { out.append(Insight(kind: kind, title: "\(title) (\(Int(cpu))%)", advice: advice)) }
        }
        // Apps working while you're in another one, helpers added up under their app.
        var byApp: [String: Double] = [:]
        for u in uses where !isApple(u.path) {
            if let app = appBundle(of: u.path) { byApp[app, default: 0] += u.cpuPercent }
        }
        for (app, cpu) in byApp.sorted(by: { $0.value > $1.value }) where cpu >= busy && app != front {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            out.append(
                Insight(
                    kind: .backgroundApp, title: "\(name) is using \(Int(cpu))% in the background",
                    advice: "It isn't the app you're in. If you're not using it, quitting it frees the CPU and cools the Mac.",
                    appPath: app))
        }
        if let m = memory, m.pressure != .normal {
            out.append(
                Insight(
                    kind: .memoryTight, title: m.pressure.label,
                    advice:
                        "The Mac is moving memory to disk. Quitting the biggest memory users (switch the list to Memory) helps more than Boost."
                ))
        }
        if onBattery {
            out.append(
                Insight(
                    kind: .onBattery, title: "On battery",
                    advice: "Games and heavy work run slower on battery. Plugged in, the Mac keeps its speed up longer."))
        }
        if let f = diskFreeFraction, f < 0.10 {
            out.append(
                Insight(
                    kind: .diskNearlyFull, title: "The disk is \(Int((1 - f) * 100))% full",
                    advice: "macOS needs free space to swap memory to; a nearly full disk makes a busy Mac much slower. Clean frees some."))
        }
        return out
    }
}

/// Whether the Mac is running on its battery right now (IOKit power sources; false on a desktop Mac).
public enum PowerSource {
    public static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
