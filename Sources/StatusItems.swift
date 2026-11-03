// StatusItems.swift. The menu bar: one main icon, plus optional live items for chosen modules.
// Each item draws itself in its own subview (never by swapping the button image, which leaves ghosts on macOS 26).
import AppKit

/// What one menu bar item shows right now.
struct BarSnapshot {
    var top = ""             // small label or first line
    var value = ""           // main text
    var values: [Double] = []   // history for graphs (0...1)
    var fraction = 0.0       // 0...1 for bars
    var cores: [Double] = [] // per-core bars for the processor
    var level = 0.0          // 0...1 how loaded (colours the icon)
    var symbol = ""
    var tint: NSColor = .labelColor
}

final class BarView: NSView {
    var module: ModuleID?          // nil = the main icon
    var style: BarStyle = .icon
    var invisible: Bool { icon == .hidden }
    var icon: MainIcon = .bars { didSet { needsDisplay = true } }
    /// Colour the icon with the Mac's effort (nil = plain menu bar ink).
    var effortTint: NSColor? { didSet { needsDisplay = true } }
    var snap = BarSnapshot() { didSet { needsDisplay = true } }
    var onWidth: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    static func width(module: ModuleID?, style: BarStyle) -> CGFloat {
        guard let m = module else { return 28 }
        switch style {
        case .off: return 0
        case .icon: return 24
        case .graph: return 38
        case .bar: return m == .cpu ? 30 : 14
        case .text: return m == .network ? 56 : (m == .clock || m == .fans ? 50 : 40)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if module == nil { drawMain(); return }
        switch style {
        case .text: drawText()
        case .graph: drawGraph()
        case .bar: drawBars()
        case .icon: drawIcon()
        case .off: break
        }
    }

    private func drawMain() {
        let ink = effortTint ?? NSColor.labelColor
        let ox = (bounds.width - 16) / 2, oy = (bounds.height - 16) / 2
        switch icon {
        case .hidden: return
        case .bars:
            // Three rising bars: a tiny equaliser. 16 pt, centred.
            ink.setFill()
            for (i, h) in ([6, 14, 10] as [CGFloat]).enumerated() {
                let r = NSRect(x: ox + 1.5 + CGFloat(i) * 5, y: oy + 15 - h, width: 3.4, height: h)
                NSBezierPath(roundedRect: r, xRadius: 1.7, yRadius: 1.7).fill()
            }
        case .chip: symbol("cpu", ink)
        case .pulse: symbol("waveform.path.ecg", ink)
        case .live:
            let r = bounds.insetBy(dx: 3, dy: 6)
            let v = Array(snap.values.suffix(20))
            guard v.count >= 2 else { return }
            let path = NSBezierPath(), step = r.width / 19
            let x0 = r.maxX - CGFloat(v.count - 1) * step
            for (i, val) in v.enumerated() {
                let p = NSPoint(x: x0 + CGFloat(i) * step, y: r.maxY - CGFloat(min(1, max(0, val))) * r.height)
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            ink.setStroke(); path.lineWidth = 1.5; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
        }
    }

    private func symbol(_ name: String, _ ink: NSColor) {
        // Colour the symbol through its configuration; repainting a copy with lockFocus failed in off-screen drawing.
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium).applying(.init(paletteColors: [ink]))
        guard let t = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        t.draw(in: NSRect(x: (bounds.width - t.size.width) / 2, y: (bounds.height - t.size.height) / 2, width: t.size.width, height: t.size.height))
    }

    private func drawText() {
        let ink = NSColor.labelColor
        let label = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        func centred(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (s as NSString).size(withAttributes: a)
            (s as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: a)
        }
        if module == .network {
            let f = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
            centred(snap.top, font: f, color: ink, y: bounds.midY - 11)
            centred(snap.value, font: f, color: ink, y: bounds.midY + 0.5)
        } else {
            centred(snap.symbol, font: label, color: ink.withAlphaComponent(0.6), y: bounds.midY - 11.5)
            centred(snap.value, font: valueFont, color: ink, y: bounds.midY - 3)
        }
    }

    private func drawGraph() {
        let r = bounds.insetBy(dx: 3, dy: 5)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        let v = Array(snap.values.suffix(24))
        guard v.count >= 2 else { return }
        let path = NSBezierPath(), area = NSBezierPath()
        let step = r.width / 23
        let x0 = r.maxX - CGFloat(v.count - 1) * step
        for (i, val) in v.enumerated() {
            let p = NSPoint(x: x0 + CGFloat(i) * step, y: r.maxY - 1 - CGFloat(min(1, max(0, val))) * (r.height - 2))
            if i == 0 { path.move(to: p); area.move(to: NSPoint(x: p.x, y: r.maxY)); area.line(to: p) } else { path.line(to: p); area.line(to: p) }
        }
        area.line(to: NSPoint(x: r.maxX, y: r.maxY)); area.close()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).addClip()
        snap.tint.withAlphaComponent(0.3).setFill(); area.fill()
        snap.tint.setStroke(); path.lineWidth = 1.3; path.lineJoinStyle = .round; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBars() {
        let h: CGFloat = 16, y0 = (bounds.height - h) / 2
        let vals = (module == .cpu && !snap.cores.isEmpty) ? snap.cores : [snap.fraction]
        let gap: CGFloat = 1.5
        let w = module == .cpu ? max(2, min(5, (bounds.width - 6 - gap * CGFloat(vals.count - 1)) / CGFloat(vals.count))) : 7
        let total = w * CGFloat(vals.count) + gap * CGFloat(vals.count - 1)
        var x = (bounds.width - total) / 2
        for v in vals {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y0, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
            let fh = max(w, h * CGFloat(min(1, max(0, v))))
            snap.tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y0 + h - fh, width: w, height: fh), xRadius: w / 2, yRadius: w / 2).fill()
            x += w + gap
        }
    }

    private func drawIcon() {
        guard !snap.symbol.isEmpty,
              let img = NSImage(systemSymbolName: snap.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) else { return }
        let tinted = img.copy() as! NSImage
        tinted.lockFocus()
        (snap.level > 0.85 ? NSColor.systemRed : snap.level > 0.65 ? NSColor.systemOrange : NSColor.labelColor).set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: (bounds.width - tinted.size.width) / 2, y: (bounds.height - tinted.size.height) / 2,
                               width: tinted.size.width, height: tinted.size.height))
    }
}

/// Builds and updates the menu bar items.
final class StatusController {
    private(set) var mainItem: NSStatusItem
    private var mainView = BarView()
    private var items: [ModuleID: (item: NSStatusItem, view: BarView)] = [:]
    private let monitor: Monitor
    private let prefs: Prefs
    var onClick: (NSStatusBarButton, ModuleID?) -> Void = { _, _ in }
    #if STATS_TEST
    /// Tests turn this on so the extra menu bar items they make are measured and drawn off-screen, never shown.
    static var quiet = false
    #endif

    init(monitor: Monitor, prefs: Prefs) {
        self.monitor = monitor; self.prefs = prefs
        mainItem = NSStatusBar.system.statusItem(withLength: BarView.width(module: nil, style: .icon))
        attach(mainItem, view: mainView, label: "Stats", module: nil)
        sync()
    }

    private func attach(_ item: NSStatusItem, view: BarView, label: String, module: ModuleID?) {
        guard let b = item.button else { return }
        b.wantsLayer = true
        b.target = self
        b.action = module == nil ? #selector(mainClicked(_:)) : #selector(moduleClicked(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.setAccessibilityLabel(label)
        b.identifier = NSUserInterfaceItemIdentifier(module?.rawValue ?? "main")
        view.module = module
        view.frame = b.bounds
        view.autoresizingMask = [.width, .height]
        b.addSubview(view)
    }

    @objc private func mainClicked(_ s: NSStatusBarButton) { onClick(s, nil) }
    @objc private func moduleClicked(_ s: NSStatusBarButton) {
        onClick(s, ModuleID(rawValue: s.identifier?.rawValue ?? ""))
    }

    /// Adds or removes module items to match the settings.
    func sync() {
        mainView.icon = prefs.mainIcon
        mainItem.length = prefs.mainIcon.width
        updateMain()
        let want = Set(prefs.barModules)
        for (m, pair) in items where !want.contains(m) {
            NSStatusBar.system.removeStatusItem(pair.item); items[m] = nil
        }
        for m in ModuleID.allCases where want.contains(m) {
            let style = prefs.style(m)
            if let pair = items[m] {
                pair.item.length = BarView.width(module: m, style: style)
                pair.view.style = style
            } else {
                let it = NSStatusBar.system.statusItem(withLength: BarView.width(module: m, style: style))
                let v = BarView(); v.style = style
                attach(it, view: v, label: m.title, module: m)
                #if STATS_TEST
                it.isVisible = !Self.quiet
                #endif
                items[m] = (it, v)
            }
        }
        refresh()
    }

    /// The main icon's live numbers: processor load for the live graph; effort colour when switched on.
    func updateMain() {
        var s = BarSnapshot()
        s.fraction = monitor.cpu.total; s.value = Fmt.pct(monitor.cpu.total); s.values = monitor.iconSeries(prefs.iconSource)
        mainView.snap = s
        mainView.effortTint = prefs.iconTinted ? NSColor(monitor.status.tint) : nil
    }

    func refresh() {
        updateMain()
        for (m, pair) in items {
            pair.view.snap = snapshot(m, style: pair.view.style)
            if pair.view.style == .text, pair.view.snap.value.count > 6 {
                pair.item.length = max(BarView.width(module: m, style: .text), CGFloat(pair.view.snap.value.count) * 7 + 6)
            }
        }
    }

    /// For tests: what each item is and how wide it is.
    func info() -> [[String: Any]] {
        var out: [[String: Any]] = [["module": "main", "length": mainItem.length, "invisible": mainView.invisible, "icon": mainView.icon.rawValue]]
        for (m, p) in items { out.append(["module": m.rawValue, "style": p.view.style.rawValue, "length": p.item.length, "text": p.view.snap.value]) }
        return out
    }

    /// For tests: one bar item drawn off-screen into a PNG (2x).
    func renderBar(_ m: ModuleID, style: BarStyle) -> NSBitmapImageRep? {
        let v = BarView(); v.module = m; v.style = style
        v.snap = snapshot(m, style: style)
        let w = BarView.width(module: m, style: style)
        v.frame = NSRect(x: 0, y: 0, width: max(w, 20), height: 24)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    func button(for m: ModuleID) -> NSStatusBarButton? { items[m]?.item.button }

    private func snapshot(_ m: ModuleID, style: BarStyle) -> BarSnapshot {
        var s = BarSnapshot()
        s.tint = NSColor(m.tint)
        s.symbol = m.symbol
        s.values = monitor.hist[m] ?? []
        switch m {
        case .cpu:
            s.top = ""; s.value = Fmt.pct(monitor.cpu.total); s.symbol = "CPU"; s.fraction = monitor.cpu.total; s.cores = monitor.cpu.cores
            s.level = monitor.cpu.total
            if style == .icon { s.symbol = "cpu" }
        case .gpu:
            s.value = Fmt.pct(monitor.gpu ?? 0); s.fraction = monitor.gpu ?? 0; s.level = s.fraction
            if style == .text { s.symbol = "GPU" }
        case .memory:
            s.value = Fmt.pct(monitor.mem.fraction); s.fraction = monitor.mem.fraction; s.level = Double(monitor.mem.pressure) / 4
            if style == .text { s.symbol = "MEM" }
        case .disk:
            let used = monitor.disk.free > 0 ? min(monitor.disk.usedFraction, 0.99) : monitor.disk.usedFraction
            s.value = Fmt.pct(used); s.fraction = used; s.level = used
            s.values = monitor.diskRead.enumerated().map { i, r in
                let peak = max(monitor.diskRead.max() ?? 1, monitor.diskWrite.max() ?? 1, 1)
                return (r + (i < monitor.diskWrite.count ? monitor.diskWrite[i] : 0)) / (peak * 2)
            }
            if style == .text { s.symbol = "DISK" }
        case .diskio:
            let peak = max(monitor.diskRead.max() ?? 1, monitor.diskWrite.max() ?? 1, 1)
            s.top = "R" + Fmt.compactRate(monitor.disk.readBps, bits: false)
            s.value = "W" + Fmt.compactRate(monitor.disk.writeBps, bits: false)
            s.values = monitor.diskRead.enumerated().map { i, r in (r + (i < monitor.diskWrite.count ? monitor.diskWrite[i] : 0)) / (peak * 2) }
            s.fraction = min(1, (monitor.disk.readBps + monitor.disk.writeBps) / (peak * 2)); s.symbol = "arrow.left.arrow.right"
        case .network:
            s.top = "↓" + Fmt.compactRate(monitor.net.downBps, bits: monitor.prefs.netBits)
            s.value = "↑" + Fmt.compactRate(monitor.net.upBps, bits: monitor.prefs.netBits)
            let peak = max(monitor.netDown.max() ?? 1, 1)
            s.values = monitor.netDown.map { $0 / peak }
            s.fraction = min(1, monitor.net.downBps / max(peak, 1)); s.symbol = monitor.net.online ? "arrow.up.arrow.down" : "wifi.slash"
        case .battery:
            let p = (monitor.battery?.percent ?? 0) / 100
            s.value = Fmt.pct(p); s.fraction = p; s.level = 1 - p
            s.symbol = (monitor.battery?.charging ?? false) ? "battery.100percent.bolt" : (p > 0.75 ? "battery.100percent" : p > 0.5 ? "battery.75percent" : p > 0.25 ? "battery.50percent" : "battery.25percent")
            if style == .text { s.symbol = "BAT" }
        case .sensors:
            let c = monitor.processorTemp() ?? monitor.hottest() ?? 0
            s.value = monitor.prefs.fahrenheit ? "\(Int((c * 9 / 5 + 32).rounded()))°" : "\(Int(c.rounded()))°"; s.fraction = c / 110; s.level = c / 110
            if style == .text { s.symbol = "TEMP" }
        case .fans:
            let avg = monitor.fans.isEmpty ? 0 : monitor.fans.map(\.rpm).reduce(0, +) / Double(monitor.fans.count)
            s.value = "\(Int(avg.rounded()))"; s.fraction = monitor.fans.first?.fraction ?? 0; s.symbol = "fan"
            if style == .text { s.symbol = "FAN" }
        case .bluetooth:
            let low = monitor.gadgets.map(\.percent).min() ?? 0
            s.value = "\(Int(low.rounded()))%"; s.fraction = low / 100; s.level = 1 - low / 100; s.symbol = "keyboard"
            if style == .text { s.symbol = "BT" }
        case .clock:
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            s.value = f.string(from: Date()); s.symbol = style == .text ? "" : "clock"
        }
        return s
    }
}

extension Fmt {
    /// Short speed for the menu bar: "1.2M", "80K", "0K".
    static func compactRate(_ bps: Double, bits: Bool) -> String {
        let v = bits ? bps * 8 : bps
        if v >= 1e9 { return String(format: "%.1fG", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return "0K"
    }
}
