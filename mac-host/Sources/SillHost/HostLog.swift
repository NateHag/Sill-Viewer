import Foundation

/// Every line the host logs, for the menu bar app, whose stdout goes nowhere when Finder, `open`
/// or a login item launches it: the last lines in a ring for its Log window, and a timestamped
/// file (~/Library/Logs/Sill/Sill.log) to `tail -F`.
///
/// How lines get here: this module's `print` (below) shadows `Swift.print` and hands each line
/// to `append` after printing it exactly as before. The CLI never calls `configure`, so it keeps
/// nothing, writes no file, and its stdout is byte for byte what it was; each line costs it one
/// lock and a check.
///
/// Threading: lines arrive from the main queue, the capture queue, VideoToolbox's thread and the
/// network queue. State is under `lock`. The file is written on its own utility queue, never on
/// the threads that print. `onAppend` fires on the main queue.
package final class HostLog: @unchecked Sendable {
    package static let shared = HostLog()

    package struct Line: Sendable {
        /// 1, 2, 3…: a reader asks for what came after the last one it has.
        package let seq: UInt64
        package let date: Date
        package let text: String
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var capacity = 0
    private var ring: [Line] = []
    private var head = 0                  // the oldest line, once the ring is full
    private var nextSeq: UInt64 = 1
    private var sink: FileSink?
    private var url: URL?
    private var appendHandler: (() -> Void)?
    private var notifyScheduled = false

    /// Call once, before the host starts. Keeps the last `keepLines` lines for `lines(after:)` and,
    /// with a URL, appends every line to that file. The defaults (0, nil) keep and write nothing.
    package func configure(keepLines: Int, fileURL: URL?) {
        let sink = fileURL.map { FileSink(url: $0) }
        lock.lock()
        capacity = max(0, keepLines)
        ring = []
        ring.reserveCapacity(capacity)
        head = 0
        self.sink = sink
        url = fileURL
        lock.unlock()
    }

    /// The log file, if `configure` was given one.
    package var fileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    /// Called on the main queue after new lines arrive, at most once per 100 ms, and only while
    /// set: the Log window sets it while open and pulls `lines(after:)`.
    package var onAppend: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return appendHandler }
        set { lock.lock(); appendHandler = newValue; lock.unlock() }
    }

    /// Records a line that has already gone to stdout. Any thread.
    package func append(_ text: String) {
        lock.lock()
        guard capacity > 0 || sink != nil else { lock.unlock(); return }
        let line = Line(seq: nextSeq, date: Date(), text: text)
        nextSeq += 1
        if capacity > 0 {
            if ring.count < capacity { ring.append(line) } else { ring[head] = line; head = (head + 1) % capacity }
        }
        sink?.write(line)      // only enqueues; under the lock, so the file keeps the ring's order
        let notify = appendHandler != nil && !notifyScheduled
        if notify { notifyScheduled = true }
        lock.unlock()
        if notify {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                lock.lock()
                notifyScheduled = false
                let handler = appendHandler
                lock.unlock()
                handler?()
            }
        }
    }

    /// For code outside SillHostCore (the app shell): printed and recorded like the host's lines.
    package func line(_ text: String) {
        Swift.print(text)
        append(text)
    }

    /// The kept lines newer than `seq`, oldest first; every kept line for 0.
    package func lines(after seq: UInt64) -> [Line] {
        lock.lock(); defer { lock.unlock() }
        let count = ring.count
        guard count > 0 else { return [] }
        let oldest = count < capacity ? 0 : head
        let firstSeq = ring[oldest].seq          // kept lines have consecutive numbers
        let skip = seq < firstSeq ? 0 : Int(min(UInt64(count), seq - firstSeq + 1))
        guard skip < count else { return [] }
        var out: [Line] = []
        out.reserveCapacity(count - skip)
        for i in skip..<count { out.append(ring[(oldest + i) % count]) }
        return out
    }
}

/// The log file. Appends across launches, and moves it aside to Sill.1.log (replacing the
/// previous one) when it is already past 10 MB at launch or passes 10 MB while running: the
/// per-second stats line alone adds about 360 KB per streaming hour. Follow it with `tail -F`,
/// which reopens Sill.log after the move; `tail -f` stays on the moved file and goes quiet.
///
/// Threading: `write` is called from any thread; everything else runs on `queue`, which owns the
/// handle, the size and the formatter.
private final class FileSink: @unchecked Sendable {
    private static let rotateAt: UInt64 = 10_000_000
    private let url: URL
    private let queue = DispatchQueue(label: "sill.log.file", qos: .utility)
    private let stamp: DateFormatter
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(url: URL) {
        self.url = url
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS "
        stamp = f
        queue.async { [self] in open() }
    }

    func write(_ line: HostLog.Line) {
        queue.async { [self] in
            let data = Data((stamp.string(from: line.date) + line.text + "\n").utf8)
            if size + UInt64(data.count) > Self.rotateAt { rotate() }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += UInt64(data.count)
            } catch {
                // A full disk or a deleted directory: the line still reached stdout and the ring.
            }
        }
    }

    /// Queue only.
    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if existing >= Self.rotateAt { moveAside() }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// Queue only.
    private func rotate() {
        try? handle?.close()
        handle = nil
        moveAside()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        size = 0
    }

    /// Sill.log → Sill.1.log, replacing the previous one. Queue only.
    private func moveAside() {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let aside = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }
}

/// Shadows `Swift.print` for every file in SillHostCore, implicitly: the ~90 existing
/// `print(…)` calls and any new one go through here without a change at the call site. Output
/// on stdout is exactly what `Swift.print` would write; then the line is handed to HostLog for
/// the app's Log window and log file (a no-op in the CLI).
///
/// Only this module: an explicit `Swift.print(…)` bypasses it, and the CLI and the app have their
/// own `print` (the app's forwards to `HostLog.shared.line`, see AppLog.swift).
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(text, terminator: terminator)
    HostLog.shared.append(text)
}
