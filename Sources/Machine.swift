// Machine.swift. What this Mac is, in plain words, for the top of the panel.
import Foundation
import IOKit

enum Machine {
    /// Apple silicon Macs only report a code like "Mac14,2", so the common ones are named here.
    private static let known: [String: String] = [
        "MacBookAir10,1": "MacBook Air (2020)", "Mac14,2": "MacBook Air (2022)", "Mac14,15": "MacBook Air 15\" (2023)",
        "Mac15,12": "MacBook Air 13\" (2024)", "Mac15,13": "MacBook Air 15\" (2024)", "Mac16,12": "MacBook Air 13\" (2025)", "Mac16,13": "MacBook Air 15\" (2025)",
        "MacBookPro17,1": "MacBook Pro 13\" (2020)", "MacBookPro18,1": "MacBook Pro 16\" (2021)", "MacBookPro18,2": "MacBook Pro 16\" (2021)",
        "MacBookPro18,3": "MacBook Pro 14\" (2021)", "MacBookPro18,4": "MacBook Pro 14\" (2021)", "Mac14,7": "MacBook Pro 13\" (2022)",
        "Mac14,5": "MacBook Pro 14\" (2023)", "Mac14,9": "MacBook Pro 14\" (2023)", "Mac14,6": "MacBook Pro 16\" (2023)", "Mac14,10": "MacBook Pro 16\" (2023)",
        "Mac15,3": "MacBook Pro 14\" (2023)", "Mac15,6": "MacBook Pro 14\" (2023)", "Mac15,8": "MacBook Pro 14\" (2023)", "Mac15,10": "MacBook Pro 14\" (2023)",
        "Mac15,7": "MacBook Pro 16\" (2023)", "Mac15,9": "MacBook Pro 16\" (2023)", "Mac15,11": "MacBook Pro 16\" (2023)",
        "Mac16,1": "MacBook Pro 14\" (2024)", "Mac16,6": "MacBook Pro 14\" (2024)", "Mac16,8": "MacBook Pro 14\" (2024)",
        "Mac16,5": "MacBook Pro 16\" (2024)", "Mac16,7": "MacBook Pro 16\" (2024)",
        "Macmini9,1": "Mac mini (2020)", "Mac14,3": "Mac mini (2023)", "Mac14,12": "Mac mini (2023)", "Mac16,10": "Mac mini (2024)", "Mac16,11": "Mac mini (2024)",
        "iMac21,1": "iMac (2021)", "iMac21,2": "iMac (2021)", "Mac15,4": "iMac (2023)", "Mac15,5": "iMac (2023)", "Mac16,2": "iMac (2024)", "Mac16,3": "iMac (2024)",
        "Mac13,1": "Mac Studio (2022)", "Mac13,2": "Mac Studio (2022)", "Mac14,13": "Mac Studio (2023)", "Mac14,14": "Mac Studio (2023)", "Mac14,8": "Mac Pro (2023)",
    ]

    /// "MacBook Air (2022)" and so on, read from the Mac's own model code; Intel codes ("MacBookPro16,1") are made readable too.
    static let name: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let id = String(cString: buf)
        if let n = known[id] { return n }
        let family = id.prefix { $0.isLetter }
        let spaced = String(family).replacingOccurrences(of: "MacBook", with: "MacBook ").replacingOccurrences(of: "Pro", with: " Pro")
            .replacingOccurrences(of: "Air", with: " Air").replacingOccurrences(of: "mini", with: " mini")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return spaced.isEmpty || spaced == "Mac" ? "This Mac" : spaced
    }()

    /// "macOS 27.2"
    static var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.minorVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion)" : "macOS \(v.majorVersion)"
    }

    /// Short facts for the header chips: chip, cores, memory.
    static func chips(gpuCores: Int) -> [String] {
        var out: [String] = []
        let chip = Monitor.chipName.replacingOccurrences(of: "Apple ", with: "")
        out.append(chip.isEmpty ? "Apple silicon" : chip)
        let cpu = Monitor.sysInt("hw.physicalcpu")
        if cpu > 0 { out.append(gpuCores > 0 ? "\(cpu) CPU · \(gpuCores) GPU cores" : "\(cpu) CPU cores") }
        out.append(Fmt.mem(Double(ProcessInfo.processInfo.physicalMemory)))
        return out
    }
}
