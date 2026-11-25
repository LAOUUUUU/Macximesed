import MacxCore
import SwiftUI

/// The Risky tier on the Performance tab: folded away, in signal red, and three steps before anything changes
/// (what breaks, type the item's name, a last yes after 5 seconds). Runs `macx risky` through the password prompt.
struct RiskySection: View {
    @Bindable var model: AppModel
    @State private var open = false
    @State private var states: [RiskyItem: String] = [:]
    @State private var asking: RiskyItem?
    @State private var step = 1
    @State private var typed = ""
    @State private var countdown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    SectionLabel(text: "Risky").foregroundStyle(Ink.signal)
                    InfoButton(
                        text:
                            "System settings that give up a feature for a little speed, disk space or battery. Each one stores what it replaced and has an undo, except the snapshot purge. Never touches SIP, Gatekeeper, XProtect, FileVault or the firewall."
                    )
                    Spacer()
                    Button(open ? "Hide" : "Show") {
                        Motion.animate { open.toggle() }
                        if open { load() }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.top, 28).padding(.bottom, 6)
                Hairline(color: Ink.signal)
            }
            if open {
                ForEach(Risky.catalog, id: \.item) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).font(Fonts.sans(13.5))
                            Text(i.breaks).font(Fonts.sans(12)).foregroundStyle(Ink.grey).fixedSize(horizontal: false, vertical: true)
                            Text(states[i.item] ?? "…").font(Fonts.mono(11)).foregroundStyle(Ink.grey)
                        }
                        Spacer()
                        if states[i.item] == "changed by macx" {
                            Button("Undo") { undo(i.item) }.buttonStyle(PlainButtonStyle()).disabled(model.busy)
                        } else if states[i.item] == "not changed" || (i.item == .snapshots && states[i.item]?.hasSuffix("s") == true) {
                            Button("Turn on…") { ask(i.item) }.buttonStyle(PlainButtonStyle(kind: .danger)).disabled(model.busy)
                        }
                    }
                    .padding(.vertical, 9)
                    .background(alignment: .bottom) { Hairline() }
                }
                .transition(.opacity)
            }
        }
        .sheet(item: Binding(get: { asking.map(Asked.init) }, set: { if $0 == nil { asking = nil } })) { a in
            confirm(a.item).frame(width: 440).padding(28)
        }
    }

    struct Asked: Identifiable {
        let item: RiskyItem
        var id: String { item.rawValue }
    }

    func confirm(_ item: RiskyItem) -> some View {
        let info = Risky.info(item)
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(step) of 3 · \(info.title)").font(Fonts.mono(11.5)).foregroundStyle(Ink.signal)
            switch step {
            case 1:
                Text(info.does).font(Fonts.sans(13))
                Text("Breaks: \(info.breaks)").font(Fonts.sans(13)).foregroundStyle(Ink.signal)
                if !info.undoable { Text("This one can't be undone.").font(Fonts.sans(13)).bold() }
            case 2:
                Text("Type \(item.rawValue) to confirm.").font(Fonts.sans(13))
                TextField(item.rawValue, text: $typed).textFieldStyle(.roundedBorder)
            default:
                Text(countdown > 0 ? "Last chance in \(countdown)…" : "Last chance. macOS will ask for your password.").font(Fonts.sans(13))
            }
            HStack {
                Spacer()
                Button("Cancel") { asking = nil }.buttonStyle(PlainButtonStyle()).keyboardShortcut(.cancelAction)
                Button(step < 3 ? "Continue" : "Do it") { next(item) }
                    .buttonStyle(PlainButtonStyle(kind: .danger))
                    .disabled((step == 2 && !Risky.confirms(item, typed: typed)) || (step == 3 && countdown > 0))
            }
        }
    }

    func ask(_ item: RiskyItem) {
        step = 1
        typed = ""
        countdown = 5
        asking = item
    }

    func next(_ item: RiskyItem) {
        if step < 3 {
            step += 1
            if step == 3 {
                Task {
                    while countdown > 0, asking == item {
                        try? await Task.sleep(for: .seconds(1))
                        countdown -= 1
                    }
                }
            }
            return
        }
        asking = nil
        model.runAdmin(["risky", "apply", item.rawValue, "--confirmed-in-app"], why: "change \(Risky.info(item).title.lowercased())") {
            load()
        }
    }

    func undo(_ item: RiskyItem) {
        model.runAdmin(["risky", "undo", item.rawValue], why: "put back \(Risky.info(item).title.lowercased())") { load() }
    }

    func load() {
        Task.detached(priority: .utility) {
            let ledger = RiskyLedger.load()
            var out: [RiskyItem: String] = [:]
            for i in RiskyItem.allCases { out[i] = Risky.state(i, ledger: ledger) }
            await MainActor.run { states = out }
        }
    }
}
