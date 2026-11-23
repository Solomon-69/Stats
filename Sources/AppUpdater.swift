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
    typealias Failure = UpdateFailure

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
        // 0 to 90 is the real download, by bytes. The rest are the steps after it, so 100 only shows when it is really finished.
        let file = work.appendingPathComponent(cfg.zipName)
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let agent = "\(cfg.appName)/\(v) (Mac)"
        do {
            try await FileDownload.get(zip, to: file, userAgent: agent) { got, total in if total > 0 { progress(Double(got) / Double(total) * 90) } }
        } catch {
            progress(0)   // one quiet retry: a dropped connection should not end the update
            try await FileDownload.get(zip, to: file, userAgent: agent) { got, total in if total > 0 { progress(Double(got) / Double(total) * 90) } }
        }
        progress(92)
        guard try FileDownload.sha256(of: file) == want else { throw UpdateFailure(why: "checksum mismatch") }
        progress(96)
        let unzipped = work.appendingPathComponent("x", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, unzipped.path])
        let newApp = unzipped.appendingPathComponent(cfg.bundleName)
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS").path) else { throw Failure(why: "not a \(cfg.appName) app") }
        progress(98)
        return newApp
    }

    /// False when this copy can't be replaced: opened from a disk image, or from Downloads before macOS has moved it.
    static func replaceable(_ bundle: URL) -> Bool {
        let p = bundle.path
        return !p.contains("/AppTranslocation/") && !p.hasPrefix("/Volumes/") && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Swap the running app's bundle for the new one (after the same bundle id is confirmed).
    static func swap(cfg: UpdateConfig, newApp: URL, bundle: URL) throws {
        guard let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle(url: bundle)?.bundleIdentifier else { throw Failure(why: "not a \(cfg.appName) app") }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: newApp)
        IconRefresh.now(bundle)
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

/// Downloads to a file with real byte counts. A connection that stops sending fails within 20 s instead of sitting still.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var done: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.dest = dest; self.progress = progress }

    static func get(_ url: URL, to dest: URL, userAgent: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 900
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        let job = FileDownload(dest: dest, progress: progress)
        let s = URLSession(configuration: c, delegate: job, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            job.done = k
            s.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten got: Int64, totalBytesExpectedToWrite total: Int64) {
        progress(got, total)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { failure = UpdateFailure(why: "download failed"); return }
        do { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: tmp, to: dest) } catch { failure = error }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? failure { done?.resume(throwing: e) } else { done?.resume() }
        done = nil
    }
    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
struct UpdateFailure: Error { let why: String }

/// What went wrong, in words a person can act on.
func updateProblem(_ e: Error, app: String) -> String {
    let why = (e as? UpdateFailure)?.why ?? ""
    if why == "checksum mismatch" { return "The download was damaged, so it was thrown away. Try again." }
    if why == "not writable" { return "\(app) can't replace itself where it is. Move it to the Applications folder, then try again." }
    if e is URLError || why == "download failed" || why == "no checksum" { return "The download stopped. Check your internet and try again." }
    if let c = (e as NSError?), c.domain == NSCocoaErrorDomain { return "\(app) can't replace itself where it is. Move it to the Applications folder, then try again." }
    return "The update did not install, your current version is untouched."
}

@MainActor final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, notPublished, available(String), downloading(Double), installing, failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
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
    #if UPDATER_TEST
    func forceState(_ s: State) { state = s }
    #endif

    func check() async {
        guard state != .checking, state != .installing else { return }
        if case .downloading = state { return }
        state = .checking
        let started = Date()
        let result = await lookUp()
        // Keep the spinner up for a moment so a fast answer still reads as "checked".
        let spent = Date().timeIntervalSince(started)
        if spent < 0.6 { try? await Task.sleep(nanoseconds: UInt64((0.6 - spent) * 1_000_000_000)) }
        if case .upToDate = result { lastChecked = Date() }
        state = result
    }

    /// GitHub's API first; if it refuses (rate limit, outage) the public releases page is asked instead.
    private func lookUp() async -> State {
        var apiProblem = false
        do {
            var req = URLRequest(url: testAPI ?? apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await UpdateFiles.session(cfg.appName).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .notPublished }
            if code == 200, let rel = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = rel["tag_name"] as? String {
                guard UpdateFiles.isNewer(tag, than: currentVersion) else { return .upToDate }
                let assets = rel["assets"] as? [[String: Any]] ?? []
                func url(_ n: String) -> URL? { (assets.first { $0["name"] as? String == n }?["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                guard let z = url(cfg.zipName), let s = url("SHA256SUMS.txt") else { return .failed("The new version has no download yet. Try again later.") }
                found = (z, s)
                return .available(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
            }
            apiProblem = true
        } catch {
            apiProblem = true
        }
        if apiProblem, testAPI == nil, let tag = await latestTagFromPage() {
            guard UpdateFiles.isNewer(tag, than: currentVersion) else { return .upToDate }
            let base = "https://github.com/\(cfg.repo)/releases/download/\(tag)/"
            if let z = URL(string: base + cfg.zipName), let s = URL(string: base + "SHA256SUMS.txt") {
                found = (z, s)
                return .available(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
            }
        }
        return .failed("Could not reach GitHub. Check your internet and try again.")
    }

    /// Backup route: github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>.
    private func latestTagFromPage() async -> String? {
        guard let page = URL(string: "https://github.com/\(cfg.repo)/releases/latest") else { return nil }
        var req = URLRequest(url: page); req.httpMethod = "HEAD"
        guard let (_, resp) = try? await UpdateFiles.session(cfg.appName).data(for: req),
              let final = (resp as? HTTPURLResponse)?.url, final.pathComponents.contains("tag") else { return nil }
        let tag = final.lastPathComponent
        return tag.isEmpty || tag == "latest" ? nil : tag
    }

    func install() async {
        guard case .available = state, let f = found else { return }
        state = .downloading(0)
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(cfg.appName.lowercased())-update-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: work) }
        do {
            guard UpdateFiles.replaceable(Bundle.main.bundleURL) else { throw UpdateFailure(why: "not writable") }
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
            NSLog("%@ update failed: %@", cfg.appName, "\(error)")
            state = .failed(updateProblem(error, app: cfg.appName))
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
    var onTint: Color = Color.black.opacity(0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(mute).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // the text wraps to the width left over, never "…"
                button.fixedSize()
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: updater.state)
            }
            if case .downloading(let p) = updater.state {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(tint).frame(width: max(6, g.size.width * CGFloat(min(p, 100) / 100)))
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
        case .downloading(let p): return p <= 90 ? "Downloading the update" : "Almost done"
        case .installing: return "Installing"
        default: return "Updates"
        }
    }
    private var subtitle: String {
        switch updater.state {
        case .idle: return "You have version \(updater.currentVersion)."
        case .checking: return "Looking for a newer version…"
        case .upToDate: return "Checked just now. You have the newest version (\(updater.currentVersion))."
        case .notPublished: return "No public release yet, so there is nothing newer to get."
        case .available: return "You have \(updater.currentVersion). The update is checked before it is installed."
        case .downloading(let p): return p <= 90 ? "\(Int(p / 90 * 100))% downloaded. \(updater.cfg.appName) restarts by itself when it is done." : "Checking the download…"
        case .installing: return "Swapping in the new version…"
        case .failed(let m): return m
        }
    }
    @ViewBuilder private var button: some View {
        switch updater.state {
        case .available:
            pill("Update now") { Task { await updater.install() } }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small).frame(height: 28)
        case .upToDate:
            UpToDateBadge { Task { await updater.check() } }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .failed:
            pill("Try again") { Task { await updater.check() } }
        default:
            pill("Check for updates") { Task { await updater.check() } }
        }
    }
    private func pill(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(onTint)
                .lineLimit(1).fixedSize().padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint))
        }
        .buttonStyle(.plain)
    }
}

/// Green tick shown after a check finds nothing newer. Tap it to check again.
struct UpToDateBadge: View {
    var recheck: () -> Void
    @State private var pop = false
    static let green = Color(red: 0.20, green: 0.78, blue: 0.42)

    var body: some View {
        Button(action: recheck) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .scaleEffect(pop ? 1 : 0.3)
                    .rotationEffect(.degrees(pop ? 0 : -25))
                Text("Up to date").font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule(style: .continuous).fill(Self.green))
        }
        .buttonStyle(.plain)
        .help("Checked just now. Click to check again.")
        .accessibilityLabel("Up to date. Click to check again.")
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.05)) { pop = true } }
    }
}

/// New icon after an update. macOS caches an app's icon by its path and date. An update unzips the new app with the
/// zip's old dates, so Finder, the Dock and Launchpad can keep showing the old icon. Stamping the bundle with today's
/// date and re-registering it with LaunchServices makes macOS read the new icon.
enum IconRefresh {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func now(_ app: URL) {
        let p = app.path
        guard app.pathExtension == "app", !p.contains("/AppTranslocation/"), !p.hasPrefix("/Volumes/") else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p)
        let r = Process(); r.executableURL = URL(fileURLWithPath: lsregister); r.arguments = ["-f", p]
        r.standardOutput = FileHandle.nullDevice; r.standardError = FileHandle.nullDevice
        if (try? r.run()) != nil { r.waitUntilExit() }
        NSWorkspace.shared.noteFileSystemChanged(p)
    }

    /// Once per version, at launch: also fixes copies an older updater already swapped in.
    static func onceForThisVersion() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let key = "iconRefreshedForVersion"
        guard UserDefaults.standard.string(forKey: key) != v else { return }
        UserDefaults.standard.set(v, forKey: key)
        let app = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async { now(app) }
    }
}
