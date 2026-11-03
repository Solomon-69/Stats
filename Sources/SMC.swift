// SMC.swift. Read-only access to the Mac's system controller (fan speeds, older temperature keys).
// Based on the SMC code in exelban/stats (MIT).
import Foundation
import IOKit

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct Limit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: IOByteCount32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
    var key: UInt32 = 0
    var vers = Vers()
    var pLimit = Limit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    static let shared = SMC()
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        if IOServiceOpen(service, mach_task_self_, 0, &conn) != kIOReturnSuccess { conn = 0 }
        IOObjectRelease(service)
    }

    var isAvailable: Bool { conn != 0 }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        var size = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
    }

    /// The value of a four-letter key as a number, or nil when this Mac doesn't have it.
    func value(_ key: String) -> Double? {
        guard conn != 0, key.utf8.count == 4 else { return nil }
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = fourCC(key)
        let info: SMCKeyData.KeyInfo
        if let cached = infoCache[input.key] { info = cached } else {
            input.data8 = 9
            guard call(&input, &output) == kIOReturnSuccess, output.result == 0, output.keyInfo.dataSize > 0 else { return nil }
            info = output.keyInfo
            infoCache[input.key] = info
        }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        let raw = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        let type = String(decoding: [UInt8(info.dataType >> 24 & 0xff), UInt8(info.dataType >> 16 & 0xff),
                                     UInt8(info.dataType >> 8 & 0xff), UInt8(info.dataType & 0xff)], as: UTF8.self)
        func u16() -> Double { Double(Int(raw[0]) << 8 | Int(raw[1])) }
        switch type {
        case "ui8 ": return raw.count >= 1 ? Double(raw[0]) : nil
        case "ui16": return raw.count >= 2 ? u16() : nil
        case "ui32": return raw.count >= 4 ? Double(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])) : nil
        case "sp78": return raw.count < 2 ? nil : Double(Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1]))) / 256
        case "fpe2": return raw.count < 2 ? nil : Double((Int(raw[0]) << 6) + (Int(raw[1]) >> 2))
        case "flt ": return raw.count >= 4 ? Double(raw.withUnsafeBytes { $0.load(as: Float.self) }) : nil
        default: return nil
        }
    }
}
