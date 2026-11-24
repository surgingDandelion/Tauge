import Crypto
import Foundation
import NIOCore
import NIOPosix
import TaugeKit

/// Exercises the catalog adapter through the system-SSH command and SFTP paths.
/// The fake ssh program uses local fixtures and never runs the requested command.
@MainActor
func runRemoteCommandServiceChecks() async {
    let files = FileManager.default
    let root = files.temporaryDirectory
        .appendingPathComponent("tauge-remote-command-checks-" + UUID().uuidString, isDirectory: true)
    defer { try? files.removeItem(at: root) }

    do {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try files.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try files.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)

        let executable = root.appendingPathComponent("ssh")
        try remoteCommandSSHFixture.write(to: executable, atomically: false, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let identity = root.appendingPathComponent("fixture.pem")
        let key = P256.Signing.PrivateKey().pemRepresentation
        try (key.hasSuffix("\n") ? key : key + "\n").write(to: identity, atomically: false, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)

        let database = try SQLiteDatabase(path: root.appendingPathComponent("catalog.sqlite").path)
        let store = try HostStore(database: database)
        let source = SSHHost(name: "legacy source", hostname: "source.invalid", port: 2223,
                             username: "fixture", authMethod: .privateKey,
                             identityFilePath: identity.path,
                             proxyPolicy: .direct, jumpPolicy: .direct, transport: .system)
        let destination = SSHHost(name: "legacy destination", hostname: "destination.invalid", port: 2224,
                                  username: "fixture", authMethod: .agent, transport: .system)
        let automatic = SSHHost(name: "auto through legacy jump", hostname: "automatic.invalid", port: 2225,
                                username: "fixture", authMethod: .agent, jumpPolicy: .hosts([source.id]))
        for host in [source, destination, automatic] {
            try store.save(host: host)
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let secrets = InMemorySecretStore()
        let service = RemoteCommandService(store: store,
                                           secrets: secrets,
                                           eventLoopGroup: group,
                                           systemSSHExecutable: executable.path)

        await runAsync("remote command executes using the saved system transport") {
            let command = "fixture command with spaces"
            let result = try await service.execute(target: source.name, command: command)
            expectEqual(result.targetID, source.id, "remote command identifies the catalog target")
            expectEqual(result.command, command, "remote command keeps its original argument")
            expectEqual(result.output, "stdout from the system transport\n", "the OpenSSH subprocess produced output")
        }

        await runAsync("remote command selects system SSH for an automatic target with a system jump") {
            let result = try await service.execute(target: automatic.name, command: "fixture command with spaces")
            expectEqual(result.targetID, automatic.id, "the command runs on the final host")
            expectEqual(result.output, "stdout from the system transport\n", "the system jump route is selected")
        }

        await runAsync("system SSH carries the first jump over an authenticated CONNECT proxy") {
            let authority = "proxy-hop.invalid:2226"
            let username = "fixture-proxy"
            let password = "fixture-password"
            let authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            let listener = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            RemoteCommandProxyFixture(authority: authority, authorization: authorization)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { listener.close(promise: nil) }
            guard let port = listener.localAddress?.port else {
                throw CheckError.message("remote command proxy fixture did not bind")
            }

            let proxy = ProxyConfig(name: "fixture CONNECT proxy", host: "127.0.0.1", port: port,
                                    username: username)
            let hop = SSHHost(name: "proxied jump", hostname: "proxy-hop.invalid", port: 2226,
                              username: "fixture", authMethod: .agent,
                              proxyPolicy: .use(proxy.id), transport: .system)
            let target = SSHHost(name: "behind proxied jump", hostname: "proxy-target.invalid", port: 2227,
                                 username: "fixture", authMethod: .agent, jumpPolicy: .hosts([hop.id]))
            try store.save(proxy: proxy)
            try secrets.setSecret(password, for: .proxyPassword(proxy.id))
            try store.save(host: hop)
            try store.save(host: target)

            let command = "fixture command with spaces"
            let result = try await service.execute(target: target.name, command: command)
            expectEqual(result.targetID, target.id, "the proxy carries the first jump to the requested host")
            expectEqual(result.output, "stdout from the system transport\n",
                        "the first hop received the initial greeting and completed a bidirectional relay")
        }

        await runAsync("system SSH rejects HTTPS proxies explicitly") {
            let proxy = ProxyConfig(name: "fixture TLS proxy", type: .https, host: "127.0.0.1", port: 1)
            let target = SSHHost(name: "behind HTTPS proxy", hostname: "https-proxy-target.invalid",
                                 username: "fixture", authMethod: .agent,
                                 proxyPolicy: .use(proxy.id), transport: .system)
            try store.save(proxy: proxy)
            try store.save(host: target)
            do {
                _ = try await service.execute(target: target.name, command: "fixture command with spaces")
                expect(false, "unsupported TLS proxy should throw before running OpenSSH")
            } catch let error as SSHConnectionError {
                expectEqual(error.stage, .proxy, "unsupported TLS proxy is a proxy-stage error")
                expect(error.detail.contains("HTTPS"), "the diagnostic identifies the unsupported proxy type")
            }
        }

        await runAsync("remote command surfaces the system transport's failure") {
            do {
                _ = try await service.execute(target: source.id.uuidString, command: "fixture fails")
                expect(false, "the subprocess failure should throw")
            } catch {
                expect(error.localizedDescription.contains("fixture refused the command"), "the subprocess diagnostic is kept")
            }
        }

        await runAsync("remote copy opens SFTP on both saved system transports") {
            let payload = Data((0..<70000).map { UInt8($0 % 251) })
            try payload.write(to: sourceDirectory.appendingPathComponent("payload.bin"))
            let result = try await service.copy(sourceTarget: source.id.uuidString, sourcePath: "payload.bin",
                                                destinationTarget: destination.name, destinationPath: ".")
            expectEqual(result.sourceTargetID, source.id, "copy reports its source")
            expectEqual(result.destinationTargetID, destination.id, "copy reports its destination")
            expectEqual(result.files, 1, "one file is copied")
            expectEqual(result.bytes, Int64(payload.count), "copy reports its byte count")
            expectEqual(try Data(contentsOf: destinationDirectory.appendingPathComponent("payload.bin")), payload,
                        "copy preserves the bytes across both subprocesses")
        }

        try await group.shutdownGracefully()
    } catch {
        expect(false, "remote command service fixture: \(error)")
    }
}

private final class RemoteCommandProxyFixture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let authority: String
    private let authorization: String
    private var received = Data()
    private var connected = false

    init(authority: String, authorization: String) {
        self.authority = authority
        self.authorization = authorization
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received.append(contentsOf: buffer.readableBytesView)
        if !connected {
            guard let separator = received.range(of: Data("\r\n\r\n".utf8)) else { return }
            let request = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            received.removeSubrange(..<separator.upperBound)
            guard request.first == "CONNECT \(authority) HTTP/1.1",
                  request.contains("Proxy-Authorization: \(authorization)") else {
                write("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n", context: context)
                return
            }
            connected = true
            // One write puts the initial SSH bytes immediately after the CONNECT header.
            write("HTTP/1.1 200 Connection Established\r\n\r\nSSH-2.0-fixture-bastion\r\n", context: context)
        }

        guard let separator = received.range(of: Data("\r\n".utf8)) else { return }
        let identification = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
        if identification == "SSH-2.0-fixture-client" {
            write("fixture relay ok\n", context: context)
        }
        context.close(promise: nil)
    }

    private func write(_ text: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }
}

private let remoteCommandSSHFixture = #"""
#!/bin/sh
set -eu
root=${0%/*}
port=
subsystem=
identity=
strict=
proxy=
forward=
fail() { printf '%s\n' "$1" >&2; exit 255; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -p) port=$2; shift 2 ;;
        -i) identity=$2; shift 2 ;;
        -l) shift 2 ;;
        -W) forward=$2; shift 2 ;;
        -o)
            case "$2" in
                StrictHostKeyChecking=*) strict=${2#*=} ;;
                ProxyCommand=*) proxy=${2#*=} ;;
            esac
            shift 2 ;;
        -F) shift 2 ;;
        -s) subsystem=sftp; shift ;;
        --) shift; break ;;
        fixture@*|proxy-hop.invalid) break ;;
        *) shift ;;
    esac
done

[ "$strict" = yes ] || fail 'system transport did not require host key verification'
if [ -n "$forward" ]; then
    [ "$1:$port" = proxy-hop.invalid:2226 ] && [ "$forward" = proxy-target.invalid:2227 ] ||
        fail 'unexpected first hop or forwarded target'
    case "$proxy" in
        '/usr/bin/nc -U '*|"'/usr/bin/nc' -U "*) ;;
        *) fail 'the first hop did not use a private relay socket' ;;
    esac
    reply=$(printf 'SSH-2.0-fixture-client\r\n' | /bin/sh -c "$proxy") || fail 'relay command failed'
    expected=$(printf 'SSH-2.0-fixture-bastion\r\nfixture relay ok')
    if [ "$reply" != "$expected" ]; then
        printf 'Relay output bytes:' >&2
        printf '%s' "$reply" | /usr/bin/od -An -tx1 >&2
        fail 'relay lost the initial greeting or client identification'
    fi
    exit 0
fi

case "${1:-}:$port" in
    fixture@source.invalid:2223)
        host=source
        /usr/bin/cmp -s "$identity" "$root/fixture.pem" || fail 'system transport did not use the saved identity' ;;
    fixture@destination.invalid:2224) host=destination ;;
    fixture@automatic.invalid:2225)
        host=automatic
        hop=${proxy% %h %p}
        /usr/bin/grep -qF 'source.invalid' "$hop" || fail 'system transport did not use the saved jump'
        /usr/bin/grep -qF 'StrictHostKeyChecking=yes' "$hop" || fail 'system transport did not verify the jump host key' ;;
    fixture@proxy-target.invalid:2227)
        host=proxy-target
        hop=${proxy% %h %p}
        /bin/sh "$hop" proxy-target.invalid 2227 || fail 'the first jump could not reach the authenticated proxy' ;;
    *) fail 'unexpected fixture endpoint' ;;
esac

if [ "$subsystem" = sftp ] && [ "${2:-}" = sftp ]; then
    exec /usr/libexec/sftp-server -d "$root/$host"
fi

case "${2:-}" in
    true) exit 0 ;;
    'fixture command with spaces') printf '%s\n' 'stdout from the system transport' ;;
    'fixture fails') printf '%s\n' 'fixture refused the command' >&2; exit 7 ;;
    *) fail 'unexpected fixture command' ;;
esac
"""#
