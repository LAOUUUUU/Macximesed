import AppKit
import MacxCore
import SwiftUI

/// Settings > Problems: make a bug report, see all of it, then copy, save or send it. Nothing leaves the Mac until
/// Send is pressed, and Send only appears once the relay and the maintainer's key are built in.
struct ReportPanel: View {
    @Bindable var model: AppModel
    @State private var description = ""
    @State private var keepFiles = false
    @State private var keepApps = false
    @State private var report: String?
    @State private var removed = 0
    @State private var building = false
    @State private var sending = false
    @State private var note: String?

    static let issues = URL(string: "https://github.com/LAOUUUUU/Macximesed/issues/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let crash = model.crashNote {
                Text(crash).font(Fonts.sans(14)).fixedSize(horizontal: false, vertical: true)
            }
            Text("What happened (optional)").font(Fonts.sans(13)).foregroundStyle(Ink.grey)
            TextEditor(text: $description)
                .font(Fonts.sans(13)).scrollContentBackground(.hidden).padding(6).frame(height: 64)
                .overlay(Rectangle().stroke(Ink.outline, lineWidth: 1))
                .onChange(of: description) { report = nil }
            HStack {
                Text("Keep file names in your folders").font(Fonts.sans(13))
                Spacer()
                TwoState(label: "Keep file names", isOn: keepFiles) { on in
                    keepFiles = on
                    report = nil
                }
            }
            HStack {
                Text("Keep app names").font(Fonts.sans(13))
                Spacer()
                TwoState(label: "Keep app names", isOn: keepApps) { on in
                    keepApps = on
                    report = nil
                }
            }
            HStack(spacing: 8) {
                Button(building ? "Making it…" : "Make the report") { build() }
                    .buttonStyle(PlainButtonStyle(kind: report == nil ? .primary : .secondary)).disabled(building)
                Button("Close") { close() }.buttonStyle(PlainButtonStyle())
            }
            if let report {
                Text("\(removed) personal details were taken out. This is everything that would be sent:")
                    .font(Fonts.sans(13)).foregroundStyle(Ink.grey)
                ScrollView {
                    Text(report).font(Fonts.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 260)
                .overlay(Rectangle().stroke(Ink.outline, lineWidth: 1))
                HStack(spacing: 8) {
                    Button("Copy") { copy(report) }.buttonStyle(PlainButtonStyle())
                    Button("Save…") { save(report) }.buttonStyle(PlainButtonStyle())
                    if ReportSending().isAvailable {
                        Button(sending ? "Sending…" : "Send") { send(report) }
                            .buttonStyle(PlainButtonStyle(kind: .primary)).disabled(sending)
                        InfoButton(
                            text:
                                "Encrypted on this Mac to the maintainer's key, so the relay in between can't read it. No name, email or ID of this Mac goes with it. Kept 90 days."
                        )
                    } else {
                        Text("Sending isn't set up in this version yet.").font(Fonts.sans(12)).foregroundStyle(Ink.grey)
                        Button("Open a GitHub issue") { NSWorkspace.shared.open(Self.issues) }.buttonStyle(PlainButtonStyle())
                        InfoButton(text: "GitHub issues are public and need an account. Paste the copied report there if you like.")
                    }
                }
            }
            if let note { Text(note).font(Fonts.sans(13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
    }

    func build() {
        building = true
        note = nil
        let (d, f, a) = (description, keepFiles, keepApps)
        Task.detached(priority: .userInitiated) {
            let made = ReportCollector.build(description: d, keepFileNames: f, keepProgramNames: a)
            await MainActor.run {
                report = made.text
                removed = made.redactions
                building = false
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Copied."
    }

    func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macx-report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            note = "Saved."
        } catch {
            note = "Couldn't save it: \(error.localizedDescription)"
        }
    }

    func send(_ text: String) {
        sending = true
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                let id = try ReportSending().send(text)
                Log.info("report", "sent from the app, report ID \(id)")
                outcome = "Sent. Report ID: \(id). Mention it in a GitHub issue if you'd like a reply, or to have it deleted."
            } catch {
                Log.warning("report", "sending from the app failed: \(error)")
                outcome = "Not sent: \(error)"
            }
            await MainActor.run {
                note = outcome
                sending = false
                if outcome.hasPrefix("Sent") { report = nil }
            }
        }
    }

    func close() {
        model.reportOpen = false
        model.crashNote = nil
    }
}
