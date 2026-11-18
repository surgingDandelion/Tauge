import Foundation
import NIOCore
import ShellXKit

/// Optional end-to-end check that reproduces the real jump-host setup: the target
/// address is only reachable from the bastion, so the client has to dial the bastion
/// first and tunnel with direct-tcpip. Keepalives are enabled on purpose, because
/// setting a socket option on a tunnel channel used to trap the process.
///
/// Environment:
///   SHELLX_REAL_JUMP=1        enable the check
///   SHELLX_REAL_JUMP_HOST     target host
///   SHELLX_REAL_JUMP_PORT     target port, default 22
///   SHELLX_REAL_JUMP_USER     target user
///   SHELLX_REAL_JUMP_VIA      bastion host
///   SHELLX_REAL_JUMP_VIA_PORT bastion port, default 22
///   SHELLX_REAL_JUMP_VIA_USER bastion user
///   SHELLX_REAL_JUMP_KEY      private key for both hops, default ~/.ssh/id_rsa
@MainActor
func runRealJumpChecks() async {
    guard ProcessInfo.processInfo.environment["SHELLX_REAL_JUMP"] == "1" else { return }

    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["SHELLX_REAL_JUMP_HOST"],
          let user = environment["SHELLX_REAL_JUMP_USER"],
          let via = environment["SHELLX_REAL_JUMP_VIA"],
          let viaUser = environment["SHELLX_REAL_JUMP_VIA_USER"] else {
        print("real.jump: missing SHELLX_REAL_JUMP_HOST/USER/VIA/VIA_USER")
        return
    }
    let port = Int(environment["SHELLX_REAL_JUMP_PORT"] ?? "22") ?? 22
    let viaPort = Int(environment["SHELLX_REAL_JUMP_VIA_PORT"] ?? "22") ?? 22
    let keyPath = environment["SHELLX_REAL_JUMP_KEY"] ?? (NSHomeDirectory() + "/.ssh/id_rsa")

    await runAsync("real.jump connects through a bastion with keepalive enabled") {
        let parsed = try SSHKeyParser.parse(path: keyPath, passphrase: nil)
        print("real.jump: loaded \(parsed.keyType) key")
        let material = SSHAuthMaterial.privateKey(parsed.key)
        let trustAll: HostKeyValidator = { _ in .trust(remember: false) }

        let client = SSHClient()
        let options = SSHConnectOptions(host: host,
                                        port: port,
                                        username: user,
                                        auth: material,
                                        hostKeyValidator: trustAll,
                                        jumps: [SSHJumpEndpoint(host: via,
                                                                port: viaPort,
                                                                username: viaUser,
                                                                auth: material,
                                                                hostKeyValidator: trustAll)],
                                        connectTimeout: .seconds(15),
                                        keepaliveSeconds: 30)
        defer { Task { await client.shutdown() } }

        try await withTimeout(40) { try await client.connect(options) }
        print("real.jump: connected through \(via)")
        expect(await client.currentState == .connected, "real hop connection is established")

        let sftp = try await withTimeout(30) { try await client.openSFTP() }
        let home = try await withTimeout(20) { try await sftp.realPath(".") }
        expect(home.hasPrefix("/"), "sftp works through the tunnel, home \(home)")
        print("real.jump: home \(home)")

        let output = LockedBox<String>("")
        let session = try await withTimeout(30) { try await client.openTerminal(term: "xterm-256color",
                                                                              columns: 90,
                                                                              rows: 24,
                                                                              onData: { data in
            output.append(String(decoding: data, as: UTF8.self))
        }, onClose: { _ in }) }
        session.write("echo shellx-real-jump-ok\n")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !output.get().contains("shellx-real-jump-ok\r\n") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        expect(output.get().contains("shellx-real-jump-ok"), "shell runs on the jumped host")
        print("real.jump: shell output \(output.get().count) bytes")
        await client.shutdown()
    }
}
