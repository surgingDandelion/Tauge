import Foundation
import TaugeKit

/// Optional end-to-end check against a real SSH server. It only runs when
/// TAUGE_LIVE_SSH=1 so the default self checks stay hermetic.
///
/// Environment:
///   TAUGE_LIVE_SSH=1           enable the check
///   TAUGE_LIVE_HOST            default 127.0.0.1
///   TAUGE_LIVE_PORT            default 22
///   TAUGE_LIVE_USER            default NSUserName()
///   TAUGE_LIVE_KEY             default ~/.ssh/id_ed25519
@MainActor
func runLiveSSHChecks() async {
    guard ProcessInfo.processInfo.environment["TAUGE_LIVE_SSH"] == "1" else { return }

    let environment = ProcessInfo.processInfo.environment
    let host = environment["TAUGE_LIVE_HOST"] ?? "127.0.0.1"
    let port = Int(environment["TAUGE_LIVE_PORT"] ?? "22") ?? 22
    let user = environment["TAUGE_LIVE_USER"] ?? NSUserName()
    let keyPath = environment["TAUGE_LIVE_KEY"]
        ?? (NSHomeDirectory() + "/.ssh/id_ed25519")

    await runAsync("live.ssh connects, lists SFTP and opens a shell") {
        let parsed = try SSHKeyParser.parse(path: keyPath, passphrase: nil)
        let auth = SSHAuthMaterial.privateKey(parsed.key)
        let fingerprintBox = LockedBox<String?>(nil)

        let validator: HostKeyValidator = { info in
            fingerprintBox.set(info.fingerprintSHA256)
            return .trust(remember: false)
        }

        let client = SSHClient()
        let options = SSHConnectOptions(host: host,
                                        port: port,
                                        username: user,
                                        auth: auth,
                                        hostKeyValidator: validator,
                                        connectTimeout: .seconds(15))
        do {
            try await client.connect(options)
        } catch {
            print("live.ssh connection detail: " + String(describing: error))
            throw error
        }
        print("live: connected")
        // NIO SSH completes key exchange and authentication lazily, on the first
        // child channel, so the host key callback fires after openSFTP/openTerminal.
        let sftp = try await withTimeout(25) { try await client.openSFTP() }
        print("live: sftp opened, fingerprint " + String(describing: fingerprintBox.get()))
        expect(await client.currentState == .connected, "ssh state is connected")
        expect(fingerprintBox.get()?.hasPrefix("SHA256:") == true, "host key fingerprint computed")
        let home = try await sftp.realPath(".")
        expect(home.hasPrefix("/"), "sftp realpath resolves an absolute directory")
        print("live: realpath " + home)
        let listing = try await withTimeout(25) { try await sftp.listDirectory(home) }
        expect(listing.count > 0, "sftp lists the home directory")

        print("live: listed " + String(listing.count) + " entries")
        let hostsAttributes = try await withTimeout(20) { try await sftp.stat("/etc/hosts") }
        expect(hostsAttributes.isRegularFile, "/etc/hosts is a regular file")
        let hostsData = try await withTimeout(20) { try await sftp.readFile("/etc/hosts") }
        expect(String(data: hostsData, encoding: .utf8)?.contains("localhost") == true, "read /etc/hosts over SFTP")

        let output = LockedBox<String>("")
        print("live: read hosts")
        let session = try await withTimeout(25) { try await client.openTerminal(term: "xterm-256color",
                                                    columns: 100,
                                                    rows: 30,
                                                    onData: { data in
            output.append(String(decoding: data, as: UTF8.self))
        }, onClose: { _ in }) }
        print("live: terminal opened")
        try await session.write("echo tauge-live-ok\n")
        try await session.resize(columns: 120, rows: 40)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !output.get().contains("tauge-live-ok\r\n") && !output.get().contains("tauge-live-ok\n") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        expect(output.get().contains("tauge-live-ok"), "shell echoed the marker, got: " + String(output.get().suffix(200)))
        try? await session.write("exit\n")
        session.close()

        await client.shutdown()
    }
}

enum LiveTimeoutError: Error {
    case timedOut
}

private let checkTraceEnabled = ProcessInfo.processInfo.environment["TAUGE_CHECK_TRACE"] == "1"

func trace(_ message: String) {
    guard checkTraceEnabled else { return }
    FileHandle.standardError.write(Data(("trace " + String(Date().timeIntervalSince1970) + " " + message + "\n").utf8))
}

func withTimeout<T: Sendable>(_ seconds: Double,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    trace("withTimeout begin " + String(seconds))
    defer { trace("withTimeout end " + String(seconds)) }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            trace("withTimeout timer fired " + String(seconds))
            throw LiveTimeoutError.timedOut
        }
        guard let result = try await group.next() else { throw LiveTimeoutError.timedOut }
        group.cancelAll()
        trace("withTimeout got result " + String(seconds))
        return result
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func append(_ text: String) {
        lock.lock()
        if let current = value as? String {
            value = (current + text) as! Value
        }
        lock.unlock()
    }
}
