import AppKit
import SillHostCore

/// The Log window: what the host printed, for an app whose stdout goes nowhere. The last 5,000
/// lines from HostLog's ring, then new ones as they come (HostLog wakes it at most every 100 ms,
/// and only while the window is open). Selectable, ⌘F finds, ⌘C copies. The same lines are in
/// ~/Library/Logs/Sill/Sill.log for `tail -F`.
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private static let keepLines = 5_000
    private let settings: HostSettings
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let statsBox: NSButton
    /// The newest line pulled from HostLog so far.
    private var lastSeq: UInt64 = 0
    /// Clear hides every line up to this one (the view only; the ring and the file keep them).
    private var clearedSeq: UInt64 = 0
    private var shownLines = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(settings: HostSettings) {
        self.settings = settings
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView   // scrollableTextView() always makes one
        statsBox = NSButton(checkboxWithTitle: "Show per-second stats", target: nil, action: nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Sill Log"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.minSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        window.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = font
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.hasVerticalScroller = true

        statsBox.target = self
        statsBox.action = #selector(toggleStats(_:))
        statsBox.state = settings.logShowsStats ? .on : .off
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
        let reveal = NSButton(title: "Reveal Log File", target: self, action: #selector(revealFile(_:)))
        reveal.isEnabled = HostLog.shared.fileURL != nil
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [statsBox, spacer, clear, reveal])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        let content = NSView()
        for v in [scrollView, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // Centred the first time; after that where the user left it.
        if !window.setFrameUsingName("SillLog") { window.center() }
        window.setFrameAutosaveName("SillLog")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Opens the window in front with everything kept so far, then follows new lines.
    func show() {
        guard let window else { return }
        reload()
        HostLog.shared.onAppend = { [weak self] in
            // HostLog calls this on the main queue, which in the app is the main thread.
            MainActor.assumeIsolated { self?.appendNew() }
        }
        WindowPlacement.bringForward(window)
        window.makeFirstResponder(textView)
    }

    func windowWillClose(_ notification: Notification) {
        HostLog.shared.onAppend = nil    // nobody reading: HostLog stops waking the main queue
    }

    // MARK: Lines

    private static func isStats(_ text: String) -> Bool {
        text.hasPrefix("[1s]") || text.hasPrefix("[30s]") || text.hasPrefix("client ")
    }

    private func reload() {
        textView.string = ""
        shownLines = 0
        let lines = HostLog.shared.lines(after: clearedSeq)
        lastSeq = max(lines.last?.seq ?? 0, clearedSeq)
        append(lines, follow: true)
    }

    private func appendNew() {
        let lines = HostLog.shared.lines(after: lastSeq)
        guard let last = lines.last else { return }
        lastSeq = last.seq
        append(lines, follow: false)
    }

    /// Appends in one batch, keeps at most `keepLines`, and scrolls to the end only if the view
    /// was already there (or `follow`), so reading back through the log is never yanked away.
    private func append(_ lines: [HostLog.Line], follow: Bool) {
        let showStats = settings.logShowsStats
        let visible = lines.filter { $0.seq > clearedSeq && (showStats || !Self.isStats($0.text)) }
        guard !visible.isEmpty, let storage = textView.textStorage else { return }
        let atBottom = follow || scrollView.contentView.documentVisibleRect.maxY >= textView.frame.maxY - 4
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let chunk = NSMutableAttributedString()
        for line in visible {
            chunk.append(NSAttributedString(string: stamp.string(from: line.date) + "  ", attributes: dim))
            chunk.append(NSAttributedString(string: line.text + "\n", attributes: body))
        }
        storage.beginEditing()
        storage.append(chunk)
        shownLines += visible.count
        if shownLines > Self.keepLines {
            // Drop the oldest lines: up to the end of the (shownLines - keepLines)th newline.
            let text = storage.string as NSString
            var cut = 0
            for _ in 0..<(shownLines - Self.keepLines) {
                let newline = text.range(of: "\n", options: [], range: NSRange(location: cut, length: text.length - cut))
                guard newline.location != NSNotFound else { break }
                cut = newline.location + 1
            }
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
            shownLines = Self.keepLines
        }
        storage.endEditing()
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    // MARK: Actions

    @objc private func toggleStats(_ sender: NSButton) {
        settings.logShowsStats = sender.state == .on
        reload()
    }

    @objc private func clear(_ sender: Any?) {
        clearedSeq = lastSeq
        textView.string = ""
        shownLines = 0
    }

    @objc private func revealFile(_ sender: Any?) {
        if let url = HostLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
