import Foundation

public struct Catalog: Sendable {
    public var groups: [HostGroup]
    public var hosts: [SSHHost]
    public var proxies: [ProxyConfig]
    public var keys: [PrivateKeyRecord]

    public init(groups: [HostGroup] = [], hosts: [SSHHost] = [], proxies: [ProxyConfig] = [], keys: [PrivateKeyRecord] = []) {
        self.groups = groups
        self.hosts = hosts
        self.proxies = proxies
        self.keys = keys
    }

    public var hostsByID: [UUID: SSHHost] {
        Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
    }

    public var groupsByID: [UUID: HostGroup] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    public var proxiesByID: [UUID: ProxyConfig] {
        Dictionary(uniqueKeysWithValues: proxies.map { ($0.id, $0) })
    }
}

public enum ConfigError: LocalizedError {
    case missingJumpHost(UUID)
    case missingProxy(UUID)
    case jumpChainTooDeep
    case jumpLoop

    public var errorDescription: String? {
        switch self {
        case .missingJumpHost(let id): return "Jump host \(id.uuidString) no longer exists."
        case .missingProxy(let id): return "Proxy \(id.uuidString) no longer exists."
        case .jumpChainTooDeep: return "Jump chain is deeper than the supported 3 hops."
        case .jumpLoop: return "The jump chain contains a loop."
        }
    }
}

public struct ProxyResolution: Sendable {
    public var proxy: ProxyConfig?
    /// Human readable origin of the decision, e.g. "Host" or "Group “Production”".
    public var source: String?
    /// True when the host (or a group) explicitly configured a proxy policy instead of inheriting silently.
    public var isExplicit: Bool

    public init(proxy: ProxyConfig?, source: String?, isExplicit: Bool) {
        self.proxy = proxy
        self.source = source
        self.isExplicit = isExplicit
    }
}

/// Resolves group inheritance for connection settings (PRD FR-1, FR-5, FR-6).
public struct ConfigResolver: Sendable {
    public let catalog: Catalog
    public let maxHops: Int

    public init(catalog: Catalog, maxHops: Int = 3) {
        self.catalog = catalog
        self.maxHops = maxHops
    }

    public func groupPath(for groupID: UUID?) -> [HostGroup] {
        guard var id = groupID else { return [] }
        let groupsByID = catalog.groupsByID
        var path: [HostGroup] = []
        var visited = Set<UUID>()
        while let group = groupsByID[id], visited.insert(id).inserted, path.count < 64 {
            path.append(group)
            guard let parent = group.parentID else { break }
            id = parent
        }
        return path
    }

    public func effective(for host: SSHHost) throws -> EffectiveHostConfig {
        let path = groupPath(for: host.groupID)
        let jumps = try jumpChain(for: host, depth: 0, visited: [host.id])

        let targetProxy = proxyResolution(for: host)
        var entryProxy = targetProxy
        if let firstJump = jumps.first {
            let jumpProxy = proxyResolution(for: firstJump)
            if jumpProxy.isExplicit {
                entryProxy = jumpProxy
            }
        }

        let encoding = host.encoding ?? path.compactMap { $0.defaults.encoding }.first ?? .utf8
        let terminalType = host.terminalType ?? path.compactMap { $0.defaults.terminalType }.first ?? "xterm-256color"
        let keepalive = host.keepaliveSeconds ?? path.compactMap { $0.defaults.keepaliveSeconds }.first ?? 30
        let logging = host.sessionLoggingEnabled ?? path.compactMap { $0.defaults.sessionLogging }.first ?? false
        let logTemplate = path.compactMap { $0.defaults.logPathTemplate }.first ?? "~/Logs/{host}/{date}.log"
        let uploadDirectory = host.defaultUploadDirectory ?? path.compactMap { $0.defaults.defaultUploadDirectory }.first

        var effectiveHost = host
        if effectiveHost.defaultUploadDirectory == nil {
            effectiveHost.defaultUploadDirectory = uploadDirectory
        }

        let jumpSteps = try jumps.map { jump -> EffectiveHostConfig.JumpStep in
            let jumpProxy = proxyResolution(for: jump).proxy
            return EffectiveHostConfig.JumpStep(host: jump, proxy: jumpProxy)
        }

        return EffectiveHostConfig(
            host: effectiveHost,
            proxy: entryProxy.proxy,
            jumps: jumpSteps,
            encoding: encoding,
            terminalType: terminalType,
            keepaliveSeconds: keepalive,
            startDirectory: host.startDirectory,
            startupCommand: host.startupCommand,
            sessionLogging: logging,
            logPathTemplate: logTemplate,
            proxySourceDescription: entryProxy.source
        )
    }

    public func proxyResolution(for host: SSHHost) -> ProxyResolution {
        let path = groupPath(for: host.groupID)
        if !host.proxyPolicy.isInherit {
            return makeResolution(policy: host.proxyPolicy, source: "Host")
        }
        for group in path where !group.defaults.proxyPolicy.isInherit {
            return makeResolution(policy: group.defaults.proxyPolicy, source: "Group “\(group.name)”")
        }
        return ProxyResolution(proxy: nil, source: nil, isExplicit: false)
    }

    public func jumpPolicy(for host: SSHHost) -> (policy: JumpPolicy, source: String?)? {
        if !host.jumpPolicy.isInherit {
            return (host.jumpPolicy, "Host")
        }
        for group in groupPath(for: host.groupID) where !group.defaults.jumpPolicy.isInherit {
            return (group.defaults.jumpPolicy, "Group “\(group.name)”")
        }
        return nil
    }

    private func makeResolution(policy: ProxyPolicy, source: String) -> ProxyResolution {
        switch policy {
        case .direct:
            return ProxyResolution(proxy: nil, source: source, isExplicit: true)
        case .use(let id):
            return ProxyResolution(proxy: catalog.proxiesByID[id], source: source, isExplicit: true)
        case .inherit:
            return ProxyResolution(proxy: nil, source: nil, isExplicit: false)
        }
    }

    private func jumpChain(for host: SSHHost, depth: Int, visited: Set<UUID>) throws -> [SSHHost] {
        guard depth <= maxHops else { throw ConfigError.jumpChainTooDeep }
        guard let resolved = jumpPolicy(for: host), case .hosts(let ids) = resolved.policy else {
            return []
        }
        var visited = visited
        var chain: [SSHHost] = []
        for id in ids {
            guard let jump = catalog.hostsByID[id] else { throw ConfigError.missingJumpHost(id) }
            guard visited.insert(jump.id).inserted else { throw ConfigError.jumpLoop }
            chain.append(contentsOf: try jumpChain(for: jump, depth: depth + 1, visited: visited))
            chain.append(jump)
            if chain.count > maxHops {
                throw ConfigError.jumpChainTooDeep
            }
        }
        return chain
    }

    /// A readable route description for the status bar, e.g. "local → bastion → 10.0.3.4".
    public func routeDescription(for config: EffectiveHostConfig) -> String {
        var parts = ["local"]
        if let proxy = config.proxy {
            parts.append("\(proxy.type.displayName.lowercased()) \(proxy.host):\(proxy.port)")
        }
        for jump in config.jumps {
            parts.append(jump.host.hostname)
        }
        parts.append(config.host.hostname)
        return parts.joined(separator: " → ")
    }
}
