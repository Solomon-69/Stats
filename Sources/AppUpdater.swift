// AppUpdater.swift. Shared in-app "Check for updates" for Solomon's Mac apps (same steps as Ludus's updater):
// ask GitHub for the latest release, compare versions, download the release zip, check its SHA-256 against
// SHA256SUMS.txt, unzip to a temp folder, clear quarantine, swap the app bundle, relaunch. Nothing happens silently:
// the person taps Check, then Update. The old app is untouched if anything fails.
// Release convention: GitHub release tagged vX.Y.Z with "<App>-mac.zip" (the .app at the top) and "SHA256SUMS.txt".
import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct UpdateConfig {
    let repo: String        // "Solomon-69/Stats"
    let appName: String     // "Stats"
    let bundleName: String  // "Stats.app"
    let zipName: String     // "Stats-mac.zip"
}

enum UpdateFiles {
    struct Failure: Error { let why: String }

    /// Hosts a release download may come from. Tests add 127.0.0.1.
    static let hosts: Set<String> = ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
    nonisolated(unsafe) static var testHosts: Set<String> = []

    static func allowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https" { return hosts.contains(host) || host.hasSuffix(".githubusercontent.com") }
        return url.scheme == "http" && testHosts.contains(host)
    }

    /// "<hash>  <name>" lines (sha256sum style). Returns the lowercase hash for `name`.
    static func expectedHash(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let file = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *\t"))
            let hash = parts[0].lowercased()
            if file == name, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) { return hash }
        }
        return nil
    }

    /// True when `latest` (e.g. "v1.2.0") is a higher version than `current` ("1.1.9"). Numbers only, missing parts count as 0.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func session(_ appName: String) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 600
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        c.httpAdditionalHeaders = ["User-Agent": "\(appName)/\(v) (Mac)"]
        return URLSession(configuration: c)
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(why: "\(path) \(p.terminationStatus)") }
    }

    /// Download, verify, unzip. Returns the unzipped .app inside `work`.
    static func stage(cfg: UpdateConfig, zip: URL, sums: URL, work: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        guard allowed(zip), allowed(sums) else { throw Failure(why: "source not allowed") }
        let s = session(cfg.appName)
        let (sumData, sumResp) = try await s.data(from: sums)
        guard (sumResp as? HTTPURLResponse)?.statusCode == 200, let text = String(data: sumData, encoding: .utf8),
              let want = expectedHash(in: text, for: cfg.zipName) else { throw Failure(why: "no checksum") }
        let file = work.appendingPathComponent(cfg.zipName)
        fm.createFile(atPath: file.path, contents: nil)
        let out = try FileHandle(forWritingTo: file)
        var hasher = SHA256()
        progress(1)
        let (bytes, resp) = try await s.bytes(from: zip)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(why: "download failed") }
        let total = Double(resp.expectedContentLength)
        var buf = Data(); var got = 0.0; var last = -1.0
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 65536 {
                hasher.update(data: buf); try out.write(contentsOf: buf); got += Double(buf.count); buf.removeAll(keepingCapacity: true)
                let p = total > 0 ? min(99, max(1, (got / total * 100).rounded())) : min(95, 1 + (got / 1_000_000).rounded())
                if p != last { last = p; progress(p) }
            }
        }
        if !buf.isEmpty { hasher.update(data: buf); try out.write(contentsOf: buf) }
        try out.close()
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == want else { throw Failure(why: "checksum mismatch") }
        progress(100)
        let unzipped = work.appendingPathComponent("x", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, unzipped.path])
        let newApp = unzipped.appendingPathComponent(cfg.bundleName)
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS").path) else { throw Failure(why: "not a \(cfg.appName) app") }
        return newApp
    }

    /// Swap the running app's bundle for the new one (after the same bundle id is confirmed).
    static func swap(cfg: UpdateConfig, newApp: URL, bundle: URL) throws {
        guard let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle(url: bundle)?.bundleIdentifier else { throw Failure(why: "not a \(cfg.appName) app") }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: newApp)
    }

    /// Waits for this process to exit, then opens the (new) app again.
    static func relaunchAfterExit(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        p.standardOutput = nil; p.standardError = nil
        try? p.run()
    }
}

@MainActor final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, notPublished, available(String), downloading(Double), installing, failed(String)
    }
    @Published private(set) var state: State = .idle
    let cfg: UpdateConfig
    private var found: (zip: URL, sums: URL)?
    private var apiURL: URL { URL(string: "https://api.github.com/repos/\(cfg.repo)/releases/latest")! }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    init(_ cfg: UpdateConfig) {
        self.cfg = cfg
        #if UPDATER_TEST
        if let api = ProcessInfo.processInfo.environment["APP_UPDATE_API"], let host = URL(string: api)?.host {
            UpdateFiles.testHosts = [host]; testAPI = URL(string: api)
        }
        #endif
    }
    private var testAPI: URL?

    func check() async {
        guard state != .checking, state != .installing else { return }
        if case .downloading = state { return }
        state = .checking
        do {
            var req = URLRequest(url: testAPI ?? apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await UpdateFiles.session(cfg.appName).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { state = .notPublished; return }
            guard code == 200, let rel = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = rel["tag_name"] as? String else {
                state = .failed("GitHub did not answer. Try again in a minute."); return
            }
            guard UpdateFiles.isNewer(tag, than: currentVersion) else { state = .upToDate; return }
            let assets = rel["assets"] as? [[String: Any]] ?? []
            func url(_ n: String) -> URL? { (assets.first { $0["name"] as? String == n }?["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            guard let z = url(cfg.zipName), let s = url("SHA256SUMS.txt") else { state = .failed("The new version has no download yet."); return }
            found = (z, s)
            state = .available(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
        } catch {
            state = .failed("Could not reach GitHub. Check your internet and try again.")
        }
    }

    func install() async {
        guard case .available = state, let f = found else { return }
        state = .downloading(1)
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(cfg.appName.lowercased())-update-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let cfg = self.cfg
            let newApp = try await UpdateFiles.stage(cfg: cfg, zip: f.zip, sums: f.sums, work: work) { [weak self] p in
                Task { @MainActor in self?.state = .downloading(p) }
            }
            state = .installing
            let bundle = Bundle.main.bundleURL
            try UpdateFiles.swap(cfg: cfg, newApp: newApp, bundle: bundle)
            #if UPDATER_TEST
            if ProcessInfo.processInfo.environment["APP_UPDATE_NO_RELAUNCH"] != nil { state = .upToDate; return }
            #endif
            UpdateFiles.relaunchAfterExit(bundle)
            NSApp.terminate(nil)
        } catch {
            state = .failed("The update did not install, your current version is untouched.")
        }
    }

    #if UPDATER_TEST
    /// Test aid: `<App> --selftest-update=RESULT`. Check, download with progress, verify, unzip; no install. Writes JSON.
    static func selfTest(_ cfg: UpdateConfig, result: String) async -> Bool {
        let u = AppUpdater(cfg)
        let t0 = Date()
        await u.check()
        var info: [String: Any] = ["state": "\(u.state)"]
        var ok = false
        if case .available = u.state, let f = u.found {
            let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            final class Box: @unchecked Sendable { var max = 0.0 }; let box = Box()
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let app = try await UpdateFiles.stage(cfg: cfg, zip: f.zip, sums: f.sums, work: work) { box.max = Swift.max(box.max, $0) }
                ok = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
                info["maxPct"] = box.max
                if ok, ProcessInfo.processInfo.environment["APP_UPDATE_SWAP"] != nil {
                    try UpdateFiles.swap(cfg: cfg, newApp: app, bundle: Bundle.main.bundleURL); info["swapped"] = true
                }
            } catch { info["error"] = "\(error)" }
        } else if case .upToDate = u.state { ok = true } else if case .notPublished = u.state { ok = true }
        info["ok"] = ok; info["seconds"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10
        if let d = try? JSONSerialization.data(withJSONObject: info) { try? d.write(to: URL(fileURLWithPath: result)) }
        return ok
    }
    #endif
}

/// The Settings row: version, a Check button that becomes Update, a progress bar, plain-words result. Matches Stats's look; adapt colours per app.
struct UpdateRow: View {
    @ObservedObject var updater: AppUpdater
    var tint: Color
    var ink: Color
    var mute: Color
    var track: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(mute).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // the text wraps to the width left over, never "…"
                button.fixedSize()
            }
            if case .downloading(let p) = updater.state {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(tint).frame(width: max(6, g.size.width * CGFloat(p / 100)))
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.2), value: p)
            }
        }
    }

    private var title: String {
        switch updater.state {
        case .available(let v): return "Version \(v) is ready"
        case .downloading: return "Downloading the update"
        case .installing: return "Installing"
        default: return "Updates"
        }
    }
    private var subtitle: String {
        switch updater.state {
        case .idle: return "You have version \(updater.currentVersion)."
        case .checking: return "Looking for a newer version…"
        case .upToDate: return "You have the newest version (\(updater.currentVersion))."
        case .notPublished: return "You're on the latest version."
        case .available: return "You have \(updater.currentVersion). The update is checked before it is installed."
        case .downloading(let p): return "\(Int(p))%. \(updater.cfg.appName) restarts by itself when it is done."
        case .installing: return "Swapping in the new version…"
        case .failed(let m): return m
        }
    }
    @ViewBuilder private var button: some View {
        switch updater.state {
        case .available:
            pill("Update now") { Task { await updater.install() } }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            pill("Check for updates") { Task { await updater.check() } }
        }
    }
    private func pill(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint))
        }
        .buttonStyle(.plain)
    }
}
