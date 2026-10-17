import Foundation

/// Counts refused connections by cause and reports them at most once a minute, so a scanner
/// hammering a door costs one log line a minute, not one per attempt. The first refusal after a
/// quiet minute is reported at once (the line then counts just it); the rest of that minute's are
/// reported together when the minute is up, and so on while refusals keep coming.
///
/// Threading: every call on `queue` (the network queue), which also runs the timer.
final class RefusalSummary {
    private let queue: DispatchQueue
    private let categories: [String]
    private let format: ([String: Int]) -> String
    private var counts: [String: Int] = [:]
    private var armed = false
    static let interval: TimeInterval = 60

    /// `format` makes the line from the counts (every category present, zeros included).
    init(queue: DispatchQueue, categories: [String], format: @escaping ([String: Int]) -> String) {
        self.queue = queue
        self.categories = categories
        self.format = format
    }

    /// One refusal of `category`. On `queue`.
    func count(_ category: String) {
        counts[category, default: 0] += 1
        if !armed { flush() }
    }

    private func flush() {
        guard counts.values.contains(where: { $0 > 0 }) else { armed = false; return }
        var all: [String: Int] = [:]
        for c in categories { all[c] = counts[c, default: 0] }
        for (c, n) in counts where all[c] == nil { all[c] = n }
        print(format(all))
        counts = [:]
        armed = true
        queue.asyncAfter(deadline: .now() + Self.interval) { [weak self] in self?.flush() }
    }
}
