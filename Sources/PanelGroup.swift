// PanelGroup.swift. One panel at a time across my menu bar apps (same as Memo, Nox, Awayke, Ludus).
import AppKit


/// One panel at a time across Solomon's menu bar apps (Nox, Memo, Awayke, Ludus). An app says
/// "my panel is opening" (com.solomon.menubar.panelWillOpen, userInfo ["sender": bundle id]) and the
/// others close theirs. Any other click outside the panel (desktop, other apps, any menu bar item)
/// closes it too, except a click on Nox's quick dark-mode switch, which never closes a panel.
enum PanelGroup {
    static let willOpen = Notification.Name("com.solomon.menubar.panelWillOpen")
    private static let noxID = "com.solomon.DarkSwitch"
    private static var me: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
    private static var token: NSObjectProtocol?

    /// Call once at launch. `close` closes this app's panel.
    static func listen(close: @escaping () -> Void) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(forName: willOpen, object: nil, queue: .main) { n in
            let sender = (n.userInfo?["sender"] as? String) ?? (n.object as? String) ?? ""
            if sender != me { close() }
        }
    }

    /// Call right before this app shows its panel.
    static func announceOpen() {
        DistributedNotificationCenter.default().postNotificationName(
            willOpen, object: me, userInfo: ["sender": me], deliverImmediately: true)
    }

    /// Where Nox's quick dark-mode switch sits (screen points, bottom-left origin, like NSEvent.mouseLocation).
    /// Nox writes it; every app reads it so a click on that switch never closes an open panel.
    static let noxFrameFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.solomon.menubar/nox-toggle-frame.json")
    static let noxFrameChanged = Notification.Name("com.solomon.nox.toggleFrame")

    /// Nox only: publish the switch's screen rectangle (call at launch and whenever it moves).
    static func publishNoxFrame(_ r: NSRect) {
        let json = "{\"x\":\(r.minX),\"y\":\(r.minY),\"w\":\(r.width),\"h\":\(r.height)}"
        try? FileManager.default.createDirectory(at: noxFrameFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.write(to: noxFrameFile, atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(noxFrameChanged, object: nil,
            userInfo: ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)], deliverImmediately: true)
    }

    /// True when the point is on Nox's quick switch (only while Nox is running).
    static func isOnNoxSwitch(_ p: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: noxID).isEmpty,
              let data = try? Data(contentsOf: noxFrameFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = d["x"], let y = d["y"], let w = d["w"], let h = d["h"] else { return false }
        return NSRect(x: x, y: y, width: w, height: h).insetBy(dx: -1, dy: -1).contains(p)
    }
}
