import Foundation

public struct SFTPPacket: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data

    public init(type: UInt8, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

public struct SFTPWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    public mutating func uint32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func uint64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        binary(bytes)
    }

    public mutating func binary(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    public mutating func append(_ value: Data) {
        data.append(value)
    }

    public mutating func attributes(_ attributes: SFTPFileAttributes) {
        uint32(attributes.flagsValue)
        if let size = attributes.size { uint64(size) }
        if let uid = attributes.uid, let gid = attributes.gid { uint32(uid); uint32(gid) }
        if let permissions = attributes.permissions { uint32(permissions) }
        if let accessTime = attributes.accessTime, let modifyTime = attributes.modifyTime {
            uint32(accessTime)
            uint32(modifyTime)
        }
    }
}

public struct SFTPReader {
    private let data: Data
    private var offset: Int = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var remaining: Int { data.count - offset }

    public mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPCodecError.truncated }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPCodecError.truncated }
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[start + index])
        }
        offset += 4
        return value
    }

    public mutating func uint64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTPCodecError.truncated }
        let start = data.startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[start + index])
        }
        offset += 8
        return value
    }

    public mutating func binary() throws -> Data {
        let length = Int(try uint32())
        guard length >= 0, remaining >= length else { throw SFTPCodecError.truncated }
        let start = data.startIndex + offset
        let slice = data[start..<(start + length)]
        offset += length
        return Data(slice)
    }

    public mutating func string() throws -> String {
        let bytes = try binary()
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    public mutating func attributes() throws -> SFTPFileAttributes {
        let flags = try uint32()
        var attributes = SFTPFileAttributes()
        if flags & SFTPAttributesFlag.size.rawValue != 0 {
            attributes.size = try uint64()
        }
        if flags & SFTPAttributesFlag.uidgid.rawValue != 0 {
            attributes.uid = try uint32()
            attributes.gid = try uint32()
        }
        if flags & SFTPAttributesFlag.permissions.rawValue != 0 {
            attributes.permissions = try uint32()
        }
        if flags & SFTPAttributesFlag.accessModifyTime.rawValue != 0 {
            attributes.accessTime = try uint32()
            attributes.modifyTime = try uint32()
        }
        if flags & SFTPAttributesFlag.extended.rawValue != 0 {
            let count = try uint32()
            guard count < 1024 else { throw SFTPCodecError.malformed("too many extended attributes") }
            for _ in 0..<count {
                _ = try string()
                _ = try binary()
            }
        }
        return attributes
    }
}

public enum SFTPCodec {
    public static func encode(_ packet: SFTPPacket) -> Data {
        var writer = SFTPWriter()
        writer.uint32(UInt32(packet.payload.count + 1))
        writer.byte(packet.type)
        writer.append(packet.payload)
        return writer.data
    }

    /// Consumes one complete packet from the buffer, or returns nil when more
    /// bytes are needed. Truncated headers stay buffered for the next read.
    public static func decode(from buffer: inout Data) throws -> SFTPPacket? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 1 else { throw SFTPCodecError.malformed("zero length packet") }
        guard length <= UInt32(SFTPConstant.maxPacketSize) else {
            throw SFTPCodecError.malformed("packet too large: " + String(length))
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex
        let type = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + total)])
        buffer.removeFirst(total)
        return SFTPPacket(type: type, payload: payload)
    }

    public static func parseResponse(_ packet: SFTPPacket) throws -> (id: UInt32?, response: SFTPResponse) {
        var reader = SFTPReader(packet.payload)
        switch packet.type {
        case SFTPPacketType.version.rawValue:
            let version = try reader.uint32()
            var extensions: [String] = []
            while reader.remaining > 0 {
                let name = try reader.string()
                let value = try reader.string()
                extensions.append(name + "=" + value)
            }
            return (nil, .version(version, extensions))

        case SFTPPacketType.status.rawValue:
            let id = try reader.uint32()
            let codeValue = try reader.uint32()
            let message = try reader.string()
            let language = try reader.string()
            let code = SFTPStatus.Code(rawValue: codeValue) ?? .failure
            return (id, .status(SFTPStatus(code: code, message: message, language: language)))

        case SFTPPacketType.handle.rawValue:
            let id = try reader.uint32()
            return (id, .handle(try reader.binary()))

        case SFTPPacketType.data.rawValue:
            let id = try reader.uint32()
            return (id, .data(try reader.binary()))

        case SFTPPacketType.name.rawValue:
            let id = try reader.uint32()
            let count = try reader.uint32()
            guard count < 1_000_000 else { throw SFTPCodecError.malformed("too many name entries") }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let filename = try reader.string()
                let longname = try reader.string()
                let attributes = try reader.attributes()
                entries.append(SFTPNameEntry(filename: filename, longname: longname, attributes: attributes))
            }
            return (id, .name(entries))

        case SFTPPacketType.attrs.rawValue:
            let id = try reader.uint32()
            return (id, .attrs(try reader.attributes()))

        case SFTPPacketType.extendedReply.rawValue:
            let id = try reader.uint32()
            return (id, .extendedReply(try reader.binary()))

        default:
            throw SFTPCodecError.malformed("unexpected packet type " + String(packet.type))
        }
    }
}

public enum SFTPRequests {
    public static func initPacket(version: UInt32 = SFTPConstant.version) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(version)
        return SFTPPacket(type: SFTPPacketType.initPacket.rawValue, payload: writer.data)
    }

    private static func request(_ type: SFTPPacketType, _ id: UInt32, body: (inout SFTPWriter) -> Void) -> SFTPPacket {
        var writer = SFTPWriter()
        writer.uint32(id)
        body(&writer)
        return SFTPPacket(type: type.rawValue, payload: writer.data)
    }

    public static func open(id: UInt32, path: String, flags: SFTPOpenFlags, attributes: SFTPFileAttributes = SFTPFileAttributes()) -> SFTPPacket {
        request(.open, id) { writer in
            writer.string(path)
            writer.uint32(flags.rawValue)
            writer.attributes(attributes)
        }
    }

    public static func close(id: UInt32, handle: Data) -> SFTPPacket {
        request(.close, id) { $0.binary(handle) }
    }

    public static func read(id: UInt32, handle: Data, offset: UInt64, length: UInt32) -> SFTPPacket {
        request(.read, id) { writer in
            writer.binary(handle)
            writer.uint64(offset)
            writer.uint32(length)
        }
    }

    public static func write(id: UInt32, handle: Data, offset: UInt64, data: Data) -> SFTPPacket {
        request(.write, id) { writer in
            writer.binary(handle)
            writer.uint64(offset)
            writer.binary(data)
        }
    }

    public static func stat(id: UInt32, path: String, followSymlink: Bool) -> SFTPPacket {
        request(followSymlink ? .stat : .lstat, id) { $0.string(path) }
    }

    public static func fstat(id: UInt32, handle: Data) -> SFTPPacket {
        request(.fstat, id) { $0.binary(handle) }
    }

    public static func setStat(id: UInt32, path: String, attributes: SFTPFileAttributes) -> SFTPPacket {
        request(.setstat, id) { writer in
            writer.string(path)
            writer.attributes(attributes)
        }
    }

    public static func openDirectory(id: UInt32, path: String) -> SFTPPacket {
        request(.opendir, id) { $0.string(path) }
    }

    public static func readDirectory(id: UInt32, handle: Data) -> SFTPPacket {
        request(.readdir, id) { $0.binary(handle) }
    }

    public static func remove(id: UInt32, path: String) -> SFTPPacket {
        request(.remove, id) { $0.string(path) }
    }

    public static func makeDirectory(id: UInt32, path: String, attributes: SFTPFileAttributes = SFTPFileAttributes()) -> SFTPPacket {
        request(.mkdir, id) { writer in
            writer.string(path)
            writer.attributes(attributes)
        }
    }

    public static func removeDirectory(id: UInt32, path: String) -> SFTPPacket {
        request(.rmdir, id) { $0.string(path) }
    }

    public static func realPath(id: UInt32, path: String) -> SFTPPacket {
        request(.realpath, id) { $0.string(path) }
    }

    public static func rename(id: UInt32, oldPath: String, newPath: String) -> SFTPPacket {
        request(.rename, id) { writer in
            writer.string(oldPath)
            writer.string(newPath)
        }
    }

    public static func readLink(id: UInt32, path: String) -> SFTPPacket {
        request(.readlink, id) { $0.string(path) }
    }

    public static func symbolicLink(id: UInt32, target: String, linkPath: String) -> SFTPPacket {
        request(.symlink, id) { writer in
            writer.string(linkPath)
            writer.string(target)
        }
    }
}
