import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import TaugeKit

/// In-process SSH server used by the self checks. It accepts every offered
/// credential, answers shell and SFTP subsystem requests, echoes terminal input
/// and serves SFTP from an in-memory file table. This lets the real client
/// stack (TCP + handshake + auth + channel + SFTP framing) run end to end
/// without an external sshd.
final class MockSSHServer: @unchecked Sendable {
    final class AcceptAnyAuth: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .all

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    let sftp: MockSFTPServer
    private let authentication: NIOSSHServerUserAuthenticationDelegate
    private let group: MultiThreadedEventLoopGroup
    private let hostKey: NIOSSHPrivateKey
    private var channel: Channel?
    private let counterLock = NSLock()
    private var shellCount = 0
    private var sftpCount = 0
    /// One canned answer for an `exec` request. `holdOpen` keeps the channel
    /// open after the output, which is how the client's timeout path is exercised.
    struct ExecStub {
        let output: String
        let holdOpen: Bool
    }

    private var execStubs: [String: ExecStub] = [:]
    private var tunnels: [(host: String, port: Int)] = []
    private var tunnelUpBytes = 0
    private var tunnelDownBytes = 0
    private(set) var port: Int = 0

    init(sftp: MockSFTPServer = MockSFTPServer(),
         authentication: NIOSSHServerUserAuthenticationDelegate = AcceptAnyAuth()) {
        self.sftp = sftp
        self.authentication = authentication
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    }

    var shellSessions: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return shellCount
    }

    var sftpSessions: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return sftpCount
    }

    /// Every direct-tcpip channel this server was asked to open, in order. A jump
    /// chain must show up here; a client that dials the destination directly does not.
    var tunnelRequests: [(host: String, port: Int)] {
        counterLock.lock()
        defer { counterLock.unlock() }
        return tunnels
    }

    func noteTunnel(host: String, port: Int) {
        counterLock.lock()
        tunnels.append((host, port))
        counterLock.unlock()
    }

    /// Bytes relayed from the SSH side towards the destination, and back.
    var tunnelByteCounts: (up: Int, down: Int) {
        counterLock.lock()
        defer { counterLock.unlock() }
        return (tunnelUpBytes, tunnelDownBytes)
    }

    func noteTunnelBytes(up: Int) {
        counterLock.lock()
        tunnelUpBytes += up
        counterLock.unlock()
    }

    func noteTunnelBytes(down: Int) {
        counterLock.lock()
        tunnelDownBytes += down
        counterLock.unlock()
    }

    /// Answers an `exec` request with the stubbed output. Unstubbed commands are
    /// refused, like a real server running a restricted shell.
    func stubExec(command: String, output: String, holdOpen: Bool = false) {
        counterLock.lock()
        execStubs[command] = ExecStub(output: output, holdOpen: holdOpen)
        counterLock.unlock()
    }

    func execStub(for command: String) -> ExecStub? {
        counterLock.lock()
        defer { counterLock.unlock() }
        return execStubs[command]
    }

    func noteShellSession() {
        counterLock.lock()
        shellCount += 1
        counterLock.unlock()
    }

    func noteSFTPSession() {
        counterLock.lock()
        sftpCount += 1
        counterLock.unlock()
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Accepted sockets stay paused until the SSH handler is in the
            // pipeline, otherwise a client KEXINIT can be dropped and the
            // handshake stalls forever.
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(hostKeys: [self.hostKey],
                                                            userAuthDelegate: self.authentication)),
                        allocator: channel.allocator
                    ) { child, type in
                        if case .directTCPIP(let request) = type {
                            return self.acceptTunnel(child: child, request: request)
                        }
                        return child.pipeline.addHandler(MockSessionHandler(server: self))
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = bound
        port = bound.localAddress?.port ?? 0
    }

    /// Forwards a direct-tcpip channel to a real TCP connection, which is what a
    /// jump host does. Without this the only tested path would be a direct dial.
    private func acceptTunnel(child: Channel, request: SSHChannelType.DirectTCPIP) -> EventLoopFuture<Void> {
        noteTunnel(host: request.targetHost, port: request.targetPort)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
        return bootstrap.connect(host: request.targetHost, port: request.targetPort).flatMap { tcp in
            tcp.pipeline.addHandler(TCPToSSHTunnelHandler(ssh: child, server: self)).flatMap {
                child.pipeline.addHandler(SSHToTCPTunnelHandler(tcp: tcp, server: self)).map {
                    child.closeFuture.whenComplete { _ in tcp.close(mode: .all, promise: nil) }
                    tcp.closeFuture.whenComplete { _ in child.close(mode: .all, promise: nil) }
                }
            }
        }
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        group.shutdownGracefully { _ in }
    }
}

/// Server-side session: replies to pty/shell/subsystem requests, echoes shell
/// input and pipes SFTP bytes through the in-memory responder.
final class MockSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    enum Mode {
        case idle
        case shell
        case sftp
    }

    private let server: MockSSHServer
    private var mode: Mode = .idle

    init(server: MockSSHServer) {
        self.server = server
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.PseudoTerminalRequest {
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            return
        }
        if let request = event as? SSHChannelRequestEvent.ShellRequest {
            mode = .shell
            server.noteShellSession()
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            write(context: context, Data("mock-shell-ready\r\n".utf8))
            return
        }
        if let request = event as? SSHChannelRequestEvent.ExecRequest {
            guard let stub = server.execStub(for: request.command) else {
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                return
            }
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            write(context: context, Data(stub.output.utf8))
            // A real command exits on its own; closing right after the write lets
            // the client's promise resolve without an explicit EOF exchange.
            if !stub.holdOpen {
                context.close(promise: nil)
            }
            return
        }
        if let request = event as? SSHChannelRequestEvent.SubsystemRequest {
            if request.subsystem == "sftp" {
                mode = .sftp
                server.noteSFTPSession()
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                }
            } else if request.wantReply {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
            return
        }
        if let request = event as? SSHChannelRequestEvent.WindowChangeRequest {
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }
        switch mode {
        case .sftp:
            let response = server.sftp.handleChunk(Data(bytes))
            if !response.isEmpty {
                write(context: context, response)
            }
        case .shell:
            write(context: context, Data(bytes))
        case .idle:
            break
        }
    }

    private func write(context: ChannelHandlerContext, _ data: Data) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        context.flush()
    }
}
/// Moves bytes arriving on the SSH channel into the forwarded TCP connection.
final class SSHToTCPTunnelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let tcp: Channel
    private let server: MockSSHServer

    init(tcp: Channel, server: MockSSHServer) {
        self.tcp = tcp
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(let buffer) = channelData.data else { return }
        server.noteTunnelBytes(up: buffer.readableBytes)
        tcp.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        tcp.close(mode: .all, promise: nil)
    }
}

/// Moves bytes read from the forwarded TCP connection back into the SSH channel.
final class TCPToSSHTunnelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let ssh: Channel
    private let server: MockSSHServer

    init(ssh: Channel, server: MockSSHServer) {
        self.ssh = ssh
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        server.noteTunnelBytes(down: buffer.readableBytes)
        ssh.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ssh.close(mode: .all, promise: nil)
    }
}
