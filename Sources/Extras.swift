// Extras.swift. Opt-in internet look-ups (public address, delay) and plain-words alerts.
import Foundation
import Network
import UserNotifications

/// Asks the internet two small questions, only when the user switched it on and the Internet tile is open.
final class NetExtras {
    private(set) var publicAddress: String?
    private(set) var delayMs: Double?
    private var busy = false

    private let queue = DispatchQueue(label: "stats.netextras")
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    func refresh(done: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        let group = DispatchGroup()
        var address: String?
        var delay: Double?
        group.enter()
        session.dataTask(with: URL(string: "https://api.ipify.org")!) { [queue] data, _, _ in
            queue.async {
                if let d = data, let s = String(data: d, encoding: .utf8), s.count < 46, !s.contains("<") { address = s }
                group.leave()
            }
        }.resume()
        group.enter()
        let start = DispatchTime.now()
        let c = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        var finished = false
        let queue = self.queue
        let finish: (Double?) -> Void = { ms in
            queue.async {
                guard !finished else { return }
                finished = true
                delay = ms
                c.cancel(); group.leave()
            }
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
        group.notify(queue: .main) { [weak self] in
            if let a = address { self?.publicAddress = a }
            self?.delayMs = delay
            self?.busy = false
            done()
        }
    }
}

/// Three plain alerts. Each fires once, then waits until things are fine again.
final class Alerts {
    private var low = false, full = false, squeezed = false

    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(battery: BatteryInfo?, disk: DiskInfo, mem: MemInfo) {
        if let b = battery {
            if !b.charging && !b.pluggedIn && b.percent <= 20 { if !low { low = true; send("Battery is low", "\(Int(b.percent))% left. Plug in soon.") } }
            else if b.percent > 25 || b.pluggedIn { low = false }
        }
        if disk.usedFraction >= 0.95 { if !full { full = true; send("Storage is nearly full", "Less than 5% of your disk is free.") } }
        else if disk.usedFraction < 0.92 { full = false }
        if mem.pressure >= 4 { if !squeezed { squeezed = true; send("Memory is squeezed", "Close an app or two to speed things up.") } }
        else if mem.pressure <= 1 { squeezed = false }
    }

    private func send(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
