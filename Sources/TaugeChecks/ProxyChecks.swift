import Foundation
import NIOCore
import NIOPosix
import TaugeKit

// Checks for the proxy route: policy exclusivity, target parsing and the probe
// used by the "测试连通性" button.

// MARK: - Stub proxies

/// Records the request line a stub proxy received, so a check can assert that
/// the client actually spoke before the timeout fired.
private final class ProxyRequestRecorder: @unchecked Sendable {
    var requestLine: String?
}

/// A minimal HTTP CONNECT proxy: answers 200 to the first request it sees.
private final class HTTPProxyStub: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let recorder: ProxyRequestRecorder
    private let greeting: String
    private var buffer = Data()
    private var replied = false

    init(recorder: ProxyRequestRecorder, greeting: String = "") {
        self.recorder = recorder
        self.greeting = greeting
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        guard !replied, buffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        replied = true
        recorder.requestLine = String(decoding: buffer, as: UTF8.self)
            .split(separator: "\r\n").first.map(String.init)
        var out = context.channel.allocator.buffer(capacity: 39 + greeting.utf8.count)
        out.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
        out.writeString(greeting)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}

private final class ProxyTunnelByteCollector: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let output: OutputRecorder

    init(output: OutputRecorder) { self.output = output }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        output.append(Data(unwrapInboundIn(data).readableBytesView))
    }
}

/// A minimal SOCKS5 proxy: accepts "no auth" and grants every CONNECT.
private final class SOCKS5ProxyStub: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let recorder: ProxyRequestRecorder
    private var buffer: [UInt8] = []
    private var stage = 0

    init(recorder: ProxyRequestRecorder) { self.recorder = recorder }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        while true {
            switch stage {
            case 0:
                // greeting = VER, NMETHODS, METHODS[NMETHODS]
                guard buffer.count >= 2 else { return }
                let methodCount = Int(buffer[1])
                guard buffer.count >= 2 + methodCount else { return }
                recorder.requestLine = "greeting methods " + buffer[2..<(2 + methodCount)].map { String($0) }.joined(separator: ",")
                buffer.removeFirst(2 + methodCount)
                write(context: context, bytes: [0x05, 0x00])
                stage = 1
            case 1:
                guard buffer.count >= 4 else { return }
                let addressType = buffer[3]
                var length = 4
                switch addressType {
                case 0x01: length += 4
                case 0x03:
                    guard buffer.count >= 5 else { return }
                    length += 1 + Int(buffer[4])
                case 0x04: length += 16
                default: return
                }
                length += 2
                guard buffer.count >= length else { return }
                buffer.removeFirst(length)
                write(context: context, bytes: [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                stage = 2
            default:
                return
            }
        }
    }

    private func write(context: ChannelHandlerContext, bytes: [UInt8]) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}

/// Starts a stub on a free loopback port and returns the port plus a shutdown hook.
private func startStub<Handler: ChannelInboundHandler>(_ makeHandler: @escaping @Sendable () -> Handler)
    async throws -> (port: Int, group: MultiThreadedEventLoopGroup, channel: Channel) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(makeHandler())
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    guard let port = channel.localAddress?.port else {
        try? await group.shutdownGracefully()
        throw CheckError.message("stub proxy did not bind")
    }
    return (port, group, channel)
}

// MARK: - Checks

func runProxyChecks() async {
    await runAsync("handshake is written to an already-connected proxy socket") {
        // Regression: the handshake handler is added after the socket is active,
        // so NIO never calls channelActive on it. The request used to be skipped
        // and every proxy looked unreachable/silent until the timeout fired.
        let recorder = ProxyRequestRecorder()
        let stub = try await startStub { HTTPProxyStub(recorder: recorder) }

        let result = await ProxyProbe.test(ProxyEndpoint(type: .http, host: "127.0.0.1", port: stub.port),
                                           targetHost: "example.com", targetPort: 443,
                                           timeout: .seconds(5))
        expectEqual(result.outcome, .ok, "HTTP CONNECT stub grants the tunnel")
        expect(result.elapsedMilliseconds < 3000, "the tunnel opens immediately, not after a timeout")
        expect(recorder.requestLine == "CONNECT example.com:443 HTTP/1.1",
               "the proxy received the CONNECT line, got " + (recorder.requestLine ?? "nothing"))
        stub.channel.close(promise: nil)
        try? await stub.group.shutdownGracefully()
    }

    await runAsync("CONNECT greeting waits for the built-in SSH pipeline") {
        let greeting = "SSH-2.0-fixture-built-in\r\n"
        let requests = ProxyRequestRecorder()
        let stub = try await startStub { HTTPProxyStub(recorder: requests, greeting: greeting) }
        defer {
            stub.channel.close(promise: nil)
            stub.group.shutdownGracefully { _ in }
        }

        let connection = try await TCPConnector.connect(
            targetHost: "fixture-target.invalid", targetPort: 22,
            proxy: ProxyEndpoint(type: .http, host: "127.0.0.1", port: stub.port),
            group: stub.group, timeout: .seconds(3)
        )
        defer { connection.close(promise: nil) }

        // The greeting was sent with CONNECT 200, before the caller installed a handler.
        let output = OutputRecorder()
        try await connection.pipeline.addHandler(ProxyTunnelByteCollector(output: output)).get()
        try await TCPConnector.startReading(connection)
        try await waitUntil(3) { output.contains(greeting) }
        expectEqual(output.text, greeting, "only the intact SSH greeting reaches the installed handler")
    }

    await runAsync("socks5 handshake is written to an already-connected proxy socket") {
        let recorder = ProxyRequestRecorder()
        let stub = try await startStub { SOCKS5ProxyStub(recorder: recorder) }

        let result = await ProxyProbe.test(ProxyEndpoint(type: .socks5, host: "127.0.0.1", port: stub.port),
                                           targetHost: "example.com", targetPort: 443,
                                           timeout: .seconds(5))
        if result.outcome != .ok { print("     socks5 stub => " + result.summary) }
        expectEqual(result.outcome, .ok, "SOCKS5 stub grants the tunnel")
        expect(result.elapsedMilliseconds < 3000, "the SOCKS5 tunnel opens immediately")
        expect(recorder.requestLine != nil, "the stub received the greeting")
        stub.channel.close(promise: nil)
        try? await stub.group.shutdownGracefully()
    }


    run("route rules treat jump and proxy as one of two choices") {
        let jumpID = UUID()
        let proxyID = UUID()

        expect(!RouteRules.isProxyActive(.direct), "direct proxy is inactive")
        expect(!RouteRules.isProxyActive(.inherit), "inherited proxy is inactive")
        expect(RouteRules.isProxyActive(.use(proxyID)), "selected proxy is active")

        expect(!RouteRules.isJumpActive(.direct), "direct jump is inactive")
        expect(!RouteRules.isJumpActive(.hosts([])), "empty jump chain is inactive")
        expect(RouteRules.isJumpActive(.hosts([jumpID])), "non-empty jump chain is active")

        // Choosing a proxy drops the jump chain.
        expectEqual(RouteRules.jumpPolicy(afterSelectingProxy: .use(proxyID), current: .hosts([jumpID])),
                    .direct, "selecting a proxy clears the jump chain")
        expectEqual(RouteRules.jumpPolicy(afterSelectingProxy: .use(proxyID), current: .inherit),
                    .direct, "selecting a proxy clears an inherited jump chain")
        expectEqual(RouteRules.jumpPolicy(afterSelectingProxy: .direct, current: .hosts([jumpID])),
                    .hosts([jumpID]), "removing the proxy leaves the jump chain alone")

        // Choosing jump hosts drops the proxy.
        expectEqual(RouteRules.proxyPolicy(afterSelectingJump: .hosts([jumpID]), current: .use(proxyID)),
                    .direct, "selecting a jump chain clears the proxy")
        expectEqual(RouteRules.proxyPolicy(afterSelectingJump: .hosts([]), current: .use(proxyID)),
                    .use(proxyID), "an empty jump chain keeps the proxy")

        // A host that somehow carries both is normalised to the proxy.
        let route = RouteRules.normalized(proxy: .use(proxyID), jump: .hosts([jumpID]))
        expectEqual(route.proxy, .use(proxyID), "normalised route keeps the proxy")
        expectEqual(route.jump, .direct, "normalised route drops the jump chain")
        let untouched = RouteRules.normalized(proxy: .direct, jump: .hosts([jumpID]))
        expectEqual(untouched.proxy, .direct, "normalise keeps a direct proxy")
        expectEqual(untouched.jump, .hosts([jumpID]), "normalise keeps a lone jump chain")
    }

    run("proxy probe parses test targets") {
        let plain = ProxyProbe.parseTarget("example.com:8443")
        expectEqual(plain?.host, "example.com", "host")
        expectEqual(plain?.port, 8443, "port")

        let bare = ProxyProbe.parseTarget("  example.com ")
        expectEqual(bare?.host, "example.com", "bare host keeps the default port's host")
        expectEqual(bare?.port, 443, "bare host uses the default port")

        let ipv6 = ProxyProbe.parseTarget("[2001:db8::1]:2222")
        expectEqual(ipv6?.host, "2001:db8::1", "bracketed IPv6 host")
        expectEqual(ipv6?.port, 2222, "bracketed IPv6 port")

        expect(ProxyProbe.parseTarget("") == nil, "empty target is rejected")
        expect(ProxyProbe.parseTarget("   ") == nil, "blank target is rejected")
        expect(ProxyProbe.parseTarget("host:99999") == nil, "out of range port is rejected")
        expect(ProxyProbe.parseTarget("host:0") == nil, "port zero is rejected")
    }

    // Optional live probe: TAUGE_PROXY_PROBE="host:port[:user[:password]]"
    // answers "does our handshake code actually speak to this proxy".
    if let spec = ProcessInfo.processInfo.environment["TAUGE_PROXY_PROBE"] {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, let port = Int(parts[1]) {
            let endpoint = ProxyEndpoint(type: .http,
                                         host: parts[0],
                                         port: port,
                                         username: parts.count > 2 ? parts[2] : nil,
                                         password: parts.count > 3 ? parts[3] : nil)
            await runAsync("live proxy probe " + spec) {
                let result = await ProxyProbe.test(endpoint, targetHost: "example.com", targetPort: 443,
                                                   timeout: .seconds(10))
                print("     probe => " + result.outcome.rawValue + " (" + String(result.elapsedMilliseconds)
                      + " ms) " + result.summary)
            }
        }
    }

    await runAsync("proxy probe separates an unreachable proxy from a rejected tunnel") {
        // Port 1 on loopback has no listener, so the proxy hop itself fails and
        // the probe must not blame the target host.
        let proxy = ProxyEndpoint(type: .http, host: "127.0.0.1", port: 1,
                                  username: "", password: "")
        let result = await ProxyProbe.test(proxy, targetHost: "example.com", targetPort: 443,
                                          timeout: .seconds(3))
        expectEqual(result.outcome, .proxyUnreachable, "closed port looks unreachable")
        expect(!result.isSuccess, "unreachable proxy is not a success")
        expect(result.summary.contains(L("连不上代理 ")), "summary names the proxy hop")
        expect(result.recommendation != nil, "unreachable proxy gets a recommendation")
        expect(result.elapsedMilliseconds >= 0, "elapsed time is recorded")

        // HTTPS (TLS) proxying is not implemented; the probe says so without
        // touching the network.
        let https = ProxyEndpoint(type: .https, host: "127.0.0.1", port: 1,
                                  username: "", password: "")
        let httpsResult = await ProxyProbe.test(https, targetHost: "example.com", targetPort: 443,
                                               timeout: .seconds(1))
        expectEqual(httpsResult.outcome, .handshakeRejected, "TLS proxy is rejected")
        expect(httpsResult.summary.contains("HTTPS"), "TLS proxy summary mentions HTTPS")
    }
}
