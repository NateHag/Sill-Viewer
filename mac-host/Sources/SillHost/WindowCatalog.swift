import Foundation
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import StreamProtocol

/// Knows what is on the Mac: the on-screen windows, a small JPEG thumbnail of each, app icons,
/// and the installed apps for the drawer. Everything here runs on the main actor; callbacks fire
/// there too and the coordinator forwards to the network.
///
/// Idle means idle: with no client connected nothing here runs on a timer. The window list is
/// read once at startup (the coordinator's `refreshWindows()`, so the CLI can print a count) and
/// then only while at least one client is connected, every `pollInterval`, together with the
/// thumbnails. The installed-app scan runs once at startup, off the main thread.
@MainActor
final class WindowCatalog {
    private(set) var windows: [SCWindow] = []
    private(set) var infos: [WindowInfo] = []
    private(set) var display: SCDisplay?
    private(set) var installedApps: [AppInfo] = []
    /// This process as ScreenCaptureKit lists it, from the last look: the Desktop stream leaves it
    /// out, so Sill's own windows (the pairing code above all) never reach a device. Nil when it
    /// is not listed (the CLI has no windows; see `resolveOwnApplication`).
    private(set) var ownApplication: SCRunningApplication?

    /// Fires when the window list changes (new, closed, retitled, resized, reordered).
    var onWindowsChanged: (([WindowInfo]) -> Void)?
    /// Fires after every poll's window-list read (each `pollInterval` while a client is connected),
    /// changed or not: the Desktop's menus follow the frontmost app, and an app's menus that did
    /// not answer are read again (StreamCoordinator's `menusPolled`).
    var onPolled: (@MainActor () -> Void)?
    /// A fresh thumbnail for one window.
    var onThumbnail: ((UInt32, Data) -> Void)?
    /// An icon we have not announced yet (running or installed app). Only fires while a client is
    /// connected; with none it is just stored, and `allIcons` hands it to the next client.
    var onNewIcon: ((String, Data) -> Void)?
    /// The installed-app scan finished (it runs in the background after launch). A client that
    /// connected before this saw an empty "All apps" list; the coordinator re-sends it.
    var onInstalledAppsReady: (([AppInfo]) -> Void)?

    /// Thumbnails cost a screenshot per window; only take them while someone is looking. They are
    /// taken inside the client-driven poll, so with `clientCount == 0` none are taken regardless.
    /// Setting this to true (even when already true) means "someone new is looking": the next
    /// pass re-sends every thumbnail, and it runs right away. The coordinator sets it in its
    /// client-connected callback, i.e. once the connection is ready and just before it sends the
    /// catalog, so the new client gets the list and icons first and then every thumbnail.
    var thumbnailsWanted = false {
        didSet { if thumbnailsWanted && clientCount > 0 { resendAllThumbnails() } }
    }

    /// Connected clients, from the server. 0→N starts polling (with an immediate pass); N→0 stops
    /// it, so an idle host makes no ScreenCaptureKit calls at all.
    ///
    /// Ordering on connect: the server reports the new count when it admits the connection (at
    /// ready, once its origin passed), just before the coordinator's `sendCatalog` runs. The pass
    /// started here awaits `SCShareableContent` (tens of ms), so it usually finishes after
    /// `sendCatalog` has already sent the list as of the last look. That is fine: when the fresh
    /// list differs, `onWindowsChanged` fires and the coordinator broadcasts it, so the client is
    /// at most one round trip stale, never a poll interval. If the refresh lands before ready,
    /// `sendCatalog` simply sends the fresh list. New icons found by that pass are broadcast, and
    /// also stored first, so `allIcons` covers a client that was not ready for the broadcast.
    var clientCount = 0 {
        didSet {
            guard clientCount != oldValue else { return }
            Stats.shared.activeClients = clientCount
            if oldValue == 0 && clientCount > 0 {
                startPolling()
            } else if oldValue > 0 && clientCount == 0 {
                stopPolling()
            } else if clientCount > oldValue {
                resendAllThumbnails()      // another client joined; it has no thumbnails yet
            }
        }
    }

    /// The window being streamed, if the coordinator tells us. Its thumbnail refreshes every pass
    /// because its contents are the ones changing. Nil is fine: it is then treated like any other.
    var activeWindowID: UInt32?

    /// `--virtual-display`: the Desktop source must capture the Mac's real main display, never the
    /// virtual one. `SCShareableContent.displays` order is not guaranteed once a second display
    /// exists, so pick by ID. Off by default: the default path keeps `displays.first`.
    var preferMainDisplay = false

    /// `--virtual-display`: the window the coordinator has moved onto the virtual display. Set right
    /// after a successful placement, cleared on release. If ScreenCaptureKit stops treating it as
    /// on-screen there (unverified), it is fetched from the full window list so its tile stays in
    /// the client's bar and the coordinator can still find it.
    var stagedWindowID: CGWindowID?

    /// Windows AppKit and SwiftUI make for themselves when a display appears ("LayerProbeParent":
    /// an off-screen window that probes layer backing on the new screen). They carry the app's
    /// name and no content, showed up as duplicate tiles with blank thumbnails, and the window
    /// server drops them onto a real display when a virtual display goes away.
    static func isSystemHelperWindow(_ w: SCWindow) -> Bool {
        (w.title ?? "").lowercased().contains("layerprobe")
    }

    /// Window list and thumbnails, while a client is connected.
    static let pollInterval: Duration = .seconds(2)
    /// A window whose `WindowInfo` (title, app, size) has not changed since its last thumbnail,
    /// and which is not the active source, is re-shot only this often. Most windows on a Mac are
    /// static; re-screenshotting them every pass is the bulk of the catalog's cost in use.
    static let staticThumbnailInterval: Duration = .seconds(6)

    private var seenOrder: [UInt32] = []
    private var icons: [String: Data] = [:]
    private var announcedIcons: Set<String> = []
    private var started = false

    private var pollTask: Task<Void, Never>?
    /// The poll loop's current sleep, separate so a kick can end it early without cancelling the loop.
    private var sleeper: Task<Void, Never>?
    /// Set by a kick that arrives mid-pass: run another pass instead of sleeping.
    private var passOwed = false
    /// What each window looked like when its thumbnail was last taken, and when.
    private var thumbStamps: [UInt32: (info: WindowInfo, at: ContinuousClock.Instant)] = [:]
    /// Refreshes can overlap (startup call plus the first poll); only the newest result applies.
    private var refreshSeq = 0
    private var appliedSeq = 0

    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Starts the one-time installed-app scan, and polling if a client is already connected.
    /// Does not read the window list itself: the coordinator awaits `refreshWindows()` right after.
    func start() {
        guard !started else { return }
        started = true
        scanInstalledApps()
        if clientCount > 0 { startPolling() }
    }

    func window(id: UInt32) -> SCWindow? { windows.first { $0.windowID == id } }

    /// `window(id:)`, else one look at every window the system knows (on-screen or not). The
    /// coordinator uses it for the staged window, whose SCWindow must be fresh after the move: the
    /// probe refetched too before capturing on the virtual display. Never one of Sill's own
    /// windows, as in the catalog: a device may name any window ID in a pick, and one just above
    /// the newest it knows could be the pairing window with its code.
    func resolveWindow(id: UInt32) async -> SCWindow? {
        if let w = window(id: id) { return w }
        guard let all = await Self.shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: false, timeout: 3) else { return nil }
        return all.windows.first { $0.windowID == id && !Self.isOwn($0) }
    }

    /// `ownApplication`, else one look at every window (on screen or not) for this process. The
    /// on-screen look can miss Sill while it shows nothing on screen: its status item's window
    /// leaves the list while a full-screen app hides the menu bar, and a Desktop stream started
    /// then would leave nothing out, so a pairing window opened later would reach the devices. Nil
    /// when this process has no window at all (the CLI).
    func resolveOwnApplication() async -> SCRunningApplication? {
        if let own = ownApplication { return own }
        guard let all = await Self.shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: false, timeout: 3) else { return nil }
        return all.applications.first { $0.processID == Self.ownPID }
            ?? all.windows.first { Self.isOwn($0) }?.owningApplication
    }

    /// One of this process's own windows (Settings, the log, the pairing window with its code).
    static func isOwn(_ w: SCWindow) -> Bool { w.owningApplication?.processID == ownPID }

    /// `SCShareableContent`, but never for longer than `timeout`. Measured 2026-09-22: in a process
    /// without Screen Recording the call never returned once a virtual display existed (it returns
    /// promptly, with no windows, without one). The virtual-display paths use this so a hang there
    /// costs seconds and a fallback, not the coordinator's `switching` flag for good. The default
    /// path's `refreshWindows` keeps the plain call it always had.
    nonisolated static func shareableContent(excludingDesktopWindows: Bool, onScreenWindowsOnly: Bool, timeout: TimeInterval) async -> SCShareableContent? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var done = false
            func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<SCShareableContent?, Never>) in
            SCShareableContent.getExcludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly) { content, _ in
                if once.first() { c.resume(returning: content) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.first() { c.resume(returning: nil) }   // the late answer, if any, is dropped
            }
        }
    }

    /// Every icon we know, for a client that just connected.
    var allIcons: [(bundleID: String, png: Data)] { icons.map { ($0.key, $0.value) } }

    // MARK: Polling (only while a client is connected)

    private func startPolling() {
        guard started, pollTask == nil else { return }
        thumbStamps = [:]
        pollTask = Task { @MainActor [weak self] in await self?.pollLoop() }
    }

    private func stopPolling() {
        pollTask?.cancel()
        sleeper?.cancel()
        pollTask = nil
        thumbStamps = [:]
    }

    /// One pass right away, then one every `pollInterval`, until cancelled. A pass is a window
    /// list refresh followed by whichever thumbnails are due.
    private func pollLoop() async {
        while !Task.isCancelled {
            passOwed = false
            await refreshWindows()
            if Task.isCancelled { break }
            onPolled?()
            if thumbnailsWanted { await refreshThumbnails() }
            if Task.isCancelled { break }
            if passOwed { continue }
            let nap = Task { _ = try? await Task.sleep(for: Self.pollInterval) }
            sleeper = nap
            await nap.value
            if sleeper == nap { sleeper = nil }
        }
    }

    /// Forget which thumbnails were sent and run a pass now (or right after the current one).
    private func resendAllThumbnails() {
        guard pollTask != nil else { return }
        thumbStamps = [:]
        passOwed = true
        sleeper?.cancel()
    }

    // MARK: Windows

    func refreshWindows() async {
        refreshSeq += 1
        let seq = refreshSeq
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        // The staged window, if the on-screen list dropped it: one extra SCShareableContent call per
        // poll, and only then. Fetched before the sequence check so its await cannot let an older
        // refresh overwrite a newer one.
        var pinned: SCWindow? = nil
        if let id = stagedWindowID, !content.windows.contains(where: { $0.windowID == id }),
           let all = await Self.shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: false, timeout: 3) {
            pinned = all.windows.first { $0.windowID == id && !Self.isOwn($0) }
            if pinned != nil { print("Catalog: the staged window \(id) is not in the on-screen list; pinned it from the full list.") }
        }
        guard seq > appliedSeq else { return }      // a newer refresh already landed; don't go backwards
        appliedSeq = seq
        ownApplication = content.applications.first { $0.processID == Self.ownPID }
        display = preferMainDisplay
            ? (content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first)
            : content.displays.first
        var visible = content.windows.filter { w in
            guard let app = w.owningApplication, !app.applicationName.isEmpty else { return false }
            return w.windowLayer == 0                                  // drops widgets, wallpaper, backstop
                && w.frame.width > 100 && w.frame.height > 100
                && app.processID != Self.ownPID
                && !Self.isSystemHelperWindow(w)
        }
        if let pinned, !visible.contains(where: { $0.windowID == pinned.windowID }) { visible.append(pinned) }
        // The system's order is not front-to-back and shuffles between polls. The brief wants a
        // fixed order in the bar, so keep first-seen order and append newcomers.
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.windowID, $0) })
        seenOrder = seenOrder.filter { byID[$0] != nil } + visible.map(\.windowID).filter { !seenOrder.contains($0) }
        let ordered = seenOrder.compactMap { byID[$0] }
        let newInfos = ordered.map { w in
            WindowInfo(id: w.windowID,
                       title: w.title ?? "",
                       appName: w.owningApplication?.applicationName ?? "",
                       bundleID: w.owningApplication?.bundleIdentifier ?? "",
                       width: Int(w.frame.width), height: Int(w.frame.height))
        }
        windows = ordered
        Stats.shared.windowCount = ordered.count
        for w in ordered { announceIconIfNeeded(for: w.owningApplication) }
        if newInfos != infos {
            infos = newInfos
            onWindowsChanged?(newInfos)
        }
    }

    /// Thumbnail cadence, per window: every pass (2 s) if its `WindowInfo` changed since its last
    /// thumbnail or it is the active source; otherwise every `staticThumbnailInterval` (6 s), which
    /// still catches content changing inside a window of fixed size and title. A window is
    /// stamped before the capture, so one that fails to capture also backs off to 6 s.
    private func refreshThumbnails() async {
        // 2× the 104×66 pt tile in the client's bar. Fit each window's aspect inside that box.
        let box = CGSize(width: 208, height: 132)
        let now = ContinuousClock.now
        let infoByID = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
        thumbStamps = thumbStamps.filter { infoByID[$0.key] != nil }      // forget closed windows
        for w in windows {
            if Task.isCancelled { return }
            guard let info = infoByID[w.windowID] else { continue }
            if let stamp = thumbStamps[w.windowID], stamp.info == info, w.windowID != activeWindowID,
               now - stamp.at < Self.staticThumbnailInterval { continue }
            thumbStamps[w.windowID] = (info, now)
            let sf = min(box.width / w.frame.width, box.height / w.frame.height)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(w.frame.width * sf))
            config.height = max(2, Int(w.frame.height * sf))
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: w)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                  let jpeg = Self.jpeg(image, quality: 0.6) else { continue }
            onThumbnail?(w.windowID, jpeg)
        }
    }

    // MARK: Icons

    private func announceIconIfNeeded(for app: SCRunningApplication?) {
        guard let app else { return }
        let id = app.bundleIdentifier
        guard !id.isEmpty, !announcedIcons.contains(id) else { return }
        let image = NSRunningApplication(processIdentifier: app.processID)?.icon
            ?? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path ?? "")
        guard let png = Self.png(image, size: 64) else { return }
        announce(bundleID: id, png: png)
    }

    private func announce(bundleID: String, png: Data) {
        icons[bundleID] = png
        announcedIcons.insert(bundleID)
        // With nobody connected a broadcast reaches no one; `allIcons` carries it to the next client.
        if clientCount > 0 { onNewIcon?(bundleID, png) }
    }

    // MARK: Installed apps

    /// Once at startup. Listing ~100 bundles and rendering their icons takes 150–300 ms, which on
    /// the main actor would hold up startup and the first window refresh, so all of it runs on a
    /// utility-priority thread and only the results hop back.
    private func scanInstalledApps() {
        Task.detached(priority: .utility) { [weak self] in
            let t0 = Date()
            let found = WindowCatalog.findInstalledApps()
            let t1 = Date()
            let rendered: [(bundleID: String, png: Data)] = found.compactMap { app in
                WindowCatalog.png(NSWorkspace.shared.icon(forFile: app.path), size: 64).map { (app.bundleID, $0) }
            }
            let t2 = Date()
            print("installed apps: \(found.count) in \(Int(t1.timeIntervalSince(t0) * 1000)) ms"
                  + " (+ icons \(Int(t2.timeIntervalSince(t1) * 1000)) ms, off the main thread)")
            await self?.installedAppsFound(found.map { AppInfo(name: $0.name, bundleID: $0.bundleID) }, icons: rendered)
        }
    }

    private func installedAppsFound(_ apps: [AppInfo], icons rendered: [(bundleID: String, png: Data)]) {
        installedApps = apps
        // A running app's icon, announced by a window refresh meanwhile, wins over the file icon.
        for (id, png) in rendered where !announcedIcons.contains(id) { announce(bundleID: id, png: png) }
        if clientCount > 0 { onInstalledAppsReady?(apps) }
    }

    /// Sorted by display name, first bundle ID wins. Thread-safe (FileManager + Bundle only).
    nonisolated private static func findInstalledApps() -> [(name: String, bundleID: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    home.appendingPathComponent("Applications").path]
        var seen: Set<String> = []
        var apps: [(name: String, bundleID: String, path: String)] = []
        for dir in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                var display = FileManager.default.displayName(atPath: url.path)
                if display.hasSuffix(".app") { display.removeLast(4) }
                apps.append((display, id, url.path))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Image encoding (thread-safe)

    nonisolated private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Draws into its own bitmap context, so it is safe off the main thread.
    nonisolated private static func png(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
