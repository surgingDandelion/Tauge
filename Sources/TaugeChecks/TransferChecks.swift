import Foundation
import TaugeKit

func makePayload(count: Int, seed: UInt8 = 7) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var value = seed
    for index in 0..<count {
        value = value &* 31 &+ 17
        bytes[index] = value
    }
    return Data(bytes)
}

private actor UploadConflictRecorder {
    private let policies: [String: ConflictPolicy]
    private(set) var paths: [String] = []

    init(_ policies: [String: ConflictPolicy]) {
        self.policies = policies
    }

    func resolve(_ path: String) throws -> ConflictPolicy {
        paths.append(path)
        guard let policy = policies[path] else {
            throw CheckError.message("Unexpected upload conflict at " + path)
        }
        return policy
    }
}

@MainActor
func waitForTerminal(_ engine: TransferEngine, id: UUID, seconds: TimeInterval) async -> TransferProgress? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let progress = await engine.progress(for: id), progress.state.isTerminal {
            return progress
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await engine.progress(for: id)
}

@MainActor
func runTransferChecks() async {
    let server = MockSFTPServer()
    let client = SFTPClient(transport: server, configuration: .init(chunkSize: 32768, requestTimeout: 20))
    let engine = TransferEngine(configuration: .init(maxConcurrent: 1,
                                                     maxRetries: 1,
                                                     downloadWindow: 4,
                                                     uploadWindow: 4,
                                                     chunkSize: 32768))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tauge-transfer-" + UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        print("FAIL transfer checks: " + String(describing: error))
        failures += 1
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        try await client.start()
    } catch {
        print("FAIL transfer checks: client start " + String(describing: error))
        failures += 1
        return
    }

    let secondServer = MockSFTPServer()
    let secondClient = SFTPClient(transport: secondServer,
                                  configuration: .init(chunkSize: 32768, requestTimeout: 20))
    do {
        try await secondClient.start()
    } catch {
        print("FAIL transfer checks: second client start " + String(describing: error))
        failures += 1
        await client.shutdown()
        return
    }

    let payload = makePayload(count: 150_000)
    let sourcePath = root.appendingPathComponent("payload.bin").path

    await runAsync("transfer.upload file through mock SFTP") {
        try payload.write(to: URL(fileURLWithPath: sourcePath))
        let item = TransferItem(hostID: UUID(),
                                direction: .upload,
                                sourcePath: sourcePath,
                                destinationPath: "/remote/payload.bin",
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "upload state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(server.fileData("/remote/payload.bin"), payload, "uploaded bytes match")
        expect(server.writes > 0, "server saw write packets")
        let localMode = ((try? FileManager.default.attributesOfItem(atPath: sourcePath))?[.posixPermissions] as? NSNumber)?.uint16Value
        expectEqual(server.filePermissions("/remote/payload.bin"), localMode, "uploaded file keeps the local permission bits")
    }

    await runAsync("transfer.upload keeps a private local mode") {
        let privatePath = root.appendingPathComponent("private.key").path
        try Data("top secret".utf8).write(to: URL(fileURLWithPath: privatePath))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                              ofItemAtPath: privatePath)
        let item = TransferItem(hostID: UUID(),
                                direction: .upload,
                                sourcePath: privatePath,
                                destinationPath: "/remote/private.key",
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "private upload state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(server.filePermissions("/remote/private.key"), 0o600, "0600 file stays private on the server")
    }

    await runAsync("transfer.upload makes executables at least 0755") {
        let scriptPath = root.appendingPathComponent("run.sh").path
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: URL(fileURLWithPath: scriptPath))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                              ofItemAtPath: scriptPath)
        let item = TransferItem(hostID: UUID(),
                                direction: .upload,
                                sourcePath: scriptPath,
                                destinationPath: "/remote/run.sh",
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "executable upload state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(server.filePermissions("/remote/run.sh"), 0o755, "0700 executable becomes 0755 on the server")
    }

    await runAsync("transfer.download restores the remote permission bits") {
        server.seedFile("/remote/tool.sh", data: Data("#!/bin/sh\n".utf8), permissions: 0o755)
        server.seedFile("/remote/secret.key", data: Data("k".utf8), permissions: 0o600)
        let scriptDestination = root.appendingPathComponent("tool.sh").path
        let keyDestination = root.appendingPathComponent("secret.key").path
        for (remotePath, destination) in [("/remote/tool.sh", scriptDestination),
                                          ("/remote/secret.key", keyDestination)] {
            let item = TransferItem(hostID: UUID(),
                                    direction: .download,
                                    sourcePath: remotePath,
                                    destinationPath: destination,
                                    recursive: false,
                                    conflictPolicy: .overwrite)
            let id = await engine.enqueue(item, remote: client)
            let result = await waitForTerminal(engine, id: id, seconds: 20)
            expectEqual(result?.state, .completed, "permission download state (error: " + (result?.errorMessage ?? "none") + ")")
        }
        let scriptMode = ((try? FileManager.default.attributesOfItem(atPath: scriptDestination))?[.posixPermissions] as? NSNumber)?.uint16Value
        let keyMode = ((try? FileManager.default.attributesOfItem(atPath: keyDestination))?[.posixPermissions] as? NSNumber)?.uint16Value
        expectEqual(scriptMode, 0o755, "downloaded executable keeps 0755")
        expectEqual(keyMode, 0o600, "downloaded key stays 0600")
    }

    await runAsync("transfer.download file through mock SFTP") {
        let destination = root.appendingPathComponent("downloaded.bin").path
        let item = TransferItem(hostID: UUID(),
                                direction: .download,
                                sourcePath: "/remote/payload.bin",
                                destinationPath: destination,
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "download state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(try? Data(contentsOf: URL(fileURLWithPath: destination)), payload, "downloaded bytes match")
        expect(server.reads > 0, "server saw read packets")
    }

    await runAsync("transfer.queue keeps each pane session with its item") {
        let firstPath = root.appendingPathComponent("queued-first.bin").path
        let secondPath = root.appendingPathComponent("queued-second.bin").path
        let firstData = makePayload(count: 250_000, seed: 11)
        let secondData = makePayload(count: 32_000, seed: 12)
        try firstData.write(to: URL(fileURLWithPath: firstPath))
        try secondData.write(to: URL(fileURLWithPath: secondPath))

        let first = TransferItem(direction: .upload,
                                 sourcePath: firstPath,
                                 destinationPath: "/remote/queued-first.bin",
                                 conflictPolicy: .overwrite)
        let second = TransferItem(direction: .upload,
                                  sourcePath: secondPath,
                                  destinationPath: "/remote/queued-second.bin",
                                  conflictPolicy: .overwrite)
        let firstID = await engine.enqueue(first, remote: client)
        let secondID = await engine.enqueue(second, remote: secondClient)
        let firstResult = await waitForTerminal(engine, id: firstID, seconds: 20)
        let secondResult = await waitForTerminal(engine, id: secondID, seconds: 20)
        expectEqual(firstResult?.state, .completed, "first queued transfer completes")
        expectEqual(secondResult?.state, .completed, "second queued transfer completes")
        expectEqual(server.fileData("/remote/queued-first.bin"), firstData,
                    "first transfer uses its source pane")
        expectEqual(secondServer.fileData("/remote/queued-second.bin"), secondData,
                    "second transfer uses its destination pane")
        expect(secondServer.fileData("/remote/queued-first.bin") == nil,
               "queued transfer is not sent to another pane")
    }

    await runAsync("transfer.download resumes from a partial local file") {
        let resumePayload = makePayload(count: 100_000, seed: 3)
        server.seedFile("/remote/resume.bin", data: resumePayload)
        let destination = root.appendingPathComponent("resume.bin").path
        try resumePayload.prefix(45_000).write(to: URL(fileURLWithPath: destination))
        let item = TransferItem(direction: .download,
                                sourcePath: "/remote/resume.bin",
                                destinationPath: destination,
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "resume state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(try? Data(contentsOf: URL(fileURLWithPath: destination)), resumePayload, "resumed bytes match")
        expectEqual(result?.bytesCompleted, 55_000, "resume transferred only the missing bytes")
    }

    await runAsync("transfer.recursive upload keeps the tree shape") {
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: sub.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: tree.appendingPathComponent("two.txt"))
        let script = tree.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: script.path)
        let item = TransferItem(direction: .upload,
                                sourcePath: tree.path,
                                destinationPath: "/remote/tree",
                                recursive: true,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "tree upload state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(server.fileData("/remote/tree/two.txt"), Data("two".utf8), "root file uploaded")
        expectEqual(server.fileData("/remote/tree/sub/one.txt"), Data("one".utf8), "nested file uploaded")
        expectEqual(server.filePermissions("/remote/tree/run.sh"), 0o755, "nested executable keeps its mode")
        expectEqual(server.filePermissions("/remote/tree/sub"), 0o755, "created directories use 0755")
    }

    await runAsync("transfer.upload resolves each existing file independently") {
        let tree = root.appendingPathComponent("conflicts", isDirectory: true)
        let nested = tree.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let replacement = Data("complete replacement".utf8)
        let preserved = Data("keep existing".utf8)
        let newData = Data("new content".utf8)
        let replacingFile = nested.appendingPathComponent("replace.txt")
        try replacement.write(to: replacingFile)
        try Data("do not copy".utf8).write(to: tree.appendingPathComponent("skip.txt"))
        try newData.write(to: nested.appendingPathComponent("new.txt"))

        let target = "/remote/conflicts"
        let replacingPath = target + "/nested/replace.txt"
        let skippingPath = target + "/skip.txt"
        server.seedFile(replacingPath, data: Data("old".utf8))
        server.seedFile(skippingPath, data: preserved)
        let choices = UploadConflictRecorder([replacingPath: .overwrite, skippingPath: .skip])
        let item = TransferItem(direction: .upload,
                                sourcePath: tree.path,
                                destinationPath: target,
                                recursive: true)
        let id = await engine.enqueue(item, remote: client) { path in
            try await choices.resolve(path)
        }
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "mixed upload completes (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(result?.skippedFiles, 1, "only the skipped file is counted")
        expectEqual(await choices.paths.sorted(), [replacingPath, skippingPath].sorted(), "ask once for each conflicting file")
        expectEqual(server.fileData(replacingPath), replacement, "overwrite replaces the old file from the first byte")
        expectEqual(server.fileData(skippingPath), preserved, "skip preserves the second file")
        expectEqual(server.fileData(target + "/nested/new.txt"), newData, "new file uploads without a conflict")

        let nextChoices = UploadConflictRecorder([replacingPath: .skip])
        try Data("a later upload".utf8).write(to: replacingFile)
        let nextItem = TransferItem(direction: .upload,
                                    sourcePath: replacingFile.path,
                                    destinationPath: replacingPath)
        let nextID = await engine.enqueue(nextItem, remote: client) { path in
            try await nextChoices.resolve(path)
        }
        let nextResult = await waitForTerminal(engine, id: nextID, seconds: 20)
        expectEqual(nextResult?.state, .completed, "subsequent upload completes")
        expectEqual(await nextChoices.paths, [replacingPath], "a new upload asks again for the same file")
        expectEqual(server.fileData(replacingPath), replacement, "the new decision preserves the previous upload")
    }

    await runAsync("transfer.upload resolves a file created between stat and open") {
        let target = "/remote/concurrent-create.bin"
        let otherUpload = Data("another upload".utf8)
        server.seedFileBeforeOpen(target, data: otherUpload)
        let choices = UploadConflictRecorder([target: .skip])
        let item = TransferItem(direction: .upload,
                                sourcePath: sourcePath,
                                destinationPath: target)
        let id = await engine.enqueue(item, remote: client) { path in
            try await choices.resolve(path)
        }
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "upload resolves the newly created file (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(await choices.paths, [target], "a collision at open also asks how to proceed")
        expectEqual(server.fileData(target), otherUpload, "skip preserves the file created by the other upload")
    }

    await runAsync("transfer.skip conflict leaves the local file untouched") {
        let destination = root.appendingPathComponent("existing.bin").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: destination))
        let item = TransferItem(direction: .download,
                                sourcePath: "/remote/payload.bin",
                                destinationPath: destination,
                                recursive: false,
                                conflictPolicy: .skip)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "skip state")
        expectEqual(result?.skippedFiles, 1, "skip counted")
        expectEqual(try? Data(contentsOf: URL(fileURLWithPath: destination)), Data("keep".utf8), "skipped file untouched")
    }

    await runAsync("transfer.download directory rebuilds it locally") {
        server.seedDirectory("/remote/dir")
        server.seedFile("/remote/dir/a.txt", data: Data("alpha".utf8))
        server.seedFile("/remote/dir/nested/b.txt", data: Data("beta".utf8))
        let destination = root.appendingPathComponent("dir-copy", isDirectory: true).path
        let item = TransferItem(direction: .download,
                                sourcePath: "/remote/dir",
                                destinationPath: destination,
                                recursive: true,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        let result = await waitForTerminal(engine, id: id, seconds: 20)
        expectEqual(result?.state, .completed, "dir download state (error: " + (result?.errorMessage ?? "none") + ")")
        expectEqual(try? Data(contentsOf: URL(fileURLWithPath: destination + "/a.txt")), Data("alpha".utf8), "flat file copied")
        expectEqual(try? Data(contentsOf: URL(fileURLWithPath: destination + "/nested/b.txt")), Data("beta".utf8), "nested file copied")
    }

    await runAsync("transfer.progress stream reports the final state") {
        var iterator = await engine.progressStream().makeAsyncIterator()
        let streamTask = Task { () -> TransferProgress? in
            var last: TransferProgress?
            while let update = await iterator.next() {
                last = update
                if update.state.isTerminal { break }
            }
            return last
        }
        let destination = root.appendingPathComponent("streamed.bin").path
        let item = TransferItem(direction: .download,
                                sourcePath: "/remote/payload.bin",
                                destinationPath: destination,
                                recursive: false,
                                conflictPolicy: .overwrite)
        let id = await engine.enqueue(item, remote: client)
        _ = await waitForTerminal(engine, id: id, seconds: 20)
        let streamed = await streamTask.value
        expectEqual(streamed?.state, .completed, "stream saw completion")
        expectEqual(streamed?.id, id, "stream carried the transfer id")
    }

    await client.shutdown()
    await secondClient.shutdown()
}
