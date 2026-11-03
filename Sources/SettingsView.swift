// SettingsView.swift. Settings: the same card rows as Memo, Nox and Awayke. Everything saves the moment it changes.
import AppKit
import SwiftUI

private let commonZones = [
    "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
    "America/Sao_Paulo", "Atlantic/Reykjavik", "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Athens", "Europe/Moscow",
    "Africa/Cairo", "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Shanghai", "Asia/Singapore",
    "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland",
]

enum SettingsTab: Int, CaseIterable, Identifiable {
    case look, modules, general, about
    var id: Int { rawValue }
    var title: String { ["Look", "What to watch", "General", "About"][rawValue] }
    var blurb: String {
        ["Light or dark, the menu bar icon, units and refresh", "Pick the tiles the panel shows", "Starting up and alerts", "What Stats costs your Mac"][rawValue]
    }
    var symbol: String { ["paintpalette.fill", "square.grid.2x2.fill", "gearshape.fill", "info.circle.fill"][rawValue] }
    var tint: Color { Pal.brand }   // every tab and page shares the app's graphite colour, so switching tabs never changes colour
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var monitor: Monitor
    @ObservedObject var nav: SettingsNav
    var scrolls = true
    var startTab: SettingsTab = .look
    let onLogin: (Bool) -> Void
    @State private var started = false
    @Namespace private var pillNS
    private var tab: SettingsTab { nav.tab }
    private func pill(_ id: String, inset: CGFloat = 0) -> NavPill { NavPill(nav: nav, id: id, ns: pillNS, inset: inset) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Pal.line).frame(width: 1)
            Group {
                if scrolls {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) { page }
                            .scrollBounceBehavior(.basedOnSize)
                            .onChange(of: nav.current) { _, id in
                                guard let id else { return }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("row-" + id, anchor: .center) } }
                            }
                    }
                } else { page }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: 780, height: scrolls ? 620 : nil)
        .background(Pal.panel)
        .onAppear { if !started { started = true; nav.tab = startTab } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stats").font(.system(size: 17, weight: .bold)).tracking(-0.3).foregroundStyle(Pal.ink)
                    Text("Settings").font(.system(size: 11)).foregroundStyle(Pal.mute)
                }
            }
            .padding(.bottom, 14).padding(.top, 6)
            ForEach(SettingsTab.allCases) { t in
                SidebarRow(tab: t, on: t == tab) { withAnimation(.easeOut(duration: 0.14)) { nav.tab = t; nav.current = nil } }
            }
            Spacer(minLength: 8)
            Text("Based on exelban/stats\nMIT licence").font(.system(size: 10.5)).foregroundStyle(Pal.mute).lineSpacing(3)
        }
        .padding(14)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Pal.box.opacity(0.45))
    }


    private var page: some View {
        VStack(alignment: .leading, spacing: 10) {
            banner(tab)
            switch tab {
            case .look: look
            case .modules: ForEach(ModuleID.allCases) { m in moduleCard(m) }
            case .general: general
            case .about: about
            }
        }
        .padding(20)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: nav.current)
        .id(tab)
    }

    private func banner(_ t: SettingsTab) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: t.symbol, tint: t.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(Pal.ink)
                Text(t.blurb).font(.system(size: 12)).foregroundStyle(Pal.mute)
            }
            Spacer()
            Text("\(t.rawValue + 1)/\(SettingsTab.allCases.count)").font(.mono(10.5, .medium)).foregroundStyle(Pal.mute)
        }
        .padding(.bottom, 6)
    }

    // MARK: Pages

    @ViewBuilder private var look: some View {
        let t = SettingsTab.look.tint
        SettingRow(symbol: "circle.lefthalf.filled", title: "Appearance", subtitle: "Light, dark, or follow your Mac", tint: t) {
            ChipRow(options: [0, 1, 2], selected: prefs.appearance, label: { ["Auto", "Light", "Dark"][$0] }, tint: t) { prefs.appearance = $0 }
        }
        .modifier(pill("appearance"))
        SettingRow(symbol: "paintbrush.pointed.fill", title: "Accent colour", subtitle: "Colours these Settings only. The panel and icons stay as they are.", tint: t) {
            AccentSwatches(selected: prefs.settingsAccent) { prefs.settingsAccent = $0 }
        }
        .modifier(pill("accent"))
        iconCard(t)
            .modifier(pill("icon"))
        pickerCard(symbol: "waveform.path.ecg", title: "Live graph shows", subtitle: "What the Live graph icon follows in the menu bar.", tint: t) {
            ChipRow(options: ModuleID.liveChoices, selected: prefs.iconSource, label: { $0.liveLabel }, tint: t) { prefs.iconSource = $0 }
        }
        .modifier(pill("iconsource"))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RowLabel(symbol: "circle.hexagongrid.fill", title: "Icon shows effort",
                         subtitle: "The menu bar icon changes colour with how hard your Mac is working.", tint: t)
                Spacer(minLength: 8)
                SmoothSwitch(isOn: prefs.iconTinted, title: "Icon shows effort", tint: t) { prefs.iconTinted = $0 }
            }
            HStack(spacing: 8) {
                effortSample("Calm", Pal.good)
                effortSample("Busy", Pal.warn)
                effortSample("Working hard", Pal.hard)
                effortSample("Hot or full", Pal.bad)
            }
            .opacity(prefs.iconTinted ? 1 : 0.5)
            .animation(.easeOut(duration: 0.2), value: prefs.iconTinted)
        }
        .padding(12)
        .tileStyle(t, radius: 14)
        .modifier(pill("icontint"))
        units
        updates
    }

    /// Every look the main menu bar icon can take, drawn by the real menu bar code so the picture is what you get.
    private func iconCard(_ t: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RowLabel(symbol: "menubar.rectangle", title: "Menu bar icon",
                     subtitle: "Pick how Stats shows up in the menu bar. Hidden keeps its place but draws nothing.", tint: t)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(MainIcon.allCases) { icon in
                    let on = prefs.mainIcon == icon
                    VStack(spacing: 6) {
                        Group {
                            if icon == .hidden {
                                Image(systemName: "eye.slash").font(.system(size: 14, weight: .medium)).foregroundStyle(Pal.mute)
                                    .frame(width: icon.width, height: 24)
                            } else if icon == .live {
                                // A proper graph picture: the live line only fills in after a minute of readings.
                                Image(systemName: "chart.xyaxis.line").font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(on ? Pal.panel : (prefs.iconTinted ? monitor.status.tint : Pal.ink))
                                    .frame(width: icon.width, height: 24)
                            } else {
                                MainIconPreview(icon: icon, values: monitor.iconSeries(prefs.iconSource), cpu: monitor.cpu.total,
                                                tint: prefs.iconTinted ? NSColor(monitor.status.tint) : nil)
                                    .frame(width: icon.width, height: 24)
                            }
                        }
                        .scaleEffect(1.25)
                        .frame(height: 30)
                        Text(icon.label).font(.system(size: 11, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Pal.panel : Pal.ink.opacity(0.85)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? t : Pal.box))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Color.clear : Pal.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { prefs.mainIcon = icon } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(icon.label) icon")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { prefs.mainIcon = icon }
                }
            }
        }
        .padding(12)
        .tileStyle(t, radius: 14)
    }

    @ViewBuilder private var updates: some View {
        pickerCard(symbol: "timer", title: "Refresh every", subtitle: "How often the menu bar numbers update. The open panel always updates every second.", tint: SettingsTab.look.tint) {
            NumberChipDrum(title: "Refresh", value: prefs.refresh, values: Array(1...60), presets: [1, 2, 3, 5, 10, 30],
                           tint: SettingsTab.look.tint, label: { $0 == 1 ? "1 second" : "\($0) seconds" }, short: { "\($0)" }) { prefs.refresh = $0 }
        }
        .modifier(pill("refresh"))
    }

    @ViewBuilder private var units: some View {
        let t = SettingsTab.look.tint
        SettingRow(symbol: "thermometer.medium", title: "Temperature", subtitle: "How warm things are shown", tint: t) {
            ChipRow(options: [false, true], selected: prefs.fahrenheit, label: { $0 ? "°F" : "°C" }, tint: t) { prefs.fahrenheit = $0 }
        }
        .modifier(pill("unit.temp"))
        SettingRow(symbol: "arrow.up.arrow.down", title: "Internet speed", subtitle: "Megabytes a second, or megabits a second", tint: t) {
            ChipRow(options: [false, true], selected: prefs.netBits, label: { $0 ? "Mbps" : "MB/s" }, tint: t) { prefs.netBits = $0 }
        }
        .modifier(pill("unit.speed"))
    }

    @ViewBuilder private var general: some View {
        let t = SettingsTab.general.tint
        SettingRow(symbol: "power", title: "Open at login", subtitle: "Start Stats when your Mac starts", tint: t) {
            SmoothSwitch(isOn: prefs.launchAtLogin, title: "Open at login", tint: t) { want in
                prefs.launchAtLogin = want
                DispatchQueue.main.async { onLogin(want) }
            }
        }
        .modifier(pill("login"))
        SettingRow(symbol: "bell.badge.fill", title: "Alerts", subtitle: "Tell me when the battery is low, storage is nearly full or memory is squeezed.", tint: Pal.rose) {
            SmoothSwitch(isOn: prefs.alerts, title: "Alerts", tint: Pal.rose) { prefs.alerts = $0 }
        }
        .modifier(pill("alerts"))
        SettingRow(symbol: "globe", title: "Internet checks", subtitle: "Show your public address and delay. Asks the internet, but only while the Internet tile is open.", tint: Pal.blue) {
            SmoothSwitch(isOn: prefs.internetChecks, title: "Internet checks", tint: Pal.blue) { prefs.internetChecks = $0 }
        }
        .modifier(pill("checks"))
    }

    /// A made-up minute of readings so the Live graph sample always looks like a graph.
    private static let sampleGraph: [Double] = [0.35, 0.5, 0.42, 0.66, 0.55, 0.78, 0.6, 0.7, 0.52, 0.64]

    /// The chosen menu bar icon drawn in one effort colour, with its name underneath.
    private func effortSample(_ label: String, _ colour: Color) -> some View {
        let icon = prefs.mainIcon == .hidden ? MainIcon.bars : prefs.mainIcon
        return VStack(spacing: 5) {
            MainIconPreview(icon: icon, values: Self.sampleGraph, cpu: 0.6, tint: NSColor(colour))
                .frame(width: icon.width, height: 22)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Pal.mute).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Pal.box))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): icon in this colour")
    }

    private func pickerCard<C: View>(symbol: String, title: String, subtitle: String, tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowLabel(symbol: symbol, title: title, subtitle: subtitle, tint: tint)
            content()
        }
        .padding(12)
        .tileStyle(tint, radius: 14)
    }

    private func moduleCard(_ m: ModuleID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RowLabel(symbol: m.symbol, title: m.title, subtitle: m.blurb, tint: m.tint)
                Spacer(minLength: 8)
                SmoothSwitch(isOn: prefs.shown.contains(m), title: "Show \(m.title)", tint: m.tint) { on in
                    if on { prefs.shown.insert(m) } else { prefs.shown.remove(m) }
                }
            }
            .modifier(pill("mod.\(m.rawValue).show", inset: 4))
            if m == .clock && prefs.shown.contains(.clock) { zones }
        }
        .padding(12)
        .tileStyle(m.tint, radius: 14)
    }

    private var zones: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(prefs.zones, id: \.self) { id in
                HStack {
                    Text(id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
                        .font(.system(size: 12)).foregroundStyle(Pal.ink)
                    Spacer()
                    Button { prefs.zones.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Pal.mute) }
                        .buttonStyle(.plain).help("Remove")
                }
            }
            Menu {
                ForEach(commonZones.filter { !prefs.zones.contains($0) }, id: \.self) { id in
                    Button(id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id) { prefs.zones.append(id) }
                }
            } label: { Label("Add a place", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var about: some View {
        let cpu = String(format: "%.1f%%", monitor.ownCPU * 100)
        let mem = Fmt.bytes(monitor.ownMemory)
        return Group {
            UpdateRow(updater: nav.updater, tint: SettingsTab.about.tint, ink: Pal.ink, mute: Pal.mute, track: Pal.box)
                .padding(12).cardStyle(radius: 14)
                .modifier(pill("update"))
            SettingRow(symbol: "gauge.with.dots.needle.33percent", title: "Stats uses \(cpu) of one core and \(mem)",
                       subtitle: "Measured right now, while this window is open", tint: SettingsTab.about.tint) {
                EmptyView()
            }
        }
    }
}

/// A square sample of a theme: its dark paper next to its accent colour.
struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: dyn(theme.panel.1, theme.panel.1)))
            Rectangle().fill(Color(nsColor: dyn(theme.accent.1, theme.accent.1)))
        }
        .frame(width: 44, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Pal.line, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Pal.ink, lineWidth: selected ? 2 : 0).padding(-4))
        .overlay(alignment: .bottom) { Text(theme.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.mute).fixedSize().offset(y: 18) }
        .padding(.bottom, 16)
        .scaleEffect(hover ? 1.04 : 1)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// The real menu bar drawing of one icon, shown in Settings so the picture matches the menu bar exactly.
struct MainIconPreview: NSViewRepresentable {
    let icon: MainIcon
    let values: [Double]
    let cpu: Double
    let tint: NSColor?
    func makeNSView(context: Context) -> BarView { BarView() }
    func updateNSView(_ v: BarView, context: Context) {
        var s = BarSnapshot(); s.values = values; s.fraction = cpu; s.value = Fmt.pct(cpu)
        v.icon = icon; v.snap = s; v.effortTint = tint
    }
}

/// One tab in the Settings sidebar. Hover looks the same as the panel's Settings and Quit buttons
/// (soft grey behind, darker text); the selected tab is outlined in the app's graphite colour, whichever tab it is.
private struct SidebarRow: View {
    let tab: SettingsTab
    let on: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let lit = on || hover
        return HStack(spacing: 9) {
            Image(systemName: tab.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Pal.brand : (hover ? Pal.ink : Pal.mute)).frame(width: 18)
            Text(tab.title).font(.system(size: 12.5, weight: on ? .semibold : .medium)).foregroundStyle(lit ? Pal.ink : Pal.mute)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(shape.fill(on ? Pal.card : (hover ? Pal.box : Color.clear)))
        .overlay(shape.strokeBorder(on ? Pal.brand.opacity(0.5) : Color.clear, lineWidth: 1))
        .contentShape(shape)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// Round colour swatches for the Settings accent. The ring slides to the chosen one with a spring.
private struct AccentSwatches: View {
    let selected: Int
    let choose: (Int) -> Void
    @Namespace private var ring

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsAccent.all.indices, id: \.self) { i in
                let a = SettingsAccent.all[i]
                ZStack {
                    if i == selected {
                        Circle().strokeBorder(Pal.ink.opacity(0.55), lineWidth: 2).matchedGeometryEffect(id: "ring", in: ring)
                    }
                    Circle().fill(Color(nsColor: dyn(a.light, a.dark))).padding(4)
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { choose(i) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(a.name) accent")
                .accessibilityAddTraits(i == selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { choose(i) }
            }
        }
    }
}
