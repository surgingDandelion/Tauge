import Foundation
import NIOSSH
import Crypto
import TaugeKit

/// Records whether a transport reported its own death. The handler runs off the
/// main actor, so the flag is guarded by a lock.
private final class DisconnectFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var reasonText: String?

    func fire(_ reason: String) {
        lock.lock()
        fired = true
        reasonText = reason
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return reasonText
    }
}

/// Checks for the transport keepalive and the SFTP reconnect story: a link that
/// nobody is typing on must stay open, an idle link that dies must be reported,
/// and a client that is closed must say so (the panes rely on it to re-dial).
@MainActor
func runConnectionChecks() async {
    let material = SSHAuthMaterial.privateKey(NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()))

    await runAsync("connection.keepalive keeps an idle link open") {
        let server = MockSSHServer()
        try server.start()
        defer { server.stop() }
        let client = SSHClient()
        let flag = DisconnectFlag()
        await client.setDisconnectHandler { reason in flag.fire(reason) }
        do {
            try await client.connect(SSHConnectOptions(host: "127.0.0.1",
                                                       port: server.port,
                                                       username: "mockuser",
                                                       auth: material,
                                                       hostKeyValidator: { _ in .trust(remember: false) },
                                                       connectTimeout: .seconds(15),
                                                       keepaliveSeconds: 1))
            // Four probe rounds: without the app-level keepalive nothing at all
            // would cross the link here, and any earlier regression (spurious
            // timeout, refused reply treated as a failure) closes the connection.
            try await Task.sleep(nanoseconds: 4_200_000_000)
            let connected = await client.isConnected
            expect(connected, "idle connection survives four keepalive rounds")
            expect(!flag.isSet, "answered keepalives are not reported as a disconnect (" + (flag.reason ?? "none") + ")")
            await client.disconnect()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    await runAsync("connection.keepalive reports a link the peer closed") {
        let server = MockSSHServer()
        try server.start()
        let client = SSHClient()
        let flag = DisconnectFlag()
        await client.setDisconnectHandler { reason in flag.fire(reason) }
        do {
            try await client.connect(SSHConnectOptions(host: "127.0.0.1",
                                                       port: server.port,
                                                       username: "mockuser",
                                                       auth: material,
                                                       hostKeyValidator: { _ in .trust(remember: false) },
                                                       connectTimeout: .seconds(15),
                                                       keepaliveSeconds: 1))
        } catch {
            await client.shutdown()
            throw error
        }
        server.stop()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !flag.isSet {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        expect(flag.isSet, "the tab is told when the transport dies")
        let connected = await client.isConnected
        expect(!connected, "a dead transport reports itself as disconnected")
        await client.shutdown()
    }

    await runAsync("connection.disconnect is not reported as a failure") {
        let server = MockSSHServer()
        try server.start()
        defer { server.stop() }
        let client = SSHClient()
        let flag = DisconnectFlag()
        await client.setDisconnectHandler { reason in flag.fire(reason) }
        do {
            try await client.connect(SSHConnectOptions(host: "127.0.0.1",
                                                       port: server.port,
                                                       username: "mockuser",
                                                       auth: material,
                                                       hostKeyValidator: { _ in .trust(remember: false) },
                                                       connectTimeout: .seconds(15),
                                                       keepaliveSeconds: 1))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            await client.disconnect()
            try await Task.sleep(nanoseconds: 300_000_000)
            expect(!flag.isSet, "closing the tab yourself must not trigger a reconnect")
        } catch {
            await client.shutdown()
            throw error
        }
    }

    await runAsync("connection.sftp client reports its channel closed") {
        let server = MockSFTPServer()
        let client = SFTPClient(transport: server, configuration: .init(chunkSize: 32768, requestTimeout: 5))
        try await client.start()
        let openBefore = await client.isClosed
        expect(!openBefore, "a freshly started SFTP client is open")
        await client.shutdown()
        let closedAfter = await client.isClosed
        expect(closedAfter, "shutdown marks the SFTP client closed so panes re-dial")
    }

    await runAsync("connection.transfer keeps the pane host, not the tab host") {
        let server = MockSFTPServer()
        server.seedFile("/remote/pane.txt", data: Data("pane".utf8))
        let client = SFTPClient(transport: server, configuration: .init(chunkSize: 32768, requestTimeout: 5))
        try await client.start()
        let engine = TransferEngine(configuration: .init(maxConcurrent: 1,
                                                         maxRetries: 0,
                                                         downloadWindow: 4,
                                                         uploadWindow: 4,
                                                         chunkSize: 32768))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tauge-pane-host-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paneHost = UUID()
        let item = TransferItem(hostID: paneHost,
                                direction: .download,
                                sourcePath: "/remote/pane.txt",
                                destinationPath: root.appendingPathComponent("pane.txt").path,
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 15)
        expectEqual(result?.state, .completed, "pane transfer finished (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(result?.hostID, paneHost, "the details list shows the pane's server, not the tab's")
        await client.shutdown()
    }
}
