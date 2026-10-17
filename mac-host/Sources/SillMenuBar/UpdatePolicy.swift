import Foundation
import StreamProtocol

/// Sill.app's update check as pure rules (docs/update-notice-plan.md §6): the feed, what one
/// answer from it means and what is kept afterwards, when the next automatic check is due, and every
/// word the menu, the Settings pane and the log say about it. UpdateChecker does the asking and the
/// timing; this file decides. Foundation and StreamProtocol's SillVersion only, so it is checked on
/// its own with swiftc.
///
/// A check, not an updater: a newer release is offered in the status menu and Settings, and opening
/// it shows its page on GitHub, where the person downloads the notarized zip. Nothing is downloaded
/// or installed by Sill, and the only feed is GitHub's (no server of Sill's, no token, no identifier).
enum UpdatePolicy {
    /// GitHub's latest published release of Sill (drafts and prereleases are never listed there).
    static let feed = URL(string: "https://api.github.com/repos/NateHag/Sill-Viewer/releases/latest")!
    /// Where a redirect may lead (a renamed repository answers 301 to its new address there).
    static func redirectAllowed(_ url: URL) -> Bool { url.scheme == "https" && url.host == "api.github.com" }

    static let period: TimeInterval = 24 * 3600
    /// A random 0–30 minutes on top of the period, so Macs behind one address drift apart.
    static let jitter: TimeInterval = 30 * 60
    /// After a check that got no HTTP answer at all (offline, a timeout): again this much later.
    static let retry: TimeInterval = 3600
    /// The first automatic check, when due, this long after the host has started (or failed to).
    static let launchDelay: TimeInterval = 30
    static let requestTimeout: TimeInterval = 10
    /// The most of a body read; more is not a release.
    static let maxBody = 1 << 20

    // MARK: What is kept

    /// The checker's own keys in the app's defaults: GitHub's last answer of any kind, and the last
    /// published release it named, which is offered whenever it is newer than what runs.
    struct Stored: Equatable {
        /// updateLastCheck: when GitHub last answered (any HTTP status).
        var lastCheck: Date?
        /// updateETag: the last 200's ETag, sent back as If-None-Match.
        var etag: String?
        /// updateLatestTag: the last published release's tag as GitHub wrote it ("v0.4.0").
        var latestTag: String?
        /// updateLatestURL: its html_url.
        var latestURL: String?

        static let lastCheckKey = "updateLastCheck", etagKey = "updateETag", tagKey = "updateLatestTag", urlKey = "updateLatestURL"
    }

    /// A newer release to offer.
    struct Offer: Equatable {
        let version: SillVersion
        let tag: String
        let url: URL
    }

    /// The stored release when it is newer than `running` and its page is one Sill opens: on
    /// github.com over https (with a test feed, any http or https page). Read again at every use, so
    /// the offer goes by itself once the new version runs, and comes back after a downgrade.
    static func offer(stored: Stored, running: SillVersion?, anyReleaseURL: Bool = false) -> Offer? {
        guard let running, let tag = stored.latestTag, let version = SillVersion(tag), version > running,
              let text = stored.latestURL, let url = releasePage(text, anyReleaseURL: anyReleaseURL) else { return nil }
        return Offer(version: version, tag: tag, url: url)
    }

    /// A release's html_url as a page Sill opens: https on github.com, or with a test feed any http
    /// or https URL with a host.
    static func releasePage(_ text: String, anyReleaseURL: Bool) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        if anyReleaseURL { return scheme == "https" || scheme == "http" ? url : nil }
        return scheme == "https" && host.lowercased() == "github.com" ? url : nil
    }

    /// `-SillUpdateFeed`: a feed on this Mac only (127.0.0.1, ::1 or localhost, over http or https).
    static func isLocalFeed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
    }

    // MARK: One answer

    /// What one request came back with, as the checker saw it.
    enum Answer: Equatable {
        /// Any HTTP status, with the body (at most `maxBody`), the ETag and X-RateLimit-Reset.
        case http(status: Int, body: Data, etag: String?, rateLimitReset: Date?)
        /// A redirect somewhere other than api.github.com, refused.
        case redirected(host: String)
        /// A body over `maxBody`.
        case tooLarge
        /// No HTTP answer: the URLError's code and description.
        case failed(code: Int, description: String)
    }

    /// What an answer comes to.
    enum Outcome: Equatable {
        /// A published release newer than this Sill.
        case newer(Offer)
        /// The latest release is not newer (its tag as written).
        case upToDate(tag: String)
        /// 404: GitHub has no release of Sill (the repository private, or public with none yet).
        case noRelease
        /// 403 or 429: GitHub is limiting this address (its X-RateLimit-Reset, when sent).
        case limited(status: Int, reset: Date?)
        case httpError(Int)
        /// An answer that is not a published release, and why.
        case notARelease(String)
        /// No connection (offline, no DNS, refused, TLS intercepted): a URLError.
        case noConnection(code: Int, description: String)
        case timeout
        case failed(code: Int, description: String)

        /// GitHub answered with some HTTP status: the next automatic check is a period later.
        /// Otherwise it is `retry` later, and nothing is stored.
        var answered: Bool {
            switch self {
            case .noConnection, .timeout, .failed: return false
            default: return true
            }
        }
    }

    /// URLError codes that mean this Mac could not reach GitHub at all.
    static let noConnectionCodes: Set<Int> = [-1009, -1005, -1004, -1003, -1006, -1020, -1018]
    static let tlsCodes = -1206 ... -1200

    /// `answer` from the feed, given what is stored and the running version: the outcome and what
    /// to store afterwards (§6.4's table).
    static func interpret(_ answer: Answer, stored: Stored, running: SillVersion, now: Date, anyReleaseURL: Bool) -> (Outcome, Stored) {
        var next = stored
        switch answer {
        case .failed(let code, let description):
            if code == -1001 { return (.timeout, stored) }
            if noConnectionCodes.contains(code) || tlsCodes.contains(code) { return (.noConnection(code: code, description: description), stored) }
            return (.failed(code: code, description: description), stored)
        case .redirected(let host):
            next.lastCheck = now
            return (.notARelease("a redirect to \(host)"), next)
        case .tooLarge:
            next.lastCheck = now
            return (.notARelease("more than 1 MB"), next)
        case .http(let status, let body, let etag, let reset):
            next.lastCheck = now
            switch status {
            case 200:
                switch release(body, anyReleaseURL: anyReleaseURL) {
                case .failure(let why):
                    return (.notARelease(why.text), next)
                case .success(let r):
                    next.etag = etag      // a 200 without one clears it: the next request sends none
                    next.latestTag = r.tag
                    next.latestURL = r.url.absoluteString
                    return (r.version > running ? .newer(Offer(version: r.version, tag: r.tag, url: r.url)) : .upToDate(tag: r.tag), next)
                }
            case 304:
                // Only sent back for a stored release (If-None-Match goes out with one alone).
                guard let tag = stored.latestTag, let version = SillVersion(tag), let text = stored.latestURL,
                      let url = releasePage(text, anyReleaseURL: anyReleaseURL) else {
                    return (.notARelease("a 304 before any release"), next)
                }
                return (version > running ? .newer(Offer(version: version, tag: tag, url: url)) : .upToDate(tag: tag), next)
            case 404:
                // A withdrawn release stops being offered.
                next.etag = nil; next.latestTag = nil; next.latestURL = nil
                return (.noRelease, next)
            case 403, 429:
                return (.limited(status: status, reset: reset), next)
            default:
                return (.httpError(status), next)
            }
        }
    }

    /// Why a 200 is not a published release.
    enum NotARelease: Error, Equatable {
        case notJSON, noTag, draft, prerelease, badTag(String), badURL

        var text: String {
            switch self {
            case .notJSON: return "not a JSON object"
            case .noTag: return "no tag_name"
            case .draft: return "a draft"
            case .prerelease: return "a prerelease"
            case .badTag(let tag): return "the tag “\(tag)” is not a version"
            case .badURL: return "html_url is not on github.com"
            }
        }
    }

    struct Release: Equatable {
        let tag: String
        let version: SillVersion
        let url: URL
    }

    /// A 200's body as a published release: a JSON object with a string `tag_name` that parses,
    /// `draft` and `prerelease` not true, and an `html_url` Sill opens (`releasePage`). Every other
    /// field is ignored.
    static func release(_ body: Data, anyReleaseURL: Bool) -> Result<Release, NotARelease> {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .failure(.notJSON) }
        guard let tag = object["tag_name"] as? String else { return .failure(.noTag) }
        if object["draft"] as? Bool == true { return .failure(.draft) }
        if object["prerelease"] as? Bool == true { return .failure(.prerelease) }
        guard let version = SillVersion(tag) else { return .failure(.badTag(String(tag.prefix(40)))) }
        guard let text = object["html_url"] as? String, let url = releasePage(text, anyReleaseURL: anyReleaseURL) else { return .failure(.badURL) }
        return .success(Release(tag: tag, version: version, url: url))
    }

    // MARK: When

    /// An automatic check is due: never checked, a period or more ago, or "in the future" (the
    /// clock went back).
    static func isDue(lastCheck: Date?, now: Date, period: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= period || lastCheck > now
    }

    /// When the next automatic check runs: at `retryAt` after a check with no HTTP answer (never
    /// sooner than `delay` from now: a wake), `delay` from now when one is due (the launch, a wake,
    /// turning automatic checks on), else a period and the jitter after the last answer.
    static func nextCheck(lastCheck: Date?, retryAt: Date?, now: Date, period: TimeInterval, jitter: TimeInterval,
                          delay: TimeInterval) -> Date {
        if let retryAt { return max(retryAt, now.addingTimeInterval(delay)) }
        if isDue(lastCheck: lastCheck, now: now, period: period) { return now.addingTimeInterval(delay) }
        return lastCheck!.addingTimeInterval(period + jitter)
    }

    // MARK: Words

    /// "Sill 0.4 Is Available…": the status menu's item.
    static func menuTitle(_ offer: Offer) -> String { "Sill \(offer.version) Is Available…" }
    /// "You have 0.3; opens its download page".
    static func menuSubtitle(running: SillVersion) -> String { "You have \(running); opens its download page" }

    /// The log's line for an outcome, nil for none (an automatic check that found nothing new).
    /// `running` as written ("0.3.0"); `retryIn` the retry's length, for a check with no answer.
    static func logLine(_ outcome: Outcome, manual: Bool, running: String, retryIn: TimeInterval,
                        time: (Date) -> String) -> String? {
        let again = manual ? "" : "; trying again in \(duration(retryIn))"
        switch outcome {
        case .newer(let offer):
            return "Update check: Sill \(offer.version) is available (this is \(running)): \(offer.url.absoluteString)"
        case .upToDate(let tag):
            return manual ? "Update check: up to date (this is \(running); the latest release is \(tag))." : nil
        case .noRelease:
            return "Update check failed: GitHub has no release of Sill (HTTP 404)."
        case .limited(let status, let reset):
            return "Update check failed: GitHub is limiting requests from this network (HTTP \(status)"
                + (reset.map { "; it resets at \(time($0))" } ?? "") + ")."
        case .httpError(let status):
            return "Update check failed: HTTP \(status)."
        case .notARelease(let why):
            return "Update check failed: the answer is not a published release (\(why))."
        case .noConnection(let code, let description):
            return "Update check failed: no connection (\(code): \(description))\(again)."
        case .timeout:
            return "Update check failed: no answer in \(Int(requestTimeout)) s\(again)."
        case .failed(let code, let description):
            return "Update check failed: \(description) (\(code))\(again)."
        }
    }

    /// "1 hour", "15 minutes", "4 s": the retry's length as the log gives it.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds == 3600 { return "1 hour" }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) hours" }
        if seconds >= 120 { return "\(Int((seconds / 60).rounded())) minutes" }
        return "\(Int(seconds.rounded())) s"
    }

    /// Settings › General's line after Check Now, and whether it is a failure (shown in orange).
    static func resultLine(_ outcome: Outcome, time: (Date) -> String) -> (text: String, failed: Bool) {
        switch outcome {
        case .newer(let offer): return ("Sill \(offer.version) is available.", false)
        case .upToDate: return ("Sill is up to date.", false)
        case .noRelease: return ("Couldn’t check: GitHub has no release of Sill yet.", true)
        case .limited(_, let reset):
            return ("Couldn’t check: GitHub is limiting requests from this network. "
                    + (reset.map { "Try again after \(time($0))." } ?? "Try again in an hour."), true)
        case .httpError(let status): return ("Couldn’t check: GitHub answered with an error (HTTP \(status)).", true)
        case .notARelease: return ("Couldn’t check: GitHub’s answer wasn’t a release Sill understands.", true)
        case .noConnection(let code, let description):
            return (tlsCodes.contains(code) ? "Couldn’t check: \(description)" : "Couldn’t check: this Mac isn’t connected to the internet.", true)
        case .timeout: return ("Couldn’t check: GitHub didn’t answer within \(Int(requestTimeout)) seconds.", true)
        case .failed(_, let description): return ("Couldn’t check: \(description)", true)
        }
    }

    /// What Settings › General shows about updates, as plain values (the previews draw each state).
    struct Pane: Equatable {
        /// The line under the switch.
        var line: String
        /// The line is a failure (orange).
        var failed = false
        /// Open Release Page… shows while a newer release is offered.
        var releasePage: URL?
        /// Check Now is enabled.
        var canCheck = true
        /// Counts Check Now's results in this run: VoiceOver hears each new one.
        var resultID = 0
    }

    static let notCheckedLine = "Not checked yet."
    static let noVersionLine = "This build of Sill has no version number, so it can’t check."
    static let testPatternLine = "Sill doesn’t check for updates in test pattern mode."

    /// The pane's line, first match wins: a check running; this run's Check Now result (kept until
    /// GitHub answers an automatic check, UpdateChecker); why Sill cannot check (no version, test
    /// pattern mode without a test feed); a newer release offered; when it last checked; never.
    static func pane(checking: Bool, result: Outcome?, resultID: Int, offer: Offer?, lastCheck: Date?,
                     hasVersion: Bool, testPatternOnly: Bool, time: (Date) -> String, date: (Date) -> String) -> Pane {
        let canCheck = hasVersion && !testPatternOnly
        var p = Pane(line: notCheckedLine, releasePage: offer?.url, canCheck: canCheck && !checking, resultID: resultID)
        if checking {
            p.line = "Checking…"
        } else if let result {
            (p.line, p.failed) = resultLine(result, time: time)
        } else if !hasVersion {
            p.line = noVersionLine
        } else if testPatternOnly {
            p.line = testPatternLine
        } else if let offer {
            p.line = "Sill \(offer.version) is available."
        } else if let lastCheck {
            p.line = "Last checked \(date(lastCheck))."
        }
        return p
    }

    /// The pane's footer.
    static let footnote = "Once a day, Sill asks GitHub whether a newer version is out. GitHub sees this Mac’s IP address and which version of Sill it has; nothing else is sent. Sill never downloads or installs anything by itself: a new version opens its page on GitHub, where you download it."
}
