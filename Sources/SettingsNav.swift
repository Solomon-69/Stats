// SettingsNav.swift. Keyboard control of the Settings window: Up/Down walk a highlighted row through every setting
// (across all pages, wrapping), Left/Right or Space/Return change it, Esc steps back. The window only forwards keys;
// the test hook calls the same `key(_:)`.
import Foundation
import SwiftUI

@MainActor final class SettingsNav: ObservableObject {
    enum Key { case up, down, left, right, activate, back }
    struct Row { let id: String; let tab: SettingsTab }

    @Published var tab: SettingsTab = .look
    @Published var current: String?
    let prefs: Prefs
    let updater = AppUpdater(UpdateConfig(repo: "Solomon-69/Stats", appName: "Stats", bundleName: "Stats.app", zipName: "Stats-mac.zip"))
    var onLogin: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let spring = Animation.spring(response: 0.34, dampingFraction: 0.82)

    init(prefs: Prefs) { self.prefs = prefs }

    /// Every setting in the order the pages show them.
    var rows: [Row] {
        var r: [Row] = [Row(id: "appearance", tab: .look), Row(id: "accent", tab: .look), Row(id: "icon", tab: .look), Row(id: "iconsource", tab: .look), Row(id: "icontint", tab: .look),
                       Row(id: "unit.temp", tab: .look), Row(id: "unit.speed", tab: .look), Row(id: "refresh", tab: .look)]
        for m in ModuleID.allCases {
            r.append(Row(id: "mod.\(m.rawValue).show", tab: .modules))
            if m.barStyles.count > 1 { r.append(Row(id: "mod.\(m.rawValue).style", tab: .modules)) }
        }
        r += [Row(id: "login", tab: .general), Row(id: "alerts", tab: .general), Row(id: "checks", tab: .general)]
        r.append(Row(id: "update", tab: .about))
        return r
    }

    func key(_ k: Key) {
        switch k {
        case .down: move(1)
        case .up: move(-1)
        case .left: if let c = current { adjust(c, -1) }
        case .right: if let c = current { adjust(c, 1) }
        case .activate: if let c = current { adjust(c, 1, activate: true) }
        case .back:
            if current != nil { withAnimation(spring) { current = nil } } else { onClose() }
        }
    }

    private func move(_ d: Int) {
        let all = rows
        let next: Row
        if let c = current, let i = all.firstIndex(where: { $0.id == c }) {
            next = all[(i + d + all.count) % all.count]
        } else {
            let here = all.filter { $0.tab == tab }
            guard let pick = d > 0 ? here.first : here.last else { return }
            next = pick
        }
        withAnimation(spring) { current = next.id; tab = next.tab }
    }

    private func step<T: Equatable>(_ all: [T], _ cur: T, _ d: Int) -> T {
        guard let i = all.firstIndex(of: cur), !all.isEmpty else { return all.first ?? cur }
        return all[(i + d + all.count) % all.count]
    }

    private func adjust(_ id: String, _ d: Int, activate: Bool = false) {
        switch id {
        case "appearance": prefs.appearance = step([0, 1, 2], prefs.appearance, d)
        case "accent": prefs.settingsAccent = step(Array(SettingsAccent.all.indices), prefs.settingsAccent, d)
        case "theme": prefs.themeIndex = step(Array(ThemeStore.all.indices), min(prefs.themeIndex, ThemeStore.all.count - 1), d)
        case "icon": prefs.mainIcon = step(MainIcon.allCases, prefs.mainIcon, d)
        case "iconsource": prefs.iconSource = step(ModuleID.liveChoices, prefs.iconSource, d)
        case "icontint": prefs.iconTinted.toggle()
        case "refresh": prefs.refresh = min(60, max(1, prefs.refresh + d))
        case "unit.temp": prefs.fahrenheit.toggle()
        case "unit.speed": prefs.netBits.toggle()
        case "login": prefs.launchAtLogin.toggle(); onLogin(prefs.launchAtLogin)
        case "alerts": prefs.alerts.toggle()
        case "checks": prefs.internetChecks.toggle()
        case "update":
            guard activate else { return }
            if case .available = updater.state { Task { await updater.install() } } else { Task { await updater.check() } }
        default:
            let p = id.split(separator: ".").map(String.init)
            guard p.count == 3, p[0] == "mod", let m = ModuleID(rawValue: p[1]) else { return }
            if p[2] == "show" { if prefs.shown.contains(m) { prefs.shown.remove(m) } else { prefs.shown.insert(m) } }
            else { prefs.setStyle(m, step(m.barStyles, prefs.style(m), d)) }
        }
    }
}

/// The soft pill behind the highlighted row. One pill glides from row to row with a spring (matched geometry).
struct NavPill: ViewModifier {
    @ObservedObject var nav: SettingsNav
    let id: String
    let ns: Namespace.ID
    var inset: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .id("row-" + id)
            .overlay {
                if nav.current == id {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Pal.accent.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Pal.accent.opacity(0.75), lineWidth: 1.5))
                        .padding(-inset)
                        .allowsHitTesting(false)
                        .matchedGeometryEffect(id: "navpill", in: ns)
                }
            }
    }
}
