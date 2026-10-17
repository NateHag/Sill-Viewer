import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Test hooks, read from the launch arguments like the iOS app's -SillLayout harness. Each does
/// nothing unless it is passed, so they stay in release builds, where the tests run.
///
///     --synthetic                              the Desktop is a test pattern and nothing is
///                                              advertised, as with the CLI (test clients connect
///                                              to the port in the "Status: Test Pattern Mode" line)
///     -SillLogFile <path>                      log file instead of ~/Library/Logs/Sill/Sill.log
///     -SillSetAfter '<s> key=value[,key=value][; <s> …]'
///                                              change settings s seconds after launch, exactly as
///                                              a control would (maxFPS, captureScale, bitrate,
///                                              awayBitrate, awayCaptureScale,
///                                              prioritizeSpeed, virtualDisplay, directWireless,
///                                              remoteAccess, remotePort, internetAccess,
///                                              remoteAddressName=host[:port], updateCheck,
///                                              requirePairing=0|1). Saved like any change
///                                              (requirePairing in the identity store: memory, or
///                                              SILL_TEST_REMOTE_DIR)
///     -requirePairing YES|NO                   Require pairing at launch, saved in the identity
///                                              store as the Devices pane saves it
///     -SillPairAfter <s>                       open a pairing window (Pair iPhone or iPad…) s
///                                              seconds after launch. With --synthetic and
///                                              SILL_TEST_REMOTE_DIR the link and the code are
///                                              also left there as pairing.url and pairing.code
///                                              (0600), never printed (the log copies stdout)
///     -SillCancelPairingAfter '<s>[; <s> …]'   close the pairing window as its Cancel does (a
///                                              window a device opened quiets its asker), s
///                                              seconds after launch
///     -SillUnpairAfter <s>                     remove every paired device s seconds after launch
///     -SillCableNoticeAfter <s>                show the notice for a device paired over the USB
///                                              cable (a sample one) s seconds after launch
///     -SillMenuAfter '<s>[; <s> …]'            print the status menu as menu.txt shows it, one
///                                              "SillMenuAfter <s> s: " line per line, s seconds
///                                              after launch (the "‹device› Wants to Pair",
///                                              older-device and "Devices Can’t Connect" items)
///     -SillQuitAfter <s>                       Quit (NSApp.terminate) s seconds after launch
///     -SillUpdateFeed <url>                    the update check asks this feed instead of GitHub:
///                                              a feed on this Mac only (http or https to
///                                              127.0.0.1, ::1 or localhost; anything else is
///                                              ignored with one line). With it any http or https
///                                              release page counts, and test pattern mode checks
///     -SillUpdateNow 1                         one check right after the host starts, as Check Now
///     -SillUpdateVersion <v>                   the version the check compares (the bare binary has
///                                              none, so it never checks without this)
///     -SillUpdateInterval <s>                  the check's 24 hours become s seconds (the hour's
///                                              retry s/24, at least 1 s; the launch delay at most
///                                              s; no jitter)
///     -SillPrintMenuAfter <s>                  print the status menu as it would open (as menu.txt
///                                              draws it, "menu: " before each line) and Settings ›
///                                              General's update line, s seconds after launch
///     -SillSettingsAfter '<s> <tab>[; <s> <tab> …]'
///                                              open Settings on that tab s seconds after launch,
///                                              as the menu does, and 0.6 s later print the window's
///                                              frame, its pane's whole height and how much shows,
///                                              the visible frame it fits and the cap (issue #59).
///                                              A tab by its name or the start of one (remote,
///                                              general, virtual); close closes the window; report
///                                              prints it as it stands; end scrolls the pane to its
///                                              last row; height=<points> sets
///                                              -SillTestScreenHeight (0: the screen's own) and
///                                              posts the screens' change, as the Dock or a
///                                              display would
///     -SillTestScreenHeight <points>           the Settings window fits the top <points> of its
///                                              screen's visible frame, as if the screen were that
///                                              short with the Dock at its bottom
///     -SillSettingsShot <dir>                  each -SillSettingsAfter step also writes the window
///                                              (title bar, toolbar, pane) to <dir>/settings-<s>s-<tab>.png
///     -SillRenderPreviews <dir>                write the Settings panes (the Devices and Remote
///                                              Access panes in each of their states, General's
///                                              update section in each of its), the pairing
///                                              window's states and the cable notice,
///                                              status cards, glyphs and menu.txt to <dir>, then
///                                              exit (no Screen Recording needed: views render
///                                              offscreen; no identity is loaded, no listener)
///
/// These are the bare SillMenuBar binary's (defaults domain "SillMenuBar"; delete it after). Sill.app
/// itself, an app bundle's executable, ignores every `-Sill…After` hook and `-requirePairing`, each
/// with one line (docs/home-pairing-plan.md §6.6): they open, answer or remove pairings, or change
/// what the doors admit, and any process of this user can start Sill.app with arguments, which then
/// runs with Sill's Screen Recording and Accessibility grants. `-SillTestScreenHeight` and
/// `-SillSettingsShot` go with `-SillSettingsAfter` and are ignored the same way: Sill.app has no
/// use for them. `--synthetic`, `-SillLogFile`,
/// `-SillRenderPreviews` and the update check's `-SillUpdateFeed`, `-SillUpdateNow`,
/// `-SillUpdateVersion` and `-SillUpdateInterval` stay: they bear on no door and no pairing (a feed
/// on this Mac only).
///
/// The bare binary (and any --synthetic run) never touches the login keychain: its identity lives
/// in SILL_TEST_REMOTE_DIR or in memory (AppModel.makeRemoteAccess).
///
/// The timers are run-loop Timers, never Tasks: NSApp.terminate may run a modal loop, which from
/// a Task would stall the main queue (see AppDelegate).
@MainActor
enum DebugHooks {
    /// Where the log file goes. Read before the app starts (main.swift).
    nonisolated static var logFileURL: URL {
        if let path = UserDefaults.standard.string(forKey: "SillLogFile"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Sill/Sill.log")
    }

    /// The timed hooks, which Sill.app itself ignores.
    static let timedHooks = ["SillSetAfter", "SillPairAfter", "SillCancelPairingAfter", "SillUnpairAfter",
                             "SillCableNoticeAfter", "SillMenuAfter", "SillPrintMenuAfter", "SillSettingsAfter", "SillQuitAfter"]
    /// The Settings window's test arguments (issue #59), which Sill.app itself ignores too.
    static let windowHooks = ["SillTestScreenHeight", "SillSettingsShot"]

    /// TEST ONLY (-SillTestScreenHeight <points>, and -SillSettingsAfter's height=): the Settings
    /// window fits the top <points> of its screen's visible frame (SettingsWindowFit.visible). Nil in
    /// Sill.app itself, and without it.
    static var testScreenHeight: CGFloat? = {
        guard !AppModel.bundled else { return nil }
        let h = UserDefaults.standard.double(forKey: "SillTestScreenHeight")
        return h > 0 ? CGFloat(h) : nil
    }()

    /// The update check's configuration: GitHub and the plan's schedule, with the running version
    /// from the bundle, unless the test arguments above say otherwise. Read once, when the model is
    /// made; nothing here makes a request.
    static func updateConfiguration(testPattern: Bool) -> UpdateChecker.Configuration {
        let defaults = UserDefaults.standard
        var c = UpdateChecker.Configuration()
        c.testPattern = testPattern
        c.running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let v = defaults.string(forKey: "SillUpdateVersion"), !v.isEmpty { c.running = v }
        if let raw = defaults.string(forKey: "SillUpdateFeed"), !raw.isEmpty {
            if let url = URL(string: raw), UpdatePolicy.isLocalFeed(url) {
                c.feed = url
                c.testFeed = true
            } else {
                print("SillUpdateFeed ignored: only a feed on this Mac (127.0.0.1, ::1 or localhost) is allowed.")
            }
        }
        c.checkAtStart = defaults.bool(forKey: "SillUpdateNow")
        let interval = defaults.double(forKey: "SillUpdateInterval")
        if interval > 0 {
            c.period = interval
            c.retry = max(1, interval / 24)
            c.launchDelay = min(UpdatePolicy.launchDelay, interval)
            c.jitter = 0
        }
        return c
    }

    /// The timed hooks, counted from now (launch). In Sill.app, one line for each that was given.
    static func schedule(model: AppModel) {
        let defaults = UserDefaults.standard
        if AppModel.bundled {
            for name in timedHooks + windowHooks where defaults.object(forKey: name) != nil {
                print("-\(name) ignored: Sill.app itself takes no test hook (use the bare SillMenuBar binary).")
            }
            return
        }
        if let spec = defaults.string(forKey: "SillSetAfter") {
            for step in spec.split(separator: ";") {
                let parts = step.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let delay = Double(parts[0]) else {
                    print("SillSetAfter: can’t read “\(step)”; expected '<seconds> key=value[,key=value]'")
                    continue
                }
                let changes = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                after(delay) {
                    var config = model.settings.config
                    var addressName: String?
                    var requirePairing: Bool?
                    var updateCheck: Bool?
                    for change in changes {
                        apply(change, to: &config, addressName: &addressName, requirePairing: &requirePairing, updateCheck: &updateCheck)
                    }
                    print("SillSetAfter \(parts[0]) s: \(changes.joined(separator: ", "))")
                    model.settings.config = config    // one assignment: several keys, one apply
                    if let addressName { model.settings.remoteAddressName = addressName }
                    if let updateCheck { model.settings.updateCheck = updateCheck }
                    // Through the identity store first, as the Devices pane's switch goes.
                    if let requirePairing { model.setRequirePairing(requirePairing) }
                }
            }
        }
        let pairAfter = defaults.double(forKey: "SillPairAfter")
        if pairAfter > 0 {
            after(pairAfter) {
                print("SillPairAfter \(pairAfter) s: opening a pairing window")
                model.pairDevice()
            }
        }
        for delay in times(defaults.string(forKey: "SillCancelPairingAfter")) {
            after(delay) {
                let wasShown = model.closePairingWindow?() ?? false
                if !wasShown { model.cancelPairing() }
                print("SillCancelPairingAfter \(delay) s: \(wasShown ? "closed the pairing window" : "no pairing window on screen; cancelled")")
            }
        }
        let unpairAfter = defaults.double(forKey: "SillUnpairAfter")
        if unpairAfter > 0 {
            after(unpairAfter) {
                let ids = model.coordinator?.status.snapshot.remote?.paired.map(\.id) ?? []
                print("SillUnpairAfter \(unpairAfter) s: removing \(ids.count) paired device\(ids.count == 1 ? "" : "s")")
                for id in ids { model.removeDevice(id) }
            }
        }
        let noticeAfter = defaults.double(forKey: "SillCableNoticeAfter")
        if noticeAfter > 0 {
            after(noticeAfter) {
                print("SillCableNoticeAfter \(noticeAfter) s: showing the cable notice for a sample device")
                model.showCableNotice?(CableNotice(name: "iPad (iPad14,1)", fingerprint: "sample"))
            }
        }
        for delay in times(defaults.string(forKey: "SillMenuAfter")) {
            after(delay) {
                model.permissions.refresh()
                for line in MenuBuilder.dump(MenuBuilder.entries(for: model), card: model.presentation).split(separator: "\n") {
                    print("SillMenuAfter \(delay) s: \(line)")
                }
            }
        }
        let printAfter = defaults.double(forKey: "SillPrintMenuAfter")
        if printAfter > 0 {
            after(printAfter) {
                model.permissions.refresh()
                model.loginItem.refresh()
                print("SillPrintMenuAfter \(printAfter) s:")
                let text = MenuBuilder.dump(MenuBuilder.entries(for: model), card: model.presentation)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty { print("menu: \(line)") }
                print("Settings › General's update line: \(model.updates.pane.line)")
            }
        }
        let shots = defaults.string(forKey: "SillSettingsShot").flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        if let shots { try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        for (label, delay, step) in settingsSteps(defaults.string(forKey: "SillSettingsAfter")) {
            after(delay) {
                // Once the layout pass has sized the window.
                @MainActor func report(_ name: String) {
                    after(0.6) {
                        let controller = model.settingsWindowForTests?()
                        print("SillSettingsAfter \(label) s: \(controller?.fitReport() ?? "no Settings window")")
                        if let shots, let controller {
                            let url = shots.appendingPathComponent("settings-\(label)s-\(name).png")
                            print("SillSettingsAfter \(label) s: \(controller.writeShot(to: url) ? "wrote" : "couldn’t write") \(url.path)")
                        }
                    }
                }
                switch step {
                case .close:
                    model.settingsWindowForTests?()?.close()
                    print("SillSettingsAfter \(label) s: closed Settings")
                case .tab(let tab):
                    model.showSettings?(tab)
                    report(tab.rawValue)
                case .report:
                    report("report")
                case .end:
                    let scrolled = model.settingsWindowForTests?()?.scrollPaneToEnd() ?? false
                    print("SillSettingsAfter \(label) s: \(scrolled ? "scrolled the pane to its end" : "no pane to scroll")")
                    report("end")
                case .height(let h):
                    testScreenHeight = h > 0 ? h : nil
                    print("SillSettingsAfter \(label) s: the test screen height is \(h > 0 ? "\(Int(h)) pt" : "the screen's own") now; posting the screens' change")
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                    report("height\(Int(h))")
                }
            }
        }
        let quitAfter = defaults.double(forKey: "SillQuitAfter")
        if quitAfter > 0 {
            after(quitAfter) {
                print("SillQuitAfter \(quitAfter) s: quitting")
                NSApp.terminate(nil)
            }
        }
    }

    /// A run-loop Timer `delay` seconds from now (the modal-loop rule: never a Task).
    private static func after(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private enum SettingsStep { case tab(SettingsTab), close, report, end, height(CGFloat) }

    /// "2 remote; 4 report; 6 height=700; 8 close" (-SillSettingsAfter): each step's seconds as
    /// written, as a number, and what it does. A tab by its raw value or title, or the start of one,
    /// without spaces and in any case; a bad step is skipped with a line.
    private static func settingsSteps(_ spec: String?) -> [(String, Double, SettingsStep)] {
        guard let spec else { return [] }
        return spec.split(separator: ";").compactMap { raw in
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let delay = Double(parts[0]), delay > 0 else {
                print("SillSettingsAfter: can’t read “\(raw)”; expected '<seconds> <tab or step>'")
                return nil
            }
            let word = parts[1].lowercased().replacingOccurrences(of: " ", with: "")
            if word == "close" { return (parts[0], delay, .close) }
            if word == "report" { return (parts[0], delay, .report) }
            if word == "end" { return (parts[0], delay, .end) }
            if word.hasPrefix("height=") {
                guard let h = Double(word.dropFirst("height=".count)), h >= 0 else {
                    print("SillSettingsAfter: can’t read “\(parts[1])”; expected height=<points>")
                    return nil
                }
                return (parts[0], delay, .height(CGFloat(h)))
            }
            let matches = SettingsTab.allCases.filter {
                $0.rawValue.lowercased().hasPrefix(word) || $0.title.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(word)
            }
            guard matches.count == 1, let tab = matches.first else {
                print("SillSettingsAfter: “\(parts[1])” is no step: a tab (general, devices, streaming, virtual display, permissions, remote access, or the start of one), close, report, end or height=<points>")
                return nil
            }
            return (parts[0], delay, .tab(tab))
        }
    }

    /// "3; 9.5; 15" (or "3, 9.5"): the times a hook fires; a bad entry is skipped with a line.
    private static func times(_ spec: String?) -> [Double] {
        guard let spec else { return [] }
        return spec.split(whereSeparator: { $0 == ";" || $0 == "," }).compactMap { part in
            let text = part.trimmingCharacters(in: .whitespaces)
            guard let t = Double(text), t > 0 else { print("Debug hook: can’t read “\(text)” as seconds"); return nil }
            return t
        }
    }

    private static func apply(_ change: String, to config: inout HostConfig, addressName: inout String?, requirePairing: inout Bool?,
                              updateCheck: inout Bool?) {
        let kv = change.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { print("SillSetAfter: can’t read “\(change)”"); return }
        let (key, value) = (kv[0], kv[1])
        let flag = ["1", "true", "yes", "on"].contains(value.lowercased())
        switch key {
        case "maxFPS": if let v = Int(value) { config.maxFPS = v }
        case "captureScale": if let v = Double(value) { config.captureScale = CGFloat(v) }
        case "bitrate": if let v = Int(value) { config.bitrate = v }
        case "awayBitrate": if let v = Int(value) { config.awayBitrate = v }
        case "awayCaptureScale": if let v = Double(value) { config.awayCaptureScale = CGFloat(v) }
        case "prioritizeSpeed": config.prioritizeSpeed = flag
        case "virtualDisplay": config.virtualDisplay = flag
        case "directWireless": config.directWireless = flag
        case "remoteAccess": config.remoteAccess = flag
        case "remotePort": if let v = Int(value) { config.remotePort = v }
        case "internetAccess": config.internetAccess = flag
        case "shareClipboard": config.shareClipboard = flag
        case "remoteAddressName": addressName = value
        case "requirePairing": requirePairing = flag
        case "updateCheck": updateCheck = flag
        default: print("SillSetAfter: no setting called \(key)")
        }
    }

    // MARK: Previews

    /// -SillRenderPreviews <dir>: renders and exits. Called before anything else starts.
    static func renderPreviewsIfAsked(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "SillRenderPreviews"), !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        // The Devices and Remote Access panes are drawn in each of their states below instead of
        // live (the model has no host here, so they would only ever show "off" and nothing paired).
        // General's update section is fixed at "Not checked yet.", whatever an earlier run stored;
        // its states are drawn alone below.
        let neverChecked = updatePaneSamples()[0].pane
        for tab in SettingsTab.allCases where tab != .remoteAccess && tab != .devices {
            for (name, appearance) in appearances {
                render(SettingsPane(tab: tab, model: model, previewUpdates: neverChecked, previewClipboardAccess: .allowed)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, to: out.appendingPathComponent("pane-\(tab.rawValue)-\(name).png"))
            }
        }
        for sample in devicesPaneSamples() {
            let pane = DevicesPane(status: sample.status, requirePairing: .constant(sample.requirePairing),
                                   requirePairingProblem: nil, actions: DevicesPane.Actions(), now: previewNow)
                .formStyle(.grouped)
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in appearances {
                render(pane, appearance: appearance, to: out.appendingPathComponent("pane-devices-\(sample.name)-\(name).png"))
            }
        }
        // General's clipboard section in each of macOS's answers (ClipboardPolicy.MacAccess), and with
        // the switch off, when it says nothing of them.
        let clipboardSamples: [(String, Bool, ClipboardPolicy.MacAccess)] = [
            ("allowed", true, .allowed), ("notasked", true, .notAsked), ("asks", true, .asks), ("denied", true, .denied),
            ("off-denied", false, .denied),
        ]
        for (sampleName, on, access) in clipboardSamples {
            let section = Form { ClipboardSection(shareClipboard: .constant(on), access: access) }
                .formStyle(.grouped)
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in appearances {
                render(section, appearance: appearance, to: out.appendingPathComponent("pane-clipboard-\(sampleName)-\(name).png"))
            }
        }
        for sample in updatePaneSamples() {
            let section = Form { UpdatesSection(pane: sample.pane, automatic: .constant(sample.automatic)) }
                .formStyle(.grouped)
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in appearances {
                render(section, appearance: appearance, to: out.appendingPathComponent("pane-updates-\(sample.name)-\(name).png"))
            }
        }
        for sample in remotePaneSamples() {
            let pane = RemoteAccessPane(status: sample.status, remoteAccess: .constant(sample.status.remoteAccess),
                                        internetAccess: .constant(sample.status.internetAccess), port: 7455,
                                        addressName: sample.status.addressName, actions: RemoteAccessPane.Actions())
                .formStyle(.grouped)
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in appearances {
                render(pane, appearance: appearance, to: out.appendingPathComponent("pane-remote-\(sample.name)-\(name).png"))
            }
        }
        for sample in pairingSamples() {
            // A view with no window reads a display scale of 1 while the bitmap is 2×: the QR code
            // would be made for 1× and smoothed on the way up. A Retina window gets 2 by itself.
            let view = PairDeviceView(offer: sample.offer, status: sample.status, remoteAccess: sample.remoteAccess,
                                      actions: PairDeviceView.Actions(), now: previewNow)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in appearances {
                render(view, appearance: appearance, to: out.appendingPathComponent("pairing-\(sample.name)-\(name).png"))
            }
        }
        let notice = CableNoticeView(name: "iPad (iPad14,1)", actions: CableNoticeView.Actions(), still: true)
            .background(Color(nsColor: .windowBackgroundColor))
        for (name, appearance) in appearances {
            render(notice, appearance: appearance, to: out.appendingPathComponent("pairing-cablenotice-\(name).png"))
        }

        var menuText = ""
        let login = LoginState(available: true, on: false, needsApproval: false, error: nil)
        for sample in samples() {
            let p = StatusText.present(snapshot: sample.snapshot, permissions: sample.permissions,
                                       startupError: sample.startupError, hasCoordinator: true, now: previewNow)
            for (name, appearance) in appearances {
                render(StatusCard(presentation: p).padding(.vertical, 4).background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, to: out.appendingPathComponent("card-\(sample.name)-\(name).png"))
            }
            var config = model.settings.config
            config.virtualDisplay = sample.snapshot.virtualDisplayOn     // the checkmark matches the sample
            let entries = MenuBuilder.entries(presentation: p, config: config, login: login, permissions: sample.permissions)
            menuText += "=== \(sample.name) (glyph: \(p.glyph), tooltip: \(p.tooltip))\n"
            menuText += MenuBuilder.dump(entries, card: p) + "\n"
        }
        // A device's link that does not keep up (docs/remote-bundle-plan.md §6.6): cards only.
        for sample in linkSamples() {
            let p = StatusText.present(snapshot: sample.snapshot, permissions: sample.permissions,
                                       startupError: sample.startupError, hasCoordinator: true)
            for (name, appearance) in appearances {
                render(StatusCard(presentation: p).padding(.vertical, 4).background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, to: out.appendingPathComponent("card-\(sample.name)-\(name).png"))
            }
        }
        // A newer release found (0.4 against 0.3): the idle menu with its item; the glyph stays.
        if let idle = samples().first(where: { $0.name == "idle" }) {
            let p = StatusText.present(snapshot: idle.snapshot, permissions: idle.permissions, startupError: nil, hasCoordinator: true)
            let entries = MenuBuilder.entries(presentation: p, config: model.settings.config, login: login, permissions: idle.permissions,
                                              update: (offer: previewOffer, running: SillVersion("0.3.0")!))
            menuText += "=== update-available (glyph: \(p.glyph), tooltip: \(p.tooltip))\n"
            menuText += MenuBuilder.dump(entries, card: p) + "\n"
        }
        try? menuText.write(to: out.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        renderGlyphSheet(to: out.appendingPathComponent("glyphs.png"))
        print("Previews written to \(out.path)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("Preview \(url.lastPathComponent): nothing to render")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Every glyph state on a light and a dark menu bar at real size, then 6× for review, and the
    /// SF Symbol fallback for comparison.
    private static func renderGlyphSheet(to url: URL) {
        let states = StatusGlyph.State.allCases
        let zoom: CGFloat = 6
        let zoomed = CGFloat(states.count) * (StatusGlyph.size.width * zoom + 10) + 10
        let size = NSSize(width: max(60 * CGFloat(states.count + 1) + 20, zoomed), height: 100 + StatusGlyph.size.height * zoom + 20)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        func tinted(_ image: NSImage, _ ink: NSColor) -> NSImage {
            NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
        }
        for (row, dark) in [false, true].enumerated() {
            let bar = NSRect(x: 0, y: size.height - 40 - CGFloat(row) * 40, width: size.width, height: 30)
            (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            bar.fill()
            let ink: NSColor = dark ? .white : .black
            let images = states.map { StatusGlyph.image($0) } + [StatusGlyph.symbolFallback].compactMap { $0 }
            for (i, image) in images.enumerated() {
                let s = image.size.height > 0 ? image.size : StatusGlyph.size
                tinted(image, ink).draw(in: NSRect(x: 20 + CGFloat(i) * 60, y: bar.minY + (30 - s.height) / 2, width: s.width, height: s.height))
            }
        }
        for (i, state) in states.enumerated() {
            let g = StatusGlyph.size
            StatusGlyph.image(state).draw(in: NSRect(x: 10 + CGFloat(i) * (g.width * zoom + 10), y: 10,
                                                     width: g.width * zoom, height: g.height * zoom))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Canned states

    /// Stand-ins for connections: a device's id is its connection's ObjectIdentifier.
    private static let tokens = [NSObject(), NSObject()]

    private struct Sample {
        var name: String
        var snapshot: HostStatusSnapshot
        var permissions = PermissionState(screenRecording: true, accessibility: true)
        var startupError: String?
    }

    private static func samples() -> [Sample] {
        var list = localSamples()
        // Sill.app always has remote access: every menu shows its two items (off here).
        for i in list.indices { list[i].snapshot.remote = RemoteStatus() }
        // One device from away: its card names the remote route, never a link word.
        var remote = list.first { $0.name == "streaming" }?.snapshot ?? HostStatusSnapshot()
        remote.devices = [HostStatusSnapshot.Device(id: ObjectIdentifier(tokens[0]), endpoint: "100.84.3.2:61022",
                                                    name: "iPad (iPad14,1)", fps: 60, frameAgeMs: 41, rttMs: 48,
                                                    remoteRoute: "through Tailscale")]
        remote.remote = RemoteStatus(remoteAccess: true, listener: .listening(7455), addresses: tailscaleAddresses,
                                     lanAddress: "192.168.1.20")
        var taken = list.first { $0.name == "idle" }?.snapshot ?? HostStatusSnapshot()
        taken.remote = RemoteStatus(remoteAccess: true, listener: .portInUse(7455), lanAddress: "192.168.1.20")
        list.append(Sample(name: "remote-device", snapshot: remote))
        list.append(Sample(name: "remote-port-in-use", snapshot: taken))
        // The same device while the away quality runs (docs/remote-bundle-plan.md §5.7): the menu's
        // Quality subtitle says so, and the stream runs at Low · Standard.
        list.append(Sample(name: "remote-away", snapshot: remoteAway()))
        // Pairing at home (docs/home-pairing-plan.md §6.4): a device's ask while its window shows
        // the code, while the limits kept one from opening, and while this Mac was locked; an older
        // device refused at the home door; the keychain unusable, so no home door at all.
        let idle = list.first { $0.name == "idle" }?.snapshot ?? HostStatusSnapshot()
        func home(_ change: (inout RemoteStatus) -> Void) -> HostStatusSnapshot {
            var snapshot = idle
            var r = RemoteStatus(homeDoor: .pairingRequired)
            change(&r)
            snapshot.remote = r
            return snapshot
        }
        let asked = previewNow.addingTimeInterval(-20)
        list.append(Sample(name: "wants-to-pair", snapshot: home {
            $0.pairingRequest = RemoteStatus.PairingRequest(name: "iPad (iPad14,1)", at: asked, reason: "showing")
            $0.pairing = .open(requestedBy: "iPad (iPad14,1)", expiresAt: previewNow.addingTimeInterval(280), triesLeft: 5,
                               lastWrongFrom: nil, byDevice: true)
        }))
        list.append(Sample(name: "wants-to-pair-limit", snapshot: home {
            $0.pairingRequest = RemoteStatus.PairingRequest(name: "iPhone (iPhone17,1)", at: asked, reason: "limit")
        }))
        list.append(Sample(name: "wants-to-pair-locked", snapshot: home {
            $0.pairingRequest = RemoteStatus.PairingRequest(name: "iPad (iPad14,1)", at: asked, reason: "locked")
        }))
        list.append(Sample(name: "older-device", snapshot: home { $0.olderDeviceAt = previewNow.addingTimeInterval(-90) }))
        var closed = HostStatusSnapshot()
        closed.remote = RemoteStatus(identityProblem: keychainProblem,
                                     homeDoor: .unavailable("Sill couldn’t use its key in the keychain (\(keychainProblem))"))
        list.append(Sample(name: "devices-cant-connect", snapshot: closed))
        return list
    }

    /// The remote device of `remote-device`, every connected device away: the away quality runs.
    private static func remoteAway() -> HostStatusSnapshot {
        var s = samples_remoteBase()
        s.away = true
        s.stream = HostStatusSnapshot.Stream(kind: .desktop, title: "Whole Desktop", width: 1512, height: 982, fps: 60, mbps: 4,
                                             onVirtualDisplay: false, softwareEncoder: false)
        s.encodedFPS = 58
        return s
    }

    /// `remote-device`'s snapshot: one device through Tailscale, streaming.
    private static func samples_remoteBase() -> HostStatusSnapshot {
        var s = localSamples().first { $0.name == "streaming" }?.snapshot ?? HostStatusSnapshot()
        s.devices = [HostStatusSnapshot.Device(id: ObjectIdentifier(tokens[0]), endpoint: "100.84.3.2:61022",
                                               name: "iPad (iPad14,1)", fps: 60, frameAgeMs: 41, rttMs: 48,
                                               remoteRoute: "through Tailscale")]
        s.remote = RemoteStatus(remoteAccess: true, listener: .listening(7455), addresses: tailscaleAddresses,
                                lanAddress: "192.168.1.20")
        return s
    }

    /// card-link-behind and card-link-stalled: the remote device at Pro on a link that cannot carry
    /// it (3 fps, a 531 ms round trip), and on a path gone dead both ways.
    private static func linkSamples() -> [Sample] {
        var behind = samples_remoteBase()
        behind.devices[0].fps = 3
        behind.devices[0].frameAgeMs = 1_840
        behind.devices[0].rttMs = 531
        behind.devices[0].link = HostStatusSnapshot.LinkStatus(state: .behind, withheld: 52, bitrate: 40_000_000, carriedKbps: 6_400,
                                                               suggestedBitrate: 4_000_000, suggestedCaptureScale: 1)
        behind.stream?.mbps = 40
        var stalled = behind
        stalled.devices[0].fps = 0
        stalled.devices[0].rttMs = -1
        stalled.devices[0].link = HostStatusSnapshot.LinkStatus(state: .stalled, withheld: 60, bitrate: 40_000_000)
        return [Sample(name: "link-behind", snapshot: behind), Sample(name: "link-stalled", snapshot: stalled)]
    }

    private static func localSamples() -> [Sample] {
        // Each word once or more: the iPad on Wi-Fi, on the USB cable ("connected" and the software
        // encoder sample), the iPhone over peer-to-peer Wi-Fi (with the iPad, and alone on a still
        // window); the test pattern's loopback client has none.
        let ipad = HostStatusSnapshot.Device(id: ObjectIdentifier(tokens[0]), endpoint: "192.168.1.23:52344",
                                             name: "iPad (iPad14,1)", fps: 118, frameAgeMs: 9, rttMs: 7, route: .wifi)
        var cabledIPad = ipad
        cabledIPad.endpoint = "fe80::1%anri0.61390"
        cabledIPad.route = .wired
        let iphone = HostStatusSnapshot.Device(id: ObjectIdentifier(tokens[1]), endpoint: "fe80::2%awdl0.63101",
                                               name: "iPhone (iPhone17,1)", fps: 60, frameAgeMs: 11, rttMs: 8, route: .direct)
        let window = HostStatusSnapshot.Stream(kind: .window, title: "Safari — Apple Developer Documentation: ScreenCaptureKit",
                                               width: 3024, height: 1898, fps: 120, mbps: 30,
                                               onVirtualDisplay: true, softwareEncoder: false)
        var idle = HostStatusSnapshot()
        idle.network = .advertising("Noah’s MacBook Pro")
        var registering = HostStatusSnapshot()
        registering.network = .registering
        var connected = idle
        connected.devices = [cabledIPad]
        var streaming = connected
        streaming.devices = [ipad]
        streaming.stream = window
        streaming.encodedFPS = 118
        streaming.virtualDisplayOn = true
        var two = streaming
        two.devices = [ipad, iphone]
        // A still window on the Mac's own screen (virtual display off) to one device, at the most the
        // menu offers (Maximum at 120 fps: 80 Mbps) over the widest word: the source row stays on one
        // line, as it does while the picture changes, so the open menu keeps its height. The device
        // gets no frames, so its row reads "0 fps · frame age –".
        var stillIPhone = iphone
        stillIPhone.fps = 0
        stillIPhone.frameAgeMs = -1
        var still = idle
        still.devices = [stillIPhone]
        still.stream = window
        still.stream?.onVirtualDisplay = false
        still.stream?.mbps = 80
        var software = connected
        software.softwareEncoder = true
        software.stream = HostStatusSnapshot.Stream(kind: .desktop, title: "Whole Desktop", width: 1512, height: 982, fps: 60,
                                                    mbps: 15, onVirtualDisplay: false, softwareEncoder: true)
        software.encodedFPS = 0
        var stuck = software
        stuck.hardwareEncoderStuck = true
        var fallback = streaming
        fallback.stream?.onVirtualDisplay = false
        fallback.lastStageFailure = "needs Accessibility"
        var test = HostStatusSnapshot()
        test.synthetic = true
        test.network = .notAdvertised(port: 56192)
        test.devices = [HostStatusSnapshot.Device(id: ObjectIdentifier(tokens[0]), endpoint: "127.0.0.1:49538")]
        test.stream = HostStatusSnapshot.Stream(kind: .testPattern, title: "Test Pattern", width: 3024, height: 1898, fps: 60,
                                                mbps: 15, onVirtualDisplay: false, softwareEncoder: false)
        test.encodedFPS = 60
        var waiting = HostStatusSnapshot()
        waiting.network = .waiting("POSIXErrorCode(rawValue: 50): Network is down")
        var failed = HostStatusSnapshot()
        failed.network = .failed("POSIXErrorCode(rawValue: 48): Address already in use")
        return [
            Sample(name: "idle", snapshot: idle),
            Sample(name: "registering", snapshot: registering),
            Sample(name: "connected", snapshot: connected),
            Sample(name: "streaming", snapshot: streaming),
            Sample(name: "still-window", snapshot: still),
            Sample(name: "two-devices", snapshot: two),
            Sample(name: "software-encoder", snapshot: software),
            Sample(name: "software-encoder-stuck", snapshot: stuck),
            Sample(name: "virtual-display-fallback", snapshot: fallback),
            Sample(name: "permissions-missing", snapshot: idle,
                   permissions: PermissionState(screenRecording: false, accessibility: false)),
            Sample(name: "test-pattern", snapshot: test,
                   permissions: PermissionState(screenRecording: false, accessibility: true)),
            Sample(name: "waiting", snapshot: waiting),
            Sample(name: "failed", snapshot: failed),
            Sample(name: "startup-error", snapshot: HostStatusSnapshot(), startupError: "POSIXErrorCode(rawValue: 22): Invalid argument"),
        ]
    }
}

// MARK: Update check previews

extension DebugHooks {
    /// Sill 0.4, found by a check, against a running 0.3.
    static let previewOffer = UpdatePolicy.Offer(version: SillVersion("0.4.0")!, tag: "v0.4.0",
                                                 url: URL(string: "https://github.com/Saffsanity/sill/releases/tag/v0.4.0")!)

    struct UpdatePaneSample {
        var name: String
        var pane: UpdatePolicy.Pane
        var automatic = true
    }

    /// pane-updates-{never,last,checking,uptodate,available,norelease,limited,offline,noversion,
    /// testpattern}: the section in each state, at the previews' clock (`previewNow`).
    static func updatePaneSamples() -> [UpdatePaneSample] {
        func pane(checking: Bool = false, result: UpdatePolicy.Outcome? = nil, offer: UpdatePolicy.Offer? = nil,
                  lastCheck: Date? = nil, hasVersion: Bool = true, testPatternOnly: Bool = false) -> UpdatePolicy.Pane {
            UpdatePolicy.pane(checking: checking, result: result, resultID: result == nil ? 0 : 1, offer: offer, lastCheck: lastCheck,
                              hasVersion: hasVersion, testPatternOnly: testPatternOnly,
                              time: UpdateChecker.time, date: UpdateChecker.date)
        }
        let lastCheck = previewNow.addingTimeInterval(-3 * 3600)
        return [
            UpdatePaneSample(name: "never", pane: pane()),
            UpdatePaneSample(name: "last", pane: pane(lastCheck: lastCheck)),
            UpdatePaneSample(name: "checking", pane: pane(checking: true, lastCheck: lastCheck)),
            UpdatePaneSample(name: "uptodate", pane: pane(result: .upToDate(tag: "v0.3.0"), lastCheck: previewNow)),
            UpdatePaneSample(name: "available", pane: pane(offer: previewOffer, lastCheck: lastCheck)),
            UpdatePaneSample(name: "norelease", pane: pane(result: .noRelease, lastCheck: previewNow)),
            UpdatePaneSample(name: "limited", pane: pane(result: .limited(status: 403, reset: previewNow.addingTimeInterval(42 * 60)), lastCheck: previewNow)),
            UpdatePaneSample(name: "offline", pane: pane(result: .noConnection(code: -1009, description: "The Internet connection appears to be offline."),
                                                         lastCheck: lastCheck), automatic: false),
            UpdatePaneSample(name: "noversion", pane: pane(hasVersion: false)),
            UpdatePaneSample(name: "testpattern", pane: pane(testPatternOnly: true)),
        ]
    }
}

// MARK: Remote access previews

extension DebugHooks {
    /// The previews' clock: 2026-09-24 16:00 UTC, so "last connected 2 minutes ago" and the
    /// countdown come out the same every run.
    static let previewNow = Date(timeIntervalSince1970: 1_790_265_600)

    static let tailscaleAddresses = [
        MacAddress(host: "mac-mini.tail1234.ts.net", kind: MacAddress.vpn, via: "Tailscale"),
        MacAddress(host: "100.101.102.103", kind: MacAddress.vpn, via: "Tailscale"),
        MacAddress(host: "fd7a:115c:a1e0::1234", kind: MacAddress.vpn, via: "Tailscale"),
        MacAddress(host: "192.168.1.20", kind: MacAddress.lan, via: "Wi\u{2011}Fi"),
    ]

    /// The keychain's refusal the unusable samples show.
    static let keychainProblem = "the key couldn’t be read: The user name or passphrase you entered is not correct."

    struct DevicesPaneSample {
        var name: String
        var status: RemoteStatus
        var requirePairing = true
    }

    /// pane-devices-{required,off,empty,unavailable}: three devices, one paired over the USB cable
    /// and seen over Wi-Fi at home, one by QR code and seen through Tailscale yesterday, one by
    /// code and never connected; Require pairing off (its warning); nothing paired yet; the
    /// keychain unusable (no home door).
    static func devicesPaneSamples() -> [DevicesPaneSample] {
        let now = previewNow
        let ipad = PairedDeviceSummary(id: "ipad", keyPrefix: "5KD2Q7", name: "iPad (iPad14,1)", model: "iPad14,1",
                                       pairedAt: now.addingTimeInterval(-2 * 86_400), method: PairResult.cable,
                                       lastSeen: now.addingTimeInterval(-120), lastRoute: "over Wi\u{2011}Fi")
        let iphone = PairedDeviceSummary(id: "iphone", keyPrefix: "9XQ3M1", name: "iPhone (iPhone17,1)", model: "iPhone17,1",
                                         pairedAt: now.addingTimeInterval(-3 * 86_400), method: PairRequest.qr,
                                         lastSeen: now.addingTimeInterval(-86_400), lastRoute: "through Tailscale")
        let pro = PairedDeviceSummary(id: "ipadpro", keyPrefix: "H4MZ8T", name: "iPad (iPad17,4)", model: "iPad17,4",
                                      pairedAt: now.addingTimeInterval(-3_600), method: PairRequest.code)
        return [
            DevicesPaneSample(name: "required", status: RemoteStatus(paired: [ipad, iphone, pro], homeDoor: .pairingRequired)),
            DevicesPaneSample(name: "off", status: RemoteStatus(paired: [ipad, iphone], homeDoor: .open), requirePairing: false),
            DevicesPaneSample(name: "empty", status: RemoteStatus(homeDoor: .pairingRequired)),
            DevicesPaneSample(name: "unavailable",
                              status: RemoteStatus(identityProblem: keychainProblem,
                                                   homeDoor: .unavailable("Sill couldn’t use its key in the keychain (\(keychainProblem))"))),
        ]
    }

    struct RemotePaneSample {
        var name: String
        var status: RemoteStatus
    }

    /// pane-remote-{off,tailscale,notconnected,novpn,internet,cgnat,doublenat,inuse,keychain}.
    static func remotePaneSamples() -> [RemotePaneSample] {
        let now = previewNow
        let ipad = PairedDeviceSummary(id: "ipad", keyPrefix: "5KD2Q7", name: "iPad (iPad14,1)", model: "iPad14,1",
                                       pairedAt: now.addingTimeInterval(-3 * 86_400), method: PairRequest.qr,
                                       lastSeen: now.addingTimeInterval(-120), lastRoute: "through Tailscale")
        let iphone = PairedDeviceSummary(id: "iphone", keyPrefix: "9XQ3M1", name: "iPhone (iPhone17,1)", model: "iPhone17,1",
                                         pairedAt: now.addingTimeInterval(-86_400), method: PairRequest.code)
        let wifi = [MacAddress(host: "192.168.1.20", kind: MacAddress.lan, via: "Wi\u{2011}Fi")]
        let internetAddresses = tailscaleAddresses + [
            MacAddress(host: "home.example.net", port: 17455, kind: MacAddress.internet, via: "Address name"),
            MacAddress(host: "203.0.113.9", kind: MacAddress.internet, via: "Router"),
            MacAddress(host: "2001:db8::20", kind: MacAddress.internet, via: "IPv6"),
        ]
        func on(_ addresses: [MacAddress], listener: RemoteStatus.Listener = .listening(7455), vpnDown: [String] = [],
                paired: [PairedDeviceSummary] = [ipad, iphone]) -> RemoteStatus {
            RemoteStatus(remoteAccess: true, listener: listener, addresses: addresses, vpnDown: vpnDown,
                         lanAddress: "192.168.1.20", paired: paired)
        }
        func internet(_ router: RemoteStatus.Router, _ addresses: [MacAddress]) -> RemoteStatus {
            var s = on(addresses)
            s.internetAccess = true
            s.router = router
            s.addressName = "home.example.net:17455"
            return s
        }
        return [
            RemotePaneSample(name: "off", status: RemoteStatus(lanAddress: "192.168.1.20", paired: [ipad])),
            RemotePaneSample(name: "tailscale", status: on(tailscaleAddresses)),
            RemotePaneSample(name: "notconnected", status: on(wifi, vpnDown: ["Tailscale"], paired: [ipad])),
            RemotePaneSample(name: "novpn", status: on(wifi, paired: [])),
            RemotePaneSample(name: "internet", status: internet(.address("203.0.113.9"), internetAddresses)),
            RemotePaneSample(name: "cgnat", status: internet(.carrierNAT("100.72.14.3"), tailscaleAddresses)),
            RemotePaneSample(name: "doublenat", status: internet(.doubleNAT, tailscaleAddresses)),
            RemotePaneSample(name: "inuse", status: on(tailscaleAddresses, listener: .portInUse(7455))),
            RemotePaneSample(name: "keychain",
                             status: RemoteStatus(identityProblem: "the key couldn’t be read: The user name or passphrase you entered is not correct.")),
        ]
    }

    struct PairingSample {
        var name: String
        var offer: RemoteAccess.PairingOffer
        var status: RemoteStatus
        var remoteAccess = true
    }

    /// pairing-{waiting,requested,wrong,paired,stopped,expired,remoteoff,novpn,othervpn,longname,asked,
    /// askednearby} (pairing-cablenotice is drawn on its own). A stand-in Mac key (the plan's
    /// SHA-256("mac") vector) and the plan's example code: nothing here pairs anything. The address to
    /// type is Tailscale's name with its IPv4 under it; `novpn` has no VPN, so this network's address;
    /// `othervpn` has a VPN that is not Tailscale, so this network's address with that VPN's IPv4
    /// under it; `longname` has a long MagicDNS name, 40 characters, on a port other than 7455. Not the
    /// longest there can be: LocalHostName allows 63 characters, and from about 46 with a port (52
    /// without) a name wraps after a hyphen, never cut. `asked` and `askednearby` are windows a device
    /// opened by asking at the home door.
    static func pairingSamples() -> [PairingSample] {
        let fingerprint = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        func makeLink(port: Int, _ addresses: [String]) -> PairLink {
            let parsed = addresses.compactMap { text -> ParsedAddress? in
                if case .success(let a) = AddressParser.parse(text) { return a }
                return nil
            }
            return PairLink(fingerprint: fingerprint, secret: Data(repeating: 0x16, count: 16), name: "Mac mini", port: port, addresses: parsed)
        }
        let standard = makeLink(port: 7455, ["192.168.1.20", "mac-mini.tail1234.ts.net", "100.101.102.103"])
        let expires = previewNow.addingTimeInterval(298)
        func offer(_ requestedBy: String? = nil, link: PairLink? = nil) -> RemoteAccess.PairingOffer {
            let link = link ?? standard
            return RemoteAccess.PairingOffer(url: link.url, code: "482913557208", expiresAt: expires, requestedBy: requestedBy,
                                             port: link.port, again: false)
        }
        func status(_ pairing: RemoteStatus.Pairing, addresses: [MacAddress]? = nil, port: Int = 7455) -> RemoteStatus {
            RemoteStatus(remoteAccess: true, listener: .listening(port), addresses: addresses ?? tailscaleAddresses,
                         lanAddress: "192.168.1.20", pairing: pairing)
        }
        let open = RemoteStatus.Pairing.open(requestedBy: nil, expiresAt: expires, triesLeft: 5, lastWrongFrom: nil, byDevice: false)
        let wifi = [MacAddress(host: "192.168.1.20", kind: MacAddress.lan, via: "Wi\u{2011}Fi")]
        let otherVPN = [MacAddress(host: "10.8.0.6", kind: MacAddress.vpn, via: "WireGuard")] + wifi
        let longName = "studio-macbook-pro-16-in.tail1234.ts.net"
        let long = [MacAddress(host: longName, kind: MacAddress.vpn, via: "Tailscale")] + tailscaleAddresses.dropFirst()
        let longLink = makeLink(port: 17455, [longName, "100.101.102.103", "fd7a:115c:a1e0::1234", "192.168.1.20"])
        // A window a device opened by asking at the home door: its link names no address.
        func askedOffer(_ who: String, from: String) -> RemoteAccess.PairingOffer {
            let link = makeLink(port: 7455, [])
            return RemoteAccess.PairingOffer(url: link.url, code: "482913557208", expiresAt: expires, requestedBy: who,
                                             port: link.port, again: false, byDevice: true, askedFrom: from)
        }
        func askedStatus(_ who: String) -> RemoteStatus {
            RemoteStatus(lanAddress: "192.168.1.20",
                         pairing: .open(requestedBy: who, expiresAt: expires, triesLeft: 5, lastWrongFrom: nil, byDevice: true),
                         homeDoor: .pairingRequired)
        }
        return [
            PairingSample(name: "waiting", offer: offer(), status: status(open)),
            PairingSample(name: "requested", offer: offer("iPad (iPad14,1)"),
                          status: status(.open(requestedBy: "iPad (iPad14,1)", expiresAt: expires, triesLeft: 5, lastWrongFrom: nil, byDevice: false))),
            PairingSample(name: "wrong", offer: offer(),
                          status: status(.open(requestedBy: nil, expiresAt: expires, triesLeft: 4, lastWrongFrom: "203.0.113.9", byDevice: false))),
            PairingSample(name: "paired", offer: offer(), status: status(.paired("iPad (iPad14,1)"))),
            PairingSample(name: "stopped", offer: offer(), status: status(.stopped)),
            PairingSample(name: "expired", offer: offer(), status: status(.expired)),
            PairingSample(name: "remoteoff", offer: offer(), status: status(open), remoteAccess: false),
            PairingSample(name: "novpn", offer: offer(link: makeLink(port: 7455, ["192.168.1.20"])), status: status(open, addresses: wifi)),
            PairingSample(name: "othervpn", offer: offer(link: makeLink(port: 7455, ["10.8.0.6", "192.168.1.20"])),
                          status: status(open, addresses: otherVPN)),
            PairingSample(name: "longname", offer: offer(link: longLink), status: status(open, addresses: long, port: 17455)),
            // Windows a device opened by asking at the home door: its link has no address, the
            // window no Address row and no Remote Access line (Remote Access off here, as it is at
            // most homes); over this network, and nearby (peer-to-peer Wi-Fi).
            PairingSample(name: "asked", offer: askedOffer("iPad (iPad14,1)", from: "on this network"),
                          status: askedStatus("iPad (iPad14,1)"), remoteAccess: false),
            PairingSample(name: "askednearby", offer: askedOffer("iPhone (iPhone17,1)", from: "nearby"),
                          status: askedStatus("iPhone (iPhone17,1)"), remoteAccess: false),
        ]

    }
}
