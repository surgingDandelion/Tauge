import Foundation
import NIOCore
import NIOSSH
import Crypto
import TaugeKit

/// Rejects every credential, so a jump host can be made to look like it is refusing
/// the login.
final class DenyAllAuth: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .all

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.failure)
    }
}

/// Jump chains must be built by opening direct-tcpip tunnels hop by hop; the
/// destination is not necessarily reachable from this machine, so the initial TCP
/// connection has to go to the first jump host.
@MainActor
func runJumpChainChecks() async {
    let trustAll: HostKeyValidator = { _ in .trust(remember: false) }
    let material = SSHAuthMaterial.privateKey(NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()))

    // MARK: single hop through a relay host

    let target = MockSSHServer()
    let jump = MockSSHServer()
    guard (try? target.start()) != nil, (try? jump.start()) != nil else {
        expect(false, "jump chain servers bind")
        return
    }
    defer {
        jump.stop()
        target.stop()
    }

    await runAsync("jump.chain one hop relays through the jump host") {
        let client = SSHClient()
        let options = SSHConnectOptions(host: "127.0.0.1",
                                        port: target.port,
                                        username: "target-user",
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        jumps: [SSHJumpEndpoint(host: "127.0.0.1",
                                                                port: jump.port,
                                                                username: "jump-user",
                                                                auth: material,
                                                                hostKeyValidator: trustAll)],
                                        connectTimeout: .seconds(10),
                                        keepaliveSeconds: 40)
        do {
            try await client.connect(options)
            let requests = jump.tunnelRequests
            expectEqual(requests.count, 1, "jump host relays exactly one connection")
            expectEqual(requests.first?.port, target.port, "relay targets the destination port")
            expectEqual(target.tunnelRequests.count, 0, "the destination is not asked to relay")
            let hops = await client.jumpChainDescription
            expectEqual(hops.count, 1, "chain reports one hop")

            let sftp = try await client.openSFTP()
            let cwd = try await sftp.realPath(".")
            expectEqual(cwd, "/", "sftp works through the tunnel")
            let payload = makePayload(count: 96_000, seed: 23)
            target.sftp.seedFile("/jump-transfer.bin", data: payload)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tauge-jump-transfer-" + UUID().uuidString,
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = TransferEngine(configuration: .init(maxConcurrent: 1,
                                                             maxRetries: 0,
                                                             downloadWindow: 8,
                                                             uploadWindow: 8,
                                                             chunkSize: 32768))
            let destination = root.appendingPathComponent("jump-transfer.bin")
            let item = TransferItem(hostID: UUID(),
                                    direction: .download,
                                    sourcePath: "/jump-transfer.bin",
                                    destinationPath: destination.path)
            let transferID = await engine.enqueue(item, remote: sftp)
            let progress = await waitForTerminal(engine, id: transferID, seconds: 20)
            let transferError = progress?.errorMessage ?? "none"
            expectEqual(progress?.state, .completed,
                        "transfer completes through the jump host (error: \(transferError))")
            expectEqual(try Data(contentsOf: destination), payload,
                        "transfer bytes survive the jump host")
            await sftp.shutdown()
            await client.shutdown()
        } catch {
            let counts = jump.tunnelByteCounts
            expect(false, "single hop connection: \(error) [relayed up=\(counts.up) down=\(counts.down)]")
        }
    }

    // MARK: two hops, each relayed by the previous host

    let first = MockSSHServer()
    let second = MockSSHServer()
    let destination = MockSSHServer()
    guard (try? first.start()) != nil, (try? second.start()) != nil, (try? destination.start()) != nil else {
        expect(false, "two hop servers bind")
        return
    }
    defer {
        first.stop()
        second.stop()
        destination.stop()
    }

    await runAsync("jump.chain two hops open a nested tunnel") {
        let client = SSHClient()
        let options = SSHConnectOptions(host: "127.0.0.1",
                                        port: destination.port,
                                        username: "target-user",
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        jumps: [
                                            SSHJumpEndpoint(host: "127.0.0.1", port: first.port, username: "first", auth: material, hostKeyValidator: trustAll),
                                            SSHJumpEndpoint(host: "127.0.0.1", port: second.port, username: "second", auth: material, hostKeyValidator: trustAll),
                                        ],
                                        connectTimeout: .seconds(10),
                                        keepaliveSeconds: 40)
        do {
            try await client.connect(options)
            expectEqual(first.tunnelRequests.count, 1, "first hop relays one connection")
            expectEqual(first.tunnelRequests.first?.port, second.port, "first hop points at the second hop")
            expectEqual(second.tunnelRequests.count, 1, "second hop relays one connection")
            expectEqual(second.tunnelRequests.first?.port, destination.port, "second hop points at the destination")
            expectEqual(destination.tunnelRequests.count, 0, "destination only terminates")
            let hops = await client.jumpChainDescription
            expectEqual(hops.count, 2, "chain reports two hops")

            let sftp = try await client.openSFTP()
            _ = try await sftp.listDirectory("/")
            await sftp.shutdown()
            await client.shutdown()
        } catch {
            let a = first.tunnelByteCounts
            let b = second.tunnelByteCounts
            expect(false, "two hop connection: \(error) [first up=\(a.up) down=\(a.down)] [second up=\(b.up) down=\(b.down)]")
        }
    }

    // MARK: a rejected jump login names the hop that failed

    let refusingJump = MockSSHServer(authentication: DenyAllAuth())
    let reachable = MockSSHServer()
    guard (try? refusingJump.start()) != nil, (try? reachable.start()) != nil else {
        expect(false, "refusing jump server binds")
        return
    }
    defer {
        refusingJump.stop()
        reachable.stop()
    }

    await runAsync("jump.chain reports which hop rejected the login") {
        let client = SSHClient()
        let options = SSHConnectOptions(host: "127.0.0.1",
                                        port: reachable.port,
                                        username: "target-user",
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        jumps: [SSHJumpEndpoint(host: "127.0.0.1",
                                                                port: refusingJump.port,
                                                                username: "jump-user",
                                                                auth: material,
                                                                hostKeyValidator: trustAll)],
                                        connectTimeout: .seconds(4))
        do {
            try await client.connect(options)
            expect(false, "connecting through a refusing jump host must fail")
        } catch let error as SSHConnectionError {
            expectEqual(error.stage, .authentication, "failure is classified as authentication")
            expect(error.detail.contains(L("第 ") + "1" + L(" 跳 ")), "detail names the failing hop (\(error.detail))")
            expect(error.detail.contains("jump-user"), "detail includes the hop user (\(error.detail))")
            expectEqual(error.port, refusingJump.port, "error points at the jump port")
        } catch {
            expect(false, "unexpected error type: \(error)")
        }
        await client.shutdown()
    }

    // MARK: transport failures carry an actionable message

    await runAsync("jump.chain explains a refused TCP connection") {
        let client = SSHClient()
        let options = SSHConnectOptions(host: "127.0.0.1",
                                        port: 1,
                                        username: "nobody",
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        connectTimeout: .seconds(3))
        do {
            try await client.connect(options)
            expect(false, "connecting to a closed port must fail")
        } catch let error as SSHConnectionError {
            expectEqual(error.stage, .tcp, "refused connection is a TCP stage failure")
            expect(error.detail.contains(L("连接被拒绝")), "refused port is explained (\(error.detail))")
        } catch {
            expect(false, "unexpected error type: \(error)")
        }
        await client.shutdown()
    }

    await runAsync("jump.chain explains an unresolvable host") {
        let client = SSHClient()
        let options = SSHConnectOptions(host: "no-such-host.invalid",
                                        port: 22,
                                        username: "nobody",
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        connectTimeout: .seconds(3))
        do {
            try await client.connect(options)
            expect(false, "connecting to an unknown host must fail")
        } catch let error as SSHConnectionError {
            if error.stage == .dns {
                expect(error.detail.contains(L("无法解析主机名 ")), "DNS failure is explained (\(error.detail))")
            } else {
                // Some sandboxes stall the resolver instead of answering NXDOMAIN;
                // the connect timeout is then the correct, still-explained outcome.
                expectEqual(error.stage, .tcp, "unknown host fails at DNS or times out on TCP")
                expect(error.detail.contains(L(" 秒内没有建立 TCP 连接：目标端口无响应，通常是地址不可达、端口不对，或被防火墙/安全组静默丢弃了握手包")), "timeout is explained (\(error.detail))")
            }
        } catch {
            expect(false, "unexpected error type: \(error)")
        }
        await client.shutdown()
    }
}
