import Foundation
import TaugeKit

/// A stand-in for the keychain so the migration path can be counted exactly.
private final class SpySecretStore: SecretStore {
    var values: [String: String]
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func secret(for account: SecretAccount) throws -> String? {
        reads.append(account.rawValue)
        return values[account.rawValue]
    }

    func setSecret(_ value: String?, for account: SecretAccount) throws {
        writes.append(account.rawValue)
        if let value {
            values[account.rawValue] = value
        } else {
            values.removeValue(forKey: account.rawValue)
        }
    }
}

private func makeVaultDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tauge-vault-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

/// Checks for the app-local encrypted credential vault and the migration away
/// from the login keychain.
func runLocalVaultChecks() {
    let password = SecretAccount.hostPassword(UUID())
    let passphrase = SecretAccount.hostPassphrase(UUID())

    run("localVault round-trips secrets") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVaultStore(directory: directory)

        try vault.setSecret("hunter2", for: password)
        try vault.setSecret("pp", for: passphrase)
        expectEqual((try vault.secret(for: password)) ?? nil, "hunter2", "the password comes back")
        expectEqual((try vault.secret(for: passphrase)) ?? nil, "pp", "the passphrase comes back")

        try vault.setSecret(nil, for: password)
        expectEqual((try vault.secret(for: password)) ?? nil, nil, "a deleted secret is gone")
        expectEqual((try vault.secret(for: passphrase)) ?? nil, "pp", "the other secret survives the delete")
    }

    run("localVault keeps plaintext out of the file") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVaultStore(directory: directory)
        try vault.setSecret("hunter2", for: password)

        let raw = (try? Data(contentsOf: vault.vaultURL)) ?? Data()
        let text = String(decoding: raw, as: UTF8.self)
        expect(!text.contains("hunter2"), "the password is not stored in the clear")
        expect(!text.contains(password.rawValue), "the account name is not stored in the clear either")
        expect(text.contains("ciphertext"), "the file is the sealed envelope")
    }

    run("localVault writes owner-only files") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVaultStore(directory: directory)
        try vault.setSecret("hunter2", for: password)

        expectEqual(permissions(vault.vaultURL), 0o600, "the vault is readable by the owner only")
        expectEqual(permissions(vault.keyURL), 0o600, "the key is readable by the owner only")
        expect(FileManager.default.fileExists(atPath: vault.keyURL.path), "a key was created on the first write")
    }

    run("localVault survives a restart with the same key") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try LocalVaultStore(directory: directory).setSecret("hunter2", for: password)
        let keyBefore = try? Data(contentsOf: LocalVaultStore(directory: directory).keyURL)

        let reopened = LocalVaultStore(directory: directory)
        expectEqual((try reopened.secret(for: password)) ?? nil, "hunter2", "a new instance reads the file")
        let keyAfter = try? Data(contentsOf: reopened.keyURL)
        expectEqual(keyBefore, keyAfter, "the key is reused, not regenerated")
        expectEqual(try reopened.storedAccounts(), [password.rawValue], "the account is listed")
    }

    run("localVault migrates the previous application directory") {
        let root = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("ShellX", isDirectory: true)
        let current = root.appendingPathComponent("Tauge", isDirectory: true)
        let legacyVault = LocalVaultStore(directory: legacy)
        try legacyVault.setSecret("legacy-pass", for: password)

        expect(try LocalVaultStore.migrateLegacyDirectoryIfNeeded(from: legacy, to: current),
               "the legacy vault should be copied")
        let migratedAgain = try LocalVaultStore.migrateLegacyDirectoryIfNeeded(from: legacy, to: current)
        expect(!migratedAgain, "the vault migration is idempotent")
        expectEqual((try LocalVaultStore(directory: current).secret(for: password)) ?? nil,
                    "legacy-pass",
                    "the copied vault remains readable")
    }

    run("localVault reports a corrupted file instead of inventing an empty one") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVaultStore(directory: directory)
        try vault.setSecret("hunter2", for: password)

        // Flip one byte of the ciphertext inside the envelope.
        var envelope = (try? JSONSerialization.jsonObject(with: Data(contentsOf: vault.vaultURL))) as? [String: Any] ?? [:]
        var ciphertext = Array(Data(base64Encoded: envelope["ciphertext"] as? String ?? "") ?? Data())
        expect(!ciphertext.isEmpty, "the envelope carries ciphertext")
        ciphertext[0] ^= 0xFF
        envelope["ciphertext"] = Data(ciphertext).base64EncodedString()
        let broken = try? JSONSerialization.data(withJSONObject: envelope)
        try? broken?.write(to: vault.vaultURL)
        let before = try? Data(contentsOf: vault.vaultURL)

        var failed = false
        do {
            _ = try LocalVaultStore(directory: directory).secret(for: password)
        } catch {
            failed = true
        }
        expect(failed, "a tampered vault reports an error")
        expectEqual(try? Data(contentsOf: vault.vaultURL), before, "the damaged file is left alone")
    }

    run("localVault distinguishes a delete from an unknown account") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVaultStore(directory: directory)
        expectEqual(try vault.knows(password), false, "a fresh vault has never seen the account")

        try vault.setSecret(nil, for: password)
        expectEqual(try vault.knows(password), true, "a delete is remembered")
        expectEqual(try vault.knows(passphrase), false, "another account is still unknown")
    }

    run("localVault migrates a keychain secret once") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = SpySecretStore([password.rawValue: "legacy-pass"])
        let store = MigratingSecretStore(local: LocalVaultStore(directory: directory), fallback: keychain)

        expectEqual((try store.secret(for: password)) ?? nil, "legacy-pass", "the keychain still answers the first read")
        expectEqual(keychain.reads.count, 1, "the keychain is read for that account")
        expectEqual(try LocalVaultStore(directory: directory).knows(password), true, "the value is copied into the vault")

        let second = MigratingSecretStore(local: LocalVaultStore(directory: directory), fallback: keychain)
        expectEqual((try second.secret(for: password)) ?? nil, "legacy-pass", "the next launch still gets the password")
        expectEqual(keychain.reads.count, 1, "and does not touch the keychain again")
        expectEqual(keychain.writes.count, 0, "nothing was written back to the keychain")
    }

    run("localVault never resurrects a deleted secret from the keychain") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = SpySecretStore([password.rawValue: "legacy-pass"])
        let store = MigratingSecretStore(local: LocalVaultStore(directory: directory), fallback: keychain)

        _ = try store.secret(for: password)
        try store.setSecret(nil, for: password)
        expectEqual((try store.secret(for: password)) ?? nil, nil, "the deleted password stays deleted")
        expectEqual(keychain.reads.count, 1, "the keychain is not consulted again")
        expectEqual(keychain.values[password.rawValue], "legacy-pass", "the old keychain item itself is untouched")
    }

    run("localVault keeps new secrets out of the keychain") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = SpySecretStore()
        let store = MigratingSecretStore(local: LocalVaultStore(directory: directory), fallback: keychain)

        try store.setSecret("fresh", for: passphrase)
        expectEqual((try store.secret(for: passphrase)) ?? nil, "fresh", "the new secret is readable")
        expectEqual(keychain.writes.count, 0, "the keychain never sees a new secret")
        expectEqual(keychain.reads.count, 0, "and is not consulted for it either")
    }

    run("localVault falls back to the keychain when the folder is unwritable") {
        let directory = makeVaultDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the vault folder should be makes every write fail.
        let blocked = directory.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath: blocked.path, contents: Data("x".utf8))
        let keychain = SpySecretStore()
        let store = MigratingSecretStore(local: LocalVaultStore(directory: blocked), fallback: keychain)

        try store.setSecret("pw", for: password)
        expectEqual(keychain.values[password.rawValue], "pw", "the write lands in the keychain instead of being lost")
    }
}
