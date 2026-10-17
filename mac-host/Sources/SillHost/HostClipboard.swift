import AppKit
import Network
import StreamProtocol

/// The clipboard, the host's side (kind 32; docs/clipboard-plan.md). The rules are ClipboardPolicy's;
/// this reads and writes the pasteboard and keeps who subscribed.
///
/// - A device subscribes with any kind 32 (an empty one at connect, while its Share Clipboard is on)
///   and stops with `stop`; one line each ("Clipboard: iPad (iPad14,1) shares the clipboard."). A
///   device that leaves is forgotten without a line.
/// - While at least one subscribes, the pasteboard's change count is looked at four times a second.
///   The count as it stands when the first subscribes is taken as seen: what was on the clipboard then
///   is never sent, only what is copied while a device shares it. A change ClipboardPolicy.hostDecides
///   takes goes to every subscriber; one whose pasteboard has no items yet is looked at again for up
///   to a second first (`hostWaits`: an app clears, then writes). A password manager's copy
///   (`markerTypes`) and one from another device through Universal Clipboard are never read.
/// - A device's text becomes the pasteboard's, written for this Mac only (`.currentHostOnly`: Universal
///   Clipboard does not carry it to the person's other devices, the sender among them) with the
///   marker `ClipboardPolicy.ownType` naming this launch; it goes to every other subscriber at once,
///   and the look never sends it again.
/// - Off (`HostConfig.shareClipboard`, `setEnabled`): every subscription dropped, nothing looked at,
///   and a kind 32 ignored without a word or an answer. The coordinator's window lists say
///   `clipboard` only while it is on.
/// - macOS's paste privacy (`MacClipboard`, ClipboardPolicy.MacAccess; macOS 15.4 and later): the look
///   reads the pasteboard only while macOS allows every read Sill makes on its own; while it would ask
///   (its alert at every copy) or denies, the look reads nothing, not even the change count, and what
///   is copied meanwhile is never sent (`accessStep`). One line when that changes (`accessLine`). A
///   device's text is written whatever macOS says: writing needs no leave.
///
/// Never logs what was copied. Stats: `clip.sent` (messages sent), `clip.recv` (texts taken).
///
/// Threading: main actor for the subscribers and the lines; the pasteboard itself is read and written
/// on a queue of its own (`Board`), one call at a time, so a slow read (an app asked for text it only
/// promised, which can take a while) never holds up the main actor, where devices' input is handled.
/// The look is a Task.sleep loop, not a RunLoop timer, which the CLI's dispatchMain never runs.
@MainActor
final class HostClipboard {
    /// Share clipboard with devices.
    private(set) var enabled: Bool
    /// The window lists' `clipboard`: the generation while on, nil while off.
    var advertised: Int? { enabled ? ClipboardPolicy.generation : nil }

    private let server: StreamServer
    /// The pasteboard, on its own queue: `NSPasteboard.general`, or a synthetic host's own.
    private let board: Board
    /// A synthetic host's own pasteboard: its name, said at its first subscription. Nil for the Mac's.
    private let testBoardName: String?
    private var saidTestBoard = false
    /// TEST ONLY (SILL_TEST_CLIPBOARD_LOG=1, a synthetic host): each decision, with sizes, never text.
    private let testLog: Bool
    /// The test hooks' line for `start` (one, when a variable is set), nil without them.
    let testHookLine: String?

    /// The subscribers, by connection, and each one's name for the lines.
    private var subscribers: [ObjectIdentifier: (connection: NWConnection, who: String)] = [:]
    /// In the order they subscribed, for a stable order of sends.
    private var order: [ObjectIdentifier] = []
    private var look: Task<Void, Never>?
    /// Each connection's subscriptions and texts of the last second (ClipboardPolicy.hostReceives).
    private var arrivals: [ObjectIdentifier: [Double]] = [:]
    /// macOS's answer at the last look, for its line (ClipboardPolicy.accessLine); kept for the launch.
    private var reportedAccess: ClipboardPolicy.MacAccess?
    private lazy var ignored = RefusalSummary(queue: .main, categories: ["rate", "tooLong", "undecodable"]) { counts in
        ClipboardPolicy.Copy.ignoredLine(rate: counts["rate"] ?? 0, tooLong: counts["tooLong"] ?? 0,
                                         undecodable: counts["undecodable"] ?? 0)
    }

    /// `synthetic`: a host that never touches this Mac's clipboard (as it never reads the real
    /// pointer): a pasteboard of its own, `me.saffer.sill.test.<pid>`, or the one TEST ONLY
    /// `SILL_TEST_PASTEBOARD` names, so a test can write and read it. macOS asks about no pasteboard
    /// but the general one, so a synthetic host's reads are always allowed, unless TEST ONLY
    /// `SILL_TEST_CLIPBOARD_ACCESS` says otherwise: `allowed`, `notAsked`, `asks` or `denied`, or the
    /// path of a file holding one of them, read at each look (so a test can change it while it runs).
    init(server: StreamServer, enabled: Bool, launchID: String, synthetic: Bool,
         environment env: [String: String] = ProcessInfo.processInfo.environment) {
        self.server = server
        self.enabled = enabled
        var lines: [String] = []
        if synthetic {
            let named = env["SILL_TEST_PASTEBOARD"].flatMap { $0.isEmpty ? nil : $0 }
            let name = named ?? "me.saffer.sill.test.\(getpid())"
            var access: @Sendable () -> ClipboardPolicy.MacAccess = { .allowed }
            switch env["SILL_TEST_CLIPBOARD_ACCESS"] {
            case nil, "":
                break
            case let spec? where ClipboardPolicy.MacAccess(rawValue: spec) != nil:
                let fixed = ClipboardPolicy.MacAccess(rawValue: spec)!
                access = { fixed }
                lines.append("Test clipboard access: macOS's answer for this host's pasteboard is \(spec).")
            case let spec? where spec.hasPrefix("/"):
                access = {
                    let word = (try? String(contentsOfFile: spec, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return word.flatMap(ClipboardPolicy.MacAccess.init(rawValue:)) ?? .allowed
                }
                lines.append("Test clipboard access: macOS's answer for this host's pasteboard is read from \(spec) at each look.")
            case let spec?:
                lines.append("SILL_TEST_CLIPBOARD_ACCESS=\(spec) ignored: allowed, notAsked, asks, denied or a file's path.")
            }
            board = Board(name: name, launchID: launchID, access: access)
            testBoardName = name
        } else {
            board = Board(name: nil, launchID: launchID, access: { MacClipboard.access() })
            testBoardName = nil
            if let named = env["SILL_TEST_PASTEBOARD"], !named.isEmpty {
                lines.append("SILL_TEST_PASTEBOARD ignored: only a --synthetic host takes it.")
            }
            if let spec = env["SILL_TEST_CLIPBOARD_ACCESS"], !spec.isEmpty {
                lines.append("SILL_TEST_CLIPBOARD_ACCESS ignored: only a --synthetic host takes it.")
            }
        }
        switch (env["SILL_TEST_CLIPBOARD_LOG"], synthetic) {
        case (nil, _), ("", _):
            testLog = false
        case ("1", true):
            testLog = true
            lines.append("Test clipboard log: each change and each device's text is printed with its size, never its text.")
        case ("1", false):
            testLog = false
            lines.append("SILL_TEST_CLIPBOARD_LOG ignored: only a --synthetic host takes it.")
        case (let value?, _):
            testLog = false
            lines.append("SILL_TEST_CLIPBOARD_LOG=\(value) ignored: 1 turns it on.")
        }
        testHookLine = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: The setting

    /// Turns sharing on or off at once; true when it changed (the caller sends the lists again). Off
    /// drops every subscription without a line: the devices see the list without `clipboard`.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        guard on != enabled else { return false }
        enabled = on
        if !on {
            subscribers = [:]
            order = []
            arrivals = [:]
            stopLooking()
        }
        return true
    }

    // MARK: A device's message

    /// A kind 32 from `connection`, named `who` for the lines.
    func received(_ payload: Data, from connection: NWConnection, who: String) {
        guard enabled else { return }
        let id = ObjectIdentifier(connection)
        // What it asks first, then the rate, which a stop never meets (ClipboardPolicy.hostReceives).
        let got = ClipboardPolicy.hostReceives(payload, arrivals: arrivals[id] ?? [], now: ProcessInfo.processInfo.systemUptime)
        arrivals[id] = got.kept
        switch got.ask {
        case .subscribe:
            subscribe(connection, who: who)
        case .set(let text):
            subscribe(connection, who: who)
            board.write(text)
            Stats.shared.bump("clip.recv")
            let others = ClipboardPolicy.forward(to: order, from: id).compactMap { subscribers[$0]?.connection }
            if testLog { print("Test clipboard: \(text.utf8.count) bytes from \(who) set on the pasteboard, sent to \(others.count) other device\(others.count == 1 ? "" : "s").") }
            send(payload: ClipboardPolicy.payload(text: text), to: others)
        case .stop:
            guard let gone = subscribers.removeValue(forKey: id) else { return }
            order.removeAll { $0 == id }
            print(ClipboardPolicy.Copy.stoppedLine(device: gone.who))
            if subscribers.isEmpty { stopLooking() }
        case .refuse(let why):
            ignored.count(why.rawValue)     // "rate", "tooLong", "undecodable"
        }
    }

    /// The device left: forgotten without a line.
    func clientLeft(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        arrivals[id] = nil
        guard subscribers.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        if subscribers.isEmpty { stopLooking() }
    }

    private func subscribe(_ connection: NWConnection, who: String) {
        let id = ObjectIdentifier(connection)
        guard subscribers[id] == nil else { return }
        if let testBoardName, !saidTestBoard {
            saidTestBoard = true
            print("Test clipboard: a pasteboard of this host's own, \(testBoardName), never this Mac's clipboard.")
        }
        subscribers[id] = (connection, who)
        order.append(id)
        print(ClipboardPolicy.Copy.sharesLine(device: who))
        startLooking()
    }

    // MARK: The pasteboard

    private func startLooking() {
        guard look == nil else { return }
        board.takeAsSeen()             // what is on the clipboard now is never sent
        look = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ClipboardPolicy.lookInterval))
                guard !Task.isCancelled, let board = self?.board else { return }
                // On the board's queue; the main actor waits for nothing meanwhile.
                let looked = await board.look()
                guard !Task.isCancelled, let self else { return }
                self.lookedAt(looked)
            }
        }
    }

    private func stopLooking() {
        look?.cancel()
        look = nil
    }

    /// A look: macOS's answer's line when it changed (ClipboardPolicy.accessLine), and a change the
    /// board looked at to every subscriber, when ClipboardPolicy took it.
    private func lookedAt(_ looked: Board.Look) {
        if let line = ClipboardPolicy.accessLine(was: reportedAccess, now: looked.access) { print(line) }
        reportedAccess = looked.access
        guard let (count, decision) = looked.change else { return }
        switch decision {
        case .send(let payload):
            let to = order.compactMap { subscribers[$0]?.connection }
            if testLog { print("Test clipboard: change \(count) sent to \(to.count) device\(to.count == 1 ? "" : "s") (\(payload.count) bytes of JSON).") }
            send(payload: payload, to: to)
        case .skip(let why):
            if testLog { print("Test clipboard: change \(count) not sent (\(why.rawValue)).") }
        }
    }

    /// The pasteboard, read and written on `queue` alone, in order: a write a device asked for is
    /// done before any later look, so the look always finds it as this host's own (its change count
    /// taken as seen, and its marker naming this launch besides).
    private final class Board: @unchecked Sendable {
        private let queue = DispatchQueue(label: "sill.clipboard", qos: .userInitiated)
        private let board: NSPasteboard
        private let launchID: String
        /// macOS's answer for this pasteboard (MacClipboard.access, or a synthetic host's own).
        private let access: @Sendable () -> ClipboardPolicy.MacAccess
        // On `queue`: the change count the looks have dealt with, the one after this host's own last
        // write, the first look at a change whose pasteboard was still empty (ClipboardPolicy.hostWaits),
        // and macOS's answer at the last look (or when the count was last taken as seen).
        private var seen = 0
        private var ownChangeCount: Int?
        private var firstLook: (count: Int, at: Double)?
        private var lastAccess: ClipboardPolicy.MacAccess?

        /// What a look found: macOS's answer, and a change of the pasteboard with ClipboardPolicy's
        /// decision (nil when the count did not move, the pasteboard was still empty, or nothing was read).
        struct Look {
            let access: ClipboardPolicy.MacAccess
            let change: (count: Int, decision: ClipboardPolicy.HostDecision)?
        }

        /// `name`: a pasteboard of a synthetic host's own; nil, the Mac's.
        init(name: String?, launchID: String, access: @escaping @Sendable () -> ClipboardPolicy.MacAccess) {
            board = name.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
            self.launchID = launchID
            self.access = access
        }

        /// The change count as it stands is seen: what is on the clipboard now is never sent. While
        /// macOS does not allow every read, nothing is read: the first look it allows takes it then.
        func takeAsSeen() {
            queue.async {
                let now = self.access()
                self.lastAccess = now
                if ClipboardPolicy.hostLooks(now) { self.seen = self.board.changeCount }
            }
        }

        /// One look: macOS's answer, then, while it allows every read and the change count moved,
        /// ClipboardPolicy's decision from the items' types, the marker and the text read only when it
        /// needs them.
        func look() async -> Look {
            await withCheckedContinuation { done in
                queue.async { done.resume(returning: self.lookNow()) }
            }
        }

        private func lookNow() -> Look {
            let access = self.access()
            let step = ClipboardPolicy.accessStep(was: lastAccess, now: access)
            lastAccess = access
            switch step {
            case .wait:
                return Look(access: access, change: nil)
            case .takeAsSeen:
                // Allowed again: what was copied while macOS asked or denied is never sent.
                seen = board.changeCount
                firstLook = nil
                return Look(access: access, change: nil)
            case .look:
                break
            }
            let count = board.changeCount
            guard count != seen else { return Look(access: access, change: nil) }
            let types = (board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
            // Cleared and not yet written: look again (the write does not move the count).
            let now = ProcessInfo.processInfo.systemUptime
            if firstLook?.count != count { firstLook = (count, now) }
            if ClipboardPolicy.hostWaits(types: types, firstLook: firstLook?.at ?? now, now: now) {
                return Look(access: access, change: nil)
            }
            seen = count
            let own = NSPasteboard.PasteboardType(ClipboardPolicy.ownType)
            let decision = ClipboardPolicy.hostDecides(types: types, changeCount: count, ownChangeCount: ownChangeCount,
                                                       launchID: launchID,
                                                       ownMarker: { self.board.string(forType: own) },
                                                       text: { self.board.string(forType: .string) })
            return Look(access: access, change: (count, decision))
        }

        /// A device's text, for this Mac only, marked as this launch's, its change count kept. Written
        /// whatever macOS says of reads: writing needs no leave.
        func write(_ text: String) {
            queue.async {
                let prepared = self.board.prepareForNewContents(with: .currentHostOnly)
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setString(self.launchID, forType: NSPasteboard.PasteboardType(ClipboardPolicy.ownType))
                self.board.writeObjects([item])
                // The count after it: read back while macOS allows reads, as the looks do; else the one
                // the write began with, which the write itself does not move.
                let count = self.lastAccess.map(ClipboardPolicy.hostLooks) == false ? prepared : self.board.changeCount
                self.ownChangeCount = count
                self.seen = count
            }
        }
    }

    private func send(payload: Data?, to connections: [NWConnection]) {
        guard let payload, !connections.isEmpty else { return }
        let message = StreamMessage(kind: .clipboard, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
        server.send(each: connections.map { ($0, message) })
        for _ in connections { Stats.shared.bump("clip.sent") }
    }
}

/// macOS's paste privacy for this Mac's clipboard (ClipboardPolicy.MacAccess; macOS 15.4 and later),
/// for HostClipboard's looks and Sill.app's Settings › General. `access` reads NSPasteboard.general's
/// `accessBehavior` alone, which never brings macOS's alert and reads nothing of the clipboard.
package enum MacClipboard {
    package static func access() -> ClipboardPolicy.MacAccess {
        if #available(macOS 15.4, *) {
            return ClipboardPolicy.macAccess(raw: NSPasteboard.general.accessBehavior.rawValue)
        }
        return ClipboardPolicy.macAccess(raw: nil)
    }

    /// Settings › General's Allow in System Settings while macOS has not asked about Sill yet
    /// (`notAsked`): one read of the clipboard, made because the person clicked, so that macOS asks
    /// about Sill and lists it under Paste from Other Apps. What it read is dropped at once and never
    /// leaves this process. Off the main thread, which macOS's alert would hold until it is answered;
    /// `then` runs on the main queue afterwards. Never from a look.
    package static func askOnce(then done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = NSPasteboard.general.string(forType: .string)
            DispatchQueue.main.async(execute: done)
        }
    }
}
