// SensorKeys.swift. Which system-controller (SMC) temperature keys each Apple chip has, and what they measure.
// Table taken from exelban/stats Modules/Sensors/values.swift and Modules/CPU/readers.swift (MIT).
// Apple chips report their real per-core temperatures through these keys; the hidden HID sensors only cover the power chips.
import Darwin

enum ChipGen { case m1, m2, m3, m4, m4Big, m5, m6, a18, intel, unknown

    /// Worked out once from the processor's name, the same way exelban/stats does ("Apple M2 Pro" is M2 family).
    static let current: ChipGen = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let name = String(cString: buf)
        if name.contains("Intel") { return .intel }
        if name.contains("A18") { return .a18 }
        let big = name.contains("Pro") || name.contains("Max") || name.contains("Ultra")
        for (tag, gen) in [("M1", ChipGen.m1), ("M2", .m2), ("M3", .m3), ("M4", .m4), ("M5", .m5), ("M6", .m6)] where name.contains(tag) {
            return gen == .m4 && big ? .m4Big : gen
        }
        return .unknown
    }()
}

/// One SMC temperature key: (key, label, group). Group names match the ones the Sensors tile already uses.
typealias SMCTempKey = (key: String, label: String, group: String)

enum SensorKeys {
    private static func cpu(_ keys: [String], _ kind: String) -> [SMCTempKey] {
        keys.enumerated().map { ($1, "CPU \(kind) core \($0 + 1)", "Processor") }
    }
    private static func gpu(_ keys: [String]) -> [SMCTempKey] {
        keys.enumerated().map { ($1, "GPU \($0 + 1)", "Graphics") }
    }

    /// Keys shared by every Apple chip.
    private static let appleCommon: [SMCTempKey] = [
        ("TaLP", "Airflow left", "Case"), ("TaRF", "Airflow right", "Case"),
        ("TH0x", "Storage chip", "Storage"), ("TB1T", "Battery 1", "Battery"), ("TB2T", "Battery 2", "Battery"),
        ("TW0P", "Wi-Fi", "Other"),
    ]

    /// Intel Macs: the classic keys (exelban reads these first for the processor figure).
    private static let intel: [SMCTempKey] = [
        ("TC0D", "CPU diode", "Processor"), ("TC0E", "CPU diode virtual", "Processor"), ("TC0F", "CPU diode filtered", "Processor"),
        ("TC0P", "CPU proximity", "Processor"), ("TC0H", "CPU heatsink", "Processor"),
        ("TG0D", "GPU diode", "Graphics"), ("TG0P", "GPU proximity", "Graphics"),
        ("TB0T", "Battery", "Battery"), ("TM0P", "Memory", "Memory"), ("Ts0P", "Palm rest", "Case"), ("TA0P", "Air inlet", "Case"),
    ]

    static func list(for gen: ChipGen) -> [SMCTempKey] {
        switch gen {
        case .m1:
            return cpu(["Tp09", "Tp0T"], "efficiency") + cpu(["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], "performance")
                + gpu(["Tg05", "Tg0D", "Tg0L", "Tg0T"])
                + [("Tm02", "Memory 1", "Memory"), ("Tm06", "Memory 2", "Memory"), ("Tm08", "Memory 3", "Memory"), ("Tm09", "Memory 4", "Memory")]
                + appleCommon
        case .m2:
            return cpu(["Tp1h", "Tp1t", "Tp1p", "Tp1l"], "efficiency")
                + cpu(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], "performance")
                + gpu(["Tg0f", "Tg0j"]) + appleCommon
        case .m3:
            return cpu(["Te05", "Te0L", "Te0P", "Te0S"], "efficiency")
                + cpu(["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"], "performance")
                + gpu(["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]) + appleCommon
        case .m4, .m4Big:
            let first: [String] = gen == .m4 ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"]
            return cpu(["Te05", "Te0S", "Te09", "Te0H"], "efficiency")
                + cpu(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], "performance")
                + gpu(first + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
                + [("Tm0p", "Memory 1", "Memory"), ("Tm1p", "Memory 2", "Memory"), ("Tm2p", "Memory 3", "Memory")]
                + appleCommon
        case .m5:
            return cpu(["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"], "super")
                + cpu(["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"], "performance")
                + gpu(["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]) + appleCommon
        case .m6:
            return cpu(["Tp0j", "Tp0g", "Tp09", "Tp07"], "super")
                + cpu(["Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05"], "performance")
                + cpu(["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"], "efficiency")
                + gpu(["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"]) + appleCommon
        case .a18:
            return cpu(["Te05", "Te0S"], "efficiency") + cpu(["Tp05", "Tp0D"], "performance")
                + gpu(["Tg05", "Tg0D", "Tg0L", "Tg0e"]) + appleCommon
        case .intel:
            return intel
        case .unknown:
            return appleCommon
        }
    }
}
