// StatusItems.swift. The menu bar: one Stats icon, never more.
// It draws itself in its own subview (never by swapping the button image, which leaves ghosts on macOS 26).
import AppKit

/// What the icon shows right now.
struct BarSnapshot {
    var value = ""              // processor load as text
    var values: [Double] = []   // history for the Live graph icon (0...1)
    var fraction = 0.0          // processor load, 0...1
}

final class BarView: NSView {
    var invisible: Bool { icon == .hidden }
    var icon: MainIcon = .bars { didSet { needsDisplay = true } }
    /// Colour the icon with the Mac's effort (nil = plain menu bar ink).
    var effortTint: NSColor? { didSet { needsDisplay = true } }
    var snap = BarSnapshot() { didSet { needsDisplay = true } }
    var onWidth: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) { drawMain() }

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
}

/// Builds and updates the one menu bar icon.
final class StatusController {
    private(set) var mainItem: NSStatusItem
    private var mainView = BarView()
    private let monitor: Monitor
    private let prefs: Prefs
    var onClick: (NSStatusBarButton) -> Void = { _ in }

    init(monitor: Monitor, prefs: Prefs) {
        self.monitor = monitor; self.prefs = prefs
        mainItem = NSStatusBar.system.statusItem(withLength: prefs.mainIcon.width)
        if let b = mainItem.button {
            b.wantsLayer = true
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel("Stats")
            b.identifier = NSUserInterfaceItemIdentifier("main")
            mainView.frame = b.bounds
            mainView.autoresizingMask = [.width, .height]
            b.addSubview(mainView)
        }
        sync()
    }

    @objc private func clicked(_ s: NSStatusBarButton) { onClick(s) }

    /// Matches the icon to the settings.
    func sync() {
        mainView.icon = prefs.mainIcon
        mainItem.length = prefs.mainIcon.width
        refresh()
    }

    /// The icon's live numbers: processor load for the live graph; effort colour when switched on.
    func refresh() {
        var s = BarSnapshot()
        s.fraction = monitor.cpu.total; s.value = Fmt.pct(monitor.cpu.total); s.values = monitor.iconSeries(prefs.iconSource)
        mainView.snap = s
        mainView.effortTint = prefs.iconTinted ? NSColor(monitor.status.tint) : nil
    }

    /// For tests: the menu bar items this app owns (always exactly one) and how wide it is.
    func info() -> [[String: Any]] {
        [["module": "main", "length": mainItem.length, "invisible": mainView.invisible, "icon": mainView.icon.rawValue]]
    }
}
