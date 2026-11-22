import Foundation
import TaugeKit

enum TabConnectionState: Equatable {
    case idle
    case connecting(String)
    case connected
    case disconnected(String)
    case failed(String)

    var isConnected: Bool { self == .connected }
    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return L("未连接")
        case .connecting(let stage): return stage
        case .connected: return L("已连接")
        case .disconnected(let reason): return L("已断开 · %@", reason)
        case .failed(let reason): return L("失败 · %@", reason)
        }
    }
}

/// What a tab shows. An SFTP tab has no shell: it connects, opens the file
/// browser and lets several servers be browsed side by side.
enum TabKind: String, Codable, Sendable {
    case terminal
    case sftp
}

/// One terminal tab: owns its SSH connection, terminal channel, SFTP client and
/// the two browser panes. Tabs are created instantly and connect in the
/// background so the UI never blocks on the network.
///
/// The tab strip is labelled with the host's own name, nothing the remote shell
/// sends (see `TerminalBridge.setTerminalTitle`). Browser-only
/// tabs get a suffix so they never collide with a shell tab of the same host.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id: UUID
    let kind: TabKind
    let hostID: UUID
    @Published var host: SSHHost
    @Published var title: String
    @Published var connectionState: TabConnectionState = .idle
    /// Fraction of the pane height used by the terminal when the SFTP browser
    /// is open. Kept on the tab so the divider position survives view churn.
    @Published var sftpSplitFraction: Double = 0.5
    @Published var showsSFTP = false
    @Published var sftpLoading = false
    @Published var statusMessage = ""
    @Published var statusDetail = ""
    @Published var reportFingerprint = false
    @Published var lastRemoteDirectory: String?

    let bridge = TerminalBridge()
    /// Primary remote pane (the tab's own host). Extra panes let one local
    /// browser talk to several servers at once.
    let remote: RemoteBrowserModel
    @Published var extraRemotes: [RemoteBrowserModel] = []
    let local: LocalBrowserModel

    var client: SSHClient?
    var terminalSession: SSHTerminalSession?
    /// SSH connections opened purely for extra SFTP panes, keyed by pane id.
    var remoteClients: [UUID: SSHClient] = [:]
    /// Extra panes to reopen once the tab's own connection is established.
    var pendingPaneHostIDs: [UUID] = []
    /// SFTP client of the primary pane.
    var sftpClient: SFTPClient? { remote.client }
    var logger: SessionLogger?
    var encoding: TextEncodingKind = .utf8
    var terminalType = "xterm-256color"
    var routeSummary = ""
    var connectTask: Task<Void, Never>?
    /// Pending automatic reconnect of the tab's own connection.
    var reconnectTask: Task<Void, Never>?
    /// Pending automatic reconnect of an extra pane's dedicated connection.
    var paneReconnectTasks: [UUID: Task<Void, Never>] = [:]
    var connectedAt: Date?
    var reconnectAttempt = 0
    var didAutoOpenSFTP = false
    var isClosing = false

    init(id: UUID = UUID(),
         kind: TabKind = .terminal,
         host: SSHHost,
         localFiles: LocalFileService,
         startRemoteDirectory: String? = nil,
         localStartDirectory: String? = nil,
         showsSFTP: Bool = false) {
        self.id = id
        self.kind = kind
        self.hostID = host.id
        self.host = host
        self.title = TerminalTab.label(for: host)
        self.showsSFTP = showsSFTP || kind == .sftp
        self.lastRemoteDirectory = startRemoteDirectory
        self.remote = RemoteBrowserModel()
        self.remote.hostID = host.id
        self.remote.hostName = Self.label(for: host)
        // A host's configured upload folder wins; otherwise reopen the folder the
        // user last browsed locally.
        self.local = LocalBrowserModel(service: localFiles,
                                       startDirectory: host.defaultUploadDirectory ?? localStartDirectory)
        self.remote.showHidden = false
        if let start = startRemoteDirectory, !start.isEmpty {
            self.remote.path = start
        }
        bridge.onResize = { [weak self] columns, rows in self?.resize(columns: columns, rows: rows) }
        bridge.onDirectoryChange = { [weak self] directory in self?.lastRemoteDirectory = directory }
        bridge.onBackgroundReply = { [weak self] data in self?.write(data) }
    }

    /// Tab-strip label: exactly the name the user gave the host. Nothing else is
    /// ever appended — an SFTP tab is told apart by its folder icon, and the two
    /// kinds are separate tabs even with "reuse connection" on.
    static func label(for host: SSHHost) -> String {
        host.name.isEmpty ? host.hostname : host.name
    }

    var isTerminalActive: Bool { terminalSession?.isActive == true }

    func write(_ data: Data) {
        terminalSession?.write(data)
        logger?.append(data)
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Output coming back from the server: shown in the terminal and written to
    /// the session log when logging is enabled.
    func receive(_ data: Data) {
        bridge.feed(data)
        logger?.append(data)
    }

    /// The size the terminal view last asked for.
    ///
    /// A tab's view is mounted (and sized to the pane) before the SSH channel
    /// exists, so its resize callbacks arrive while `terminalSession` is still
    /// nil. Remembering the last size here lets the channel be opened with the
    /// real pane size instead of the 100x30 placeholder — otherwise full-screen
    /// programs (vim, htop, tmux) drew themselves in the top-left corner of an
    /// oversized grid, which read as "the content only fills half the window".
    private(set) var terminalColumns = 100
    private(set) var terminalRows = 30

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, columns != terminalColumns || rows != terminalRows else { return }
        terminalColumns = columns
        terminalRows = rows
        terminalSession?.resize(columns: columns, rows: rows)
    }

    func setEncoding(_ encoding: TextEncodingKind) {
        self.encoding = encoding
    }

    func attach(client: SSHClient, session: SSHTerminalSession, encoding: TextEncodingKind, terminalType: String, route: String, logger: SessionLogger?) {
        self.client = client
        self.terminalSession = session
        self.encoding = encoding
        self.terminalType = terminalType
        self.routeSummary = route
        self.logger = logger
        self.connectedAt = Date()
        self.reconnectAttempt = 0
        self.connectionState = .connected
    }

    /// Connection for a tab with no shell: keeps the client, skips the
    /// terminal channel.
    func attachClientOnly(client: SSHClient, encoding: TextEncodingKind, terminalType: String, route: String) {
        self.client = client
        self.encoding = encoding
        self.terminalType = terminalType
        self.routeSummary = route
        self.connectedAt = Date()
        self.reconnectAttempt = 0
        self.connectionState = .connected
    }

    func attach(sftp: SFTPClient) {
        remote.setClient(sftp)
    }

    /// Every remote pane, primary first.
    var allRemotes: [RemoteBrowserModel] { [remote] + extraRemotes }

    func sshClient(for pane: RemoteBrowserModel) -> SSHClient? {
        if pane === remote { return client }
        return remoteClients[pane.id]
    }

    /// Drops a pane (and its dedicated SSH connection) without touching the tab.
    func removeRemotePane(_ pane: RemoteBrowserModel) {
        guard pane !== remote else { return }
        if let sftp = pane.client {
            Task { await sftp.shutdown() }
        }
        if let ssh = remoteClients.removeValue(forKey: pane.id) {
            Task { await ssh.disconnect() }
        }
        paneReconnectTasks[pane.id]?.cancel()
        paneReconnectTasks[pane.id] = nil
        pane.setClient(nil)
        extraRemotes.removeAll { $0.id == pane.id }
    }

    func markConnecting(_ stage: String) {
        connectionState = .connecting(stage)
    }

    func markDisconnected(_ reason: String) {
        connectionState = .disconnected(reason)
        terminalSession = nil
    }

    func markFailed(_ message: String) {
        connectionState = .failed(message)
        terminalSession = nil
    }

    /// Sends a startup command once the shell prompt has had a moment to
    /// appear. Used for hosts configured with "run command on connect".
    func runStartupCommandIfNeeded(
        confirm: @escaping @MainActor (String, CommandRiskAssessment) async -> Bool
    ) {
        guard let command = host.startupCommand, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            let assessment = CommandRiskClassifier.assess(command)
            if assessment.requiresConfirmation, !(await confirm(command, assessment)) { return }
            self.write(command + "\n")
        }
    }

    func teardown() {
        logger?.close()
        logger = nil
        terminalSession?.close()
        terminalSession = nil
        for pane in allRemotes {
            if let sftp = pane.client {
                Task { await sftp.shutdown() }
            }
            pane.setClient(nil)
        }
        for (_, ssh) in remoteClients {
            Task { await ssh.disconnect() }
        }
        remoteClients.removeAll()
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

    func close() {
        isClosing = true
        connectTask?.cancel()
        connectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        for (_, task) in paneReconnectTasks { task.cancel() }
        paneReconnectTasks.removeAll()
        teardown()
        bridge.close()
        extraRemotes.removeAll()
        connectionState = .idle
    }

    /// Metadata persisted for crash recovery. Contents and secrets are never
    /// stored, per the PRD's recovery requirements.
    var snapshot: WorkspaceSnapshot.Tab {
        WorkspaceSnapshot.Tab(hostID: hostID,
                              title: title,
                              lastRemoteDirectory: remote.path,
                              showsSFTP: showsSFTP,
                              additionalHostIDs: extraRemotes.compactMap { $0.hostID },
                              kind: kind.rawValue)
    }
}

/// Appends raw terminal output to a per-host log file. Writes are serialized on
/// a private queue so a chatty build log cannot stall the main thread.
final class SessionLogger: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.tauge.session-log")
    private let redactions: [String]

    init?(directory: URL, hostName: String, redactions: [String] = []) {
        let fm = FileManager.default
        let safeHost = hostName.replacingOccurrences(of: "/", with: "_")
        let folder = directory.appendingPathComponent(safeHost, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let file = folder.appendingPathComponent(formatter.string(from: Date()) + ".log")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
        self.redactions = redactions
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [handle, redactions] in
            var payload = data
            if !redactions.isEmpty, var text = String(data: data, encoding: .utf8) {
                for secret in redactions where !secret.isEmpty {
                    text = text.replacingOccurrences(of: secret, with: "[redacted]")
                }
                payload = Data(text.utf8)
            }
            try? handle.write(contentsOf: payload)
        }
    }

    func close() {
        queue.sync { [handle] in
            try? handle.close()
        }
    }

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Logs", isDirectory: true)
    }
}
