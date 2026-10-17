import Foundation
import StreamProtocol

/// Which devices this host serves, by the version in their hello (kind 23), and the words and log
/// lines of a refusal (docs/update-notice-plan.md §4). Pure: Foundation and StreamProtocol, checked
/// on its own with swiftc.
///
/// A host whose floor is above "0" judges each device by its first message before it registers it
/// or sends it anything (StreamServer's gate): a hello whose version the floor admits is served; a
/// lower version, no hello at all (a device from before 2026-09-25), any other message first, or
/// nothing within `firstMessageDeadline`, gets kind 22 "update" with this Mac's message and
/// `"reconnect":false`, and is closed. With the floor at "0" (every build so far) nothing waits and
/// nothing new is sent or printed.
package enum DeviceGate {
    /// The oldest Sill for iPhone and iPad this host serves. "0" admits every device, those that send
    /// no hello included. A build constant, never a setting: a floor below what the host needs would
    /// serve a device something it cannot use. Raised only by docs/update-notice-plan.md §4.6: for a
    /// requirement older devices cannot meet (never as a nudge), to a version live on the App Store,
    /// with `SillProtocol.current` when the change cannot be skipped, said in the release notes, and
    /// never lowered again without Noah.
    package static let minimumDeviceVersion = "0"

    /// A refused device's first message must come within this long of `.ready`.
    package static let firstMessageDeadline: TimeInterval = 2
    /// A source refused `loopRefusals` times within `loopWindow` gets each next goodbye `loopDelay`
    /// after its first message: a device from before 2026-09-25 cannot read the notice and redials at
    /// once, and a later one then still sees the message.
    package static let loopRefusals = 5
    package static let loopWindow: TimeInterval = 60
    package static let loopDelay: TimeInterval = 2
    /// After the goodbye and this side's FIN, how long a refused device has to close its side before
    /// the host cancels the connection anyway (StreamServer.closeWithGoodbye).
    package static let closeWait: TimeInterval = 1

    /// The shipped floor as a version (the swiftc check asserts that the constant parses).
    package static var floor: SillVersion { SillVersion(minimumDeviceVersion) ?? .zero }

    /// A device's version: its hello's `appVersion`, else 0 (no hello: a device from before
    /// 2026-09-25; or a version that does not parse).
    package static func version(_ hello: Hello?) -> SillVersion {
        hello?.appVersion.flatMap { SillVersion($0) } ?? .zero
    }

    package static func admits(_ hello: Hello?, floor: SillVersion) -> Bool {
        version(hello) >= floor
    }

    /// Whether the next refusal of a source is slowed, given how many times it was refused within
    /// the last `loopWindow`.
    package static func slows(refusedInWindow count: Int) -> Bool {
        count >= loopRefusals
    }

    /// {"reason":"update", message, "minimumVersion": the floor as SillVersion shows it,
    /// "reconnect":false}.
    package static func refusal(_ hello: Hello?, floor: SillVersion, macName: String) -> Goodbye {
        Goodbye(reason: Goodbye.update, message: message(hello, floor: floor, macName: macName),
                minimumVersion: floor.description, reconnect: false)
    }

    /// "Update Sill on your iPad to keep using Mac mini. It needs version 1.2 or later." The Mac by
    /// its name: on the device's connect screen "this Mac" would read as the device itself.
    package static func message(_ hello: Hello?, floor: SillVersion, macName: String) -> String {
        "Update Sill on your \(deviceWord(hello)) to keep using \(macName). It needs version \(floor) or later."
    }

    /// "iPhone" or "iPad" from the start of the hello's cleaned name, else "device".
    package static func deviceWord(_ hello: Hello?) -> String {
        let name = SafeText.label(hello?.device ?? "")
        if name.hasPrefix("iPhone") { return "iPhone" }
        if name.hasPrefix("iPad") { return "iPad" }
        return "device"
    }

    /// "Refused iPad (iPad14,1) (Sill 1.0): needs 1.2 or later." The device's cleaned name, else
    /// its endpoint; "an older Sill" when it sent no hello (or one that does not decode), "no
    /// version" for a hello without one.
    package static func refusedLine(_ hello: Hello?, endpoint: String, floor: SillVersion) -> String {
        let name = SafeText.label(hello?.device ?? "")
        let what: String
        if let hello {
            let v = SafeText.label(hello.appVersion ?? "", limit: 32)
            what = v.isEmpty ? "no version" : "Sill \(v)"
        } else {
            what = "an older Sill"
        }
        return "Refused \(name.isEmpty ? endpoint : name) (\(what)): needs \(floor) or later."
    }

    /// The refusals of one source after its Refused line, once its minute is up.
    package static func countLine(_ n: Int, source: String, floor: SillVersion) -> String {
        "Refused \(n) more connection\(n == 1 ? "" : "s") from \(source) in the last minute: too old for this Mac (needs \(floor) or later)."
    }

    /// "Client hello: iPad (iPad14,1), Sill 1.0 (42), protocol 1 (192.168.1.23:52344)": the cleaned
    /// name, else the endpoint; the version and build as sent (cleaned), or "no version"; the
    /// protocol when sent; the endpoint in parentheses when a name came first.
    package static func helloLine(_ hello: Hello, endpoint: String) -> String {
        let name = SafeText.label(hello.device ?? "")
        let v = SafeText.label(hello.appVersion ?? "", limit: 32)
        let build = SafeText.label(hello.build ?? "", limit: 32)
        var line = "Client hello: \(name.isEmpty ? endpoint : name), "
        line += v.isEmpty ? "no version" : "Sill \(v)" + (build.isEmpty ? "" : " (\(build))")
        if let p = hello.protocol { line += ", protocol \(p)" }
        if !name.isEmpty { line += " (\(endpoint))" }
        return line
    }
}
