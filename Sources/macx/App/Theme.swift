import AppKit
import MacxCore
import SwiftUI

/// The app's colours and type (research/app-ui/RESEARCH.md, "Visual direction"). Every colour has a light and a
/// dark value and follows the system appearance; Increase Contrast turns hairlines into ink.
enum Ink {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastDarkAqua]) != .aqua
                return NSColor(hex: isDark ? dark : light)
            })
    }

    static let paper = dynamic(0xF3F1EC, 0x141413)
    static let side = dynamic(0xECE9E2, 0x191917)
    static let raised = dynamic(0xFBFAF7, 0x1F1E1C)
    static let selected = dynamic(0xE1DDD3, 0x232220)
    static let rowOpen = dynamic(0xEAE6DD, 0x1F1E1C)
    static let text = dynamic(0x1B1B19, 0xE9E7E1)
    static let grey = dynamic(0x5F5D58, 0x9D9A93)
    static let signal = dynamic(0xB3261E, 0xE8705C)
    static let paused = dynamic(0x8A5A00, 0xD9A441)

    static var line: Color {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? text : dynamic(0xD9D5CC, 0x2F2E2B)
    }
    static var outline: Color {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? text : dynamic(0xB9B4A9, 0x4A4945)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// New York for sentences of state, SF Pro for text, SF Mono for anything technical. Sizes scale with the
/// user's preferred text size (Settings > Accessibility > Display > Text size).
enum Fonts {
    static var scale: CGFloat { max(0.85, min(1.6, NSFont.preferredFont(forTextStyle: .body).pointSize / 13)) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size * scale, weight: weight, design: .serif)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * scale, weight: weight) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size * scale, design: .monospaced) }
}

/// Small capitals, spaced: section labels only.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(Fonts.sans(11.5, .medium).lowercaseSmallCaps()).tracking(1.3).foregroundStyle(Ink.grey)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Hairline: View {
    var color: Color = Ink.line
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// Plain rectangular buttons: filled ink for the one main action, an outline for the rest.
struct PlainButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.sans(12.5))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(kind == .primary ? Ink.paper : (kind == .danger ? Ink.signal : Ink.text))
            .background(kind == .primary ? Ink.text : Color.clear)
            .overlay(Rectangle().stroke(kind == .primary ? Ink.text : Ink.outline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// A two-part On | Off control, square, not a pill.
struct TwoState: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            part("On", selected: isOn) { set(true) }
            part("Off", selected: !isOn) { set(false) }
        }
        .overlay(Rectangle().stroke(Ink.outline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAdjustableAction { _ in set(!isOn) }
    }

    func part(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Fonts.sans(12)).padding(.horizontal, 12).frame(height: 24)
                .foregroundStyle(selected ? Ink.paper : Ink.grey)
                .background(selected ? Ink.text : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Severity as a word and a shape as well as a colour: filled square for critical, outlined for high and medium,
/// a dash for low.
struct SeverityMark: View {
    let severity: Severity
    var body: some View {
        Group {
            switch severity {
            case .critical: Rectangle().fill(Ink.signal).frame(width: 7, height: 7)
            case .high: Rectangle().strokeBorder(Ink.signal, lineWidth: 1.5).frame(width: 7, height: 7)
            case .medium: Rectangle().strokeBorder(Ink.grey, lineWidth: 1.5).frame(width: 7, height: 7)
            case .low, .info: Rectangle().fill(Ink.grey).frame(width: 7, height: 1.5)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}

struct SeverityWord: View {
    let severity: Severity
    var body: some View {
        HStack(spacing: 8) {
            SeverityMark(severity: severity)
            Text(Self.word(severity))
                .font(Fonts.sans(13, severity == .critical ? .semibold : .regular))
                .foregroundStyle(severity >= .high ? Ink.signal : (severity == .medium ? Ink.text : Ink.grey))
        }
    }

    static func word(_ s: Severity) -> String { String(describing: s).capitalized }
}

/// Helper text lives behind this: an outlined ⓘ that opens a small panel on click, with the same text as a
/// tooltip. The screen keeps only the facts.
struct InfoButton: View {
    let text: String
    var detail: String?
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            InfoGlyph().frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.grey)
        .help(text)
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        .overlay(alignment: .topLeading) {
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(Fonts.sans(12)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(Fonts.mono(11)).foregroundStyle(Ink.grey).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(width: 300, alignment: .leading)
                .background(Ink.raised)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.outline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
                .offset(x: -10, y: 28)
                .onTapGesture { open = false }
                .onExitCommand { open = false }
                .zIndex(10)
            }
        }
        .zIndex(open ? 10 : 0)
    }
}

struct InfoGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(x: (size.width - 13) / 2, y: (size.height - 13) / 2, width: 13, height: 13)
            ctx.stroke(Path(ellipseIn: r), with: .foreground, lineWidth: 1.2)
            var stem = Path()
            stem.move(to: CGPoint(x: r.midX, y: r.minY + 5.5))
            stem.addLine(to: CGPoint(x: r.midX, y: r.minY + 9.8))
            ctx.stroke(stem, with: .foreground, lineWidth: 1.3)
            ctx.fill(Path(ellipseIn: CGRect(x: r.midX - 0.85, y: r.minY + 2.6, width: 1.7, height: 1.7)), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// The page header every screen shares: a small-caps label, a sentence of state, and its actions.
struct PageHeader<Actions: View>: View {
    let label: String
    let headline: String
    var sentence: String?
    var headlineColor: Color = Ink.text
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: label)
                    Text(headline).font(Fonts.serif(34)).tracking(-0.4).foregroundStyle(headlineColor)
                        .accessibilityAddTraits(.isHeader)
                    if let sentence {
                        Text(sentence).font(Fonts.sans(14)).foregroundStyle(Ink.grey).frame(maxWidth: 580, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions() }
            }
            .padding(.horizontal, 48).padding(.top, 56).padding(.bottom, 28)
            Hairline()
        }
    }
}

extension ByteCountFormatter {
    static func file(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
