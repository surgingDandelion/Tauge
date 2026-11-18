import Foundation

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    case overwrite
    case skip
    case rename
    case onlyIfNewer

    public var displayName: String {
        switch self {
        case .overwrite: return L("覆盖")
        case .skip: return L("跳过")
        case .rename: return L("重命名")
        case .onlyIfNewer: return L("仅较新")
        }
    }
}

public enum TransferError: Error, LocalizedError, Equatable {
    case sourceMissing(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): return "Source missing: " + path
        case .cancelled: return "Transfer cancelled"
        case .failed(let message): return message
        }
    }
}

public struct TransferItem: Identifiable, Sendable {
    public let id: UUID
    public var hostID: UUID?
    public var direction: TransferDirection
    public var sourcePath: String
    public var destinationPath: String
    public var recursive: Bool
    public var conflictPolicy: ConflictPolicy

    public init(id: UUID = UUID(),
                hostID: UUID? = nil,
                direction: TransferDirection,
                sourcePath: String,
                destinationPath: String,
                recursive: Bool = false,
                conflictPolicy: ConflictPolicy = .overwrite) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.recursive = recursive
        self.conflictPolicy = conflictPolicy
    }

    public var displayName: String {
        (sourcePath as NSString).lastPathComponent
    }
}

public struct TransferProgress: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var hostID: UUID?
    public var direction: TransferDirection
    public var sourcePath: String
    public var destinationPath: String
    public var state: TransferState
    public var bytesCompleted: Int64
    public var bytesTotal: Int64
    public var filesCompleted: Int
    public var filesTotal: Int
    public var currentFile: String?
    public var bytesPerSecond: Double
    public var errorMessage: String?
    public var attempt: Int
    public var skippedFiles: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                hostID: UUID? = nil,
                direction: TransferDirection,
                sourcePath: String,
                destinationPath: String,
                state: TransferState = .queued,
                bytesCompleted: Int64 = 0,
                bytesTotal: Int64 = 0,
                filesCompleted: Int = 0,
                filesTotal: Int = 0,
                currentFile: String? = nil,
                bytesPerSecond: Double = 0,
                errorMessage: String? = nil,
                attempt: Int = 0,
                skippedFiles: Int = 0,
                updatedAt: Date = Date()) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.state = state
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.currentFile = currentFile
        self.bytesPerSecond = bytesPerSecond
        self.errorMessage = errorMessage
        self.attempt = attempt
        self.skippedFiles = skippedFiles
        self.updatedAt = updatedAt
    }

    public var fraction: Double {
        guard bytesTotal > 0 else { return state == .completed ? 1 : 0 }
        return min(1, max(0, Double(bytesCompleted) / Double(bytesTotal)))
    }

    public var remainingTime: TimeInterval? {
        guard bytesPerSecond > 1, bytesTotal > bytesCompleted else { return nil }
        return TimeInterval(bytesTotal - bytesCompleted) / bytesPerSecond
    }

    public var displayName: String {
        (sourcePath as NSString).lastPathComponent
    }
}

/// Queues uploads and downloads with bounded concurrency, resume-by-offset,
/// conflict policies and automatic retries. One engine can serve several hosts;
/// each item carries the SFTP client it belongs to.
public actor TransferEngine {
    public struct Configuration: Sendable {
        public var maxConcurrent: Int
        public var maxRetries: Int
        public var downloadWindow: Int
        public var uploadWindow: Int
        public var chunkSize: UInt32

        public init(maxConcurrent: Int = 2,
                    maxRetries: Int = 3,
                    downloadWindow: Int = 8,
                    uploadWindow: Int = 8,
                    chunkSize: UInt32 = UInt32(SFTPConstant.minimumChunkSize)) {
            self.maxConcurrent = min(4, max(1, maxConcurrent))
            self.maxRetries = max(0, maxRetries)
            self.downloadWindow = min(16, max(1, downloadWindow))
            self.uploadWindow = min(16, max(1, uploadWindow))
            self.chunkSize = max(chunkSize, UInt32(SFTPConstant.minimumChunkSize))
        }
    }

    private struct Managed {
        var item: TransferItem
        /// Keep the destination session with the queued item. Passing the most
        /// recently enqueued client to the scheduler makes a queued transfer
        /// jump to another SFTP pane when several panes share one engine.
        var remote: SFTPClient
        var progress: TransferProgress
        var task: Task<Void, Never>?
        var pauseRequested = false
        var cancelRequested = false
        var retryCount = 0
    }

    private struct PlannedFile {
        var relativePath: String
        var size: Int64
        var modified: Date?
    }

    private struct TransferPlan {
        var isDirectory: Bool
        var files: [PlannedFile]
        var totalBytes: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }
    }

    private enum ConflictDecision {
        case proceed(path: String)
        case skip
    }

    private let configuration: Configuration
    private var overrideConfiguration: Configuration?
    private let local = LocalFileService()
    private var items: [UUID: Managed] = [:]
    private var order: [UUID] = []
    private var listeners: [UUID: AsyncStream<TransferProgress>.Continuation] = [:]
    private var conflictOverrides: [UUID: ConflictPolicy] = [:]
    private var globalConflictOverride: ConflictPolicy?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private var activeConfiguration: Configuration { overrideConfiguration ?? configuration }

    public func updateConfiguration(_ configuration: Configuration) {
        overrideConfiguration = configuration
    }

    public func setGlobalConflictOverride(_ policy: ConflictPolicy?) {
        globalConflictOverride = policy
    }

    public func setConflictOverride(_ policy: ConflictPolicy?, for id: UUID) {
        conflictOverrides[id] = policy
    }

    // MARK: - Public API

    @discardableResult
    public func enqueue(_ item: TransferItem, remote: SFTPClient) -> UUID {
        let progress = TransferProgress(id: item.id,
                                        hostID: item.hostID,
                                        direction: item.direction,
                                        sourcePath: item.sourcePath,
                                        destinationPath: item.destinationPath,
                                        state: .queued,
                                        bytesCompleted: 0,
                                        bytesTotal: 0,
                                        filesCompleted: 0,
                                        filesTotal: 0,
                                        currentFile: nil,
                                        bytesPerSecond: 0,
                                        errorMessage: nil,
                                        attempt: 0,
                                        skippedFiles: 0,
                                        updatedAt: Date())
        items[item.id] = Managed(item: item, remote: remote, progress: progress)
        order.append(item.id)
        emit(item.id)
        pump()
        return item.id
    }

    public func cancel(_ id: UUID) {
        guard var managed = items[id] else { return }
        managed.cancelRequested = true
        managed.task?.cancel()
        managed.task = nil
        managed.progress.state = .cancelled
        managed.progress.bytesPerSecond = 0
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
        pump()
    }

    public func pause(_ id: UUID) {
        guard var managed = items[id], !managed.progress.state.isTerminal else { return }
        if managed.progress.state == .queued {
            managed.progress.state = .paused
            managed.progress.updatedAt = Date()
            items[id] = managed
            emit(id)
            return
        }
        managed.pauseRequested = true
        managed.task?.cancel()
        managed.task = nil
        managed.progress.state = .paused
        managed.progress.bytesPerSecond = 0
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
        pump()
    }

    public func resume(_ id: UUID, remote: SFTPClient) {
        guard var managed = items[id] else { return }
        managed.pauseRequested = false
        managed.cancelRequested = false
        if managed.progress.state == .paused || managed.progress.state == .failed {
            managed.remote = remote
            managed.progress.state = .queued
            managed.progress.errorMessage = nil
            managed.progress.updatedAt = Date()
            items[id] = managed
            emit(id)
            pump()
        }
    }

    public func retry(_ id: UUID, remote: SFTPClient) {
        guard var managed = items[id] else { return }
        guard managed.progress.state == .failed || managed.progress.state == .cancelled else { return }
        managed.retryCount = 0
        managed.pauseRequested = false
        managed.cancelRequested = false
        managed.remote = remote
        managed.progress.state = .queued
        managed.progress.errorMessage = nil
        managed.progress.bytesPerSecond = 0
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
        pump()
    }

    public func retryAllFailed(remote: SFTPClient) {
        for id in order where items[id]?.progress.state == .failed {
            retry(id, remote: remote)
        }
    }

    public func cancelAll() {
        for id in order where !(items[id]?.progress.state.isTerminal ?? true) {
            cancel(id)
        }
    }

    public func remove(_ id: UUID) {
        guard let managed = items[id], managed.progress.state.isTerminal else { return }
        items.removeValue(forKey: id)
        order.removeAll { $0 == id }
        conflictOverrides.removeValue(forKey: id)
    }

    public func clearFinished() {
        for id in order where items[id]?.progress.state.isTerminal ?? false {
            items.removeValue(forKey: id)
            conflictOverrides.removeValue(forKey: id)
        }
        order.removeAll { items[$0] == nil }
    }

    public func progress(for id: UUID) -> TransferProgress? {
        items[id]?.progress
    }

    public func allProgress() -> [TransferProgress] {
        order.compactMap { items[$0]?.progress }
    }

    public func activeCount() -> Int {
        items.values.filter { $0.progress.state == .running }.count
    }

    public func progressStream() -> AsyncStream<TransferProgress> {
        AsyncStream { continuation in
            let key = UUID()
            listeners[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(key) }
            }
        }
    }

    private func removeListener(_ key: UUID) {
        listeners.removeValue(forKey: key)
    }

    private func emit(_ id: UUID) {
        guard let progress = items[id]?.progress else { return }
        for continuation in listeners.values {
            continuation.yield(progress)
        }
    }

    // MARK: - Scheduling

    private func pump() {
        for id in order {
            guard let managed = items[id], managed.progress.state == .queued, managed.task == nil else { continue }
            guard items.values.filter({ $0.progress.state == .running }).count < activeConfiguration.maxConcurrent else { break }
            start(id)
        }
    }

    private func start(_ id: UUID) {
        guard var managed = items[id] else { return }
        managed.progress.state = .running
        managed.progress.updatedAt = Date()
        managed.pauseRequested = false
        managed.cancelRequested = false
        let item = managed.item
        let remote = managed.remote
        items[id] = managed
        emit(id)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(item: item, remote: remote)
        }
        managed.task = task
        items[id] = managed
    }

    private func run(item: TransferItem, remote: SFTPClient) async {
        do {
            switch item.direction {
            case .download:
                try await runDownload(item: item, remote: remote)
            case .upload:
                try await runUpload(item: item, remote: remote)
            }
            finishSuccess(item.id)
        } catch is CancellationError {
            handleInterruption(item.id)
        } catch {
            await handleFailure(item.id, error: error, remote: remote)
        }
    }

    private func finishSuccess(_ id: UUID) {
        guard var managed = items[id] else { return }
        managed.task = nil
        managed.progress.state = .completed
        managed.progress.bytesPerSecond = 0
        managed.progress.currentFile = nil
        managed.progress.updatedAt = Date()
        if managed.progress.bytesTotal < managed.progress.bytesCompleted {
            managed.progress.bytesTotal = managed.progress.bytesCompleted
        }
        items[id] = managed
        emit(id)
        pump()
    }

    private func handleInterruption(_ id: UUID) {
        guard var managed = items[id] else { return }
        managed.task = nil
        if managed.cancelRequested {
            managed.progress.state = .cancelled
        } else if managed.pauseRequested {
            managed.progress.state = .paused
        } else {
            managed.progress.state = .cancelled
        }
        managed.progress.bytesPerSecond = 0
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
        pump()
    }

    private func handleFailure(_ id: UUID, error: Error, remote: SFTPClient) async {
        guard var managed = items[id] else { return }
        managed.task = nil
        if managed.pauseRequested || managed.cancelRequested {
            handleInterruption(id)
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if managed.retryCount < activeConfiguration.maxRetries {
            managed.retryCount += 1
            managed.progress.attempt = managed.retryCount
            managed.progress.state = .queued
            managed.progress.bytesPerSecond = 0
            managed.progress.errorMessage = message
            managed.progress.updatedAt = Date()
            items[id] = managed
            emit(id)
            let delay = UInt64(1 << (managed.retryCount - 1)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            pump()
            return
        }
        managed.progress.state = .failed
        managed.progress.bytesPerSecond = 0
        managed.progress.errorMessage = message
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
    }

    private func mutate(_ id: UUID, _ body: (inout TransferProgress) -> Void) {
        guard var managed = items[id] else { return }
        body(&managed.progress)
        managed.progress.updatedAt = Date()
        items[id] = managed
        emit(id)
    }

    private func checkCancellation(_ id: UUID) throws {
        if Task.isCancelled { throw CancellationError() }
        if let managed = items[id], managed.pauseRequested || managed.cancelRequested {
            throw CancellationError()
        }
    }

    private func effectivePolicy(for item: TransferItem) -> ConflictPolicy {
        conflictOverrides[item.id] ?? globalConflictOverride ?? item.conflictPolicy
    }

    // MARK: - Plans

    private func downloadPlan(item: TransferItem, remote: SFTPClient) async throws -> TransferPlan {
        let attrs = try await remote.stat(item.sourcePath)
        if !attrs.isDirectory {
            let name = (item.sourcePath as NSString).lastPathComponent
            return TransferPlan(isDirectory: false,
                                files: [PlannedFile(relativePath: name,
                                                    size: Int64(attrs.size ?? 0),
                                                    modified: attrs.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })])
        }
        guard item.recursive else {
            throw TransferError.failed("Source is a directory; enable recursive transfer")
        }
        var files: [PlannedFile] = []
        var visited: Set<String> = []
        var stack: [(path: String, prefix: String)] = [(item.sourcePath, "")]
        while let current = stack.popLast() {
            if visited.contains(current.path) { continue }
            visited.insert(current.path)
            let entries = try await remote.listDirectory(current.path)
            for entry in entries where entry.filename != "." && entry.filename != ".." {
                let childPath = POSIXPath.join(current.path, entry.filename)
                let relative = current.prefix.isEmpty ? entry.filename : current.prefix + "/" + entry.filename
                if entry.attributes.isDirectory {
                    stack.append((childPath, relative))
                } else if entry.attributes.isSymlink {
                    continue
                } else {
                    files.append(PlannedFile(relativePath: relative,
                                             size: Int64(entry.attributes.size ?? 0),
                                             modified: entry.attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                }
            }
        }
        files.sort { $0.relativePath < $1.relativePath }
        return TransferPlan(isDirectory: true, files: files)
    }

    private func uploadPlan(item: TransferItem) throws -> TransferPlan {
        guard local.exists(item.sourcePath) else { throw TransferError.sourceMissing(item.sourcePath) }
        if local.isDirectory(item.sourcePath) {
            guard item.recursive else {
                throw TransferError.failed("Source is a directory; enable recursive transfer")
            }
            let files = try local.enumerateFiles(root: item.sourcePath)
            let planned = files.map { file in
                PlannedFile(relativePath: file.relativePath,
                            size: file.size,
                            modified: local.attributes(of: file.absolutePath)?.modified)
            }
            return TransferPlan(isDirectory: true, files: planned)
        }
        let attrs = local.attributes(of: item.sourcePath)
        let name = (item.sourcePath as NSString).lastPathComponent
        return TransferPlan(isDirectory: false,
                            files: [PlannedFile(relativePath: name,
                                                size: attrs?.size ?? 0,
                                                modified: attrs?.modified)])
    }

    // MARK: - Download

    private func runDownload(item: TransferItem, remote: SFTPClient) async throws {
        let plan = try await downloadPlan(item: item, remote: remote)
        mutate(item.id) { progress in
            progress.bytesTotal = plan.totalBytes
            progress.filesTotal = plan.files.count
            progress.filesCompleted = 0
            progress.skippedFiles = 0
        }

        for (index, file) in plan.files.enumerated() {
            try checkCancellation(item.id)
            let remotePath = plan.isDirectory ? POSIXPath.join(item.sourcePath, file.relativePath) : item.sourcePath
            let localPath = plan.isDirectory ? POSIXPath.join(item.destinationPath, file.relativePath) : item.destinationPath
            if plan.isDirectory {
                try local.createDirectory(at: POSIXPath.parent(localPath))
            }
            mutate(item.id) { $0.currentFile = file.relativePath }

            let decision = await resolveLocalConflict(path: localPath,
                                                      sourceSize: file.size,
                                                      sourceModified: file.modified,
                                                      policy: effectivePolicy(for: item))
            switch decision {
            case .skip:
                mutate(item.id) { progress in
                    progress.filesCompleted = index + 1
                    progress.skippedFiles += 1
                }
                continue
            case .proceed(let finalPath):
                try await downloadFile(itemID: item.id,
                                       remote: remote,
                                       remotePath: remotePath,
                                       localPath: finalPath,
                                       expectedSize: file.size,
                                       modified: file.modified)
            }
            mutate(item.id) { $0.filesCompleted = index + 1 }
        }
    }

    private func resolveLocalConflict(path: String,
                                      sourceSize: Int64,
                                      sourceModified: Date?,
                                      policy: ConflictPolicy) async -> ConflictDecision {
        guard local.exists(path) else { return .proceed(path: path) }
        switch policy {
        case .overwrite:
            return .proceed(path: path)
        case .skip:
            return .skip
        case .onlyIfNewer:
            if let destinationDate = local.attributes(of: path)?.modified,
               let sourceDate = sourceModified,
               destinationDate >= sourceDate {
                return .skip
            }
            return .proceed(path: path)
        case .rename:
            let unique = uniqueLocalPath(for: path)
            return .proceed(path: unique)
        }
    }

    private func uniqueLocalPath(for path: String) -> String {
        if !local.exists(path) { return path }
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let baseName = nsPath.deletingPathExtension as NSString
        var index = 1
        while true {
            let name = ext.isEmpty
                ? baseName.lastPathComponent + " (" + String(index) + ")"
                : baseName.lastPathComponent + " (" + String(index) + ")." + ext
            let candidate = POSIXPath.join(directory, name)
            if !local.exists(candidate) { return candidate }
            index += 1
        }
    }

    private func downloadFile(itemID: UUID,
                              remote: SFTPClient,
                              remotePath: String,
                              localPath: String,
                              expectedSize: Int64,
                              modified: Date?) async throws {
        let handle: Data
        do {
            handle = try await remote.open(remotePath, flags: [.read])
        } catch let error as SFTPError {
            throw TransferError.failed(error.localizedDescription)
        }

        do {
            var offset: Int64 = 0
            if local.exists(localPath), let attributes = local.attributes(of: localPath) {
                if attributes.size < expectedSize { offset = attributes.size }
            }
            if offset == 0 {
                try local.createDirectory(at: POSIXPath.parent(localPath))
                try local.writeData(Data(), to: localPath, atomically: false)
            }
            guard let fileHandle = FileHandle(forWritingAtPath: localPath) else {
                throw TransferError.failed("Unable to open " + localPath)
            }
            defer { try? fileHandle.close() }
            try fileHandle.seek(toOffset: UInt64(offset))

            var nextReadOffset = offset
            var writeOffset = offset
            var pending: [(offset: Int64, task: Task<Data, Error>)] = []
            let window = activeConfiguration.downloadWindow
            let chunkSize = Int64(activeConfiguration.chunkSize)
            let started = Date()
            var windowBytes: Int64 = offset

            while true {
                try checkCancellation(itemID)
                while pending.count < window, nextReadOffset < expectedSize {
                    let readOffset = nextReadOffset
                    let length = UInt32(min(chunkSize, expectedSize - readOffset))
                    let task = Task<Data, Error> {
                        try await remote.read(handle: handle, offset: UInt64(readOffset), length: length)
                    }
                    pending.append((readOffset, task))
                    nextReadOffset += Int64(length)
                }
                if pending.isEmpty { break }
                let (_, task) = pending.removeFirst()
                let data = try await task.value
                if data.isEmpty { break }
                try fileHandle.seek(toOffset: UInt64(writeOffset))
                try fileHandle.write(contentsOf: data)
                writeOffset += Int64(data.count)

                let elapsed = Date().timeIntervalSince(started)
                let speed = elapsed > 0.3 ? Double(writeOffset - offset) / elapsed : 0
                _ = windowBytes
                mutate(itemID) { progress in
                    progress.bytesCompleted += Int64(data.count)
                    progress.bytesPerSecond = speed
                }
            }
            try fileHandle.synchronize()
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: localPath)
            }
        } catch {
            try? await remote.close(handle)
            throw error
        }
        try? await remote.close(handle)
    }

    // MARK: - Upload

    private func runUpload(item: TransferItem, remote: SFTPClient) async throws {
        let plan = try uploadPlan(item: item)
        mutate(item.id) { progress in
            progress.bytesTotal = plan.totalBytes
            progress.filesTotal = plan.files.count
            progress.filesCompleted = 0
            progress.skippedFiles = 0
        }

        var ensured: Set<String> = []
        for (index, file) in plan.files.enumerated() {
            try checkCancellation(item.id)
            let localPath = plan.isDirectory ? POSIXPath.join(item.sourcePath, file.relativePath) : item.sourcePath
            let remotePath = plan.isDirectory ? POSIXPath.join(item.destinationPath, file.relativePath) : item.destinationPath
            if plan.isDirectory {
                try await ensureRemoteDirectory(remote: remote,
                                                path: POSIXPath.parent(remotePath),
                                                ensured: &ensured)
            }
            mutate(item.id) { $0.currentFile = file.relativePath }

            let decision = await resolveRemoteConflict(remote: remote,
                                                       path: remotePath,
                                                       sourceSize: file.size,
                                                       sourceModified: file.modified,
                                                       policy: effectivePolicy(for: item))
            switch decision {
            case .skip:
                mutate(item.id) { progress in
                    progress.filesCompleted = index + 1
                    progress.skippedFiles += 1
                }
                continue
            case .proceed(let finalPath):
                try await uploadFile(itemID: item.id,
                                     remote: remote,
                                     localPath: localPath,
                                     remotePath: finalPath,
                                     size: file.size,
                                     modified: file.modified)
            }
            mutate(item.id) { $0.filesCompleted = index + 1 }
        }
    }

    private func ensureRemoteDirectory(remote: SFTPClient, path: String, ensured: inout Set<String>) async throws {
        let normalized = POSIXPath.normalize(path)
        if normalized == "/" || normalized.isEmpty || ensured.contains(normalized) { return }
        if let existing = try? await remote.stat(normalized), existing.isDirectory {
            ensured.insert(normalized)
            return
        }
        try await ensureRemoteDirectory(remote: remote, path: POSIXPath.parent(normalized), ensured: &ensured)
        do {
            try await remote.createDirectory(normalized)
        } catch let error as SFTPError {
            if case .status(let status) = error, status.code == .failure {
                // Directory may have been created by a concurrent transfer.
                if let existing = try? await remote.stat(normalized), existing.isDirectory {
                    ensured.insert(normalized)
                    return
                }
            }
            throw TransferError.failed(error.localizedDescription)
        }
        ensured.insert(normalized)
    }

    private func resolveRemoteConflict(remote: SFTPClient,
                                       path: String,
                                       sourceSize: Int64,
                                       sourceModified: Date?,
                                       policy: ConflictPolicy) async -> ConflictDecision {
        guard let existing = try? await remote.stat(path) else { return .proceed(path: path) }
        switch policy {
        case .overwrite:
            return .proceed(path: path)
        case .skip:
            return .skip
        case .onlyIfNewer:
            if let remoteDate = existing.modifyTime.map({ Date(timeIntervalSince1970: TimeInterval($0)) }),
               let sourceDate = sourceModified,
               remoteDate >= sourceDate {
                return .skip
            }
            return .proceed(path: path)
        case .rename:
            var candidate = path
            var index = 1
            let nsPath = path as NSString
            let directory = nsPath.deletingLastPathComponent
            let ext = nsPath.pathExtension
            let baseName = nsPath.deletingPathExtension as NSString
            while true {
                if (try? await remote.stat(candidate)) == nil { break }
                let name = ext.isEmpty
                    ? baseName.lastPathComponent + " (" + String(index) + ")"
                    : baseName.lastPathComponent + " (" + String(index) + ")." + ext
                candidate = POSIXPath.join(directory, name)
                index += 1
            }
            return .proceed(path: candidate)
        }
    }

    private func uploadFile(itemID: UUID,
                            remote: SFTPClient,
                            localPath: String,
                            remotePath: String,
                            size: Int64,
                            modified: Date?) async throws {
        let data: Data
        do {
            data = try local.readData(at: localPath)
        } catch {
            throw TransferError.failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }

        var offset: Int64 = 0
        if let existing = try? await remote.stat(remotePath), existing.isRegularFile {
            if let remoteSize = existing.size.map({ Int64($0) }), remoteSize < size {
                offset = remoteSize
            }
        }

        let flags: SFTPOpenFlags = offset > 0 ? [.write] : SFTPOpenFlags.writeTruncateCreate
        let handle: Data
        do {
            handle = try await remote.open(remotePath, flags: flags)
        } catch let error as SFTPError {
            throw TransferError.failed(error.localizedDescription)
        }

        do {
            var nextOffset = offset
            var pending: [(offset: Int64, size: Int, task: Task<Void, Error>)] = []
            let window = activeConfiguration.uploadWindow
            let chunkSize = Int(activeConfiguration.chunkSize)
            let started = Date()
            let bytesAtStart = offset

            while nextOffset < size || !pending.isEmpty {
                try checkCancellation(itemID)
                while pending.count < window, nextOffset < size {
                    let start = Int(nextOffset)
                    let end = min(data.count, start + chunkSize)
                    guard start < end else { break }
                    let chunk = data.subdata(in: start..<end)
                    let writeOffset = nextOffset
                    let task = Task<Void, Error> {
                        try await remote.write(handle: handle, offset: UInt64(writeOffset), data: chunk)
                    }
                    pending.append((writeOffset, chunk.count, task))
                    nextOffset += Int64(chunk.count)
                }
                guard !pending.isEmpty else { break }
                let entry = pending.removeFirst()
                try await entry.task.value
                let elapsed = Date().timeIntervalSince(started)
                let speed = elapsed > 0.3 ? Double(nextOffset - offset) / elapsed : 0
                _ = bytesAtStart
                mutate(itemID) { progress in
                    progress.bytesCompleted += Int64(entry.size)
                    progress.bytesPerSecond = speed
                }
            }
        } catch {
            try? await remote.close(handle)
            throw error
        }
        try? await remote.close(handle)

        if let modified {
            let seconds = UInt32(clamping: Int(modified.timeIntervalSince1970))
            let attributes = SFTPFileAttributes(size: nil,
                                                permissions: nil,
                                                accessTime: seconds,
                                                modifyTime: seconds)
            try? await remote.setAttributes(remotePath, attributes: attributes)
        }
    }
}
