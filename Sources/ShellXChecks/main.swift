import Foundation
import ShellXKit

setbuf(stdout, nil)

// A tiny self-check runner: the Command Line Tools toolchain ships neither
// XCTest nor swift-testing, so the checks run as a normal executable and exit
// non-zero when something regresses.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line " + String(line) + "] " + message)
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: Int = #line) {
    checks += 1
    let l = lhs
    let r = rhs
    if l != r {
        failures += 1
        print("FAIL [line " + String(line) + "] " + message + " — expected " + String(describing: r) + ", got " + String(describing: l))
    }
}

func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("ok   " + name)
    } catch {
        failures += 1
        print("FAIL " + name + ": " + String(describing: error))
    }
}

func runAsync(_ name: String, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
        print("ok   " + name)
    } catch {
        failures += 1
        print("FAIL " + name + ": " + String(describing: error))
    }
}

// MARK: - SFTP codec

run("sftp.open round trip") {
    let packet = SFTPRequests.open(id: 7, path: "/tmp/文件.txt", flags: [.read, .write])
    var buffer = SFTPCodec.encode(packet)
    guard let decoded = try SFTPCodec.decode(from: &buffer) else {
        throw CheckError.message("packet did not decode")
    }
    expectEqual(decoded.type, SFTPPacketType.open.rawValue, "packet type")
    expect(buffer.isEmpty, "buffer drained")
    var reader = SFTPReader(decoded.payload)
    expectEqual(try reader.uint32(), 7, "request id")
    expectEqual(try reader.string(), "/tmp/文件.txt", "path survives UTF-8")
    expectEqual(try reader.uint32(), SFTPOpenFlags.read.rawValue | SFTPOpenFlags.write.rawValue, "flags")
}

run("sftp.codec waits for remainder") {
    let encoded = SFTPCodec.encode(SFTPRequests.stat(id: 1, path: "/x", followSymlink: true))
    var partial = encoded.prefix(encoded.count - 2)
    expect(try SFTPCodec.decode(from: &partial) == nil, "incomplete packet returns nil")
    partial.append(encoded.suffix(2))
    let decoded = try SFTPCodec.decode(from: &partial)
    expectEqual(decoded?.type, SFTPPacketType.stat.rawValue, "completed packet decodes")
}

run("sftp.status parsing") {
    var writer = SFTPWriter()
    writer.uint32(42)
    writer.uint32(2)
    writer.string("no such file")
    writer.string("en")
    let packet = SFTPPacket(type: SFTPPacketType.status.rawValue, payload: writer.data)
    let parsed = try SFTPCodec.parseResponse(packet)
    expectEqual(parsed.id, 42, "status id")
    guard case .status(let status) = parsed.response else {
        throw CheckError.message("expected status response")
    }
    expectEqual(status.code, .noSuchFile, "status code")
}

run("sftp.truncated string throws") {
    var writer = SFTPWriter()
    writer.uint32(99)
    var reader = SFTPReader(writer.data)
    do {
        _ = try reader.string()
        throw CheckError.message("expected truncation error")
    } catch is SFTPCodecError {
        // expected
    }
}

// MARK: - ssh_config

// OpenSSH keeps the first value seen for each keyword, so the wildcard block
// sits at the end exactly like a well-formed user config.
let sampleConfig = """
Host prod
    HostName 10.0.3.4
    User deploy
    Port 2202
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump bastion

Host bastion
    HostName bastion.example.com
    User ops

Host *
    ServerAliveInterval 30
    User default-user
"""

run("ssh_config parses blocks and wildcard defaults") {
    let hosts = SSHConfigParser.parse(sampleConfig)
    expect(hosts.contains { $0.concreteAliases.contains("prod") }, "prod alias present")
    guard let prod = SSHConfigParser.effective(for: "prod", in: hosts) else {
        throw CheckError.message("prod not resolved")
    }
    expectEqual(prod.hostName, "10.0.3.4", "hostname")
    expectEqual(prod.user, "deploy", "user")
    expectEqual(prod.port, 2202, "port")
    expectEqual(prod.proxyJump, "bastion", "proxy jump")
    expectEqual(prod.identityFiles.first?.hasSuffix("id_ed25519"), true, "identity file")

    guard let bastion = SSHConfigParser.effective(for: "bastion", in: hosts) else {
        throw CheckError.message("bastion not resolved")
    }
    expectEqual(bastion.user, "ops", "explicit value wins over Host *")
    expectEqual(bastion.serverAliveInterval, 30, "wildcard default inherited")
}

run("ssh_config first value wins like OpenSSH") {
    let text = """
Host *
    User wildcard

Host late
    HostName late.example.com
"""
    let hosts = SSHConfigParser.parse(text)
    let late = SSHConfigParser.effective(for: "late", in: hosts)
    expectEqual(late?.user, "wildcard", "wildcard block declared first wins, as in OpenSSH")
    expectEqual(late?.hostName, "late.example.com", "specific keywords still fill in")
}

// MARK: - ConfigResolver

run("resolver inherits closest group value") {
    let proxy = ProxyConfig(name: "corp", type: .http, host: "proxy.local", port: 3128)
    let root = HostGroup(name: "Root", defaults: GroupDefaults(encoding: .gbk,
                                                             terminalType: "xterm-256color",
                                                             keepaliveSeconds: 45))
    let child = HostGroup(parentID: root.id, name: "Child", defaults: GroupDefaults(terminalType: "screen-256color"))
    let host = SSHHost(groupID: child.id,
                       name: "app",
                       hostname: "10.0.0.8",
                       username: "deploy",
                       proxyPolicy: .use(proxy.id))
    let catalog = Catalog(groups: [root, child], hosts: [host], proxies: [proxy])
    let resolved = try ConfigResolver(catalog: catalog).effective(for: host)
    expectEqual(resolved.encoding, .gbk, "encoding inherited from root")
    expectEqual(resolved.terminalType, "screen-256color", "closest terminal type wins")
    expectEqual(resolved.keepaliveSeconds, 45, "keepalive from root")
    expectEqual(resolved.proxy?.host, "proxy.local", "proxy resolved")
    expectEqual(resolved.proxySourceDescription, "Host", "proxy source")
}

run("resolver builds ordered jump chain") {
    let bastion = SSHHost(name: "bastion", hostname: "bastion")
    let inner = SSHHost(name: "inner", hostname: "inner", jumpPolicy: .hosts([bastion.id]))
    let target = SSHHost(name: "target", hostname: "target", jumpPolicy: .hosts([inner.id]))
    let catalog = Catalog(hosts: [bastion, inner, target])
    let resolved = try ConfigResolver(catalog: catalog).effective(for: target)
    expectEqual(resolved.jumps.map(\.host.hostname), ["bastion", "inner"], "nearest hop first")
    expect(ConfigResolver(catalog: catalog).routeDescription(for: resolved).hasSuffix("target"), "route ends at target")
}

run("resolver rejects jump loops") {
    var a = SSHHost(name: "a", hostname: "a")
    let b = SSHHost(name: "b", hostname: "b", jumpPolicy: .hosts([a.id]))
    a.jumpPolicy = .hosts([b.id])
    let catalog = Catalog(hosts: [a, b])
    do {
        _ = try ConfigResolver(catalog: catalog).effective(for: a)
        throw CheckError.message("expected loop rejection")
    } catch ConfigError.jumpLoop {
        // expected
    }
}

// MARK: - Paths and formatting

run("posix path helpers") {
    expectEqual(POSIXPath.normalize("/a/b/../c/./d"), "/a/c/d", "normalize")
    expectEqual(POSIXPath.normalize("/"), "/", "root stays root")
    expectEqual(POSIXPath.join("/a/b", "c"), "/a/b/c", "join")
    expectEqual(POSIXPath.parent("/a/b/c"), "/a/b", "parent")
    expectEqual(POSIXPath.uniqueName(for: "a.txt", existing: ["a.txt"]), "a (1).txt", "rename 1")
    expectEqual(POSIXPath.uniqueName(for: "a.txt", existing: ["a.txt", "a (1).txt"]), "a (2).txt", "rename 2")
}

run("permission and size formatting") {
    expectEqual(FileAttributeFormatter.octal(mode: 0o644), "644", "octal")
    expectEqual(FileAttributeFormatter.symbolic(mode: 0o755, kind: .directory), "drwxr-xr-x", "dir symbolic")
    expectEqual(FileAttributeFormatter.symbolic(mode: 0o600, kind: .file), "-rw-------", "file symbolic")
    expectEqual(FileAttributeFormatter.size(1_048_576), "1.0 MB", "size")
}

run("fingerprint formatting") {
    expectEqual(KeyFingerprint.sha256(Data()), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU", "sha256 of empty data")
}

// MARK: - Local file service

run("local file service lifecycle") {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("shellx-checks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = LocalFileService()
    try service.createDirectory(at: root.appendingPathComponent("sub").path)
    try service.createEmptyFile(at: root.appendingPathComponent("note.txt").path)

    let entries = try service.list(directory: root.path, showHidden: false)
    expectEqual(Set(entries.map(\.name)), ["sub", "note.txt"], "listing")
    expect(entries.first { $0.name == "sub" }?.kind == .directory, "directory kind")

    try service.setPermissions(root.appendingPathComponent("sub").path, mode: 0o700)
    guard let attributes = service.attributes(of: root.appendingPathComponent("sub").path) else {
        throw CheckError.message("missing attributes")
    }
    expect(attributes.modified.timeIntervalSince1970 > 0, "modified date")

    let moved = root.appendingPathComponent("renamed.txt").path
    try service.rename(root.appendingPathComponent("note.txt").path, to: moved)
    expect(service.exists(moved), "renamed file exists")
    try service.remove(at: moved, recursive: false)
    expect(!service.exists(moved), "renamed file removed")
}

// MARK: - SFTP client and transfer engine (in-memory server)

await runAsync("timeout helper fires on a stuck operation") {
    do {
        _ = try await withTimeout(0.5) { try await Task.sleep(nanoseconds: 3_000_000_000) }
        throw CheckError.message("expected a timeout")
    } catch LiveTimeoutError.timedOut {
    }
}

runCatalogChecks()
runTermiusCryptoChecks()
runBoardChecks()
runBoardTreeChecks()
runBoardDropChecks()
runBroadcastChecks()
runUpdateChecks()
await runProxyChecks()
await runTransferChecks()

// MARK: - Operating system detection and its bundled logos

await runPlatformChecks()

// MARK: - Optional real Termius vault import (SHELLX_TERMIUS=1)

await runTermiusVaultChecks()

// MARK: - System ssh compatibility transport

runSystemSSHChecks()

// MARK: - End-to-end SSH + SFTP against an in-process server

await runMockSSHChecks()

// MARK: - Jump chains (direct-tcpip tunnels)

await runJumpChainChecks()

// MARK: - RSA private keys (rsa-sha2-256 / rsa-sha2-512)

await runRSAKeyChecks()

// MARK: - Optional live SSH check (SHELLX_LIVE_SSH=1)

do {
    try await withTimeout(150) { await runLiveSSHChecks() }
} catch {
    failures += 1
    print("FAIL live ssh checks: " + String(describing: error))
}

// MARK: - Optional real bastion check (SHELLX_REAL_JUMP=1)

do {
    try await withTimeout(180) { await runRealJumpChecks() }
} catch {
    failures += 1
    print("FAIL real jump checks: " + String(describing: error))
}

// MARK: - Optional real SFTP transfer check (SHELLX_REAL_TRANSFER=1)

do {
    try await withTimeout(240) { await runRealTransferChecks() }
} catch {
    failures += 1
    print("FAIL real transfer checks: " + String(describing: error))
}

run("workspace snapshot keeps old JSON readable") {
    // Snapshots written before multi-pane support have no additionalHostIDs.
    let id = UUID()
    let legacy = "{\"tabs\":[{\"hostID\":\"" + id.uuidString + "\",\"title\":\"h\",\"showsSFTP\":true}],\"selectedIndex\":0}"
    let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(legacy.utf8))
    expectEqual(snapshot.tabs.count, 1, "legacy snapshot keeps its tab")
    expectEqual(snapshot.tabs[0].hostID, id, "legacy snapshot keeps the host id")
    expectEqual(snapshot.tabs[0].showsSFTP, true, "legacy snapshot keeps the SFTP flag")
    expect(snapshot.tabs[0].additionalHostIDs == nil, "legacy snapshot must decode without extra panes")

    let extra = UUID()
    let modern = WorkspaceSnapshot(tabs: [.init(hostID: id, title: "h", showsSFTP: true, additionalHostIDs: [extra])],
                                   selectedIndex: 0)
    let data = try JSONEncoder().encode(modern)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    expectEqual(decoded.tabs[0].additionalHostIDs ?? [], [extra], "extra panes survive a snapshot round trip")
}

enum CheckError: Error {
    case message(String)
}

// MARK: - Localization

runLocalizationChecks()

// MARK: - Summary

if failures == 0 {
    print("")
    print("All " + String(checks) + " checks passed.")
    exit(0)
} else {
    print("")
    print(String(failures) + " of " + String(checks) + " checks failed.")
    exit(1)
}
