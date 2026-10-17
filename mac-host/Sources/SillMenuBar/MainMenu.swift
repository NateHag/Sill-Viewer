import AppKit

/// The main menu of an app that never shows one. An accessory app (LSUIElement) has no menu bar,
/// but AppKit still routes key equivalents through the main menu, so without this ⌘C, ⌘A, ⌘F,
/// ⌘W and ⌘Q would do nothing in the Settings and Log windows.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let sill = submenu(in: main, title: "Sill")
        sill.addItem(withTitle: "About Sill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        sill.addItem(.separator())
        sill.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        sill.addItem(.separator())
        sill.addItem(withTitle: "Quit Sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        // performFindPanelAction: with the NSFindPanelAction tags, which a text view with a find
        // bar (the Log window) answers.
        let actions: [(String, String, NSFindPanelAction)] = [("Find…", "f", .showFindPanel), ("Find Next", "g", .next),
                                                              ("Find Previous", "G", .previous)]
        for (title, key, tag) in actions {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = Int(tag.rawValue)
        }
        findItem.submenu = find

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }

    @MainActor
    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
