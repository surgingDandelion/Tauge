import Foundation
import ShellXKit

/// An in-memory stand-in for the keychain.
///
/// The check runner has no unlocked login keychain (and no code signature the
/// system trusts), so anything that touches `SecItem*` has to be faked here.
private final class FakeItemStore: KeychainItemStore {
    var items: [String: String]
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    func string(for account: String) throws -> String? {
        reads.append(account)
        return items[account]
    }

    func setString(_ value: String?, for account: String) throws {
        writes.append(account)
        if let value {
            items[account] = value
        } else {
            items.removeValue(forKey: account)
        }
    }

    func accounts() throws -> [String] {
        items.keys.sorted()
    }
}

private func legacyReads(_ store: FakeItemStore, _ account: SecretAccount) -> Int {
    store.reads.filter { $0 == account.rawValue }.count
}

private func value(_ vault: KeychainVaultStore, _ account: SecretAccount) -> String? {
    (try? vault.secret(for: account)) ?? nil
}

/// Checks for the single-item keychain vault that replaced one item per secret.
func runKeychainVaultChecks() {
    let password = SecretAccount.hostPassword(UUID())
    let passphrase = SecretAccount.hostPassphrase(UUID())
    let proxy = SecretAccount.proxyPassword(UUID())

    run("keychain vault adopts a legacy item once") {
        let store = FakeItemStore([password.rawValue: "legacy-pass"])
        let vault = KeychainVaultStore(items: store)

        expectEqual(value(vault, password), "legacy-pass", "the old per-account item still answers")
        expectEqual(legacyReads(store, password), 1, "the legacy item is read once")
        expect(store.items[KeychainVaultStore.vaultAccount] != nil, "the answer is copied into the vault")

        expectEqual(value(vault, password), "legacy-pass", "later reads answer from the vault")
        expectEqual(legacyReads(store, password), 1, "the legacy item is never touched again")
    }

    run("keychain vault caches the document in memory") {
        let store = FakeItemStore([password.rawValue: "p"])
        let vault = KeychainVaultStore(items: store)
        _ = value(vault, password)
        let before = store.reads.count
        _ = value(vault, password)
        _ = value(vault, passphrase)
        expectEqual(store.reads.count - before, 1, "only the unseen account goes back to the store")
    }

    run("keychain vault keeps a deleted secret deleted") {
        let store = FakeItemStore([password.rawValue: "legacy-pass"])
        let vault = KeychainVaultStore(items: store)
        _ = value(vault, password)

        try vault.setSecret(nil, for: password)
        expectEqual(value(vault, password), nil, "a deleted secret stays gone")
        expectEqual(store.items[password.rawValue], "legacy-pass", "the legacy item itself is left alone")
    }

    run("keychain vault forgets an account that was deleted before it was read") {
        let store = FakeItemStore([password.rawValue: "legacy-pass"])
        let vault = KeychainVaultStore(items: store)

        try vault.setSecret(nil, for: password)
        expectEqual(value(vault, password), nil, "the stale legacy item does not resurrect the password")
        expectEqual(legacyReads(store, password), 0, "nothing needed to be read to forget it")
    }

    run("keychain vault stores every secret in one item") {
        let store = FakeItemStore()
        let vault = KeychainVaultStore(items: store)
        try vault.setSecret("pw", for: password)
        try vault.setSecret("pp", for: passphrase)
        try vault.setSecret("proxy", for: proxy)

        expectEqual(store.items.count, 1, "one keychain item, not one per secret")
        expect(store.items[KeychainVaultStore.vaultAccount] != nil, "that item is the vault")
        expectEqual(value(vault, password), "pw", "the first secret round-trips")
        expectEqual(value(vault, passphrase), "pp", "the passphrase round-trips")
        expectEqual(value(vault, proxy), "proxy", "the proxy password round-trips")
    }

    run("keychain vault survives a restart") {
        let store = FakeItemStore()
        try KeychainVaultStore(items: store).setSecret("pw", for: password)
        let reopened = KeychainVaultStore(items: store)
        expectEqual(value(reopened, password), "pw", "a new instance reads the written secret")
    }

    run("keychain vault refuses to overwrite a corrupt vault") {
        let corrupt = "{ this is not json"
        let store = FakeItemStore([KeychainVaultStore.vaultAccount: corrupt])
        let vault = KeychainVaultStore(items: store)

        var failed = false
        do {
            _ = try vault.secret(for: password)
        } catch {
            failed = true
        }
        expect(failed, "reading a corrupt vault reports an error instead of inventing an empty one")
        expectEqual(store.items[KeychainVaultStore.vaultAccount], corrupt, "the stored bytes are untouched")
    }

    run("keychain vault lists every known account") {
        let store = FakeItemStore([SecretAccount.privateKey(UUID()).rawValue: "key"])
        let vault = KeychainVaultStore(items: store)
        try vault.setSecret("pw", for: password)

        let names = try vault.storedAccounts()
        expect(names.contains(password.rawValue), "a written account is listed")
        expect(names.contains(SecretAccount.privateKey(UUID()).rawValue) == false, "an unrelated legacy item is not invented")
        expect(names.contains(KeychainVaultStore.vaultAccount) == false, "the vault item itself is not an account")
        expectEqual(names, names.sorted(), "the list is sorted")
    }

    run("biometric gate remembers an unlock until locked") {
        let gate = BiometricGate()
        expectEqual(gate.isUnlocked, false, "a fresh gate is locked")
        gate.markUnlocked()
        expectEqual(gate.isUnlocked, true, "an unlock is remembered")
        gate.lock()
        expectEqual(gate.isUnlocked, false, "locking forgets it")
    }
}
