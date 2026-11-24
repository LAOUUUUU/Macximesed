import AppKit
import MacxCore
import SwiftUI
import UniformTypeIdentifiers

/// Asks before anything is moved. Returns true for the action button.
@MainActor func confirm(_ title: String, _ message: String, action: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.addButton(withTitle: action)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}

struct Loading: View {
    let text: String
    var body: some View {
        Text(text).font(Fonts.sans(14)).foregroundStyle(Ink.grey)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 48).padding(.vertical, 24)
    }
}

// MARK: Startup items

struct StartupView: View {
    @Bindable var model: AppModel
    @State private var note: String?

    struct Flagged: Identifiable {
        var item: PersistenceItem
        var severity: Severity
        var titles: [String]
        var id: String { item.key }
    }

    var flagged: [Flagged] {
        var byKey: [String: Flagged] = [:]
        for f in model.startupFindings where f.severity >= .medium {
            var e = byKey[f.item.key] ?? Flagged(item: f.item, severity: f.severity, titles: [])
            e.severity = max(e.severity, f.severity)
            e.titles.append(f.title)
            byKey[f.item.key] = e
        }
        return byKey.values.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id }
    }

    var headline: String {
        guard model.startupItems != nil else { return "Scanning…" }
        switch flagged.count {
        case 0: return "Nothing needs a look."
        case 1: return "One needs a look."
        default: return "\(flagged.count) need a look."
        }
    }

    var sentence: String? {
        guard let items = model.startupItems else { return nil }
        var s = "\(items.count) things start with your Mac or your login."
        if model.startupHasBaseline {
            s +=
                model.startupAdded.isEmpty
                ? " Nothing is new since your baseline." : " \(model.startupAdded.count) new since your baseline."
        }
        return s + (note.map { " \($0)" } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(label: "Startup items", headline: headline, sentence: sentence) {
                Button("Scan again") { scan() }.buttonStyle(PlainButtonStyle()).disabled(model.startupItems == nil)
                Button("Set as baseline") { setBaseline() }.buttonStyle(PlainButtonStyle()).disabled(model.startupItems == nil)
            }
            if let items = model.startupItems {
                let flagged = flagged
                let flaggedKeys = Set(flagged.map(\.id))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !flagged.isEmpty {
                            groupHeader("Needs a look", flagged.count)
                            ForEach(flagged) { f in
                                row(f.item, severity: f.severity, why: f.titles.joined(separator: "\n"))
                            }
                        }
                        let known = items.filter { !flaggedKeys.contains($0.key) }
                        groupHeader("Known", known.count)
                        ForEach(known, id: \.key) { item in row(item, severity: nil, why: nil) }
                    }
                    .padding(.horizontal, 48).padding(.bottom, 32)
                }
            } else {
                Loading(text: "Reading launch agents, daemons, login items, extensions and shell startup files…")
                Spacer()
            }
        }
        .task { if model.startupItems == nil { scan() } }
    }

    func groupHeader(_ title: String, _ count: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Fonts.sans(11.5, .medium).lowercaseSmallCaps()).tracking(1.3)
                Spacer()
                Text("\(count)").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
            }
            .padding(.top, 22).padding(.bottom, 6)
            Hairline(color: Ink.text)
        }
    }

    func row(_ item: PersistenceItem, severity: Severity?, why: String?) -> some View {
        let name = item.label ?? (item.path as NSString).lastPathComponent
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Group {
                    if let severity {
                        SeverityWord(severity: severity)
                    } else {
                        HStack(spacing: 8) {
                            SeverityMark(severity: .low)
                            Text("Known").foregroundStyle(Ink.grey)
                        }
                    }
                }
                .frame(width: 104, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name).font(Fonts.sans(13.5)).lineLimit(1)
                        if let why { InfoButton(text: why, detail: item.program) }
                    }
                    Text(ProtectionView.short(item.path)).font(Fonts.mono(11)).foregroundStyle(Ink.grey).lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.signature?.label ?? item.kind.label).font(Fonts.sans(12)).foregroundStyle(Ink.grey).lineLimit(1)
                    .frame(width: 190, alignment: .leading)
                Text(model.startupAdded.contains(item.key) ? "new" : "").font(Fonts.mono(11)).frame(width: 36, alignment: .leading)
                HStack(spacing: 6) {
                    if item.path.hasPrefix("/"), FileManager.default.fileExists(atPath: item.path) {
                        Button("Show") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                        .buttonStyle(PlainButtonStyle())
                        if severity != nil, Self.canRemove(item) {
                            Button("Remove…") { remove(item, name: name) }.buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
        }
        .zIndex(why == nil ? 0 : 1)
    }

    /// Only files you own (your LaunchAgents, login hooks you wrote). System-wide ones need `sudo macx persist`.
    static func canRemove(_ item: PersistenceItem) -> Bool {
        guard item.kind != .shellStartup, item.path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: item.path)
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func scan() {
        model.startupItems = nil
        let own = AppModel.executable
        Task.detached(priority: .userInitiated) {
            let found = PersistenceScanner.current()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let f = PersistenceRules.evaluate(found, home: home, ownProgram: own)
            let old = try? PersistenceBaseline.load()
            let diff = old.map { PersistenceBaseline.diff(old: $0, new: found) }
            let addedKeys = Set((diff?.added ?? []).map(\.key) + (diff?.changed ?? []).map(\.key))
            await MainActor.run {
                model.startupItems = found
                model.startupFindings = f
                model.startupHasBaseline = old != nil
                model.startupAdded = addedKeys
                model.startupCount = found.count
            }
        }
    }

    func setBaseline() {
        guard let items = model.startupItems else { return }
        do {
            try PersistenceBaseline.save(items)
            model.startupHasBaseline = true
            model.startupAdded = []
            note = "Baseline saved."
        } catch {
            note = "Couldn't save the baseline: \(error.localizedDescription)"
        }
    }

    func remove(_ item: PersistenceItem, name: String) {
        guard
            confirm(
                "Remove \(name)?", "It moves to the undo store and stops starting at login. You can put it back with macx undo.",
                action: "Remove")
        else { return }
        do {
            let batch = try UndoStore().stash([URL(fileURLWithPath: item.path)], reason: "startup item: \(name)")
            note = "Moved \(name) to the undo store (\(batch.id))."
            scan()
        } catch {
            note = "Couldn't remove it: \(error.localizedDescription)"
        }
    }
}

// MARK: Check a file

struct CheckView: View {
    @State private var report: FileReport?
    @State private var checking: String?
    @State private var problem: String?
    @State private var targeted = false

    var headline: String {
        if let checking { return "Checking \(checking)…" }
        guard let report else { return problem == nil ? "Check a file." : "Couldn't check it." }
        switch report.verdict {
        case .ok: return "Looks fine."
        case .partlyUnknown: return "Partly unknown."
        case .caution: return "Be careful."
        case .dangerous: return "Don't open this."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                label: "Check a file", headline: headline,
                sentence: report.map { "\($0.path.lastPathComponent), \($0.kind.label)." } ?? problem
                    ?? "An app, installer, disk image or script. It's read, never opened.",
                headlineColor: (report?.verdict ?? .ok) >= .caution ? Ink.signal : Ink.text
            ) {
                Button("Choose…") { choose() }.buttonStyle(PlainButtonStyle(kind: report == nil ? .primary : .secondary))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    dropTarget.padding(.top, 28)
                    if let report { details(report) }
                }
                .padding(.horizontal, 48).padding(.bottom, 32)
            }
        }
    }

    var dropTarget: some View {
        Text(targeted ? "Let go to check it" : "Drop a file here")
            .font(Fonts.sans(13)).foregroundStyle(Ink.grey)
            .frame(maxWidth: .infinity).frame(height: report == nil ? 180 : 72)
            .overlay(Rectangle().stroke(targeted ? Ink.text : Ink.outline, lineWidth: 1))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in check(url) } }
                }
                return true
            }
    }

    func details(_ r: FileReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !r.findings.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        SectionLabel(text: "Why")
                        Spacer()
                    }
                    .padding(.top, 28).padding(.bottom, 6)
                    Hairline(color: Ink.text)
                }
                ForEach(Array(r.findings.sorted { $0.severity > $1.severity }.enumerated()), id: \.offset) { _, f in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 20) {
                            SeverityWord(severity: f.severity).frame(width: 96, alignment: .leading)
                            HStack(spacing: 4) {
                                Text(f.title).font(Fonts.sans(13.5))
                                if let d = f.detail, !d.isEmpty { InfoButton(text: d) }
                            }
                            Spacer()
                            Text(f.rule).font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                        }
                        .padding(.vertical, 10)
                        .background(alignment: .bottom) { Hairline() }
                    }
                    .zIndex(1)
                }
            }
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(text: "Facts")
                    Spacer()
                }
                .padding(.top, 28).padding(.bottom, 6)
                Hairline(color: Ink.text)
            }
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 8) {
                fact("Signature", r.signature?.label)
                if let g = r.gatekeeper {
                    fact("Gatekeeper", (g.accepted ? "allowed" : "blocked") + (g.source.map { " (\($0))" } ?? ""))
                }
                if let q = r.quarantine {
                    fact(
                        "Downloaded",
                        "by \(q.agent ?? "an unknown app")"
                            + (q.date.map { ", \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short))" } ?? ""))
                }
                fact("SHA-256", r.sha256, mono: true)
                ForEach(Array(r.installs.enumerated()), id: \.offset) { _, i in
                    fact("Installs", i.label + (i.path.map { " → \($0)" } ?? ""), mono: true)
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder func fact(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(Ink.grey).font(Fonts.sans(12.5))
                Text(value).font(mono ? Fonts.mono(11.5) : Fonts.sans(13)).textSelection(.enabled)
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true  // .app bundles are folders
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { check(url) }
    }

    func check(_ url: URL) {
        guard PrivacyPolicy.current.allows(url) || FileManager.default.isReadableFile(atPath: url.path) else {
            problem = "\(url.lastPathComponent) is in a privacy-guarded folder. Give Macximesed Full Disk Access first (Settings)."
            report = nil
            return
        }
        checking = url.lastPathComponent
        problem = nil
        Task.detached(priority: .userInitiated) {
            let checker = FileChecker(signatures: GuardedSignatureChecker(), lookup: HashFeed.loadCached())
            let result = Result { try checker.check(url) }
            await MainActor.run {
                checking = nil
                switch result {
                case .success(let r): report = r
                case .failure(let e):
                    report = nil
                    problem = "\(e)"
                }
            }
        }
    }
}

// MARK: Clean

struct CleanView: View {
    @Bindable var model: AppModel
    @State private var lastBatch: UndoBatch?
    @State private var note: String?
    @State private var held = UndoUsage(batches: 0, bytes: 0)

    var total: UInt64 { (model.cleanItems ?? []).filter { model.cleanChosen.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                label: "Clean",
                headline: model.cleanItems == nil
                    ? "Measuring…" : (total == 0 ? "Nothing chosen." : "\(formatBytes(total)) can go."),
                sentence: note ?? "Caches and logs that apps rebuild. Everything moves to the undo store first; nothing is deleted."
            ) {
                if let lastBatch {
                    Button("Undo last clean") { undo(lastBatch) }.buttonStyle(PlainButtonStyle())
                }
                if held.batches > 0 {
                    Button("Empty undo folder (\(formatBytes(held.bytes)))…") { emptyUndo() }
                        .buttonStyle(PlainButtonStyle())
                }
                if model.cleanItems != nil {
                    Button("Clean \(formatBytes(total))…") { clean() }
                        .buttonStyle(PlainButtonStyle(kind: .primary)).disabled(total == 0)
                }
            }
            if let items = model.cleanItems {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in row(item) }
                    }
                    .padding(.horizontal, 48).padding(.bottom, 32)
                }
            } else {
                Loading(text: "Measuring caches and logs…")
                Spacer()
            }
        }
        .task { if model.cleanItems == nil { scan() } }
    }

    func row(_ item: CleanupItem) -> some View {
        let on = model.cleanChosen.contains(item.id)
        let blocked = item.inUseBy != nil
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Button {
                    if on { model.cleanChosen.remove(item.id) } else { model.cleanChosen.insert(item.id) }
                } label: {
                    Rectangle().strokeBorder(Ink.outline, lineWidth: 1)
                        .background(on ? Ink.text : Color.clear)
                        .overlay {
                            if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.paper) }
                        }
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .accessibilityLabel(item.title)
                .accessibilityValue(on ? "chosen" : "not chosen")
                HStack(spacing: 4) {
                    Text(item.title).font(Fonts.sans(13.5)).foregroundStyle(blocked ? Ink.grey : Ink.text)
                    InfoButton(
                        text: blocked ? "In use by \(item.inUseBy ?? "an app"), so it's left alone." : "Belongs to: \(item.owner.label).",
                        detail: item.paths.map { ProtectionView.short($0.path) }.prefix(6).joined(separator: "\n"))
                }
                Spacer()
                Text(formatBytes(item.bytes)).font(Fonts.mono(12))
            }
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
        }
        .zIndex(1)
    }

    func scan() {
        held = UndoStore().usage()
        let running = runningBundleIDs()
        Task.detached(priority: .userInitiated) {
            let all = CleanupCatalog.safe(.current(runningBundleIDs: running)).filter { $0.bytes > 0 }
            let preset = Set(CleanupCatalog.select(all, only: [], includeInUse: false, includeUnknown: false).map(\.id))
            await MainActor.run {
                model.cleanItems = all.sorted { $0.bytes > $1.bytes }
                model.cleanChosen = preset
                model.cleanBytes = all.filter { preset.contains($0.id) }.reduce(0) { $0 + $1.bytes }
            }
        }
    }

    func clean() {
        guard let items = model.cleanItems else { return }
        let picked = items.filter { model.cleanChosen.contains($0.id) && $0.inUseBy == nil }
        guard
            confirm(
                "Clean \(formatBytes(total))?", "\(picked.count) items move to the undo store. Undo puts them back.",
                action: "Clean")
        else { return }
        do {
            let batch = try CleanupCatalog.run(picked, store: UndoStore())
            lastBatch = batch
            note =
                "Moved \(formatBytes(batch.totalBytes)) to the undo store."
                + (batch.failed.isEmpty ? "" : " \(batch.failed.count) couldn't move.")
            model.cleanItems = nil
            scan()
        } catch {
            note = "Couldn't clean: \(error.localizedDescription)"
        }
    }

    /// The only way the app deletes anything for good: what earlier cleans, removals and quarantines moved aside.
    func emptyUndo() {
        let use = UndoStore().usage()
        guard
            confirm(
                "Empty the undo folder?",
                "\(use.batches) earlier cleans, removed apps and quarantined files (\(formatBytes(use.bytes))) are deleted for good. They can't be put back after this.",
                action: "Empty")
        else { return }
        do {
            try UndoStore().empty()
            note = "Freed \(formatBytes(use.bytes)). The undo folder is empty."
            lastBatch = nil
        } catch {
            note = "Couldn't empty the undo folder: \(error.localizedDescription)"
        }
        held = UndoStore().usage()
    }

    func undo(_ batch: UndoBatch) {
        do {
            let r = try UndoStore().restore(id: batch.id)
            note = "Put back \(r.restored.count) items."
            lastBatch = nil
            model.cleanItems = nil
            scan()
        } catch {
            note = "Couldn't undo: \(error.localizedDescription)"
        }
    }
}

// MARK: Apps

struct AppsView: View {
    @Bindable var model: AppModel
    @State private var note: String?
    @State private var unusedOnly = false

    var shown: [AppInfo] {
        let all = (model.apps ?? []).filter { !$0.isOnSystemVolume }
        return unusedOnly ? AppScanner.unused(all, olderThanDays: 90) : all
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                label: "Apps", headline: model.apps == nil ? "Finding apps…" : "\(shown.count) apps.",
                sentence: note
                    ?? (model.appsSkipped > 0 ? "\(model.appsSkipped) in guarded folders were skipped (Full Disk Access is off)." : nil)
            ) {
                TwoState(label: "Unused for 90 days only", isOn: unusedOnly) { unusedOnly = $0 }
                    .help("Only apps not opened for 90 days")
            }
            if model.apps != nil {
                HStack(spacing: 20) {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Size").frame(width: 80, alignment: .trailing)
                    Text("Last used").frame(width: 120, alignment: .trailing)
                    Text("").frame(width: 90)
                }
                .font(Fonts.sans(11.5, .medium).lowercaseSmallCaps()).tracking(1.3).foregroundStyle(Ink.grey)
                .padding(.horizontal, 48).padding(.top, 12).padding(.bottom, 8)
                Hairline().padding(.horizontal, 48)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown, id: \.url) { app in row(app) }
                    }
                    .padding(.horizontal, 48).padding(.bottom, 32)
                }
            } else {
                Loading(text: "Asking Spotlight for every app on this Mac…")
                Spacer()
            }
        }
        .task { if model.apps == nil { scan() } }
    }

    func row(_ app: AppInfo) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(Fonts.sans(13.5))
                    Text(app.bundleID + (app.version.map { " · \($0)" } ?? "")).font(Fonts.mono(11)).foregroundStyle(Ink.grey).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(formatBytes(app.bytes)).font(Fonts.mono(12)).frame(width: 80, alignment: .trailing)
                Text(
                    app.lastUsed.map {
                        (app.lastUsedIsEstimate ? "about " : "") + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
                    } ?? "never"
                )
                .font(Fonts.sans(12)).foregroundStyle(Ink.grey).frame(width: 120, alignment: .trailing)
                Group {
                    if app.isApple && !app.fromAppStore {
                        Text("built in").font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                    } else {
                        Button("Remove…") { remove(app) }.buttonStyle(PlainButtonStyle())
                    }
                }
                .frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 10)
            .background(alignment: .bottom) { Hairline() }
        }
    }

    func scan() {
        Task.detached(priority: .userInitiated) {
            let found = AppScanner.discover(home: FileManager.default.homeDirectoryForCurrentUser)
            await MainActor.run {
                model.apps = found.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                model.appsSkipped = found.skippedGuarded
                model.appCount = model.apps?.filter { !$0.isOnSystemVolume }.count
            }
        }
    }

    func remove(_ app: AppInfo) {
        let plan: UninstallPlan
        do {
            plan = try AppUninstaller.plan(app, home: FileManager.default.homeDirectoryForCurrentUser, runningBundleIDs: runningBundleIDs())
        } catch UninstallError.running(let name) {
            note = "Quit \(name) first."
            return
        } catch {
            note = "\(app.name) can't be removed here (\(error))."
            return
        }
        guard
            confirm(
                "Remove \(app.name)?",
                "The app and \(plan.paths.count - 1) leftover items (\(formatBytes(plan.bytes))) move to the undo store.",
                action: "Remove")
        else { return }
        do {
            let batch = try AppUninstaller.run(plan, store: UndoStore())
            note = "Moved \(app.name) to the undo store (\(batch.id))."
            model.apps = nil
            scan()
        } catch {
            note = "Couldn't remove \(app.name): \(error.localizedDescription)"
        }
    }
}
