import Foundation

// MARK: - Enumerations

/// Authentication strategy for a host.
public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case password
    case privateKey
    case agent
    case keyboardInteractive

    public var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        case .agent: return "SSH Agent"
        case .keyboardInteractive: return "Keyboard Interactive"
        }
    }
}

public enum TextEncodingKind: String, Codable, CaseIterable, Sendable {
    case utf8
    case gbk

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .gbk: return "GBK"
        }
    }

    /// Foundation encoding used when decoding remote bytes.
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .gbk:
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
}

public enum ProxyType: String, Codable, CaseIterable, Sendable {
    case http
    case socks5
    case socks5h
    case https

    public var displayName: String {
        switch self {
        case .http: return "HTTP CONNECT"
        case .socks5: return "SOCKS5"
        case .socks5h: return "SOCKS5 (remote DNS)"
        case .https: return "HTTPS CONNECT"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .http: return 8080
        case .https: return 443
        case .socks5, .socks5h: return 1080
        }
    }
}

/// Where a host gets its outbound proxy from.
public enum ProxyPolicy: Codable, Hashable, Sendable {
    case inherit
    case direct
    case use(UUID)

    public var isInherit: Bool {
        if case .inherit = self { return true }
        return false
    }

    public var proxyID: UUID? {
        if case .use(let id) = self { return id }
        return nil
    }

    // Codable as {"kind":"inherit"} / {"kind":"use","id":"..."}
    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "use": self = .use(try c.decode(UUID.self, forKey: .id))
        case "direct": self = .direct
        default: self = .inherit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit: try c.encode("inherit", forKey: .kind)
        case .direct: try c.encode("direct", forKey: .kind)
        case .use(let id):
            try c.encode("use", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

/// Where a host gets its jump chain from.
public enum JumpPolicy: Codable, Hashable, Sendable {
    case inherit
    case direct
    case hosts([UUID])

    public var isInherit: Bool {
        if case .inherit = self { return true }
        return false
    }

    public var hostIDs: [UUID] {
        if case .hosts(let ids) = self { return ids }
        return []
    }

    private enum CodingKeys: String, CodingKey { case kind, ids }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "hosts": self = .hosts(try c.decode([UUID].self, forKey: .ids))
        case "direct": self = .direct
        default: self = .inherit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit: try c.encode("inherit", forKey: .kind)
        case .direct: try c.encode("direct", forKey: .kind)
        case .hosts(let ids):
            try c.encode("hosts", forKey: .kind)
            try c.encode(ids, forKey: .ids)
        }
    }
}

// MARK: - Group defaults

/// Defaults a group provides to its children (hosts and sub-groups).
public struct GroupDefaults: Codable, Hashable, Sendable {
    public var proxyPolicy: ProxyPolicy
    public var jumpPolicy: JumpPolicy
    public var encoding: TextEncodingKind?
    public var terminalType: String?
    public var keepaliveSeconds: Int?
    public var sessionLogging: Bool?
    public var logPathTemplate: String?
    public var defaultUploadDirectory: String?

    public init(
        proxyPolicy: ProxyPolicy = .inherit,
        jumpPolicy: JumpPolicy = .inherit,
        encoding: TextEncodingKind? = nil,
        terminalType: String? = nil,
        keepaliveSeconds: Int? = nil,
        sessionLogging: Bool? = nil,
        logPathTemplate: String? = nil,
        defaultUploadDirectory: String? = nil
    ) {
        self.proxyPolicy = proxyPolicy
        self.jumpPolicy = jumpPolicy
        self.encoding = encoding
        self.terminalType = terminalType
        self.keepaliveSeconds = keepaliveSeconds
        self.sessionLogging = sessionLogging
        self.logPathTemplate = logPathTemplate
        self.defaultUploadDirectory = defaultUploadDirectory
    }

    public static let empty = GroupDefaults()
}

// MARK: - Core entities

public struct HostGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    /// Optional accent used by the sidebar and start page. Nil keeps the
    /// generated neutral palette for groups created by older versions.
    public var colorHex: String?
    public var sortIndex: Int
    public var isExpanded: Bool
    public var defaults: GroupDefaults

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        colorHex: String? = nil,
        sortIndex: Int = 0,
        isExpanded: Bool = true,
        defaults: GroupDefaults = .empty
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.isExpanded = isExpanded
        self.defaults = defaults
    }
}

public struct ProxyConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String
    /// Whether the proxy password is saved in the credential vault.
    public var savesPassword: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProxyType = .http,
        host: String = "",
        port: Int = 8080,
        username: String = "",
        savesPassword: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.savesPassword = savesPassword
    }

    public var endpointDescription: String {
        "\(type.displayName) \(host):\(port)"
    }
}

public struct PrivateKeyRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var publicKeyOpenSSH: String
    public var fingerprintSHA256: String
    public var hasPassphrase: Bool
    /// Secret-store account that holds the PEM/OpenSSH private key blob, nil when the key is referenced from disk.
    public var storageRef: String?

    public init(
        id: UUID = UUID(),
        name: String,
        publicKeyOpenSSH: String = "",
        fingerprintSHA256: String = "",
        hasPassphrase: Bool = false,
        storageRef: String? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.hasPassphrase = hasPassphrase
        self.storageRef = storageRef
    }
}

public struct SSHHost: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var groupID: UUID?
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var keyID: UUID?
    /// Identity file path when the user references a key on disk instead of importing it.
    public var identityFilePath: String?
    /// Save the password / passphrase into the app's vault. When false the user is prompted every time.
    public var savesPassword: Bool
    public var proxyPolicy: ProxyPolicy
    public var jumpPolicy: JumpPolicy
    /// nil means inherit from the enclosing group
    public var terminalType: String?
    /// nil means inherit from the enclosing group
    public var encoding: TextEncodingKind?
    public var startDirectory: String?
    public var startupCommand: String?
    /// nil means inherit from the enclosing group
    public var keepaliveSeconds: Int?
    public var reuseConnection: Bool
    public var tags: [String]
    public var colorHex: String?
    public var notes: String
    public var defaultUploadDirectory: String?
    public var sessionLoggingEnabled: Bool?
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    /// How the connection is carried. nil keeps the built-in stack; `system`
    /// hands the session to the local OpenSSH client for legacy servers.
    public var transport: HostTransport?

    public init(
        id: UUID = UUID(),
        groupID: UUID? = nil,
        name: String,
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        keyID: UUID? = nil,
        identityFilePath: String? = nil,
        savesPassword: Bool = true,
        proxyPolicy: ProxyPolicy = .inherit,
        jumpPolicy: JumpPolicy = .inherit,
        terminalType: String? = nil,
        encoding: TextEncodingKind? = nil,
        startDirectory: String? = nil,
        startupCommand: String? = nil,
        keepaliveSeconds: Int? = nil,
        reuseConnection: Bool = true,
        tags: [String] = [],
        colorHex: String? = nil,
        notes: String = "",
        defaultUploadDirectory: String? = nil,
        sessionLoggingEnabled: Bool? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        transport: HostTransport? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyID = keyID
        self.identityFilePath = identityFilePath
        self.savesPassword = savesPassword
        self.proxyPolicy = proxyPolicy
        self.jumpPolicy = jumpPolicy
        self.terminalType = terminalType
        self.encoding = encoding
        self.startDirectory = startDirectory
        self.startupCommand = startupCommand
        self.keepaliveSeconds = keepaliveSeconds
        self.reuseConnection = reuseConnection
        self.tags = tags
        self.colorHex = colorHex
        self.notes = notes
        self.defaultUploadDirectory = defaultUploadDirectory
        self.sessionLoggingEnabled = sessionLoggingEnabled
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.transport = transport
    }

    public var displayAddress: String {
        hostname.isEmpty ? name : (username.isEmpty ? hostname : "\(username)@\(hostname)")
    }
}

// MARK: - Effective (resolved) configuration

/// Fully resolved connection intent for a host, after group inheritance and proxy/jump resolution.
public struct EffectiveHostConfig: Sendable {
    public struct JumpStep: Sendable {
        public var host: SSHHost
        public var proxy: ProxyConfig?
        public init(host: SSHHost, proxy: ProxyConfig?) {
            self.host = host
            self.proxy = proxy
        }
    }

    public var host: SSHHost
    public var proxy: ProxyConfig?
    /// Jump hosts ordered from the hop closest to the client to the hop closest to the target.
    public var jumps: [JumpStep]
    public var encoding: TextEncodingKind
    public var terminalType: String
    public var keepaliveSeconds: Int
    public var startDirectory: String?
    public var startupCommand: String?
    public var sessionLogging: Bool
    public var logPathTemplate: String
    /// Human readable description of where the proxy setting came from, e.g. "Group 'Production'".
    public var proxySourceDescription: String?

    public init(
        host: SSHHost,
        proxy: ProxyConfig?,
        jumps: [JumpStep],
        encoding: TextEncodingKind,
        terminalType: String,
        keepaliveSeconds: Int,
        startDirectory: String?,
        startupCommand: String?,
        sessionLogging: Bool,
        logPathTemplate: String,
        proxySourceDescription: String?
    ) {
        self.host = host
        self.proxy = proxy
        self.jumps = jumps
        self.encoding = encoding
        self.terminalType = terminalType
        self.keepaliveSeconds = keepaliveSeconds
        self.startDirectory = startDirectory
        self.startupCommand = startupCommand
        self.sessionLogging = sessionLogging
        self.logPathTemplate = logPathTemplate
        self.proxySourceDescription = proxySourceDescription
    }
}

// MARK: - DTOs

public struct KnownHostEntry: Identifiable, Codable, Hashable, Sendable {
    /// "host:port"
    public var id: String { "\(hostPort)|\(keyType)" }
    public var hostPort: String
    public var keyType: String
    public var fingerprintSHA256: String
    public var publicKeyBase64: String
    public var firstSeen: Date

    public init(hostPort: String, keyType: String, fingerprintSHA256: String, publicKeyBase64: String, firstSeen: Date = Date()) {
        self.hostPort = hostPort
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.publicKeyBase64 = publicKeyBase64
        self.firstSeen = firstSeen
    }
}

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
}

public enum TransferState: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .paused: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return L("等待中")
        case .running: return L("进行中")
        case .paused: return L("已暂停")
        case .completed: return L("已完成")
        case .failed: return L("失败")
        case .cancelled: return L("已取消")
        }
    }
}

public struct TransferRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var direction: TransferDirection
    public var sourcePath: String
    public var destinationPath: String
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var state: TransferState
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        direction: TransferDirection,
        sourcePath: String,
        destinationPath: String,
        totalBytes: Int64 = 0,
        completedBytes: Int64 = 0,
        state: TransferState = .queued,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.state = state
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

public struct RemoteFileAttributes: Hashable, Sendable {
    public var size: UInt64?
    public var permissions: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var accessTime: Date?
    public var modificationTime: Date?

    public init(size: UInt64? = nil, permissions: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil, accessTime: Date? = nil, modificationTime: Date? = nil) {
        self.size = size
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    public var permissionsOctal: String {
        guard let p = permissions else { return "" }
        return String(format: "%03o", p & 0o777)
    }

    public var permissionsSymbolic: String {
        guard let p = permissions else { return "" }
        func bits(_ v: UInt32, _ shift: UInt32) -> String {
            let r = (v >> shift) & 0b100 != 0
            let w = (v >> shift) & 0b010 != 0
            let x = (v >> shift) & 0b001 != 0
            return "\(r ? "r" : "-")\(w ? "w" : "-")\(x ? "x" : "-")"
        }
        var out = ""
        if p & 0o040000 != 0 { out += "d" } else if p & 0o120000 != 0 { out += "l" } else { out += "-" }
        out += bits(p, 6)
        out += bits(p, 3)
        out += bits(p, 0)
        return out
    }

    public var isDirectory: Bool {
        guard let p = permissions else { return false }
        return (p & 0o170000) == 0o040000
    }

    public var isSymlink: Bool {
        guard let p = permissions else { return false }
        return (p & 0o170000) == 0o120000
    }
}

public struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var longName: String
    public var attributes: RemoteFileAttributes

    public init(name: String, path: String, longName: String = "", attributes: RemoteFileAttributes = .init()) {
        self.name = name
        self.path = path
        self.longName = longName
        self.attributes = attributes
    }

    public var isDirectory: Bool { attributes.isDirectory }
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable, Equatable {
    public var scrollbackLines: Int = 10_000
    public var terminalFontFamily: String = "SF Mono"
    public var terminalFontSize: Double = 13
    public var terminalLineHeight: Double = 1.0
    public var terminalThemeName: String = "Tauge Dark"
    public var terminalBackgroundOpacity: Double = 1.0
    public var optionAsMeta: Bool = true
    public var copyOnSelect: Bool = true
    public var confirmMultilinePaste: Bool = true
    public var defaultTransferConcurrency: Int = 2
    public var transferRetryCount: Int = 3
    public var conflictPolicy: String = "ask"
    public var autoReconnect: Bool = false
    public var editorMaxFileSize: Int = 2 * 1024 * 1024
    public var showHiddenFiles: Bool = false
    public var language: String = TaugeLanguage.systemDefault.rawValue
    public var appearance: String = "system"
    public var confirmCloseRunning: Bool = true
    public var telemetryEnabled: Bool = false
    /// Workspace presentation: "tabs" (one session at a time) or "board"
    /// (kanban of boards == host groups). Persisted so the choice survives.
    public var navigationMode: String = "tabs"
    /// Last folder the local SFTP pane was browsing, so it reopens there.
    public var lastLocalDirectory: String?
    /// Whether the host sidebar is visible. The start page already lists every
    /// host, so the sidebar can be hidden to give the terminal the full width.
    public var sidebarVisible: Bool = false
    /// Command broadcast: keystrokes typed in one workspace pane are replayed
    /// into every other connected pane. Off by default — a shared prompt is
    /// powerful and easy to fire by accident, so it is strictly opt-in.
    public var broadcastInput: Bool = false
    /// Check GitHub for a newer release shortly after launch, at most once a
    /// day. Manual checks from the menu or About panel always run.
    public var automaticallyChecksForUpdates: Bool = true
    /// Enables the local MCP bridge exposed by Tauge.
    public var mcpEnabled: Bool = false
    /// Timestamp of the last successful update check; drives the daily throttle.
    public var lastUpdateCheck: Date?
    /// Ask for Touch ID (falling back to the device password) before a saved
    /// password or key passphrase is read from the vault. On by default: the
    /// vault is a file any process running as the user could open, so the gate
    /// is what keeps a stored credential from being used by someone else.
    public var unlockWithBiometrics: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        scrollbackLines = (try? c.decode(Int.self, forKey: .scrollbackLines)) ?? scrollbackLines
        terminalFontFamily = (try? c.decode(String.self, forKey: .terminalFontFamily)) ?? terminalFontFamily
        terminalFontSize = (try? c.decode(Double.self, forKey: .terminalFontSize)) ?? terminalFontSize
        terminalLineHeight = (try? c.decode(Double.self, forKey: .terminalLineHeight)) ?? terminalLineHeight
        if let stored = try? c.decode(String.self, forKey: .terminalThemeName) {
            // The product was renamed from Tauge to Tauge; migrate the theme key.
            switch stored {
            case "Tauge Dark": terminalThemeName = "Tauge Dark"
            case "Tauge Light": terminalThemeName = "Tauge Light"
            default: terminalThemeName = stored
            }
        }
        terminalBackgroundOpacity = (try? c.decode(Double.self, forKey: .terminalBackgroundOpacity)) ?? terminalBackgroundOpacity
        optionAsMeta = (try? c.decode(Bool.self, forKey: .optionAsMeta)) ?? optionAsMeta
        copyOnSelect = (try? c.decode(Bool.self, forKey: .copyOnSelect)) ?? copyOnSelect
        confirmMultilinePaste = (try? c.decode(Bool.self, forKey: .confirmMultilinePaste)) ?? confirmMultilinePaste
        defaultTransferConcurrency = (try? c.decode(Int.self, forKey: .defaultTransferConcurrency)) ?? defaultTransferConcurrency
        transferRetryCount = (try? c.decode(Int.self, forKey: .transferRetryCount)) ?? transferRetryCount
        conflictPolicy = (try? c.decode(String.self, forKey: .conflictPolicy)) ?? conflictPolicy
        autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? autoReconnect
        editorMaxFileSize = (try? c.decode(Int.self, forKey: .editorMaxFileSize)) ?? editorMaxFileSize
        showHiddenFiles = (try? c.decode(Bool.self, forKey: .showHiddenFiles)) ?? showHiddenFiles
        language = (try? c.decode(String.self, forKey: .language)) ?? language
        appearance = (try? c.decode(String.self, forKey: .appearance)) ?? appearance
        confirmCloseRunning = (try? c.decode(Bool.self, forKey: .confirmCloseRunning)) ?? confirmCloseRunning
        telemetryEnabled = (try? c.decode(Bool.self, forKey: .telemetryEnabled)) ?? telemetryEnabled
        navigationMode = (try? c.decode(String.self, forKey: .navigationMode)) ?? navigationMode
        lastLocalDirectory = (try? c.decodeIfPresent(String.self, forKey: .lastLocalDirectory)) ?? lastLocalDirectory
        sidebarVisible = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? sidebarVisible
        broadcastInput = (try? c.decodeIfPresent(Bool.self, forKey: .broadcastInput)) ?? broadcastInput
        automaticallyChecksForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates)) ?? automaticallyChecksForUpdates
        mcpEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .mcpEnabled)) ?? mcpEnabled
        lastUpdateCheck = (try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)) ?? lastUpdateCheck
        unlockWithBiometrics = (try? c.decodeIfPresent(Bool.self, forKey: .unlockWithBiometrics)) ?? unlockWithBiometrics
    }
}

/// One remembered SFTP folder for a host. Used to reopen the pane where the
/// user left off and to offer a short "recent folders" menu.
public struct SFTPHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var hostID: UUID
    public var path: String
    public var lastUsed: Date
    public var id: String { path }
    public init(hostID: UUID, path: String, lastUsed: Date = Date()) {
        self.hostID = hostID
        self.path = path
        self.lastUsed = lastUsed
    }
}

// MARK: - Terminal boards (split workspaces)

/// A board is a named set of terminal sessions laid out either one at a time
/// (list) or as nested splits (grid). Boards are independent of host groups:
/// the same host can appear in several boards, and a board can hold two live
/// sessions to the same host.
public enum BoardSplitAxis: String, Codable, Sendable, Equatable {
    /// Children are side by side; the divider is a vertical line.
    case horizontal
    /// Children are stacked; the divider is a horizontal line.
    case vertical
}

/// Binary split tree. Leaves point at panes by id, so a layout survives being
/// saved and restored with its own connections.
public indirect enum BoardSplitNode: Codable, Sendable, Equatable {
    case pane(UUID)
    case split(axis: BoardSplitAxis, fraction: Double, first: BoardSplitNode, second: BoardSplitNode)
}

/// One terminal inside a board.
public struct BoardPaneDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    /// Whether this pane's SFTP browser was open, so a board reopens the same way.
    public var showsSFTP: Bool

    public init(id: UUID = UUID(), hostID: UUID, showsSFTP: Bool = false) {
        self.id = id
        self.hostID = hostID
        self.showsSFTP = showsSFTP
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hostID
        case showsSFTP
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        // Boards saved before panes could own SFTP browsers have no flag.
        showsSFTP = (try? container.decodeIfPresent(Bool.self, forKey: .showsSFTP)) ?? false
    }
}

/// A persisted board: pane list, split layout and which pane had focus.
public struct BoardDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Optional accent used by the workspace header and tab chip.
    public var colorHex: String?
    public var panes: [BoardPaneDefinition]
    /// "list" shows the focused pane only; "grid" renders `tree`.
    public var layout: String
    public var tree: BoardSplitNode?
    public var focusedPaneID: UUID?

    public init(id: UUID = UUID(),
                name: String,
                colorHex: String? = nil,
                panes: [BoardPaneDefinition] = [],
                layout: String = "list",
                tree: BoardSplitNode? = nil,
                focusedPaneID: UUID? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.panes = panes
        self.layout = layout
        self.tree = tree
        self.focusedPaneID = focusedPaneID
    }

    public var isGrid: Bool { layout == "grid" }
    public var paneIDs: [UUID] { panes.map { $0.id } }
    public func pane(id: UUID) -> BoardPaneDefinition? { panes.first { $0.id == id } }
    public func hostID(forPane paneID: UUID) -> UUID? { pane(id: paneID)?.hostID }

    /// The workspace that results from dropping one terminal tab onto another:
    /// both panes side by side, the dropped one focused. Pure, so the layout can
    /// be checked without a running app.
    public static func sideBySide(_ first: BoardPaneDefinition,
                                  _ second: BoardPaneDefinition,
                                  name: String) -> BoardDefinition {
        BoardDefinition(name: name,
                        panes: [first, second],
                        layout: "grid",
                        tree: .split(axis: .horizontal,
                                     fraction: 0.5,
                                     first: .pane(first.id),
                                     second: .pane(second.id)),
                        focusedPaneID: second.id)
    }
}

/// Names for workspaces that the app derives instead of asking the user.
public enum BoardNaming {
    /// Placeholder name for a workspace made by dragging one tab onto another:
    /// “left + right”, or “host ×2” for two sessions to the same server. Saving
    /// such a workspace asks for the real name, so this is only what the chip
    /// shows before that.
    public static func split(first: String, second: String, limit: Int = 60) -> String {
        let left = first.trimmingCharacters(in: .whitespaces)
        let right = second.trimmingCharacters(in: .whitespaces)
        let base: String
        if left == right {
            base = left.isEmpty ? L("分屏工作区") : left + " ×2"
        } else {
            base = (left.isEmpty ? "?" : left) + " + " + (right.isEmpty ? "?" : right)
        }
        return String(base.prefix(limit))
    }
}

/// Pure tree operations, kept in the kit so they can be unit-checked without a
/// running app. Everything is value-in/value-out.
public enum BoardSplitTree {
    /// Ordered pane ids in a tree.
    public static func leaves(_ node: BoardSplitNode) -> [UUID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return leaves(first) + leaves(second)
        }
    }

    /// Even grid for the given panes: rows of ceil(sqrt(n)) cells, stacked.
    public static func grid(for panes: [UUID]) -> BoardSplitNode? {
        guard !panes.isEmpty else { return nil }
        if panes.count == 1 { return .pane(panes[0]) }
        let columns = Int(Double(panes.count).squareRoot().rounded(.up))
        var rows: [BoardSplitNode] = []
        var index = 0
        while index < panes.count {
            let end = min(index + columns, panes.count)
            rows.append(chain(panes[index..<end].map { BoardSplitNode.pane($0) }, axis: .horizontal))
            index = end
        }
        return chain(rows, axis: .vertical)
    }

    /// Chains nodes with equal shares along one axis.
    public static func chain(_ nodes: [BoardSplitNode], axis: BoardSplitAxis) -> BoardSplitNode {
        guard let first = nodes.first else { preconditionFailure("empty chain") }
        guard nodes.count > 1 else { return first }
        let rest = Array(nodes.dropFirst())
        return .split(axis: axis, fraction: 1.0 / Double(nodes.count), first: first, second: chain(rest, axis: axis))
    }

    /// Replaces a leaf with a split that holds the leaf and a new pane. With
    /// `newFirst` the new pane lands on the left/top instead of the right/bottom.
    public static func splitting(_ node: BoardSplitNode,
                                 leaf: UUID,
                                 axis: BoardSplitAxis,
                                 newPane: UUID,
                                 newFirst: Bool = false,
                                 fraction: Double = 0.5) -> BoardSplitNode {
        switch node {
        case .pane(let id):
            guard id == leaf else { return node }
            let first: BoardSplitNode = newFirst ? .pane(newPane) : .pane(id)
            let second: BoardSplitNode = newFirst ? .pane(id) : .pane(newPane)
            return .split(axis: axis, fraction: fraction, first: first, second: second)
        case .split(let splitAxis, let current, let first, let second):
            return .split(axis: splitAxis,
                          fraction: current,
                          first: splitting(first, leaf: leaf, axis: axis, newPane: newPane, newFirst: newFirst, fraction: fraction),
                          second: splitting(second, leaf: leaf, axis: axis, newPane: newPane, newFirst: newFirst, fraction: fraction))
        }
    }

    /// Moves an existing pane next to `target` (or into its slot). Used when a
    /// pane is dropped on a neighbour: the pane is unplugged from its old place
    /// and re-attached to the given edge, so no empty hole is left behind.
    public static func moving(_ node: BoardSplitNode,
                              source: UUID,
                              onto target: UUID,
                              axis: BoardSplitAxis,
                              newFirst: Bool) -> BoardSplitNode {
        guard source != target,
              leaves(node).contains(source),
              leaves(node).contains(target),
              let rest = removing(node, leaf: source),
              leaves(rest).contains(target) else { return node }
        return splitting(rest, leaf: target, axis: axis, newPane: source, newFirst: newFirst)
    }

    /// Removes a leaf, collapsing the parent split into the surviving child.
    public static func removing(_ node: BoardSplitNode, leaf: UUID) -> BoardSplitNode? {
        switch node {
        case .pane(let id):
            return id == leaf ? nil : node
        case .split(let axis, let fraction, let first, let second):
            let left = removing(first, leaf: leaf)
            let right = removing(second, leaf: leaf)
            switch (left, right) {
            case (nil, nil): return nil
            case (let only?, nil): return only
            case (nil, let only?): return only
            case (let left?, let right?): return .split(axis: axis, fraction: fraction, first: left, second: right)
            }
        }
    }

    /// Swaps two leaves, keeping the surrounding layout untouched.
    public static func swapping(_ node: BoardSplitNode, _ first: UUID, _ second: UUID) -> BoardSplitNode {
        switch node {
        case .pane(let id):
            if id == first { return .pane(second) }
            if id == second { return .pane(first) }
            return node
        case .split(let axis, let fraction, let left, let right):
            return .split(axis: axis,
                          fraction: fraction,
                          first: swapping(left, first, second),
                          second: swapping(right, first, second))
        }
    }

    /// Sets the fraction of the split reached by `path` (0 = first child,
    /// 1 = second child), clamped so panes keep a usable minimum.
    public static func settingFraction(_ node: BoardSplitNode, path: [Int], fraction: Double) -> BoardSplitNode {
        guard case .split(let axis, let current, let first, let second) = node else { return node }
        let clamped = min(0.88, max(0.12, fraction))
        guard let step = path.first else {
            return .split(axis: axis, fraction: clamped, first: first, second: second)
        }
        var rest = path
        rest.removeFirst()
        if step == 0 {
            return .split(axis: axis, fraction: current, first: settingFraction(first, path: rest, fraction: fraction), second: second)
        }
        return .split(axis: axis, fraction: current, first: first, second: settingFraction(second, path: rest, fraction: fraction))
    }

    /// Snaps a dragged divider to one of the familiar fractions.
    public static func snapped(_ value: Double, tolerance: Double = 0.045) -> Double {
        let targets = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75]
        var best = min(0.88, max(0.12, value))
        var bestDistance = tolerance
        for target in targets {
            let distance = abs(value - target)
            if distance < bestDistance {
                bestDistance = distance
                best = target
            }
        }
        return best
    }

    /// Drops leaves that no longer exist (e.g. a pane was closed while the app
    /// was not running) and returns nil when nothing is left.
    public static func pruning(_ node: BoardSplitNode, keeping panes: Set<UUID>) -> BoardSplitNode? {
        switch node {
        case .pane(let id):
            return panes.contains(id) ? node : nil
        case .split(let axis, let fraction, let first, let second):
            let left = pruning(first, keeping: panes)
            let right = pruning(second, keeping: panes)
            switch (left, right) {
            case (nil, nil): return nil
            case (let only?, nil): return only
            case (nil, let only?): return only
            case (let left?, let right?): return .split(axis: axis, fraction: fraction, first: left, second: right)
            }
        }
    }
}

/// Persisted list of tabs so that a crash/restart can restore the workspace.
public struct WorkspaceSnapshot: Codable, Sendable {
    public struct Tab: Codable, Sendable {
        public var hostID: UUID
        public var title: String
        public var lastRemoteDirectory: String?
        public var showsSFTP: Bool
        /// Hosts of the extra SFTP panes that were open in this tab.
        public var additionalHostIDs: [UUID]?
        /// "terminal" (default) or "sftp": an SFTP-only tab has no shell.
        public var kind: String?
        public init(hostID: UUID,
                    title: String,
                    lastRemoteDirectory: String? = nil,
                    showsSFTP: Bool = false,
                    additionalHostIDs: [UUID]? = nil,
                    kind: String? = nil) {
            self.hostID = hostID
            self.title = title
            self.lastRemoteDirectory = lastRemoteDirectory
            self.showsSFTP = showsSFTP
            self.additionalHostIDs = additionalHostIDs
            self.kind = kind
        }
    }

    public var tabs: [Tab]
    public var selectedIndex: Int

    public init(tabs: [Tab] = [], selectedIndex: Int = 0) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}
