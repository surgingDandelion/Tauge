import Foundation
import NIOCore
import NIOPosix

/// Provides an OpenSSH ProxyCommand with a private local path to one fixed
/// destination. The proxy credentials stay in the in-process TCP connector.
final class SystemSSHProxyRelay: @unchecked Sendable {
    let socketPath: String

    private let directory: URL
    private let lock = NSLock()
    private var listener: Channel?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var closed = false
    private var failure: Error?

    var connectionError: Error? { lock.withLock { failure } }

    private init() throws {
        // Keep the literal /tmp prefix to stay well below Darwin's sun_path limit.
        directory = URL(fileURLWithPath: "/tmp/tauge-proxy-" + UUID().uuidString, isDirectory: true)
        socketPath = directory.appendingPathComponent("relay.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func start(targetHost: String, targetPort: Int, proxy: ProxyEndpoint, group: EventLoopGroup,
                      timeout: TimeAmount) async throws -> SystemSSHProxyRelay {
        guard proxy.type != .https else { throw ProxyHandshakeError.unsupportedType("HTTPS") }
        let relay = try SystemSSHProxyRelay()
        do {
            let listener = try await ServerBootstrap(group: group)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { [weak relay] local in
                    guard let relay else {
                        return local.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                    }
                    return relay.accept(local) { channel, handler in
                        try await TCPConnector.connect(targetHost: targetHost, targetPort: targetPort, proxy: proxy,
                                                       group: channel.eventLoop, timeout: timeout, inboundHandler: handler)
                    }
                }
                .bind(unixDomainSocketPath: relay.socketPath).get()
            relay.lock.withLock { relay.listener = listener }
            try Task.checkCancellation()
            return relay
        } catch {
            relay.close()
            throw error
        }
    }

    private func accept(_ local: Channel, connect: @escaping Connection.Connect) -> EventLoopFuture<Void> {
        let id = ObjectIdentifier(local)
        let pair = Connection(local: local, connect: connect) { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.connections.removeValue(forKey: id)
                if self.failure == nil { self.failure = error }
            }
        }
        let accepted = lock.withLock {
            guard !closed else { return false }
            connections[id] = pair
            return true
        }
        guard accepted else { return local.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
        local.closeFuture.whenComplete { [weak pair] _ in pair?.finish() }
        return local.pipeline.addHandler(Forwarder(connection: pair, isLocal: true))
    }

    func close() {
        let resources = lock.withLock { () -> (Channel?, [Connection])? in
            guard !closed else { return nil }
            closed = true
            let resources = (listener, Array(connections.values))
            listener = nil
            connections.removeAll()
            return resources
        }
        guard let (listener, connections) = resources else { return }
        listener?.close(promise: nil)
        for pair in connections {
            pair.local.eventLoop.execute { pair.finish() }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { close() }

    /// Mutable state stays on the accepted socket's event loop. The outbound
    /// bootstrap uses the same loop, including all Happy Eyeballs candidates.
    private final class Connection: @unchecked Sendable {
        typealias Connect = @Sendable (Channel, Forwarder) async throws -> Channel
        private static let earlyLocalByteLimit = 64 * 1024

        let local: Channel
        private(set) var upstream: Channel?
        private(set) var localInputClosed = false
        private let connect: Connect
        private let onClose: @Sendable (Error?) -> Void
        private var candidates: [ObjectIdentifier: Channel] = [:]
        private var task: Task<Void, Never>?
        private var earlyLocalBytes: ByteBuffer?
        private var lastLocalWrite: EventLoopFuture<Void>?
        private var closed = false

        init(local: Channel, connect: @escaping Connect, onClose: @escaping @Sendable (Error?) -> Void) {
            self.local = local
            self.connect = connect
            self.onClose = onClose
        }

        func start() {
            local.eventLoop.preconditionInEventLoop()
            guard !closed else { return }
            task = Task {
                do {
                    try Task.checkCancellation()
                    let channel = try await connect(local, Forwarder(connection: self, isLocal: false))
                    local.eventLoop.execute { self.connected(channel) }
                } catch {
                    local.eventLoop.execute { self.finish(error) }
                }
            }
        }

        func register(_ channel: Channel) {
            local.eventLoop.preconditionInEventLoop()
            if closed {
                channel.close(promise: nil)
            } else {
                candidates[ObjectIdentifier(channel)] = channel
            }
        }

        private func connected(_ channel: Channel) {
            local.eventLoop.preconditionInEventLoop()
            task = nil
            guard !closed else {
                channel.close(promise: nil)
                return
            }
            guard channel.isActive else {
                finishAfterWritingToLocal()
                return
            }
            upstream = channel
            if let earlyLocalBytes {
                self.earlyLocalBytes = nil
                channel.writeAndFlush(earlyLocalBytes, promise: nil)
            }
            if localInputClosed {
                channel.close(mode: .output, promise: nil)
            } else if channel.isWritable {
                local.read()
            }
            if local.isWritable { channel.read() }
        }

        func forward(_ buffer: ByteBuffer, fromLocal: Bool) {
            local.eventLoop.preconditionInEventLoop()
            guard !closed else { return }
            if !fromLocal {
                // A proxy reply can already contain an SSH greeting.
                lastLocalWrite = local.writeAndFlush(buffer)
            } else if let upstream {
                upstream.writeAndFlush(buffer, promise: nil)
            } else {
                // macOS can deliver data with EOF even while autoRead is off.
                let bufferedCount = earlyLocalBytes?.readableBytes ?? 0
                guard buffer.readableBytes <= Self.earlyLocalByteLimit - bufferedCount else {
                    finish()
                    return
                }
                if earlyLocalBytes == nil {
                    earlyLocalBytes = buffer
                } else {
                    earlyLocalBytes?.writeImmutableBuffer(buffer)
                }
            }
        }

        func closeLocalInput() {
            local.eventLoop.preconditionInEventLoop()
            localInputClosed = true
            upstream?.close(mode: .output, promise: nil)
        }

        func peerClosed(_ channel: Channel, isLocal: Bool, error: Error? = nil) {
            local.eventLoop.preconditionInEventLoop()
            if isLocal {
                finish(error)
            } else if channel === upstream {
                if let error { finish(error) }
                else { finishAfterWritingToLocal() }
            } else {
                candidates.removeValue(forKey: ObjectIdentifier(channel))
                // Only the connector reports failure for unsuccessful TCP candidates
                // or a proxy handshake instead of racing a candidate channel close.
                if error != nil { channel.close(promise: nil) }
            }
        }

        private func finishAfterWritingToLocal() {
            if let lastLocalWrite {
                lastLocalWrite.whenComplete { [weak self] _ in self?.finish() }
            } else {
                finish()
            }
        }

        func finish(_ error: Error? = nil) {
            local.eventLoop.preconditionInEventLoop()
            guard !closed else { return }
            closed = true
            task?.cancel()
            task = nil
            let channels = Array(candidates.values)
            candidates.removeAll()
            earlyLocalBytes = nil
            lastLocalWrite = nil
            upstream = nil
            onClose(error)
            local.close(promise: nil)
            for channel in channels { channel.close(promise: nil) }
        }
    }

    private final class Forwarder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private weak var connection: Connection?
        private let isLocal: Bool

        init(connection: Connection, isLocal: Bool) {
            self.connection = connection
            self.isLocal = isLocal
        }

        func handlerAdded(context: ChannelHandlerContext) {
            if !isLocal { connection?.register(context.channel) }
        }

        func channelActive(context: ChannelHandlerContext) {
            if isLocal { connection?.start() }
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            connection?.forward(unwrapInboundIn(data), fromLocal: isLocal)
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            if connection?.upstream?.isActive == true && peer?.isWritable == true
                && (!isLocal || connection?.localInputClosed == false) {
                context.read()
            }
            context.fireChannelReadComplete()
        }

        func channelWritabilityChanged(context: ChannelHandlerContext) {
            if connection?.upstream?.isActive == true && context.channel.isWritable
                && (isLocal || connection?.localInputClosed == false) {
                peer?.read()
            }
            context.fireChannelWritabilityChanged()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if isLocal, (event as? ChannelEvent) == .inputClosed {
                connection?.closeLocalInput()
            }
            context.fireUserInboundEventTriggered(event)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            connection?.peerClosed(context.channel, isLocal: isLocal, error: error)
        }

        func channelInactive(context: ChannelHandlerContext) {
            connection?.peerClosed(context.channel, isLocal: isLocal)
            context.fireChannelInactive()
        }

        private var peer: Channel? { isLocal ? connection?.upstream : connection?.local }
    }
}
