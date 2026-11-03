// SpeedTest.swift. An on-demand internet speed test, like the speed testers on a phone: it measures how fast the
// connection can go (megabits a second), not what the Mac happens to be using right now. Only runs when asked.
// Uses Cloudflare's free public speed test servers; nothing but test data is sent.
import Foundation
import CoreWLAN

/// Wi-Fi facts that need no location permission.
enum WiFiInfo {
    /// The speed the Wi-Fi link is negotiated at right now, in megabits a second (nil when not on Wi-Fi).
    static var linkMbps: Double? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let r = i.transmitRate()
        return r > 0 ? r : nil
    }
}

final class SpeedTest: NSObject, ObservableObject, URLSessionDataDelegate {
    enum Phase: Equatable { case idle, down, up, done, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var downMbps: Double?
    @Published private(set) var upMbps: Double?
    @Published private(set) var liveMbps = 0.0
    @Published private(set) var pingMs: Double?
    /// 0...1 through the current phase (ping counts as the start of the download phase).
    @Published private(set) var progress = 0.0

    private let lock = NSLock()
    private var bytes = 0                 // bytes moved in the current phase
    private var session: URLSession?
    private var runID = 0
    private static let streams = 4
    private static let seconds = 6.0

    var running: Bool { phase == .down || phase == .up }

    func start() {
        guard !running else { return }
        runID += 1
        let id = runID
        downMbps = nil; upMbps = nil; pingMs = nil; liveMbps = 0; progress = 0
        phase = .down
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        cfg.httpMaximumConnectionsPerHost = Self.streams
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        Task { [weak self] in
            guard let self else { return }
            await self.ping(id)
            let down = await self.measure(id, phase: .down)
            guard id == self.runID else { return }
            await MainActor.run { self.downMbps = down; self.phase = .up; self.liveMbps = 0; self.progress = 0 }
            let up = await self.measure(id, phase: .up)
            guard id == self.runID else { return }
            await MainActor.run {
                self.upMbps = up; self.liveMbps = 0; self.progress = 1
                self.phase = (down == nil && up == nil) ? .failed : .done
            }
            self.session?.invalidateAndCancel(); self.session = nil
        }
    }

    func cancel() {
        runID += 1
        session?.invalidateAndCancel(); session = nil
        phase = .idle; liveMbps = 0; progress = 0
    }

    private func ping(_ id: Int) async {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=0"), let s = session else { return }
        var best: Double?
        for _ in 0..<3 {
            let t0 = Date()
            if (try? await s.data(from: url)) != nil {
                let ms = Date().timeIntervalSince(t0) * 1000
                best = min(best ?? ms, ms)
            }
        }
        guard id == runID else { return }
        await MainActor.run { self.pingMs = best }
    }

    /// Moves data on several connections for a few seconds and returns the speed, ignoring the first second (ramp-up).
    private func measure(_ id: Int, phase p: Phase) async -> Double? {
        guard let s = session else { return nil }
        lock.lock(); bytes = 0; lock.unlock()
        var tasks: [URLSessionTask] = []
        let body = Data(count: 8_000_000)
        for _ in 0..<Self.streams {
            if p == .down {
                tasks.append(s.dataTask(with: URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!))
            } else {
                var r = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
                r.httpMethod = "POST"
                tasks.append(s.uploadTask(with: r, from: body))
            }
        }
        tasks.forEach { $0.resume() }
        let t0 = Date()
        var mark: (t: Date, b: Int)?
        var last: (t: Date, b: Int) = (t0, 0)
        while Date().timeIntervalSince(t0) < Self.seconds, id == runID {
            try? await Task.sleep(nanoseconds: 250_000_000)
            lock.lock(); let b = bytes; lock.unlock()
            let now = Date()
            let dt = now.timeIntervalSince(last.t)
            if dt > 0 { let live = Double(b - last.b) * 8 / dt / 1e6; let pr = min(1, now.timeIntervalSince(t0) / Self.seconds); await MainActor.run { self.liveMbps = live; self.progress = pr } }
            last = (now, b)
            if mark == nil, now.timeIntervalSince(t0) >= 1 { mark = (now, b) }
            // A task that finished is replaced so the line stays full for the whole test.
            for (i, t) in tasks.enumerated() where t.state == .completed {
                let n: URLSessionTask
                if p == .down { n = s.dataTask(with: URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!) }
                else {
                    var r = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
                    r.httpMethod = "POST"
                    n = s.uploadTask(with: r, from: body)
                }
                n.resume(); tasks[i] = n
            }
        }
        tasks.forEach { $0.cancel() }
        guard id == runID, let m = mark else { return nil }
        lock.lock(); let b = bytes; lock.unlock()
        let dt = Date().timeIntervalSince(m.t)
        guard dt > 0.5, b > m.b else { return nil }
        return Double(b - m.b) * 8 / dt / 1e6
    }

    /// Only a real answer counts: a rate-limited or refused reply (429, 403...) must not look like a 0 Mbps result.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse, h.statusCode != 200 { completionHandler(.cancel) } else { completionHandler(.allow) }
    }

    #if STATS_TEST
    /// Test hook: show a made-up state so the card can be drawn in every phase without using the network.
    func testSet(phase: Phase, live: Double, down: Double?, up: Double?, ping: Double?, progress: Double) {
        self.phase = phase; liveMbps = live; downMbps = down; upMbps = up; pingMs = ping; self.progress = progress
    }
    #endif

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); bytes += data.count; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); bytes += Int(bytesSent); lock.unlock()
    }
}
