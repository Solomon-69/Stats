// Model.swift. What the app knows: the module list, the user's choices, and the live numbers.
import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum ModuleID: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, memory, disk, diskio, network, battery, sensors, fans, bluetooth, clock
    /// The clock was removed from Stats (3 Nov): it stays decodable so old saved settings load, but is never listed, shown or drawn.
    static var allCases: [ModuleID] { [.cpu, .gpu, .memory, .disk, .diskio, .network, .battery, .sensors, .fans, .bluetooth] }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "Processor"
        case .gpu: "Graphics"
        case .memory: "Memory used"
        case .disk: "Storage"
        case .diskio: "Disk activity"
        case .network: "Internet"
        case .battery: "Battery"
        case .sensors: "Temperature"
        case .fans: "Fans"
        case .bluetooth: "Bluetooth gadgets"
        case .clock: "Clock"
        }
    }
    var short: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .disk: "DISK"
        case .diskio: "I/O"
        case .network: "NET"
        case .battery: "BAT"
        case .sensors: "TEMP"
        case .fans: "FAN"
        case .bluetooth: "BT"
        case .clock: "TIME"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .diskio: "arrow.left.arrow.right"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .sensors: "thermometer.medium"
        case .fans: "fan"
        case .bluetooth: "keyboard"
        case .clock: "clock"
        }
    }
    /// What the module does, in plain words (Settings subtitle).
    var blurb: String {
        switch self {
        case .cpu: "How busy the Mac's brain is"
        case .gpu: "How hard the graphics chip works"
        case .memory: "How much working space is in use"
        case .disk: "Total size, free space and what is using it"
        case .diskio: "How fast the drive reads and writes"
        case .network: "Download and upload speed"
        case .battery: "Charge, time left and battery health"
        case .sensors: "How warm the chips are"
        case .fans: "How fast the fans spin"
        case .bluetooth: "Battery of your keyboard, mouse and trackpad"
        case .clock: "Time in other places"
        }
    }
    var tint: Color { ThemeStore.colourfulTiles ? Color(nsColor: ModuleID.tints[self] ?? .systemOrange) : Pal.accent }
    static let tints: [ModuleID: NSColor] = [
        .cpu: dyn(0xD63A28, 0xFF5A47), .gpu: dyn(0x7C4DDB, 0xB388FF), .memory: dyn(0x14935E, 0x3DDC97),
        .disk: dyn(0xB87800, 0xFFB000), .diskio: dyn(0xC25E00, 0xFF8A3D), .network: dyn(0x0A84C6, 0x35C2FF), .battery: dyn(0x5E9A00, 0xA3E635),
        .sensors: dyn(0xD4287A, 0xFF4FA0), .fans: dyn(0x5A7184, 0x8FA6B8), .bluetooth: dyn(0x2F5FD6, 0x5B8CFF),
        .clock: dyn(0x8A7650, 0xC9B38A),
    ]
}

extension ModuleID {
    /// What the Live graph menu bar icon can follow, with short labels for the picker.
    /// Parts this Mac really has: a MacBook Air has no fans, a desktop has no battery. Settings only lists what exists.
    var availableHere: Bool {
        switch self {
        case .fans: return Hardware.hasFans
        case .battery: return Hardware.hasBattery
        default: return true
        }
    }
    /// What can be pinned to the menu bar as its own live readout (all of these are read while the panel is closed).
    static let extraChoices: [ModuleID] = [.cpu, .gpu, .memory, .disk, .diskio, .network, .battery]
    static let liveChoices: [ModuleID] = [.cpu, .gpu, .memory, .diskio, .network, .sensors]
    var liveLabel: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .diskio: "Disk"
        case .network: "Internet"
        case .sensors: "Temp"
        default: title
        }
    }
}

/// What the main Stats icon in the menu bar looks like.
enum MainIcon: String, CaseIterable, Identifiable {
    case bars, chip, pulse, live, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bars: "Bars"
        case .chip: "Chip"
        case .pulse: "Pulse"
        case .live: "Live graph"
        case .hidden: "Hidden"
        }
    }
    /// Needs the processor reading even when the processor tile is off.
    var needsCPU: Bool { self == .live }
    var width: CGFloat { self == .live ? 40 : 28 }
}

/// Everything the user can change. Each one saves the moment it changes.
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard
    @Published var shown: Set<ModuleID> { didSet { d.set(shown.map(\.rawValue), forKey: "shown") } }
    /// The tile that opens by itself each time the panel opens ("" = none). Chosen in Settings, remembered between launches.
    @Published var openTab: String { didSet { d.set(openTab, forKey: "openTab") } }
    @Published var refresh: Int { didSet { d.set(refresh, forKey: "refresh") } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "fahrenheit") } }
    @Published var netBits: Bool { didSet { d.set(netBits, forKey: "netBits") } }
    /// 0 = follow the Mac, 1 = light, 2 = dark.
    @Published var appearance: Int { didSet { d.set(appearance, forKey: "appearance") } }
    /// Which colour theme (see ThemeStore).
    @Published var themeIndex: Int { didSet { d.set(themeIndex, forKey: "themeIndex"); ThemeStore.current = ThemeStore.all[min(max(themeIndex, 0), ThemeStore.all.count - 1)] } }
    @Published var colourfulTiles: Bool { didSet { d.set(colourfulTiles, forKey: "colourfulTiles"); ThemeStore.colourfulTiles = colourfulTiles; themeIndex = colourfulTiles ? 0 : 4 } }
    @Published var mainIcon: MainIcon { didSet { d.set(mainIcon.rawValue, forKey: "mainIcon") } }
    /// The icon turns green, amber or red with how hard the Mac is working.
    /// What the Live graph icon draws.
    @Published var iconSource: ModuleID { didSet { d.set(iconSource.rawValue, forKey: "iconSource") } }
    @Published var iconTinted: Bool { didSet { d.set(iconTinted, forKey: "iconTinted") } }
    /// Which accent colour the Settings screens use (an index into SettingsAccent.all). Never touches the panel or icons.
    @Published var settingsAccent: Int {
        didSet { d.set(settingsAccent, forKey: "settingsAccent"); SettingsAccent.current = SettingsAccent.clamp(settingsAccent) }
    }
    /// Kept for the test hooks: the hidden icon is one of the icon choices.
    var invisibleIcon: Bool {
        get { mainIcon == .hidden }
        set { mainIcon = newValue ? .hidden : .bars }
    }
    /// Extra live readouts, each its own small item in the menu bar (empty by default).
    @Published var extras: [ModuleID] { didSet { d.set(extras.map(\.rawValue), forKey: "extras") } }
    @Published var zones: [String] { didSet { d.set(zones, forKey: "zones") } }
    /// Opt-in: look up the public address and delay to the internet (asks the internet, so it is off until chosen).
    @Published var internetChecks: Bool { didSet { d.set(internetChecks, forKey: "internetChecks") } }
    /// Opt-in: plain alerts for low battery, full storage and squeezed memory.
    @Published var alerts: Bool { didSet { d.set(alerts, forKey: "alerts"); if alerts { Alerts.ask() } } }
    @Published var launchAtLogin: Bool
    /// Off by default: Stats lives in the menu bar only. On adds it to the Dock and the app switcher too.
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }

    init() {
        let raw = d.stringArray(forKey: "shown")
        shown = raw.map { Set($0.compactMap(ModuleID.init(rawValue:)).filter { $0 != .clock }) } ?? [.cpu, .gpu, .memory, .disk, .diskio, .network, .battery, .sensors, .fans, .bluetooth]
        // Stats has one menu bar icon. Older versions could add one per module: forget those choices for good.
        d.removeObject(forKey: "barStyles")
        refresh = d.object(forKey: "refresh") as? Int ?? 2
        openTab = d.string(forKey: "openTab") ?? ""
        fahrenheit = d.bool(forKey: "fahrenheit")
        // Internet speeds are quoted in megabits a second everywhere (phone testers, providers), so that is the default.
        netBits = d.object(forKey: "netBits") as? Bool ?? true
        extras = (d.stringArray(forKey: "extras") ?? []).compactMap(ModuleID.init(rawValue:)).filter { ModuleID.extraChoices.contains($0) && $0.availableHere }
        appearance = d.integer(forKey: "appearance")
        mainIcon = d.string(forKey: "mainIcon").flatMap(MainIcon.init(rawValue:)) ?? (d.bool(forKey: "invisibleIcon") ? .hidden : .bars)
        iconTinted = d.bool(forKey: "iconTinted")
        let accent = SettingsAccent.clamp(d.integer(forKey: "settingsAccent"))
        settingsAccent = accent
        SettingsAccent.current = accent
        iconSource = d.string(forKey: "iconSource").flatMap(ModuleID.init(rawValue:)).flatMap { ModuleID.liveChoices.contains($0) ? $0 : nil } ?? .cpu
        // The colourful look is the only look now (the switch was removed), whatever an older version saved.
        themeIndex = 0
        ThemeStore.current = ThemeStore.all[0]
        colourfulTiles = true
        ThemeStore.colourfulTiles = true
        zones = d.stringArray(forKey: "zones") ?? ["America/New_York", "Europe/London", "Asia/Tokyo"]
        internetChecks = d.bool(forKey: "internetChecks")
        alerts = d.bool(forKey: "alerts")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showInDock = d.bool(forKey: "showInDock")
        // Disk activity arrived after first releases: switch it on once for people who already have saved choices.
        if !d.bool(forKey: "seenDiskIO") { d.set(true, forKey: "seenDiskIO"); if raw != nil { shown.insert(.diskio) } }
    }

}

/// The live numbers. Samples on a timer; the panel redraws only while it is open.
final class Monitor: ObservableObject {
    /// On-demand internet speed test (the network tile's Test speed button).
    let speed = SpeedTest()
    let prefs: Prefs
    var onTick: () -> Void = {}

    private let cpuR = CPUReader(), memR = MemReader(), diskR = DiskReader(), netR = NetReader()
    private let batR = BatteryReader(), gpuR = GPUReader(), senR = SensorReader(), procR = ProcessReader()
    let selfMeter = SelfMeter()

    var cpu = CPUInfo(), mem = MemInfo(), disk = DiskInfo(), net = NetInfo()
    var battery: BatteryInfo?, gpu: Double?, gpuName = "", gpuCores = 0, gpuRender: Double?, gpuTile: Double?
    let netX = NetExtras(), alertsR = Alerts()
    private var netCheckAt: TimeInterval = 0
    var temps: [SensorReading] = [], fans: [FanReading] = [], gadgets: [GadgetInfo] = []
    var procs: [ProcRow] = []
    var hist: [ModuleID: [Double]] = [:]
    var netDown: [Double] = [], netUp: [Double] = [], diskRead: [Double] = [], diskWrite: [Double] = []
    var ownCPU = 0.0, ownMemory = 0.0
    let keep = 60
    var sampleAt = ProcessInfo.processInfo.systemUptime

    /// True while the panel or Settings is on screen: only then do we redraw views and read the app list.
    var visible = false {
        didSet {
            guard visible != oldValue else { return }
            restartTimer()
            if visible { sampleSlow(); sample(); objectWillChange.send() }
        }
    }
    /// Seconds between samples: once a second while the panel is open so the graphs glide, the chosen refresh otherwise.
    var interval: TimeInterval {
        if visible { return 2 }
        // Low Power Mode: wake less often while nothing is on screen.
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? max(5, TimeInterval(prefs.refresh)) : TimeInterval(max(1, prefs.refresh))
    }
    @Published var expanded: ModuleID?
    /// The Temperature tile's "Show all sensors" view: that one tile fills the panel so as many sensors as possible show.
    @Published var allSensors = false
    @Published var openCount = 0

    private var timer: Timer?
    private var slowAt: TimeInterval = 0
    private var ownAt: TimeInterval = 0
    private var procAt: TimeInterval = 0
    private var tempEMA: Double?
    var tempsAt: TimeInterval = 0
    /// The temperature graph always spans this fixed range, so its line sits in the same place and never jumps.
    static let tempFloor = 30.0, tempCeil = 100.0

    /// Readings from the last two minutes, and the status label they gave (with when it last changed).
    private var statusLog: [(t: TimeInterval, cpu: Double, temp: Double?, pressure: Int)] = []
    private(set) var steady: (status: (text: String, tint: Color), at: TimeInterval)?
    static let statusWindow = 120.0, statusMinGap = 60.0

    init(prefs: Prefs) { self.prefs = prefs }

    /// Averages the last two minutes into one status, and lets it change at most once a minute.
    private func updateSteady(_ now: TimeInterval) {
        statusLog.append((now, cpu.total, mainTemp, mem.pressure))
        statusLog.removeAll { now - $0.t > Self.statusWindow }
        let n = Double(statusLog.count)
        let avgCPU = statusLog.map(\.cpu).reduce(0, +) / n
        let temps = statusLog.compactMap(\.temp)
        let avgTemp = temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
        let avgPressure = statusLog.map { Double($0.pressure) }.reduce(0, +) / n
        let pressure = avgPressure >= 3 ? 4 : (avgPressure >= 1.5 ? 2 : 1)
        let next = Self.judge(cpu: avgCPU, temp: avgTemp, pressure: pressure, battery: battery)
        guard let s = steady else { steady = (next, now); return }
        if s.status.text != next.text && now - s.at >= Self.statusMinGap { steady = (next, now) }
    }

    func start() {
        sampleSlow(); sample()
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = visible ? 0.1 : 0.5   // lets macOS group our wake-ups with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func needs(_ m: ModuleID) -> Bool {
        if prefs.mainIcon == .live && m == prefs.iconSource { return true }
        if prefs.extras.contains(m) || (m == .disk && prefs.extras.contains(.diskio)) { return true }
        if visible { return prefs.shown.contains(m) }
        // Cheap readings keep running while the panel is closed, so its graphs open already full of recent history.
        if prefs.shown.contains(m), [.cpu, .memory, .gpu, .disk, .diskio, .network, .battery].contains(m) { return true }
        return prefs.alerts && (m == .battery || m == .disk || m == .memory)
    }

    private func push(_ m: ModuleID, _ v: Double) {
        var a = hist[m] ?? []
        a.append(max(0, v)); if a.count > keep { a.removeFirst(a.count - keep) }
        hist[m] = a
    }
    private func append(_ a: inout [Double], _ v: Double) {
        a.append(max(0, v)); if a.count > keep { a.removeFirst(a.count - keep) }
    }

    #if STATS_TEST
    /// Tests freeze the readings so two pictures of the panel can be compared pixel for pixel.
    var frozen = false
    #endif

    func sample() {
        #if STATS_TEST
        if frozen { return }
        #endif
        sampleAt = ProcessInfo.processInfo.systemUptime
        if needs(.cpu), let c = cpuR.sample() { cpu = c; push(.cpu, c.total) }
        if needs(.memory), let m = memR.sample() { mem = m; push(.memory, m.fraction) }
        if needs(.gpu), let g = gpuR.sample() { gpu = g; gpuName = gpuR.name; gpuCores = gpuR.cores; gpuRender = gpuR.renderer; gpuTile = gpuR.tiler; push(.gpu, g) }
        if needs(.disk) || needs(.diskio) {
            disk = diskR.sample()
            append(&diskRead, disk.readBps); append(&diskWrite, disk.writeBps)
            push(.disk, disk.usedFraction)
        }
        if needs(.network) {
            net = netR.sample()
            append(&netDown, net.downBps); append(&netUp, net.upBps)
            push(.network, net.downBps + net.upBps)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - slowAt >= max(visible ? 5 : 10, Double(prefs.refresh)) { sampleSlow() }
        // Slow readings repeat their last value every tick so every graph has the same time scale; temperature is smoothed.
        if let b = battery { push(.battery, b.percent / 100) }
        // Sensors are only read while the panel is open, so the graph only gets points while the reading is fresh.
        if now - tempsAt >= 30 { tempEMA = nil }
        if now - tempsAt < 30, let hot = processorTemp() ?? hottest() {
            tempEMA = tempEMA.map { $0 + (hot - $0) * 0.25 } ?? hot
            push(.sensors, ((tempEMA ?? hot) - Self.tempFloor) / (Self.tempCeil - Self.tempFloor))
        }
        if visible && prefs.internetChecks && expanded == .network && now - netCheckAt > 30 {
            netCheckAt = now
            netX.refresh { [weak self] in self?.objectWillChange.send() }
        }
        updateSteady(now)
        if visible {
            // The app list is the costliest reading (one call per running app), so it is only kept fresh while a tile that
            // lists apps is open; otherwise it refreshes every 10 seconds for the "Busiest" line.
            let listing = expanded == .cpu || expanded == .memory
            if now - procAt >= (listing ? 3 : 10) { procAt = now; procs = procR.sample(exactMemory: expanded == .memory) }
            if now - ownAt > 2 { ownAt = now; let s = selfMeter.sample(); ownCPU = s.cpu; ownMemory = s.memory }
            objectWillChange.send()
        }
        onTick()
    }

    func sampleSlow() {
        slowAt = ProcessInfo.processInfo.systemUptime
        batR.drainGap = max(5, Double(prefs.refresh))
        if needs(.battery) { battery = batR.sample() }
        if prefs.alerts { alertsR.check(battery: battery, disk: disk, mem: mem) }
        // Sensors, fans and gadgets are only read while the panel is open, or when pinned to the menu bar.
        func live(_ x: ModuleID) -> Bool { needs(x) && (visible || (x == .sensors && temps.isEmpty) || (x == .sensors && prefs.mainIcon == .live && prefs.iconSource == .sensors)) }
        if live(.sensors) {
            temps = senR.temperatures()
            tempsAt = ProcessInfo.processInfo.systemUptime
        }
        if live(.fans) || (needs(.fans) && fans.isEmpty) { fans = senR.fans() }
        if live(.bluetooth) || (needs(.bluetooth) && gadgets.isEmpty) { gadgets = BluetoothReader.gadgets() }
    }

    // MARK: Plain-words helpers

    /// Modules that have something to show on this Mac, in panel order.
    var panelModules: [ModuleID] {
        ModuleID.allCases.filter { m in
            guard prefs.shown.contains(m) else { return false }
            switch m {
            case .battery: return battery != nil
            case .fans: return !fans.isEmpty
            case .bluetooth: return !gadgets.isEmpty
            case .gpu: return gpu != nil
            case .sensors: return !temps.isEmpty
            default: return true
            }
        }
    }

    func topByCPU(_ n: Int = 5) -> [ProcRow] {
        ProcessReader.merged(procs).filter { $0.cpu > 0.001 }.sorted { $0.cpu > $1.cpu }.prefix(n).map { $0 }
    }
    func topByMemory(_ n: Int = 5) -> [ProcRow] {
        ProcessReader.merged(procs).sorted { $0.memory > $1.memory }.prefix(n).map { $0 }
    }

    func temp(_ c: Double) -> String { prefs.fahrenheit ? "\(Int((c * 9 / 5 + 32).rounded()))°F" : "\(Int(c.rounded()))°C" }
    func hottest() -> Double? { temps.map(\.celsius).max() }
    /// The one temperature shown everywhere (tile, menu bar, graph, header): the average of the processor core sensors,
    /// the same "Average CPU" figure exelban/stats shows for its CPU temperature.
    func processorTemp() -> Double? {
        let p = temps.filter { $0.group == "Processor" }.map(\.celsius)
        return p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
    }
    /// That figure, or nil when it is stale (sensors are not read while the panel is closed), so old numbers never colour the header or icon.
    var mainTemp: Double? {
        guard ProcessInfo.processInfo.systemUptime - tempsAt < 30 else { return nil }
        return processorTemp() ?? hottest()
    }

    /// Bytes per second as readable text ("1.2 MB/s" or "9.6 Mbps").
    func rate(_ bps: Double) -> String {
        if prefs.netBits {
            let b = bps * 8
            if b >= 1e9 { return String(format: "%.1f Gbps", b / 1e9) }
            if b >= 1e6 { return String(format: "%.1f Mbps", b / 1e6) }
            if b >= 1e3 { return String(format: "%.0f Kbps", b / 1e3) }
            return String(format: "%.0f bps", b)
        }
        return Fmt.bytes(bps) + "/s"
    }
}

enum Fmt {
    /// Memory sizes the way Activity Monitor writes them (1 GB = 1024 MB).
    static func mem(_ v: Double) -> String {
        let g = 1024.0 * 1024 * 1024
        if v >= g { return String(format: "%.1f GB", v / g) }
        if v >= g / 1024 { return String(format: "%.0f MB", v / (g / 1024)) }
        return String(format: "%.0f KB", v / 1024)
    }
    static func bytes(_ v: Double) -> String {
        if v >= 1e12 { return String(format: "%.1f TB", v / 1e12) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return String(format: "%.0f B", v)
    }
    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m >= 1440 { return "\(m / 1440) d \((m % 1440) / 60) h" }
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(max(1, m)) min"
    }
}

func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func c(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    let l = c(light), d = c(dark)
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
}
