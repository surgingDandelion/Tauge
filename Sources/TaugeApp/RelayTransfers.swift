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

struct RelayFile {
    var sourcePath: String
    var destinationPath: String
    var size: Int64
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
        Task { @MainActor in
            await self.performRelay(request, tab: tab, source: source, target: target)
        }
    }

    private func performRelay(_ request: RelayRequest,
                              tab: TerminalTab,
                              source: RemoteBrowserModel,
                              target: RemoteBrowserModel) async {
        guard !request.entries.isEmpty else { return }
        var sourceClient = source.client
        if sourceClient == nil {
            await openSFTP(tab: tab, pane: source)
            sourceClient = source.client
        }
        guard let sourceClient else {
            presentMessage(L("无法传输"),
                           source.connectionError ?? L("源服务器的 SFTP 会话尚未建立。"),
                           suggestion: L("在源面板上点“重试”，连上之后再拖一次。"))
            return
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
            return
        }

        guard let policy = await relayConflictPolicy(entries: request.entries,
                                                     directory: target.path,
                                                     client: targetClient) else { return }

        let progressID = UUID()
        var progress = TransferProgress(id: progressID,
                                        // The transfer task is shown at its destination.
                                        // This keeps the label aligned with the target
                                        // pane's title when several SFTP panes are open.
                                        hostID: target.hostID,
                                        direction: .download,
                                        sourcePath: source.hostName + ":" + source.path,
                                        destinationPath: target.hostName + ":" + target.path,
                                        state: .running,
                                        filesTotal: request.entries.count,
                                        currentFile: request.entries.first?.name,
                                        updatedAt: Date())
        relayRequests[progressID] = request
        updateTransfer(progress)

        let relay = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRelay(progressID: progressID,
                                source: source,
                                target: target,
                                sourceClient: sourceClient,
                                targetClient: targetClient,
                                policy: policy)
        }
        relayTasks[progressID] = relay
        await relay.value
    }

    private func relayConflictPolicy(entries: [FileEntry],
                                     directory: String,
                                     client: SFTPClient) async -> ConflictPolicy? {
        if let override = transferConflictPolicy { return override }
        if settings.conflictPolicy != "ask" {
            return Self.conflictPolicy(fromSetting: settings.conflictPolicy)
        }
        var hasConflict = false
        for entry in entries.prefix(20) {
            if (try? await client.stat(POSIXPath.join(directory, entry.name))) != nil {
                hasConflict = true
                break
            }
        }
        if !hasConflict { return .overwrite }
        return await askConflictPolicy(fileCount: entries.count)
    }

    private func runRelay(progressID: UUID,
                          source: RemoteBrowserModel,
                          target: RemoteBrowserModel,
                          sourceClient: SFTPClient,
                          targetClient: SFTPClient,
                          policy: ConflictPolicy) async {
        guard var progress = transfers.first(where: { $0.id == progressID }) else { return }
        var files: [RelayFile] = []
        do {
            files = try await collectRelayFiles(entries: relayRequests[progressID]?.entries ?? [],
                                                source: sourceClient,
                                                target: targetClient,
                                                destinationDirectory: target.path,
                                                policy: policy)
        } catch {
            finishRelay(progressID: progressID, state: .failed, error: error)
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
                try await relayFile(file,
                                    source: sourceClient,
                                    target: targetClient,
                                    onBytes: { chunk in
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
                })
                progress.bytesCompleted = completedBytes
                progress.filesCompleted += 1
                progress.bytesPerSecond = Double(completedBytes) / max(0.001, Date().timeIntervalSince(startedAt))
                progress.updatedAt = Date()
                updateTransfer(progress)
            } catch {
                // A cancelled relay is not a failure: the user asked for it.
                let cancelled = error is CancellationError || Task.isCancelled
                finishRelay(progressID: progressID,
                            state: cancelled ? .cancelled : .failed,
                            error: cancelled ? nil : error)
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
                           onBytes: (Int) -> Void) async throws {
        let readHandle = try await source.open(file.sourcePath, flags: [.read])
        var wroteAny = false
        do {
            let writeHandle = try await target.open(file.destinationPath, flags: .writeTruncateCreate)
            var offset: UInt64 = 0
            let chunk: UInt32 = 32768
            while true {
                if Task.isCancelled { throw CancellationError() }
                let data = try await source.read(handle: readHandle, offset: offset, length: chunk)
                if data.isEmpty { break }
                try await target.write(handle: writeHandle, offset: offset, data: data)
                wroteAny = true
                offset += UInt64(data.count)
                onBytes(data.count)
            }
            try await target.close(writeHandle)
        } catch {
            if wroteAny { try? await target.removeFile(file.destinationPath) }
            try? await source.close(readHandle)
            throw error
        }
        try await source.close(readHandle)
    }

    /// Drop of remote rows onto another remote pane: relays the whole drag, one
    /// request per source pane, awaited in turn so two relays never race for the
    /// single conflict continuation.
    func copyDroppedPaths(_ items: [(path: String, hostID: UUID?, paneID: UUID?)],
                          in tab: TerminalTab,
                          to target: RemoteBrowserModel) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            let resolution = await self.resolveDroppedItems(items, in: tab)
            for batch in resolution.batches {
                guard batch.pane.id != target.id else {
                    self.presentMessage(L("无法传输"),
                                        L("源和目标在同一个面板里。"),
                                        suggestion: L("拖到另一个远端面板，或直接拖到本地面板下载。"))
                    continue
                }
                await self.performRelay(RelayRequest(tabID: tab.id,
                                                     sourcePaneID: batch.pane.id,
                                                     targetPaneID: target.id,
                                                     entries: batch.entries),
                                        tab: tab,
                                        source: batch.pane,
                                        target: target)
            }
            self.reportDroppedFailures(resolution.failures, title: L("无法传输"))
        }
    }

    // MARK: - Planning

    private func collectRelayFiles(entries: [FileEntry],
                                   source: SFTPClient,
                                   target: SFTPClient,
                                   destinationDirectory: String,
                                   policy: ConflictPolicy) async throws -> [RelayFile] {
        var files: [RelayFile] = []
        for entry in entries {
            if let planned = try await planRelay(entry: entry,
                                                 source: source,
                                                 target: target,
                                                 destinationDirectory: destinationDirectory,
                                                 policy: policy,
                                                 name: entry.name) {
                files.append(contentsOf: planned)
            }
        }
        return files
    }

    /// Resolve one entry (recursively for directories) into the list of files to
    /// copy. Returns nil when the entry is skipped entirely.
    private func planRelay(entry: FileEntry,
                           source: SFTPClient,
                           target: SFTPClient,
                           destinationDirectory: String,
                           policy: ConflictPolicy,
                           name: String) async throws -> [RelayFile]? {
        var destinationName = name
        let candidate = POSIXPath.join(destinationDirectory, destinationName)
        let existing = try? await target.stat(candidate)

        if let existing, !(existing.isDirectory && entry.kind == .directory) {
            switch policy {
            case .overwrite:
                break
            case .skip:
                return nil
            case .rename:
                destinationName = await uniqueRemoteName(base: name, directory: destinationDirectory, client: target)
            case .onlyIfNewer:
                let sourceTime = entry.modified
                let destTime = existing.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                if let sourceTime, let destTime, sourceTime <= destTime { return nil }
            }
        } else if entry.kind == .directory, existing == nil {
            do {
                try await target.createDirectory(candidate)
            } catch {
                // Already there is fine; anything else is a real failure.
                if (try? await target.stat(candidate)) == nil { throw error }
            }
        }

        let destinationPath = POSIXPath.join(destinationDirectory, destinationName)
        if entry.kind == .directory {
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
                if let planned = try await planRelay(entry: childEntry,
                                                     source: source,
                                                     target: target,
                                                     destinationDirectory: destinationPath,
                                                     policy: policy,
                                                     name: child.filename) {
                    files.append(contentsOf: planned)
                }
            }
            return files
        }
        return [RelayFile(sourcePath: entry.path, destinationPath: destinationPath, size: entry.size)]
    }

    private func uniqueRemoteName(base: String, directory: String, client: SFTPClient) async -> String {
        var counter = 1
        var candidate = base
        let ext = (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        while (try? await client.stat(POSIXPath.join(directory, candidate))) != nil {
            candidate = ext.isEmpty ? stem + " (" + String(counter) + ")"
                : stem + " (" + String(counter) + ")." + ext
            counter += 1
            if counter > 999 { break }
        }
        return candidate
    }
}
