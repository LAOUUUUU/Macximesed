import AppKit
import MacxCore
import SwiftUI
import UserNotifications

/// The Mac app: a menu bar item that is always there, and a window opened from it (or from Finder).
@MainActor
enum MacxApp {
    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = AppDelegate.makeMainMenu()
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    var window: NSWindow?
    var setupWindow: NSWindow?
    var status: StatusController?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(model: model, openWindow: { [weak self] section in self?.showWindow(section) })
        let env = ProcessInfo.processInfo.environment
        UNUserNotificationCenter.current().delegate = self
        model.runSetup = { [weak self] in self?.showSetup() }
        // For checking the design without Screen Recording: the app draws its own window into PNG files and quits.
        if let dir = env["MACX_APP_SNAPSHOT"], !dir.isEmpty {
            Snapshots(delegate: self, folder: URL(fileURLWithPath: dir)).start()
            return
        }
        watchForUpdates()
        if env["MACX_APP_SETUP"] == "1" || FirstRun.shouldShowSetup(finished: UserDefaults.standard.string(forKey: FirstRun.defaultsKey)) {
            showSetup()
        } else if env["MACX_APP_HIDDEN"] != "1" {
            showWindow(nil)
        }
        // For screenshots and checks: `open --env MACX_APP_PANEL=1 Macximesed.app` opens the menu bar panel too.
        if env["MACX_APP_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.status?.showPanel() }
        }
    }

    /// Updates: ask the channel now and every 6 hours, and install a chosen update when the screen sleeps or the Mac wakes.
    func watchForUpdates() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.handle(.screenSlept) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.handle(.woke)
                self?.model.checkForUpdate()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.model.checkForUpdate() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.checkForUpdate() } }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showWindow(_ section: AppModel.Section?) {
        if let section { model.section = section }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.title = "Macximesed"
            w.backgroundColor = NSColor(Ink.paper)
            w.contentView = NSHostingView(rootView: MainView(model: model))
            w.setFrameAutosaveName("MacximesedMain")
            if !w.setFrameUsingName("MacximesedMain") { w.center() }
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        // Show in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        model.windowOpen = true
        NSApp.activate()
    }

    func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.title = "Set up Macximesed"
            w.backgroundColor = NSColor(Ink.paper)
            w.contentView = NSHostingView(rootView: SetupView(model: model) { [weak self] in self?.finishSetup() })
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            setupWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Finished or skipped: it doesn't open by itself again (Settings has "Run setup again").
    func finishSetup() {
        UserDefaults.standard.set(macxVersion, forKey: FirstRun.defaultsKey)
        let w = setupWindow
        setupWindow = nil
        w?.close()
        showWindow(.protection)
    }

    // Alerts the app posts show even while it's in front; clicking one opens Protection.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { showWindow(.protection) }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === setupWindow {
            // Closed with the red button: counts as skipped.
            UserDefaults.standard.set(macxVersion, forKey: FirstRun.defaultsKey)
            setupWindow = nil
            if window?.isVisible != true { showWindow(nil) }
            return
        }
        model.windowOpen = false
        NSApp.setActivationPolicy(.accessory)
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Macximesed", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Macximesed", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Macximesed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// MARK: Menu bar

/// The status item: a glyph drawn in code (template, so macOS tints it), a borderless panel on left click and a
/// plain menu on right click. Not an NSPopover, so it doesn't get the glass look.
@MainActor
final class StatusController: NSObject {
    let model: AppModel
    let openWindow: (AppModel.Section?) -> Void
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var panel: NSPanel?
    var monitor: Any?
    var lastGlyph: (WatchState.Glyph, Bool)?

    init(model: AppModel, openWindow: @escaping (AppModel.Section?) -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Macximesed")
        updateGlyph()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateGlyph() } }
        RunLoop.main.add(t, forMode: .common)
    }

    func updateGlyph() {
        let now = (model.state.glyph, model.unreadCritical > 0)
        if let lastGlyph, lastGlyph == now { return }
        lastGlyph = now
        item.button?.image = Glyph.image(now.0, critical: now.1)
        item.button?.toolTip = "Macximesed: \(model.state.headline)" + (now.1 ? " \(model.unreadCritical) critical unread." : "")
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showMenu()
        } else if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        if case .paused = model.state {
            menu.addItem(action("Resume…") { [model] in model.resume() })
        } else if model.installed {
            menu.addItem(action("Pause for 1 hour…") { [model] in model.pause() })
        }
        menu.addItem(action("Show all alerts") { [weak self] in self?.openWindow(.protection) })
        menu.addItem(action("Open Macximesed") { [weak self] in self?.openWindow(nil) })
        menu.addItem(.separator())
        menu.addItem(action("Quit") { NSApp.terminate(nil) })
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, run: run)
        return i
    }

    func showPanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let view = MenuPanelView(
            model: model,
            open: { [weak self] section in
                self?.closePanel()
                self?.openWindow(section)
            },
            close: { [weak self] in self?.closePanel() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
        item.button?.highlight(true)
        model.refresh()
        model.markSeen()
        updateGlyph()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        item.button?.highlight(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Lets the borderless panel take key focus (Escape closes it).
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

final class ClosureMenuItem: NSMenuItem {
    let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }
    @objc func fire() { run() }
}

/// The menu bar mark: a square outline with a filled centre while watching, the outline alone when paused, a
/// slash through it when nothing is watching, and a red dot for an unread critical alert (the one colour).
enum Glyph {
    static func image(_ g: WatchState.Glyph, critical: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let ink = critical ? NSColor.labelColor : NSColor.black
            ink.setStroke()
            ink.setFill()
            let frame = NSBezierPath(rect: NSRect(x: 2.75, y: 2.75, width: 10.5, height: 10.5))
            frame.lineWidth = 1.5
            frame.stroke()
            switch g {
            case .watching: NSBezierPath(rect: NSRect(x: 5.5, y: 5.5, width: 5, height: 5)).fill()
            case .paused: break
            case .off:
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 1, y: 15))
                slash.line(to: NSPoint(x: 15, y: 1))
                slash.lineWidth = 1.5
                slash.stroke()
            }
            if critical {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 5, height: 5)).fill()
            }
            return true
        }
        // A template image can't carry colour, so the red-dot version draws in the label colour instead.
        img.isTemplate = !critical
        img.accessibilityDescription = "Macximesed"
        return img
    }
}

struct MenuPanelView: View {
    @Bindable var model: AppModel
    let open: (AppModel.Section?) -> Void
    let close: () -> Void

    var sub: String {
        var parts: [String] = []
        switch model.state {
        case .watching(let since): parts.append("Since \(WatchState.clock(since))")
        case .paused: parts.append("Alerts still logged")
        case .refused(let m): parts.append(String(m.split(separator: "\n").first ?? ""))
        case .notRunning: parts.append("Installed, stopped")
        case .notInstalled: parts.append("Background watch not installed")
        case .starting: parts.append("Starting eslogger")
        }
        parts.append(model.fullDiskAccess ? "Full Disk Access on" : "Full Disk Access off")
        if model.unreadCritical > 0 { parts.append("\(model.unreadCritical) critical unread") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Macximesed")
                HStack(spacing: 9) {
                    if model.state.glyph == .watching { LiveMark() }
                    Text(model.state.headline).font(Fonts.serif(22)).tracking(-0.2)
                        .foregroundStyle(
                            model.state.glyph == .watching ? Ink.text : (model.state.glyph == .paused ? Ink.paused : Ink.signal)
                        )
                        .contentTransition(.opacity).motion(value: model.state.headline)
                }
                Text(sub).font(Fonts.sans(12)).foregroundStyle(Ink.grey).lineLimit(2)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            Hairline()
            SectionLabel(text: "Latest").padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            let latest = Array(model.groups.sorted { $0.last > $1.last }.prefix(4))
            if latest.isEmpty {
                Text("No alerts this week.").font(Fonts.sans(12.5)).foregroundStyle(Ink.grey)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            ForEach(Array(latest.enumerated()), id: \.element.id) { i, g in
                Button {
                    open(.protection)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SeverityMark(severity: g.severity).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.latest.title).font(Fonts.sans(13, g.severity == .critical ? .semibold : .regular)).lineLimit(1)
                            Text(ProtectionView.short(g.process) + (g.count > 1 ? " · \(g.count)" : ""))
                                .font(Fonts.mono(10.5)).foregroundStyle(Ink.grey).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text(ProtectionView.when(g.last)).font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowHover()).focusEffectDisabled()
                .reveal(i, rise: 4)
            }
            Hairline().padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                if case .paused = model.state {
                    menuRow("Resume…", info: "Asks for your administrator password.") {
                        close()
                        model.resume()
                    }
                } else if model.installed {
                    menuRow(
                        "Pause for 1 hour…",
                        info: "Asks for your administrator password. The watch turns itself back on when the hour is up."
                    ) {
                        close()
                        model.pause()
                    }
                }
                menuRow("Show all alerts", key: "⌘1") { open(.protection) }
                menuRow("Open Macximesed", key: "⌘O") { open(nil) }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 340)
        .background(Ink.raised)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.outline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(Ink.text)
        .monospacedDigit()
    }

    func menuRow(_ title: String, key: String = "", info: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(Fonts.sans(13))
                if let info { InfoGlyph().frame(width: 14, height: 14).foregroundStyle(Ink.grey).help(info) }
                Spacer()
                Text(key).font(Fonts.sans(12)).foregroundStyle(Ink.grey)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHover()).focusEffectDisabled()
    }
}

/// Menu-like rows: a flat tint under the pointer, nothing else.
struct RowHover: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Hovering(pressed: configuration.isPressed) { configuration.label } }

    struct Hovering<Content: View>: View {
        let pressed: Bool
        @ViewBuilder let content: () -> Content
        @State private var over = false
        var body: some View {
            content().background(pressed ? Ink.selected : (over ? Ink.rowOpen : Color.clear)).motion(Motion.quick, value: over)
                .onHover { over = $0 }
        }
    }
}

/// `MACX_APP_SNAPSHOT=DIR`: every page of the main window, the menu bar panel and the first setup screen, in
/// light and dark, drawn by the app itself into PNGs (no Screen Recording needed), then quit.
@MainActor
final class Snapshots {
    let delegate: AppDelegate
    let folder: URL
    init(delegate: AppDelegate, folder: URL) {
        self.delegate = delegate
        self.folder = folder
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        delegate.showWindow(.protection)
        if let v = ProcessInfo.processInfo.environment["MACX_APP_SNAPSHOT_UPDATE"] {
            delegate.model.updateAvailable = v
            delegate.model.updatePrompt = v
        }
        var steps: [(String, () -> Void)] = []
        for appearance in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            steps.append(("", { NSApp.appearance = NSAppearance(named: appearance.1) }))
            for section in AppModel.Section.allCases {
                steps.append(
                    (
                        "\(appearance.0)-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                        { self.delegate.model.section = section }
                    ))
            }
            steps.append(("\(appearance.0)-menu-panel", {}))
        }
        run(steps, 0)
    }

    func run(_ steps: [(String, () -> Void)], _ i: Int) {
        guard i < steps.count else {
            NSApp.terminate(nil)
            return
        }
        let (name, action) = steps[i]
        action()
        // Long enough for the data to load and every animation to settle.
        let slow = name.hasSuffix("check-a-file") && ProcessInfo.processInfo.environment["MACX_APP_SNAPSHOT_CHAMBER"] == "1"
        if slow {
            // One more while the chamber is still running, to see its stage in the status bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                if let view = self.delegate.window?.contentView { self.save(view, name + "-running") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (name.isEmpty ? 0.5 : slow ? 9 : 2.5)) {
            if name.hasSuffix("menu-panel") {
                let host = NSHostingView(rootView: MenuPanelView(model: self.delegate.model, open: { _ in }, close: {}))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                w.appearance = NSApp.appearance
                // On screen (far off to the side) so its appear animations run, as in the real panel.
                w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                w.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.save(host, name)
                    self.run(steps, i + 1)
                }
                return
            }
            if !name.isEmpty, let view = self.delegate.window?.contentView { self.save(view, name) }
            self.run(steps, i + 1)
        }
    }

    func save(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
