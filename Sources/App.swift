// App.swift. Stats: your Mac's numbers in the menu bar.
// The app delegate owns the menu bar items, the popover and Settings. Views only read Monitor and Prefs.
import AppKit
import Combine
import ServiceManagement
import SwiftUI

#if STATS_TEST
let testNotification = Notification.Name("com.solomon.Stats.test")
#endif

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StatsRemake.log")
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

@main enum Main {
    @MainActor static func main() {
        #if UPDATER_TEST
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--selftest-update=") }) {
            let result = String(a.dropFirst("--selftest-update=".count))
            Task { @MainActor in
                let ok = await AppUpdater.selfTest(UpdateConfig(repo: "Solomon-69/Stats", appName: "Stats", bundleName: "Stats.app", zipName: "Stats-mac.zip"), result: result)
                exit(ok ? 0 : 1)
            }
            RunLoop.main.run()
        }
        #endif
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(d) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let prefs = Prefs()
    private lazy var monitor = Monitor(prefs: prefs)
    private var status: StatusController!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private lazy var nav = SettingsNav(prefs: prefs)
    private var settingsKeys: Any?
    private var quietOpen = false
    private var shownFrom: NSStatusBarButton?
    private var clickMonitor: Any?, keyMonitor: Any?
    private var panelPrepared = false
    private var bag = Set<AnyCancellable>()
    private var lastRefresh = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }
        applyAppearance()
        lastRefresh = prefs.refresh
        monitor.start()
        status = StatusController(monitor: monitor, prefs: prefs)
        status.onClick = { [weak self] button in self?.statusClicked(button, nil) }
        monitor.onTick = { [weak self] in self?.status.refresh() }

        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = false   // the pop-up animation slid the window in from the side while it sized itself; the tiles fade in instead

        prefs.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.prefsChanged() } }.store(in: &bag)
        PanelGroup.listen { [weak self] in self?.closePopover() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.restartTimer(); self?.monitor.sample()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.settingsWindow { self?.updateVisible(settings: false) }
        }
        #if STATS_TEST
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(testCommand(_:)), name: testNotification, object: nil)
        #endif
        Log.write("launched")
    }

    /// Opening Stats again from Finder or Spotlight shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown, let b = status.mainItem.button { openPopover(from: b, module: nil) }
        return false
    }

    // MARK: Settings changes

    private func applyAppearance() {
        switch prefs.appearance {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        // The popover otherwise follows the menu bar's look, so give it the chosen one too.
        popover.appearance = NSApp.appearance
    }

    private func prefsChanged() {
        applyAppearance()
        status.sync()
        if prefs.refresh != lastRefresh { lastRefresh = prefs.refresh; monitor.restartTimer() }
        monitor.sampleSlow(); monitor.sample()
    }

    // MARK: Popover

    private func statusClicked(_ button: NSStatusBarButton, _ module: ModuleID?) {
        if popover.isShown, shownFrom === button { closePopover() } else { openPopover(from: button, module: module) }
    }

    /// The panel's views only exist while it is open: building them takes a moment and closing frees their memory (about 50 MB).
    private func ensureContent() {
        guard popover.contentViewController == nil else { return }
        let view = PanelView(monitor: monitor, prefs: prefs, onSettings: { [weak self] in self?.openSettings() },
                             onQuit: { [weak self] in self?.quit() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        let fit = host.view.fittingSize
        if fit.width > 10, fit.height > 10 { host.preferredContentSize = fit; popover.contentSize = fit }
        popover.contentViewController = host
        panelPrepared = false
    }

    private func openPopover(from button: NSStatusBarButton, module: ModuleID?) {
        removeMonitors()
        if popover.isShown { popover.close() }
        shownFrom = button
        // Read fresh numbers and build the panel at its final size before it appears: a panel shown first and sized
        // afterwards drew its contents small in the top-left corner for a frame, then jumped into place.
        monitor.expanded = module
        updateVisible(panel: true)
        ensureContent()
        if let host = popover.contentViewController?.view {
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            if fit.width > 10, fit.height > 10 { popover.contentViewController?.preferredContentSize = fit; popover.contentSize = fit }
        }
        monitor.openCount += 1
        bounce(button)
        PanelGroup.announceOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Never activate the app (that would swap the menu bar). A non-activating panel still gets keys.
        if let panel = popover.contentViewController?.view.window as? NSPanel, !panelPrepared {
            panel.styleMask.insert(.nonactivatingPanel)
            panelPrepared = true
        }
        popover.contentViewController?.view.window?.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if PanelGroup.isOnNoxSwitch() { return }
            self?.closePopover()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.popover.isShown, e.keyCode == 53 else { return e }   // esc
            if self.monitor.expanded != nil { self.monitor.expanded = nil } else { self.closePopover() }
            return nil
        }
        Log.write("panel opened from \(module?.rawValue ?? "main")")
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        removeMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        Log.write("popover closed")
        if !popover.isShown {
            removeMonitors(); updateVisible(panel: false)
            popover.contentViewController = nil
            // Hand the freed pages back to macOS once the views are gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private var panelVisible = false, settingsVisible = false
    private func updateVisible(panel: Bool? = nil, settings: Bool? = nil) {
        if let p = panel { panelVisible = p }
        if let s = settings { settingsVisible = s }
        monitor.visible = panelVisible || settingsVisible
    }

    private func bounce(_ b: NSStatusBarButton) {
        guard !reduceMotion, let layer = b.layer else { return }
        let a = CASpringAnimation(keyPath: "transform")
        let cx = b.bounds.midX, cy = b.bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, 1.12, 1.12, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        a.fromValue = t; a.toValue = CATransform3DIdentity
        a.mass = 1; a.stiffness = 320; a.damping = 11
        a.duration = a.settlingDuration
        layer.add(a, forKey: "bounce")
    }

    // MARK: Settings window, quit, login

    private func openSettings() {
        closePopover()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(prefs: prefs, monitor: monitor, nav: nav) { [weak self] want in self?.setLogin(want) })
            w.setContentSize(NSSize(width: 780, height: 620))
            w.center()
            settingsWindow = w
            nav.onLogin = { [weak self] want in self?.setLogin(want) }
            nav.onClose = { [weak self] in self?.settingsWindow?.performClose(nil) }
            settingsKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.settingsWindow, e.window === w, w.isKeyWindow, !(w.firstResponder is NSText),
                      e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
                let k: SettingsNav.Key
                switch e.keyCode {
                case 125: k = .down
                case 126: k = .up
                case 123: k = .left
                case 124: k = .right
                case 49, 36, 76: k = .activate
                case 53: k = .back
                default: return e
                }
                self.nav.key(k)
                return nil
            }
        }
        updateVisible(settings: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setLogin(_ want: Bool) {
        do { if want { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { Log.write("login item failed: \(error.localizedDescription)") }
        prefs.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Quit folds the panel away first, then ends the app.
    private func quit() {
        closePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.3)) { NSApp.terminate(nil) }
    }

    #if STATS_TEST
    // MARK: Test hook (test builds only): com.solomon.Stats.test with a text command.
    @objc private func testCommand(_ n: Notification) {
        guard let cmd = n.object as? String else { return }
        let p = cmd.split(separator: ":").map(String.init)
        Log.write("test: \(cmd)")
        switch p.first {
        case "panel":
            // Silent: marks the panel as open (so numbers and details are read) but never puts a window on screen.
            quietOpen = true
            monitor.expanded = p.count > 1 ? ModuleID(rawValue: p[1]) : nil
            monitor.openCount += 1
            updateVisible(panel: true)
        case "close": quietOpen = false; closePopover(); updateVisible(panel: false)
        case "settings": updateVisible(settings: true)
        case "closesettings": updateVisible(settings: false)
        case "expand": monitor.expanded = p.count > 1 ? ModuleID(rawValue: p[1]) : nil
        case "show": if p.count > 2, let m = ModuleID(rawValue: p[1]) { if p[2] == "1" { prefs.shown.insert(m) } else { prefs.shown.remove(m) } }
        case "appearance": if p.count > 1 { prefs.appearance = Int(p[1]) ?? 0 }
        case "theme": if p.count > 1 { prefs.themeIndex = Int(p[1]) ?? 0 }
        case "checks": if p.count > 1 { prefs.internetChecks = p[1] == "1" }
        case "tiles": if p.count > 1 { prefs.colourfulTiles = p[1] == "1" }
        case "invisible": if p.count > 1 { prefs.invisibleIcon = p[1] == "1" }
        case "freeze": monitor.frozen = p.count > 1 && p[1] == "1"
        case "icon": if p.count > 1, let i = MainIcon(rawValue: p[1]) { prefs.mainIcon = i }
        case "iconsrc": if p.count > 1, let m = ModuleID(rawValue: p[1]), ModuleID.liveChoices.contains(m) { prefs.iconSource = m }
        case "icontint": if p.count > 1 { prefs.iconTinted = p[1] == "1" }
        case "accent": if p.count > 1 { prefs.settingsAccent = SettingsAccent.clamp(Int(p[1]) ?? 0) }
        case "refresh": if p.count > 1 { prefs.refresh = Int(p[1]) ?? 2 }
        case "units": if p.count > 2 { if p[1] == "temp" { prefs.fahrenheit = p[2] == "f" } else { prefs.netBits = p[2] == "bits" } }
        case "zones": prefs.zones = p.count > 1 ? p[1].split(separator: ",").map(String.init) : []
        case "nav":
            let keys: [String: SettingsNav.Key] = ["up": .up, "down": .down, "left": .left, "right": .right, "space": .activate, "esc": .back]
            if p.count > 1, p[1] == "reset" { nav.current = nil; nav.tab = .look }
            else if p.count > 1, p[1] == "tab", p.count > 2, let n = Int(p[2]), let t = SettingsTab(rawValue: n) { nav.tab = t }
            else if p.count > 1, let k = keys[p[1]] { nav.key(k) }
        case "state": writeState()
        case "realclick": status.mainItem.button?.performClick(nil)
        case "popopen": popoverRealOpen(scheme: p.count > 1 ? p[1] : "light")
        case "popjoin": popoverJoinSnapshot(name: p.count > 1 ? p[1] : "join", scheme: p.count > 2 ? p[2] : "light")
        case "setshot": settingsShot(name: p.count > 1 ? p[1] : "setshot", tab: p.count > 2 ? Int(p[2]) ?? 0 : 0, scheme: p.count > 3 ? p[3] : "light")
        case "snap": snapshot(name: p.count > 1 ? p[1] : "snap", scheme: p.count > 2 ? p[2] : "light")
        case "quit": quit()
        default: break
        }
    }

    private func writeState() {
        monitor.sampleSlow()
        let m = monitor
        var d: [String: Any] = [
            "cpu": m.cpu.total, "cpuUser": m.cpu.user, "cpuSystem": m.cpu.system, "cores": m.cpu.cores.count,
            "load": [m.cpu.load1, m.cpu.load5, m.cpu.load15], "uptime": m.cpu.uptime,
            "memTotal": m.mem.total, "memUsed": m.mem.used, "memApp": m.mem.app, "memWired": m.mem.wired,
            "memCompressed": m.mem.compressed, "memFree": m.mem.free, "memCached": m.mem.cached, "pressure": m.mem.pressure, "swapUsed": m.mem.swapUsed,
            "diskTotal": m.disk.total, "diskFree": m.disk.free, "diskRead": m.disk.readBps, "diskWrite": m.disk.writeBps,
            "netDown": m.net.downBps, "netUp": m.net.upBps, "netKind": m.net.kind, "netAddr": m.net.address, "online": m.net.online,
            "temps": m.temps.map { ["name": $0.raw, "group": $0.group, "c": $0.celsius] }, "fans": m.fans.count, "gadgets": m.gadgets.map(\.name),
            "ownCPU": m.ownCPU, "ownMemory": m.ownMemory, "shown": prefs.shown.map(\.rawValue).sorted(),
            "navCurrent": nav.current ?? "", "navTab": nav.tab.rawValue, "appearance": prefs.appearance, "themeIndex": prefs.themeIndex,
            "refresh": prefs.refresh, "fahrenheit": prefs.fahrenheit, "netBits": prefs.netBits, "invisibleIcon": prefs.invisibleIcon,
            "launchAtLogin": prefs.launchAtLogin,
            "panelShown": popover.isShown || quietOpen, "publicAddress": m.netX.publicAddress ?? "", "delayMs": m.netX.delayMs ?? 0, "expanded": m.expanded?.rawValue ?? "", "panelModules": m.panelModules.map(\.rawValue),
        ]
        if let g = m.gpu { d["gpu"] = g }
        d["bars"] = status.info()
        d["summary"] = Dictionary(uniqueKeysWithValues: ModuleID.allCases.map { ($0.rawValue, ["value": m.summary($0).value, "subtitle": m.summary($0).subtitle]) })
        d["prefs"] = ["refresh": prefs.refresh, "fahrenheit": prefs.fahrenheit, "netBits": prefs.netBits, "appearance": prefs.appearance, "invisible": prefs.invisibleIcon, "icon": prefs.mainIcon.rawValue, "iconSource": prefs.iconSource.rawValue, "iconTinted": prefs.iconTinted, "accent": prefs.settingsAccent, "theme": prefs.themeIndex, "tiles": prefs.colourfulTiles, "checks": prefs.internetChecks, "alerts": prefs.alerts, "zones": prefs.zones]
        if let b = m.battery { d["battery"] = ["percent": b.percent, "charging": b.charging, "plugged": b.pluggedIn, "cycles": b.cycles,
                                                "health": b.health ?? -1, "secondsLeft": b.secondsLeft ?? -1] }
        if let w = popover.contentViewController?.view.window { d["panelFrame"] = NSStringFromRect(w.frame); d["panelWindow"] = w.windowNumber }
        if let w = status.mainItem.button?.window { d["iconFrame"] = NSStringFromRect(w.frame) }
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StatsRemake-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out) }
    }

    /// Draws the panel and Settings off-screen into PNG files. Nothing shows on screen, the Mac's own look is untouched.
    /// Draws the popover's frame (arrow + body) into a PNG without ever showing it: the window is made fully transparent
    /// before it can be drawn, and only its view tree is rendered.
    private func popoverJoinSnapshot(name: String, scheme: String) {
        guard let button = status.mainItem.button else { return }
        ensureContent()
        let was = popover.animates
        popover.animates = false
        NSApp.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let win = popover.contentViewController?.view.window, let host = popover.contentViewController?.view else { return }
        win.alphaValue = 0
        let root: NSView = host.superview ?? host
        root.layoutSubtreeIfNeeded()
        var chain: [String] = []
        func dump(_ x: NSView, _ d: Int) {
            var line = String(repeating: "  ", count: d) + "\(type(of: x)) \(x.frame) layer=\(x.layer.map { String(describing: type(of: $0)) } ?? "-")"
            if let ve = x as? NSVisualEffectView { line += " material=\(ve.material.rawValue) state=\(ve.state.rawValue) mask=\(ve.maskImage != nil)" }
            if let l = x.layer, l.mask != nil { line += " layerMask" }
            chain.append(line); x.subviews.forEach { dump($0, d + 1) }
        }
        dump(root, 0)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StatsRemake-snap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? chain.joined(separator: "\n").write(to: dir.appendingPathComponent("popjoin-views.txt"), atomically: true, encoding: .utf8)
        if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
        }
        win.alphaValue = 1
        popover.close()
        popover.animates = was
        applyAppearance()
    }

    /// Really shows the popover (no animation, no focus) so an outside tool can screenshot its window by number. One short proof only.
    private func popoverRealOpen(scheme: String) {
        guard let button = status.mainItem.button else { return }
        ensureContent()
        popover.animates = false
        NSApp.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The real Settings view in a window that is never shown, drawn to a PNG (so NSView parts like the icon pictures appear).
    private func settingsShot(name: String, tab: Int, scheme: String) {
        nav.tab = SettingsTab(rawValue: tab) ?? .look
        var view = SettingsView(prefs: prefs, monitor: monitor, nav: nav) { _ in }
        view.startTab = nav.tab   // the view picks its first page on appear
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            host.layoutSubtreeIfNeeded()
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StatsRemake-snap")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
            }
            // Close it: the app keeps every window in its list, and an open hidden window would keep redrawing.
            win.contentView = nil; win.close()
        }
    }

    private func snapshot(name: String, scheme: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StatsRemake-snap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render<V: View>(_ v: V, file: String) {
            MainActor.assumeIsolated {
                let content = scheme == "auto" ? AnyView(v) : AnyView(v.environment(\.colorScheme, scheme == "dark" ? .dark : .light))
                let r = ImageRenderer(content: content)
                r.scale = 2
                guard let cg = r.cgImage else { return }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
            }
        }
        render(PanelView(monitor: monitor, prefs: prefs, onSettings: {}, onQuit: {}, scrolls: false), file: "\(name)-panel-\(scheme).png")
        for tab in SettingsTab.allCases {
            render(SettingsView(prefs: prefs, monitor: monitor, nav: nav, scrolls: false, startTab: tab) { _ in }, file: "\(name)-settings\(tab.rawValue)-\(scheme).png")
        }
    }
    #endif
}
