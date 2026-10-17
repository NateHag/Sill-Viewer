import Foundation
import Network
import ApplicationServices
import StreamProtocol

/// The streamed app's menus, for the devices that asked for them (docs/menu-bar-plan.md §4.4).
///
/// Main actor: the target, the version, the top level, the kept elements and the cache are its
/// state. Every Accessibility call is the reader's, on `sill.menus`; none is made here. Answers go
/// out through the server (thread-safe). Nothing is read, sent or printed until a device asks: with
/// no subscriber a target change costs the coordinator one comparison, so an older device, and a
/// test client that never sends kind 27, are served exactly as before.
///
/// Requests are served one at a time, in arrival order (`enqueue`): a fetch's activation and read,
/// a press, a subscription's read. So a device's answers follow its requests, and no two reads of
/// one app overlap. Target and version change at once (`setTarget`); every step that waited checks
/// them again, and a read that comes back for another version is dropped. A fetch whose turn comes
/// after its device has stopped waiting (`RequestDeadline`) is not read, a choice that late is
/// refused, and only a subscriber is served: a request from any other connection is answered at
/// once, and one whose connection left before its turn is dropped (a choice still runs: a move's
/// new connection counts on the Mac acting on what the old one carried).
///
/// Within one version an id names one item for every device (§3.3). A fetch and a choice carry the
/// title the device showed, and nothing is read or pressed where that title is not the item's now.
/// The submenus read in a version are recorded with their titles (`SubmenuRecord`): a read that
/// finds another one at a recorded place, or a walk from the bar that meets one, means the app
/// changed its menus in place, and the version moves (`treeChanged`), so no device's older ids are
/// served against the new tree.
@MainActor
final class MenuMirror {
    struct Target: Equatable {
        let pid: pid_t
        let app: String
        let bundleID: String?
        /// The streamed window, for a window source: another window of the same app keeps the
        /// version (the same menus) but not the cache (its key window, so its states, changed).
        var window: UInt32? = nil
    }

    private let server: StreamServer
    private let reader: MenuReader
    /// Before a read or a press of a window source: its app active and the window key (the
    /// coordinator's `focusForMenus`). True when the app is frontmost as it returns; true at once
    /// for the Desktop and for nothing.
    var prepare: () async -> Bool = { true }
    /// The app behind the current source, asked when the first device subscribes (the coordinator
    /// tells the mirror of changes only while someone subscribes).
    var currentTarget: () -> Target? = { nil }
    /// The first device subscribed (true) or the last one left (false).
    var onSubscribersChanged: ((Bool) -> Void)?

    private(set) var target: Target?
    /// One for all devices, from 1 each launch: +1 whenever the target changes, or a re-read finds
    /// the top level changed. Ids are good within one version only.
    private(set) var version = 1
    /// The top level as sent, and whether it has been read for this version.
    private var top: [MacMenuItem] = []
    private var topRead = false
    private var topLevel: TopLevel?
    /// The app did not answer a read within the timeout: presses are refused and fetches answered
    /// with `note`, until a read (each catalog poll) succeeds again.
    private var stale = false
    private var note: String?
    /// The top level was refused for Accessibility: read again at each catalog poll, so a grant
    /// shows the menus without a pick.
    private var untrusted = false
    /// The element of every item read in this version, for presses and for reading its submenu,
    /// with its title (the host's own, for the log). This version only; at most `maxKept`.
    private struct Kept { let element: AXUIElement; let title: String }
    private var elements: [MenuPath: Kept] = [:]
    private static let maxKept = 5_000
    private var cache = MenuCache()
    /// The submenus read in this version, with their titles: the check of a read, and what a walk
    /// from the bar must meet on its way.
    private var submenus = SubmenuRecord()
    /// When the top level was last read, and each bar menu's element by its index: a fetch within a
    /// second of that read opens its menu without reading the top level again (a sweep across the
    /// iPad's bar costs one top-level read).
    private var topReadAt = -Double.infinity
    private var topElements: [Int: AXUIElement] = [:]
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]
    private var rates: [ObjectIdentifier: RequestRate] = [:]
    /// Each subscriber's worst round trip of a recent second (its client stats), in ms: how long its
    /// device waits for an answer (`RequestDeadline`).
    private var roundTrips: [ObjectIdentifier: Int] = [:]
    /// The last top level broadcast to the subscribers (never an answer): sent again only changed.
    private var lastSent: MacMenu?
    private var chain: Task<Void, Never>?
    /// Requests queued or being served: while others wait behind a fetch, it opens its menu without
    /// reading the top level again (the titles it checks keep that safe).
    private var queued = 0
    private var retryQueued = false

    var hasSubscribers: Bool { !subscribers.isEmpty }

    init(server: StreamServer, reader: MenuReader = MenuReader()) {
        self.server = server
        self.reader = reader
    }

    // MARK: From the coordinator

    /// The app behind the current source, when it may have changed: a pick, the Desktop's frontmost
    /// app. Equal to the current one: nothing. Otherwise the version moves and, with subscribers,
    /// the new top level goes to each of them once read (never an empty one in between: a device's
    /// Menus button would flicker), or at once with no menus for no target.
    func setTarget(_ t: Target?) {
        guard t != target else { return }
        let sameApp = adopt(t)
        guard hasSubscribers else { return }
        // The same app, or none: nothing to read (a name shown differently is sent, deduplicated).
        if sameApp || t == nil { publishTop(); return }
        let v = version
        enqueue {
            guard await self.readTop(version: v) else { return }
            self.publishTop()
        }
    }

    /// Makes `t` the target. The same app (another of its windows, or the Desktop with it in front)
    /// keeps the version, its menus and ids, but not the cache: its states were computed for
    /// another key window. Any other change moves the version. True for the same app.
    private func adopt(_ t: Target?) -> Bool {
        if let t, let old = target, t.pid == old.pid {
            target = t
            cache.clear()
            return true
        }
        target = t
        newVersion()
        return false
    }

    /// Kind 27. Without an id: the subscription, answered with the top level. With one: that menu's
    /// items, from a read of less than a second ago made while the app was frontmost, or read now.
    /// At most 20 a second per connection; the rest get "Too many requests…" at once, and so does
    /// nothing else: a connection that never subscribed gets "The menus changed…" at once, unread.
    func fetch(_ r: FetchMenu, from c: NWConnection, who: String) {
        let id = ObjectIdentifier(c)
        let now = CFAbsoluteTimeGetCurrent()
        var rate = rates[id] ?? RequestRate()
        let allowed = rate.allowFetch(now: now)
        if !allowed, rate.ignoredLineDue(now: now) {
            print("Menus from \(who) ignored: more than \(RequestRate.fetchesPerSecond) requests a second.")
        }
        rates[id] = rate
        let menu = r.id.flatMap(MenuPath.init)?.id
        guard allowed else {
            Stats.shared.bump("menu.refused")
            send(MacMenu(version: version, answering: r.token, menu: menu, items: [], note: MenuRefusal.tooManyNote), to: c)
            return
        }
        guard let menuID = r.id else { subscribe(c, token: r.token); return }
        // Only a device that asked for the top level is served a menu: any other was never sent one,
        // and its target may be one nobody watches any more.
        guard subscribers[id] != nil else {
            Stats.shared.bump("menu.refused")
            send(MacMenu(version: version, answering: r.token, menu: menu, items: [], note: MenuRefusal.changedNote), to: c)
            return
        }
        enqueue { await self.serveFetch(r, id: menuID, to: c, arrived: now) }
    }

    /// Kind 25: choose one item, at most 4 a second per connection, and only from a subscriber.
    /// Logged whatever the outcome.
    func press(_ r: PressMenuItem, from c: NWConnection, who: String) {
        let id = ObjectIdentifier(c)
        let now = CFAbsoluteTimeGetCurrent()
        var rate = rates[id] ?? RequestRate()
        let allowed = rate.allowPress(now: now)
        if !allowed, rate.ignoredLineDue(now: now) {
            print("Menus from \(who) ignored: more than \(RequestRate.pressesPerSecond) choices a second.")
        }
        rates[id] = rate
        guard allowed else {
            Stats.shared.bump("menu.refused")
            send(MacMenu(version: version, answering: r.token, pressed: false, note: MenuRefusal.tooManyNote), to: c)
            return
        }
        guard subscribers[id] != nil else {
            Stats.shared.bump("menu.refused")
            print("Menu from \(who) refused: \(r.id.flatMap(MenuPath.init)?.id ?? SafeText.label(r.id ?? "no id", limit: 32)): \(MenuRefusal.changed.logReason(app: ""))")
            send(MacMenu(version: version, answering: r.token, pressed: false, note: MenuRefusal.changedNote), to: c)
            return
        }
        enqueue { await self.servePress(r, to: c, who: who, arrived: now) }
    }

    /// A connection's client stats, about once a second: its worst round trip of that second (a
    /// negative one: none measured, and the last one measured stands).
    func clientStats(_ c: NWConnection, rttMs: Int) {
        let id = ObjectIdentifier(c)
        guard subscribers[id] != nil, rttMs >= 0 else { return }
        roundTrips[id] = rttMs
    }

    /// A connection closed.
    func clientLeft(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        rates[id] = nil
        roundTrips[id] = nil
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty {
            // Nobody to answer: let go of the app's elements and of what was read; the next subscriber
            // reads afresh, in a new version, since nothing recorded any more what the ids of this one
            // named (a device's rows from before, after a move whose old connection went first, are
            // then refused rather than served against a tree read since).
            version += 1
            elements = [:]
            topElements = [:]
            topReadAt = -.infinity
            submenus.clear()
            cache.clear()
            onSubscribersChanged?(false)
        }
    }

    /// Each catalog poll (every 2 s while a device is connected and someone subscribes), one read
    /// at a time: the top level is read again while the app is shown as not answering (a read that
    /// succeeds clears that and sends the top level), while this version's top level is unread (its
    /// read failed with a passing error, and nothing was sent for it), and while it was refused for
    /// Accessibility (a grant then shows the menus within a poll, without a pick).
    func catalogPolled() {
        guard hasSubscribers, target != nil, !retryQueued, needsRetry else { return }
        retryQueued = true
        let v = version
        enqueue {
            self.retryQueued = false
            guard v == self.version, self.needsRetry, await self.readTop(version: v) else { return }
            self.publishTop()
        }
    }

    private var needsRetry: Bool { stale || !topRead || untrusted }

    // MARK: Serving, one request at a time

    private func subscribe(_ c: NWConnection, token: Int?) {
        let id = ObjectIdentifier(c)
        let first = subscribers.isEmpty
        subscribers[id] = c
        if first {
            onSubscribersChanged?(true)
            // Until now the coordinator told the mirror nothing: take the current app, as setTarget
            // would (a different one moves the version).
            let t = currentTarget()
            if t != target { _ = adopt(t) }
        }
        enqueue {
            guard self.subscribers[id] != nil else { return }
            // Read even when this version's top level is known: nobody may have watched it change.
            if self.target != nil { _ = await self.readTop(version: self.version) }
            guard self.subscribers[id] != nil else { return }
            self.send(self.topMessage(answering: token), to: c)
            self.publishTop(except: id)
        }
    }

    private func serveFetch(_ r: FetchMenu, id menuID: String, to c: NWConnection, arrived: Double) async {
        let cid = ObjectIdentifier(c)
        // The device left before this fetch's turn: nobody to answer, so nothing is activated or read.
        guard subscribers[cid] != nil else { return }
        let path = MenuPath(menuID)
        func answer(_ m: MacMenu) { send(m, to: c) }
        func refuse(_ note: String) {
            Stats.shared.bump("menu.refused")
            answer(MacMenu(version: version, answering: r.token, menu: path?.id, items: [], note: note))
        }
        // What the device showed for the menu: the item at the id must still have it (an id is a place).
        let shown = r.title ?? ""
        guard r.version == version, let path, let t = target, !shown.isEmpty else { refuse(MenuRefusal.changedNote); return }
        if stale {
            answer(MacMenu(version: version, answering: r.token, menu: path.id, items: [], stale: true, note: note))
            return
        }
        func cached(_ e: MenuCache.Entry) {
            Stats.shared.bump("menu.cached")
            answer(MacMenu(version: version, answering: r.token, menu: path.id, items: e.items, more: e.more > 0 ? e.more : nil))
        }
        // A read an active app's states came from answers any fetch, with no activation.
        if let e = cache.fresh(path.id, title: shown, now: CFAbsoluteTimeGetCurrent(), frontmostNow: true) { cached(e); return }
        // Its device has stopped waiting (it waited behind other requests): nothing is activated or read.
        if RequestDeadline.expired(waited: CFAbsoluteTimeGetCurrent() - arrived, rttMs: roundTrips[cid]) {
            refuse(MenuRefusal.tooManyNote)
            return
        }
        let v = version
        let frontmost = await prepare()
        guard v == version, target?.pid == t.pid else { refuse(MenuRefusal.changedNote); return }
        // Still not frontmost: a read now would return the last validation, an inactive app's too.
        if !frontmost, let e = cache.fresh(path.id, title: shown, now: CFAbsoluteTimeGetCurrent(), frontmostNow: false) { cached(e); return }
        // Brought forward after a read made while it was not: AppKit validates the menu again only
        // once its second is over.
        let wait = frontmost ? cache.wait(path.id, now: CFAbsoluteTimeGetCurrent()) : 0
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard v == version, target?.pid == t.pid else { refuse(MenuRefusal.changedNote); return }
        }
        // The activation and the wait can take a second and a half: the same checks again, now.
        guard subscribers[cid] != nil else { return }
        if RequestDeadline.expired(waited: CFAbsoluteTimeGetCurrent() - arrived, rttMs: roundTrips[cid]) {
            refuse(MenuRefusal.tooManyNote)
            return
        }
        // The top level again, then the menu, in one hop: a top level that changed meanwhile moves
        // the version, and this answer then says so (the menu is not read). Within a second of the
        // last read of the top level, with other requests waiting, or with no time for a top-level
        // read and a whole menu before the answer must go out, only the menu: a sweep across the
        // bar reads the top level once, and the titles checked keep a menu read without it right.
        let reader = self.reader
        let onePart = path.indexes.count == 1
        let until = arrived + RequestDeadline.answerBy(rttMs: roundTrips[cid])
        let now = CFAbsoluteTimeGetCurrent()
        let readTopNow = !topRead || (onePart && topElements[path.indexes[0]] == nil)
            || (now - topReadAt >= MenuCache.lifetime && queued <= 1
                && until - now > Double(MenuReader.timeout) + MenuReader.readBudget)
        let expected: TopLevel? = topRead ? topLevel : nil      // nothing to compare with before a first read
        let parent = onePart ? topElements[path.indexes[0]] : elements[path]?.element
        let ancestors = ancestorTitles(path)
        typealias TopRead = Result<(titles: [MenuReader.Read], ms: Double), MenuReader.Failure>
        let (topResult, menuResult) = await onMenus { () -> (TopRead?, Result<MenuReader.Menu, MenuReader.Failure>?) in
            var opener = parent
            var top: TopRead? = nil
            if readTopNow {
                let read = reader.topLevel(pid: t.pid)
                top = read
                guard case .success(let got) = read else { return (read, nil) }
                if let expected, Self.level(of: got.titles) != expected { return (read, nil) }
                if onePart { opener = got.titles.first { $0.index == path.indexes[0] }?.element }
            }
            return (top, reader.items(pid: t.pid, of: opener, path: path, shown: shown, ancestors: ancestors, until: until))
        }
        guard v == version, target?.pid == t.pid else { refuse(MenuRefusal.changedNote); return }
        if let topResult { applyTop(topResult, target: t) }
        // What that read found goes to the subscribers first: a changed top level (a new version), the
        // app gone or not answering, or a top level read here for the first time in this version (its
        // first read failed; the polls stop retrying once it is read). An unchanged one sends nothing.
        publishTop()
        guard v == version, target?.pid == t.pid else {
            refuse(target == nil ? MenuRefusal.goneNote(label(t.app)) : MenuRefusal.changedNote)
            return
        }
        if stale {
            answer(MacMenu(version: version, answering: r.token, menu: path.id, items: [], stale: true, note: note))
            return
        }
        guard let menuResult else {
            if case .failure(.notTrusted)? = topResult { refuse(MenuRefusal.noAccessNote) } else { refuse(MenuRefusal.changedNote) }
            return
        }
        switch menuResult {
        case .success(let menu):
            Stats.shared.bump("menu.read")
            var items: [MacMenuItem] = []
            var found: [(index: Int, title: String, submenu: Bool)] = []
            for read in menu.reads {
                guard let childPath = path.child(read.index), let item = MenuFormat.item(read.item, id: childPath.id) else { continue }
                items.append(item)
                guard item.separator != true, let title = item.title else { continue }
                found.append((read.index, title, item.submenu == true))
                if elements.count < Self.maxKept || elements[childPath] != nil {
                    elements[childPath] = Kept(element: read.element, title: title)
                }
            }
            // A submenu read before in this version at a place this read covers, and not there now:
            // the app changed this menu in place, and the ids every device holds below it may name
            // other items now.
            guard submenus.read(menu: path.id, found: found, examined: menu.total - menu.unread) else {
                treeChanged()
                refuse(MenuRefusal.changedNote)
                return
            }
            let more = menu.unread
            cache.store(path.id, MenuCache.Entry(title: shown, items: items, more: more, at: CFAbsoluteTimeGetCurrent(),
                                                 appWasFrontmost: frontmost))
            answer(MacMenu(version: version, answering: r.token, menu: path.id, items: items, more: more > 0 ? more : nil))
        case .failure(.notShown(let found)):
            // Not the menu the device opened. One of the bar's (read less than a second ago): the top
            // level is read again now, which moves the version if it changed. A submenu read under
            // another title in this version: the tree changed.
            if onePart {
                if await readTop(version: v) { publishTop() }
            } else if let recorded = submenus.title(of: path.id), recorded != found {
                treeChanged()
            }
            refuse(MenuRefusal.changedNote)
        case .failure(.moved):
            treeChanged()
            refuse(MenuRefusal.changedNote)
        case .failure(.late):
            // Its time ran out on the way (the top level read first took it): nothing was read.
            refuse(MenuRefusal.tooManyNote)
        case .failure(.notAnswering):
            Stats.shared.bump("menu.axTimeout")
            becomeStale(t)
            publishTop()
            answer(MacMenu(version: version, answering: r.token, menu: path.id, items: [], stale: true, note: note))
        case .failure(.gone):
            targetGone()
            publishTop()
            refuse(MenuRefusal.goneNote(label(t.app)))
        case .failure(.notTrusted):
            refuse(MenuRefusal.noAccessNote)
        case .failure(.noMenuBar), .failure(.failed):
            refuse(MenuRefusal.changedNote)
        }
    }

    private func servePress(_ r: PressMenuItem, to c: NWConnection, who: String, arrived: Double) async {
        let cid = ObjectIdentifier(c)
        let path = r.id.flatMap(MenuPath.init)
        let app = label(target?.app ?? "")
        // The host's own titles; the device's are never logged. An id from another version, or one
        // that names nothing, is given as it came (cleaned).
        let shownID = path?.id ?? SafeText.label(r.id ?? "no id", limit: 32)
        func refuse(_ why: MenuRefusal, what: String) {
            Stats.shared.bump("menu.refused")
            print("Menu from \(who) refused: \(what): \(why.logReason(app: app))")
            send(MacMenu(version: version, answering: r.token, pressed: false, note: why.note(app: app)), to: c)
        }
        guard r.version == version, let path, let t = target else { refuse(.changed, what: shownID); return }
        // One of the bar's menus: AXPress there would open it on the Mac, which then sits in menu
        // tracking. A device never sends one; refused before anything is activated or read.
        guard path.indexes.count >= 2 else { refuse(.changed, what: logPath(path, app: t.app)); return }
        if stale { refuse(.notAnswering, what: logPath(path, app: t.app)); return }
        // A device never gives up on a choice: one whose turn came this late is refused, not made
        // seconds after it was chosen.
        let waited = CFAbsoluteTimeGetCurrent() - arrived
        if RequestDeadline.expired(waited: waited, rttMs: roundTrips[cid]) { refuse(.late(waited), what: logPath(path, app: t.app)); return }
        let v = version
        _ = await prepare()
        guard v == version, target?.pid == t.pid else { refuse(.changed, what: shownID); return }
        let reader = self.reader
        let kept = elements[path]?.element
        let shown = r.title
        let ancestors = ancestorTitles(path)
        let result = await onMenus { reader.press(pid: t.pid, element: kept, path: path, shownTitle: shown, ancestors: ancestors) }
        // A press can change any state.
        cache.clear()
        let what = logPath(path, app: t.app, last: result.foundTitle)
        switch result.outcome {
        case .pressed:
            Stats.shared.bump("menu.press")
            print("Menu from \(who): \(what)")
            send(MacMenu(version: version, answering: r.token, pressed: true), to: c)
        case .pressedNoAnswer:
            Stats.shared.bump("menu.press")
            Stats.shared.bump("menu.axTimeout")
            print("Menu from \(who): \(what) (\(label(t.app)) did not answer within 1 s; a dialog may be open)")
            send(MacMenu(version: version, answering: r.token, pressed: true), to: c)
        case .moved:
            // Found again by its path, a menu on the way was not the one read there: the tree changed.
            refuse(.changed, what: what)
            if v == version, target?.pid == t.pid { treeChanged() }
        case .refused(let why):
            if why == .notAnswering { Stats.shared.bump("menu.axTimeout") }
            refuse(why, what: what)
            if why == .gone, target?.pid == t.pid { targetGone(); publishTop() }
            if why == .notAnswering, target?.pid == t.pid, !stale { becomeStale(t); publishTop() }
        }
    }

    /// The titles of the menus on the way to `path` (every part but the last), as read in this
    /// version: the top level's for the first, the submenus' record for the rest. A walk from the bar
    /// must meet each of them. Nil when one is not known: nothing read there in this version.
    private func ancestorTitles(_ path: MenuPath) -> [String]? {
        var titles: [String] = []
        for p in path.lineage.dropLast() {
            let title = p.indexes.count == 1 ? top.first { $0.id == p.id }?.title : submenus.title(of: p.id)
            guard let title else { return nil }
            titles.append(title)
        }
        return titles
    }

    // MARK: The top level

    /// Reads the target's bar for version `v` and applies it. False when the read was dropped (the
    /// version or the target moved meanwhile).
    private func readTop(version v: Int) async -> Bool {
        guard v == version, let t = target else { return false }
        let reader = self.reader
        let result = await onMenus { reader.topLevel(pid: t.pid) }
        guard v == version, target?.pid == t.pid else { return false }
        applyTop(result, target: t)
        return true
    }

    /// What a read of the bar found: the top level of this version, a changed top level (the
    /// version moves), the app not answering (stale), gone (no target), or no menus.
    private func applyTop(_ result: Result<(titles: [MenuReader.Read], ms: Double), MenuReader.Failure>, target t: Target) {
        switch result {
        case .success(let got):
            Stats.shared.bump("menu.top")
            if stale { print("Menus of \(label(t.app)) answering again.") }
            setTop(Self.level(of: got.titles), got.titles.compactMap { MenuFormat.topItem($0.item, index: $0.index) }, note: nil)
            topReadAt = CFAbsoluteTimeGetCurrent()
            topElements = Dictionary(got.titles.map { ($0.index, $0.element) }, uniquingKeysWith: { first, _ in first })
            untrusted = false
        case .failure(.notAnswering):
            Stats.shared.bump("menu.axTimeout")
            becomeStale(t)
        case .failure(.gone):
            targetGone()
        case .failure(.notTrusted):
            setTop(TopLevel(titles: [], enabled: []), [], note: MenuRefusal.noAccessNote)
            untrusted = true
        case .failure(.noMenuBar):
            setTop(TopLevel(titles: [], enabled: []), [], note: nil)
            untrusted = false
        case .failure(.failed), .failure(.notShown), .failure(.moved), .failure(.late):
            // A passing error: what was read stays. A top level never read stays unread, so nothing
            // is sent for it (never an empty one in between), and each catalog poll reads again.
            // (A top-level read never checks a title: those two come only from a menu's read.)
            break
        }
    }

    /// A top level as read: when this version already had one and it differs (titles, count,
    /// enabled flags, or menus where there were none), the version moves first.
    private func setTop(_ level: TopLevel, _ items: [MacMenuItem], note newNote: String?) {
        if topRead, level != topLevel { newVersion() }
        stale = false
        note = newNote
        topLevel = level
        topRead = true
        top = items
    }

    nonisolated private static func level(of reads: [MenuReader.Read]) -> TopLevel {
        TopLevel(titles: reads.map { MenuFormat.displayTitle(title: $0.item.title, description: nil) },
                 enabled: reads.map { $0.item.enabled != false })
    }

    private func becomeStale(_ t: Target) {
        guard !stale else { return }
        stale = true
        note = MenuRefusal.notRespondingNote(label(t.app))
        print("Menus of \(label(t.app)) not answering (\(String(format: "%.1f", Double(MenuReader.timeout))) s); shown as unavailable until it answers.")
    }

    private func targetGone() {
        target = nil
        newVersion()
    }

    /// A read found the tree changed under this version below the top level (`SubmenuRecord`): the
    /// version moves, what was read in the old one goes, and the same top level goes out again with
    /// the new version, so every device's older ids are refused and its open menus say so.
    private func treeChanged() {
        version += 1
        cache.clear()
        elements = [:]
        submenus.clear()
        publishTop()
    }

    private func newVersion() {
        version += 1
        cache.clear()
        elements = [:]
        submenus.clear()
        topElements = [:]
        topReadAt = -.infinity
        top = []
        topRead = false
        topLevel = nil
        stale = false
        note = nil
        untrusted = false
    }

    private func topMessage(answering: Int?) -> MacMenu {
        guard let t = target else { return MacMenu(version: version, menus: [], answering: answering) }
        return MacMenu(version: version, app: label(t.app), bundleID: t.bundleID, menus: top, answering: answering,
                       stale: stale ? true : nil, note: note)
    }

    /// The top level to every subscriber (but `except`), when it differs from the last one sent:
    /// no menus for no target, else only once this version's top level has been read or the app
    /// was found not answering. A top level whose read failed is never sent empty in its place.
    private func publishTop(except: ObjectIdentifier? = nil) {
        guard target == nil || topRead || stale else { return }
        let m = topMessage(answering: nil)
        guard m != lastSent else { return }
        lastSent = m
        for (id, c) in subscribers where id != except { send(m, to: c) }
    }

    // MARK: Helpers

    /// "menufixture › Probe › Set Label A" from the host's own titles, else the id. `last`: the title
    /// an item found again by its path had there, which stands for it.
    private func logPath(_ path: MenuPath, app: String, last: String? = nil) -> String {
        let lineage = path.lineage
        let titles: [String?] = lineage.enumerated().map { i, p in
            if i == lineage.count - 1, let last { return last }
            return p.indexes.count == 1 ? top.first { $0.id == p.id }?.title : elements[p]?.title
        }
        return MenuLog.path(app: app, titles: titles) ?? path.id
    }

    private func label(_ app: String) -> String { SafeText.label(app) }

    private func send(_ m: MacMenu, to c: NWConnection) {
        guard c.state == .ready else { return }   // it closed meanwhile: nothing to answer
        server.send(StreamMessage(kind: .macMenu, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                  payload: Wire.encode(m)), to: c)
    }

    /// One request after the other, in arrival order (see the class comment). A request's arrival
    /// time is taken by the caller: its wait for its turn is judged against its device's.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = chain
        queued += 1
        chain = Task { @MainActor in
            await previous?.value
            await op()
            self.queued -= 1
        }
    }

    /// `work` on `sill.menus`, the caller resuming on the main actor with its result.
    private func onMenus<T>(_ work: @escaping @Sendable () -> T) async -> T {
        let queue = reader.queue
        return await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: work()) }
        }
    }
}
