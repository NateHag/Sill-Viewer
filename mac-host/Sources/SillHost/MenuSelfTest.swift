import Foundation
import AppKit
import StreamProtocol

/// `--menu-selftest[=APP]` (the CLI's main.swift; Sill.app takes it too, as its other self-tests):
/// the menus a device would be sent for APP, read once each, one level deep, with each read's time
/// (docs/menu-bar-plan.md §4.8). APP is a pid, or the start of a running app's name (any case);
/// without it, the frontmost app. The "=" is needed: a bare second argument is the CLI's window
/// match.
///
/// Read-only: nothing is activated, nothing is pressed. Each menu it reads, the app validates, as
/// if that menu had been opened. Exits 0, or 1 when nothing could be read.
package enum MenuSelfTest {
    /// Nil: the flag is not there. `.some(nil)`: the flag without an app.
    package static func requested(in arguments: [String]) -> String?? {
        guard let flag = arguments.first(where: { $0 == "--menu-selftest" || $0.hasPrefix("--menu-selftest=") }) else { return nil }
        let app = String(flag.dropFirst("--menu-selftest".count).drop { $0 == "=" })
        return .some(app.isEmpty ? nil : app)
    }

    package static func run(app query: String?) -> Never {
        guard let (pid, name, bundleID) = resolve(query) else {
            print("Menu self-test: no running app matches \"\(SafeText.label(query ?? ""))\".")
            exit(1)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        print("Menu self-test: \(name) (\(bundleID ?? "no bundle ID"), pid \(pid)), "
              + (frontmost ? "frontmost." : "not frontmost: states are an inactive app's."))
        let reader = MenuReader()
        let top = reader.queue.sync { reader.topLevel(pid: pid) }
        guard case .success(let got) = top else {
            if case .failure(let f) = top { print("  top level: \(describe(f))") }
            exit(1)
        }
        let menus = got.titles.compactMap { read in MenuFormat.topItem(read.item, index: read.index).map { (read, $0) } }
        print("  top level, \(menus.count) menus in \(ms(got.ms)) ms: " + menus.map { $0.1.title ?? "" }.joined(separator: ", "))
        for (read, menu) in menus {
            guard let path = MenuPath(indexes: [read.index]) else { continue }
            // The bar item just read, under the title just read: nothing is walked (no ancestors).
            let shown = MenuFormat.displayTitle(title: read.item.title, description: nil)
            switch reader.queue.sync(execute: { reader.items(pid: pid, of: read.element, path: path, shown: shown, ancestors: nil) }) {
            case .success(let got):
                let items = got.reads.compactMap { r in path.child(r.index).flatMap { MenuFormat.item(r.item, id: $0.id) } }
                let more = got.unread > 0 ? " | … \(got.unread) more" : ""
                print("  \(read.index) \(menu.title ?? ""), \(items.count) items in \(ms(got.ms)) ms: "
                      + items.map(describe).joined(separator: " | ") + more)
            case .failure(let f):
                print("  \(read.index) \(menu.title ?? ""): \(describe(f))")
            }
        }
        exit(0)
    }

    /// "Save ⌘S", "Open Recent ▸", "Auto Save ✓", "Revert File (off)", "—" for a separator.
    static func describe(_ item: MacMenuItem) -> String {
        if item.separator == true { return "—" }
        var s = item.title ?? ""
        if item.submenu == true { s += " ▸" }
        if let key = item.key { s += " \(key)" }
        if let mark = item.mark { s += " \(mark)" }
        if item.enabled == false { s += " (off)" }
        return s
    }

    private static func describe(_ f: MenuReader.Failure) -> String {
        switch f {
        case .notTrusted: "no Accessibility permission for this process"
        case .noMenuBar: "no menu bar (a background-only app)"
        case .gone: "the app is no longer running"
        case .notAnswering: "no answer within \(String(format: "%.1f", Double(MenuReader.timeout))) s"
        case .failed(let error): "Accessibility error: \(error)"
        case .notShown(let found): "the menu is now \(found.isEmpty ? "untitled" : "“\(found)”")"
        case .moved: "the menu bar changed while it was read"
        case .late: "out of time"
        }
    }

    private static func ms(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func resolve(_ query: String?) -> (pid_t, String, String?)? {
        guard let query, !query.isEmpty else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.localizedName ?? "pid \(app.processIdentifier)", app.bundleIdentifier)
        }
        if let pid = Int32(query), pid > 0 {
            guard MenuReader.alive(pid) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return (pid, app?.localizedName ?? "pid \(pid)", app?.bundleIdentifier)
        }
        let q = query.lowercased()
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.localizedName?.lowercased() == q })
                ?? apps.first(where: { $0.localizedName?.lowercased().hasPrefix(q) == true }) else { return nil }
        return (app.processIdentifier, app.localizedName ?? "pid \(app.processIdentifier)", app.bundleIdentifier)
    }
}
