import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Logging

/// Where a connection attempt failed, used to give the user actionable advice.
public enum SSHConnectionStage: String, Sendable {
    case dns
    case tcp
    case proxy
    case keyExchange
    case hostKey
    case authentication
    case channel

    public var displayName: String {
        switch self {
        case .dns: return "域名解析"
        case .tcp: return "建立 TCP 连接"
        case .proxy: return "代理握手"
        case .keyExchange: return "算法协商"
        case .hostKey: return "主机密钥校验"
        case .authentication: return "身份认证"
        case .channel: return "打开会话通道"
        }
    }

    public var suggestion: String {
        switch self {
        case .dns: return "请检查主机地址拼写，或确认当前网络可以解析该域名。"
        case .tcp: return "请确认主机在线、端口正确，并检查防火墙或安全组设置。"
        case .proxy: return "请先在代理设置里点「测试」：它会把「到代理的 TCP 不通」和「代理拒绝这条隧道」区分开，再按提示检查地址、类型或账号。"
        case .keyExchange: return "服务器可能只支持过时的算法，请升级服务器 SSH 版本。"
        case .hostKey: return "主机密钥与记录不一致，可能存在中间人攻击；确认无误后可更新记录。"
        case .authentication: return "请检查用户名、密码或私钥是否匹配，以及服务器是否允许该认证方式。"
        case .channel: return "服务器拒绝打开会话，可能限制了会话数量或子系统。"
        }
    }
}

public struct SSHConnectionError: Error, LocalizedError {
    public let stage: SSHConnectionStage
    public let detail: String
    public let host: String
    public let port: Int

    public init(stage: SSHConnectionStage, detail: String, host: String, port: Int) {
        self.stage = stage
        self.detail = detail
        self.host = host
        self.port = port
    }

    public var errorDescription: String? {
        return stage.displayName + "失败（" + host + ":" + String(port) + "）：" + detail
    }

    public var recoverySuggestion: String? {
        return stage.suggestion
    }
}

public struct SSHJumpEndpoint: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SSHAuthMaterial
    public var hostKeyValidator: HostKeyValidator

    public init(host: String, port: Int, username: String, auth: SSHAuthMaterial, hostKeyValidator: @escaping HostKeyValidator) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyValidator = hostKeyValidator
    }
}

public struct SSHConnectOptions: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SSHAuthMaterial
    public var hostKeyValidator: HostKeyValidator
    public var proxy: ProxyEndpoint?
    public var jumps: [SSHJumpEndpoint]
    public var connectTimeout: TimeAmount
    public var keepaliveSeconds: Int
    /// Built-in NIO stack or the local /usr/bin/ssh. See `HostTransport`.
    public var transport: HostTransport
    /// Credentials for the system ssh transport. Ignored by the built-in stack.
    public var systemCredential: SystemSSHCredential

    public init(host: String,
                port: Int,
                username: String,
                auth: SSHAuthMaterial,
                hostKeyValidator: @escaping HostKeyValidator,
                proxy: ProxyEndpoint? = nil,
                jumps: [SSHJumpEndpoint] = [],
                connectTimeout: TimeAmount = .seconds(20),
                keepaliveSeconds: Int = 0,
                transport: HostTransport = .builtin,
                systemCredential: SystemSSHCredential = .none) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyValidator = hostKeyValidator
        self.proxy = proxy
        self.jumps = jumps
        self.connectTimeout = connectTimeout
        self.keepaliveSeconds = keepaliveSeconds
        self.transport = transport
        self.systemCredential = systemCredential
    }
}

public enum SSHClientState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected(String)
}

/// A single SSH connection (optionally tunneled through 1-3 jump hosts) that can
/// open multiple terminal and SFTP channels.
public actor SSHClient {
    private var group: MultiThreadedEventLoopGroup?
    private let ownsGroup: Bool
    private var rootChannel: Channel?
    private var sshHandler: NIOSSHHandler?
    private var state: SSHClientState = .idle
    private var hopDescriptions: [String] = []
    private var targetAuthDelegate: SSHAuthDelegate?
    private var channelTimeout: TimeAmount = .seconds(20)
    /// How many channels this connection has opened successfully. A transport that
    /// dies before the first one never finished the SSH handshake.
    private var openedChannelCount = 0
    /// Set when the transport closed itself before the handshake completed, so later
    /// channel requests can report the real cause instead of a bare "not connected".
    private var handshakeFailure: SSHConnectionError?
    /// Set when the connection is carried by the local /usr/bin/ssh instead of
    /// the in-process stack. The workspace keeps the temporary identity file and
    /// askpass helper alive for as long as any child process uses them.
    private var transportKind: HostTransport = .builtin
    private var systemWorkspace: SystemSSHWorkspace?
    private var systemOptions: SystemSSHOptions?
    private var systemChildren: [SystemSSHChild] = []
    private let logger = Logger(label: "shellx.ssh")

    public init(eventLoopGroup: MultiThreadedEventLoopGroup? = nil) {
        if let eventLoopGroup {
            self.group = eventLoopGroup
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    public var currentState: SSHClientState {
        state
    }

    public var jumpChainDescription: [String] {
        hopDescriptions
    }

    public var isConnected: Bool {
        if case .connected = state {
            if transportKind == .system {
                return systemWorkspace != nil
            }
            return rootChannel?.isActive ?? false
        }
        return false
    }

    /// Connects through the jump chain and authenticates with the final host.
    public func connect(_ options: SSHConnectOptions) async throws {
        if case .idle = state {
            // Fresh connection.
        } else if case .disconnected = state {
            state = .idle
        } else {
            throw SSHConnectionError(stage: .channel, detail: "连接已存在或正在建立", host: options.host, port: options.port)
        }
        if options.transport == .system {
            try await connectWithSystemSSH(options)
            return
        }
        guard let group else {
            throw SSHConnectionError(stage: .tcp, detail: "事件循环组已关闭", host: options.host, port: options.port)
        }
        state = .connecting
        openedChannelCount = 0
        handshakeFailure = nil
        var stage: SSHConnectionStage = .tcp
        // The transport that is currently open; closed on any failure so a
        // rejected handshake cannot leave a socket behind.
        var openedChannel: Channel?
        // Whichever machine the current step talks to: the first jump host, a later
        // hop, or the destination. Errors are reported against this, not the target.
        var activeHost = options.jumps.first?.host ?? options.host
        var activePort = options.jumps.first?.port ?? options.port
        var hopContext: String?
        do {
            stage = options.proxy == nil ? .tcp : .proxy
            // With a jump chain the socket goes to the first hop; the destination is
            // only reachable through direct-tcpip, so connecting to it directly would
            // fail on any network where it is not routable.
            var transport = try await TCPConnector.connect(targetHost: activeHost,
                                                           targetPort: activePort,
                                                           proxy: options.proxy,
                                                           group: group,
                                                           timeout: options.connectTimeout)
            openedChannel = transport
            var descriptions: [String] = []
            var tunnelHops: [SSHJumpEndpoint] = options.jumps
            var destinationHost = options.host
            var destinationPort = options.port
            var hopIndex = 0

            while !tunnelHops.isEmpty {
                let jump = tunnelHops.removeFirst()
                hopIndex += 1
                activeHost = jump.host
                activePort = jump.port
                hopContext = "第 " + String(hopIndex) + " 跳 " + jump.username + "@" + jump.host + ":" + String(jump.port)
                stage = .keyExchange
                let (jumpHandler, jumpAuthDelegate) = try await addSSHHandler(to: transport,
                                                               host: jump.host,
                                                               port: jump.port,
                                                               username: jump.username,
                                                               auth: jump.auth,
                                                               validator: jump.hostKeyValidator)
                descriptions.append(jump.username + "@" + jump.host + ":" + String(jump.port))
                let nextHost = tunnelHops.first?.host ?? destinationHost
                let nextPort = tunnelHops.first?.port ?? destinationPort
                stage = .channel
                let tunnel = try await openTunnelChannel(handler: jumpHandler,
                                                         parent: transport,
                                                         targetHost: nextHost,
                                                         targetPort: nextPort,
                                                         authDelegate: jumpAuthDelegate)
                transport = tunnel
                openedChannel = tunnel
                activeHost = nextHost
                activePort = nextPort
            }

            // The destination handshake rides on the tunnel set up above.
            if hopIndex > 0 {
                hopContext = "经 " + String(hopIndex) + " 跳"
            }
            stage = .keyExchange
            let (handler, authDelegate) = try await addSSHHandler(to: transport,
                                                                  host: options.host,
                                                                  port: options.port,
                                                                  username: options.username,
                                                                  auth: options.auth,
                                                                  validator: options.hostKeyValidator)
            self.rootChannel = transport
            self.sshHandler = handler
            self.targetAuthDelegate = authDelegate
            self.channelTimeout = options.connectTimeout
            self.hopDescriptions = descriptions
            self.state = .connected
            // NIOSSH completes the key exchange lazily, when the first channel is
            // opened. Without this throwaway channel a server that refuses every
            // algorithm we offer still looks connected here, and the failure only
            // surfaces when the terminal channel opens — after the app has told the
            // user it was connected and too late for the caller to fall back to the
            // system ssh client.
            let handshakeProbe: Channel
            do {
                handshakeProbe = try await openChildChannel(handler: handler, parent: transport, type: .session)
            } catch {
                let mapped = SSHClient.mapError(error, stage: .keyExchange, host: options.host, port: options.port)
                // The TCP connection is up, so a probe channel that never opens means the
                // SSH handshake itself was rejected. Report that (not "connection closed")
                // so the caller can retry with a transport that speaks the legacy algorithms.
                if let connectionError = mapped as? SSHConnectionError,
                   connectionError.stage == .tcp || connectionError.stage == .channel {
                    throw SSHClient.handshakeFailure(for: options)
                }
                throw mapped
            }
            handshakeProbe.close(mode: .all, promise: nil)
            startKeepalive(seconds: options.keepaliveSeconds)
            logger.info("connected")
            let handshakeError = SSHClient.handshakeFailure(for: options)
            transport.closeFuture.whenComplete { [weak self] _ in
                Task { await self?.handleChannelClosed(failure: handshakeError) }
            }
        } catch {
            if let channel = openedChannel ?? rootChannel {
                channel.close(mode: .all, promise: nil)
            }
            state = .disconnected(String(describing: error))
            // A jump host that drops the connection the moment the socket opens is
            // what a server offering only ssh-rsa / SHA-1 looks like from here: the
            // hop's handshake is refused before any channel exists. Reporting that as
            // a plain "connection closed" would hide the real cause and stop the app
            // from switching this host to the system ssh transport.
            if let hopContext, let hopError = SSHClient.rejectedHandshake(at: hopContext,
                                                                          error: error,
                                                                          host: activeHost,
                                                                          port: activePort) {
                throw hopError
            }
            let mapped = SSHClient.mapError(error, stage: stage, host: activeHost, port: activePort)
            if let hopContext, var connectionError = mapped as? SSHConnectionError {
                connectionError = SSHConnectionError(stage: connectionError.stage,
                                                     detail: hopContext + "：" + connectionError.detail,
                                                     host: activeHost,
                                                     port: activePort)
                throw connectionError
            }
            throw mapped
        }
    }

    private func addSSHHandler(to channel: Channel,
                               host: String,
                               port: Int,
                               username: String,
                               auth: SSHAuthMaterial,
                               validator: @escaping HostKeyValidator) async throws -> (NIOSSHHandler, SSHAuthDelegate) {
        var offers: [NIOSSHUserAuthenticationOffer.Offer]
        switch auth {
        case .password(let password):
            offers = [.password(.init(password: password))]
        case .privateKey(let key):
            offers = [.privateKey(.init(privateKey: key))]
            // RFC 8332 servers may only allow one of the two RSA signature algorithms
            // (for example `PubkeyAcceptedAlgorithms rsa-sha2-256`), so offer the other one
            // as a fallback instead of failing the connection outright.
            if let current = key.rsaSignatureAlgorithm {
                let alternate: NIOSSHRSASignatureAlgorithm = current == .rsaSHA2_512 ? .rsaSHA2_256 : .rsaSHA2_512
                if let retry = key.withRSASignatureAlgorithm(alternate) {
                    offers.append(.privateKey(.init(privateKey: retry)))
                }
            }
        case .none:
            offers = [.none]
        }
        let authDelegate = SSHAuthDelegate(username: username, offers: offers)
        let serverDelegate = HostKeyValidationDelegate(host: host, port: port, validator: validator)
        let configuration = SSHClientConfiguration(userAuthDelegate: authDelegate, serverAuthDelegate: serverDelegate)
        let handler = NIOSSHHandler(role: .client(configuration),
                                    allocator: channel.allocator,
                                    inboundChildChannelInitializer: nil)
        try await channel.pipeline.addHandler(handler).get()
        try await TCPConnector.startReading(channel)
        return (handler, authDelegate)
    }

    private final class AdapterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SSHChannelAdapter?
        var adapter: SSHChannelAdapter? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    private func openChildChannel(handler: NIOSSHHandler,
                                  parent: Channel,
                                  type: SSHChannelType,
                                  adapter: ChannelHandler? = nil,
                                  authDelegate: SSHAuthDelegate? = nil,
                                  deferReads: Bool = false) async throws -> Channel {
        let promise = parent.eventLoop.makePromise(of: Channel.self)
        // NIOSSH never fails a pending channel when the server rejects the
        // credentials, so bound the wait ourselves and report the real cause.
        let timeoutTask = parent.eventLoop.scheduleTask(in: channelTimeout) {
            promise.fail(SSHClientError.channelOpenTimedOut)
        }
        parent.eventLoop.execute {
            handler.createChannel(promise, channelType: type) { channel, _ in
                // A tunneled channel carries a nested SSH handshake whose greeting is
                // sent by the peer unprompted, so reads stay paused until the caller has
                // installed its handler; otherwise that greeting is dropped.
                let setup = deferReads
                    ? channel.setOption(ChannelOptions.autoRead, value: false)
                    : channel.eventLoop.makeSucceededVoidFuture()
                return setup.flatMap {
                    if let adapter {
                        return channel.pipeline.addHandler(adapter)
                    }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
            }
        }
        do {
            let channel = try await promise.futureResult.get()
            timeoutTask.cancel()
            openedChannelCount += 1
            return channel
        } catch {
            throw mapChannelOpenError(error, authDelegate: authDelegate ?? targetAuthDelegate)
        }
    }

    private func mapChannelOpenError(_ error: Error, authDelegate: SSHAuthDelegate?) -> Error {
        if let failure = handshakeFailure, error is ChannelError || error is NIOSSHError {
            // The transport died before the handshake finished; ChannelError.eof from a
            // torn-down pipeline would otherwise be all the user sees.
            return failure
        }
        if let error = error as? SSHClientError, case .channelOpenTimedOut = error {
            if authDelegate?.didExhaustOffers ?? false {
                return SSHConnectionError(stage: .authentication,
                                          detail: "服务器拒绝了所有可用的认证方式（私钥或密码）",
                                          host: "",
                                          port: 0)
            }
            return SSHConnectionError(stage: .channel,
                                      detail: "服务器没有响应打开通道的请求，连接可能已被中断",
                                      host: "",
                                      port: 0)
        }
        return error
    }

    private func openTunnelChannel(handler: NIOSSHHandler,
                                   parent: Channel,
                                   targetHost: String,
                                   targetPort: Int,
                                   authDelegate: SSHAuthDelegate) async throws -> Channel {
        // The tunnel carries a nested SSH stream, so the adapter must forward bytes in
        // both directions instead of handing them to a terminal/SFTP sink.
        let adapter = SSHStreamAdapter()
        let type = SSHChannelType.directTCPIP(.init(targetHost: targetHost,
                                                    targetPort: targetPort,
                                                    originatorAddress: try SocketAddress(ipAddress: "0.0.0.0", port: 0)))
        // Reads start when addSSHHandler installs the next hop's handler and calls startReading.
        return try await openChildChannel(handler: handler,
                                          parent: parent,
                                          type: type,
                                          adapter: adapter,
                                          authDelegate: authDelegate,
                                          deferReads: true)
    }

    /// Opens an interactive shell with a pseudo terminal.
    public func openTerminal(term: String,
                             columns: Int,
                             rows: Int,
                             onData: @escaping @Sendable (Data) -> Void,
                             onClose: @escaping @Sendable (Error?) -> Void) async throws -> SSHTerminalSession {
        if transportKind == .system {
            return try openSystemTerminal(term: term,
                                          columns: columns,
                                          rows: rows,
                                          onData: onData,
                                          onClose: onClose)
        }
        guard let handler = sshHandler, let root = rootChannel, root.isActive else {
            throw handshakeFailure ?? SSHClientError.notConnected
        }
        let box = AdapterBox()
        let adapter = SSHChannelAdapter()
        box.adapter = adapter
        let channel = try await openChildChannel(handler: handler, parent: root, type: .session, adapter: adapter)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true,
                                                               term: term,
                                                               terminalCharacterWidth: max(columns, 1),
                                                               terminalRowHeight: max(rows, 1),
                                                               terminalPixelWidth: 0,
                                                               terminalPixelHeight: 0,
                                                               terminalModes: SSHTerminalModes([:]))
        do {
            try await channel.triggerUserOutboundEvent(pty).get()
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
        } catch {
            channel.close(mode: .all, promise: nil)
            throw SSHClient.mapError(error, stage: .channel, host: "", port: 0)
        }
        return SSHTerminalSession(channel: channel, adapter: adapter, onData: onData, onClose: onClose)
    }

    /// Opens the SFTP subsystem and returns a ready client.
    public func openSFTP() async throws -> SFTPClient {
        if transportKind == .system {
            return try await openSystemSFTP()
        }
        guard let handler = sshHandler, let root = rootChannel, root.isActive else {
            throw handshakeFailure ?? SSHClientError.notConnected
        }
        let adapter = SSHChannelAdapter()
        let channel = try await openChildChannel(handler: handler, parent: root, type: .session, adapter: adapter)
        do {
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)).get()
        } catch {
            channel.close(mode: .all, promise: nil)
            throw SSHClient.mapError(error, stage: .channel, host: "", port: 0)
        }
        let transport = SSHByteStreamTransport(channel: channel, adapter: adapter)
        let client = SFTPClient(transport: transport)
        do {
            try await client.start()
        } catch {
            channel.close(mode: .all, promise: nil)
            throw error
        }
        return client
    }

    /// Runs one short command over an `exec` channel and returns its combined
    /// stdout/stderr.
    ///
    /// The channel closes as soon as the command exits, so this is only for
    /// one-shot probes (OS detection uses it). Output collected before `timeout`
    /// is returned even when the peer never closes the channel: a login script
    /// that hangs should not stall the UI, and a partial probe is still useful.
    public func runCommand(_ command: String, timeout: TimeAmount = .seconds(12)) async throws -> String {
        if transportKind == .system {
            return try await runSystemCommand(command, timeout: timeout)
        }
        guard let handler = sshHandler, let root = rootChannel, root.isActive else {
            throw handshakeFailure ?? SSHClientError.notConnected
        }
        let collector = SSHCommandCollector()
        // Close and timeout race to resolve the wait; the latch makes sure the
        // promise is fulfilled exactly once. The defer covers every early exit
        // (channel open refused, exec rejected): a NIO promise that is released
        // unfulfilled traps, which used to take the whole app down when a server
        // said no to the probe.
        let latch = SSHOnceLatch()
        let done = root.eventLoop.makePromise(of: Void.self)
        defer { if latch.fire() { done.succeed(()) } }
        let adapter = SSHChannelAdapter()
        adapter.onData = { collector.append($0) }
        adapter.onClose = { _ in
            if latch.fire() { done.succeed(()) }
        }
        let channel = try await openChildChannel(handler: handler, parent: root, type: .session, adapter: adapter)
        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(mode: .all, promise: nil)
            if latch.fire() { done.succeed(()) }
        }
        defer { timeoutTask.cancel() }
        do {
            try await channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            ).get()
        } catch {
            channel.close(mode: .all, promise: nil)
            throw SSHClient.mapError(error, stage: .channel, host: "", port: 0)
        }
        // Resolved by the close event or by the timeout, so this never waits
        // longer than `timeout` plus one event-loop tick.
        try await done.futureResult.get()
        return collector.output
    }

    // MARK: - System ssh transport

    private func connectWithSystemSSH(_ options: SSHConnectOptions) async throws {
        var systemOptions = SystemSSHOptions(
            host: options.host,
            port: options.port,
            username: options.username,
            credential: options.systemCredential,
            jumps: options.jumps.map {
                SystemSSHJump(host: $0.host, port: $0.port, username: $0.username)
            },
            proxy: options.proxy,
            connectTimeoutSeconds: Int(max(Double(options.connectTimeout.nanoseconds) / 1_000_000_000, 5)),
            keepaliveSeconds: options.keepaliveSeconds
        )
        systemOptions.term = options.username.isEmpty ? "xterm-256color" : systemOptions.term
        let workspace: SystemSSHWorkspace
        do {
            try SystemSSHCommandBuilder.validate(options: systemOptions)
            workspace = try SystemSSHWorkspace(options: systemOptions)
            let timeout = TimeInterval(systemOptions.connectTimeoutSeconds)
            // A one-shot `true` proves the local client can negotiate, trust and
            // authenticate; every later channel reuses the same argv.
            let probe = await Task.detached(priority: .userInitiated) {
                SystemSSHRunner.run(options: systemOptions, workspace: workspace, command: "true", timeout: timeout)
            }.value
            guard probe.exitCode == 0, !probe.timedOut else {
                throw SSHClient.systemSSHFailure(probe, host: options.host, port: options.port)
            }
        } catch {
            state = .disconnected(String(describing: error))
            throw SSHClient.mapError(error,
                                     stage: options.proxy == nil ? .authentication : .proxy,
                                     host: options.host,
                                     port: options.port)
        }
        systemOptions.term = "xterm-256color"
        self.systemOptions = systemOptions
        self.systemWorkspace = workspace
        self.transportKind = .system
        var description = ["系统 ssh " + systemOptions.destination + ":" + String(systemOptions.port)]
        if !systemOptions.jumps.isEmpty {
            description.append("经 " + String(systemOptions.jumps.count) + " 跳")
        }
        self.hopDescriptions = description
        self.state = .connected
        logger.info("connected via system ssh")
    }

    private func openSystemTerminal(term: String,
                                    columns: Int,
                                    rows: Int,
                                    onData: @escaping @Sendable (Data) -> Void,
                                    onClose: @escaping @Sendable (Error?) -> Void) throws -> SSHTerminalSession {
        guard let workspace = systemWorkspace, var options = systemOptions else {
            throw SSHClientError.notConnected
        }
        options.term = term
        do {
            let process = try SystemSSHTerminalProcess(options: options,
                                                       workspace: workspace,
                                                       columns: columns,
                                                       rows: rows)
            pruneSystemChildren()
            systemChildren.append(process)
            return SSHTerminalSession(process: process, onData: onData, onClose: onClose)
        } catch {
            throw SSHClient.mapError(error, stage: .channel, host: options.host, port: options.port)
        }
    }

    private func openSystemSFTP() async throws -> SFTPClient {
        guard let workspace = systemWorkspace, let options = systemOptions else {
            throw SSHClientError.notConnected
        }
        let transport: SystemSSHSFTPTransport
        do {
            transport = try SystemSSHSFTPTransport(options: options, workspace: workspace)
        } catch {
            throw SSHClient.mapError(error, stage: .channel, host: options.host, port: options.port)
        }
        pruneSystemChildren()
        systemChildren.append(transport)
        let client = SFTPClient(transport: transport)
        do {
            try await client.start()
        } catch {
            transport.terminate()
            if let sftpError = error as? SFTPError, case .transport(let detail) = sftpError, !detail.isEmpty {
                throw SSHConnectionError(stage: .channel, detail: detail, host: options.host, port: options.port)
            }
            throw error
        }
        return client
    }

    private func runSystemCommand(_ command: String, timeout: TimeAmount) async throws -> String {
        guard let workspace = systemWorkspace, let options = systemOptions else {
            throw SSHClientError.notConnected
        }
        let seconds = max(Double(timeout.nanoseconds) / 1_000_000_000, 1)
        let result = await Task.detached(priority: .userInitiated) {
            SystemSSHRunner.run(options: options, workspace: workspace, command: command, timeout: seconds)
        }.value
        if result.exitCode != 0 && result.stdout.isEmpty {
            throw SSHClient.systemSSHFailure(result, host: options.host, port: options.port)
        }
        return result.stdoutText
    }

    private func pruneSystemChildren() {
        systemChildren.removeAll { !$0.isRunning }
    }

    /// Turns the stderr of a failed local ssh into the same staged error the
    /// built-in transport produces.
    static func systemSSHFailure(_ result: SystemSSHResult, host: String, port: Int) -> SSHConnectionError {
        let raw = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty
            ? (result.timedOut ? "连接超时，服务器没有回应" : "系统 ssh 以状态码 " + String(result.exitCode) + " 退出")
            : raw
        let lower = text.lowercased()
        let stage: SSHConnectionStage
        if result.timedOut
            || lower.contains("timed out")
            || lower.contains("connection refused")
            || lower.contains("could not resolve")
            || lower.contains("no route to host")
            || lower.contains("network is unreachable") {
            stage = .tcp
        } else if lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed") {
            stage = .hostKey
        } else if lower.contains("permission denied") {
            stage = .authentication
        } else if lower.contains("unable to negotiate")
            || lower.contains("no matching")
            || lower.contains("host key type")
            || lower.contains("key exchange method") {
            stage = .keyExchange
        } else {
            stage = .channel
        }
        return SSHConnectionError(stage: stage, detail: text, host: host, port: port)
    }

    public func disconnect() {
        for child in systemChildren {
            child.terminate()
        }
        systemChildren.removeAll()
        systemWorkspace?.cleanup()
        systemWorkspace = nil
        systemOptions = nil
        transportKind = .builtin
        rootChannel?.close(mode: .all, promise: nil)
        rootChannel = nil
        sshHandler = nil
        state = .disconnected("已断开")
    }

    /// Closes the connection and releases the event loop group when owned.
    public func shutdown() {
        disconnect()
        if ownsGroup, let group {
            try? group.syncShutdownGracefully()
            self.group = nil
        }
    }

    private func startKeepalive(seconds: Int) {
        guard seconds > 0, var channel = rootChannel else { return }
        // A jump chain terminates in an SSH child channel, and those channels trap on
        // socket options ("setting option ... on SSHChildChannel not supported"), which
        // used to crash the app as soon as a keepalive was configured. Walk down to the
        // real TCP socket, which is the only channel that owns a file descriptor.
        while let parent = channel.parent {
            channel = parent
        }
        guard channel is SocketOptionProvider else { return }
        // NIO SSH does not expose app-level global requests, so keep the NAT/firewall
        // mapping alive with TCP keepalives instead.
        _ = channel.setOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
    }

    private func handleChannelClosed(failure: SSHConnectionError?) {
        guard case .connected = state else { return }
        // Nothing was ever opened on this transport, so the peer dropped it during the
        // handshake (a rejected algorithm, a banned client banner, ...). Remember that so
        // the pending SFTP/terminal request can explain what actually happened.
        if openedChannelCount == 0, let failure {
            handshakeFailure = failure
            state = .disconnected(failure.detail)
            return
        }
        state = .disconnected("连接已关闭")
    }

    /// The error reported when a transport closes before its first channel opens.
    private static func handshakeFailure(for options: SSHConnectOptions) -> SSHConnectionError {
        SSHConnectionError(stage: .keyExchange,
                           detail: "服务器在密钥交换阶段关闭了连接。若该服务器只提供 ssh-rsa（SHA-1）、ssh-dss 等旧算法，"
                               + "Tauge 出于安全策略不会启用它们，请升级服务器 SSH 版本或改用 ed25519/ECDSA 主机密钥。",
                           host: options.host,
                           port: options.port)
    }

    /// Recognises a hop that hung up during the SSH handshake. The algorithms we
    /// offer are the usual reason: an old server refuses them and closes before the
    /// channel opens, which NIO surfaces as `ChannelError.eof`.
    public static func rejectedHandshake(at hopContext: String,
                                  error: Error,
                                  host: String,
                                  port: Int) -> SSHConnectionError? {
        let closedImmediately: Bool
        switch error {
        case ChannelError.eof, ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed:
            closedImmediately = true
        default:
            closedImmediately = false
        }
        guard closedImmediately else { return nil }
        return SSHConnectionError(stage: .keyExchange,
                                  detail: hopContext + "：对端在 SSH 握手阶段关闭了连接。"
                                      + "该机器可能只提供 ssh-rsa（SHA-1）等旧算法，Tauge 的内置 SSH 栈不会启用它们；"
                                      + "请把「连接方式」改为系统 ssh，或直接连接让 Tauge 自动切换。",
                                  host: host,
                                  port: port)
    }

    static func mapError(_ error: Error, stage: SSHConnectionStage, host: String, port: Int) -> Error {
        if let connectionError = error as? SSHConnectionError {
            return connectionError
        }
        if let hostKeyError = error as? HostKeyError {
            return SSHConnectionError(stage: .hostKey, detail: hostKeyError.localizedDescription, host: host, port: port)
        }
        if let proxyError = error as? ProxyHandshakeError {
            return SSHConnectionError(stage: .proxy, detail: proxyError.localizedDescription, host: host, port: port)
        }
        if let proxyConnectionError = error as? ProxyConnectionError {
            return SSHConnectionError(stage: .proxy,
                                      detail: proxyConnectionError.localizedDescription,
                                      host: host,
                                      port: port)
        }
        if error is SFTPError {
            return error
        }
        // NIO only offers localized descriptions such as "The operation couldn't be
        // completed. (NIOCore.ChannelError error 0.)", which tells the user nothing,
        // so translate the interesting transport failures ourselves.
        let described = TransportFailure.describe(error)
        return SSHConnectionError(stage: described.stage ?? stage,
                                  detail: described.detail ?? error.localizedDescription,
                                  host: host,
                                  port: port)
    }
}

public enum SSHClientError: Error, LocalizedError {
    case notConnected
    case unsupported(String)
    case channelOpenTimedOut

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH 连接尚未建立"
        case .unsupported(let feature): return "暂不支持：" + feature
        case .channelOpenTimedOut: return "打开 SSH 通道超时"
        }
    }
}

/// Accumulates the bytes of one exec channel's stdout/stderr.
private final class SSHCommandCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var output: String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
    }
}

/// Fires exactly once, so a channel close and a timeout can both try to resolve
/// the same NIO promise without tripping its "succeeded twice" precondition.
private final class SSHOnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
