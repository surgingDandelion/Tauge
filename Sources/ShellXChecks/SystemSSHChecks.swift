import Foundation
import NIOCore
import NIOPosix
import ShellXKit

/// Covers the "system ssh" compatibility transport: the argv/env the app hands
/// to /usr/bin/ssh, the temporary key + askpass workspace, the host preference
/// round trip, and one real (failing fast) spawn so process plumbing is checked.
func runSystemSSHChecks() {
    // MARK: Preferences

    run("system ssh transport raw values are stable") {
        expectEqual(HostTransport.builtin.rawValue, "builtin", "builtin raw value")
        expectEqual(HostTransport.system.rawValue, "system", "system raw value")
        expectEqual(HostTransport.allCases.count, 2, "two transports")
        expect(!HostTransport.system.displayName.isEmpty, "system transport has a name")
        expect(HostTransport.system.detail.contains("ssh-rsa"), "detail explains the legacy algorithms")
    }

    run("host transport survives a store round trip") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shellx-systemssh-" + UUID().uuidString)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("hosts.sqlite")

        let systemHost = SSHHost(name: "legacy", hostname: "10.103.136.65", port: 23, transport: .system)
        let plainHost = SSHHost(name: "plain", hostname: "example.com")
        do {
            let database = try SQLiteDatabase(path: url.path)
            let store = try HostStore(database: database)
            try store.save(host: systemHost)
            try store.save(host: plainHost)
            database.close()
        }

        let reopened = try SQLiteDatabase(path: url.path)
        let store = try HostStore(database: reopened)
        defer { reopened.close() }
        expectEqual(try store.host(id: systemHost.id)?.transport, .system, "system preference persists")
        expectEqual(try store.host(id: plainHost.id)?.transport, nil, "unset preference stays nil")

        var updated = try store.host(id: systemHost.id)!
        updated.transport = .builtin
        try store.save(host: updated)
        expectEqual(try store.host(id: systemHost.id)?.transport, .builtin, "switching back to builtin persists")
    }

    // MARK: Workspace

    run("workspace writes a private identity file") {
        let keyText = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
        let options = SystemSSHOptions(host: "legacy", port: 23, username: "root",
                                       credential: .key(text: keyText, passphrase: nil))
        let workspace = try SystemSSHWorkspace(options: options)
        defer { workspace.cleanup() }
        guard let keyPath = workspace.keyPath else { throw CheckError.message("no identity file") }
        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "identity is 0600")
        let written = try String(contentsOfFile: keyPath, encoding: .utf8)
        expect(written.hasSuffix("\n"), "identity ends with a newline")
        expect(written.contains("BEGIN OPENSSH PRIVATE KEY"), "identity content is preserved")
        expect(workspace.askpassPath == nil, "no askpass without a secret")
    }

    run("workspace askpass script answers with the secret") {
        let secret = "pa'ss word"
        let options = SystemSSHOptions(host: "legacy", port: 23, username: "root",
                                       credential: .password(secret))
        let workspace = try SystemSSHWorkspace(options: options)
        defer { workspace.cleanup() }
        guard let path = workspace.askpassPath else { throw CheckError.message("no askpass script") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, "askpass is 0700")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expectEqual(process.terminationStatus, 0, "askpass exits cleanly")
        expectEqual(String(decoding: data, as: UTF8.self), secret + "\n", "single quotes survive the shell escape")
    }

    run("workspace cleans up its directory") {
        var directory: URL?
        do {
            let options = SystemSSHOptions(host: "legacy", port: 23, username: "root",
                                           credential: .key(text: "KEY", passphrase: "pass"))
            let workspace = try SystemSSHWorkspace(options: options)
            directory = workspace.directory
            expect(FileManager.default.fileExists(atPath: workspace.directory.path), "directory exists while in use")
            expect(workspace.askpassPath != nil, "passphrase-derived key gets an askpass helper")
            workspace.cleanup()
        }
        if let directory {
            expect(!FileManager.default.fileExists(atPath: directory.path), "cleanup removes the directory")
        }
    }

    run("workspace rejects a missing ssh binary") {
        do {
            _ = try SystemSSHWorkspace(options: SystemSSHOptions(host: "h", port: 22, username: "u",
                                                                 credential: .none),
                                       sshExecutable: "/nonexistent/ssh")
            throw CheckError.message("expected missingExecutable")
        } catch SystemSSHError.missingExecutable {
        }
    }

    // MARK: argv

    func options(_ credential: SystemSSHCredential,
                 jumps: [SystemSSHJump] = [],
                 proxy: ProxyEndpoint? = nil) -> SystemSSHOptions {
        SystemSSHOptions(host: "10.103.136.65", port: 23, username: "root",
                         credential: credential, jumps: jumps, proxy: proxy,
                         connectTimeoutSeconds: 12, keepaliveSeconds: 30)
    }

    func joined(_ options: SystemSSHOptions, _ workspace: SystemSSHWorkspace, _ mode: SystemSSHMode) -> String {
        SystemSSHCommandBuilder.arguments(options: options, workspace: workspace, mode: mode)
            .joined(separator: " ")
    }

    run("terminal argv requests legacy algorithms and a pty") {
        let opts = options(.key(text: "KEY", passphrase: nil))
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let args = SystemSSHCommandBuilder.arguments(options: opts, workspace: workspace, mode: .terminal)
        let line = args.joined(separator: " ")
        expect(line.contains("-o HostKeyAlgorithms=+ssh-rsa"), "ssh-rsa host keys are appended, not replaced")
        expect(line.contains("-o PubkeyAcceptedAlgorithms=+ssh-rsa"), "ssh-rsa user keys are appended")
        expect(line.contains("-o KexAlgorithms=+diffie-hellman-group14-sha1"), "group14-sha1 is appended")
        expect(line.contains("-o Ciphers=+aes128-ctr"), "aes-ctr is appended")
        expect(line.contains("-o MACs=+hmac-sha1"), "hmac-sha1 is appended")
        expect(line.contains("-p 23"), "non-default port is forwarded")
        expect(line.contains("-o BatchMode=yes"), "key-only sessions never prompt")
        expect(line.contains("-o ConnectTimeout=12"), "connect timeout is forwarded")
        expect(line.contains("-o ServerAliveInterval=30"), "keepalive is forwarded")
        expect(args.last == "root@10.103.136.65", "destination is last")
        expect(line.contains("-tt"), "terminal mode asks for a pty")
        expect(line.contains("-i " + (workspace.keyPath ?? "")), "identity path is passed")
        expect(line.contains("-o IdentitiesOnly=yes"), "only our identity is offered")
        expect(!line.contains("-s "), "terminal mode is not a subsystem")
        expect(!line.contains("--"), "terminal mode has no command separator")
    }

    run("command argv separates the remote command") {
        let opts = options(.key(text: "KEY", passphrase: nil))
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let args = SystemSSHCommandBuilder.arguments(options: opts, workspace: workspace,
                                                     mode: .command("uname -s; id"))
        let line = args.joined(separator: " ")
        expect(line.contains(" -- root@10.103.136.65 uname -s; id"), "command follows -- and the destination")
        expect(!line.contains("-tt"), "command mode does not allocate a pty")
    }

    run("sftp argv asks for the subsystem") {
        let opts = options(.key(text: "KEY", passphrase: nil))
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let args = SystemSSHCommandBuilder.arguments(options: opts, workspace: workspace, mode: .sftp)
        let line = args.joined(separator: " ")
        expect(line.contains("-s root@10.103.136.65 sftp"), "sftp subsystem request")
        expect(!line.contains("-tt"), "sftp does not allocate a pty")
    }

    run("password credential disables pubkey auth") {
        let opts = options(.password("secret"))
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let line = joined(opts, workspace, .terminal)
        expect(line.contains("-o PubkeyAuthentication=no"), "pubkey auth is off")
        expect(line.contains("-o PreferredAuthentications=password,keyboard-interactive"), "password auth is preferred")
        expect(line.contains("-o BatchMode=no"), "askpass mode allows prompting")
        expect(!line.contains("-i "), "no identity file for a password")

        let env = SystemSSHCommandBuilder.environment(options: opts, workspace: workspace, base: ["HOME": "/Users/x"])
        expectEqual(env["SSH_ASKPASS"], workspace.askpassPath, "askpass helper is wired up")
        expectEqual(env["SSH_ASKPASS_REQUIRE"], "force", "askpass is forced")
        expectEqual(env["TERM"], "xterm-256color", "terminal type is forwarded")
        expectEqual(env["HOME"], "/Users/x", "the rest of the environment is preserved")
    }

    run("agent credential leaves authentication to OpenSSH") {
        let opts = options(.agent)
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let line = joined(opts, workspace, .terminal)
        expect(!line.contains("PubkeyAuthentication"), "agent auth is not disabled")
        expect(!line.contains("-i "), "no inline identity")
        expect(line.contains("-o BatchMode=yes"), "agent mode needs no prompt")
    }

    run("jump chain becomes ProxyCommand scripts that keep the legacy options") {
        let opts = options(.key(text: "KEY", passphrase: nil),
                           jumps: [SystemSSHJump(host: "136.78", port: 22, username: "root"),
                                   SystemSSHJump(host: "10.103.136.65", port: 23, username: "root")])
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        guard let proxy = workspace.jumpProxyPath else { throw CheckError.message("no jump proxy script") }
        let line = joined(opts, workspace, .terminal)
        expect(line.contains("-o ProxyCommand=" + proxy + " %h %p"), "the destination is reached through the last hop script")
        expect(!line.contains("-J "), "no -J: it does not forward the legacy algorithms to the hop")

        let lastHop = try String(contentsOfFile: proxy, encoding: .utf8)
        expect(lastHop.hasPrefix("#!/bin/sh"), "hop script is a shell script")
        expect(lastHop.contains("-p 23"), "last hop keeps its own port")
        expect(lastHop.contains("-l 'root'"), "last hop keeps its own user")
        expect(lastHop.contains("-W \"$1:$2\""), "hop script forwards the real destination")
        expect(lastHop.contains("HostKeyAlgorithms=+ssh-rsa"), "hop carries the legacy algorithms")
        expect(lastHop.contains("BatchMode=yes"), "hop never prompts")
        if let keyPath = workspace.keyPath {
            expect(lastHop.contains("'-i' '" + keyPath + "'"),
                   "hop carries the temporary identity")
        } else {
            expect(false, "workspace has a temporary identity for the hop")
        }
        expect(lastHop.contains("'-o' 'IdentitiesOnly=yes'"),
               "hop uses the temporary identity exclusively")

        let firstHopPath = workspace.directory.appendingPathComponent("jump1.sh").path
        let firstHop = try String(contentsOfFile: firstHopPath, encoding: .utf8)
        expect(firstHop.contains("-p 22"), "first hop keeps its own port")
        expect(!firstHop.contains("ProxyCommand"), "first hop dials the first server directly")
        expect(lastHop.contains(firstHopPath + " %h %p"), "second hop reaches itself through the first script")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: proxy) {
            expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, "hop script is 0700")
        }
    }

    run("socks proxy becomes a ProxyCommand") {
        let opts = options(.none,
                           proxy: ProxyEndpoint(type: .socks5, host: "127.0.0.1", port: 1080))
        try SystemSSHCommandBuilder.validate(options: opts)
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let line = joined(opts, workspace, .terminal)
        expect(line.contains("/usr/bin/nc -X 5 -x 127.0.0.1:1080 %h %p"), "socks5 proxy command")
    }

    run("authenticated and https proxies are rejected up front") {
        do {
            try SystemSSHCommandBuilder.validate(options: options(.none,
                proxy: ProxyEndpoint(type: .http, host: "p", port: 8080, username: "u", password: "p")))
            throw CheckError.message("expected unsupportedProxy for credentials")
        } catch SystemSSHError.unsupportedProxy {
        }
        do {
            try SystemSSHCommandBuilder.validate(options: options(.none,
                proxy: ProxyEndpoint(type: .https, host: "p", port: 443)))
            throw CheckError.message("expected unsupportedProxy for https")
        } catch SystemSSHError.unsupportedProxy {
        }
        do {
            try SystemSSHCommandBuilder.validate(options: options(.none,
                jumps: [SystemSSHJump(host: "bastion", port: 22, username: "root")],
                proxy: ProxyEndpoint(type: .socks5, host: "127.0.0.1", port: 1080)))
            throw CheckError.message("expected unsupportedProxy for proxy + jump")
        } catch SystemSSHError.unsupportedProxy {
        }
    }

    // MARK: Hop handshake detection

    run("a hop that hangs up mid-handshake is reported as a legacy algorithm problem") {
        let mapped = SSHClient.rejectedHandshake(at: "第 1 跳 root@10.103.136.65:23",
                                                 error: ChannelError.eof,
                                                 host: "10.103.136.65",
                                                 port: 23)
        guard let mapped else { throw CheckError.message("expected a handshake failure") }
        expectEqual(mapped.stage, .keyExchange, "the caller can retry with the system ssh transport")
        expect(mapped.detail.hasPrefix("第 1 跳 root@10.103.136.65:23"), "the failing hop is named first")
        expect(mapped.detail.contains("ssh-rsa"), "the likely cause is spelled out")

        let closedLater = SSHClient.rejectedHandshake(at: "第 2 跳 root@bastion:22",
                                                      error: ChannelError.ioOnClosedChannel,
                                                      host: "bastion",
                                                      port: 22)
        expectEqual(closedLater?.stage, .keyExchange, "a channel closed on open counts as well")

        let unrelated = SSHClient.rejectedHandshake(at: "第 1 跳 root@bastion:22",
                                                    error: IOError(errnoCode: ECONNREFUSED, reason: "refused"),
                                                    host: "bastion",
                                                    port: 22)
        expect(unrelated == nil, "genuine network failures keep their own stage")
    }

    // MARK: One real spawn

    run("runner reports a refused connection instead of hanging") {
        let opts = SystemSSHOptions(host: "127.0.0.1", port: 9, username: "root",
                                    credential: .none, connectTimeoutSeconds: 5)
        let workspace = try SystemSSHWorkspace(options: opts)
        defer { workspace.cleanup() }
        let result = SystemSSHRunner.run(options: opts, workspace: workspace, command: "true", timeout: 20)
        expect(result.exitCode != 0, "ssh exits non-zero when nothing listens")
        expect(!result.timedOut, "a refused connection fails fast")
        expect(!result.stderrText.isEmpty, "ssh explains the failure on stderr")
    }
}
