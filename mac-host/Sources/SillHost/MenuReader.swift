import Foundation
import ApplicationServices
import StreamProtocol

/// Accessibility reads and presses of one app's menu bar (docs/menu-bar-plan.md §4.3). Every call
/// runs on `queue`, never on the main actor or `sill.net`: an app's answer can take a second
/// (Blender: 6 ms a call; a hung app the whole timeout), and a press can wait for the app's action.
/// Every element touched gets `timeout` before its first call (a local call, no IPC); the
/// process-wide default is never changed, as it would change the injector's and the sizer's too.
///
/// The reads, as the probe measured them (2026-09-25): the bar's items are `kAXMenuBarAttribute`'s
/// children, the first the Apple menu (13 of 13 apps), each with one AXMenu child whose children are
/// the items; hidden items are left out. Reading a menu's children makes the app validate it
/// (`menuNeedsUpdate:`, `menuWillOpen:`, `validateMenuItem:` for each item, `menuDidClose:`),
/// throttled by AppKit to about once a second per menu. A missing attribute comes back from
/// `AXUIElementCopyMultipleAttributeValues` as an AXValue holding an AX error, read here as nil
/// (nil title: missing; "" title: a separator's).
final class MenuReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "sill.menus", qos: .userInitiated)
    static let timeout: Float = 1.0
    /// The bar's menus read, the Apple menu not counted.
    static let maxMenus = 32
    /// Items read of one menu; `unread` counts the rest.
    static let maxItems = 500
    /// Seconds for one menu's items. A menu costs a call per item, two for a submenu item, and every
    /// request waits behind it (MenuMirror serves one at a time): 500 items at Blender's 6 ms a call
    /// would take 3 s or more, near or past a device's 4 s wait. Past it the read stops after the
    /// item in hand and `unread` counts the rest; one call can take up to `timeout`, so a read ends
    /// by about 2.5 s. Blender's 42-item Window menu (290 ms), the slowest the probe timed, stays far
    /// inside it.
    static let readBudget = 1.5

    /// One item (or one of the bar's menus) as read, with its index among its menu's children and
    /// its element, which the mirror keeps for presses and for reading its submenu.
    struct Read: @unchecked Sendable {
        let item: RawMenuItem
        let index: Int
        let element: AXUIElement
    }

    enum Failure: Error, Equatable {
        /// AXIsProcessTrusted() false, or .apiDisabled.
        case notTrusted
        /// No AXMenuBar (a background-only app).
        case noMenuBar
        /// The process exited.
        case gone
        /// .cannotComplete after at least 0.9 × timeout.
        case notAnswering
        /// Any other error, by name (WindowSizer.axErrorName), or an id that names nothing.
        case failed(String)
        /// The item at the id is not the one the device was shown there: its title now is `found` (""
        /// for none). Nothing below it was read.
        case notShown(found: String)
        /// On the way from the bar to the id, a menu is not the one read there in this version (another
        /// title, gone, or no menu any more): the app changed the tree in place.
        case moved
        /// The read would end after `until`: its answer could not reach the device in time.
        case late
    }

    struct Menu: @unchecked Sendable {
        let reads: [Read]
        /// All the menu's children.
        let total: Int
        /// The children not read: past `maxItems`, or left when `readBudget` ran out. A device is
        /// told how many more the Mac has.
        let unread: Int
        let ms: Double
    }

    struct Pressed: Equatable {
        enum Outcome: Equatable {
            case pressed
            /// AXPress ran into the timeout: the action is running, often a modal dialog.
            case pressedNoAnswer
            case refused(MenuRefusal)
            /// Found again by its path, a menu on the way was not the one read there in this version.
            case moved
        }
        let outcome: Outcome
        /// The item's title as read at its path, when it was found again that way.
        let foundTitle: String?
    }

    // MARK: The bar

    /// The bar's menus but the Apple menu: [AXTitle, AXEnabled] of each, at most `maxMenus`.
    func topLevel(pid: pid_t) -> Result<(titles: [Read], ms: Double), Failure> {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let started = CFAbsoluteTimeGetCurrent()
        let bar: AXUIElement
        switch menuBar(pid: pid) {
        case .success(let b): bar = b
        case .failure(let f): return .failure(f)
        }
        let children: [AXUIElement]
        switch self.children(of: bar, pid: pid) {
        case .success(let c): children = c
        case .failure(let f): return .failure(f)
        }
        var reads: [Read] = []
        for (i, child) in children.enumerated() where i >= 1 && i <= Self.maxMenus {
            switch values(of: child, [kAXTitleAttribute, kAXEnabledAttribute], pid: pid) {
            case .success(let v):
                reads.append(Read(item: RawMenuItem(title: v[0] as? String, enabled: v[1] as? Bool), index: i, element: child))
            case .failure(let f):
                return .failure(f)
            }
        }
        return .success((reads, ms(since: started)))
    }

    // MARK: One menu

    private static let itemAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute,
                                         "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers",
                                         "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph", kAXChildrenAttribute]

    /// The items of the menu at `path`, only while the item that opens it has the title the device
    /// showed (`shown`): an app can add or remove items above a submenu in place, and an id is a
    /// place. `parent` is that item as kept from an earlier read (its bar item, from the last
    /// top-level read, for one of the bar's menus), else, or when that one no longer answers, the path
    /// is walked from the bar, each menu on the way checked against `ancestors` (the titles read there
    /// in this version; nil: none known, and no walk). The item's title and children come in one call,
    /// so a menu that is not the one shown is never opened (read) and validated. Then one
    /// `AXUIElementCopyMultipleAttributeValues` per item, no action names (every AXMenuItem has
    /// AXPress), and one more AXRole read of a titled item's first child. At most `maxItems`, and no
    /// more once `readBudget` has passed since the call began, or once an item as slow as the slowest
    /// so far would end past `until` (CFAbsoluteTime: when its answer must go out, `RequestDeadline`);
    /// nothing at all past `until`.
    func items(pid: pid_t, of parent: AXUIElement?, path: MenuPath, shown: String, ancestors: [String]?,
               until: Double = .infinity) -> Result<Menu, Failure> {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let started = CFAbsoluteTimeGetCurrent()
        guard started < until else { return .failure(.late) }
        var opener: ItemNow? = nil
        if let parent {
            switch itemNow(parent, pid: pid) {
            case .success(let n): opener = n
            case .failure(.failed): opener = nil          // no longer answering as it was (rebuilt): walk the path
            case .failure(let f): return .failure(f)
            }
        }
        if opener == nil {
            guard let ancestors else { return .failure(.moved) }   // nothing read on the way in this version
            switch walk(pid: pid, to: path, ancestors: ancestors) {
            case .success(let e):
                switch itemNow(e, pid: pid) {
                case .success(let n): opener = n
                case .failure(let f): return .failure(f)
                }
            case .failure(let f): return .failure(f)
            }
        }
        guard let opener, ShownTitle.matches(now: opener.title, shown: shown) else {
            return .failure(.notShown(found: opener?.title ?? ""))
        }
        let kids: [AXUIElement]
        switch menuItems(among: opener.children, pid: pid) {
        case .success(let k): kids = k
        case .failure(.failed): return .failure(.moved)       // the item shown there opens no menu now
        case .failure(let f): return .failure(f)
        }
        var reads: [Read] = []
        var examined = 0
        // The slowest item so far: the read stops before one as slow would end past `until`.
        var slowest = 0.0
        for (i, item) in kids.prefix(Self.maxItems).enumerated() {
            let itemStarted = CFAbsoluteTimeGetCurrent()
            switch read(item, index: i, pid: pid) {
            case .failure(let f): return .failure(f)
            case .success(let r): if let r { reads.append(r) }       // nil: not an AXMenuItem (its index still counts)
            }
            examined = i + 1
            let now = CFAbsoluteTimeGetCurrent()
            slowest = max(slowest, now - itemStarted)
            if now - started >= Self.readBudget || now + slowest >= until { break }
        }
        return .success(Menu(reads: reads, total: kids.count, unread: kids.count - examined, ms: ms(since: started)))
    }

    /// One child of a menu, or nil when it is not an AXMenuItem (a menu lists only items).
    private func read(_ item: AXUIElement, index i: Int, pid: pid_t) -> Result<Read?, Failure> {
        let v: [CFTypeRef?]
        switch values(of: item, Self.itemAttributes, pid: pid) {
        case .success(let got): v = got
        case .failure(let f): return .failure(f)
        }
        guard (v[0] as? String) == kAXMenuItemRole else { return .success(nil) }
        let children = (v[9] as? [AXUIElement]) ?? []
        var raw = RawMenuItem(title: v[1] as? String, description: v[2] as? String, enabled: v[3] as? Bool,
                              mark: v[4] as? String, char: v[5] as? String, modifiers: (v[6] as? NSNumber)?.intValue,
                              virtualKey: (v[7] as? NSNumber)?.intValue, glyph: (v[8] as? NSNumber)?.intValue,
                              childCount: children.count)
        if let first = children.first, !MenuFormat.displayTitle(title: raw.title, description: raw.description).isEmpty {
            AXUIElementSetMessagingTimeout(first, Self.timeout)
            switch value(of: first, kAXRoleAttribute, pid: pid) {
            case .success(let role): raw.firstChildRole = role as? String
            case .failure(let f): return .failure(f)
            }
        }
        return .success(Read(item: raw, index: i, element: item))
    }

    // MARK: Pressing

    /// AXPress on the kept element, or, when it no longer answers (the app gave the menu a new
    /// NSMenu), on the item at `path`, found again with each menu on the way checked against
    /// `ancestors` (the titles read there in this version; nil: none known, and no walk); either only
    /// when its title now is `shownTitle`, it has no children and it is enabled (`PressDecision`).
    /// AppKit's item elements are positional: after an app replaced the items inside the same NSMenu,
    /// a kept element answers for whatever item is at its place now, and the title decides. An id of
    /// one part is one of the bar's menus: never pressed (the mirror refuses it first). An AppKit app
    /// answers AXPress before it runs the action (the fixture: 2–3 ms); one that answers only after
    /// holds this queue until the timeout, which counts as pressed.
    func press(pid: pid_t, element: AXUIElement?, path: MenuPath, shownTitle: String?, ancestors: [String]?) -> Pressed {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted() else { return Pressed(outcome: .refused(.notTrusted), foundTitle: nil) }
        guard path.indexes.count >= 2 else { return Pressed(outcome: .refused(.changed), foundTitle: nil) }
        var target: AXUIElement? = nil
        var elementValid = false
        var now: ItemNow? = nil
        var found: String? = nil
        if let element {
            switch itemNow(element, pid: pid) {
            case .success(let n): target = element; elementValid = true; now = n
            case .failure(.failed): break                           // no longer answering (rebuilt): found again below
            case .failure(let f): return Pressed(outcome: .refused(Self.refusal(f)), foundTitle: nil)
            }
        }
        if !elementValid {
            guard let ancestors else { return Pressed(outcome: .refused(.changed), foundTitle: nil) }
            switch walk(pid: pid, to: path, ancestors: ancestors) {
            case .success(let e):
                switch itemNow(e, pid: pid) {
                case .success(let n): target = e; now = n; found = n.title
                case .failure(.failed): break
                case .failure(let f): return Pressed(outcome: .refused(Self.refusal(f)), foundTitle: nil)
                }
            case .failure(.moved): return Pressed(outcome: .moved, foundTitle: nil)
            case .failure(.failed): break                           // nothing at that path now
            case .failure(let f): return Pressed(outcome: .refused(Self.refusal(f)), foundTitle: nil)
            }
        }
        switch PressDecision.decide(elementValid: elementValid, current: now?.title, shown: shownTitle, enabled: now?.enabled,
                                    hasChildren: !(now?.children.isEmpty ?? true)) {
        case .refuse(let why):
            return Pressed(outcome: .refused(why), foundTitle: found)
        case .press, .pressFound:
            guard let target else { return Pressed(outcome: .refused(.changed), foundTitle: found) }
            let started = CFAbsoluteTimeGetCurrent()
            let e = AXUIElementPerformAction(target, kAXPressAction as CFString)
            if e == .success { return Pressed(outcome: .pressed, foundTitle: found) }
            if e == .cannotComplete, CFAbsoluteTimeGetCurrent() - started >= Double(Self.timeout) * 0.9 {
                return Pressed(outcome: .pressedNoAnswer, foundTitle: found)
            }
            return Pressed(outcome: .refused(Self.refusal(failure(e, started: started, pid: pid))), foundTitle: found)
        }
    }

    /// An item as it is now: its title as a device is shown it, its enabled flag, and its children
    /// (a submenu's AXMenu, or a custom view's).
    private struct ItemNow {
        let title: String
        let enabled: Bool?
        let children: [AXUIElement]
    }

    /// [AXTitle, AXDescription, AXEnabled, AXChildren] of one item, in one call. Fresh within a
    /// second: the read validates the item's menu.
    private func itemNow(_ element: AXUIElement, pid: pid_t) -> Result<ItemNow, Failure> {
        switch values(of: element, [kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute, kAXChildrenAttribute], pid: pid) {
        case .success(let v):
            return .success(ItemNow(title: MenuFormat.displayTitle(title: v[0] as? String, description: v[1] as? String),
                                    enabled: v[2] as? Bool, children: (v[3] as? [AXUIElement]) ?? []))
        case .failure(let f):
            return .failure(f)
        }
    }

    static func refusal(_ f: Failure) -> MenuRefusal {
        switch f {
        case .notTrusted: .notTrusted
        case .noMenuBar, .notShown, .moved: .changed
        case .late: .tooMany
        case .gone: .gone
        case .notAnswering: .notAnswering
        case .failed(let name): .failed(name)
        }
    }

    // MARK: Accessibility, typed

    private func menuBar(pid: pid_t) -> Result<AXUIElement, Failure> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        let started = CFAbsoluteTimeGetCurrent()
        var value: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value)
        if e == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let bar = value as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, Self.timeout)
            return .success(bar)
        }
        if e == .success || e == .noValue || e == .attributeUnsupported {
            return .failure(Self.alive(pid) ? .noMenuBar : .gone)
        }
        return .failure(failure(e, started: started, pid: pid))
    }

    /// The menu among an item's children (the first AXMenu), and that menu's children. Reading them
    /// makes the app validate the menu. `.failed` when the item has no menu.
    private func menuItems(among children: [AXUIElement], pid: pid_t) -> Result<[AXUIElement], Failure> {
        for kid in children {
            AXUIElementSetMessagingTimeout(kid, Self.timeout)
            switch value(of: kid, kAXRoleAttribute, pid: pid) {
            case .success(let role) where (role as? String) == kAXMenuRole:
                return self.children(of: kid, pid: pid)
            case .success: continue
            case .failure(let f): return .failure(f)
            }
        }
        return .failure(.failed("no menu"))
    }

    /// The element at `path`, from the bar: the bar's child at the first index, then each next index
    /// among the items of the one before's menu. Each menu on the way (every part but the last) must
    /// have the title `ancestors` gives for it, and a menu, or the walk stops with `.moved`: the tree
    /// is not the one the device was shown, whatever the item at the end is called.
    private func walk(pid: pid_t, to path: MenuPath, ancestors: [String]) -> Result<AXUIElement, Failure> {
        guard ancestors.count == path.indexes.count - 1 else { return .failure(.moved) }
        let bar: AXUIElement
        switch menuBar(pid: pid) {
        case .success(let b): bar = b
        case .failure(let f): return .failure(f)
        }
        var level: [AXUIElement]
        switch children(of: bar, pid: pid) {
        case .success(let c): level = c
        case .failure(let f): return .failure(f)
        }
        var element: AXUIElement? = nil
        for (depth, index) in path.indexes.enumerated() {
            if depth > 0, let menu = element {
                switch itemNow(menu, pid: pid) {
                case .success(let n):
                    guard ShownTitle.matches(now: n.title, shown: ancestors[depth - 1]) else { return .failure(.moved) }
                    switch menuItems(among: n.children, pid: pid) {
                    case .success(let k): level = k
                    case .failure(.failed): return .failure(.moved)
                    case .failure(let f): return .failure(f)
                    }
                case .failure(let f): return .failure(f)
                }
            }
            guard index < level.count else {
                return .failure(depth < path.indexes.count - 1 ? .moved : .failed("no item at \(path.id)"))
            }
            element = level[index]
            AXUIElementSetMessagingTimeout(level[index], Self.timeout)
        }
        guard let element else { return .failure(.failed("no item at \(path.id)")) }
        return .success(element)
    }

    private func children(of element: AXUIElement, pid: pid_t) -> Result<[AXUIElement], Failure> {
        switch value(of: element, kAXChildrenAttribute, pid: pid) {
        case .success(let v): return .success((v as? [AXUIElement]) ?? [])
        case .failure(let f): return .failure(f)
        }
    }

    /// One attribute; nil for a missing one (NoValue, unsupported).
    private func value(of element: AXUIElement, _ attribute: String, pid: pid_t) -> Result<CFTypeRef?, Failure> {
        let started = CFAbsoluteTimeGetCurrent()
        var value: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch e {
        case .success: return .success(value)
        case .noValue, .attributeUnsupported: return .success(nil)
        default: return .failure(failure(e, started: started, pid: pid))
        }
    }

    /// Several attributes in one call; a missing one (an AXValue holding an AX error, or CFNull) is nil.
    private func values(of element: AXUIElement, _ attributes: [String], pid: pid_t) -> Result<[CFTypeRef?], Failure> {
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        let started = CFAbsoluteTimeGetCurrent()
        var array: CFArray?
        let e = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &array)
        guard e == .success, let list = array as [AnyObject]? else { return .failure(failure(e, started: started, pid: pid)) }
        var out: [CFTypeRef?] = []
        for i in 0..<attributes.count {
            guard i < list.count else { out.append(nil); continue }
            let v = list[i] as CFTypeRef
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError {
                var error = AXError.success
                _ = AXValueGetValue(v as! AXValue, .axError, &error)
                // A timed-out app answers the whole call with .cannotComplete; an error inside the
                // array is one attribute's: missing (NoValue), or an element gone meanwhile.
                if error == .invalidUIElement { return .failure(failure(error, started: started, pid: pid)) }
                out.append(nil)
            } else if CFGetTypeID(v) == CFNullGetTypeID() {
                out.append(nil)
            } else {
                out.append(v)
            }
        }
        return .success(out)
    }

    /// An AX error as a Failure. A timeout is `.cannotComplete` after at least 0.9 × `timeout`; a quick
    /// one, or an invalid element, from a process that has exited is `.gone`.
    private func failure(_ e: AXError, started: CFAbsoluteTime, pid: pid_t) -> Failure {
        switch e {
        case .apiDisabled: return .notTrusted
        case .cannotComplete where CFAbsoluteTimeGetCurrent() - started >= Double(Self.timeout) * 0.9: return .notAnswering
        default: return Self.alive(pid) ? .failed(WindowSizer.axErrorName(e)) : .gone
        }
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func ms(since started: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - started) * 1000 }
}
