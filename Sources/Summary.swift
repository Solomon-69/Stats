// Summary.swift. Plain-words one-liners for each module (the value and the small print on its card).
import Foundation
import SwiftUI

struct Summary {
    var value: String
    var subtitle: String
}

extension Monitor {
    /// The two short lines of a menu bar readout: a tiny label and the live number.
    func barText(_ m: ModuleID) -> (label: String, value: String) {
        switch m {
        case .cpu: return ("CPU", Fmt.pct(cpu.total))
        case .gpu: return ("GPU", Fmt.pct(gpu ?? 0))
        case .memory: return ("RAM", Fmt.pct(mem.fraction))
        case .disk: return ("DISK", Fmt.pct(disk.free > 0 ? min(disk.usedFraction, 0.99) : disk.usedFraction))
        case .diskio: return ("R/W", Fmt.bytes(disk.readBps + disk.writeBps) + "/s")
        case .network:
            let d = prefs.netBits ? String(format: "%.1f", net.downBps * 8 / 1e6) : Fmt.bytes(net.downBps)
            return ("NET", prefs.netBits ? d + " Mb" : d + "/s")
        case .battery: return ("BATT", battery.map { Fmt.pct($0.percent / 100) } ?? "--")
        default: return (m.liveLabel.uppercased(), "")
        }
    }

    func summary(_ m: ModuleID) -> Summary {
        switch m {
        case .cpu:
            let top = topByCPU(1).first
            let name = top.map { $0.name.count > 15 ? String($0.name.prefix(14)) + "…" : $0.name }
            let sub = (top != nil && top!.cpu > 0.08) ? "Busiest: \(name!)" : (cpu.total >= 0.3 ? "Busy with macOS tasks" : "Mostly resting")
            return Summary(value: Fmt.pct(cpu.total), subtitle: sub)
        case .gpu:
            let chip = gpuName.isEmpty ? "Graphics chip" : gpuName
            return Summary(value: Fmt.pct(gpu ?? 0), subtitle: gpuCores > 0 ? "\(chip) · \(gpuCores) cores" : chip)
        case .memory:
            let swap = mem.swapUsed > 1_000_000 ? " · Swap \(Fmt.mem(mem.swapUsed))" : ""
            return Summary(value: Fmt.pct(mem.fraction), subtitle: "\(Fmt.mem(mem.used)) of \(Fmt.mem(mem.total))\(swap)")
        case .disk:
            // Never say 100% while there is still free room.
            let used = disk.free > 0 ? min(disk.usedFraction, 0.99) : disk.usedFraction
            return Summary(value: Fmt.pct(used), subtitle: "\(Fmt.bytes(disk.free)) free of \(Fmt.bytes(disk.total))")
        case .diskio:
            return Summary(value: Fmt.bytes(disk.readBps) + "/s", subtitle: "Write \(Fmt.bytes(disk.writeBps))/s")
        case .network:
            if !net.online { return Summary(value: "Offline", subtitle: "Not connected") }
            return Summary(value: rate(net.downBps), subtitle: "Upload \(rate(net.upBps))")
        case .battery:
            guard let b = battery else { return Summary(value: "", subtitle: "") }
            return Summary(value: "\(Int(b.percent.rounded()))%", subtitle: batteryLine(b))
        case .sensors:
            let c = processorTemp() ?? hottest() ?? 0   // same sensor as the graph, header and menu bar (the graph line is a smoothed copy)
            return Summary(value: temp(c), subtitle: Self.tempWord(c))
        case .fans:
            let avg = fans.isEmpty ? 0 : fans.map(\.rpm).reduce(0, +) / Double(fans.count)
            return Summary(value: "\(Int(avg.rounded())) rpm", subtitle: fans.count == 1 ? "1 fan" : "\(fans.count) fans")
        case .bluetooth:
            guard let low = gadgets.map(\.percent).min() else { return Summary(value: "None", subtitle: "No gadgets connected") }
            return Summary(value: "\(Int(low.rounded()))%", subtitle: gadgets.map(\.name).prefix(2).joined(separator: ", "))
        case .clock:
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            let d = DateFormatter(); d.dateStyle = .full; d.timeStyle = .none
            return Summary(value: f.string(from: Date()), subtitle: d.string(from: Date()))
        }
    }

    /// Facts that never change while the Mac runs.
    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()
    static func sysInt(_ name: String) -> Int {
        var v: Int32 = 0; var l = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &l, nil, 0) == 0 ? Int(v) : 0
    }

    func batteryLine(_ b: BatteryInfo) -> String {
        if b.pluggedIn && (b.full || (!b.charging && b.percent >= 99)) { return "Fully charged" }
        if b.charging { return b.secondsLeft.map { "Charging · \(Fmt.duration($0)) to full" } ?? "Charging" }
        if b.pluggedIn { return "Plugged in, not charging" }
        return b.secondsLeft.map { "\(Fmt.duration($0)) left" } ?? "Working out time left"
    }

    static func tempWord(_ c: Double) -> String {
        switch c {
        case ..<55: "Cool"
        case ..<75: "Warm"
        case ..<90: "Hot"
        default: "Very hot"
        }
    }
    static func tempTint(_ c: Double) -> Color { c < 75 ? Pal.good : (c < 90 ? Pal.warn : Pal.bad) }

    func pressureWord() -> (text: String, tint: Color, short: String) {
        switch mem.pressure {
        case 2: ("Getting full", Pal.warn, "Filling up")
        case 4: ("Squeezed", Pal.bad, "Squeezed")
        default: ("Plenty of room", Pal.good, "Roomy")
        }
    }

    /// One line at the top of the panel, with a colour for how hard the Mac is working:
    /// green calm, amber busy, orange working hard, red hot or squeezed.
    /// It is judged on the last two minutes of readings and changes at most once a minute, so a short spike never flips it.
    /// The menu bar effort colour uses the same answer.
    var status: (text: String, tint: Color) {
        steady?.status ?? Self.judge(cpu: cpu.total, temp: mainTemp, pressure: mem.pressure, battery: battery)
    }

    static func judge(cpu: Double, temp: Double?, pressure: Int, battery: BatteryInfo?) -> (text: String, tint: Color) {
        if pressure >= 4 { return ("Memory is squeezed", Pal.bad) }
        if let t = temp, t >= 90 { return ("Running hot", Pal.bad) }
        if cpu > 0.8 { return ("Working hard", Pal.hard) }
        if pressure == 2 { return ("Memory is getting full", Pal.hard) }
        if let b = battery, !b.pluggedIn, b.percent < 15 { return ("Battery is low", Pal.hard) }
        if cpu > 0.45 { return ("Busy", Pal.warn) }
        if let t = temp, t >= 75 { return ("Warm", Pal.warn) }
        return ("Everything looks calm", Pal.good)
    }
    var overall: String { status.text }

    /// The last minute of one reading, 0 to 1, for the Live graph menu bar icon.
    func iconSeries(_ m: ModuleID) -> [Double] {
        switch m {
        case .network:
            let peak = max(netDown.max() ?? 1, 1); return netDown.map { $0 / peak }
        case .diskio:
            let peak = max(diskRead.max() ?? 1, diskWrite.max() ?? 1, 1)
            return diskRead.enumerated().map { i, r in min(1, (r + (i < diskWrite.count ? diskWrite[i] : 0)) / (peak * 2)) }
        default: return hist[m] ?? []
        }
    }

    func chartSeries(_ m: ModuleID) -> (series: [Series], max: Double?)? {
        switch m {
        case .cpu, .gpu:
            return ([Series(values: hist[m] ?? [], tint: m.tint)], 1)
        case .sensors:
            return ([Series(values: hist[m] ?? [], tint: m.tint)], 1)
        case .memory, .battery, .disk:
            return nil   // flat lines say nothing: memory shows a pressure pill, battery and storage a bar
        case .network:
            return ([Series(values: netDown, tint: m.tint), Series(values: netUp, tint: Pal.second)], nil)
        case .diskio:
            return ([Series(values: diskRead, tint: m.tint), Series(values: diskWrite, tint: Pal.second)], nil)
        default: return nil
        }
    }
}
