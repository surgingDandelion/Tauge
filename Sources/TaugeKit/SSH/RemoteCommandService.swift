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

public enum RemoteCommandServiceError: Error, LocalizedError, Sendable {
    case targetNotFound(String)
    case unsupportedRoute
    case unsupportedAuthentication(AuthMethod)
    case credentialUnavailable
    case privateKeyUnavailable

    public var errorDescription: String? {
        switch self {
        case .targetNotFound(let value): return "Target not found: " + value
        case .unsupportedRoute: return "The selected target requires a proxy or jump host, which this local command adapter does not support yet."
        case .unsupportedAuthentication(let method): return "The selected target uses unsupported authentication: " + method.rawValue
        case .credentialUnavailable: return "The saved credential is unavailable. Unlock Tauge and save the credential first."
        case .privateKeyUnavailable: return "The configured private key is unavailable."
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
