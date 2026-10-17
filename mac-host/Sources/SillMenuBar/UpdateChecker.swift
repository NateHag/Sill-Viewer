import Foundation
import Observation
import StreamProtocol

/// Sill.app's update check (docs/update-notice-plan.md §6): asks GitHub's releases feed whether a
/// newer Sill is out, keeps what it learned in the app's defaults, and says so through `offer` (the
/// status menu's item) and `pane` (Settings › General). UpdatePolicy decides what every answer
/// means; this class does the asking and the timing. Foundation and Observation only (and
/// StreamProtocol's SillVersion), so it compiles on its own with swiftc against a local fake feed,
/// with no host.
///
/// When: automatic checks (the `automatic` switch, on by default) run `launchDelay` after `start()`
/// when one is due, then a period plus a random jitter after each answer, or `retry` after a check
/// that got no answer at all; a wake re-arms the timer (a check that fell due during sleep runs
/// `launchDelay` after it). Check Now runs at once, whatever the switch and the period; during an
/// automatic check it joins it. At most one request is in flight, one an hour while network errors
/// last, one a period otherwise, and never a retry of a 404, 403, 429 or 5xx before the next period.
///
/// What goes out: GET the feed with `User-Agent: Sill/‹version›`, GitHub's Accept and API version
/// headers, `Accept-Language: en`, and If-None-Match with a stored ETag and release (URLSession adds
/// Host, Accept-Encoding and Connection); an ephemeral session with no cookies, no cache and no
/// credentials; redirects only to https://api.github.com/. Never a token, an identifier or anything
/// about the Mac or its devices. Errors are one log line and the pane's line, never an alert
/// (AppDelegate's modal-loop rule).
///
/// Main actor; the timers are run-loop timers that hop here with a Task.
@MainActor @Observable
final class UpdateChecker {
    /// Where and when it checks: GitHub and the plan's schedule, or a test's (DebugHooks).
    struct Configuration {
        /// The releases feed.
        var feed = UpdatePolicy.feed
        /// A feed on this Mac (`-SillUpdateFeed`): any http or https release page counts, and test
        /// pattern mode checks.
        var testFeed = false
        /// This Sill's version as written (CFBundleShortVersionString, or `-SillUpdateVersion`); a
        /// build whose version does not parse ("dev") never checks.
        var running: String?
        /// `--synthetic`: no check without a test feed.
        var testPattern = false
        /// `-SillUpdateNow 1`: one check right after `start()`, as Check Now.
        var checkAtStart = false
        var period = UpdatePolicy.period
        var retry = UpdatePolicy.retry
        var launchDelay = UpdatePolicy.launchDelay
        var jitter = UpdatePolicy.jitter
        var timeout = UpdatePolicy.requestTimeout
    }

    enum Phase: Equatable { case idle, checking }

    private(set) var phase = Phase.idle
    /// What the defaults keep (UpdatePolicy.Stored).
    private(set) var stored: UpdatePolicy.Stored
    /// This run's last Check Now result, until an automatic check that GitHub answers replaces it
    /// with what is known then (Sill.app runs from login for weeks: a release out since Check Now
    /// must show), and how many Check Now results there were (VoiceOver hears each).
    private(set) var result: UpdatePolicy.Outcome?
    private(set) var resultCount = 0
    /// Automatic checks: HostSettings' `updateCheck`, set through `setAutomatic`.
    private(set) var automatic: Bool

    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored private let running: SillVersion?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var started = false
    @ObservationIgnored private var inFlight = false
    /// A Check Now waits on the check in flight (it joined an automatic one, or started it).
    @ObservationIgnored private var manualPending = false
    @ObservationIgnored private var timer: Timer?
    /// After a check with no answer: the next automatic one, in memory only.
    @ObservationIgnored private var retryAt: Date?
    /// This period's jitter, drawn once per answer so a wake does not move the check.
    @ObservationIgnored private var jitter: TimeInterval

    init(configuration: Configuration, automatic: Bool, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.automatic = automatic
        self.defaults = defaults
        running = configuration.running.flatMap { SillVersion($0) }
        jitter = configuration.jitter > 0 ? .random(in: 0...configuration.jitter) : 0
        let d = defaults
        stored = UpdatePolicy.Stored(
            lastCheck: d.object(forKey: UpdatePolicy.Stored.lastCheckKey) == nil ? nil
                : Date(timeIntervalSince1970: d.double(forKey: UpdatePolicy.Stored.lastCheckKey)),
            etag: d.string(forKey: UpdatePolicy.Stored.etagKey),
            latestTag: d.string(forKey: UpdatePolicy.Stored.tagKey),
            latestURL: d.string(forKey: UpdatePolicy.Stored.urlKey))
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = configuration.timeout
        c.timeoutIntervalForResource = configuration.timeout
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        // Accept-Language fixed: URLSession would otherwise send this Mac's preferred languages.
        // What else it adds (Host, Accept-Encoding, Connection) says nothing about the Mac.
        c.httpAdditionalHeaders = ["User-Agent": "Sill/\(configuration.running ?? "unknown")",
                                   "Accept": "application/vnd.github+json",
                                   "X-GitHub-Api-Version": "2022-11-28",
                                   "Accept-Language": "en"]
        session = URLSession(configuration: c)
    }

    /// Whether this build can check at all: it has a version, and it is not in test pattern mode
    /// without a test feed.
    var canCheck: Bool { running != nil && !testPatternOnly }
    private var testPatternOnly: Bool { configuration.testPattern && !configuration.testFeed }

    /// The stored release, when it is newer than what runs.
    var offer: UpdatePolicy.Offer? {
        UpdatePolicy.offer(stored: stored, running: running, anyReleaseURL: configuration.testFeed)
    }

    /// Settings › General's line and buttons.
    var pane: UpdatePolicy.Pane {
        UpdatePolicy.pane(checking: phase == .checking, result: result, resultID: resultCount, offer: offer,
                          lastCheck: stored.lastCheck, hasVersion: running != nil, testPatternOnly: testPatternOnly,
                          time: Self.time, date: Self.date)
    }

    /// The running version as SillVersion shows it ("0.3"), for the menu's subtitle.
    var runningVersion: SillVersion? { running }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    // MARK: Starting and scheduling

    /// Once the host has started, or could not (a newer Sill may be the fix): says what an earlier
    /// check found, runs `-SillUpdateNow`'s check, and schedules the automatic ones.
    func start() {
        guard !started else { return }
        started = true
        if let offer { print("Update: Sill \(offer.version) is available (found by an earlier check).") }
        if configuration.checkAtStart {
            if testPatternOnly {
                print("SillUpdateNow ignored: test pattern mode checks only a test feed (-SillUpdateFeed).")
            } else if running == nil {
                print("SillUpdateNow ignored: this build has no version number (-SillUpdateVersion gives it one).")
            } else {
                checkNow()
            }
        }
        schedule()
    }

    /// The Automatic switch. On: scheduled by the rule (if due, `launchDelay` later). Off: nothing
    /// more is scheduled; a check in flight finishes, and what was found stays offered.
    func setAutomatic(_ on: Bool) {
        guard on != automatic else { return }
        automatic = on
        schedule()
    }

    /// The Mac woke: timers did not run while it slept, so the next check is worked out again.
    func systemDidWake() {
        schedule()
    }

    /// Arms the one timer for the next automatic check, or none.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard started, automatic, canCheck, !inFlight else { return }
        let now = Date()
        let at = UpdatePolicy.nextCheck(lastCheck: stored.lastCheck, retryAt: retryAt, now: now, period: configuration.period,
                                        jitter: jitter, delay: configuration.launchDelay)
        let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.timerFired() }
        }
        t.tolerance = min(60, max(0.1, configuration.period / 1440))
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func timerFired() {
        timer = nil
        guard started, automatic, canCheck, !inFlight else { return }
        run()
    }

    // MARK: Checking

    /// Check Now (and `-SillUpdateNow`): at once, whatever the switch and the period; during a
    /// check it joins it, and that check's result is Check Now's.
    func checkNow() {
        guard canCheck else { return }
        manualPending = true
        if !inFlight { run() }
    }

    private func run() {
        inFlight = true
        phase = .checking
        timer?.invalidate()
        timer = nil
        var request = URLRequest(url: configuration.feed)
        if let etag = stored.etag, stored.latestTag != nil, stored.latestURL != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        Task { @MainActor [session] in
            let answer = await Self.fetch(request, session: session)
            self.finish(answer)
        }
    }

    private func finish(_ answer: UpdatePolicy.Answer) {
        let manual = manualPending
        manualPending = false
        inFlight = false
        phase = .idle
        guard let running else { return }
        let now = Date()
        let (outcome, next) = UpdatePolicy.interpret(answer, stored: stored, running: running, now: now,
                                                      anyReleaseURL: configuration.testFeed)
        if next != stored {
            stored = next
            save(next)
        }
        if let line = UpdatePolicy.logLine(outcome, manual: manual, running: configuration.running ?? "\(running)",
                                           retryIn: configuration.retry, time: Self.time) {
            print(line)
        }
        if manual {
            result = outcome
            resultCount += 1
        } else if outcome.answered {
            // GitHub answered an automatic check since Check Now: the pane goes back to what is
            // known now (the offer, or when it last checked) instead of an older result. A check
            // with no answer leaves it: nothing it learned is newer. VoiceOver hears Check Now's
            // results only (`resultCount`).
            result = nil
        }
        if outcome.answered {
            retryAt = nil
            jitter = configuration.jitter > 0 ? .random(in: 0...configuration.jitter) : 0
        } else {
            retryAt = now.addingTimeInterval(configuration.retry)
        }
        schedule()
    }

    private func save(_ s: UpdatePolicy.Stored) {
        func set(_ value: Any?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        set(s.lastCheck?.timeIntervalSince1970, UpdatePolicy.Stored.lastCheckKey)
        set(s.etag, UpdatePolicy.Stored.etagKey)
        set(s.latestTag, UpdatePolicy.Stored.tagKey)
        set(s.latestURL, UpdatePolicy.Stored.urlKey)
    }

    /// One GET, as UpdatePolicy reads it: the status, at most `maxBody` of the body, the ETag and
    /// the rate limit's reset; a redirect other than to api.github.com refused; a URLError's code.
    /// Off the main actor: the body is read a byte at a time.
    nonisolated private static func fetch(_ request: URLRequest, session: URLSession) async -> UpdatePolicy.Answer {
        let guardian = RedirectGuard()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
            if let host = guardian.refusedHost { return .redirected(host: host) }
            guard let http = response as? HTTPURLResponse else { return .failed(code: 0, description: "not an HTTP answer") }
            if http.expectedContentLength > Int64(UpdatePolicy.maxBody) { return .tooLarge }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > UpdatePolicy.maxBody { return .tooLarge }
            }
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            return .http(status: http.statusCode, body: body, etag: http.value(forHTTPHeaderField: "ETag"), rateLimitReset: reset)
        } catch let e as URLError {
            if let host = guardian.refusedHost { return .redirected(host: host) }
            return .failed(code: e.code.rawValue, description: e.localizedDescription)
        } catch {
            return .failed(code: 0, description: error.localizedDescription)
        }
    }
}

/// Follows a redirect only to https://api.github.com/ and remembers where any other one led.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refused: String?

    var refusedHost: String? {
        lock.lock(); defer { lock.unlock() }
        return refused
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, UpdatePolicy.redirectAllowed(url) {
            completionHandler(request)
            return
        }
        lock.lock()
        refused = request.url?.host ?? "an address without a host"
        lock.unlock()
        completionHandler(nil)
    }
}
