import Foundation
import TaugeKit

/// In-memory SFTP v3 server used by the self checks. It speaks just enough of
/// the protocol for SFTPClient and TransferEngine: directory listings, stat,
/// open/read/write/close, mkdir, setstat and remove.
final class MockSFTPServer: SFTPTransport, @unchecked Sendable {
    struct Node {
        var isDirectory: Bool
        var data: Data
        var permissions: UInt32
        var modifyTime: UInt32
        var symlinkTarget: String? = nil
    }

    enum Handle {
        case file(String)
        case directory(String, sent: Bool)
    }

    enum MockError: Error {
        case closed
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var filesAppearingBeforeOpen: [String: Data] = [:]
    private var extraDirectoryNames: [String: [String]] = [:]
    private var openedSymlinks: Set<String> = []
    private var nextRemovalFailures: [String: SFTPStatus.Code] = [:]
    private var outbound = Data()
    private var isClosed = false
    private var handles: [Data: Handle] = [:]
    private var handleCounter: UInt8 = 0

    private(set) var reads = 0
    private(set) var writes = 0

    init(roots: [String] = ["/", "/remote"]) {
        for root in roots {
            nodes[POSIXPath.normalize(root)] = Node(isDirectory: true,
                                                    data: Data(),
                                                    permissions: 0o040755,
                                                    modifyTime: 1_700_000_000)
        }
    }

    // MARK: - Inspection helpers (used by checks)

    func fileData(_ path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[POSIXPath.normalize(path)], !node.isDirectory else { return nil }
        return node.data
    }

    func filePermissions(_ path: String) -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[POSIXPath.normalize(path)] else { return nil }
        return UInt16(node.permissions & 0o7777)
    }

    func seedFile(_ path: String, data: Data, permissions: UInt16 = 0o644) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = POSIXPath.normalize(path)
        ensureParents(of: normalized)
        nodes[normalized] = Node(isDirectory: false,
                                 data: data,
                                 permissions: 0o100000 | (UInt32(permissions) & 0o7777),
                                 modifyTime: 1_700_000_000)
    }

    func seedDirectory(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = POSIXPath.normalize(path)
        ensureParents(of: normalized)
        nodes[normalized] = Node(isDirectory: true, data: Data(), permissions: 0o040755, modifyTime: 1_700_000_000)
    }

    func seedSymlink(_ path: String, to target: String) {
        lock.withLock {
            let normalized = POSIXPath.normalize(path)
            ensureParents(of: normalized)
            nodes[normalized] = Node(isDirectory: false, data: Data(), permissions: 0o120777,
                                     modifyTime: 1_700_000_000, symlinkTarget: target)
        }
    }

    func didOpenSymlink(_ path: String) -> Bool {
        lock.withLock { openedSymlinks.contains(POSIXPath.normalize(path)) }
    }

    func advertiseNames(_ names: [String], in directory: String) {
        lock.withLock { extraDirectoryNames[POSIXPath.normalize(directory)] = names }
    }

    func failNextRemoval(_ path: String, with error: SFTPStatus.Code) {
        lock.withLock { nextRemovalFailures[POSIXPath.normalize(path)] = error }
    }

    func seedFileBeforeOpen(_ path: String, data: Data) {
        lock.withLock { filesAppearingBeforeOpen[POSIXPath.normalize(path)] = data }
    }

    private func ensureParents(of path: String) {
        var parent = POSIXPath.parent(path)
        while parent != "/", nodes[parent] == nil {
            nodes[parent] = Node(isDirectory: true, data: Data(), permissions: 0o040755, modifyTime: 1_700_000_000)
            parent = POSIXPath.parent(parent)
        }
    }

    // MARK: - SFTPTransport

    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !isClosed else { throw MockError.closed }
            var buffer = data
            while true {
                let packet: SFTPPacket?
                do {
                    packet = try SFTPCodec.decode(from: &buffer)
                } catch {
                    break
                }
                guard let packet else { break }
                for response in respond(to: packet) {
                    outbound.append(SFTPCodec.encode(response))
                }
            }
        }
    }

    func receive() async throws -> Data? {
        while true {
            let (chunk, closed) = lock.withLock { () -> (Data?, Bool) in
                if outbound.isEmpty { return (nil, isClosed) }
                let chunk = outbound
                outbound.removeAll()
                return (chunk, isClosed)
            }
            if let chunk { return chunk }
            if closed { return nil }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Synchronous plumbing for the in-process SSH server mock: raw SFTP bytes
    /// in, raw SFTP bytes out.
    func handleChunk(_ data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var buffer = data
        var responses = Data()
        while true {
            let packet: SFTPPacket?
            do {
                packet = try SFTPCodec.decode(from: &buffer)
            } catch {
                break
            }
            guard let packet else { break }
            for response in respond(to: packet) {
                responses.append(SFTPCodec.encode(response))
            }
        }
        return responses
    }

    func closeTransport() async {
        lock.withLock { isClosed = true }
    }

    // MARK: - Request handling

    private func respond(to packet: SFTPPacket) -> [SFTPPacket] {
        var reader = SFTPReader(packet.payload)
        guard let id = try? reader.uint32() else { return [] }
        switch SFTPPacketType(rawValue: packet.type) {
        case .initPacket:
            var writer = SFTPWriter()
            writer.uint32(SFTPConstant.version)
            return [SFTPPacket(type: SFTPPacketType.version.rawValue, payload: writer.data)]
        case .realpath:
            // Resolve relative paths against the mock root, like a real server
            // would resolve them against the login directory.
            let requested = (try? reader.string()) ?? "/"
            let absolute = requested.hasPrefix("/") ? requested : "/" + requested
            return [namePacket(id: id, entries: [(POSIXPath.normalize(absolute), 0o040755, 0, 1_700_000_000)], includeDot: false)]
        case .stat, .lstat:
            let path = POSIXPath.normalize((try? reader.string()) ?? "/")
            let followSymlink = packet.type == SFTPPacketType.stat.rawValue
            let target = followSymlink ? nodes[path]?.symlinkTarget ?? path : path
            guard let node = nodes[target] else { return [statusPacket(id, .noSuchFile)] }
            return [attrsPacket(id: id, attributes(for: node))]
        case .open:
            let path = POSIXPath.normalize((try? reader.string()) ?? "")
            let flags = SFTPOpenFlags(rawValue: (try? reader.uint32()) ?? SFTPOpenFlags.read.rawValue)
            let requested = (try? reader.attributes()) ?? SFTPFileAttributes()
            if let data = filesAppearingBeforeOpen.removeValue(forKey: path), nodes[path] == nil {
                nodes[path] = Node(isDirectory: false, data: data, permissions: 0o100644, modifyTime: 1_700_000_000)
            }
            var node = nodes[path]
            if node != nil, flags.contains([.create, .exclusive]) {
                return [statusPacket(id, .failure)]
            }
            if node == nil {
                guard flags.contains(.create) else { return [statusPacket(id, .noSuchFile)] }
                ensureParents(of: path)
                let mode = (requested.permissions ?? 0o644) & 0o7777
                node = Node(isDirectory: false,
                            data: Data(),
                            permissions: 0o100000 | mode,
                            modifyTime: 1_700_000_000)
            }
            if flags.contains(.truncate) {
                node?.data = Data()
            }
            nodes[path] = node
            return [handlePacket(id: id, path: path, isDirectory: false)]
        case .read:
            guard let handle = try? reader.binary(), case .file(let path)? = handles[handle],
                  let node = nodes[path] else {
                return [statusPacket(id, .failure)]
            }
            let offset = Int((try? reader.uint64()) ?? 0)
            let length = Int((try? reader.uint32()) ?? 0)
            if offset >= node.data.count { return [statusPacket(id, .eof)] }
            let end = min(node.data.count, offset + max(length, 1))
            reads += 1
            return [dataPacket(id: id, data: node.data.subdata(in: offset..<end))]
        case .write:
            guard let handle = try? reader.binary(), case .file(let path)? = handles[handle],
                  let offset = try? reader.uint64(), let data = try? reader.binary() else {
                return [statusPacket(id, .failure)]
            }
            var node = nodes[path] ?? Node(isDirectory: false, data: Data(), permissions: 0o100644, modifyTime: 1_700_000_000)
            var bytes = Array(node.data)
            let start = Int(offset)
            if bytes.count < start { bytes.append(contentsOf: [UInt8](repeating: 0, count: start - bytes.count)) }
            let end = start + data.count
            if bytes.count < end {
                bytes.append(contentsOf: [UInt8](repeating: 0, count: end - bytes.count))
            }
            bytes.replaceSubrange(start..<end, with: [UInt8](data))
            node.data = Data(bytes)
            node.modifyTime = 1_700_000_000
            nodes[path] = node
            writes += 1
            return [statusPacket(id, .ok)]
        case .close:
            if let handle = try? reader.binary() {
                handles.removeValue(forKey: handle)
            }
            return [statusPacket(id, .ok)]
        case .opendir:
            let path = POSIXPath.normalize((try? reader.string()) ?? "/")
            let target = nodes[path]?.symlinkTarget ?? path
            guard let node = nodes[target], node.isDirectory else {
                return [statusPacket(id, .noSuchFile)]
            }
            if target != path { openedSymlinks.insert(path) }
            return [handlePacket(id: id, path: target, isDirectory: true)]
        case .readdir:
            guard let handle = try? reader.binary(), case .directory(let path, let sent)? = handles[handle] else {
                return [statusPacket(id, .failure)]
            }
            if sent {
                return [statusPacket(id, .eof)]
            }
            handles[handle] = .directory(path, sent: true)
            let entries = children(of: path) + (extraDirectoryNames[path] ?? []).map { ($0, 0o040755, 0, 1_700_000_000) }
            return [namePacket(id: id, entries: entries, includeDot: false)]
        case .mkdir:
            let path = POSIXPath.normalize((try? reader.string()) ?? "")
            let requested = (try? reader.attributes()) ?? SFTPFileAttributes()
            if nodes[path] != nil { return [statusPacket(id, .failure)] }
            ensureParents(of: path)
            let mode = (requested.permissions ?? 0o755) & 0o7777
            nodes[path] = Node(isDirectory: true,
                               data: Data(),
                               permissions: 0o040000 | mode,
                               modifyTime: 1_700_000_000)
            return [statusPacket(id, .ok)]
        case .rmdir:
            let path = POSIXPath.normalize((try? reader.string()) ?? "")
            if let error = nextRemovalFailures.removeValue(forKey: path) { return [statusPacket(id, error)] }
            guard let node = nodes[path] else { return [statusPacket(id, .noSuchFile)] }
            guard node.isDirectory else { return [statusPacket(id, .failure)] }
            if !children(of: path).isEmpty { return [statusPacket(id, .failure)] }
            nodes.removeValue(forKey: path)
            return [statusPacket(id, .ok)]
        case .remove:
            let path = POSIXPath.normalize((try? reader.string()) ?? "")
            if let error = nextRemovalFailures.removeValue(forKey: path) { return [statusPacket(id, error)] }
            guard let node = nodes[path] else { return [statusPacket(id, .noSuchFile)] }
            guard !node.isDirectory else { return [statusPacket(id, .failure)] }
            nodes.removeValue(forKey: path)
            return [statusPacket(id, .ok)]
        case .rename:
            let from = POSIXPath.normalize((try? reader.string()) ?? "")
            let to = POSIXPath.normalize((try? reader.string()) ?? "")
            guard let node = nodes[from] else { return [statusPacket(id, .noSuchFile)] }
            nodes.removeValue(forKey: from)
            ensureParents(of: to)
            nodes[to] = node
            return [statusPacket(id, .ok)]
        case .setstat:
            let path = POSIXPath.normalize((try? reader.string()) ?? "")
            let attributes = (try? reader.attributes()) ?? SFTPFileAttributes()
            guard var node = nodes[path] else { return [statusPacket(id, .noSuchFile)] }
            if let permissions = attributes.permissions {
                node.permissions = (node.permissions & SFTPFileAttributes.fileTypeMask) | (permissions & 0o7777)
            }
            if let modifyTime = attributes.modifyTime { node.modifyTime = modifyTime }
            nodes[path] = node
            return [statusPacket(id, .ok)]
        case .fsetstat:
            let attributes = (try? reader.attributes()) ?? SFTPFileAttributes()
            _ = attributes
            return [statusPacket(id, .ok)]
        default:
            return [statusPacket(id, .opUnsupported)]
        }
    }

    private func attributes(for node: Node) -> SFTPFileAttributes {
        SFTPFileAttributes(size: node.isDirectory ? nil : UInt64(node.data.count),
                           uid: 501,
                           gid: 20,
                           permissions: node.permissions,
                           accessTime: node.modifyTime,
                           modifyTime: node.modifyTime)
    }

    private func children(of directory: String) -> [(name: String, permissions: UInt32, size: UInt64, mtime: UInt32)] {
        nodes.compactMap { path, node in
            guard path != "/", POSIXPath.parent(path) == directory else { return nil }
            return (POSIXPath.lastComponent(path),
                    node.permissions,
                    node.isDirectory ? 0 : UInt64(node.data.count),
                    node.modifyTime)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Packet builders

    private func statusPacket(_ id: UInt32, _ code: SFTPStatus.Code) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.uint32(code.rawValue)
        writer.string("")
        writer.string("en")
        return SFTPPacket(type: SFTPPacketType.status.rawValue, payload: writer.data)
    }

    private func handlePacket(id: UInt32, path: String, isDirectory: Bool) -> SFTPPacket {
        handleCounter &+= 1
        let handle = Data([handleCounter])
        if isDirectory {
            handles[handle] = .directory(path, sent: false)
        } else {
            handles[handle] = .file(path)
        }
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.binary(handle)
        return SFTPPacket(type: SFTPPacketType.handle.rawValue, payload: writer.data)
    }

    private func attrsPacket(id: UInt32, _ attributes: SFTPFileAttributes) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.attributes(attributes)
        return SFTPPacket(type: SFTPPacketType.attrs.rawValue, payload: writer.data)
    }

    private func dataPacket(id: UInt32, data: Data) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.binary(data)
        return SFTPPacket(type: SFTPPacketType.data.rawValue, payload: writer.data)
    }

    private func namePacket(id: UInt32,
                            entries: [(name: String, permissions: UInt32, size: UInt64, mtime: UInt32)],
                            includeDot: Bool) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.uint32(UInt32(entries.count))
        for entry in entries {
            writer.string(entry.name)
            writer.string(entry.name)
            writer.attributes(SFTPFileAttributes(size: entry.size,
                                                 permissions: entry.permissions,
                                                 accessTime: entry.mtime,
                                                 modifyTime: entry.mtime))
        }
        return SFTPPacket(type: SFTPPacketType.name.rawValue, payload: writer.data)
    }
}
