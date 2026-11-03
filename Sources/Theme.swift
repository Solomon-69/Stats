// Theme.swift. Soft telemetry: rounded cards on a dark or paper base, one accent per theme, mono numbers.
import AppKit
import SwiftUI

/// One colour theme: a warm or cool paper colour, a card colour, text colours and one accent. Each has a light and a dark shade.
struct Theme: Identifiable {
    let id: Int
    let name: String
    let panel, card, box, edge, ink, mute, accent: (UInt32, UInt32)
}

enum ThemeStore {
    static let all: [Theme] = [
        Theme(id: 0, name: "Telemetry", panel: (0xF4F4F0, 0x0A0A0A), card: (0xFBFBF8, 0x111111), box: (0xE9E8E3, 0x1B1B1B),
              edge: (0x1A1A1A, 0x2E2E2E), ink: (0x0B0B0B, 0xEAEAEA), mute: (0x575752, 0x8A8A8A), accent: (0xE61919, 0xFF2A2A)),
        Theme(id: 1, name: "Acid", panel: (0xF2F4EC, 0x111314), card: (0xFAFBF6, 0x171A1C), box: (0xE5E9DC, 0x202427),
              edge: (0x1D2412, 0x2A3033), ink: (0x111418, 0xE8ECEF), mute: (0x555F4C, 0x7D878F), accent: (0x4D8A00, 0xA3E635)),
        Theme(id: 2, name: "Amber CRT", panel: (0xF5F0E3, 0x0D0B07), card: (0xFBF7EA, 0x15120C), box: (0xEBE4D0, 0x211C12),
              edge: (0x2A2415, 0x3A3220), ink: (0x1F1A0F, 0xF2E4C0), mute: (0x625841, 0xA39368), accent: (0xC27C00, 0xFFB000)),
        Theme(id: 3, name: "Cyan HUD", panel: (0xEEF4F6, 0x081014), card: (0xF8FCFD, 0x0E181D), box: (0xDFEAEE, 0x162429),
              edge: (0x14323B, 0x1E3944), ink: (0x0C1A20, 0xDDF3F8), mute: (0x46606B, 0x7FA3B0), accent: (0x007FA3, 0x35E0FF)),
        Theme(id: 4, name: "Mono", panel: (0xF1F1F1, 0x141414), card: (0xFAFAFA, 0x1B1B1B), box: (0xE4E4E4, 0x262626),
              edge: (0x222222, 0x333333), ink: (0x111111, 0xEDEDED), mute: (0x585858, 0x999999), accent: (0x111111, 0xF5F5F5)),
    ]
    static var current: Theme = all[0]
    /// false = every icon tile uses the theme accent instead of its own colour.
    static var colourfulTiles = true
}

enum Pal {
    private static func c(_ p: (UInt32, UInt32)) -> Color { Color(nsColor: dyn(p.0, p.1)) }
    static var panel: Color { c(ThemeStore.current.panel) }
    static var card: Color { c(ThemeStore.current.card) }
    static var box: Color { c(ThemeStore.current.box) }
    static var edge: Color { c(ThemeStore.current.edge) }
    static var ink: Color { c(ThemeStore.current.ink) }
    static var mute: Color { c(ThemeStore.current.mute) }
    static var accent: Color { c(ThemeStore.current.accent) }
    /// Card outline: clear in dark, whisper-thin in light.
    static var line: Color {
        let e = ThemeStore.current.edge
        return Color(nsColor: NSColor(name: nil) { ap in
            let dark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = dark ? e.1 : e.0
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: dark ? 0.95 : 0.13)
        })
    }
    /// Companion colours so no screen is one flat colour: second chart line, section colours in Settings.
    static let second = Color(nsColor: dyn(0xE58A3A, 0xF2A25C))
    /// The Settings accent (graphite by default, matching the icon). Only the Settings screens use it.
    static var brand: Color { let a = SettingsAccent.all[SettingsAccent.current]; return Color(nsColor: dyn(a.light, a.dark)) }
    static let violet = Color(nsColor: dyn(0x8A6FD0, 0xA58BE8))
    static let blue = Color(nsColor: dyn(0x5B86D6, 0x7EA3EA))
    static let teal = Color(nsColor: dyn(0x3FA48F, 0x58C2AB))
    static let green = Color(nsColor: dyn(0x4F9D69, 0x66BB82))
    static let rose = Color(nsColor: dyn(0xD1495B, 0xEA6678))
    static let amber = Color(nsColor: dyn(0xC9A227, 0xE0BA3F))
    static let slate = Color(nsColor: dyn(0x6B7684, 0x9AA5B4))
    static let good = Color(nsColor: dyn(0x4F9D69, 0x66BB82))
    static let bad = Color(nsColor: dyn(0xD1495B, 0xEA6678))
    static let warn = Color(nsColor: dyn(0xC9A227, 0xE0BA3F))
    static let hard = Color(nsColor: dyn(0xD9702A, 0xF08A47))
}

let panelSpring = Animation.spring(duration: 0.42, bounce: 0.18)

struct CardStyle: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Pal.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Pal.line, lineWidth: 1))
    }
}

/// A rounded card with a hairline edge.
struct TileStyle: ViewModifier {
    let tint: Color
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content.modifier(CardStyle(radius: radius))
    }
}

extension Font {
    /// Technical labels and numbers: monospaced.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension View {
    /// Small spaced capital label, like a stamp on a machine plate.
    func plate(_ size: CGFloat = 10.5) -> some View { self.font(.mono(size, .medium)).tracking(0.6) }
}

extension View {
    func tileStyle(_ tint: Color, radius: CGFloat = 14) -> some View { modifier(TileStyle(tint: tint, radius: radius)) }
    func cardStyle(radius: CGFloat = 16) -> some View { modifier(CardStyle(radius: radius)) }
    func entrance(index: Int, trigger: Int) -> some View { modifier(Entrance(index: index, trigger: trigger)) }
}

/// Cards rise in one after another each time the panel opens.
struct Entrance: ViewModifier {
    let index: Int
    let trigger: Int
    @State private var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // The spring is scoped to the fade and lift only. A withAnimation here also animated the popover's first layout,
        // so on opening the whole panel could slide in from the top-left corner.
        content
            .animation(shown ? .spring(response: 0.42, dampingFraction: 0.8).delay(0.03 + Double(index) * 0.025) : nil) {
                $0.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
            }
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion, index < 12 else { return }
                shown = false
                DispatchQueue.main.async { shown = true }
            }
    }
}

/// A rounded coloured tile with a white symbol.
struct IconTile: View {
    let symbol: String
    var tint: Color = Pal.accent
    var size: CGFloat = 32
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(tint))
    }
}

struct RowLabel: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = Pal.accent
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Pal.ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Pal.mute).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = Pal.accent
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(spacing: 10) {
            RowLabel(symbol: symbol, title: title, subtitle: subtitle, tint: tint)
            Spacer(minLength: 8)
            control()
        }
        .padding(12)
        .tileStyle(tint)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Pal.ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Pal.box.opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Pal.line, lineWidth: 1))
            .animation(.easeOut(duration: 0.14), value: hover)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// A small row of choices (like Off / Numbers / Graph). One is selected.
struct ChipRow<T: Hashable>: View {
    let options: [T]
    let selected: T
    let label: (T) -> String
    var tint: Color = Pal.accent
    let onPick: (T) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                // Picked: panel-coloured text on the Settings accent, which keeps AA contrast in light and dark.
                let fill: Color = on ? tint : Pal.box
                let ink: Color = on ? Pal.panel : Pal.ink
                Text(label(o))
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? Color.clear : Pal.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onTapGesture { if !on { onPick(o) } }
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: on)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label(o))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onPick(o) }
            }
        }
    }
}

/// Accent colours for the Settings screens (light shade, dark shade). Selected chips and tabs put the panel colour on top,
/// and each pair keeps WCAG AA contrast for that text: at least 4.9 to 1 in light and 5.8 to 1 in dark.
enum SettingsAccent {
    static let all: [(name: String, light: UInt32, dark: UInt32)] = [
        ("Graphite", 0x454952, 0xC5C9D2), ("Blue", 0x2160C4, 0x82B1F2), ("Teal", 0x0B7268, 0x4FD1C0),
        ("Orchid", 0xB0307F, 0xE25AA4), ("Orange", 0xB04A0A, 0xF59A4A),
    ]
    static var current = 0
    static func clamp(_ i: Int) -> Int { min(max(i, 0), all.count - 1) }
}
