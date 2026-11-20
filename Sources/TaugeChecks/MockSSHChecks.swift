import Foundation
import NIOSSH
import Crypto
import TaugeKit

/// Collects terminal output from a background thread.
final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func contains(_ needle: String) -> Bool {
        text.contains(needle)
    }
}

func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw LiveTimeoutError.timedOut
}

/// End-to-end check against the in-process SSH server: handshake, public key
/// auth, pty + shell channel, subsystem channel and SFTP request/response.
@MainActor
func runMockSSHChecks() async {
    let server = MockSSHServer()
    server.sftp.seedDirectory("/remote")
    server.sftp.seedFile("/remote/hello.txt", data: Data("hello over ssh\r\n".utf8))
    do {
        try server.start()
    } catch {
        expect(false, "mock ssh server binds: \(error)")
        return
    }
    defer { server.stop() }

    await runAsync("mock.ssh handshake and shell channel") {
        let client = SSHClient()
        let material = SSHAuthMaterial.privateKey(NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()))
        let options = SSHConnectOptions(host: "127.0.0.1",
                                        port: server.port,
                                        username: "mockuser",
                                        auth: material,
                                        hostKeyValidator: { _ in .trust(remember: false) },
                                        connectTimeout: .seconds(15))
        do {
            try await client.connect(options)
            let recorder = OutputRecorder()
            let session = try await client.openTerminal(term: "xterm-256color",
                                                        columns: 100,
                                                        rows: 30,
                                                        onData: { recorder.append($0) },
                                                        onClose: { _ in })
            try await waitUntil(10) { recorder.contains("mock-shell-ready") }
            expect(true, "shell channel echoes the server banner")

            session.write(Data("echo tauge-e2e\n".utf8))
            try await waitUntil(10) { recorder.contains("tauge-e2e") }
            expect(true, "terminal input reaches the server and comes back")

            session.resize(columns: 120, rows: 40)
            try await Task.sleep(nanoseconds: 100_000_000)
            expect(server.shellSessions >= 1, "server saw a shell session (\(server.shellSessions))")

            let sftp = try await client.openSFTP()
            let cwd = try await sftp.realPath(".")
            expect(cwd == "/", "sftp realpath returns the server path (\(cwd))")

            let entries = try await sftp.listDirectory("/remote")
            expect(entries.contains { $0.filename == "hello.txt" }, "sftp lists the seeded file")

            let remoteData = try await sftp.readFile("/remote/hello.txt")
            expect(String(decoding: remoteData, as: UTF8.self).contains("hello over ssh"),
                   "sftp reads the seeded file")

            let payload = Data((0..<4096).map { UInt8($0 % 251) })
            try await sftp.writeFile("/remote/uploaded.bin", data: payload)
            expect(server.sftp.fileData("/remote/uploaded.bin") == payload,
                   "sftp write lands on the server intact")
            expect(server.sftpSessions >= 1, "server saw an sftp session (\(server.sftpSessions))")

            await sftp.shutdown()
            await client.shutdown()
            expect(!(await client.isConnected), "client disconnects cleanly")
        } catch {
            expect(false, "mock ssh session: \(error)")
            await client.shutdown()
        }
    }
}
