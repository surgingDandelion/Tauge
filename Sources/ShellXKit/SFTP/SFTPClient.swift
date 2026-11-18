import Foundation

/// Abstraction over the SSH subsystem channel so the SFTP client can be tested
/// against an in-memory server without any networking.
public protocol SFTPTransport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func closeTransport() async
}

public actor SFTPClient {
    public struct Configuration: Sendable {
        public var chunkSize: UInt32
        public var requestTimeout: TimeInterval?

        public init(chunkSize: UInt32 = UInt32(SFTPConstant.minimumChunkSize),
                    requestTimeout: TimeInterval? = 60) {
            self.chunkSize = max(chunkSize, UInt32(SFTPConstant.minimumChunkSize))
            self.requestTimeout = requestTimeout
        }
    }

    private let transport: SFTPTransport
    private let configuration: Configuration

    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var buffer = Data()
    private var readTask: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var terminalError: Error?

    private var versionWaiter: CheckedContinuation<SFTPResponse, Error>?
    private var versionResponse: SFTPResponse?

    public private(set) var serverVersion: UInt32 = 0
    public private(set) var extensions: [String] = []

    public init(transport: SFTPTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    public var chunkSize: UInt32 { configuration.chunkSize }

    /// True once the subsystem channel is gone: either shutdown() ran or the
    /// read loop saw the transport close. The UI uses it to tell a live SFTP
    /// channel from a stale one whose client is still referenced.
    public var isClosed: Bool { closed || terminalError != nil }

    // MARK: - Lifecycle

    public func start() async throws {
        if let terminalError { throw terminalError }
        if started { return }
        started = true
        readTask = Task { await self.readLoop() }

        do {
            try await transport.send(SFTPCodec.encode(SFTPRequests.initPacket()))
        } catch {
            let wrapped = SFTPError.transport(String(describing: error))
            fail(with: wrapped)
            throw wrapped
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPResponse, Error>) in
            if let queued = self.versionResponse {
                self.versionResponse = nil
                continuation.resume(returning: queued)
            } else {
                self.versionWaiter = continuation
                if let timeout = self.configuration.requestTimeout, timeout > 0 {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        await self?.failVersionWaiting(with: SFTPError.protocolError("timed out waiting for SSH_FXP_VERSION"))
                    }
                }
            }
        }

        guard case .version(let version, let extensions) = response else {
            throw SFTPError.protocolError("expected SSH_FXP_VERSION")
        }
        serverVersion = version
        self.extensions = extensions
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        readTask = nil
        resumeAll(with: SFTPError.closed)
        await transport.closeTransport()
    }

    // MARK: - Directory listing

    public func realPath(_ path: String) async throws -> String {
        let response = try await perform { SFTPRequests.realPath(id: $0, path: path) }
        guard case .name(let entries) = try checked(response), let first = entries.first else {
            throw SFTPError.protocolError("REALPATH returned no names")
        }
        return first.filename
    }

    public func stat(_ path: String, followSymlink: Bool = true) async throws -> SFTPFileAttributes {
        let response = try await perform { SFTPRequests.stat(id: $0, path: path, followSymlink: followSymlink) }
        guard case .attrs(let attributes) = try checked(response) else {
            throw SFTPError.protocolError("STAT did not return attributes")
        }
        return attributes
    }

    public func listDirectory(_ path: String) async throws -> [SFTPNameEntry] {
        let handle = try await openDirectory(path)
        do {
            let entries = try await readAllDirectoryEntries(handle: handle)
            try await close(handle)
            return entries
        } catch {
            try? await close(handle)
            throw error
        }
    }

    public func openDirectory(_ path: String) async throws -> Data {
        let response = try await perform { SFTPRequests.openDirectory(id: $0, path: path) }
        guard case .handle(let handle) = try checked(response) else {
            throw SFTPError.protocolError("OPENDIR did not return a handle")
        }
        return handle
    }

    public func readDirectory(_ handle: Data) async throws -> [SFTPNameEntry]? {
        let response = try await perform { SFTPRequests.readDirectory(id: $0, handle: handle) }
        if case .status(let status) = response {
            if status.isEOF { return nil }
            throw SFTPError.status(status)
        }
        guard case .name(let entries) = response else {
            throw SFTPError.protocolError("READDIR did not return names")
        }
        return entries
    }

    private func readAllDirectoryEntries(handle: Data) async throws -> [SFTPNameEntry] {
        var result: [SFTPNameEntry] = []
        while let chunk = try await readDirectory(handle) {
            result.append(contentsOf: chunk)
            if chunk.isEmpty { break }
        }
        return result
    }

    // MARK: - File handles

    public func open(_ path: String,
                     flags: SFTPOpenFlags,
                     attributes: SFTPFileAttributes = SFTPFileAttributes()) async throws -> Data {
        let response = try await perform { SFTPRequests.open(id: $0, path: path, flags: flags, attributes: attributes) }
        guard case .handle(let handle) = try checked(response) else {
            throw SFTPError.protocolError("OPEN did not return a handle")
        }
        return handle
    }

    public func close(_ handle: Data) async throws {
        let response = try await perform { SFTPRequests.close(id: $0, handle: handle) }
        _ = try checked(response)
    }

    /// Reads up to chunkSize bytes. An empty result means end of file.
    public func read(handle: Data, offset: UInt64, length: UInt32? = nil) async throws -> Data {
        let requested = min(length ?? configuration.chunkSize, configuration.chunkSize)
        let response = try await perform { SFTPRequests.read(id: $0, handle: handle, offset: offset, length: requested) }
        if case .status(let status) = response {
            if status.isEOF { return Data() }
            throw SFTPError.status(status)
        }
        guard case .data(let data) = response else {
            throw SFTPError.protocolError("READ did not return data")
        }
        return data
    }

    public func write(handle: Data, offset: UInt64, data: Data) async throws {
        let response = try await perform { SFTPRequests.write(id: $0, handle: handle, offset: offset, data: data) }
        _ = try checked(response)
    }

    public func setAttributes(_ path: String, attributes: SFTPFileAttributes) async throws {
        let response = try await perform { SFTPRequests.setStat(id: $0, path: path, attributes: attributes) }
        _ = try checked(response)
    }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        try await setAttributes(path, attributes: SFTPFileAttributes(permissions: UInt32(mode)))
    }

    // MARK: - Namespace mutation

    public func createDirectory(_ path: String, mode: UInt16? = nil) async throws {
        let attributes = mode.map { SFTPFileAttributes(permissions: UInt32($0)) } ?? SFTPFileAttributes()
        let response = try await perform { SFTPRequests.makeDirectory(id: $0, path: path, attributes: attributes) }
        _ = try checked(response)
    }

    public func removeDirectory(_ path: String) async throws {
        let response = try await perform { SFTPRequests.removeDirectory(id: $0, path: path) }
        _ = try checked(response)
    }

    public func removeFile(_ path: String) async throws {
        let response = try await perform { SFTPRequests.remove(id: $0, path: path) }
        _ = try checked(response)
    }

    public func rename(_ oldPath: String, to newPath: String) async throws {
        let response = try await perform { SFTPRequests.rename(id: $0, oldPath: oldPath, newPath: newPath) }
        _ = try checked(response)
    }

    public func readLink(_ path: String) async throws -> String {
        let response = try await perform { SFTPRequests.readLink(id: $0, path: path) }
        guard case .name(let entries) = try checked(response), let first = entries.first else {
            throw SFTPError.protocolError("READLINK returned no names")
        }
        return first.filename
    }

    public func createSymbolicLink(target: String, at linkPath: String) async throws {
        let response = try await perform { SFTPRequests.symbolicLink(id: $0, target: target, linkPath: linkPath) }
        _ = try checked(response)
    }

    // MARK: - Convenience

    public func readFile(_ path: String, limit: Int? = nil) async throws -> Data {
        let handle = try await open(path, flags: [.read])
        do {
            var result = Data()
            var offset: UInt64 = 0
            while true {
                let chunk = try await read(handle: handle, offset: offset)
                if chunk.isEmpty { break }
                result.append(chunk)
                offset += UInt64(chunk.count)
                if let limit, result.count >= limit { break }
            }
            try await close(handle)
            if let limit, result.count > limit { return result.prefix(limit) }
            return result
        } catch {
            try? await close(handle)
            throw error
        }
    }

    public func writeFile(_ path: String, data: Data) async throws {
        let handle = try await open(path, flags: SFTPOpenFlags.writeTruncateCreate)
        do {
            var offset: UInt64 = 0
            while offset < UInt64(data.count) {
                let end = min(data.count, Int(offset) + Int(configuration.chunkSize))
                let chunk = data.subdata(in: Int(offset)..<end)
                try await write(handle: handle, offset: offset, data: chunk)
                offset += UInt64(chunk.count)
            }
            try await close(handle)
        } catch {
            try? await close(handle)
            throw error
        }
    }

    // MARK: - Request plumbing

    private func perform(_ build: (UInt32) -> SFTPPacket) async throws -> SFTPResponse {
        if let terminalError { throw terminalError }
        guard started, !closed else { throw SFTPError.closed }

        let id = nextRequestID
        nextRequestID &+= 1
        let packet = build(id)
        let encoded = SFTPCodec.encode(packet)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPResponse, Error>) in
            pending[id] = continuation
            if let timeout = configuration.requestTimeout, timeout > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.failRequest(id, with: SFTPError.protocolError("request timed out"))
                }
            }
            Task {
                do {
                    try await self.transport.send(encoded)
                } catch {
                    await self.failRequest(id, with: SFTPError.transport(String(describing: error)))
                }
            }
        }
    }

    private func checked(_ response: SFTPResponse) throws -> SFTPResponse {
        if case .status(let status) = response, !status.isOK {
            throw SFTPError.status(status)
        }
        return response
    }

    private func readLoop() async {
        while !closed {
            let chunk: Data?
            do {
                chunk = try await transport.receive()
            } catch {
                fail(with: SFTPError.transport(String(describing: error)))
                return
            }
            guard let chunk else {
                fail(with: SFTPError.closed)
                return
            }
            ingest(chunk)
            if terminalError != nil { return }
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while true {
            let packet: SFTPPacket?
            do {
                packet = try SFTPCodec.decode(from: &buffer)
            } catch {
                fail(with: SFTPError.protocolError(String(describing: error)))
                return
            }
            guard let packet else { return }
            do {
                let (id, response) = try SFTPCodec.parseResponse(packet)
                if case .version = response {
                    deliverVersion(response)
                    continue
                }
                guard let id, let continuation = pending.removeValue(forKey: id) else { continue }
                continuation.resume(returning: response)
            } catch {
                fail(with: SFTPError.protocolError(String(describing: error)))
                return
            }
        }
    }

    private func deliverVersion(_ response: SFTPResponse) {
        if let waiter = versionWaiter {
            versionWaiter = nil
            waiter.resume(returning: response)
        } else {
            versionResponse = response
        }
    }

    private func failVersionWaiting(with error: Error) {
        guard let waiter = versionWaiter else { return }
        versionWaiter = nil
        waiter.resume(throwing: error)
    }

    private func failRequest(_ id: UInt32, with error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func resumeAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        if let waiter = versionWaiter {
            versionWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    private func fail(with error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        closed = true
        readTask?.cancel()
        readTask = nil
        resumeAll(with: error)
    }
}
