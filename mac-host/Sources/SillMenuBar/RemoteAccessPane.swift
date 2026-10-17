import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Remote Access, live: the host's remote status (pushed, so nothing polls) and the
/// app's settings, with the model's actions.
struct LiveRemoteAccessPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        RemoteAccessPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                         remoteAccess: $settings.config.remoteAccess,
                         internetAccess: $settings.config.internetAccess,
                         port: settings.config.remotePort,
                         addressName: settings.remoteAddressName,
                         actions: RemoteAccessPane.Actions(
                             setPort: { settings.config.remotePort = $0 },
                             setAddressName: { settings.remoteAddressName = $0 },
                             showDevices: { model.showSettings?(.devices) }))
    }
}

/// The Remote Access pane (docs/remote-access-plan.md §6.1): the switch, the Mac's addresses and
/// its port, how many devices are paired (the list itself is in Settings › Devices,
/// docs/home-pairing-plan.md §6.2), the internet switch, and sleep. Values in, actions out, so the
/// previews can draw every state. Errors show inline, never in alerts.
struct RemoteAccessPane: View {
    struct Actions {
        var setPort: (Int) -> Void = { _ in }
        var setAddressName: (String) -> Void = { _ in }
        /// Show Devices…: Settings on the Devices tab.
        var showDevices: () -> Void = {}
    }

    let status: RemoteStatus
    @Binding var remoteAccess: Bool
    @Binding var internetAccess: Bool
    /// The configured port (the app's is never 0).
    let port: Int
    /// The address name setting, as saved.
    let addressName: String
    let actions: Actions

    @State private var editingPort = false
    @State private var portText = ""
    @State private var portSaved = false
    @State private var nameText: String?
    @State private var nameProblem: String?

    private var available: Bool { status.identityProblem == nil }
    private var on: Bool { remoteAccess && available }

    var body: some View {
        Form {
            Section {
                Toggle("Remote access", isOn: $remoteAccess)
                    .disabled(!available)
                if let problem = status.identityProblem {
                    // The system's messages end with a full stop of their own.
                    let reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
                    Warning("Remote access isn’t available: Sill couldn’t use the keychain (\(reason)).")
                }
            } footer: {
                Footnote("Lets the iPhone and iPad you pair connect to this Mac from other networks: through a VPN such as Tailscale, or through a port you forward on your router. Sill turns away every device you haven’t paired, and encrypts everything the paired ones send and receive.")
            }
            if on { addresses }
            pairedDevices
            if on { internet }
            Section {
                LabeledContent {
                    Button("Open Energy Settings…") { Self.openEnergySettings() }
                } label: {
                    Text("Sleep")
                    Text("This Mac can’t be reached while it’s asleep. While a device is connected from away, Sill keeps it from going to sleep by itself.")
                }
            }
        }
    }

    // MARK: Addresses

    @ViewBuilder private var addresses: some View {
        let rows = Self.addressRows(status.addresses)
        Section {
            switch status.listener {
            case .portInUse(let p):
                LabeledContent {
                    Button("Change…") { startEditingPort() }
                } label: {
                    Warning("Port \(p) is in use by another app, so devices can’t reach this Mac remotely. Sill tries again every 30 seconds.")
                }
            case .failed(let error):
                Warning("Remote access couldn’t start (\(error)). Sill tries again every 30 seconds.")
            case .off, .listening:
                EmptyView()
            }
            ForEach(rows) { row in
                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.primary).textSelection(.enabled)
                            if !row.others.isEmpty {
                                Text(row.others.joined(separator: " · "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        CopyButton(text: row.primary, spoken: "Copy the \(row.label) address")
                    }
                } label: {
                    Text(row.label)
                    if row.lan {
                        Text("This network. Use it with a VPN into your home network, such as WireGuard on your router.")
                    }
                }
            }
            ForEach(status.vpnDown, id: \.self) { name in
                Text("\(name) — Not connected").foregroundStyle(.secondary)
            }
            if !rows.contains(where: { $0.vpn }) && status.vpnDown.isEmpty {
                Text("No VPN is running on this Mac. Install one such as Tailscale on this Mac and on your iPhone or iPad, or allow connections from the internet below.")
                    .foregroundStyle(.secondary)
            }
            portRow
        } header: {
            Text("Addresses")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(status.vpnDown, id: \.self) { name in
                    Footnote("Your devices can’t reach this Mac through \(name) until it connects.")
                }
                Footnote("Your devices learn these when they pair and keep them current whenever they connect.")
            }
        }
    }

    @ViewBuilder private var portRow: some View {
        if editingPort {
            let problem = Self.portProblem(portText)
            LabeledContent("Port") {
                HStack(spacing: 8) {
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { savePort() }
                        .onExitCommand { editingPort = false }
                    Button("Save") { savePort() }
                        .disabled(problem?.blocks ?? false)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { editingPort = false }
                }
            }
            if let problem {
                if problem.blocks { Warning(problem.message) } else { Text(problem.message).foregroundStyle(.secondary) }
            }
        } else {
            LabeledContent("Port") {
                HStack(spacing: 8) {
                    Text(String(port)).monospacedDigit().textSelection(.enabled)
                    Button("Change…") { startEditingPort() }
                }
            }
            if portSaved {
                Text("Paired devices learn the new port the next time they connect at home.").foregroundStyle(.secondary)
            }
        }
    }

    private func startEditingPort() {
        portText = String(port)
        portSaved = false
        editingPort = true
    }

    private func savePort() {
        if let problem = Self.portProblem(portText), problem.blocks { return }
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        editingPort = false
        if p != port {
            actions.setPort(p)
            portSaved = true
        }
    }

    /// What is wrong with a port typed into the field: blocking (it cannot be saved), or only a
    /// warning. Nil when it is fine.
    static func portProblem(_ text: String) -> (message: String, blocks: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), t.count <= 5, let p = Int(t), (1024...65535).contains(p) else {
            return ("Choose a port from 1024 to 65535.", true)
        }
        if p == 5000 || p == 7000 { return ("Port \(p) belongs to AirPlay Receiver. Choose another.", true) }
        if p >= 49152 { return ("Ports from 49152 up can be taken by any app at any moment.", false) }
        return nil
    }

    // MARK: Paired devices

    /// One row: the list, Remove and Pair iPhone or iPad… are in Settings › Devices, since the same
    /// devices connect at home too.
    private var pairedDevices: some View {
        Section {
            LabeledContent("Paired devices") {
                HStack(spacing: 8) {
                    Text(status.paired.isEmpty ? "None" : "\(status.paired.count)").monospacedDigit()
                    Button("Show Devices…") { actions.showDevices() }
                }
            }
        } footer: {
            Footnote("The devices you pair in Devices can connect from afar while Remote Access is on.")
        }
    }

    // MARK: Internet

    private var internet: some View {
        Section {
            Toggle("Allow connections from the internet", isOn: $internetAccess)
            if internetAccess {
                if let lan = status.lanAddress {
                    LabeledContent {
                        CopyButton(text: lan, spoken: "Copy this Mac’s address")
                    } label: {
                        Text("Forward TCP port \(String(port)) on your router to this Mac (\(lan)), and reserve that address for this Mac in the router’s settings.")
                    }
                }
                routerRow
                addressNameRow
                if let v6 = status.addresses.first(where: { $0.kind == MacAddress.internet && $0.via == "IPv6" }) {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(v6.host).textSelection(.enabled)
                            CopyButton(text: v6.host, spoken: "Copy the IPv6 address")
                        }
                    } label: {
                        Text("IPv6")
                        Text("Works only if your router lets incoming IPv6 connections reach this Mac; most don’t.")
                    }
                }
            }
        } header: {
            Text("Internet")
        } footer: {
            if internetAccess {
                Footnote("Anyone on the internet can now reach port \(String(port)) and try to connect. Sill turns away every device you haven’t paired. Turning this off doesn’t close the port on your router: remove the forward there too.")
            } else {
                Footnote("Only needed for a port forward on your router. A VPN is simpler and keeps this Mac off the open internet.")
            }
        }
    }

    @ViewBuilder private var routerRow: some View {
        switch status.router {
        case .off:
            EmptyView()
        case .asking:
            LabeledContent("Router’s internet address") { Text("Asking your router…").foregroundStyle(.secondary) }
        case .address(let a):
            LabeledContent("Router’s internet address") {
                HStack(spacing: 8) {
                    Text(a).textSelection(.enabled)
                    CopyButton(text: a, spoken: "Copy the router’s internet address")
                }
            }
        case .carrierNAT(let a):
            LabeledContent("Router’s internet address") {
                Warning("Your internet provider shares this address among many homes (\(Self.masked(a))), so a port forward can’t reach this Mac. Use a VPN such as Tailscale instead.")
            }
        case .doubleNAT:
            LabeledContent("Router’s internet address") {
                Warning("Your router sits behind another router. Forward the port on both, or use a VPN.")
            }
        case .noAnswer:
            LabeledContent("Router’s internet address") {
                Text("Your router didn’t say. You’ll find the address in its settings.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var addressNameRow: some View {
        LabeledContent {
            TextField("Address name", text: Binding(get: { nameText ?? addressName }, set: { nameText = $0; nameProblem = nil }),
                      prompt: Text("home.example.net"))
                .labelsHidden()
                .frame(width: 220)
                .onSubmit { saveAddressName() }
        } label: {
            Text("Address name (optional)")
            Text("If your router has a dynamic DNS name, enter it so your devices keep finding this Mac when your internet address changes. Add :port if the router forwards a different outside port.")
        }
        if let nameProblem { Warning(nameProblem) }
    }

    private func saveAddressName() {
        let text = (nameText ?? addressName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { nameProblem = nil; actions.setAddressName(""); return }
        switch AddressParser.parse(text) {
        case .success:
            nameProblem = nil
            actions.setAddressName(text)
        case .failure(.zone):
            nameProblem = "Remove the part after %: it only works on this network."
        case .failure:
            nameProblem = "That doesn’t look like an address. Try home.example.net, or home.example.net:17455."
        }
    }

    // MARK: Helpers

    /// One row per way in: the service's name, the name devices dial first (a MagicDNS name) and
    /// the addresses behind it. Internet addresses have their own section.
    struct AddressRow: Identifiable {
        var id: String { label }
        var label: String
        var primary: String
        var others: [String]
        var vpn: Bool
        var lan: Bool
    }

    static func addressRows(_ addresses: [MacAddress]) -> [AddressRow] {
        var order: [String] = []
        var byVia: [String: [MacAddress]] = [:]
        for a in addresses where a.kind != MacAddress.internet {
            if byVia[a.via] == nil { order.append(a.via) }
            byVia[a.via, default: []].append(a)
        }
        return order.compactMap { via in
            guard let list = byVia[via] else { return nil }
            let isName: (MacAddress) -> Bool = { a in
                if case .success(let p) = AddressParser.parse(a.host) { return p.kind == .name }
                return false
            }
            let sorted = list.filter(isName) + list.filter { !isName($0) }
            guard let first = sorted.first else { return nil }
            return AddressRow(label: via, primary: first.host, others: sorted.dropFirst().map(\.host),
                              vpn: list.contains { $0.kind == MacAddress.vpn },
                              lan: list.allSatisfy { $0.kind == MacAddress.lan } && via != "This Mac")
        }
    }

    /// "100.72.x.x": a shared carrier address says nothing useful beyond its first half.
    static func masked(_ address: String) -> String {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return address }
        return "\(parts[0]).\(parts[1]).x.x"
    }

    /// Battery on a laptop, Energy on a desktop: one System Settings extension on macOS 27
    /// (/System/Library/ExtensionKit/Extensions/PowerPreferences.appex).
    static func openEnergySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Copy, then "Copied" for 1.5 s.
private struct CopyButton: View {
    let text: String
    let spoken: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .accessibilityLabel(copied ? "Copied" : spoken)
    }
}
