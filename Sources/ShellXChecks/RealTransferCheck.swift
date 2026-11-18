import Foundation
import ShellXKit

/// Optional end-to-end check for the transfer engine against a real SFTP server,
/// optionally reached through a bastion. Mirrors what the app does when a user
/// uploads or downloads from the SFTP pane: enqueue an item, wait for a terminal
/// progress state, and compare the bytes on both sides.
///
/// Environment: the same variables as the real jump check, plus
///   SHELLX_REAL_TRANSFER=1   enable the check
@MainActor
func runRealTransferChecks() async {
    guard ProcessInfo.processInfo.environment["SHELLX_REAL_TRANSFER"] == "1" else { return }

    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["SHELLX_REAL_JUMP_HOST"],
          let user = environment["SHELLX_REAL_JUMP_USER"] else {
        print("real.xfer: missing SHELLX_REAL_JUMP_HOST/USER")
        return
    }
    let port = Int(environment["SHELLX_REAL_JUMP_PORT"] ?? "22") ?? 22
    let keyPath = environment["SHELLX_REAL_JUMP_KEY"] ?? (NSHomeDirectory() + "/.ssh/id_rsa")
    let via = environment["SHELLX_REAL_JUMP_VIA"]
    let viaPort = Int(environment["SHELLX_REAL_JUMP_VIA_PORT"] ?? "22") ?? 22
    let viaUser = environment["SHELLX_REAL_JUMP_VIA_USER"]

    await runAsync("real.xfer uploads and downloads through a real SFTP server") {
        let parsed = try SSHKeyParser.parse(path: keyPath, passphrase: nil)
        let material = SSHAuthMaterial.privateKey(parsed.key)
        let trustAll: HostKeyValidator = { _ in .trust(remember: false) }

        var jumps: [SSHJumpEndpoint] = []
        if let via, let viaUser {
            jumps = [SSHJumpEndpoint(host: via,
                                     port: viaPort,
                                     username: viaUser,
                                     auth: material,
                                     hostKeyValidator: trustAll)]
        }
        let client = SSHClient()
        defer { Task { await client.shutdown() } }
        try await withTimeout(45) {
            try await client.connect(SSHConnectOptions(host: host,
                                                      port: port,
                                                      username: user,
                                                      auth: material,
                                                      hostKeyValidator: trustAll,
                                                      jumps: jumps,
                                                      connectTimeout: .seconds(15),
                                                      keepaliveSeconds: 30))
        }
        let sftp = try await withTimeout(30) { try await client.openSFTP() }
        print("real.xfer: sftp ready via \(jumps.isEmpty ? "direct" : "bastion")")

        let engine = TransferEngine(configuration: .init(maxConcurrent: 2, maxRetries: 1))
        let tag = UUID().uuidString.prefix(8)
        let payload = makePayload(count: 256 * 1024, seed: 7)
        let remotePath = "/tmp/shellx-xfer-\(tag).bin"
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellx-xfer-\(tag)", isDirectory: true)
        try? FileManager.default.removeItem(at: localDir)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localFile = localDir.appendingPathComponent("payload.bin")
        try payload.write(to: localFile)

        // Upload.
        let uploadID = await engine.enqueue(TransferItem(direction: .upload,
                                                         sourcePath: localFile.path,
                                                         destinationPath: remotePath,
                                                         conflictPolicy: .overwrite),
                                            remote: sftp)
        let uploadState = await waitForTerminal(engine, id: uploadID, seconds: 60)
        expectEqual(uploadState?.state, .completed, "real upload completed (\(uploadState?.errorMessage ?? "no error"))")
        let remoteBytes = try await withTimeout(30) { try await sftp.readFile(remotePath) }
        expectEqual(remoteBytes.count, payload.count, "real upload stored \(payload.count) bytes")
        expect(remoteBytes == payload, "real upload bytes match the local file")

        // Download.
        let downloadPath = localDir.appendingPathComponent("back.bin").path
        let downloadID = await engine.enqueue(TransferItem(direction: .download,
                                                           sourcePath: remotePath,
                                                           destinationPath: downloadPath,
                                                           conflictPolicy: .overwrite),
                                              remote: sftp)
        let downloadState = await waitForTerminal(engine, id: downloadID, seconds: 60)
        expectEqual(downloadState?.state, .completed, "real download completed (\(downloadState?.errorMessage ?? "no error"))")
        let back = try Data(contentsOf: URL(fileURLWithPath: downloadPath))
        expect(back == payload, "real download bytes match the remote file")

        // Recursive directory upload, as the SFTP pane does for folders.
        let treeDir = localDir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: treeDir.appendingPathComponent("nested", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: treeDir.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: treeDir.appendingPathComponent("nested/b.txt"))
        let remoteTree = "/tmp/shellx-xfer-\(tag)-tree"
        let treeID = await engine.enqueue(TransferItem(direction: .upload,
                                                       sourcePath: treeDir.path,
                                                       destinationPath: remoteTree,
                                                       recursive: true,
                                                       conflictPolicy: .overwrite),
                                          remote: sftp)
        let treeState = await waitForTerminal(engine, id: treeID, seconds: 60)
        expectEqual(treeState?.state, .completed, "real recursive upload completed (\(treeState?.errorMessage ?? "no error"))")
        let nested = try await withTimeout(30) { try await sftp.readFile(remoteTree + "/nested/b.txt") }
        expectEqual(String(decoding: nested, as: UTF8.self), "beta", "real recursive upload kept the tree")

        // Clean up.
        try? await sftp.removeFile(remotePath)
        try? await sftp.removeFile(remoteTree + "/nested/b.txt")
        try? await sftp.removeFile(remoteTree + "/a.txt")
        try? await sftp.removeDirectory(remoteTree + "/nested")
        try? await sftp.removeDirectory(remoteTree)
        try? FileManager.default.removeItem(at: localDir)
        await client.shutdown()
        print("real.xfer: done")
    }
}
