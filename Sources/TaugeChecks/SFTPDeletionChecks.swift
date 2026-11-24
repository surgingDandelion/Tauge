import Foundation
import TaugeKit

@MainActor
func runSFTPDeletionChecks() async {
    let server = MockSFTPServer()
    let client = SFTPClient(transport: server, configuration: .init(chunkSize: 32768, requestTimeout: 5))
    do {
        try await client.start()
    } catch {
        expect(false, "SFTP deletion fixture starts: \(error)")
        return
    }

    await runAsync("sftp removes nonempty directories without following symbolic links") {
        let tree = "/remote/要删除's folder"
        let empty = tree + "/empty"
        let hidden = tree + "/nested/.hidden"
        let link = tree + "/external link"
        let target = "/remote/keep"
        let sentinel = target + "/data.txt"
        let payload = Data("keep".utf8)
        server.seedDirectory(empty)
        server.seedFile(hidden, data: Data("hidden".utf8))
        server.seedFile(sentinel, data: payload)
        server.seedSymlink(link, to: target)
        server.advertiseNames([".", ".."], in: tree)
        server.advertiseNames([".", ".."], in: tree + "/nested")

        do {
            try await client.removeDirectory(tree)
            expect(false, "the low-level RMDIR still requires an empty directory")
        } catch SFTPError.status(let status) {
            expectEqual(status.code, .failure, "RMDIR rejects the nonempty tree")
        }

        try await client.removeItem(tree)
        expectEqual(server.filePermissions(tree), nil, "the selected directory is removed")
        expectEqual(server.filePermissions(empty), nil, "empty child directories are removed")
        expectEqual(server.filePermissions(hidden), nil, "hidden files inside a nested directory are removed")
        expectEqual(server.filePermissions(link), nil, "the link itself is removed")
        expect(!server.didOpenSymlink(link), "recursive deletion never opens a symbolic link as a directory")
        expectEqual(server.fileData(sentinel), payload, "the target of the link survives")
    }

    await runAsync("sftp rejects removal outside the selected tree") {
        let tree = "/remote/invalid listing"
        let sentinel = "/remote/preserve.txt"
        let payload = Data("preserve".utf8)
        server.seedFile(sentinel, data: payload)

        for path in ["", "/", ".", ".."] {
            do {
                try await client.removeItem(path)
                expect(false, "unsafe deletion path must throw: \(String(reflecting: path))")
            } catch {
                expectEqual(server.fileData(sentinel), payload, "invalid roots leave other files in place")
            }
        }

        for name in ["../preserve.txt", "invalid\u{0}name"] {
            server.seedFile(tree + "/child.txt", data: Data())
            server.advertiseNames([name], in: tree)
            do {
                try await client.removeItem(tree)
                expect(false, "an unsafe READDIR name must throw")
            } catch {
                expectEqual(server.fileData(sentinel), payload, "malformed names leave other files in place")
            }
        }
    }

    await runAsync("sftp reports deletion failure and allows a retry") {
        let tree = "/remote/retry folder"
        let first = tree + "/a.txt"
        let denied = tree + "/z.txt"
        server.seedFile(first, data: Data())
        server.seedFile(denied, data: Data())
        server.failNextRemoval(denied, with: .permissionDenied)

        do {
            try await client.removeItem(tree)
            expect(false, "a permission error from REMOVE must propagate")
        } catch SFTPError.status(let status) {
            expectEqual(status.code, .permissionDenied, "the actual SFTP status is preserved")
        }
        expect(server.filePermissions(tree) != nil, "the directory remains after a child deletion fails")
        expect(server.filePermissions(denied) != nil, "the child that failed remains")

        try await client.removeItem(tree)
        try await client.removeItem(tree)
        expectEqual(server.filePermissions(tree), nil, "retry completes partial deletion and accepts a missing path")
        expectEqual(server.filePermissions(first), nil, "the ordinary file is removed")
        expectEqual(server.filePermissions(denied), nil, "the previously failing file is removed")
    }

    await client.shutdown()
}
