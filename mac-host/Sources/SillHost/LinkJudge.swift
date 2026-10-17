import Foundation
import StreamProtocol

/// How the link to one device keeps up (docs/remote-bundle-plan.md §6), judged once a second from
/// what the host did for it: fine, behind ("the link can't carry this quality") or stalled (nothing
/// gets through either way). Every device is judged, at home too; the host only counts, and nothing
/// it sends or drops changes. Pure (Foundation and StreamProtocol's QualityPreset), checked with
/// swiftc (Tests/checks/link-judge).
///
/// `.contentProcessed` comes once a message has been taken whole, so a 1.6 MB keyframe crossing
/// 2 Mbps can show as seconds of nothing taken, then all of it, though the link carried it
/// throughout: stalled needs the device silent too, and the carried rate is a mean.
struct LinkJudge {
    enum State: Equatable { case fine, behind, stalled }

    /// One second of what the host did for the device.
    struct Second: Equatable {
        /// Frames sent to it.
        var sent: Int
        /// Frames withheld from it: dropped, or skipped while it waited for a keyframe. Not those
        /// before its first keyframe since it connected or the stream changed: that wait is the
        /// connect or a restart, not the link (the host leaves them out).
        var withheld: Int
        /// Bytes its connection took (`.contentProcessed`).
        var taken: Int
        /// Bytes waiting at the second's end.
        var waiting: Int
        /// Anything came from the device in the second (it pings every 0.25 s).
        var heard: Bool
    }

    /// A report: the state, what the second that judged it saw, and the carried rate as it stands.
    struct Verdict: Equatable {
        var state: State
        var withheld: Int
        /// Frames offered in that second: sent and withheld.
        var offered: Int
        var carriedKbps: Int?
        var waiting: Int
        /// Fine because the stream restarted (`reset`), not because the link recovered: the host
        /// clears the report without a line.
        var reset: Bool
    }

    /// Behind: `shortToBehind` of the last `window` seconds short. Fine again: `cleanToFine` seconds
    /// in a row not short. Stalled: `stallSeconds` in a row with bytes waiting, none taken and nothing
    /// heard.
    static let window = 5, shortToBehind = 3, cleanToFine = 5, stallSeconds = 3
    /// The carried rate: over the last `window` seconds that ended with at least `measureWaiting`
    /// bytes waiting (the link, not the stream, set the pace), needing `measureNeeded` of them.
    static let measureWaiting = 16 * 1024, measureNeeded = 3
    /// A suggestion fits in this share of what the link carried.
    static let headroom = 0.7
    /// During a spell the carried rate is reported again when it has moved by this share of the
    /// rate last reported: the first seconds of a connection read high while the buffers between
    /// the host and the link fill (0.7–1 MB on the harness's loopback path, up to the kernel's
    /// autotuned send buffer on a real one), and the suggestion follows the rate as it settles.
    static let carriedMove = 0.25

    /// At least 3 frames withheld, and at least a tenth of the second's frames: a single drop at
    /// home (one frame, then the keyframe asked for at once) never counts, nor a still window (no
    /// frames).
    static func isShort(_ s: Second) -> Bool {
        s.withheld >= 3 && 10 * s.withheld >= s.sent + s.withheld
    }

    private(set) var state = State.fine
    /// The last `window` seconds, oldest first.
    private var recent: [Second] = []
    /// Seconds in a row that were not short.
    private var cleanRun = 0
    /// Seconds in a row with bytes waiting, none taken and nothing heard.
    private var stallRun = 0
    /// The carried rate this spell (from leaving fine until back) last reported; nil for none yet.
    private var reportedCarried: Int?

    /// Closes a second. A verdict when the state changes, and again during a spell when the carried
    /// rate is first measured or has moved by `carriedMove` since it was last reported (never every
    /// second: the device's own stats carry its fps).
    mutating func close(_ s: Second) -> Verdict? {
        recent.append(s)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        let short = Self.isShort(s)
        cleanRun = short ? 0 : cleanRun + 1
        let dead = s.taken == 0 && s.waiting > 0 && !s.heard
        stallRun = dead ? stallRun + 1 : 0
        let shorts = recent.filter(Self.isShort).count
        let before = state
        switch state {
        case .fine:
            if stallRun >= Self.stallSeconds { state = .stalled }
            else if shorts >= Self.shortToBehind { state = .behind }
        case .behind:
            if stallRun >= Self.stallSeconds { state = .stalled }
            else if cleanRun >= Self.cleanToFine { state = .fine }
        case .stalled:
            // Ends at the first second anything is taken or heard: behind while the window says so.
            if !dead { state = shorts >= Self.shortToBehind ? .behind : .fine }
        }
        let carried = carriedKbps
        let verdict = Verdict(state: state, withheld: s.withheld, offered: s.sent + s.withheld, carriedKbps: carried,
                              waiting: s.waiting, reset: false)
        if state == .fine {
            reportedCarried = nil
            return state != before ? verdict : nil
        }
        if state != before {
            reportedCarried = carried
            return verdict
        }
        if let now = carried, reportedCarried.map({ Double(abs(now - $0)) >= Self.carriedMove * Double($0) }) ?? true {
            reportedCarried = now
            return verdict
        }
        return nil
    }

    /// The stream restarted at another quality, or stopped (`judgedAfresh`): the window is cleared
    /// and the state goes back to fine, to be judged afresh. A verdict, marked `reset`, when it was
    /// not fine: picking a lower quality clears the callout at once.
    mutating func reset() -> Verdict? {
        let was = state
        state = .fine
        recent = []
        cleanRun = 0
        stallRun = 0
        reportedCarried = nil
        return was == .fine ? nil : Verdict(state: .fine, withheld: 0, offered: 0, carriedKbps: nil, waiting: 0, reset: true)
    }

    /// What the links are judged at: the stream's bitrate (per 60 fps, as the reports name it), its
    /// frame rate and its capture scale.
    struct Quality: Equatable {
        var bitrate: Int
        var fps: Int
        var captureScale: Double
    }

    /// Whether a restarted stream's links are judged afresh (`reset`): when it runs at another
    /// quality (a bitrate, a rate or a resolution the reports and suggestions were not made for),
    /// and when nothing streams any more (`new` nil). A restart that keeps the quality (a window
    /// picked, a rotation, a resize, the Aa scale, the virtual display) keeps the judgement: the link
    /// and what it must carry are the same. Judged afresh there, a link that could not carry the
    /// quality was reported again 2.5–3 s later, after the device's line had gone (its linger is 2 s):
    /// the line came back, VoiceOver said it again and the Mac logged it again, at every such restart
    /// (the review of 2026-09-27; the pacing harness's linkrestart).
    static func judgedAfresh(from old: Quality?, to new: Quality?) -> Bool {
        new != old
    }

    /// What the link carried in the seconds it set the pace: the bytes taken in the last `window`
    /// seconds that ended with at least `measureWaiting` waiting, over their number, as kilobits a
    /// second; nil until `measureNeeded` such seconds. A mean, not a median: messages are taken
    /// whole, so a keyframe that crosses in 2 s counts as a second of nothing and a second of all
    /// of it.
    var carriedKbps: Int? {
        let measured = recent.filter { $0.waiting >= Self.measureWaiting }
        guard measured.count >= Self.measureNeeded else { return nil }
        let mean = Double(measured.reduce(0) { $0 + $1.taken }) / Double(measured.count)
        return Int((mean * 8 / 1000).rounded())
    }

    /// What would fit (§6.2), relative to the running quality (`bitrate` per 60 fps at
    /// `captureScale`) and the stream's frame rate: the highest preset below the running bitrate
    /// whose rate at `fps` is at most 70 % of what the link carried, Low when none fits, one step
    /// down without a measure; with Standard when that is Low and the stream runs at Retina. With no
    /// preset below the running bitrate (Low, or a hand-set rate under it), the same bitrate at
    /// Standard from Retina, and nothing (nil) from Standard. Never a higher bitrate. A nil capture
    /// scale keeps the resolution.
    static func suggestion(carriedKbps: Int?, bitrate: Int, fps: Int, captureScale: Double) -> (bitrate: Int, captureScale: Double?)? {
        let retina = captureScale >= 1.5
        let lower = QualityPreset.allCases.map(\.rawValue).filter { $0 < bitrate }.sorted()
        guard let oneDown = lower.last else { return retina ? (bitrate, 1) : nil }
        var pick = oneDown
        if let carried = carriedKbps {
            let budget = Double(carried) * 1000 * headroom
            pick = lower.last { Double($0) * Double(max(fps, 1)) / 60 <= budget } ?? lower[0]
        }
        return (pick, pick == QualityPreset.low.rawValue && retina ? 1 : nil)
    }

    // MARK: The host's lines (docs/remote-bundle-plan.md §6.8)

    /// "Link to iPad (iPad14,1): cannot carry Pro (withheld 52 of 58 frames in the last second; the
    /// link carried about 6.4 Mbps); suggesting Low · Standard." The suggestion's resolution is named
    /// when it changes it.
    static func behindLine(device: String, bitrate: Int, withheld: Int, offered: Int, carriedKbps: Int?,
                           suggestion: (bitrate: Int, captureScale: Double?)?) -> String {
        let carried = carriedKbps.map { "; the link carried about \(mbps(kbps: $0)) Mbps" } ?? ""
        let suggesting = suggestion.map { "suggesting \(title($0))" } ?? "nothing lower to suggest"
        return "Link to \(device): cannot carry \(QualityPreset.name(forBitrate: bitrate)) "
            + "(withheld \(withheld) of \(offered) frames in the last second\(carried)); \(suggesting)."
    }

    /// "Link to iPad (iPad14,1): nothing has got through for 3 s, and nothing has come from it (1.2
    /// MB waiting)."
    static func stalledLine(device: String, waiting: Int) -> String {
        "Link to \(device): nothing has got through for \(stallSeconds) s, and nothing has come from it (\(bytes(waiting)) waiting)."
    }

    /// "Link to iPad (iPad14,1): keeping up again." A judged recovery only, never a restart's reset.
    static func fineLine(device: String) -> String { "Link to \(device): keeping up again." }

    /// A suggestion as the lines and the device name it: "Low · Standard" when it names a
    /// resolution, else the preset's name alone ("Ultra").
    static func title(_ s: (bitrate: Int, captureScale: Double?)) -> String {
        s.captureScale.map { QualityPreset.shortTitle(bitrate: s.bitrate, captureScale: $0) } ?? QualityPreset.name(forBitrate: s.bitrate)
    }

    /// 6400 → "6.4", 12000 → "12", 800 → "0.8".
    static func mbps(kbps: Int) -> String {
        let tenths = Int((Double(kbps) / 100).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }

    /// 1_200_000 → "1.2 MB", 640_000 → "640 kB".
    static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 {
            let tenths = Int((Double(n) / 100_000).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10) MB" : "\(tenths / 10).\(tenths % 10) MB"
        }
        return "\(Int((Double(n) / 1000).rounded())) kB"
    }
}
