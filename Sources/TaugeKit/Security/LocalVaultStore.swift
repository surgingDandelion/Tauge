import Foundation
import CryptoKit

public enum LocalVaultError: Error, LocalizedError, Equatable {
    case keyUnavailable
    case keyCorrupt
    case malformed
    case corrupted

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "The credential vault key could not be written"
        case .keyCorrupt: return "The credential vault key has the wrong size"
        case .malformed: return "The credential vault file is malformed"
        case .corrupted: return "The credential vault cannot be decrypted"
        }
    }
}

/// Credentials kept in the app's own folder instead of the login keychain.
///
/// The login keychain re-asks for its password whenever the app's code signature
/// no longer matches the item's ACL, which means an update, a reinstall or any
/// ad-hoc build greets the user with "Tauge wants to use your confidential
/// information stored in com.tauge.credentials". Two plain files under
/// `~/Library/Application Support/Tauge` remove that dialog entirely:
///
/// - `vault.v1.enc` — the account map as JSON, sealed with AES-256-GCM.
/// - `vault.key` — the 32-byte key, created once on the first write.
///
/// Both are `0600`. The honest trade: the key sits next to the ciphertext, so
/// this keeps plaintext passwords out of backups, greps, crash reports and
/// screen sharing, but it does not defend against a process that already runs as
/// the same user. In exchange the vault survives every rebuild and the keychain
/// is touched at most once, when an old value has to be migrated.
///
/// Deleting an account is recorded in `seen`, so a stale keychain value can never
/// resurrect a password the user removed.
public final class LocalVaultStore: SecretStore {
    public static let vaultFileName = "vault.v1.enc"
    public static let keyFileName = "vault.key"
    public static let keyByteCount = 32
    static let associatedData = Data("tauge-local-vault-v1".utf8)
    static let legacyAssociatedData = Data("shellx-local-vault-v1".utf8)

    struct Document: Codable, Equatable {
        var version: Int = 1
        var items: [String: String] = [:]
        /// Every account this vault has ever handled, including deleted ones.
        var seen: [String] = []
    }

    struct Envelope: Codable, Equatable {
        var version: Int = 1
        var nonce: Data
        var ciphertext: Data
        var tag: Data
    }

    private let directory: URL
    private let lock = NSLock()
    private var document: Document?
    private var key: SymmetricKey?

    public init(directory: URL = LocalVaultStore.defaultDirectory()) {
        self.directory = directory
    }

    /// The folder next to the catalog, which is also where the app keeps its
    /// settings and history.
    public static func defaultDirectory() -> URL {
        HostStore.defaultDatabaseURL().deletingLastPathComponent()
    }

    /// Directory used by the pre-Tauge builds. It is a one-time migration
    /// source so an app update keeps the encrypted credential vault available.
    public static func legacyDirectory() -> URL {
        HostStore.legacyDatabaseURL().deletingLastPathComponent()
    }

    /// Copies the old vault pair into the Tauge directory when the new pair is
    /// absent. The encrypted payload can then be opened through the legacy
    /// associated-data fallback below and is rewritten with the current format
    /// on the next credential change.
    @discardableResult
    public static func migrateLegacyDirectoryIfNeeded(
        from legacy: URL = LocalVaultStore.legacyDirectory(),
        to current: URL = LocalVaultStore.defaultDirectory()
    ) throws -> Bool {
        let fileManager = FileManager.default
        let currentVault = current.appendingPathComponent(vaultFileName)
        let legacyVault = legacy.appendingPathComponent(vaultFileName)
        guard !fileManager.fileExists(atPath: currentVault.path),
              fileManager.fileExists(atPath: legacyVault.path) else { return false }
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyVault, to: currentVault)
        let legacyKey = legacy.appendingPathComponent(keyFileName)
        let currentKey = current.appendingPathComponent(keyFileName)
        if fileManager.fileExists(atPath: legacyKey.path), !fileManager.fileExists(atPath: currentKey.path) {
            try fileManager.copyItem(at: legacyKey, to: currentKey)
        }
        return true
    }

    public var vaultURL: URL { directory.appendingPathComponent(Self.vaultFileName) }
    public var keyURL: URL { directory.appendingPathComponent(Self.keyFileName) }
    public var exists: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }

    // MARK: - SecretStore

    public func secret(for account: SecretAccount) throws -> String? {
        try withLock { try secretLocked(for: account.rawValue) }
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        try withLock { try setSecretLocked(value, for: account.rawValue) }
    }

    // MARK: - Maintenance

    /// True once this vault has handled `account`, including a delete. Callers use
    /// it to tell "the vault has never heard of this" from "the vault says no".
    public func knows(_ account: SecretAccount) throws -> Bool {
        try withLock { try currentLocked()?.seen.contains(account.rawValue) ?? false }
    }

    public func storedAccounts() throws -> [String] {
        try withLock { try currentLocked()?.seen.sorted() ?? [] }
    }

    /// Drops the in-memory document; the next read comes from disk.
    public func evictCache() {
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

    private func secretLocked(for account: String) throws -> String? {
        try currentLocked()?.items[account]
    }

    private func setSecretLocked(_ value: String?, for account: String) throws {
        var doc = try currentLocked() ?? Document()
        if !doc.seen.contains(account) {
            doc.seen.append(account)
            doc.seen.sort()
        }
        if let value, !value.isEmpty {
            doc.items[account] = value
        } else {
            doc.items.removeValue(forKey: account)
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
        guard let data = FileManager.default.contents(atPath: vaultURL.path) else { return nil }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LocalVaultError.malformed
        }
        guard envelope.version == 1 else { throw LocalVaultError.malformed }
        // No key next to an existing vault means the pair was broken by hand; a
        // freshly generated key would only produce a misleading "corrupted".
        guard let key = try existingKeyLocked() else { throw LocalVaultError.corrupted }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                                       ciphertext: envelope.ciphertext,
                                       tag: envelope.tag)
        } catch {
            throw LocalVaultError.corrupted
        }
        for associatedData in [Self.associatedData, Self.legacyAssociatedData] {
            do {
                let plain = try AES.GCM.open(box, using: key, authenticating: associatedData)
                return try JSONDecoder().decode(Document.self, from: plain)
            } catch {
                continue
            }
        }
        throw LocalVaultError.corrupted
    }

    private func persistLocked(_ doc: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(doc)
        // The key is created before the ciphertext so a crash in between leaves a
        // readable vault, never a vault nobody can open.
        let key = try keyLocked(creating: true)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.associatedData)
        let envelope = Envelope(nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag)
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: vaultURL, options: [.atomic])
        // `.atomic` renames a 0644 temp file into place, so the mode is set after.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: vaultURL.path)
        document = doc
    }

    private func existingKeyLocked() throws -> SymmetricKey? {
        if let key { return key }
        guard let data = FileManager.default.contents(atPath: keyURL.path) else { return nil }
        guard data.count == Self.keyByteCount else { throw LocalVaultError.keyCorrupt }
        let key = SymmetricKey(data: data)
        self.key = key
        return key
    }

    private func keyLocked(creating: Bool) throws -> SymmetricKey {
        if let key { return key }
        if let existing = try existingKeyLocked() { return existing }
        guard creating else { throw LocalVaultError.keyUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = CredentialVault.randomBytes(count: Self.keyByteCount)
        guard FileManager.default.createFile(atPath: keyURL.path,
                                             contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw LocalVaultError.keyUnavailable
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let key = SymmetricKey(data: data)
        self.key = key
        return key
    }
}

/// Prefers the app's own vault and keeps the login keychain only as a source for
/// credentials written by older builds.
///
/// Reads: local first. An account the vault has never handled falls through to
/// the keychain once; a hit is copied into the vault so the next launch never
/// touches the keychain again. An account the vault knows about — including one
/// the user deleted — never falls through, so a stale keychain item cannot bring
/// a removed password back.
///
/// Writes go to the vault only. If the vault cannot be written (a read-only data
/// folder, a damaged key) the write lands in the keychain instead of being lost.
public final class MigratingSecretStore: SecretStore {
    private let local: LocalVaultStore
    private let fallback: SecretStore
    private let log: (String) -> Void

    public init(local: LocalVaultStore, fallback: SecretStore, log: @escaping (String) -> Void = { _ in }) {
        self.local = local
        self.fallback = fallback
        self.log = log
    }

    public func secret(for account: SecretAccount) throws -> String? {
        do {
            if let value = try local.secret(for: account) { return value }
            if try local.knows(account) { return nil }
        } catch {
            log("credential vault unreadable, using the keychain: " + error.localizedDescription)
        }
        guard let legacy = try fallback.secret(for: account) else { return nil }
        do {
            try local.setSecret(legacy, for: account)
            log("migrated " + account.rawValue + " into the app vault")
        } catch {
            log("could not migrate " + account.rawValue + ": " + error.localizedDescription)
        }
        return legacy
    }

    public func setSecret(_ value: String?, for account: SecretAccount) throws {
        do {
            try local.setSecret(value, for: account)
        } catch {
            log("credential vault is read-only, writing to the keychain: " + error.localizedDescription)
            try fallback.setSecret(value, for: account)
        }
    }
}
