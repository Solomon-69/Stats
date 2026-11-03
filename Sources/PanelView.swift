// PanelView.swift. The popover: one card per module with a live mini chart; tap a card for details.
import AppKit
import SwiftUI

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs
    let onSettings: () -> Void
    let onQuit: () -> Void
    var scrolls = true
    @State private var contentHeight: CGFloat = 400
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let width: CGFloat = 380
    static let maxListHeight: CGFloat = 560
    /// With every sensor listed the panel grows to the screen (minus room for the header, footer and menu bar).
    private var listLimit: CGFloat { monitor.allSensors ? max(Self.maxListHeight, (NSScreen.main?.visibleFrame.height ?? 800) - 190) : Self.maxListHeight }

    var body: some View {
        let modules = monitor.panelModules
        VStack(spacing: 10) {
            header
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        cards(modules).background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                    }
                    .frame(height: min(contentHeight, listLimit))
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
                    // Showing every sensor lists the Temperature tile from its top; hiding them puts the tile back at the bottom, half open.
                    .onChange(of: monitor.allSensors) { _, all in
                        guard let open = monitor.expanded else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            withAnimation(reduceMotion ? nil : panelSpring) { proxy.scrollTo(open, anchor: all ? .top : nil) }
                        }
                    }
                    // An opened tile near the bottom would be cut off, so once it has grown, scroll just enough to show all of it.
                    .onChange(of: monitor.expanded) { _, open in
                        guard let open else { monitor.allSensors = false; return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            withAnimation(reduceMotion ? nil : panelSpring) { proxy.scrollTo(open, anchor: nil) }
                        }
                    }
                }
            } else {
                cards(modules)   // test snapshots: ImageRenderer cannot draw a ScrollView
            }
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // The popover's own glass shows through, so the arrow and the body are one shape with one fill (a solid body
        // colour here made a visible seam where the arrow meets it). Snapshots have no popover, so they get a flat colour.
        .background(scrolls ? Color.clear : Pal.panel)
        .animation(reduceMotion ? nil : panelSpring, value: modules)
    }

    /// Tiles sit two to a row. The opened tile takes a whole row (its details need the room) at the start of its pair, so the tiles
    /// above it still pair up evenly; the rest pair up in order and, if one is left over, it spans the row so no row ever has a gap.
    private func cards(_ modules: [ModuleID]) -> some View {
        func pairs(_ list: ArraySlice<ModuleID>) -> [[ModuleID]] {
            stride(from: list.startIndex, to: list.endIndex, by: 2).map { Array(list[$0..<min($0 + 2, list.endIndex)]) }
        }
        var rows: [[ModuleID]]
        if monitor.allSensors, let open = monitor.expanded, modules.contains(open) {
            rows = [[open]]
        } else if let open = monitor.expanded, let i = modules.firstIndex(of: open) {
            let others = modules.filter { $0 != open }
            let at = min(i - i % 2, others.count)
            rows = pairs(others[..<at]) + [[open]] + pairs(others[at...])
        } else {
            rows = pairs(modules[...])
        }
        return VStack(spacing: 10) {
            if modules.isEmpty {
                Text("Nothing is switched on. Open Settings to pick what to watch.")
                    .font(.mono(11)).foregroundStyle(Pal.mute).multilineTextAlignment(.center).padding(24)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(row, id: \.self) { m in
                                ModuleTile(module: m, monitor: monitor, expanded: monitor.expanded == m, wide: row.count == 1) {
                                    withAnimation(reduceMotion ? nil : panelSpring) { monitor.expanded = monitor.expanded == m ? nil : m }
                                }
                                .id(m)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .entrance(index: i, trigger: monitor.openCount)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Two lines: the Mac's name with how it is doing right now (the only coloured part), then its specs as quiet chips.
    private var header: some View {
        let st = monitor.status
        let chips = Machine.chips(gpuCores: monitor.gpuCores) + [Machine.system]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text(Machine.name).font(.system(size: 16, weight: .semibold)).tracking(-0.2).foregroundStyle(Pal.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Circle().fill(st.tint).frame(width: 6, height: 6)
                    Text(st.text).font(.mono(10.5, .medium)).foregroundStyle(Pal.ink.opacity(0.85)).lineLimit(1).fixedSize()
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(st.tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(st.tint.opacity(0.40), lineWidth: 1))
                .layoutPriority(1)
                .animation(.easeInOut(duration: 0.35), value: st.text)
            }
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { c in
                    Text(c).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Pal.ink.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Pal.ink.opacity(0.07)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button(action: onSettings) { Label("Settings", systemImage: "slider.horizontal.3").font(.system(size: 12.5, weight: .semibold)) }
                .buttonStyle(QuietButtonStyle()).noFocusRing()
            Spacer()
            Button(action: onQuit) { Text("Quit").font(.system(size: 12.5, weight: .semibold)) }.buttonStyle(QuietButtonStyle()).noFocusRing()
        }
    }
}

/// Twelve small blocks that fill up like a bar of lights.
struct SegBar: View {
    let fraction: Double
    let tint: Color
    var segments = 12
    var body: some View {
        let on = Int((min(max(fraction, 0), 1) * Double(segments)).rounded())
        HStack(spacing: 2.5) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(i < on ? tint : Pal.box).frame(height: 5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

struct ModuleTile: View {
    let module: ModuleID
    @ObservedObject var monitor: Monitor
    let expanded: Bool
    let wide: Bool
    let tap: () -> Void
    @State private var hover = false

    private var fraction: Double? {
        switch module {
        case .cpu: monitor.cpu.total
        case .memory: monitor.mem.fraction
        case .disk: monitor.disk.usedFraction
        case .gpu: monitor.gpu
        case .battery: monitor.battery.map { $0.percent / 100 }
        default: nil
        }
    }

    /// "172.7 MB/s" becomes a big "172.7" and a small "MB/s", so long speeds never get cut off.
    static func splitRate(_ v: String, rate: Bool) -> (number: String, unit: String?) {
        guard rate, let i = v.lastIndex(of: " ") else { return (v, nil) }
        return (String(v[..<i]), String(v[v.index(after: i)...]))
    }

    var body: some View {
        let s = monitor.summary(module)
        let chart = monitor.chartSeries(module)
        let hot = module == .disk && monitor.disk.usedFraction >= 0.9
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    IconTile(symbol: module.symbol, tint: module.tint, size: 22)
                    Text(module.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.mute).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hover || expanded ? module.tint : Pal.mute.opacity(0.7))
                }
                HStack(alignment: .bottom, spacing: 8) {
                    let parts = Self.splitRate(s.value, rate: module == .network || module == .diskio)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(parts.number)
                            .font(.mono(wide ? 28 : 24, .medium)).tracking(-0.3)
                            .foregroundStyle(hot ? Pal.bad : Pal.ink)
                            .contentTransition(.numericText()).animation(.smooth(duration: 0.6), value: s.value).lineLimit(1).minimumScaleFactor(0.55)
                        if let u = parts.unit { Text(u).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.mute).lineLimit(1).fixedSize() }
                    }
                    .padding(.trailing, 4).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let c = chart {
                        LiveChart(monitor: monitor, series: c.series, max: c.max, fill: false, lineWidth: 1.3)
                            .frame(minWidth: 28, idealWidth: wide ? 150 : 62, maxWidth: wide ? 150 : 62)
                            .frame(height: 26)
                    } else if module == .memory {
                        let p = monitor.pressureWord()
                        Text(p.short).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.tint)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(p.tint.opacity(0.16)))
                            .padding(.bottom, 2)
                    }
                }
                Text(s.subtitle).font(.system(size: 11)).foregroundStyle(Pal.mute).lineLimit(1).minimumScaleFactor(0.8)
                if let f = fraction { SegBar(fraction: f, tint: hot ? Pal.bad : module.tint) }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onHover { hover = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(module.title), \(s.value), \(s.subtitle)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, tap)

            if expanded {
                Rectangle().fill(Pal.line).frame(height: 1)
                ModuleDetail(module: module, monitor: monitor)
                    .padding(12)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover && !expanded ? Pal.box : Pal.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(expanded || hover ? module.tint.opacity(0.55) : Pal.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: hover)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Details

/// The speed test: a button, live megabits while it runs, then the result. Phone speed testers show the same figures.
private struct SpeedTestRows: View {
    @ObservedObject var speed: SpeedTest
    let bits: Bool
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(speed.running ? "Stop test" : (speed.phase == .idle ? "Test speed" : "Test again")) {
                speed.running ? speed.cancel() : speed.start()
            }.buttonStyle(QuietButtonStyle())
            if speed.running {
                KV(key: speed.phase == .down ? "Testing download…" : "Testing upload…", value: String(format: "%.0f Mbps", speed.liveMbps), tint: tint)
            }
            if let d = speed.downMbps { KV(key: "Test: download", value: String(format: "%.0f Mbps", d), tint: tint) }
            if let u = speed.upMbps { KV(key: "Test: upload", value: String(format: "%.0f Mbps", u), tint: Pal.second) }
            if let p = speed.pingMs { KV(key: "Test: delay", value: String(format: "%.0f ms", p)) }
            if speed.phase == .failed { KV(key: "Test", value: "Could not reach the test server", tint: Pal.warn) }
            if speed.phase == .idle {
                Text("Uses a little data from Cloudflare's free test servers, only when you press it.").font(.system(size: 10)).foregroundStyle(Pal.mute)
            }
        }
        .padding(.top, 2)
    }
}

private struct KV: View {
    let key: String
    let value: String
    var tint: Color = Pal.ink
    var body: some View {
        HStack {
            Text(key).font(.mono(10.5)).foregroundStyle(Pal.mute)
            Spacer(minLength: 8)
            Text(value).font(.mono(11, .medium)).foregroundStyle(tint).lineLimit(1)
        }
    }
}

private struct Section: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.mute)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }
}

private struct AppList: View {
    let rows: [ProcRow]
    let byMemory: Bool
    let tint: Color
    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.name).font(.mono(10.5)).foregroundStyle(Pal.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(byMemory ? Fmt.mem(r.memory) : String(format: "%.0f%%", r.cpu * 100))
                        .font(.mono(10.5, .medium)).foregroundStyle(Pal.mute)
                }
            }
            if rows.isEmpty { Text("Looking…").font(.mono(10.5)).foregroundStyle(Pal.mute) }
        }
    }
}

struct ModuleDetail: View {
    let module: ModuleID
    @ObservedObject var monitor: Monitor

    /// Apple chips have fast and efficient cores; the efficient ones come first.
    private var coresTitle: String {
        func si(_ n: String) -> Int { var v: Int32 = 0; var l = MemoryLayout<Int32>.size; return sysctlbyname(n, &v, &l, nil, 0) == 0 ? Int(v) : 0 }
        let e = si("hw.perflevel1.logicalcpu"), f = si("hw.perflevel0.logicalcpu")
        return e > 0 && f > 0 ? "Cores: \(e) efficient + \(f) fast" : "Each core"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch module {
            case .cpu: cpu
            case .gpu: gpu
            case .memory: memory
            case .disk: disk
            case .diskio: diskio
            case .network: network
            case .battery: battery
            case .sensors: sensors
            case .fans: fans
            case .bluetooth: bluetooth
            case .clock: clock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cpu: some View {
        let c = monitor.cpu
        let parts = [SegmentBar.Part(label: "Apps", value: c.user, tint: Pal.second),
                     SegmentBar.Part(label: "System", value: c.system, tint: Pal.bad),
                     SegmentBar.Part(label: "Resting", value: max(0, 1 - c.total), tint: Pal.edge)]
        return VStack(alignment: .leading, spacing: 8) {
            SegmentBar(parts: parts)
            Legend(parts: parts) { Fmt.pct($0.value) }
            KV(key: "Chip", value: Monitor.chipName)
            KV(key: "Cores (real / counting threads)", value: "\(Monitor.sysInt("hw.physicalcpu")) / \(Monitor.sysInt("hw.logicalcpu"))")
            Section(title: coresTitle)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(c.cores.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Pal.box)
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Pal.second).frame(height: max(2, 30 * v))
                    }
                    .frame(height: 30)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.1), value: c.cores)
            KV(key: "Recent workload (1, 5, 15 min)", value: String(format: "%.1f · %.1f · %.1f", c.load1, c.load5, c.load15))
            KV(key: "On for", value: Fmt.duration(c.uptime / 1))
            Section(title: "Busiest apps")
            AppList(rows: monitor.topByCPU(), byMemory: false, tint: module.tint)
        }
    }

    private var gpu: some View {
        VStack(alignment: .leading, spacing: 8) {
            MiniBar(value: monitor.gpu ?? 0, tint: module.tint)
            KV(key: "Chip", value: monitor.gpuName.isEmpty ? "Graphics" : monitor.gpuName)
            if monitor.gpuCores > 0 { KV(key: "Graphics cores", value: "\(monitor.gpuCores)") }
            KV(key: "Busy", value: Fmt.pct(monitor.gpu ?? 0))
            if let r = monitor.gpuRender { KV(key: "Drawing (renderer)", value: Fmt.pct(r)) }
            if let t = monitor.gpuTile { KV(key: "Shapes (tiler)", value: Fmt.pct(t)) }
        }
    }

    private var memory: some View {
        let m = monitor.mem
        let parts = [SegmentBar.Part(label: "Apps", value: m.app, tint: Pal.good),
                     SegmentBar.Part(label: "System", value: m.wired, tint: Pal.second),
                     SegmentBar.Part(label: "Compressed", value: m.compressed, tint: Pal.warn),
                     SegmentBar.Part(label: "Available", value: max(0, m.total - m.used), tint: Pal.edge)]
        let (word, tint, _) = monitor.pressureWord()
        return VStack(alignment: .leading, spacing: 8) {
            SegmentBar(parts: parts)
            Legend(parts: parts) { Fmt.mem($0.value) }
            KV(key: "Total memory", value: Fmt.mem(m.total))
            KV(key: "Room to work", value: word, tint: tint)
            KV(key: "Cached files (part of available)", value: Fmt.mem(m.cached))
            KV(key: "Spilled to disk (swap)", value: Fmt.mem(m.swapUsed))
            Section(title: "Biggest apps")
            AppList(rows: monitor.topByMemory(), byMemory: true, tint: module.tint)
        }
    }

    private var diskio: some View {
        let d = monitor.disk
        return VStack(alignment: .leading, spacing: 8) {
            KV(key: "Reading now", value: Fmt.bytes(d.readBps) + "/s")
            KV(key: "Writing now", value: Fmt.bytes(d.writeBps) + "/s")
            KV(key: "Read since start-up", value: Fmt.bytes(d.readTotal))
            KV(key: "Written since start-up", value: Fmt.bytes(d.writeTotal))
        }
    }

    private var disk: some View {
        let d = monitor.disk
        return VStack(alignment: .leading, spacing: 8) {
            MiniBar(value: d.usedFraction, tint: module.tint)
            KV(key: "Total size", value: Fmt.bytes(d.total))
            KV(key: "Used", value: Fmt.bytes(max(0, d.total - d.free)))
            KV(key: "Free", value: Fmt.bytes(d.free))
            if d.purgeable > 1e8 { KV(key: "Of that, the Mac can clear by itself", value: Fmt.bytes(d.purgeable)) }
            if !d.format.isEmpty { KV(key: "Drive", value: "\(d.name) · \(d.format)") }
            KV(key: "Reading now", value: Fmt.bytes(d.readBps) + "/s", tint: module.tint)
            KV(key: "Writing now", value: Fmt.bytes(d.writeBps) + "/s", tint: Pal.second)
            KV(key: "Read since the Mac started", value: Fmt.bytes(d.readTotal))
            KV(key: "Written since the Mac started", value: Fmt.bytes(d.writeTotal))
            let others = d.volumes.filter { $0.id != "/" }
            if !others.isEmpty {
                Section(title: "Other drives")
                ForEach(others) { v in
                    VStack(alignment: .leading, spacing: 3) {
                        KV(key: v.name, value: "\(Fmt.bytes(v.free)) free")
                        MiniBar(value: (v.total - v.free) / v.total, tint: module.tint, height: 5)
                    }
                }
            }
        }
    }

    private var network: some View {
        let n = monitor.net
        return VStack(alignment: .leading, spacing: 8) {
            LiveChart(monitor: monitor, series: [Series(values: monitor.netDown, tint: module.tint),
                                                 Series(values: monitor.netUp, tint: Pal.second)], max: nil)
                .frame(height: 44)
            KV(key: "Download now (this Mac)", value: monitor.rate(n.downBps), tint: module.tint)
            KV(key: "Upload now (this Mac)", value: monitor.rate(n.upBps), tint: Pal.second)
            KV(key: "Downloaded since Stats opened", value: Fmt.bytes(n.downTotal))
            KV(key: "Uploaded since Stats opened", value: Fmt.bytes(n.upTotal))
            if n.online {
                KV(key: "Connected with", value: n.kind)
                if let w = WiFiInfo.linkMbps { KV(key: "Wi-Fi link speed", value: String(format: "%.0f Mbps", w)) }
                KV(key: "This Mac's address", value: n.address)
                if monitor.prefs.internetChecks {
                    KV(key: "Public address", value: monitor.netX.publicAddress ?? "Looking…")
                    KV(key: "Delay to the internet", value: monitor.netX.delayMs.map { String(format: "%.0f ms", $0) } ?? "Looking…")
                }
            } else {
                KV(key: "Status", value: "Not connected")
            }
            SpeedTestRows(speed: monitor.speed, bits: monitor.prefs.netBits, tint: module.tint)
        }
    }

    private var battery: some View {
        let b = monitor.battery ?? BatteryInfo()
        return VStack(alignment: .leading, spacing: 8) {
            MiniBar(value: b.percent / 100, tint: b.percent < 15 && !b.pluggedIn ? Pal.bad : module.tint)
            KV(key: "State", value: monitor.batteryLine(b))
            if let h = b.health { KV(key: "Health (how much it still holds)", value: Fmt.pct(h), tint: h < 0.8 ? Pal.warn : Pal.ink) }
            if let h = b.holdsMAh, let n = b.newMAh, h > 100 { KV(key: "Holds now / when new", value: "\(Int(h)) / \(Int(n)) mAh") }
            KV(key: "Charge cycles", value: "\(b.cycles)")
            if let v = b.volts, v > 1 { KV(key: "Voltage", value: String(format: "%.2f V", v)) }
            if let t = b.temperatureC { KV(key: "Battery warmth", value: monitor.temp(t)) }
            if let w = b.watts, w > 0.2 { KV(key: b.charging ? "Charging power" : "Using", value: String(format: "%.1f W", w)) }
            if let a = b.adapterWatts, b.pluggedIn { KV(key: "Charger", value: "\(Int(a)) W") }
        }
    }

    private var sensors: some View {
        let groups = Dictionary(grouping: monitor.temps, by: \.group)
        let order = ["Processor", "Graphics", "Memory", "Storage", "Battery", "Case", "Power chip", "Other"]
        return VStack(alignment: .leading, spacing: 8) {
            if !monitor.allSensors {
                ForEach(order.filter { groups[$0] != nil }, id: \.self) { g in
                    let list = groups[g] ?? []
                    let hot = list.map(\.celsius).max() ?? 0
                    KV(key: g, value: "\(monitor.temp(hot)) · \(Monitor.tempWord(hot))", tint: Monitor.tempTint(hot))
                }
            }
            Button(monitor.allSensors ? "Hide all sensors" : "Show all \(monitor.temps.count) sensors") {
                withAnimation(panelSpring) { monitor.allSensors.toggle() }
            }.buttonStyle(QuietButtonStyle())
            if monitor.allSensors {
                ForEach(monitor.temps) { s in KV(key: s.raw, value: monitor.temp(s.celsius)) }
            }
        }
    }

    private var fans: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(monitor.fans) { f in
                VStack(alignment: .leading, spacing: 4) {
                    KV(key: "Fan \(f.id + 1)", value: "\(Int(f.rpm.rounded())) rpm")
                    MiniBar(value: f.fraction, tint: module.tint, height: 5)
                }
            }
        }
    }

    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(monitor.gadgets) { g in
                VStack(alignment: .leading, spacing: 4) {
                    KV(key: g.name, value: "\(Int(g.percent.rounded()))%", tint: g.percent < 20 ? Pal.bad : Pal.ink)
                    MiniBar(value: g.percent / 100, tint: g.percent < 20 ? Pal.bad : module.tint, height: 5)
                }
            }
        }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(monitor.prefs.zones, id: \.self) { id in
                if let row = clockRow(id) { KV(key: row.0, value: row.1) }
            }
        }
    }

    private func clockRow(_ id: String) -> (String, String)? {
        guard let tz = TimeZone(identifier: id) else { return nil }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; f.timeZone = tz
        let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
        return ("\(city)\(dayNote(tz))", f.string(from: Date()))
    }

    private func dayNote(_ tz: TimeZone) -> String {
        var cal = Calendar.current
        let here = cal.component(.day, from: Date())
        cal.timeZone = tz
        let there = cal.component(.day, from: Date())
        if there == here { return "" }
        return there > here || (here > 27 && there == 1) ? " (tomorrow)" : " (yesterday)"
    }
}
