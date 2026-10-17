import Foundation

/// Wire format shared by the Mac host and the iOS client.
/// Header (14 bytes, big endian): kind(1) timestamp(8, Double) isKeyframe(1) payloadLength(4)
public enum StreamMessageKind: UInt8 {
    // Host → client: video
    case parameterSets = 0   // payload: ParameterSets.encoded()
    case frame = 1           // payload: one HEVC access unit, length-prefixed NALs (hvcC style)
    // Host → client: window switcher catalog (see Switcher.swift)
    case windowList = 2      // JSON WindowList; sent on connect and whenever windows or the active source change
    case thumbnail = 3       // ImageBlob: windowID(4) + JPEG, refreshed every second or two per window
    case appIcon = 4         // ImageBlob: bundleID + PNG, once per app
    case appList = 5         // JSON [AppInfo]: installed apps for the drawer's "All apps"
    // Client → host
    case selectSource = 6    // JSON StreamSource: what to stream
    case launchApp = 7       // JSON LaunchApp: open an installed app; its first window gets selected
    case input = 8           // JSON InputEvent: pointer, scroll, text or key aimed at the streamed source (see Input.swift)
    case viewport = 9        // JSON Viewport: the client's stream panel size and wanted scale (see Viewport.swift)
    case ping = 10           // client → host: 8 bytes, client clock (Double, BE) — echoed back as pong for RTT
    case pong = 11           // host → client: the ping payload, unchanged
    case clientStats = 12    // client → host: JSON ClientStats once a second, so the host log shows the far end
    case tick = 13           // host → client, empty: keeps the device's Wi-Fi radio out of power save while a
                             // session is live (an idle downlink dozes and every next packet waits up to ~300 ms)
    case cursorShape = 14    // host → client: CursorShapeBlob, the Mac's current cursor image, whenever it changes
    case windowCommand = 15  // client → host: JSON WindowCommand — close, minimize or full-screen a window (the bar's long-press menu)
    case hostSettings = 16   // host → client: JSON HostSettingsState (see HostSettings.swift) — the settings as the Mac's menu
                             // shows them and what this host allows; on connect (right after the window list), whenever it
                             // changes, and with `answering` set as the reply to one device's changeSettings
    case changeSettings = 17 // client → host: JSON HostSettingsChange — only the fields one control changed, plus a token.
                             // No ack kind, no "send me the state" kind, no version check for settings (a kind 16 on the
                             // connection says the host has them): the answer is a hostSettings sent to that device alone
    // Remote access (Remote.swift, Pairing.swift). Older readers map all five to `.unknown` and skip them.
    case macInfo = 18        // host → device: JSON SignedMacInfo — who this Mac is and how to reach it from afar, signed
                             // with its identity key. In the catalog right after kind 16, on both doors, and again whenever
                             // it changes. Only from a host with an identity (Sill.app always; SillHost with --remote)
    case pairRequest = 19    // device → host: JSON PairRequest — the one message of a pairing connection (ALPN sill-pair/1),
                             // at most `maxPairingPayload` bytes, within 10 s of the connection
    case pairResult = 20     // host → device: JSON PairResult — the answer to 19; the host then closes the connection
    case pairingWanted = 21  // device → host, empty payload: "show your pairing code" (Pair This iPad…). Home door only,
                             // from this Mac's own networks, at most once per 30 s per connection; ignored elsewhere
    case goodbye = 22        // host → device: JSON Goodbye — why the host is about to close this session, and
                             // what the device should do then (a message to show, whether to reconnect)
    // Compatibility (Compatibility.swift). Older hosts map it to `.unknown` and skip it.
    case hello = 23          // device → host: JSON Hello — who the device is (its version, build, protocol and
                             // name). The first message of every session connection, before anything else, so a
                             // host can judge the device before it sends anything (DeviceGate). Never on a
                             // pairing connection
    // The Mac's menus (MacMenu.swift): 24, 25 and 27, around the pointer's 26. Older readers map all three
    // to `.unknown` and skip them.
    case macMenu = 24        // host → device: JSON MacMenu — the streamed app's menu bar (the Desktop's: the frontmost
                             // app's), to a device that asked for it with a kind 27 without an id: its top level then, and
                             // again whenever the app or its titles change. With `answering` set: the reply to one of
                             // that device's kind 27s (one menu's items) or kind 25s
    case pressMenuItem = 25  // device → host: JSON PressMenuItem — choose one item, by the id and title the device was
                             // shown in that tree version. Answered to that device alone (a kind 24 with `pressed`)
    // The Mac's pointer (Pointer.swift), between the menus' kinds: 24 and 25 were the menus', whose third kind is
    // 27. Older readers map it to `.unknown` and skip it.
    case macPointer = 26     // host → device: JSON MacPointer — where the Mac's pointer is while this device is not the
                             // one moving it (the Mac's own mouse, or another device). Only when it changed, at most once
                             // per sample per device: each 30 ms tick, and at the stream's frame rate while it moves
    case fetchMenu = 27      // device → host: JSON FetchMenu — one menu's current items, asked when the device opens it,
                             // with the title it showed for that menu; without an id, the top level, and a request for
                             // every later one on this connection. Answered to that device alone, from a read of at
                             // most 1 s ago
    // Trackpad gestures (Gesture.swift), after the menus' 24, 25 and 27. Older hosts map it to `.unknown` and
    // skip it.
    case gesture = 28        // device → host: JSON TrackpadGesture — a three- or four-finger gesture the device
                             // recognized, which the Mac turns into its own shortcut (Mission Control, a Space,
                             // Apps…). Only to a host whose window list says `gestures` 1 or more
    // The clipboard (Clipboard.swift, ClipboardPolicy.swift), after the gesture's 28: 29 is the audio
    // plan's, 30 and 31 the Mac client's side streams (pull request #66, which shares this number and
    // shape). Older readers map it to `.unknown` and skip it.
    case clipboard = 32      // both ways: JSON Clipboard. Device → host: any kind 32 subscribes the connection to
                             // the Mac's copies (an empty one at connect, while the device's Share Clipboard is
                             // on), its text becomes the Mac's clipboard, and `stop` ends the subscription; only
                             // to a host whose window list says `clipboard` 1 or more. Host → device: text copied
                             // on the Mac (or sent by another device), only to a connection that subscribed
    case unknown = 255       // never sent: what parseHeader yields for a kind this build does not know
}

public struct StreamHeader {
    public let kind: StreamMessageKind
    public let timestamp: Double      // host wall clock, seconds since 1970 (approximate cross-device)
    public let isKeyframe: Bool
    public let payloadLength: Int
}

public struct StreamMessage {
    public static let headerLength = 14

    // Caps on what a header may announce. The length field allows 4 GiB, and a reader that simply
    // waits for the announced bytes can be held (or fed an SSH banner that parses as a 1.7 GB
    // payload), so each side refuses more than it could ever legitimately receive and closes.
    /// Any client → host message, on both doors. The largest real one is a few hundred bytes.
    public static let maxClientPayload = 1 << 20
    /// The one message of a pairing connection (kind 19).
    public static let maxPairingPayload = 4096
    /// A video frame, as a device accepts it (a Retina keyframe is 1–2 MB).
    public static let maxFramePayload = 32 << 20
    /// Any other host → device message (window lists, icons, thumbnails, the app list).
    public static let maxOtherHostPayload = 4 << 20

    public var kind: StreamMessageKind
    public var timestamp: Double
    public var isKeyframe: Bool
    public var payload: Data

    public init(kind: StreamMessageKind, timestamp: Double, isKeyframe: Bool, payload: Data) {
        self.kind = kind
        self.timestamp = timestamp
        self.isKeyframe = isKeyframe
        self.payload = payload
    }

    public func serialized() -> Data {
        var d = Data(capacity: Self.headerLength + payload.count)
        d.append(kind.rawValue)
        d.appendBigEndian(timestamp.bitPattern)
        d.append(isKeyframe ? 1 : 0)
        d.appendBigEndian(UInt32(payload.count))
        d.append(payload)
        return d
    }

    public static func parseHeader(_ data: Data) -> StreamHeader? {
        guard data.count >= headerLength else { return nil }
        // A kind this build does not know is skipped by the reader, not a reason to stop reading:
        // an older device must keep working against a newer host and the other way round.
        let kind = StreamMessageKind(rawValue: data[data.startIndex]) ?? .unknown
        let ts = Double(bitPattern: data.readBigEndian(UInt64.self, at: 1))
        let key = data[data.startIndex + 9] == 1
        let len = Int(data.readBigEndian(UInt32.self, at: 10))
        return StreamHeader(kind: kind, timestamp: ts, isKeyframe: key, payloadLength: len)
    }
}

/// HEVC VPS/SPS/PPS as delivered by VideoToolbox, plus the NAL length-prefix size (normally 4).
public struct ParameterSets {
    public var nalUnitHeaderLength: Int
    public var sets: [Data]

    public init(nalUnitHeaderLength: Int, sets: [Data]) {
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.sets = sets
    }

    /// nalLen(1) count(1) then per set: length(2) bytes
    public func encoded() -> Data {
        var d = Data()
        d.append(UInt8(nalUnitHeaderLength))
        d.append(UInt8(sets.count))
        for s in sets {
            d.appendBigEndian(UInt16(s.count))
            d.append(s)
        }
        return d
    }

    public init?(encoded d: Data) {
        guard d.count >= 2 else { return nil }
        nalUnitHeaderLength = Int(d[d.startIndex])
        let count = Int(d[d.startIndex + 1])
        var offset = 2
        var result: [Data] = []
        for _ in 0..<count {
            guard d.count >= offset + 2 else { return nil }
            let len = Int(d.readBigEndian(UInt16.self, at: offset))
            offset += 2
            guard d.count >= offset + len else { return nil }
            result.append(d.subdata(in: (d.startIndex + offset)..<(d.startIndex + offset + len)))
            offset += len
        }
        sets = result
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        let start = startIndex + offset
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            copyBytes(to: dst, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(bigEndian: v)
    }
}
