import AppKit
import Foundation
import UniformTypeIdentifiers
import ShellXKit

/// Drag representation for remote entries.
///
/// Every entry is draggable as its remote path (the SFTP panes use that to
/// enqueue downloads), and regular files additionally advertise a file
/// representation so Finder can materialise them. The file is streamed to a
/// temporary location in chunks, so dragging a multi-gigabyte file does not
/// balloon memory (PRD FR-4).
private func dragTrace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SHELLX_TRACE_TRANSFERS"] == "1" else { return }
    FileHandle.standardError.write(Data(("[drag] " + message() + "\n").utf8))
}

enum RemoteFileDrag {
    /// Private type so an in-app drop knows *which* remote pane the path came
    /// from (two panes can show the same absolute path on different hosts).
    static let payloadType = UTType(exportedAs: "com.shellx.remote-path")

    struct Payload: Codable {
        var hostID: String?
        var path: String
        /// Identifies the exact pane, so a drop onto another pane becomes a
        /// server-to-server relay instead of a download.
        var paneID: String?
    }

    static func itemProvider(for entry: FileEntry, client: SFTPClient?, hostID: UUID?, paneID: UUID? = nil) -> NSItemProvider {
        dragTrace("drag started for \(entry.path) (kind \(entry.kind), host \(hostID?.uuidString ?? "none"))")
        let provider = NSItemProvider(object: entry.path as NSString)
        if let hostID, let data = try? JSONEncoder().encode(Payload(hostID: hostID.uuidString, path: entry.path, paneID: paneID?.uuidString)) {
            provider.registerDataRepresentation(forTypeIdentifier: payloadType.identifier,
                                                visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        guard entry.kind == .file, let client else { return provider }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task {
                do {
                    let url = try await materialize(client: client,
                                                    remotePath: entry.path,
                                                    fileName: entry.name)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Streams the remote file into a fresh temporary directory and returns the
    /// file URL the item provider hands to Finder.
    static func materialize(client: SFTPClient, remotePath: String, fileName: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellX-Drag-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(fileName)

        let handle = try await client.open(remotePath, flags: .read)
        do {
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target)
            var offset: UInt64 = 0
            while true {
                let chunk = try await client.read(handle: handle, offset: offset)
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
            }
            try output.close()
        } catch {
            try? await client.close(handle)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try? await client.close(handle)
        return target
    }
}
