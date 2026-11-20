import Foundation
import NIOSSH
import Crypto
import TaugeKit

/// Width and height of a PNG's IHDR chunk, so the icon check needs no image
/// framework: the app draws these files at 12-16pt from a 128px source.
private func pngSize(at url: URL) -> (width: Int, height: Int)? {
    guard let data = try? Data(contentsOf: url), data.count > 24 else { return nil }
    guard data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
    func bigEndian(_ offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
    }
    return (bigEndian(16), bigEndian(20))
}

/// Covers the OS badge: the probe parser (one case per distribution, verbatim
/// output), the bundled logo files, an end-to-end probe over a real SSH channel,
/// and the per-host cache in the catalog.
@MainActor
func runPlatformChecks() async {
    // MARK: Parser

    run("platform reads a macOS probe") {
        let info = HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=Darwin\nSXOS_RELEASE=25.6.0\nSXOS_MACOS=26.6.2\n")
        expectEqual(info?.platform, .macOS, "Darwin kernel means macOS")
        expectEqual(info?.detail, "macOS 26.6.2", "sw_vers version becomes the tooltip")
    }

    run("platform reads an Ubuntu probe") {
        let probe = """
        SXOS_KERNEL=Linux
        SXOS_RELEASE=5.15.0-105-generic
        SXOS_MACOS=
        PRETTY_NAME="Ubuntu 22.04.4 LTS"
        NAME="Ubuntu"
        VERSION_ID="22.04"
        ID=ubuntu
        ID_LIKE=debian
        """
        let info = HostPlatformDetector.parse(probeOutput: probe)
        expectEqual(info?.platform, .ubuntu, "ID=ubuntu wins over its debian ID_LIKE")
        expectEqual(info?.detail, "Ubuntu 22.04.4 LTS", "quoted PRETTY_NAME is unwrapped")
    }

    run("platform reads a CentOS probe") {
        // ID_LIKE lists rhel, so a mapping that checks the family before the
        // brand would draw the Red Hat logo here.
        let probe = """
        SXOS_KERNEL=Linux
        SXOS_RELEASE=4.18.0-513.el8.x86_64
        SXOS_MACOS=
        NAME="CentOS Stream"
        VERSION="9"
        ID="centos"
        ID_LIKE="rhel fedora"
        PRETTY_NAME="CentOS Stream 9"
        """
        let info = HostPlatformDetector.parse(probeOutput: probe)
        expectEqual(info?.platform, .centos, "CentOS keeps its own logo despite ID_LIKE=rhel")
        expectEqual(info?.detail, "CentOS Stream 9", "PRETTY_NAME is the tooltip")
    }

    let distroCases: [(String, String, HostPlatform)] = [
        ("debian", "ID=debian\nPRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"", .debian),
        ("fedora", "ID=fedora\nPRETTY_NAME=\"Fedora Linux 40\"", .fedora),
        ("rhel", "ID=\"rhel\"\nID_LIKE=\"fedora\"\nPRETTY_NAME=\"Red Hat Enterprise Linux 9.4\"", .redhat),
        ("almalinux", "ID=\"almalinux\"\nID_LIKE=\"rhel centos fedora\"", .almalinux),
        ("arch", "ID=arch\nPRETTY_NAME=\"Arch Linux\"", .archlinux),
        ("opensuse-leap", "ID=\"opensuse-leap\"\nID_LIKE=\"suse opensuse\"", .opensuse),
        ("alpine", "ID=alpine\nPRETTY_NAME=\"Alpine Linux v3.20\"", .alpinelinux),
        // Rocky has no logo of its own, so it must fall back to the generic Tux
        // rather than borrow CentOS or Red Hat.
        ("rocky", "ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"", .linux),
        // Mint names itself and lists a single family, so the Ubuntu logo is right.
        ("linuxmint", "ID=linuxmint\nID_LIKE=ubuntu\nPRETTY_NAME=\"Linux Mint 22\"", .ubuntu),
        ("unknown distro", "ID=\"weirdos\"\nPRETTY_NAME=\"WeirdOS 1.0\"", .linux),
    ]
    for (label, extra, expected) in distroCases {
        run("platform reads a \(label) probe") {
            let probe = "SXOS_KERNEL=Linux\nSXOS_RELEASE=6.1.0\nSXOS_MACOS=\n" + extra + "\n"
            expectEqual(HostPlatformDetector.parse(probeOutput: probe)?.platform, expected, "\(label) mapping")
        }
    }

    run("platform keeps a generic Linux host readable") {
        let info = HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=Linux\nSXOS_RELEASE=5.10.0\nSXOS_MACOS=\n")
        expectEqual(info?.platform, .linux, "kernel without os-release is still Linux")
        expectEqual(info?.detail, "Linux", "no PRETTY_NAME falls back to the label")
        expectEqual(info?.platform.iconName, "os-linux", "generic Linux has the Tux logo")
    }

    run("platform recognizes non-Linux kernels") {
        expectEqual(HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=FreeBSD\nSXOS_RELEASE=14.0-RELEASE\n")?.platform,
                    .freebsd, "FreeBSD kernel")
        expectEqual(HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=FreeBSD\nSXOS_RELEASE=14.0-RELEASE\n")?.detail,
                    "FreeBSD 14.0-RELEASE", "FreeBSD release becomes the tooltip")
        expectEqual(HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=CYGWIN_NT-10.0\n")?.platform,
                    .windows, "Cygwin means Windows")
        let sunos = HostPlatformDetector.parse(probeOutput: "SXOS_KERNEL=SunOS\nSXOS_RELEASE=5.11\n")
        expectEqual(sunos?.platform, .unknown, "unrecognized kernel is not guessed")
        expectEqual(sunos?.detail, "SunOS 5.11", "unknown kernel still reports what it saw")
    }

    run("platform ignores shell noise and empty output") {
        expect(HostPlatformDetector.parse(probeOutput: "") == nil, "no output means no verdict")
        expect(HostPlatformDetector.parse(probeOutput: "Unable to negotiate with 10.0.0.1\n") == nil,
               "banner text without KEY=VALUE means no verdict")
        let noisy = """
        Last login: Tue Nov 12 09:14:03 2024 from 10.0.0.2
        export PATH=/usr/local/bin:$PATH
        SXOS_KERNEL=Linux
        SXOS_RELEASE=6.8.0-45-generic
        SXOS_MACOS=
        ID=ubuntu
        PRETTY_NAME='Ubuntu 24.04.1 LTS'
        """
        let info = HostPlatformDetector.parse(probeOutput: noisy)
        expectEqual(info?.platform, .ubuntu, "prompt noise before the probe output is skipped")
        expectEqual(info?.detail, "Ubuntu 24.04.1 LTS", "single-quoted values are unwrapped too")
    }

    // MARK: Bundled logos

    run("platform logos ship in the app assets") {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TaugeChecks
            .deletingLastPathComponent()   // Sources
        let assets = sources.appendingPathComponent("TaugeApp/Assets")
        for platform in HostPlatform.allCases {
            guard let name = platform.iconName else {
                expect(platform == .windows || platform == .unknown,
                       "\(platform.rawValue) has no logo on purpose")
                continue
            }
            let url = assets.appendingPathComponent(name + ".png")
            guard let size = pngSize(at: url) else {
                expect(false, "missing or invalid logo \(name).png")
                continue
            }
            expect(size.width == 128 && size.height == 128,
                   "\(name).png is 128x128 (got \(size.width)x\(size.height))")
        }
        for expected in ["os-macos", "os-ubuntu", "os-centos", "os-linux"] {
            expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent(expected + ".png").path),
                   "\(expected).png is bundled")
        }
    }

    // MARK: Catalog cache

    run("platform cache survives a catalog reopen") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tauge-platform-checks-" + UUID().uuidString)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("platform.sqlite")
        let host = SSHHost(name: "linux-box", hostname: "10.0.0.9")

        do {
            let database = try SQLiteDatabase(path: url.path)
            let store = try HostStore(database: database)
            try store.save(host: host)
            try store.setHostPlatform(HostPlatformInfo(platform: .ubuntu, detail: "Ubuntu 24.04.1 LTS"),
                                      for: host.id)
            database.close()
        }

        let reopened = try SQLiteDatabase(path: url.path)
        let store = try HostStore(database: reopened)
        let cached = try store.hostPlatforms()
        expectEqual(cached[host.id]?.platform, .ubuntu, "detected platform survives a restart")
        expectEqual(cached[host.id]?.detail, "Ubuntu 24.04.1 LTS", "detail text survives a restart")

        // Re-detecting after an OS upgrade must overwrite, not duplicate, the row.
        try store.setHostPlatform(HostPlatformInfo(platform: .centos, detail: "CentOS Stream 9"), for: host.id)
        let updated = try store.hostPlatforms()
        expectEqual(updated.count, 1, "one row per host")
        expectEqual(updated[host.id]?.platform, .centos, "re-detection replaces the cached platform")

        try store.clearHostPlatform(for: host.id)
        expect(try store.hostPlatforms()[host.id] == nil, "reset clears the cached platform")

        try store.save(host: host)
        try store.setHostPlatform(HostPlatformInfo(platform: .debian, detail: "Debian 12"), for: host.id)
        try store.deleteHost(id: host.id)
        expect(try store.hostPlatforms().isEmpty, "deleting a host drops its cached platform")
        reopened.close()
    }

    // MARK: End to end over SSH

    let server = MockSSHServer()
    do {
        try server.start()
    } catch {
        expect(false, "mock ssh server binds: \(error)")
        return
    }
    defer { server.stop() }

    let centosProbe = """
    SXOS_KERNEL=Linux
    SXOS_RELEASE=4.18.0-513.el8.x86_64
    SXOS_MACOS=
    NAME="CentOS Stream"
    VERSION="9"
    ID="centos"
    ID_LIKE="rhel fedora"
    PRETTY_NAME="CentOS Stream 9"

    """
    server.stubExec(command: HostPlatformDetector.probeCommand, output: centosProbe)

    await runAsync("platform probe runs over a real exec channel") {
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
            let info = await HostPlatformDetector.detect(using: client, timeout: .seconds(10))
            expectEqual(info?.platform, .centos, "probe output over the wire maps to CentOS")
            expectEqual(info?.detail, "CentOS Stream 9", "tooltip comes from the remote PRETTY_NAME")

            // The badge is probed on every connection, so a second probe on the
            // same client must work and must not leave the channel wedged.
            let again = await HostPlatformDetector.detect(using: client, timeout: .seconds(10))
            expectEqual(again?.platform, .centos, "detection is repeatable on one connection")

            let sftp = try await client.openSFTP()
            expect((try await sftp.realPath(".")) == "/", "detection does not disturb later SFTP channels")
            await sftp.shutdown()
            await client.shutdown()
        } catch {
            expect(false, "platform probe over mock ssh: \(error)")
            await client.shutdown()
        }
    }

    await runAsync("platform probe returns partial output instead of hanging") {
        // A login script that never exits, or a host that keeps the channel open,
        // must not leave the sidebar spinning: the timeout returns what arrived.
        server.stubExec(command: HostPlatformDetector.probeCommand,
                        output: "SXOS_KERNEL=Linux\nSXOS_RELEASE=6.8.0\nSXOS_MACOS=\nID=ubuntu\n",
                        holdOpen: true)
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
            let started = Date()
            let info = await HostPlatformDetector.detect(using: client, timeout: .seconds(1))
            let elapsed = Date().timeIntervalSince(started)
            expectEqual(info?.platform, .ubuntu, "partial probe output is still parsed")
            expect(elapsed < 4, "probe gives up on schedule (\(String(format: "%.2f", elapsed))s)")
            await client.shutdown()
        } catch {
            expect(false, "platform probe timeout path: \(error)")
            await client.shutdown()
        }
    }
}
