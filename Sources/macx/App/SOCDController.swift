import AppKit
import ApplicationServices
import MacxCore

/// SOCD for the games the user picked (research/performance-v2/RESEARCH.md): a keyboard tap that exists only while
/// one of those games is the front app. It sees only key presses and releases, keeps nothing, and acts only on
/// the movement pairs (A/D, W/S). It needs Input Monitoring (to see keys) and Accessibility (to post them).
@MainActor
final class SOCDController {
    static let shared = SOCDController()

    /// Marks the events this tap posts, so it lets its own events through untouched.
    nonisolated static let marker: Int64 = 0x4D41_4358  // "MACX"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var guardTimer: Timer?
    private var observer: NSObjectProtocol?
    fileprivate var resolver = SOCDResolver()
    private(set) var activeApp: String?

    /// Both permissions are there.
    static var permitted: Bool { CGPreflightListenEventAccess() && AXIsProcessTrusted() }

    /// Asks macOS for whichever permission is missing (it opens System Settings' prompt).
    static func requestPermissions() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    /// Tap on while a chosen game is in front and both permissions are there; off otherwise.
    func update() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let apps = Set(GameHooks.load().socdApps)
        let want = front.map(apps.contains) == true && Self.permitted
        if want, tap == nil {
            install()
            activeApp = front
        } else if !want, tap != nil {
            remove()
        }
    }

    private func install() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                callback: socdCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // A tap left behind after a permission is withdrawn can freeze all input: check every second and leave first.
        guardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if !Self.permitted { self?.remove() } }
        }
    }

    func remove() {
        guardTimer?.invalidate()
        guardTimer = nil
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
        activeApp = nil
        // Let go of anything the game still thinks is held.
        for case .post(let key, let down) in resolver.reset() { Self.post(key: key, down: down, proxy: nil) }
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    nonisolated static func post(key: UInt16, down: Bool, proxy: CGEventTapProxy?) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        if let proxy { e.tapPostEvent(proxy) } else { e.post(tap: .cgSessionEventTap) }
    }
}

/// The tap: every event goes back out in order (real ones and made-up ones), so the game never sees both keys down.
private func socdCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?
{
    guard let info else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<SOCDController>.fromOpaque(info).takeUnretainedValue()
    if type == .tapDisabledByTimeout {
        MainActor.assumeIsolated { controller.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.eventSourceUserData) == SOCDController.marker { return Unmanaged.passUnretained(event) }
    let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let actions = MainActor.assumeIsolated { controller.resolver.handle(key: key, down: type == .keyDown, isRepeat: isRepeat) }
    if actions == [.pass] { return Unmanaged.passUnretained(event) }
    for a in actions {
        switch a {
        case .pass: event.tapPostEvent(proxy)
        case .swallow: break
        case .post(let k, let down): SOCDController.post(key: k, down: down, proxy: proxy)
        }
    }
    return nil
}
