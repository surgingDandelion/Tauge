import Foundation

/// The slice of `Keychain` the vault needs. Tests substitute an in-memory
/// double because the check runner has no unlocked login keychain.
public protocol KeychainItemStore {
    func string(for account: String) throws -> String?
    func setString(_ value: String?, for account: String) throws
    func accounts() throws -> [String]
}

extension Keychain: KeychainItemStore {}

/// Stores every secret in a single keychain item.
///
/// Each generic-password item carries its own ACL, and macOS re-asks for the
/// login-keychain password whenever it cannot match that ACL — which happens
/// for every credential after the binary is re-signed (and for every build when
/// the app is signed ad hoc). Keeping one item means the user authorises the
/// app once per signature instead of once per host password. This is a legacy
/// format; the app and CLI only use the read-only migration method below.
///
/// Values written by older builds live in one item per account. They are
/// adopted lazily: the first time an account is read the legacy item is copied
/// into the vault and the account is recorded in `seen`, so the keychain is
/// touched at most once per account and a deleted secret can never come back
/// from a stale legacy item.
public final class KeychainVaultStore: SecretStore {
    public static let vaultAccount = "vault.v1"

    struct Document: Codable, Equatable {
        var version: Int = 1
        var items: [String: String] = [:]
        /// Every account this vault has ever known, including deleted ones.
        var seen: [String] = []
    }

    private let items: any KeychainItemStore
    private let lock = NSLock()
    private var document: Document?

    public init(items: any KeychainItemStore = Keychain()) {
        self.items = items
    }

    // MARK: - SecretStore

    public func secret(for account: SecretAccount) throws -> String? {
        try withLock { try secretLocked(for: account.rawValue) }
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        try withLock { try setSecretLocked(value, for: account.rawValue) }
    }

    // MARK: - Maintenance

    /// Reads either legacy format without creating or updating a keychain
    /// item. A deletion recorded by the old vault takes precedence over an
    /// even older per-account item.
    public func readForMigration(_ account: SecretAccount) throws -> String? {
        try withLock {
            let key = account.rawValue
            if let doc = try currentLocked(), doc.seen.contains(key) {
                return doc.items[key]
            }
            return try items.string(for: key)
        }
    }

    /// Every account the vault knows about, plus accounts that still only exist
    /// as legacy items.
    public func storedAccounts() throws -> [String] {
        try withLock {
            var names = Set(try (document ?? loadLocked())?.seen ?? [])
            names.formUnion(try items.accounts())
            names.remove(KeychainVaultStore.vaultAccount)
            return names.sorted()
        }
    }

    /// Drops the in-memory copy so the next read goes back to the keychain.
    func evictCache() {
        lock.lock()
        document = nil
        lock.unlock()
    }

    // MARK: - Locked helpers

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func secretLocked(for key: String) throws -> String? {
        if var doc = try currentLocked() {
            if doc.seen.contains(key) {
                return doc.items[key]
            }
            // First sighting since the vault was created: adopt the legacy item
            // once, then remember the account so a later delete sticks.
            let legacy = try items.string(for: key)
            if let legacy {
                doc.items[key] = legacy
            }
            doc.seen.append(key)
            doc.seen.sort()
            try persistLocked(doc)
            return legacy
        }

        // No vault yet. Seed it from the legacy item so the prompt (if any) is
        // paid once and every later read is answered from the single item.
        guard let legacy = try items.string(for: key) else { return nil }
        var doc = Document()
        doc.items[key] = legacy
        doc.seen = [key]
        try persistLocked(doc)
        return legacy
    }

    private func setSecretLocked(_ value: String?, for key: String) throws {
        var doc = try currentLocked() ?? Document()
        if !doc.seen.contains(key) {
            doc.seen.append(key)
            doc.seen.sort()
        }
        if let value, !value.isEmpty {
            doc.items[key] = value
        } else {
            doc.items.removeValue(forKey: key)
        }
        try persistLocked(doc)
    }

    private func currentLocked() throws -> Document? {
        if let document { return document }
        let loaded = try loadLocked()
        document = loaded
        return loaded
    }

    private func loadLocked() throws -> Document? {
        guard let raw = try items.string(for: Self.vaultAccount) else { return nil }
        guard let data = raw.data(using: .utf8) else { throw KeychainError.invalidData }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch {
            // Never overwrite a vault we cannot parse: that would destroy every
            // stored credential at once. Surface the error instead.
            throw KeychainError.invalidData
        }
    }

    private func persistLocked(_ doc: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        guard let raw = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        try items.setString(raw, for: Self.vaultAccount)
        document = doc
    }
}
