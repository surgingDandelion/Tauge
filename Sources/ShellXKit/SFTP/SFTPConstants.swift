import Foundation

/// SFTP protocol version 3 constants (draft-ietf-secsh-filexfer-02).
public enum SFTPConstant {
    public static let version: UInt32 = 3
    public static let maxPacketSize = 256 * 1024 * 1024
    /// Draft mandates that peers support at least 32768 byte reads/writes.
    public static let minimumChunkSize = 32768
}

public enum SFTPPacketType: UInt8, Sendable {
    case initPacket = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

public struct SFTPOpenFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)

    public static let writeTruncateCreate: SFTPOpenFlags = [.write, .truncate, .create]
    public static let writeAppendCreate: SFTPOpenFlags = [.write, .create, .append]
}

public enum SFTPAttributesFlag: UInt32, Sendable {
    case size = 0x0000_0001
    case uidgid = 0x0000_0002
    case permissions = 0x0000_0004
    case accessModifyTime = 0x0000_0008
    case extended = 0x8000_0000
}

public struct SFTPFileAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modifyTime: UInt32?

    public init(size: UInt64? = nil,
                uid: UInt32? = nil,
                gid: UInt32? = nil,
                permissions: UInt32? = nil,
                accessTime: UInt32? = nil,
                modifyTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modifyTime = modifyTime
    }

    public var flagsValue: UInt32 {
        var flags: UInt32 = 0
        if size != nil { flags |= SFTPAttributesFlag.size.rawValue }
        if uid != nil || gid != nil { flags |= SFTPAttributesFlag.uidgid.rawValue }
        if permissions != nil { flags |= SFTPAttributesFlag.permissions.rawValue }
        if accessTime != nil || modifyTime != nil { flags |= SFTPAttributesFlag.accessModifyTime.rawValue }
        return flags
    }

    public var isEmpty: Bool { flagsValue == 0 }

    public static let fileTypeMask: UInt32 = 0o170000
    public static let directoryType: UInt32 = 0o040000
    public static let regularType: UInt32 = 0o100000
    public static let symlinkType: UInt32 = 0o120000

    public var isDirectory: Bool {
        guard let permissions else { return false }
        return permissions & SFTPFileAttributes.fileTypeMask == SFTPFileAttributes.directoryType
    }

    public var isSymlink: Bool {
        guard let permissions else { return false }
        return permissions & SFTPFileAttributes.fileTypeMask == SFTPFileAttributes.symlinkType
    }

    public var isRegularFile: Bool {
        guard let permissions else { return false }
        return permissions & SFTPFileAttributes.fileTypeMask == SFTPFileAttributes.regularType
    }

    public var modeBits: UInt16 {
        UInt16((permissions ?? 0) & 0o7777)
    }
}

public struct SFTPStatus: Equatable, Sendable {
    public enum Code: UInt32, Sendable {
        case ok = 0
        case eof = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case opUnsupported = 8
    }

    public var code: Code
    public var message: String
    public var language: String

    public init(code: Code, message: String, language: String = "") {
        self.code = code
        self.message = message
        self.language = language
    }

    public var isOK: Bool { code == .ok }
    public var isEOF: Bool { code == .eof }
}

public struct SFTPNameEntry: Equatable, Sendable {
    public var filename: String
    public var longname: String
    public var attributes: SFTPFileAttributes

    public init(filename: String, longname: String = "", attributes: SFTPFileAttributes = SFTPFileAttributes()) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

public enum SFTPResponse: Equatable, Sendable {
    case version(UInt32, [String])
    case status(SFTPStatus)
    case handle(Data)
    case data(Data)
    case name([SFTPNameEntry])
    case attrs(SFTPFileAttributes)
    case extendedReply(Data)
}

public enum SFTPCodecError: Error, LocalizedError, Equatable {
    case truncated
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "SFTP packet is truncated"
        case .malformed(let reason): return "Malformed SFTP packet: " + reason
        }
    }
}

public enum SFTPError: Error, LocalizedError, Equatable {
    case status(SFTPStatus)
    case protocolError(String)
    case closed
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            switch status.code {
            case .noSuchFile: return "No such file or directory" + suffix(status)
            case .permissionDenied: return "Permission denied" + suffix(status)
            case .failure: return "SFTP request failed" + suffix(status)
            case .opUnsupported: return "Operation not supported by server" + suffix(status)
            case .noConnection: return "No connection" + suffix(status)
            case .connectionLost: return "Connection lost" + suffix(status)
            default: return "SFTP error " + String(status.code.rawValue) + suffix(status)
            }
        case .protocolError(let reason): return "SFTP protocol error: " + reason
        case .closed: return "SFTP channel is closed"
        case .transport(let reason): return "SFTP transport error: " + reason
        }
    }

    private func suffix(_ status: SFTPStatus) -> String {
        status.message.isEmpty ? "" : " (" + status.message + ")"
    }

    public var isNoSuchFile: Bool {
        if case .status(let status) = self { return status.code == .noSuchFile }
        return false
    }

    public var isPermissionDenied: Bool {
        if case .status(let status) = self { return status.code == .permissionDenied }
        return false
    }
}
