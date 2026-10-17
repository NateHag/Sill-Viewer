import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a grouped Form, 520 pt wide. The controls bind straight to
/// `settings.config`, whose didSet is the one path to the host (see HostSettings).
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel
    /// The previews (DebugHooks): General's update section in this state instead of the live one,
    /// so a render does not depend on what an earlier run stored.
    var previewUpdates: UpdatePolicy.Pane?
    /// …and its clipboard section with macOS's answer as given, never read from this Mac.
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model, settings: model.settings, previewUpdates: previewUpdates,
                                       previewClipboardAccess: previewClipboardAccess)
            case .devices: LiveDevicesPane(model: model, settings: model.settings)
            case .streaming: StreamingPane(model: model, settings: model.settings)
            case .virtualDisplay: VirtualDisplayPane(model: model, settings: model.settings)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        // Permissions and the login item change behind Sill's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when Sill becomes active; an
        // idle Sill with Settings closed wakes for nothing. The Devices and Remote Access panes
        // follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            guard model.visibleSettingsTab == tab, tab != .streaming, tab != .devices, tab != .remoteAccess else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    var previewUpdates: UpdatePolicy.Pane?
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    private static let runsFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if !model.loginItem.available {
                    Footnote("Available when Sill runs from its app bundle.")
                } else if model.loginItem.needsApproval {
                    LabeledContent("Waiting for your approval") {
                        Button("Approve in System Settings…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Running from") {
                    Text(Bundle.main.bundlePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !Self.runsFromApplications {
                    Label("The login item and the permissions follow this copy of Sill. Keep one copy, in Applications.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("Visible on your network as") { Text(networkName) }
            } footer: {
                HStack(spacing: 4) {
                    Text("This is the Mac’s name.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Change It in Sharing Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                    Spacer(minLength: 0)
                }
            }
            // How devices reach this Mac, so beside its name on the network. Applies at once without
            // restarting the stream (the listener is replaced); enabled in test pattern mode too,
            // where it is saved and changes only the listener.
            Section {
                Toggle("Direct wireless connection", isOn: $settings.config.directWireless)
            } footer: {
                Footnote("Lets your iPhone and iPad connect when they’re near this Mac, even without a shared Wi\u{2011}Fi network, the way AirDrop does. While it’s on, this Mac’s Wi\u{2011}Fi keeps stepping away from your network, so streaming over Wi\u{2011}Fi can stutter. Anyone nearby with Sill can find this Mac; only devices you paired can connect, unless Require pairing is off.")
            }
            // The clipboard both ways (HostClipboard): at once, no restart. Each device has its own
            // switch too. macOS's answer is read with the permissions (once a second while this pane
            // shows, and when Sill becomes active), never in a preview.
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            Section {
                HStack {
                    Button("Show Log…") { model.showLog?() }
                    Button("Reveal Log File") {
                        if let url = HostLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(HostLog.shared.fileURL == nil)
                }
            }
            Section {
                // A way out when the status item is hidden (a crowded menu bar, the notch).
                Button("Quit Sill") { NSApp.terminate(nil) }
            } footer: {
                Footnote("Sill \(AppModel.version) (\(AppModel.build)). Free and open source.")
            }
        }
    }

    private var networkName: String {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        switch snapshot.network {
        case .advertising(let name): return "“\(name)”"
        case .notAdvertised: return "Not advertised (test pattern mode)"
        case .failed: return "Not visible (the listener failed)"
        case .waiting: return "Not yet (waiting for the network)"
        case .starting, .registering: return "Registering…"
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read Sill makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("Share clipboard with devices", isOn: $shareClipboard)
            if shareClipboard, let warning = ClipboardPolicy.Copy.macAccessWarning(access) {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(warning)
                    if let hint = ClipboardPolicy.Copy.macAccessHint(access) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(ClipboardPolicy.Copy.macAccessButton, action: allow)
                }
            }
        } footer: {
            Footnote(ClipboardPolicy.Copy.macFootnote)
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why Sill cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("Open Release Page…") { actions.openRelease(url) }
                    }
                    Button("Check Now") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Streaming

private struct StreamingPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        Form {
            Section {
                Picker("Frame rate limit", selection: $settings.config.maxFPS) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                Picker("Quality", selection: $settings.config.bitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.bitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.bitrate)).tag(settings.config.bitrate)
                    }
                }
                Picker("Resolution", selection: $settings.config.captureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("Standard").tag(CGFloat(1))
                }
            } footer: {
                Footnote("Each device asks for its own screen’s rate, up to this limit. Quality is per 60 fps; a 120 fps stream gets twice as much. \(QualityPreset.fastLinkNote) Changes apply at once: the current stream restarts for a moment.")
            }
            // Away from home (docs/remote-bundle-plan.md §5): its own quality, which a device away
            // sets too; the menu's Quality and Resolution stay the home ones.
            Section {
                Picker("Quality", selection: $settings.config.awayBitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.awayBitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.awayBitrate)).tag(settings.config.awayBitrate)
                    }
                }
                Picker("Resolution", selection: $settings.config.awayCaptureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("Standard").tag(CGFloat(1))
                }
            } header: {
                Text("Away from home")
            } footer: {
                Footnote("Sill streams at these while every connected device is away from home, through a VPN or over the internet, so a slow connection never starts at your home quality. A device away from home changes these, and never your Quality and Resolution above."
                         + (model.coordinator?.status.snapshot.away == true ? " Streaming at these now." : ""))
            }
            Section {
                Toggle("Prioritize encoding speed", isOn: $settings.config.prioritizeSpeed)
            } footer: {
                Footnote("Lower latency when the Mac is busy, at a softer picture.")
            }
            if let snapshot = model.coordinator?.status.snapshot, snapshot.softwareEncoder {
                Section {
                    Label(snapshot.hardwareEncoderStuck
                          ? "The hardware encoder is stuck, so streams use the software encoder: up to 60 fps at Standard resolution. Restarting the Mac fixes this."
                          : "The hardware encoder is busy or not answering, so streams use the software encoder: up to 60 fps at Standard resolution. Sill switches back by itself once it keeps up again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Virtual Display

private struct VirtualDisplayPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    @State private var retrying = false

    var body: some View {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        Form {
            Section {
                Toggle("Stream from a virtual display", isOn: $settings.config.virtualDisplay)
            } footer: {
                Footnote("Sill moves the window you pick onto an invisible display made for your device, so it keeps updating when other windows cover it and text is drawn at your device’s scale. The window leaves this screen while it streams and comes back when you stop streaming or quit Sill.")
            }
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(statusText(snapshot))
                            .multilineTextAlignment(.trailing)
                        if canRetry(snapshot) {
                            Button("Try Again") {
                                retrying = true
                                Task { @MainActor in
                                    await model.coordinator?.retryVirtualDisplay()
                                    retrying = false
                                }
                            }
                            .disabled(retrying || model.coordinator == nil)
                        }
                    }
                }
                if settings.config.virtualDisplay, let failure = snapshot.lastStageFailure {
                    LabeledContent("Last window") {
                        Text("Streamed where it is: \(failure)").multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Footnote("Uses a private macOS interface (CGVirtualDisplay). If a macOS update breaks it, Sill streams the window where it is.")
            }
        }
    }

    private func statusText(_ s: HostStatusSnapshot) -> String {
        let sr = model.permissions.screenRecording, ax = model.permissions.accessibility
        if s.virtualDisplayAPIMissing, let problem = s.virtualDisplayProblem {
            return "Not available on this version of macOS: \(problem)"
        }
        if !sr && !ax { return "Needs Screen Recording and Accessibility" }
        if !ax { return "Needs Accessibility" }
        if !sr { return "Needs Screen Recording" }
        if let problem = s.virtualDisplayProblem { return "Off for this session: \(problem)" }
        return "Available"
    }

    /// A run-level disable (the system removed the display too often) can be retried; a missing
    /// API or permission cannot.
    private func canRetry(_ s: HostStatusSnapshot) -> Bool {
        s.virtualDisplayProblem != nil && !s.virtualDisplayAPIMissing && model.permissions.allGranted
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(title: "Screen Recording", allowed: permissions.screenRecording,
                              // Not "on this network": a device connected over Direct Wireless shares none.
                              explanation: "Lets Sill capture the windows you pick on your iPhone or iPad. Nothing is recorded or saved; frames go straight to your devices.",
                              button: model.settings.askedScreenRecording ? "Open System Settings…" : "Allow…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(title: "Accessibility", allowed: permissions.accessibility,
                              explanation: "Lets your iPhone or iPad click, scroll and type on this Mac, and lets Sill move and size the window it streams.",
                              button: model.settings.askedAccessibility ? "Open System Settings…" : "Allow…") {
                    permissions.requestAccessibility()
                }
            } footer: {
                Footnote("Access belongs to Sill itself. Access you gave Terminal for the SillHost command-line tool doesn’t carry over.")
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("Screen Recording starts working once Sill opens again.") {
                        Button(permissions.canRelaunch ? "Relaunch Sill" : "Quit Sill") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("Open Local Network…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("Local Network")
                        Text("If your iPhone or iPad can’t find this Mac, allow Sill in Privacy & Security › Local Network.")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("You’re all set. Open Sill on your iPhone or iPad.", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let explanation: String
    let button: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(button, action: action)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}
