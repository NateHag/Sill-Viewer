import AppKit
import SwiftUI
import SillHostCore

/// The Settings window's tabs, in the toolbar's order.
enum SettingsTab: String, CaseIterable {
    case general, devices, streaming, virtualDisplay, permissions, remoteAccess

    var title: String {
        switch self {
        case .general: "General"
        case .devices: "Devices"
        case .streaming: "Streaming"
        case .virtualDisplay: "Virtual Display"
        case .permissions: "Permissions"
        case .remoteAccess: "Remote Access"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .devices: "ipad.and.iphone"
        case .streaming: "play.rectangle"
        case .virtualDisplay: "display"
        case .permissions: "lock.shield"
        case .remoteAccess: "globe"
        }
    }
}

/// Settings, owned by AppKit: toolbar tabs over grouped SwiftUI Forms, so it looks like a SwiftUI
/// Settings scene but opens from anywhere (the menu, ⌘,, reopening the app, onboarding) and is
/// kept off Sill's own virtual display. The window is made once and hidden on close.
///
/// Never taller than its screen (issue #59, docs/settings-window-plan.md). AppKit makes the selected
/// pane's view as tall as its whole Form, the hosting controller's preferredContentSize, at priority
/// 501, just over the window's own 500 for keeping its size, and sets the window's frame from that
/// in the layout pass; the window is not resizable, so nothing shortens it to the screen. `heightCap`
/// keeps the content at most `SettingsWindowFit.contentLimit` for the window's screen, at 750, and
/// the Form scrolls. Its constant follows the screen (`refit`); the window is moved back onto the
/// screen when Sill's own changes leave it partly outside (`place`).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let tabs: SettingsTabController
    private let heightCap: NSLayoutConstraint
    /// The cap's constant until a screen is known (none at all, or only Sill's virtual display, as a
    /// Mac with no display of its own could have): taller than any display, so no cap, as before.
    private static let noCap: CGFloat = 10_000
    /// A move that waits for the mouse buttons to be released (`placeOnRelease`).
    private var releaseWatch: Timer?

    init(model: AppModel) {
        self.model = model
        tabs = SettingsTabController(model: model)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        heightCap = tabs.view.heightAnchor.constraint(lessThanOrEqualToConstant: Self.noCap)
        heightCap.priority = .defaultHigh
        heightCap.identifier = "Sill.settingsScreenCap"
        super.init(window: window)
        window.delegate = self
        // Centred the first time; after that where the user left it.
        if !window.setFrameUsingName("SillSettings") { window.center() }
        window.setFrameAutosaveName("SillSettings")
        // The cap for the screen the window will show on, before it is ever laid out there.
        refit()
        heightCap.isActive = true
        // A tab switch makes a new 501 constraint at that pane's whole height; the cap holds it, and
        // the screen (the Dock) may have changed since the last look.
        tabs.onSelect = { [weak self] in self?.refit() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Opens Settings in front, on `tab` or the last one shown, and remembers that tab for the
    /// next launch. Remembered here as well as on a tab click: a tab selected while the window
    /// was hidden is not saved by the tab controller (see its `tabView(_:didSelect:)`).
    func show(tab: SettingsTab?) {
        tabs.select(tab ?? model.settings.settingsTab)
        guard let window else { return }
        refit()
        WindowPlacement.bringForward(window)
        // At the selected pane's height, and on the screen bringForward chose (it moves a window that
        // sat on Sill's virtual display), before it is placed there.
        window.layoutIfNeeded()
        refit()
        model.visibleSettingsTab = tabs.current
        model.settings.settingsTab = tabs.current
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closed by the user while a permission is still missing: later launches (a login item)
        // stop opening it and only mark the status item.
        model.permissions.refresh()
        if !model.permissions.allGranted { model.settings.permissionsOnboardingDismissed = true }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.visibleSettingsTab = nil
    }

    // MARK: The screen (issue #59)

    func windowDidChangeScreen(_ notification: Notification) { refit() }

    /// The layout's resize after a tab switch, a pane that grew or a new cap: back onto the screen if
    /// it now runs off it.
    func windowDidResize(_ notification: Notification) { place() }

    /// A display added, removed or rearranged, its resolution, the Dock.
    @objc private func screensChanged(_ notification: Notification) { refit() }

    /// Sets the cap for the window's screen, then moves the window back inside that screen when it is
    /// partly outside. A new cap resizes a window on screen at once, so the move sees its new height
    /// (a window placed at its old height, then shortened from the bottom, would keep no margin above).
    private func refit() {
        guard let window, let visible = fitVisibleFrame() else { return }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let limit = SettingsWindowFit.contentLimit(visible: visible, chrome: chrome)
        if heightCap.constant != limit {
            heightCap.constant = limit
            if window.isVisible { window.layoutIfNeeded() }
        }
        place()
    }

    /// Moves the window back inside its screen's visible frame when it runs off it top or bottom
    /// (SettingsWindowFit.placed), only while it is on screen (a hidden window's frame waits for its
    /// next layout; `show` places it after that), and never while a mouse button is down: a window
    /// the user is dragging (across screens, its cap changing on the way) stays under the pointer and
    /// is placed once every button is up. A window the user leaves partly off the screen stays there
    /// until Sill next changes its size or shows it.
    private func place() {
        guard let window, window.isVisible, let visible = fitVisibleFrame() else { return }
        guard NSEvent.pressedMouseButtons == 0 else { placeOnRelease(); return }
        let placed = SettingsWindowFit.placed(window.frame, in: visible)
        if placed.origin != window.frame.origin { window.setFrameOrigin(placed.origin) }
    }

    /// Places the window once no mouse button is down, looking ten times a second until then. A
    /// run-loop Timer in the common modes, so it also fires while AppKit tracks the mouse.
    private func placeOnRelease() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self?.releaseWatch = nil
                self?.place()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    /// The visible frame the window must fit in: its screen's or, when it is on none or on Sill's
    /// virtual display, the first other screen's, where bringForward puts it; TEST ONLY, the top
    /// part of it (-SillTestScreenHeight).
    private func fitVisibleFrame() -> CGRect? {
        let screens = NSScreen.screens
        let ids = screens.map(Self.displayID)
        let list = zip(screens, ids).map { screen, id in
            SettingsWindowFit.Screen(visible: screen.visibleFrame, sillVirtual: id.map(StreamCoordinator.isSillVirtualDisplay) ?? false)
        }
        let on = window?.screen.flatMap(Self.displayID).flatMap { id in ids.firstIndex(of: id) }
        guard let index = SettingsWindowFit.screenIndex(windowOn: on, screens: list) else { return nil }
        return SettingsWindowFit.visible(list[index].visible, testHeight: DebugHooks.testScreenHeight)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // MARK: TEST ONLY (-SillSettingsAfter, -SillSettingsShot)

    /// The window as it stands, on one line: its frame, content and chrome, the pane's whole height
    /// and how much of it shows (the Form's scroll view), the visible frame it fits in, the cap, and
    /// the room left above and below it.
    func fitReport() -> String {
        guard let window else { return "no window" }
        func n(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        func r(_ rect: CGRect) -> String { "\(n(rect.minX)),\(n(rect.minY)) \(n(rect.width))×\(n(rect.height))" }
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame).height
        let host = tabs.tabViewItems[max(0, tabs.selectedTabViewItemIndex)].viewController
        let pane = host?.preferredContentSize.height ?? 0
        var shows = "no scroll view"
        if let scroll = host.flatMap({ Self.firstScrollView(in: $0.view) }) {
            let clip = scroll.contentView.bounds, document = scroll.documentView?.frame.height ?? 0
            shows = "shows \(n(clip.height)) of \(n(document))" + (document > clip.height + 0.5 ? ", scrolls" : "")
                + (clip.minY > 0.5 ? " (scrolled \(n(clip.minY)))" : "")
        }
        var screen = "no screen"
        if let used = fitVisibleFrame() {
            let real = window.screen?.visibleFrame
            screen = "screen \(window.screen?.localizedName ?? "none") visible \(real.map(r) ?? "none")"
                + (DebugHooks.testScreenHeight != nil ? ", as \(r(used)) (-SillTestScreenHeight)" : "")
                + "; \(n(frame.minY - used.minY)) pt over its bottom, \(n(used.maxY - frame.maxY)) under its top"
        }
        return "\(tabs.current.title): window \(r(frame)) (content \(n(content)), chrome \(n(frame.height - content))); "
            + "pane \(n(pane)) tall, \(shows); limit \(n(heightCap.constant)); \(screen)\(window.isVisible ? "" : "; not on screen")"
    }

    /// Scrolls the pane's Form to its last row, as a scroll to the end would: what a capped pane hides
    /// below the window can be reached.
    func scrollPaneToEnd() -> Bool {
        guard let host = tabs.tabViewItems[max(0, tabs.selectedTabViewItemIndex)].viewController,
              let scroll = Self.firstScrollView(in: host.view), let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let end = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? end : 0))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// Writes the window, its title bar and toolbar included, as cacheDisplay draws them.
    func writeShot(to url: URL) -> Bool {
        guard let frameView = window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let scroll = firstScrollView(in: sub) { return scroll } }
        return nil
    }
}

/// One NSHostingController per tab, sized to its pane, so the window resizes as the tabs change (up to
/// the screen's height: SettingsWindowController's cap).
@MainActor
final class SettingsTabController: NSTabViewController {
    private let model: AppModel
    /// Every selection, the window's own included: SettingsWindowController sets the cap again.
    var onSelect: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: tab, model: model))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    var current: SettingsTab {
        let index = max(0, selectedTabViewItemIndex)
        return (tabViewItems[index].identifier as? String).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func select(_ tab: SettingsTab) {
        if let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab.rawValue }) {
            selectedTabViewItemIndex = index
        }
    }

    /// A tab the user picked. Only while the window is on screen: NSTabViewController also
    /// selects its first tab when `NSWindow(contentViewController:)` loads it, before `show`
    /// has read the saved tab, and saving that would reopen Settings on General every launch.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
        guard view.window?.isVisible == true else { return }
        let tab = current
        model.settings.settingsTab = tab
        model.visibleSettingsTab = tab
    }
}

/// Where Sill's windows appear, and how they come forward.
@MainActor
enum WindowPlacement {
    /// Centres `window` on the main display when it has no screen or sits on the Sill virtual
    /// display (a streamed window lives there, off the user's screens), then activates Sill and
    /// makes the window key. An accessory app's activation can be refused when no click led to
    /// it; the window is then ordered front anyway on the next turn, visible if not key.
    static func bringForward(_ window: NSWindow) {
        if onNoUsefulScreen(window), let area = NSScreen.screens.first?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !window.isKeyWindow { window.orderFrontRegardless() }
            }
        }
    }

    /// A window a device put up (a pairing window it asked for, the cable notice): in front of every
    /// app's windows (over a full-screen app too, with `.fullScreenAuxiliary` in its collection
    /// behavior), off the virtual display, without activating Sill or taking the keyboard, so a
    /// device's request can never swallow what is being typed in another app. A click makes it key.
    /// (docs/home-pairing-plan.md §6.3)
    static func showInFront(_ window: NSWindow) {
        if onNoUsefulScreen(window), let area = NSScreen.screens.first?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        window.orderFrontRegardless()
    }

    private static func onNoUsefulScreen(_ window: NSWindow) -> Bool {
        guard let screen = window.screen else { return true }
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return StreamCoordinator.isSillVirtualDisplay(id)
    }
}
