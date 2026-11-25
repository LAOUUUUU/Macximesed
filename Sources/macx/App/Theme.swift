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

    func makeBody(configuration: Configuration) -> some View {
        Styled(kind: kind, configuration: configuration)
    }

    struct Styled: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var over = false

        var body: some View {
            configuration.label
                .font(Fonts.sans(12.5))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(kind == .primary ? Ink.paper : (kind == .danger ? Ink.signal : Ink.text))
                .background(kind == .primary ? Ink.text : (over && enabled ? Ink.rowOpen : Color.clear))
                .overlay(Rectangle().stroke(kind == .primary ? Ink.text : (over && enabled ? Ink.text : Ink.outline), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
                .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.97 : 1)
                .motion(Motion.quick, value: configuration.isPressed)
                .motion(Motion.quick, value: over)
                .contentShape(Rectangle())
                .onHover { over = $0 }
        }
    }
}

/// A two-part On | Off control, square, not a pill.
struct TwoState: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void
    @Namespace private var ink

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
        .motion(Motion.settle, value: isOn)
    }

    func part(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Fonts.sans(12)).padding(.horizontal, 12).frame(height: 24)
                .foregroundStyle(selected ? Ink.paper : Ink.grey)
                .background {
                    if selected { Rectangle().fill(Ink.text).matchedGeometryEffect(id: "ink", in: ink) }
                }
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
        // A real popover: its own window above the page, fully opaque, so nothing on the page can show through it
        // or be drawn over it (the old in-page panel let later rows paint on top).
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(Fonts.sans(12)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Fonts.mono(11)).foregroundStyle(Ink.grey).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(width: 320, alignment: .leading)
            .background(Ink.raised)
        }
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
                        .contentTransition(.opacity)
                        .motion(value: headline)
                        .accessibilityAddTraits(.isHeader)
                    if let sentence {
                        Text(sentence).font(Fonts.sans(14)).foregroundStyle(Ink.grey).frame(maxWidth: 580, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .motion(value: sentence)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions() }
            }
            .padding(.horizontal, 48).padding(.top, 56).padding(.bottom, 28)
            .reveal(rise: 4)
            Hairline()
        }
    }
}

// MARK: - Motion

/// One set of timings for every animation in the app: quick and quiet, ink settling on paper. All of it stops
/// when System Settings > Accessibility > Display > Reduce motion is on.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeOut(duration: 0.24)
    static let page = Animation.easeOut(duration: 0.28)
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.88)
    /// The gap between rows easing in one after another, and the most rows that wait for their turn.
    static let stagger = 0.03
    static let maxStaggered = 12

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// withAnimation, or no animation when Reduce motion is on.
    static func animate(_ animation: Animation = standard, _ change: () -> Void) {
        if reduced { change() } else { withAnimation(animation, change) }
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce motion.
    func motion<V: Equatable>(_ animation: Animation = Motion.standard, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Eases in on first appearance: up a few points and from transparent, rows one after another.
    func reveal(_ order: Int = 0, rise: CGFloat = 6) -> some View { modifier(Reveal(order: order, rise: rise)) }
}

struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

struct Reveal: ViewModifier {
    let order: Int
    let rise: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : rise)
            .onAppear {
                guard !shown, !reduceMotion, order <= Motion.maxStaggered else {
                    shown = true
                    return
                }
                withAnimation(Motion.standard.delay(Double(min(order, Motion.maxStaggered)) * Motion.stagger)) { shown = true }
            }
    }
}

/// The watch is live: a small filled square whose ink breathes slowly. No glow; still when Reduce motion is on.
/// Drawn with Core Animation, which runs in the render server: a SwiftUI repeating animation re-ran the whole
/// window's layout every frame (about 40% CPU while idle).
struct LiveMark: View {
    var color: Color = Ink.text
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LayerAnimation(kind: .pulse, color: NSColor(color), still: reduceMotion).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Work in progress as a hairline with a short ink segment travelling along it, instead of a spinner (Core Animation too).
struct HairlineProgress: View {
    var width: CGFloat = 180
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LayerAnimation(kind: .travel, color: NSColor(Ink.text), track: NSColor(Ink.line), still: reduceMotion)
            .frame(width: width, height: 1.5)
            .accessibilityLabel("Working")
    }
}

/// A layer-backed view whose animation lives in Core Animation, so SwiftUI does no work per frame.
struct LayerAnimation: NSViewRepresentable {
    enum Kind { case pulse, travel }
    let kind: Kind
    let color: NSColor
    var track: NSColor? = nil
    let still: Bool

    func makeNSView(context: Context) -> AnimatedLayerView {
        let v = AnimatedLayerView()
        v.configure(kind: kind, color: color, track: track, still: still)
        return v
    }

    func updateNSView(_ v: AnimatedLayerView, context: Context) { v.configure(kind: kind, color: color, track: track, still: still) }
}

final class AnimatedLayerView: NSView {
    private var kind: LayerAnimation.Kind = .pulse
    private var color: NSColor = .black
    private var track: NSColor?
    private var still = false
    private let segment = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(segment)
    }

    required init?(coder: NSCoder) { nil }

    func configure(kind: LayerAnimation.Kind, color: NSColor, track: NSColor?, still: Bool) {
        let changed = kind != self.kind || still != self.still
        self.kind = kind
        self.color = color
        self.track = track
        self.still = still
        applyColors()
        if changed { restart() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        segment.frame = kind == .pulse ? b : CGRect(x: 0, y: 0, width: b.width * 0.28, height: b.height)
        CATransaction.commit()
        restart()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            segment.backgroundColor = color.cgColor
            layer?.backgroundColor = kind == .travel ? track?.cgColor : nil
        }
    }

    private func restart() {
        segment.removeAllAnimations()
        guard !still, bounds.width > 0 else {
            if kind == .travel { segment.position = CGPoint(x: bounds.midX, y: bounds.midY) }
            return
        }
        let a: CABasicAnimation
        switch kind {
        case .pulse:
            a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 1.6
            a.autoreverses = true
        case .travel:
            a = CABasicAnimation(keyPath: "position.x")
            let w = segment.bounds.width
            a.fromValue = -w / 2
            a.toValue = bounds.width + w / 2
            a.duration = 1.1
        }
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        segment.add(a, forKey: "motion")
    }
}

/// Rows that answer the pointer: a soft fill on hover, a little deeper when pressed.
struct HoverRow<Content: View>: View {
    var pressed = false
    @ViewBuilder let content: () -> Content
    @State private var over = false

    var body: some View {
        content()
            .background(pressed ? Ink.selected : (over ? Ink.rowOpen : Color.clear))
            .motion(Motion.quick, value: over)
            .onHover { over = $0 }
    }
}
