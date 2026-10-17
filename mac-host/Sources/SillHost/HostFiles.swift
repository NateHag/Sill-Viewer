import AppKit
import Foundation
import Network
import StreamProtocol

/// Sill Desktop Host addition: files both ways with Sill Viewer, the same messages as sill-linux
/// (kinds 201–206, StreamMessage.swift).
///
/// From a device: FILE_START, then FILE_DATA pieces, then FILE_END, one file at a time. Each file is
/// written to ~/Downloads as "name.part" and renamed when whole, so a broken transfer never looks
/// finished; a folder keeps its shape, and a name already there gets " (1)". Names can never leave
/// Downloads ("..", "~" and empty parts are dropped).
///
/// To a device, on FILE_REQUEST: the files and folders copied in Finder (the general pasteboard's
/// file URLs), sent the same way. While the connection still has more than `backlogLimit` bytes to
/// take, the sender waits, so a big file never fills memory or holds up the video for long.
///
/// FILE_STATUS: short notes for the person, shown by the viewer.
final class HostFiles {
    static let chunk = 128 * 1024
    static let backlogLimit = 1 << 20

    private let server: StreamServer
    /// Receiving, per connection, in the order the pieces came.
    private let queue = DispatchQueue(label: "sill.files", qos: .utility)
    /// Sending: one batch at a time, so pieces of two batches never mix.
    private let sendQueue = DispatchQueue(label: "sill.files.send", qos: .utility)
    private var incoming: [ObjectIdentifier: Incoming] = [:]   // on `queue`
    private var nextID: UInt32 = 1                             // on `sendQueue`

    init(server: StreamServer) {
        self.server = server
    }

    static func handles(_ kind: StreamMessageKind) -> Bool {
        switch kind {
        case .fileStart, .fileData, .fileEnd, .fileCancel, .fileRequest: return true
        default: return false
        }
    }

    /// A file message from a device. Any thread; handled in order on `queue`.
    func received(_ message: StreamMessage, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if message.kind == .fileRequest {
            sendQueue.async { [self] in sendCopied(to: connection) }
            return
        }
        queue.async { [self] in
            let inc = incoming[id] ?? Incoming()
            incoming[id] = inc
            if let note = inc.handle(message) {
                status(note, to: connection)
            }
        }
    }

    /// The device left: its half-received files are deleted.
    func clientLeft(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        queue.async { [self] in
            incoming.removeValue(forKey: id)?.dropAll()
        }
    }

    // MARK: Sending

    private func status(_ text: String, to connection: NWConnection) {
        send(.fileStatus, json: ["text": text], to: connection)
    }

    private func send(_ kind: StreamMessageKind, json: [String: Any], to connection: NWConnection) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        server.send(StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload),
                    to: connection)
    }

    /// On `sendQueue`.
    private func sendCopied(to connection: NWConnection) {
        let board = NSPasteboard.general
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let items = Self.walk(urls)
        guard !items.isEmpty else {
            status("No files are copied on this Mac. Select files in Finder, press Cmd+C, then try again.", to: connection)
            return
        }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        status(String(format: "Sending %d file%@ (%.1f MB)…", items.count, items.count == 1 ? "" : "s",
                      Double(total) / 1_000_000), to: connection)
        var sent = 0
        for (i, item) in items.enumerated() {
            let id = nextID
            nextID &+= 1
            guard let handle = try? FileHandle(forReadingFrom: item.url) else {
                status("Could not read \(item.name)", to: connection)
                continue
            }
            send(.fileStart, json: ["id": Int(id), "name": item.name, "size": item.size, "root": item.root], to: connection)
            var ok = true
            while ok {
                let piece: Data
                do {
                    guard let d = try handle.read(upToCount: Self.chunk), !d.isEmpty else { break }
                    piece = d
                } catch {
                    status("Could not read \(item.name): \(error.localizedDescription)", to: connection)
                    send(.fileCancel, json: ["id": Int(id)], to: connection)
                    ok = false
                    break
                }
                // Wait while the connection is behind; stop if it is gone.
                while true {
                    guard let pending = server.pendingBytes(of: connection) else {
                        try? handle.close()
                        print("Files: the device left during a transfer")
                        return
                    }
                    if pending <= Self.backlogLimit { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                var payload = Data(capacity: 4 + piece.count)
                payload.append(contentsOf: [UInt8(id >> 24 & 0xff), UInt8(id >> 16 & 0xff), UInt8(id >> 8 & 0xff), UInt8(id & 0xff)])
                payload.append(piece)
                server.send(StreamMessage(kind: .fileData, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                          payload: payload), to: connection)
            }
            try? handle.close()
            if ok {
                send(.fileEnd, json: ["id": Int(id), "last": i == items.count - 1], to: connection)
                sent += 1
            }
        }
        print("Files: sent \(sent) of \(items.count)")
    }

    struct Item {
        let url: URL
        let name: String   // relative, "/"-separated: a folder's files keep their place in it
        let size: Int64
        let root: Int      // which copied item it came from (a folder's files share one)
    }

    /// Every file in `urls`, folders walked; links and hidden files inside folders left out.
    static func walk(_ urls: [URL]) -> [Item] {
        var out: [Item] = []
        let fm = FileManager.default
        for (root, url) in urls.enumerated() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = url.deletingLastPathComponent().standardizedFileURL.path
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
                var files: [URL] = []
                for case let f as URL in e {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(f) }
                }
                for f in files.sorted(by: { $0.path < $1.path }) {
                    let path = f.standardizedFileURL.path
                    let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : f.lastPathComponent
                    let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    out.append(Item(url: f, name: rel, size: size, root: root))
                }
            } else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                out.append(Item(url: url, name: url.lastPathComponent, size: size, root: root))
            }
        }
        return out
    }

    // MARK: Receiving

    /// What one connection is sending here. Used on `queue` only.
    private final class Incoming {
        struct Open {
            let handle: FileHandle
            let dest: URL
            let size: Int64
            var got: Int64
        }

        var open: [UInt32: Open] = [:]
        /// The sender's root index → the folder made for it here.
        var folders: [Int: URL] = [:]
        var saved = 0

        static var downloads: URL {
            let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }

        /// The parts of a relative path that stay inside the folder.
        static func safeParts(_ name: String) -> [String] {
            name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("~") }
                .map { $0.replacingOccurrences(of: "\0", with: "") }
        }

        static func part(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".part") }

        /// `url`, or "name (1).ext" and so on when it, or its ".part", is taken.
        static func unique(_ url: URL) -> URL {
            let fm = FileManager.default
            func free(_ u: URL) -> Bool { !fm.fileExists(atPath: u.path) && !fm.fileExists(atPath: part(u).path) }
            if free(url) { return url }
            let dir = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            var n = 1
            while true {
                let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                let candidate = dir.appendingPathComponent(name)
                if free(candidate) { return candidate }
                n += 1
            }
        }

        static func json(_ data: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        /// One file message; a note for the person, if any.
        func handle(_ m: StreamMessage) -> String? {
            switch m.kind {
            case .fileData:
                let p = m.payload
                guard p.count >= 4 else { return nil }
                let id = p.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                guard var t = open[id] else { return nil }
                let body = p.dropFirst(4)
                do {
                    try t.handle.write(contentsOf: body)
                } catch {
                    drop(id)
                    return "Could not save \(t.dest.lastPathComponent): \(error.localizedDescription)"
                }
                t.got += Int64(body.count)
                open[id] = t
                return nil
            case .fileStart:
                guard let j = Self.json(m.payload), let idN = j["id"] as? NSNumber, let sizeN = j["size"] as? NSNumber,
                      let name = j["name"] as? String else { return nil }
                let parts = Self.safeParts(name)
                guard let first = parts.first else { return nil }
                let top = Self.downloads
                let dest: URL
                if parts.count == 1 {
                    dest = Self.unique(top.appendingPathComponent(first))
                } else {
                    let root = (j["root"] as? NSNumber)?.intValue ?? 0
                    let folder = folders[root] ?? Self.unique(top.appendingPathComponent(first))
                    folders[root] = folder
                    dest = parts.dropFirst().reduce(folder) { $0.appendingPathComponent($1) }
                }
                let fm = FileManager.default
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard fm.createFile(atPath: Self.part(dest).path, contents: nil) else {
                        return "Could not save \(name)"
                    }
                    let handle = try FileHandle(forWritingTo: Self.part(dest))
                    open[idN.uint32Value] = Open(handle: handle, dest: dest, size: sizeN.int64Value, got: 0)
                } catch {
                    return "Could not save \(name): \(error.localizedDescription)"
                }
                return nil
            case .fileEnd:
                guard let j = Self.json(m.payload), let idN = j["id"] as? NSNumber,
                      let t = open.removeValue(forKey: idN.uint32Value) else { return nil }
                try? t.handle.close()
                let fm = FileManager.default
                guard t.got == t.size else {
                    try? fm.removeItem(at: Self.part(t.dest))
                    return "\(t.dest.lastPathComponent) did not arrive whole"
                }
                do {
                    try fm.moveItem(at: Self.part(t.dest), to: t.dest)
                } catch {
                    return "Could not save \(t.dest.lastPathComponent): \(error.localizedDescription)"
                }
                print("Files: received \(t.dest.path) (\(t.size) bytes)")
                saved += 1
                if (j["last"] as? Bool) == true {
                    let n = saved
                    saved = 0
                    folders = [:]
                    return "Saved \(n) file\(n == 1 ? "" : "s") to \(Self.downloads.path)"
                }
                return nil
            case .fileCancel:
                if let j = Self.json(m.payload), let idN = j["id"] as? NSNumber { drop(idN.uint32Value) }
                return nil
            default:
                return nil
            }
        }

        func drop(_ id: UInt32) {
            guard let t = open.removeValue(forKey: id) else { return }
            try? t.handle.close()
            try? FileManager.default.removeItem(at: Self.part(t.dest))
        }

        func dropAll() {
            for id in Array(open.keys) { drop(id) }
        }
    }
}
