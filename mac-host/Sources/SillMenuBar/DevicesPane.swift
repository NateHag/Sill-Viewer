import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Devices, live: Require pairing, which the model keeps in the identity store beside
/// the trust list (never in UserDefaults), and the paired devices from the host's status (pushed,
/// so nothing polls), with the model's actions.
struct LiveDevicesPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                    requirePairing: Binding(get: { settings.config.requirePairing }, set: { model.setRequirePairing($0) }),
                    requirePairingProblem: model.requirePairingProblem,
                    actions: DevicesPane.Actions(pair: { model.pairDevice() },
                                                 remove: { model.removeDevice($0) },
                                                 rename: { model.renameDevice($0, to: $1) }))
    }
}

/// The Devices pane (docs/home-pairing-plan.md §6.1): Require pairing, and the devices paired with
/// this Mac at home and from afar (one trust list), each with how it paired and how it last
/// connected, Remove, rename and Pair iPhone or iPad…. Values in, actions out, so the previews can
/// draw every state. Errors show inline, never in alerts.
struct DevicesPane: View {
    struct Actions {
        var pair: () -> Void = {}
        /// Nil when the device was removed; otherwise why it is still paired.
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
    }

    let status: RemoteStatus
    @Binding var requirePairing: Bool
    /// The last Require pairing change the identity store did not keep.
    var requirePairingProblem: AppModel.RequirePairingProblem?
    let actions: Actions
    /// "Last connected 2 minutes ago" counts from here (fixed in the previews).
    var now: Date?

    @State private var removedName: String?
    /// A Remove the keychain did not keep: the device's name and why.
    @State private var removeProblem: (name: String, reason: String)?

    /// Why devices can't connect at all: the identity (the key, the trust list) could not be used,
    /// so the home door has no listener. Nil when it works.
    private var unavailable: String? {
        if let problem = status.identityProblem { return problem }
        if case .unavailable(let why) = status.homeDoor { return why }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Require pairing", isOn: $requirePairing)
                    .disabled(unavailable != nil)
                if let problem = unavailable {
                    Warning("Devices can’t connect: Sill couldn’t use its key in your keychain (\(withoutFullStop(problem))). Quit Sill and open it again, and choose Always Allow if the keychain asks.")
                } else if let p = requirePairingProblem {
                    let reason = withoutFullStop(p.reason)
                    Warning(p.wanted
                            ? "Pairing is required until Sill quits: Sill couldn’t update the keychain (\(reason)). Try again."
                            : "Pairing is still required: Sill couldn’t update the keychain (\(reason)). Try again.")
                }
            } footer: {
                if requirePairing {
                    Footnote("Each iPhone or iPad pairs once: over the USB cable by itself, or on Wi\u{2011}Fi with a code this Mac shows when the device asks. Everything devices send and receive is encrypted.")
                } else {
                    Label("Any device on your network (or nearby, with Direct Wireless Connection on) and any app on this Mac can see and control it without pairing. Connections are still encrypted.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            pairedDevices
        }
    }

    private var pairedDevices: some View {
        Section {
            if let removedName {
                Text("\(removedName) can no longer connect. To use it again, pair it again.")
            }
            if let removeProblem {
                Warning("\(removeProblem.name) is still paired: Sill couldn’t update the keychain (\(withoutFullStop(removeProblem.reason))). Try again.")
            }
            if unavailable != nil {
                // The trust list lives with the key: unread, not empty.
                Text("Your paired devices show here once Sill can use its key again.").foregroundStyle(.secondary)
            } else if status.paired.isEmpty {
                Text("No paired devices yet.").foregroundStyle(.secondary)
            }
            ForEach(status.paired) { device in
                PairedDeviceRow(device: device, now: now,
                                remove: {
                                    // Said only once the keychain kept it: otherwise the device
                                    // would be trusted again at the next launch.
                                    if let reason = actions.remove(device.id) {
                                        removedName = nil
                                        removeProblem = (device.name, reason)
                                    } else {
                                        removedName = device.name
                                        removeProblem = nil
                                    }
                                },
                                rename: { actions.rename(device.id, $0) })
            }
            Button("Pair iPhone or iPad…") { actions.pair() }
                .disabled(unavailable != nil)
        } header: {
            Text("Paired Devices")
        } footer: {
            Footnote("A paired device can see and control this Mac on your network, nearby, and from afar while Remote Access is on. If one is lost, remove it here.")
        }
    }
}

/// One paired device: its name (double-click to rename: Return saves, Esc cancels), how it paired,
/// when and how it last connected (at home or from away), and Remove, with no confirmation since
/// it only takes access away.
struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let now: Date?
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            Button("Remove", action: remove)
        } label: {
            if editing {
                TextField("Name", text: $text)
                    .focused($focused)
                    .onSubmit {
                        rename(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(device.name)
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityAction(named: "Rename") { startEditing() }
            }
            Text(Self.detail(device, now: now ?? Date()))
        }
    }

    private func startEditing() {
        text = device.name
        editing = true
        focused = true
    }

    /// "Paired Sep 25 over the USB cable · last connected 2 minutes ago over Wi‑Fi", "Paired Sep 24
    /// with the QR code · last connected yesterday through Tailscale".
    static func detail(_ device: PairedDeviceSummary, now: Date) -> String {
        var out = "Paired \(day(device.pairedAt, now: now))"
        if let method = device.displayMethod { out += " \(method)" }
        if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            let when = now.timeIntervalSince(seen) < 60 ? "just now" : formatter.localizedString(for: seen, relativeTo: now)
            out += " · last connected \(when)"
            if let route = device.lastRoute { out += " \(route)" }
        }
        return out
    }

    static func day(_ date: Date, now: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
