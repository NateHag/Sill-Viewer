import Foundation

/// Counters for the spike, printed as one line so a stalled stage is obvious.
///
/// Cadence: a line every second while there is something to report (any counter bumped in the
/// last second) or a client is connected. When a second passes with neither, the 1 s timer is
/// rescheduled to a 30 s heartbeat with generous leeway, so an idle host is not woken every
/// second. The next `bump` or a client arriving switches back to 1 s.
///
/// Threading: `bump` comes from the capture queue, VideoToolbox's callback thread and the
/// network queue; `activeClients` / `windowCount` from the main actor. All shared state is under
/// `lock`. The timer, its schedule and `fast` belong to the main queue, and every reschedule runs
/// there, so a wake-up enqueued by `bump` always lands after the tick that armed it.
package final class Stats {
    package static let shared = Stats()

    /// Each tick's counters (empty on an idle heartbeat), on the main queue just before the line
    /// prints: the app's live encoded fps. Set it on the main queue. The main queue is not always
    /// the main thread (the CLI's dispatchMain drains it on a worker), so a main-actor consumer
    /// hops with `Task { @MainActor }` rather than assuming isolation.
    var onTick: (([String: Int]) -> Void)?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var counts: [String: Int] = [:]
    private var clients = 0
    private var windows = 0
    /// Set by a quiet tick: the next bump (or client) must wake the 1 s timer. Keeps `bump` to one
    /// extra bool check on the hot path.
    private var armed = false

    // Main queue only.
    private var timer: DispatchSourceTimer?
    private var fast = true

    static let activeInterval: DispatchTimeInterval = .seconds(1)
    static let idleInterval: DispatchTimeInterval = .seconds(30)

    func bump(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        let wake = armed
        armed = false
        lock.unlock()
        if wake { DispatchQueue.main.async { self.goFast() } }
    }

    /// Connected clients. With any, the line prints every second even when nothing is counted.
    var activeClients: Int {
        get { lock.lock(); defer { lock.unlock() }; return clients }
        set {
            lock.lock()
            clients = newValue
            let wake = newValue > 0 && armed
            if wake { armed = false }
            lock.unlock()
            if wake { DispatchQueue.main.async { self.goFast() } }
        }
    }

    /// Windows in the catalog's last poll, for the idle heartbeat. While idle the catalog does
    /// not poll, so this is the count as of the last look.
    var windowCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return windows }
        set { lock.lock(); windows = newValue; lock.unlock() }
    }

    /// Call once, on the main queue.
    package func startPrinting() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        fast = true
        schedule()
        timer.resume()
    }

    private func schedule() {
        if fast {
            timer?.schedule(deadline: .now() + Self.activeInterval, repeating: Self.activeInterval, leeway: .milliseconds(50))
        } else {
            // Leeway lets the kernel coalesce this wake-up with others; nobody needs it on the dot.
            timer?.schedule(deadline: .now() + Self.idleInterval, repeating: Self.idleInterval, leeway: .seconds(5))
        }
    }

    /// Main queue. Back to one line a second.
    private func goFast() {
        guard timer != nil, !fast else { return }
        fast = true
        schedule()
    }

    private func tick() {
        lock.lock()
        let snapshot = counts
        counts = [:]
        let clients = self.clients, windows = self.windows
        let quiet = snapshot.isEmpty && clients == 0
        if quiet { armed = true }
        lock.unlock()

        onTick?(snapshot)
        if quiet {
            if fast { fast = false; schedule() }       // heartbeat from now on, until woken
            print("[30s] idle · 0 clients · \(windows) windows")
            return
        }
        if !fast { fast = true; schedule() }           // a heartbeat tick found work (normally bump wakes us first)
        let line = snapshot.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  ")
        let who = clients == 1 ? "1 client" : "\(clients) clients"
        print("[1s] " + (line.isEmpty ? "nothing captured" : line) + " · " + who)
    }

    /// One-shot print of every counter, for the self-test.
    func dump() {
        lock.lock(); let snapshot = counts; lock.unlock()
        print("   stats: " + snapshot.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  "))
    }
}
