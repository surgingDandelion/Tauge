import AppKit
import Foundation
import UniformTypeIdentifiers
import TaugeKit

/// Drag representation for remote entries.
///
/// Every entry is draggable as its remote path (the SFTP panes use that to
/// enqueue downloads), and regular files additionally advertise a file
/// representation so Finder can materialise them. The file is streamed to a
/// temporary location in chunks, so dragging a multi-gigabyte file does not
/// balloon memory (PRD FR-4).
private func dragTrace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["TAUGE_TRACE_TRANSFERS"] == "1" else { return }
    FileHandle.standardError.write(Data(("[drag] " + message() + "\n").utf8))
}

/// Rows a drag starting on `entry` carries.
///
/// Dragging a row that is part of the selection moves the whole selection, which
/// is what makes multi-select drag work at all. Dragging a row outside the
/// selection carries only that row: silently transferring unselected files would
/// be worse than the single-item drag it replaces.
func dragEntries(grabbed entry: FileEntry, in entries: [FileEntry], selected: Set<String>) -> [FileEntry] {
    guard selected.contains(entry.path) else { return [entry] }
    let picked = entries.filter { selected.contains($0.path) }
    guard picked.count > 1, picked.contains(where: { $0.path == entry.path }) else { return [entry] }
    return picked
}

enum RemoteFileDrag {
    /// Private type so an in-app drop knows *which* remote pane the path came
    /// from (two panes can show the same absolute path on different hosts).
    static let payloadType = UTType(exportedAs: RemoteDragPayload.typeIdentifier)

    typealias Payload = RemoteDragPayload

    static func itemProvider(for entry: FileEntry,
                             client: SFTPClient?,
                             hostID: UUID?,
                             paneID: UUID? = nil) -> NSItemProvider {
        itemProvider(entries: [entry], grabbed: entry, client: client, hostID: hostID, paneID: paneID)
    }

    /// `entries` is everything the drag carries; `grabbed` is the row under the
    /// pointer. Finder can only materialise one file per SwiftUI drag item, so a
    /// Finder drop receives `grabbed`; in-app drops read the payload and queue
    /// every selected row.
    static func itemProvider(entries: [FileEntry],
                             grabbed: FileEntry,
                             client: SFTPClient?,
                             hostID: UUID?,
                             paneID: UUID?) -> NSItemProvider {
        dragTrace("drag started for " + String(entries.count) + " item(s), grabbed " + grabbed.path)
        let provider = NSItemProvider(object: grabbed.path as NSString)
        let payload = Payload(hostID: hostID?.uuidString,
                              path: grabbed.path,
                              paths: entries.count > 1 ? entries.map(\.path) : nil,
                              paneID: paneID?.uuidString)
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: payloadType.identifier,
                                                visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        guard grabbed.kind == .file, let client else { return provider }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task {
                do {
                    let url = try await materialize(client: client,
                                                    remotePath: grabbed.path,
                                                    fileName: grabbed.name)
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
            .appendingPathComponent("Tauge-Drag-" + UUID().uuidString, isDirectory: true)
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

/// Drag representation for local rows: the grabbed file as a real URL plus, for a
/// multi-row drag, the rest of the selection as a private payload the remote
/// panes read to upload everything in one gesture.
enum LocalFileDrag {
    static let payloadType = UTType(exportedAs: LocalDragPayload.typeIdentifier)

    static func itemProvider(entries: [FileEntry], grabbed: FileEntry) -> NSItemProvider {
        dragTrace("local drag started for " + String(entries.count) + " item(s), grabbed " + grabbed.path)
        let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: grabbed.path))
            ?? NSItemProvider(object: grabbed.path as NSString)
        guard entries.count > 1,
              let data = try? JSONEncoder().encode(LocalDragPayload(paths: entries.map(\.path))) else {
            return provider
        }
        provider.registerDataRepresentation(forTypeIdentifier: payloadType.identifier,
                                            visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
