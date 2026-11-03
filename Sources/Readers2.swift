// Readers2.swift. Battery, graphics, temperatures, fans, Bluetooth gadgets and the busiest apps.
import Darwin
import Foundation
import IOKit
import IOKit.ps

private func registryProps(_ entry: io_registry_entry_t) -> [String: Any]? {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return props?.takeRetainedValue() as? [String: Any]
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

struct BatteryInfo {
    var percent = 0.0
    var charging = false, pluggedIn = false, full = false
    /// Seconds until empty (on battery) or full (charging); nil while the Mac is still working it out.
    var secondsLeft: Double?
    var cycles = 0
    var health: Double?
    var temperatureC: Double?
    var watts: Double?
    var adapterWatts: Double?
    /// What the battery holds when full now, and when new, in mAh.
    var holdsMAh: Double?, newMAh: Double?
    var volts: Double?
}

final class BatteryReader {
    /// Smoothed charge current in mA (the raw value jumps with every app that wakes up).
    private var ampEMA: Double?
    private var ampAt: TimeInterval = 0
    /// Smoothed discharge current in mA and how many readings it has seen (the Mac's own estimate averages old use, this follows the real draw).
    private var drainEMA: Double?
    private var drainN = 0
    private var drainAt: TimeInterval = 0
    /// How many seconds apart battery readings usually are (set by the monitor), so a slow refresh still builds a smoothed value.
    var drainGap: TimeInterval = 10

    private static func systemMinutes(_ key: String) -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let v = d[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    /// "Maximum Capacity" exactly as System Settings reports it (the raw registry figure wobbles by a point or two). Read in the
    /// background at most every six hours; nil until the first answer arrives.
    private static var systemHealth: Double?
    private static var healthAt: Date?
    private static func refreshSystemHealth() {
        if let at = healthAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        healthAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPPowerDataType"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8),
                  let r = text.range(of: #"Maximum Capacity:\s*(\d+)%"#, options: .regularExpression),
                  let n = Double(text[r].filter(\.isNumber)) else { return }
            DispatchQueue.main.async { systemHealth = n / 100 }
        }
    }

    func sample() -> BatteryInfo? {
        Self.refreshSystemHealth()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let p = registryProps(service) else { return nil }
        var b = BatteryInfo()
        if let cur = num(p["CurrentCapacity"]), let max = num(p["MaxCapacity"]), max > 0 {
            // On Apple chips CurrentCapacity is already a percentage.
            b.percent = max <= 100 ? cur : cur / max * 100
        }
        b.charging = (p["IsCharging"] as? Bool) ?? false
        b.pluggedIn = (p["ExternalConnected"] as? Bool) ?? false
        b.full = (p["FullyCharged"] as? Bool) ?? false
        b.cycles = Int(num(p["CycleCount"]) ?? 0)
        // Health = what the battery can still hold compared with new (the same figure System Settings shows).
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        if let design = num(p["DesignCapacity"]) ?? num(data["DesignCapacity"]), design > 0 {
            let now = num(data["NominalChargeCapacity"]) ?? num(p["NominalChargeCapacity"]) ?? num(p["AppleRawMaxCapacity"]) ?? num(data["AppleRawMaxCapacity"])
            if let now, now > 100 { b.health = min(1, now / design) }
        }
        if let t = num(p["Temperature"]) { b.temperatureC = t / 100 }
        b.newMAh = num(p["DesignCapacity"]) ?? num(data["DesignCapacity"])
        b.holdsMAh = num(data["NominalChargeCapacity"]) ?? num(p["NominalChargeCapacity"]) ?? num(p["AppleRawMaxCapacity"]) ?? num(data["AppleRawMaxCapacity"])
        // Prefer the figure System Settings shows, and keep the mAh line consistent with it.
        if let h = Self.systemHealth, let n = b.newMAh, n > 100 { b.health = h; b.holdsMAh = h * n }
        if let v = num(p["Voltage"]) { b.volts = v / 1000 }
        if let a = (p["Amperage"] as? NSNumber)?.int64Value, let v = num(p["Voltage"]) {
            b.watts = abs(Double(a)) * v / 1_000_000
        }
        if let ad = p["AdapterDetails"] as? [String: Any], let w = num(ad["Watts"]) { b.adapterWatts = w }
        if b.charging {
            // Our own estimate from what is really flowing into the battery: smoothed charge current, the charge still missing,
            // and the slow-down every lithium battery does after about 80% (current falls to about two thirds on average over the last fifth, measured 3 Nov on a 30 W charger).
            let now = ProcessInfo.processInfo.systemUptime
            if let a = (p["Amperage"] as? NSNumber).map({ Double($0.int64Value) }), a > 0 {
                if let e = ampEMA, now - ampAt < 60 { ampEMA = e + (a - e) * 0.3 } else { ampEMA = a }
                ampAt = now
            }
            let cap = num(data["AppleRawMaxCapacity"]) ?? num(p["AppleRawMaxCapacity"]) ?? 0
            let have = num(data["AppleRawCurrentCapacity"]) ?? num(p["AppleRawCurrentCapacity"]) ?? 0
            if let i = ampEMA, i >= 50, cap > 500, have > 0, have <= cap {
                let toTop = cap - have
                let knee = cap * 0.8
                let hours = have < knee ? (knee - have) / i + (cap - knee) / (i * 0.65) : toTop / (i * 0.65)
                b.secondsLeft = min(hours, 24) * 3600
            } else if let m = Self.systemMinutes("Time to Full Charge"), m > 0, m < 65535 { b.secondsLeft = m * 60 }
            else if let t = num(p["AvgTimeToFull"]), t > 0, t < 65535 { b.secondsLeft = t * 60 }
        } else if !b.pluggedIn {
            // Charge still inside the battery divided by the smoothed current flowing out of it right now.
            let now = ProcessInfo.processInfo.systemUptime
            if let a = (p["Amperage"] as? NSNumber)?.int64Value, a < 0 {
                let out = Double(-a)
                if let e = drainEMA, now - drainAt < max(60, drainGap * 3) { drainEMA = e + (out - e) * 0.15; drainN += 1 } else { drainEMA = out; drainN = 1 }
                drainAt = now
            }
            let have = num(data["AppleRawCurrentCapacity"]) ?? num(p["AppleRawCurrentCapacity"]) ?? 0
            if let out = drainEMA, drainN >= 4, out >= 50, have > 0 {
                b.secondsLeft = min(have / out, 48) * 3600
            } else {
                let est = IOPSGetTimeRemainingEstimate()
                if est > 0 { b.secondsLeft = est }
            }
        }
        if b.charging || b.pluggedIn { drainEMA = nil; drainN = 0 }
        if !b.charging { ampEMA = nil }
        return b
    }
}

final class GPUReader {
    private(set) var name: String = ""
    private(set) var cores = 0
    private(set) var renderer: Double?, tiler: Double?

    /// Graphics busy share 0...1, or nil when this Mac doesn't report it.
    func sample() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        var e = IOIteratorNext(iter)
        while e != 0 {
            if let p = registryProps(e) {
                if name.isEmpty, let m = p["model"] as? String { name = m }
                if cores == 0, let c = num(p["gpu-core-count"]) { cores = Int(c) }
                if let s = p["PerformanceStatistics"] as? [String: Any],
                   let u = num(s["Device Utilization %"]) ?? num(s["GPU Activity(%)"]) {
                    best = max(best ?? 0, u / 100)
                    renderer = num(s["Renderer Utilization %"]).map { $0 / 100 }
                    tiler = num(s["Tiler Utilization %"]).map { $0 / 100 }
                }
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        return best
    }
}

struct SensorReading: Identifiable {
    var id: String { raw }
    var raw: String
    var label: String
    var group: String
    var celsius: Double
}

struct FanReading: Identifiable {
    var id: Int
    var rpm: Double, minRPM: Double, maxRPM: Double
    var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

final class SensorReader {
    /// Temperatures. Apple chips are read through the hidden sensor service; Intel Macs through the system controller.
    func temperatures() -> [SensorReading] {
        var out: [SensorReading] = []
        let hid = AppleSiliconSensors(0xff00, 5, 15) as? [String: NSNumber] ?? [:]
        for (name, v) in hid {
            let c = v.doubleValue
            guard c > 0, c < 150 else { continue }
            let (group, label) = Self.friendly(name)
            out.append(SensorReading(raw: name, label: label, group: group, celsius: c))
        }
        if out.isEmpty, SMC.shared.isAvailable {
            let keys: [(String, String, String)] = [("TC0P", "Processor", "Processor"), ("TC0D", "Processor die", "Processor"),
                ("TG0P", "Graphics", "Graphics"), ("TB0T", "Battery", "Battery"), ("TM0P", "Memory", "Memory"),
                ("Ts0P", "Palm rest", "Case"), ("TA0P", "Air inlet", "Case")]
            for (k, label, group) in keys {
                if let v = SMC.shared.value(k), v > 0, v < 150 { out.append(SensorReading(raw: k, label: label, group: group, celsius: v)) }
            }
        }
        return out.sorted { ($0.group, $0.label) < ($1.group, $1.label) }
    }

    static func friendly(_ raw: String) -> (String, String) {
        let l = raw.lowercased()
        if l.contains("gas gauge") || l.contains("battery") { return ("Battery", "Battery") }
        if l.contains("nand") { return ("Storage", "Storage chip") }
        if l.contains("gpu") { return ("Graphics", raw) }
        if l.contains("tdie") || l.contains("acc") || l.contains("cpu") { return ("Processor", raw) }
        if l.contains("tdev") || l.contains("tcal") { return ("Power chip", raw) }
        return ("Other", raw)
    }

    func fans() -> [FanReading] {
        guard SMC.shared.isAvailable, let n = SMC.shared.value("FNum"), n >= 1 else { return [] }
        return (0..<Int(n)).compactMap { i in
            guard let rpm = SMC.shared.value("F\(i)Ac") else { return nil }
            return FanReading(id: i, rpm: rpm, minRPM: SMC.shared.value("F\(i)Mn") ?? 0, maxRPM: SMC.shared.value("F\(i)Mx") ?? max(rpm, 1))
        }
    }
}

struct GadgetInfo: Identifiable { var id: String; var name: String; var percent: Double }

enum BluetoothReader {
    /// Keyboards, mice and trackpads that report a battery level. No Bluetooth permission is needed for this.
    static func gadgets() -> [GadgetInfo] {
        var out: [GadgetInfo] = []
        var seen = Set<String>()
        for cls in ["AppleDeviceManagementHIDEventService", "AppleBluetoothHIDKeyboard", "BNBMouseDevice", "BNBTrackpadDevice"] {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { continue }
            var e = IOIteratorNext(iter)
            while e != 0 {
                if let p = registryProps(e), let pct = num(p["BatteryPercent"]) {
                    let name = (p["Product"] as? String) ?? "Bluetooth device"
                    let key = (p["DeviceAddress"] as? String) ?? name
                    if seen.insert(key).inserted { out.append(GadgetInfo(id: key, name: name, percent: pct)) }
                }
                IOObjectRelease(e)
                e = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        return out.sorted { $0.name < $1.name }
    }
}

struct ProcRow: Identifiable { var id: Int32; var name: String; var cpu: Double; var memory: Double }

/// The busiest apps. Only read while the panel is open.
final class ProcessReader {
    private var prev: [Int32: UInt64] = [:]
    private var prevAt: TimeInterval = 0
    private var names: [Int32: String] = [:]
    private let timebase: Double = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return Double(t.numer) / Double(t.denom)
    }()

    func sample(exactMemory: Bool = true) -> [ProcRow] {
        // proc_listallpids returns a number of processes (not bytes); the buffer size argument is in bytes.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride)))
        guard n > 0 else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        // After a long gap (panel closed) old tick counts would average a whole stretch of time, so start fresh.
        if prevAt > 0, now - prevAt > 15 { prev = [:]; prevAt = 0 }
        let dt = (now - prevAt) * 1e9
        var cur: [Int32: UInt64] = [:]
        var rows: [ProcRow] = []
        for pid in pids.prefix(n) where pid > 0 {
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.stride)) > 0 else { continue }
            let ticks = ti.pti_total_user &+ ti.pti_total_system
            cur[pid] = ticks
            var cpu = 0.0
            if prevAt > 0, dt > 0, let p = prev[pid], ticks >= p { cpu = Double(ticks - p) * timebase / dt }
            rows.append(ProcRow(id: pid, name: name(pid), cpu: cpu, memory: Double(ti.pti_resident_size)))
        }
        prev = cur; prevAt = now
        guard exactMemory else { return rows }
        // The exact memory figure (what Activity Monitor shows) costs a call per app, so only the biggest ones get it.
        let big = Set(rows.sorted { $0.memory > $1.memory }.prefix(40).map(\.id))
        for i in rows.indices where big.contains(rows[i].id) {
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(rows[i].id, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { rows[i].memory = Double(ru.ri_phys_footprint) }
        }
        return rows
    }

    private func name(_ pid: Int32) -> String {
        if let n = names[pid] { return n }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var result = "Unknown"
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") {
                result = URL(fileURLWithPath: String(path[..<r.lowerBound])).deletingPathExtension().lastPathComponent
            } else { result = URL(fileURLWithPath: path).lastPathComponent }
        }
        if result.hasPrefix("com.apple.") {
            switch result {
            case "com.apple.WebKit.WebContent": result = "Web page (WebKit)"
            case "com.apple.WebKit.GPU": result = "Web graphics (WebKit)"
            case "com.apple.WebKit.Networking": result = "Web network (WebKit)"
            default: result = String(result.dropFirst(10))
            }
        }
        names[pid] = result
        if names.count > 4000 { names.removeAll() }
        return result
    }

    /// Rows with the same app name (many helper processes) added together.
    static func merged(_ rows: [ProcRow]) -> [ProcRow] {
        var by: [String: ProcRow] = [:]
        for r in rows {
            if var e = by[r.name] { e.cpu += r.cpu; e.memory += r.memory; by[r.name] = e } else { by[r.name] = r }
        }
        return Array(by.values)
    }
}

/// This app's own cost, shown in Settings.
final class SelfMeter {
    private var last: (ns: UInt64, at: TimeInterval)?
    private let timebase: Double = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return Double(t.numer) / Double(t.denom)
    }()
    /// (cpu share of one core 0...1, memory in bytes)
    func sample() -> (cpu: Double, memory: Double) {
        var ru = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return (0, 0) }
        let ns = ru.ri_user_time &+ ru.ri_system_time
        let now = ProcessInfo.processInfo.systemUptime
        var cpu = 0.0
        if let l = last, now > l.at { cpu = Double(ns &- l.ns) * timebase / ((now - l.at) * 1e9) }
        last = (ns, now)
        return (cpu, Double(ru.ri_phys_footprint))
    }
}

/// Facts about the machine that never change while it runs.
enum Hardware {
    static let hasFans: Bool = !SensorReader().fans().isEmpty
    static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }()
}
