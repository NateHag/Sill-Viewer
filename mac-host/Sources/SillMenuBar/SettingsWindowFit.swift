import CoreGraphics

/// How tall the Settings window may be on a screen, and where it goes when Sill changes its size
/// (issue #59, docs/settings-window-plan.md). AppKit makes the window as tall as the selected pane's
/// whole content; SettingsWindowController caps it with one constraint whose constant is
/// `contentLimit`, and the pane, a grouped Form, scrolls. Pure (CoreGraphics only), so
/// Tests/checks/settings-window can list the cases.
enum SettingsWindowFit {
    /// Kept clear between a capped or moved window and the top and bottom of the visible frame (the
    /// menu bar above; the Dock, or the screen's edge, below).
    static let margin: CGFloat = 12
    /// The least height a pane is given, however short the screen: the window then runs off the
    /// screen's bottom rather than show next to nothing.
    static let minimumContent: CGFloat = 200

    /// A screen as the window controller reads it from NSScreen.
    struct Screen: Equatable {
        /// NSScreen.visibleFrame: under the menu bar and beside the Dock, in global coordinates.
        var visible: CGRect
        /// Sill's own virtual display, where a streamed window lives, off the user's screens.
        var sillVirtual: Bool
    }

    /// The screen whose visible frame bounds the window: the one it is on (`windowOn`, an index into
    /// `screens`); on none, or on Sill's virtual display, the first other screen, the one
    /// WindowPlacement.bringForward moves it to. Nil with no other screen.
    static func screenIndex(windowOn: Int?, screens: [Screen]) -> Int? {
        if let i = windowOn, screens.indices.contains(i), !screens[i].sillVirtual { return i }
        return screens.firstIndex { !$0.sillVirtual }
    }

    /// The visible frame the cap and the move use: the screen's own or, TEST ONLY
    /// (-SillTestScreenHeight), its top `testHeight` points, as if the screen ended there with the
    /// Dock at its bottom. A test height that is not positive, or not shorter than the screen's, is
    /// no test.
    static func visible(_ real: CGRect, testHeight: CGFloat?) -> CGRect {
        guard let h = testHeight, h > 0, h < real.height else { return real }
        return CGRect(x: real.minX, y: real.maxY - h, width: real.width, height: h)
    }

    /// The tallest content (the pane, under the title bar and the toolbar) for a window whose frame is
    /// `chrome` points taller than its content, keeping `margin` clear above and below it in
    /// `visible`: whole points, never under `minimumContent`.
    static func contentLimit(visible: CGRect, chrome: CGFloat) -> CGFloat {
        max(minimumContent, (visible.height - chrome - 2 * margin).rounded(.down))
    }

    /// Where a window with `frame` goes in `visible`, top to bottom only: unchanged while it lies
    /// inside it. Its bottom below the visible frame: moved up to `margin` above its bottom, or as far
    /// as keeps its top inside. Its top above the visible frame: moved down to `margin` under its top,
    /// or as far as keeps its bottom inside. Taller than the visible frame: its top at the top, so
    /// the title bar can be reached. Never resized, never moved sideways.
    static func placed(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var y = frame.minY
        if frame.height > visible.height {
            y = visible.maxY - frame.height
        } else if frame.minY < visible.minY {
            y = min(visible.minY + margin, visible.maxY - frame.height)
        } else if frame.maxY > visible.maxY {
            y = max(visible.maxY - margin - frame.height, visible.minY)
        }
        return CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }
}
