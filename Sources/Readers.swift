// Readers.swift. Reads the Mac's live numbers: processor, memory, disk, network. Each reader keeps
// the last sample so it can work out "per second" figures. Everything is read with cheap system calls.
// Approach follows exelban/stats (MIT).
import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct CPUInfo {
    var total = 0.0, user = 0.0, system = 0.0
    var cores: [Double] = []
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var uptime: TimeInterval = 0
}

final class CPUReader {
    private var prev: [[UInt32]] = []

    func sample() -> CPUInfo? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        var now: [[UInt32]] = []
        for i in 0..<Int(count) {
            now.append((0..<stride).map { UInt32(bitPattern: info[i * stride + $0]) })
        }
        defer { prev = now }
        guard prev.count == now.count else { return nil }
        var out = CPUInfo()
        var sumU = 0.0, sumS = 0.0, sumAll = 0.0
        for i in 0..<now.count {
            let u = Double(now[i][Int(CPU_STATE_USER)] &- prev[i][Int(CPU_STATE_USER)])
            let s = Double(now[i][Int(CPU_STATE_SYSTEM)] &- prev[i][Int(CPU_STATE_SYSTEM)])
            let idle = Double(now[i][Int(CPU_STATE_IDLE)] &- prev[i][Int(CPU_STATE_IDLE)])
            let n = Double(now[i][Int(CPU_STATE_NICE)] &- prev[i][Int(CPU_STATE_NICE)])
            let all = u + s + idle + n
            out.cores.append(all > 0 ? (u + s + n) / all : 0)
            sumU += u + n; sumS += s; sumAll += all
        }
        if sumAll > 0 { out.user = sumU / sumAll; out.system = sumS / sumAll; out.total = out.user + out.system }
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        out.load1 = l[0]; out.load5 = l[1]; out.load15 = l[2]
        var tv = timeval(); var size = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            out.uptime = Date().timeIntervalSince1970 - TimeInterval(tv.tv_sec)
        }
        return out
    }
}

struct MemInfo {
    var total = 0.0, used = 0.0, app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0, free = 0.0
    var swapUsed = 0.0
    /// 1 = fine, 2 = getting full, 4 = squeezed (the Mac's own pressure level).
    var pressure = 1
    var fraction: Double { total > 0 ? used / total : 0 }
}

final class MemReader {
    private let pageSize = Double(getpagesize())
    private let total: Double = {
        var v: UInt64 = 0; var s = MemoryLayout<UInt64>.stride
        sysctlbyname("hw.memsize", &v, &s, nil, 0)
        return Double(v)
    }()

    func sample() -> MemInfo? {
        var st = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        var m = MemInfo()
        m.total = total
        let internalPages = Double(st.internal_page_count), purgeable = Double(st.purgeable_count)
        m.app = max(0, internalPages - purgeable) * pageSize
        m.wired = Double(st.wire_count) * pageSize
        m.compressed = Double(st.compressor_page_count) * pageSize
        m.cached = (Double(st.external_page_count) + purgeable) * pageSize
        m.free = Double(st.free_count) * pageSize
        m.used = m.app + m.wired + m.compressed
        var level: Int32 = 1; var ls = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &ls, nil, 0) == 0 { m.pressure = Int(level) }
        var sw = xsw_usage(); var ss = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &sw, &ss, nil, 0) == 0 { m.swapUsed = Double(sw.xsu_used) }
        return m
    }
}

struct VolumeInfo: Identifiable { var id: String; var name: String; var total: Double; var free: Double }

struct DiskInfo {
    var total = 0.0, free = 0.0
    var readBps = 0.0, writeBps = 0.0
    /// Space the Mac can clear by itself (caches, old snapshots); counted as free in `free`.
    var purgeable = 0.0
    /// Bytes read and written since the Mac started.
    var readTotal = 0.0, writeTotal = 0.0
    var name = "", format = ""
    var volumes: [VolumeInfo] = []
    var usedFraction: Double { total > 0 ? (total - free) / total : 0 }
}

final class DiskReader {
    private var last: (read: UInt64, write: UInt64, at: TimeInterval)?
    private var volumeCache: [VolumeInfo] = []
    private var volumeAt: TimeInterval = 0

    func sample() -> DiskInfo {
        var d = DiskInfo()
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeNameKey]) {
            d.total = Double(v.volumeTotalCapacity ?? 0)
            d.free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            d.purgeable = max(0, d.free - Double(v.volumeAvailableCapacity ?? 0))
            d.name = v.volumeName ?? "Macintosh HD"
        }
        var fs = statfs()
        if statfs("/", &fs) == 0 { d.format = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0).uppercased() } } }
        let now = ProcessInfo.processInfo.systemUptime
        // A failed read keeps the last good one, so a single miss never turns the lifetime total into a fake speed spike.
        let io = ioBytes() ?? last.map { (read: $0.read, write: $0.write) } ?? (read: 0, write: 0)
        if let l = last, now > l.at {
            let dt = now - l.at
            d.readBps = Double(io.read >= l.read ? io.read - l.read : 0) / dt
            d.writeBps = Double(io.write >= l.write ? io.write - l.write : 0) / dt
        }
        last = (io.read, io.write, now)
        d.readTotal = Double(io.read); d.writeTotal = Double(io.write)
        if now - volumeAt > 30 {
            volumeAt = now
            volumeCache = volumes()
        }
        d.volumes = volumeCache
        return d
    }

    private func ioBytes() -> (read: UInt64, write: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        var e = IOIteratorNext(iter)
        while e != 0 {
            // Mounted disk images (.dmg) have a driver of their own whose reads the real drive counts again, so skip them.
            var path = [CChar](repeating: 0, count: 512)
            let isImage = IORegistryEntryGetPath(e, kIOServicePlane, &path) == KERN_SUCCESS
                && { let p = String(cString: path); return p.contains("DiskImage") || p.contains("HDIX") }()
            // Ask for the one property we need, not the whole (large) registry entry.
            if !isImage, let s = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                r &+= (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        return (r, w)
    }

    private func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), (v.volumeIsLocal ?? false),
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            if u.path.hasPrefix("/System/Volumes") || u.path.hasPrefix("/private") { return nil }
            return VolumeInfo(id: u.path, name: v.volumeName ?? u.lastPathComponent, total: Double(total),
                              free: Double(v.volumeAvailableCapacityForImportantUsage ?? 0))
        }
    }
}

struct NetInfo {
    var downBps = 0.0, upBps = 0.0
    var interface = "", kind = "", address = ""
    var online = false
    /// Bytes moved since Stats was opened.
    var downTotal = 0.0, upTotal = 0.0
}

final class NetReader {
    private var last: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastAt: TimeInterval = 0
    private var kinds: [String: String] = [:]
    private var sumDown = 0.0, sumUp = 0.0

    init() {
        for case let i as SCNetworkInterface in (SCNetworkInterfaceCopyAll() as? [Any] ?? []) {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                kinds[bsd] = n
            }
        }
    }

    private func counters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, 17 /* PF_ROUTE */, 0, 0, 6 /* NET_RT_IFLIST2 */, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msgLen = Int(h.ifm_msglen)
                if msgLen <= 0 { break }
                if h.ifm_type == 0x12 /* RTM_IFINFO2 */, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        let up = (Int32(m.ifm_flags) & IFF_UP) != 0 && (Int32(m.ifm_flags) & IFF_LOOPBACK) == 0
                        if name.hasPrefix("en"), up { out[name] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes) }
                    }
                }
                off += msgLen
            }
        }
        return out
    }

    func sample() -> NetInfo {
        var n = NetInfo()
        let now = ProcessInfo.processInfo.systemUptime
        let c = counters()
        var busiest: (name: String, bytes: Double)?
        var rx = 0.0, tx = 0.0
        if now > lastAt, lastAt > 0 {
            let dt = now - lastAt
            for (name, v) in c {
                guard let p = last[name] else { continue }
                // A counter that went backwards (interface reset) counts as nothing, never as a huge number.
                let dRx = v.rx >= p.rx ? v.rx - p.rx : 0, dTx = v.tx >= p.tx ? v.tx - p.tx : 0
                let dr = Double(dRx) / dt, dt2 = Double(dTx) / dt
                rx += dr; tx += dt2
                sumDown += Double(dRx); sumUp += Double(dTx)
                if busiest == nil || dr + dt2 > busiest!.bytes { busiest = (name, dr + dt2) }
            }
        }
        last = c; lastAt = now
        n.downBps = rx; n.upBps = tx
        n.downTotal = sumDown; n.upTotal = sumUp
        let ip = localAddress(preferring: busiest?.name)
        n.address = ip.address
        n.interface = ip.name
        n.kind = kinds[ip.name] ?? (ip.name.isEmpty ? "" : "Network")
        n.online = !ip.address.isEmpty
        return n
    }

    private func localAddress(preferring: String?) -> (name: String, address: String) {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return ("", "") }
        defer { freeifaddrs(ifa) }
        var found: [String: String] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("en"), let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found[name] = String(cString: host)
                }
            }
            p = cur.pointee.ifa_next
        }
        if let pf = preferring, let a = found[pf] { return (pf, a) }
        if let k = found.keys.sorted().first, let a = found[k] { return (k, a) }
        return ("", "")
    }
}
