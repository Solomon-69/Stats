// Intro.swift. The welcome window shown once after installing Stats: what it is, what the menu bar icon can be,
// and how to open Stats again. Three pages, skippable, springs throughout.
import SwiftUI

enum IntroPref {
    static let done = "introDone"
}

/// Each element of a page rises in a little after the one above it.
struct IntroRise: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .blur(radius: shown || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? .easeOut(duration: 0.2)
                       : .spring(response: 0.55, dampingFraction: 0.84).delay(0.08 + Double(index) * 0.07), value: shown)
    }
}

extension View {
    func introRise(_ index: Int, _ shown: Bool) -> some View { modifier(IntroRise(index: index, shown: shown)) }
}

struct IntroView: View {
    @ObservedObject var prefs: Prefs
    let finish: (_ openPanel: Bool) -> Void
    @State private var page: Int
    @State private var shown = false
    @State private var seen: Set<Int> = [0]     // pages whose rise-in already played; it never replays
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let pages = 3

    init(prefs: Prefs, page: Int = 0, finish: @escaping (_ openPanel: Bool) -> Void) {
        self.prefs = prefs; self.finish = finish
        _page = State(initialValue: page)
        _seen = State(initialValue: [page])
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: welcome.transition(slide)
                case 1: iconPage.transition(slide)
                default: ready.transition(slide)
                }
            }
            .padding(.vertical, 10)
            .frame(height: 392, alignment: .top)
            .clipped()
            footer
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Pal.panel))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Pal.line, lineWidth: 1))
        .padding(16)
        .frame(width: 456)
        .background(Pal.box.ignoresSafeArea())
        .foregroundStyle(Pal.ink)
        .onAppear { shown = true }
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                          removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).antialiased(true).frame(width: 92, height: 92)
                .shadow(color: Pal.brand.opacity(0.35), radius: 16, y: 8)
                .scaleEffect(shown || reduceMotion ? 1 : 0.55)
                .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.6).delay(0.05), value: shown)
                .introRise(0, shown)
            Text("Welcome to Stats").font(.system(size: 24, weight: .semibold, design: .rounded)).introRise(1, shown)
            Text("See how your Mac is doing, at a glance.").font(.system(size: 13)).foregroundStyle(Pal.mute).introRise(2, shown)
            VStack(spacing: 8) {
                feature("cpu", "Click the icon in the menu bar", "A panel opens with processor, memory, storage and more.").introRise(3, shown)
                feature("waveform.path.ecg", "Live and calm", "Numbers update gently, and only while you look.").introRise(4, shown)
                feature("lock.fill", "Stays on your Mac", "Nothing is ever uploaded. No account needed.").introRise(5, shown)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconPage: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "menubar.rectangle", tint: Pal.brand, size: 64).introRise(0, shown)
            Text("Pick your menu bar icon").font(.system(size: 22, weight: .semibold, design: .rounded)).introRise(1, shown)
            Text("Choose how Stats looks up there. You can change it any time in Settings.")
                .font(.system(size: 13)).foregroundStyle(Pal.mute).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).introRise(2, shown)
            HStack(spacing: 8) {
                ForEach(Array(MainIcon.allCases.enumerated()), id: \.element.id) { i, icon in
                    let on = prefs.mainIcon == icon
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { prefs.mainIcon = icon } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: Self.symbol(icon)).font(.system(size: 18, weight: .medium)).frame(height: 22)
                            Text(icon.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(on ? Pal.panel : Pal.ink)
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Pal.ink : Pal.card))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Pal.line, lineWidth: 1))
                    }
                    .buttonStyle(IntroPressStyle())
                    .introRise(3 + i, shown)
                }
            }
            if prefs.mainIcon == .hidden {
                Text("Hidden means no icon at all. Open Stats again from Spotlight or Finder and Settings opens.")
                    .font(.system(size: 11)).foregroundStyle(Pal.mute).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: prefs.mainIcon)
    }

    private var ready: some View {
        VStack(spacing: 12) {
            IconTile(symbol: "checkmark", tint: Pal.brand, size: 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.5)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55), value: shown)
                .introRise(0, shown)
            Text("You're all set").font(.system(size: 24, weight: .semibold, design: .rounded)).introRise(1, shown)
            VStack(spacing: 8) {
                feature("cursorarrow.click", "Click the icon any time", "Tap a tile for the details behind it.").introRise(2, shown)
                feature("slider.horizontal.3", "Make it yours", "Choose what to watch, units and colours in Settings.").introRise(3, shown)
                feature("power", "Start with your Mac", "Turn on Open at login in Settings > General.").introRise(4, shown)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    static func symbol(_ i: MainIcon) -> String {
        switch i {
        case .bars: "chart.bar.fill"
        case .chip: "cpu"
        case .pulse: "waveform.path.ecg"
        case .live: "chart.xyaxis.line"
        case .hidden: "eye.slash"
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: Pal.brand, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Pal.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .cardStyle()
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if page < Self.pages - 1 {
                IntroQuietLink(title: "Skip") { finish(false) }
            } else {
                IntroQuietLink(title: "Back") { go(page - 1) }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.pages, id: \.self) { i in
                    Capsule().fill(i == page ? Pal.ink : Pal.mute.opacity(0.35))
                        .frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: page)
            Spacer()
            Button { page < Self.pages - 1 ? go(page + 1) : finish(true) } label: {
                Text(page < Self.pages - 1 ? "Continue" : "Open Stats")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.panel)
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(Capsule().fill(Pal.ink))
            }
            .buttonStyle(IntroPressStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ p: Int) {
        guard (0..<Self.pages).contains(p) else { return }
        forward = p > page
        let first = !seen.contains(p)
        seen.insert(p)
        if first { shown = false }                  // only a page seen for the first time rises in
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)) { page = p }
        if first { DispatchQueue.main.async { shown = true } }
    }
}

struct IntroPressStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hover ? 0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// Skip / Back: a plain tappable label, so macOS never draws a keyboard focus box around it.
struct IntroQuietLink: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(hover ? Pal.ink : Pal.mute)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Pal.box.opacity(hover ? 1 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
    }
}
