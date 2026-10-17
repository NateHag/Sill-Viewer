import Foundation
import Observation
import ServiceManagement

/// Launch at login, through SMAppService.mainApp. The system's status is the truth and nothing is
/// stored here: the user can switch it off in System Settings › General › Login Items. Re-read
/// when the menu opens and while a pane that shows it is on screen. Never switched on by itself.
///
/// The login item records the bundle's path, so it follows the copy that registered it: keep one
/// copy of Sill, in /Applications (Scripts/make-app.sh --install).
@MainActor @Observable
final class LoginItemModel {
    private(set) var status: SMAppService.Status = .notRegistered
    /// The last register or unregister error, shown inline (never as an alert).
    private(set) var error: String?
    /// SMAppService needs the app bundle; the bare SillMenuBar binary has none.
    let available = Bundle.main.bundleURL.pathExtension == "app"

    /// On, or on and waiting for the user's approval. A never-registered app reports .notFound
    /// (measured), which is simply off: it must not disable the toggle.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        guard available else { return }
        let now = SMAppService.mainApp.status
        if now != status { status = now }
    }

    func set(_ on: Bool) {
        guard available else { return }
        error = nil
        if on {
            do {
                try SMAppService.mainApp.register()
            } catch {
                self.error = error.localizedDescription
                print("Launch at login could not be turned on: \(error.localizedDescription)")
            }
            refresh()
        } else {
            Task { @MainActor in
                do {
                    try await SMAppService.mainApp.unregister()
                } catch {
                    self.error = error.localizedDescription
                    print("Launch at login could not be turned off: \(error.localizedDescription)")
                }
                self.refresh()
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
