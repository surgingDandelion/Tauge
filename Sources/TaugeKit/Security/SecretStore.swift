import Foundation

/// Typed account names for credential storage. Keeping them in one place prevents
/// typos and makes it obvious which secrets exist (useful for the export flow).
public enum SecretAccount: Hashable, Sendable {
    case hostPassword(UUID)
    case hostPassphrase(UUID)
    case proxyPassword(UUID)
    case privateKey(UUID)
    case exportPassphrase

    public var rawValue: String {
        switch self {
        case .hostPassword(let id): return "host.\(id.uuidString).password"
        case .hostPassphrase(let id): return "host.\(id.uuidString).passphrase"
        case .proxyPassword(let id): return "proxy.\(id.uuidString).password"
        case .privateKey(let id): return "key.\(id.uuidString).private"
        case .exportPassphrase: return "master.export"
        }
    }
}

public protocol SecretStore: AnyObject {
    func secret(for account: SecretAccount) throws -> String?
    func setSecret(_ value: String?, for account: SecretAccount) throws
}

public final class KeychainSecretStore: SecretStore {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func secret(for account: SecretAccount) throws -> String? {
        try keychain.string(for: account.rawValue)
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        try keychain.setString(value, for: account.rawValue)
    }
}

/// Volatile store used when the user disabled keychain persistence or for
/// transient jump-host credentials typed into a connection sheet.
public final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(seed: [SecretAccount: String] = [:]) {
        for (account, value) in seed {
            storage[account.rawValue] = value
        }
    }

    public func secret(for account: SecretAccount) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account.rawValue]
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            storage[account.rawValue] = value
        } else {
            storage.removeValue(forKey: account.rawValue)
        }
    }
}

/// Reads through to the keychain but caches in memory for the lifetime of the
/// process, so repeated reconnect attempts do not prompt for access.
public final class CachingSecretStore: SecretStore {
    private let upstream: SecretStore
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init(upstream: SecretStore) {
        self.upstream = upstream
    }

    public func secret(for account: SecretAccount) throws -> String? {
        lock.lock()
        if let cached = cache[account.rawValue] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = try upstream.secret(for: account)
        if let value {
            lock.lock()
            cache[account.rawValue] = value
            lock.unlock()
        }
        return value
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        try upstream.setSecret(value, for: account)
        lock.lock()
        if let value {
            cache[account.rawValue] = value
        } else {
            cache.removeValue(forKey: account.rawValue)
        }
        lock.unlock()
    }

    public func evictAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
