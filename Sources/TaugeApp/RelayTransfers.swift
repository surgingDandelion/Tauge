import Foundation
import TaugeKit

// MARK: - Remote to remote transfers

/// Copies files between two SFTP panes (two different servers, or two
/// directories on servers opened in different panes). The transfer engine only
/// speaks "one remote + the local disk", so a relay moves bytes through this
/// process: read from the source client, write to the destination client.
struct RelayRequest {
    var tabID: UUID
    var sourcePaneID: UUID
    var targetPaneID: UUID
    var entries: [FileEntry]
}

private struct RelayFile {
    var sourcePath: String
    var destinationPath: String
    var size: Int64
    var modified: Date?
}

extension AppState {
    /// True when dropping a remote item from `source` onto `target` means a
    /// server-to-server copy rather than a download.
    func isRemoteToRemote(from source: RemoteBrowserModel, to target: RemoteBrowserModel) -> Bool {
        source.id != target.id
    }

    func copyRemotely(entries: [FileEntry],
                      from source: RemoteBrowserModel,
                      to target: RemoteBrowserModel,
                      tab: TerminalTab) {
        traceTransfer("relay " + String(entries.count) + " item(s) "
                      + source.hostName + " -> " + target.hostName)
        let request = RelayRequest(tabID: tab.id,
                                   sourcePaneID: source.id,
                                   targetPaneID: target.id,
                                   entries: entries)
        let destination = target.path
        let resolveConflict = relayConflictResolver()
        Task { @MainActor in
            _ = await self.performRelay(request, tab: tab, source: source, target: target,
                                        destination: destination, resolveConflict: resolveConflict)
        }
    }

    private func performRelay(_ request: RelayRequest,
                              tab: TerminalTab,
                              source: RemoteBrowserModel,
                              target: RemoteBrowserModel,
                              destination: String,
                              resolveConflict: @escaping UploadConflictResolver) async -> TransferState? {
        guard !request.entries.isEmpty else { return nil }
        var sourceClient = source.client
        if sourceClient == nil {
            await openSFTP(tab: tab, pane: source)
            sourceClient = source.client
        }
        guard let sourceClient else {
            presentMessage(L("无法传输"),
                           source.connectionError ?? L("源服务器的 SFTP 会话尚未建立。"),
                           suggestion: L("在源面板上点“重试”，连上之后再拖一次。"))
            return nil
        }
        var targetClient = target.client
        if targetClient == nil {
            await openSFTP(tab: tab, pane: target)
            targetClient = target.client
        }
        guard let targetClient else {
            presentMessage(L("无法传输"),
                           target.connectionError ?? L("目标服务器的 SFTP 会话尚未建立。"),
                           suggestion: L("在目标面板上点“重试”，连上之后再拖一次。"))
            return nil
        }

        let progressID = UUID()
        let progress = TransferProgress(id: progressID,
                                        // The transfer task is shown at its destination.
                                        // This keeps the label aligned with the target
                                        // pane's title when several SFTP panes are open.
                                        hostID: target.hostID,
                                        direction: .download,
                                        sourcePath: source.hostName + ":" + source.path,
                                        destinationPath: target.hostName + ":" + destination,
                                        state: .running,
                                        filesTotal: request.entries.count,
                                        currentFile: request.entries.first?.name,
                                        updatedAt: Date())
        relayRequests[progressID] = request
        updateTransfer(progress)

        let sameHost = sourceClient === targetClient || (source.hostID != nil && source.hostID == target.hostID)
        let relay = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRelay(progressID: progressID,
                                destination: destination,
                                sourceClient: sourceClient,
                                targetClient: targetClient,
                                sameHost: sameHost,
                                resolveConflict: resolveConflict)
        }
        relayTasks[progressID] = relay
        await relay.value
        return transfers.first(where: { $0.id == progressID })?.state
    }

    private func relayConflictResolver() -> UploadConflictResolver {
        if let policy = configuredTransferConflictPolicy {
            return { _ in policy }
        }
        return makeTransferConflictResolver()
    }

    private func runRelay(progressID: UUID,
                          destination: String,
                          sourceClient: SFTPClient,
                          targetClient: SFTPClient,
                          sameHost: Bool,
                          resolveConflict: UploadConflictResolver) async {
        guard var progress = transfers.first(where: { $0.id == progressID }) else { return }
        var files: [RelayFile] = []
        do {
            files = try await collectRelayFiles(entries: relayRequests[progressID]?.entries ?? [],
                                                source: sourceClient,
                                                target: targetClient,
                                                destinationDirectory: destination,
                                                resolveConflict: resolveConflict)
        } catch {
            finishRelay(progressID: progressID, after: error)
            return
        }

        progress.bytesTotal = files.reduce(Int64(0)) { $0 + $1.size }
        progress.filesTotal = files.count
        updateTransfer(progress)

        var completedBytes: Int64 = 0
        var lastReport = Date.distantPast
        let startedAt = Date()

        for file in files {
            if Task.isCancelled {
                finishRelay(progressID: progressID, state: .cancelled, error: nil)
                return
            }
            progress.currentFile = (file.sourcePath as NSString).lastPathComponent
            do {
                let copied = try await relayFile(file,
                                                 source: sourceClient,
                                                 target: targetClient,
                                                 sameHost: sameHost,
                                                 resolveConflict: resolveConflict) { chunk in
                    completedBytes += Int64(chunk)
                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.12 {
                        lastReport = now
                        progress.bytesCompleted = completedBytes
                        let elapsed = max(0.001, now.timeIntervalSince(startedAt))
                        progress.bytesPerSecond = Double(completedBytes) / elapsed
                        progress.updatedAt = now
                        self.updateTransfer(progress)
                    }
                }
                if !copied {
                    progress.skippedFiles += 1
                    progress.bytesTotal -= file.size
                }
                progress.bytesCompleted = completedBytes
                progress.filesCompleted += 1
                progress.bytesPerSecond = Double(completedBytes) / max(0.001, Date().timeIntervalSince(startedAt))
                progress.updatedAt = Date()
                updateTransfer(progress)
            } catch {
                finishRelay(progressID: progressID, after: error)
                return
            }
        }

        progress.state = .completed
        progress.bytesCompleted = progress.bytesTotal
        progress.filesCompleted = progress.filesTotal
        progress.updatedAt = Date()
        updateTransfer(progress)
        finishRelay(progressID: progressID, state: .completed, error: nil)
        traceTransfer("relay completed " + String(files.count) + " file(s)")
    }

    private func finishRelay(progressID: UUID, after error: Error) {
        let cancelled = error is CancellationError || Task.isCancelled
        finishRelay(progressID: progressID, state: cancelled ? .cancelled : .failed,
                    error: cancelled ? nil : error)
    }

    private func finishRelay(progressID: UUID, state: TransferState, error: Error?) {
        if var progress = transfers.first(where: { $0.id == progressID }) {
            progress.state = state
            progress.errorMessage = error.map { describe($0) }
            progress.updatedAt = Date()
            updateTransfer(progress)
        }
        relayTasks[progressID] = nil
    }

    private func relayFile(_ file: RelayFile,
                           source: SFTPClient,
                           target: SFTPClient,
                           sameHost: Bool,
                           resolveConflict: UploadConflictResolver,
                           onBytes: (Int) -> Void) async throws -> Bool {
        let readHandle = try await source.open(file.sourcePath, flags: [.read])
        do {
            guard let output = try await openRelayDestination(file, target: target,
                                                              sameHost: sameHost, resolveConflict: resolveConflict) else {
                try await source.close(readHandle)
                return false
            }
            var offset: UInt64 = 0
            do {
                let chunk: UInt32 = 32768
                while true {
                    try Task.checkCancellation()
                    let data = try await source.read(handle: readHandle, offset: offset, length: chunk)
                    if data.isEmpty { break }
                    try await target.write(handle: output.handle, offset: offset, data: data)
                    offset += UInt64(data.count)
                    onBytes(data.count)
                }
                try await target.close(output.handle)
            } catch {
                try? await target.close(output.handle)
                if offset > 0 { try? await target.removeFile(output.path) }
                throw error
            }
        } catch {
            try? await source.close(readHandle)
            throw error
        }
        try await source.close(readHandle)
        return true
    }

    private func openRelayDestination(_ file: RelayFile,
                                      target: SFTPClient,
                                      sameHost: Bool,
                                      resolveConflict: UploadConflictResolver) async throws -> (path: String, handle: Data)? {
        let destination = file.destinationPath
        while true {
            try Task.checkCancellation()
            if let existing = try await relayDestinationAttributes(destination, client: target) {
                switch try await resolveConflict(destination) {
                case .skip:
                    return nil
                case .rename:
                    return try await openRenamedRelayFile(destination, target: target)
                case .onlyIfNewer:
                    if relayDestinationIsCurrent(existing, sourceModified: file.modified) { return nil }
                case .overwrite:
                    break
                }
                // Two panes on the same host can show the same file. Opening
                // its destination with truncation would also empty the source.
                if sameHost && POSIXPath.normalize(file.sourcePath) == POSIXPath.normalize(destination) { return nil }
                try Task.checkCancellation()
                let handle = try await target.open(destination, flags: .writeTruncateCreate)
                return (destination, handle)
            }
            if let output = try await createRelayFile(destination, target: target) { return output }
        }
    }

    /// Exclusive creation keeps a file that appears after the lookup intact.
    /// SFTP v3 can report that collision with its generic failure status.
    private func createRelayFile(_ path: String,
                                 target: SFTPClient) async throws -> (path: String, handle: Data)? {
        try Task.checkCancellation()
        do {
            let handle = try await target.open(path, flags: [.write, .create, .exclusive])
            return (path, handle)
        } catch let error as SFTPError {
            guard try await relayDestinationAttributes(path, client: target) != nil else { throw error }
            return nil
        }
    }

    /// Drop of remote rows onto another remote pane: one relay per source pane
    /// with one set of conflict choices for the whole drag.
    func copyDroppedPaths(_ items: [(path: String, hostID: UUID?, paneID: UUID?)],
                          in tab: TerminalTab,
                          to target: RemoteBrowserModel) {
        guard !items.isEmpty else { return }
        let destination = target.path
        let resolveConflict = relayConflictResolver()
        Task { @MainActor in
            let resolution = await self.resolveDroppedItems(items, in: tab)
            for batch in resolution.batches {
                guard batch.pane.id != target.id else {
                    self.presentMessage(L("无法传输"),
                                        L("源和目标在同一个面板里。"),
                                        suggestion: L("拖到另一个远端面板，或直接拖到本地面板下载。"))
                    continue
                }
                let state = await self.performRelay(RelayRequest(tabID: tab.id,
                                                                 sourcePaneID: batch.pane.id,
                                                                 targetPaneID: target.id,
                                                                 entries: batch.entries),
                                                    tab: tab,
                                                    source: batch.pane,
                                                    target: target,
                                                    destination: destination,
                                                    resolveConflict: resolveConflict)
                if state == .cancelled { return }
            }
            self.reportDroppedFailures(resolution.failures, title: L("无法传输"))
        }
    }

    // MARK: - Planning

    private func collectRelayFiles(entries: [FileEntry],
                                   source: SFTPClient,
                                   target: SFTPClient,
                                   destinationDirectory: String,
                                   resolveConflict: UploadConflictResolver) async throws -> [RelayFile] {
        var files: [RelayFile] = []
        for entry in entries {
            files.append(contentsOf: try await planRelay(entry: entry,
                                                         source: source,
                                                         target: target,
                                                         destinationDirectory: destinationDirectory,
                                                         resolveConflict: resolveConflict))
        }
        return files
    }

    private func planRelay(entry: FileEntry,
                           source: SFTPClient,
                           target: SFTPClient,
                           destinationDirectory: String,
                           resolveConflict: UploadConflictResolver) async throws -> [RelayFile] {
        try Task.checkCancellation()
        let destination = POSIXPath.join(destinationDirectory, entry.name)
        guard entry.kind == .directory else {
            return [RelayFile(sourcePath: entry.path, destinationPath: destination,
                              size: entry.size, modified: entry.modified)]
        }
        guard let path = try await prepareRelayDirectory(destination, sourceModified: entry.modified,
                                                         target: target, resolveConflict: resolveConflict) else { return [] }
        let children = try await source.listDirectory(entry.path)
        var files: [RelayFile] = []
        for child in children where child.filename != "." && child.filename != ".." {
            let attributes = child.attributes
            let kind: FileEntry.Kind = attributes.isDirectory ? .directory
                : (attributes.isSymlink ? .symlink : .file)
            let childEntry = FileEntry(path: POSIXPath.join(entry.path, child.filename),
                                       name: child.filename,
                                       kind: kind,
                                       size: Int64(attributes.size ?? 0),
                                       modified: attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            files.append(contentsOf: try await planRelay(entry: childEntry,
                                                         source: source,
                                                         target: target,
                                                         destinationDirectory: path,
                                                         resolveConflict: resolveConflict))
        }
        return files
    }

    private func prepareRelayDirectory(_ path: String, sourceModified: Date?,
                                       target: SFTPClient, resolveConflict: UploadConflictResolver) async throws -> String? {
        while true {
            try Task.checkCancellation()
            if let existing = try await relayDestinationAttributes(path, client: target) {
                if existing.isDirectory { return path }
                switch try await resolveConflict(path) {
                case .skip:
                    return nil
                case .rename:
                    for index in 1...999 {
                        let candidate = renamedRelayPath(path, index: index)
                        if try await createRelayDirectory(candidate, target: target) { return candidate }
                    }
                    throw TransferError.failed("No available name for " + path)
                case .onlyIfNewer:
                    if relayDestinationIsCurrent(existing, sourceModified: sourceModified) { return nil }
                case .overwrite:
                    break
                }
                throw TransferError.failed("Destination is not a directory: " + path)
            }
            if try await createRelayDirectory(path, target: target) { return path }
        }
    }

    private func createRelayDirectory(_ path: String, target: SFTPClient) async throws -> Bool {
        try Task.checkCancellation()
        do {
            try await target.createDirectory(path)
            return true
        } catch let error as SFTPError {
            guard try await relayDestinationAttributes(path, client: target) != nil else { throw error }
            return false
        }
    }

    private func openRenamedRelayFile(_ path: String, target: SFTPClient) async throws -> (path: String, handle: Data) {
        for index in 1...999 {
            if let output = try await createRelayFile(renamedRelayPath(path, index: index), target: target) {
                return output
            }
        }
        throw TransferError.failed("No available name for " + path)
    }

    private func renamedRelayPath(_ path: String, index: Int) -> String {
        let filename = (path as NSString).lastPathComponent as NSString
        let ext = filename.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        return POSIXPath.join(POSIXPath.parent(path), filename.deletingPathExtension + " (\(index))" + suffix)
    }

    private func relayDestinationAttributes(_ path: String, client: SFTPClient) async throws -> SFTPFileAttributes? {
        do {
            return try await client.stat(path, followSymlink: false)
        } catch let error as SFTPError where error.isNoSuchFile {
            return nil
        }
    }

    private func relayDestinationIsCurrent(_ attributes: SFTPFileAttributes, sourceModified: Date?) -> Bool {
        guard let sourceModified, let modified = attributes.modifyTime else { return false }
        return Date(timeIntervalSince1970: TimeInterval(modified)) >= sourceModified
    }
}
