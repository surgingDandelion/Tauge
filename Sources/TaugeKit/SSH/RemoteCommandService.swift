import Foundation
import NIOCore
import NIOPosix

/// A machine target exposed to the local CLI or MCP adapter.
public struct RemoteCommandTarget: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let address: String
    public let authMethod: AuthMethod

    public init(id: UUID, name: String, address: String, authMethod: AuthMethod) {
        self.id = id
        self.name = name
        self.address = address
        self.authMethod = authMethod
    }
}

public struct RemoteCommandResult: Codable, Equatable, Sendable {
    public let targetID: UUID
    public let command: String
    public let output: String
    public let durationMilliseconds: Int

    public init(targetID: UUID, command: String, output: String, durationMilliseconds: Int) {
        self.targetID = targetID
        self.command = command
        self.output = output
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct RemoteCopyResult: Codable, Equatable, Sendable {
    public let sourceTargetID: UUID
    public let destinationTargetID: UUID
    public let sourcePath: String
    public let destinationPath: String
    public let files: Int
    public let bytes: Int64
    public let durationMilliseconds: Int

    public init(sourceTargetID: UUID, destinationTargetID: UUID, sourcePath: String,
                destinationPath: String, files: Int, bytes: Int64, durationMilliseconds: Int) {
        self.sourceTargetID = sourceTargetID
        self.destinationTargetID = destinationTargetID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.files = files
        self.bytes = bytes
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum RemoteCommandServiceError: Error, LocalizedError, Sendable {
    case targetNotFound(String)
    case unsupportedRoute
    case unsupportedAuthentication(AuthMethod)
    case credentialUnavailable
    case privateKeyUnavailable
    case recursiveRequired(String)

    public var errorDescription: String? {
        switch self {
        case .targetNotFound(let value): return "Target not found: " + value
        case .unsupportedRoute: return "The selected target requires a proxy or jump host, which this local command adapter does not support yet."
        case .unsupportedAuthentication(let method): return "The selected target uses unsupported authentication: " + method.rawValue
        case .credentialUnavailable: return "The saved credential is unavailable. Unlock Tauge and save the credential first."
        case .privateKeyUnavailable: return "The configured private key is unavailable."
        case .recursiveRequired(let path): return "Source is a directory. Use --recursive for: " + path
        }
    }
}

/// Reuses Tauge's catalog, vault and SSH stack for local command adapters.
///
/// The service deliberately does not accept passwords or private keys as
/// arguments. Callers provide an application-owned SecretStore.
public final class RemoteCommandService: @unchecked Sendable {
    private let store: HostStore
    private let secrets: SecretStore
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    public init(store: HostStore,
                secrets: SecretStore,
                eventLoopGroup: MultiThreadedEventLoopGroup) {
        self.store = store
        self.secrets = secrets
        self.eventLoopGroup = eventLoopGroup
    }

    public func targets() throws -> [RemoteCommandTarget] {
        try store.hosts().map {
            RemoteCommandTarget(id: $0.id,
                                name: $0.name,
                                address: $0.displayAddress,
                                authMethod: $0.authMethod)
        }
    }

    public func execute(target: String,
                        command: String,
                        timeout: TimeAmount = .seconds(30),
                        hostKeyValidator: HostKeyValidator? = nil) async throws -> RemoteCommandResult {
        let host = try resolveTarget(target)
        let catalog = Catalog(groups: try store.groups(),
                              hosts: try store.hosts(),
                              proxies: try store.proxies(),
                              keys: try store.privateKeys())
        let config = try ConfigResolver(catalog: catalog).effective(for: host)
        guard config.host.transport != .system else { throw RemoteCommandServiceError.unsupportedRoute }

        let auth = try authentication(for: host)
        let validator = hostKeyValidator ?? knownHostValidator()
        let targetUsername = config.host.username.isEmpty ? NSUserName() : config.host.username
        let jumps = try config.jumps.map { step in
            SSHJumpEndpoint(host: step.host.hostname,
                            port: step.host.port,
                            username: step.host.username.isEmpty ? targetUsername : step.host.username,
                            auth: try authentication(for: step.host),
                            hostKeyValidator: validator)
        }
        let options = SSHConnectOptions(host: config.host.hostname,
                                        port: config.host.port,
                                        username: targetUsername,
                                        auth: auth,
                                        hostKeyValidator: validator,
                                        proxy: try proxyEndpoint(for: config.proxy),
                                        jumps: jumps,
                                        keepaliveSeconds: config.keepaliveSeconds)
        let client = SSHClient(eventLoopGroup: eventLoopGroup)
        let started = Date()
        do {
            try await client.connect(options)
            let output = try await client.runCommand(command, timeout: timeout)
            await client.shutdown()
            return RemoteCommandResult(targetID: host.id,
                                       command: command,
                                       output: output,
                                       durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            await client.shutdown()
            throw error
        }
    }

    public func copy(sourceTarget: String,
                     sourcePath: String,
                     destinationTarget: String,
                     destinationPath: String,
                     recursive: Bool = false) async throws -> RemoteCopyResult {
        let source = try await openSFTP(target: sourceTarget)
        let destination: (host: SSHHost, client: SSHClient, sftp: SFTPClient)
        do {
            destination = try await openSFTP(target: destinationTarget)
        } catch {
            await source.client.shutdown()
            throw error
        }
        let started = Date()
        do {
            let sourceAttributes = try await source.sftp.stat(sourcePath)
            let finalDestination = try await resolveCopyDestination(destination.sftp,
                                                                      sourcePath: sourcePath,
                                                                      destinationPath: destinationPath)
            if sourceAttributes.isDirectory && !recursive {
                throw RemoteCommandServiceError.recursiveRequired(sourcePath)
            }
            var files = 0
            var bytes: Int64 = 0
            try await copyNode(source: source.sftp,
                               destination: destination.sftp,
                               sourcePath: sourcePath,
                               destinationPath: finalDestination,
                               sourceAttributes: sourceAttributes,
                               files: &files,
                               bytes: &bytes)
            await source.client.shutdown()
            await destination.client.shutdown()
            return RemoteCopyResult(sourceTargetID: source.host.id,
                                    destinationTargetID: destination.host.id,
                                    sourcePath: sourcePath,
                                    destinationPath: finalDestination,
                                    files: files,
                                    bytes: bytes,
                                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            await source.client.shutdown()
            await destination.client.shutdown()
            throw error
        }
    }

    private func openSFTP(target: String) async throws -> (host: SSHHost, client: SSHClient, sftp: SFTPClient) {
        let host = try resolveTarget(target)
        let catalog = Catalog(groups: try store.groups(), hosts: try store.hosts(),
                              proxies: try store.proxies(), keys: try store.privateKeys())
        let config = try ConfigResolver(catalog: catalog).effective(for: host)
        guard config.host.transport != .system else { throw RemoteCommandServiceError.unsupportedRoute }
        let auth = try authentication(for: host)
        let validator = knownHostValidator()
        let username = config.host.username.isEmpty ? NSUserName() : config.host.username
        let jumps = try config.jumps.map { step in
            SSHJumpEndpoint(host: step.host.hostname,
                            port: step.host.port,
                            username: step.host.username.isEmpty ? username : step.host.username,
                            auth: try authentication(for: step.host),
                            hostKeyValidator: validator)
        }
        let options = SSHConnectOptions(host: config.host.hostname, port: config.host.port,
                                        username: username, auth: auth,
                                        hostKeyValidator: validator,
                                        proxy: try proxyEndpoint(for: config.proxy), jumps: jumps,
                                        keepaliveSeconds: config.keepaliveSeconds)
        let client = SSHClient(eventLoopGroup: eventLoopGroup)
        do {
            try await client.connect(options)
            let sftp = try await client.openSFTP()
            return (host, client, sftp)
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func resolveCopyDestination(_ destination: SFTPClient,
                                        sourcePath: String,
                                        destinationPath: String) async throws -> String {
        if let attributes = try? await destination.stat(destinationPath), attributes.isDirectory {
            return POSIXPath.join(destinationPath, (sourcePath as NSString).lastPathComponent)
        }
        return destinationPath
    }

    private func copyNode(source: SFTPClient, destination: SFTPClient,
                          sourcePath: String, destinationPath: String,
                          sourceAttributes: SFTPFileAttributes,
                          files: inout Int, bytes: inout Int64) async throws {
        if sourceAttributes.isDirectory {
            if let existing = try? await destination.stat(destinationPath) {
                guard existing.isDirectory else {
                    throw RemoteCommandServiceError.targetNotFound(destinationPath)
                }
            } else {
                try await destination.createDirectory(destinationPath, mode: 0o755)
            }
            let entries = try await source.listDirectory(sourcePath)
            for entry in entries where entry.filename != "." && entry.filename != ".." {
                let childSource = POSIXPath.join(sourcePath, entry.filename)
                let childDestination = POSIXPath.join(destinationPath, entry.filename)
                let childAttributes = try await source.stat(childSource)
                try await copyNode(source: source, destination: destination,
                                   sourcePath: childSource, destinationPath: childDestination,
                                   sourceAttributes: childAttributes,
                                   files: &files, bytes: &bytes)
            }
            return
        }

        let readHandle = try await source.open(sourcePath, flags: [.read])
        let writeHandle = try await destination.open(destinationPath,
                                                     flags: .writeTruncateCreate,
                                                     attributes: SFTPFileAttributes(permissions: sourceAttributes.permissions))
        do {
            var offset: UInt64 = 0
            while true {
                let chunk = try await source.read(handle: readHandle, offset: offset, length: 32768)
                if chunk.isEmpty { break }
                try await destination.write(handle: writeHandle, offset: offset, data: chunk)
                offset += UInt64(chunk.count)
                bytes += Int64(chunk.count)
            }
            try await destination.close(writeHandle)
            try await source.close(readHandle)
            if let permissions = sourceAttributes.permissions {
                try? await destination.setPermissions(destinationPath, mode: UInt16(permissions & 0o7777))
            }
            files += 1
        } catch {
            try? await destination.close(writeHandle)
            try? await source.close(readHandle)
            throw error
        }
    }

    private func resolveTarget(_ value: String) throws -> SSHHost {
        let hosts = try store.hosts()
        if let id = UUID(uuidString: value), let host = hosts.first(where: { $0.id == id }) {
            return host
        }
        if let host = hosts.first(where: { $0.name == value || $0.hostname == value }) {
            return host
        }
        throw RemoteCommandServiceError.targetNotFound(value)
    }

    private func authentication(for host: SSHHost) throws -> SSHAuthMaterial {
        switch host.authMethod {
        case .password, .keyboardInteractive:
            guard let value = try secrets.secret(for: .hostPassword(host.id)), !value.isEmpty else {
                throw RemoteCommandServiceError.credentialUnavailable
            }
            return .password(value)
        case .privateKey:
            let data: Data
            if let path = host.identityFilePath, !path.isEmpty {
                guard let loaded = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else {
                    throw RemoteCommandServiceError.privateKeyUnavailable
                }
                data = loaded
            } else if let keyID = host.keyID,
                      let value = try secrets.secret(for: .privateKey(keyID)),
                      let loaded = value.data(using: .utf8) {
                data = loaded
            } else {
                throw RemoteCommandServiceError.privateKeyUnavailable
            }
            let passphrase = try? secrets.secret(for: .hostPassphrase(host.id))
            return .privateKey(try SSHKeyParser.parse(data: data, passphrase: passphrase ?? nil).key)
        case .agent:
            throw RemoteCommandServiceError.unsupportedAuthentication(.agent)
        }
    }

    private func proxyEndpoint(for proxy: ProxyConfig?) throws -> ProxyEndpoint? {
        guard let proxy else { return nil }
        let password: String?
        if proxy.savesPassword {
            password = try secrets.secret(for: .proxyPassword(proxy.id))
        } else {
            password = nil
        }
        return ProxyEndpoint(type: proxy.type,
                             host: proxy.host,
                             port: proxy.port,
                             username: proxy.username.isEmpty ? nil : proxy.username,
                             password: password)
    }

    private func knownHostValidator() -> HostKeyValidator {
        { [store] info in
            let hostPort = info.host + ":" + String(info.port)
            guard let known = try? store.hostKey(hostPort: hostPort, keyType: info.keyType),
                  known.fingerprintSHA256 == info.fingerprintSHA256 else {
                return .reject
            }
            return .trust(remember: false)
        }
    }
}
