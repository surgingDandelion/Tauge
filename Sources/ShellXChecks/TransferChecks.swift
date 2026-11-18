import Foundation
import ShellXKit

func makePayload(count: Int, seed: UInt8 = 7) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var value = seed
    for index in 0..<count {
        value = value &* 31 &+ 17
        bytes[index] = value
    }
    return Data(bytes)
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
        .appendingPathComponent("shellx-transfer-" + UUID().uuidString, isDirectory: true)
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
