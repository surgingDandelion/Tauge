import Foundation
import NIOCore
import NIOPosix

/// A resolved proxy endpoint used when opening the TCP connection to the first hop.
public struct ProxyEndpoint: Sendable {
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(type: ProxyType, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public enum ProxyHandshakeError: Error, LocalizedError {
    case unsupportedType(String)
    case malformedResponse
    case closedWithoutResponse
    case timeout(seconds: Int)
    case httpStatus(Int)
    case socks5MethodRejected
    case socks5AuthFailed
    case socks5Reply(UInt8)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return L("暂不支持 ") + name + L(" 代理")
        case .malformedResponse:
            return L("代理返回了无法解析的响应：端口上的服务可能不是所选类型的代理")
        case .closedWithoutResponse:
            return L("代理在收到请求后直接关闭了连接：端口上可能不是该类型的代理，或代理拒绝了这次转发")
        case .timeout(let seconds):
            return L("代理在 ") + String(seconds) + L(" 秒内没有完成握手：TCP 已连通，但端口上的服务没有按 ")
                + L("所选代理类型应答")
        case .httpStatus(let code):
            if code == 407 {
                return L("HTTP 代理要求认证（407）：请填写代理用户名和密码，或确认密码是否正确")
            }
            if code == 403 {
                return L("HTTP 代理拒绝了这次 CONNECT（403）：代理策略不允许访问该目标地址")
            }
            if code == 502 || code == 503 || code == 504 {
                return L("HTTP 代理无法连到目标（状态码 ") + String(code) + L("）：目标地址对代理不可达")
            }
            return L("HTTP 代理拒绝 CONNECT 请求（状态码 ") + String(code) + "）"
        case .socks5MethodRejected:
            return L("代理不接受所支持的 SOCKS5 认证方式")
        case .socks5AuthFailed:
            return L("SOCKS5 用户名或密码错误")
        case .socks5Reply(let code):
            if code == 0x05 {
                return L("SOCKS5 代理拒绝连接（错误码 5：目标地址不可达）")
            }
            return L("SOCKS5 代理连接失败（错误码 ") + String(code) + "）"
        }
    }
}

/// The TCP socket to the proxy itself never opened. Kept apart from
/// `ProxyHandshakeError` so the UI can say which of the two legs failed: a
/// timeout here means the proxy address/port is wrong or unreachable, not that
/// the proxy rejected the tunnel.
public enum ProxyConnectionError: Error, LocalizedError {
    case unreachable(host: String, port: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host, let port, let reason):
            return L("连不上代理 ") + host + ":" + String(port) + "：" + reason
                + L("。代理是独立的一段网络，请先确认本机能直接访问代理地址和端口（必要时先连 VPN），")
                + L("并核对代理端口与类型")
        }
    }
}

/// Guards the one-shot promise shared by a proxy handshake handler and its
/// timeout, so neither can complete the promise twice.
final class ProxyHandshakeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

public enum TCPConnector {
    /// Opens a TCP connection to the target, optionally tunneling through a proxy.
    public static func connect(targetHost: String,
                               targetPort: Int,
                               proxy: ProxyEndpoint?,
                               group: EventLoopGroup,
                               timeout: TimeAmount = .seconds(20)) async throws -> Channel {
        try await connect(targetHost: targetHost, targetPort: targetPort, proxy: proxy,
                          group: group, timeout: timeout, inboundHandler: nil)
    }

    static func connect(targetHost: String,
                        targetPort: Int,
                        proxy: ProxyEndpoint?,
                        group: EventLoopGroup,
                        timeout: TimeAmount,
                        inboundHandler: (any ChannelHandler & Sendable)?) async throws -> Channel {
        // Keep reads paused until the SSH pipeline is in place: a channel with an
        // empty pipeline silently discards inbound bytes, and a server sends its
        // KEXINIT immediately after accepting the connection. The caller resumes
        // reading with `startReading(_:)` once its handlers are installed.
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.autoRead, value: false)
        if let inboundHandler {
            _ = bootstrap.channelInitializer { channel in channel.pipeline.addHandler(inboundHandler) }
        } else if proxy != nil {
            _ = bootstrap.channelInitializer { channel in channel.pipeline.addHandler(PendingTunnelBytes()) }
        }
        guard let proxy else {
            let direct = try await bootstrap.connect(host: targetHost, port: targetPort).get()
            return direct
        }
        if proxy.type == .https {
            throw ProxyHandshakeError.unsupportedType("HTTPS")
        }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: proxy.host, port: proxy.port).get()
        } catch {
            // Distinguish "the proxy itself is unreachable" from "the proxy
            // refused this tunnel": they need completely different fixes.
            let reason = TransportFailure.describe(error).detail ?? error.localizedDescription
            throw ProxyConnectionError.unreachable(host: proxy.host, port: proxy.port, reason: reason)
        }
        do {
            try await handshake(channel: channel,
                                proxy: proxy,
                                targetHost: targetHost,
                                targetPort: targetPort,
                                timeout: timeout)
            try await pauseReading(channel)
            return channel
        } catch {
            channel.close(mode: .all, promise: nil)
            throw error
        }
    }

    /// Starts delivering inbound bytes to the pipeline. Every connect starts with
    /// reads paused so handlers can be installed without losing server greetings.
    public static func startReading(_ channel: Channel) async throws {
        try await channel.eventLoop.flatSubmit {
            let pipeline = channel.pipeline.syncOperations
            if let pending = try? pipeline.handler(type: PendingTunnelBytes.self) {
                pipeline.removeHandler(pending, promise: nil)
            }
            return channel.setOption(ChannelOptions.autoRead, value: true)
        }.get()
        // SSH child channels only re-arm reads when they are asked for one; a plain
        // socket ignores this call because autoRead already schedules reads.
        channel.read()
    }

    public static func pauseReading(_ channel: Channel) async throws {
        try await channel.setOption(ChannelOptions.autoRead, value: false).get()
    }

    private static func handshake(channel: Channel,
                                  proxy: ProxyEndpoint,
                                  targetHost: String,
                                  targetPort: Int,
                                  timeout: TimeAmount) async throws {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let latch = ProxyHandshakeLatch()
        let handler: any ChannelHandler & Sendable
        switch proxy.type {
        case .http:
            handler = HTTPConnectHandler(targetHost: targetHost,
                                         targetPort: targetPort,
                                         username: proxy.username,
                                         password: proxy.password,
                                         promise: promise,
                                         latch: latch)
        case .socks5, .socks5h:
            handler = SOCKS5HandshakeHandler(targetHost: targetHost,
                                             targetPort: targetPort,
                                             username: proxy.username,
                                             password: proxy.password,
                                             promise: promise,
                                             latch: latch)
        case .https:
            throw ProxyHandshakeError.unsupportedType("HTTPS")
        }
        // A proxy that accepts TCP but never answers used to hang the connect
        // forever (no overall timeout once the socket is up).
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            guard latch.fire() else { return }
            let seconds = max(1, Int(timeout.nanoseconds / 1_000_000_000))
            promise.fail(ProxyHandshakeError.timeout(seconds: seconds))
            channel.close(mode: .all, promise: nil)
        }
        do {
            // Consume the proxy reply before any SSH data reaches the caller's
            // handler, including a server greeting appended to the reply.
            try await channel.pipeline.addHandler(handler, position: .first).get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            try await promise.futureResult.get()
            deadline.cancel()
        } catch {
            deadline.cancel()
            if latch.fire() { promise.fail(error) }
            throw error
        }
    }
}

/// Holds destination bytes received during the handoff from the proxy handshake
/// to a caller that installs its protocol handler after connect returns.
private final class PendingTunnelBytes: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var pending = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        guard incoming.readableBytes <= 128 * 1024 - pending.readableBytes else {
            context.close(promise: nil)
            return
        }
        pending.writeImmutableBuffer(incoming)
    }

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        if pending.readableBytes > 0 {
            context.fireChannelRead(NIOAny(pending))
            context.fireChannelReadComplete()
        }
        context.leavePipeline(removalToken: removalToken)
    }
}

final class HTTPConnectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        context.leavePipeline(removalToken: removalToken)
    }

    private let targetHost: String
    private let targetPort: Int
    private let username: String?
    private let password: String?
    private let promise: EventLoopPromise<Void>
    private let latch: ProxyHandshakeLatch
    private var buffer = Data()
    private var receivedAny = false
    private var finished = false
    private var sentRequest = false

    init(targetHost: String,
         targetPort: Int,
         username: String?,
         password: String?,
         promise: EventLoopPromise<Void>,
         latch: ProxyHandshakeLatch) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.username = username
        self.password = password
        self.promise = promise
        self.latch = latch
    }

    /// The handshake handler is installed after the socket is already up, so
    /// NIO never sends this handler a fresh channelActive. Without this hook the
    /// CONNECT request was never written and every proxy looked like it timed out.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendRequest(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequest(context: context)
        context.fireChannelActive()
    }

    private func sendRequest(context: ChannelHandlerContext) {
        guard !sentRequest else { return }
        sentRequest = true
        let authority = targetHost + ":" + String(targetPort)
        var request = "CONNECT " + authority + " HTTP/1.1\r\n"
        request += "Host: " + authority + "\r\n"
        request += "Proxy-Connection: keep-alive\r\n"
        if let username, let password {
            let token = Data((username + ":" + password).utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic " + token + "\r\n"
        }
        request += "\r\n"
        var out = context.channel.allocator.buffer(capacity: request.utf8.count)
        out.writeString(request)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
            receivedAny = receivedAny || !bytes.isEmpty
        }
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return
        }
        let headerData = buffer[buffer.startIndex..<terminator.lowerBound]
        let header = String(decoding: headerData, as: UTF8.self)
        let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) : nil
        guard let status else {
            finish(context: context, error: ProxyHandshakeError.malformedResponse)
            return
        }
        guard status == 200 else {
            finish(context: context, error: ProxyHandshakeError.httpStatus(status))
            return
        }
        finished = true
        let leftover = Data(buffer[terminator.upperBound...])
        if !leftover.isEmpty {
            var out = context.channel.allocator.buffer(capacity: leftover.count)
            out.writeBytes(leftover)
            context.fireChannelRead(NIOAny(out))
        }
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
        if latch.fire() {
            promise.succeed(())
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            if latch.fire() {
                promise.fail(receivedAny
                    ? ProxyHandshakeError.malformedResponse
                    : ProxyHandshakeError.closedWithoutResponse)
            }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context: context, error: error)
        context.close(promise: nil)
    }

    private func finish(context: ChannelHandlerContext, error: Error) {
        guard !finished else { return }
        finished = true
        guard latch.fire() else { return }
        promise.fail(error)
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
    }
}

final class SOCKS5HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        context.leavePipeline(removalToken: removalToken)
    }

    private enum Stage {
        case greeting
        case auth
        case connect
        case done
    }

    private let targetHost: String
    private let targetPort: Int
    private let username: String?
    private let password: String?
    private let promise: EventLoopPromise<Void>
    private let latch: ProxyHandshakeLatch
    private var stage: Stage = .greeting
    private var receivedAny = false
    private var buffer = Data()
    private var sentGreeting = false

    init(targetHost: String,
         targetPort: Int,
         username: String?,
         password: String?,
         promise: EventLoopPromise<Void>,
         latch: ProxyHandshakeLatch) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.username = username
        self.password = password
        self.promise = promise
        self.latch = latch
    }

    /// See HTTPConnectHandler.handlerAdded: the socket is already active when
    /// this handler is added, so the greeting has to be sent from here.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendGreeting(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendGreeting(context: context)
        context.fireChannelActive()
    }

    private func sendGreeting(context: ChannelHandlerContext) {
        guard !sentGreeting else { return }
        sentGreeting = true
        var greeting: [UInt8] = [0x05]
        if username != nil, password != nil {
            greeting += [0x02, 0x00, 0x02]
        } else {
            greeting += [0x01, 0x00]
        }
        send(context: context, bytes: greeting)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stage != .done else { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
            receivedAny = receivedAny || !bytes.isEmpty
        }
        while true {
            switch stage {
            case .greeting:
                guard buffer.count >= 2 else { return }
                let method = buffer[buffer.startIndex + 1]
                buffer.removeFirst(2)
                if method == 0xFF {
                    fail(context: context, error: ProxyHandshakeError.socks5MethodRejected)
                    return
                }
                if method == 0x02 {
                    stage = .auth
                    sendAuth(context: context)
                } else {
                    stage = .connect
                    sendConnect(context: context)
                }
            case .auth:
                guard buffer.count >= 2 else { return }
                let status = buffer[buffer.startIndex + 1]
                buffer.removeFirst(2)
                guard status == 0 else {
                    fail(context: context, error: ProxyHandshakeError.socks5AuthFailed)
                    return
                }
                stage = .connect
                sendConnect(context: context)
            case .connect:
                guard buffer.count >= 4 else { return }
                let reply = buffer[buffer.startIndex + 1]
                let addressType = buffer[buffer.startIndex + 3]
                var headerLength = 4
                switch addressType {
                case 0x01: headerLength += 4
                case 0x03:
                    guard buffer.count >= 5 else { return }
                    headerLength += 1 + Int(buffer[buffer.startIndex + 4])
                case 0x04: headerLength += 16
                default:
                    fail(context: context, error: ProxyHandshakeError.malformedResponse)
                    return
                }
                headerLength += 2
                guard buffer.count >= headerLength else { return }
                buffer.removeFirst(headerLength)
                guard reply == 0 else {
                    fail(context: context, error: ProxyHandshakeError.socks5Reply(reply))
                    return
                }
                stage = .done
                let leftover = buffer
                buffer = Data()
                if !leftover.isEmpty {
                    var out = context.channel.allocator.buffer(capacity: leftover.count)
                    out.writeBytes(leftover)
                    context.fireChannelRead(NIOAny(out))
                }
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
                if latch.fire() {
                    promise.succeed(())
                }
                return
            case .done:
                return
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if stage != .done {
            stage = .done
            if latch.fire() {
                promise.fail(receivedAny
                    ? ProxyHandshakeError.malformedResponse
                    : ProxyHandshakeError.closedWithoutResponse)
            }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error: error)
        context.close(promise: nil)
    }

    private func sendAuth(context: ChannelHandlerContext) {
        let user = Data((username ?? "").utf8)
        let pass = Data((password ?? "").utf8)
        var bytes: [UInt8] = [0x01, UInt8(min(user.count, 255))]
        bytes += user.prefix(255)
        bytes.append(UInt8(min(pass.count, 255)))
        bytes += pass.prefix(255)
        send(context: context, bytes: bytes)
    }

    private func sendConnect(context: ChannelHandlerContext) {
        var bytes: [UInt8] = [0x05, 0x01, 0x00]
        let hostBytes = Data(targetHost.utf8)
        if hostBytes.count <= 255 {
            bytes += [0x03, UInt8(hostBytes.count)]
            bytes += hostBytes
        } else {
            bytes += [0x01, 127, 0, 0, 1]
        }
        bytes += [UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF)]
        send(context: context, bytes: bytes)
    }

    private func send(context: ChannelHandlerContext, bytes: [UInt8]) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    private func fail(context: ChannelHandlerContext, error: Error) {
        guard stage != .done else { return }
        stage = .done
        guard latch.fire() else { return }
        promise.fail(error)
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
        context.close(promise: nil)
    }
}
