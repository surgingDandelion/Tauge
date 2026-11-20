import Foundation
import TaugeKit

/// Opt-in check against the real Termius vault on this machine.
///
/// Run with TAUGE_TERMIUS=1 (plus TAUGE_TERMIUS_KEY=<base64 key> when the
/// login keychain prompt is not available in the current environment).
@MainActor
func runTermiusVaultChecks() async {
    guard ProcessInfo.processInfo.environment["TAUGE_TERMIUS"] == "1" else { return }
    print("termius: reading local vault")

    let keyValue = ProcessInfo.processInfo.environment["TAUGE_TERMIUS_KEY"]
    let key: [UInt8]
    do {
        if let keyValue, !keyValue.isEmpty {
            key = try TermiusVaultReader.decodeKey(keyValue)
        } else {
            key = try TermiusVaultReader.localKey()
        }
    } catch {
        expect(false, "termius key available: \(error)")
        return
    }
    expect(key.count == 32, "termius key is 32 bytes")

    let catalogue: TermiusCatalogue
    do {
        catalogue = try TermiusVaultReader.read(key: key)
    } catch {
        expect(false, "termius vault readable: \(error)")
        return
    }
    print("termius: dir \(catalogue.sourceDirectory)")
    print("termius: files \(catalogue.scannedFiles) blobs \(catalogue.ciphertextCount) decrypted \(catalogue.decryptedCount) saved \(catalogue.savedHosts.count) identities \(catalogue.identities.count) keys \(catalogue.keys.count) known_hosts \(catalogue.knownHosts.count) history \(catalogue.history.count)")

    print("termius key labels: " + catalogue.keys.map { $0.label }.joined(separator: ", "))
    expect(catalogue.decryptedCount > 0, "termius vault decrypts records")
    expect(!catalogue.savedHosts.isEmpty, "termius saved hosts found")
    expect(!catalogue.identities.isEmpty, "termius identities found")
    expect(!catalogue.knownHosts.isEmpty, "termius known_hosts found")

    let hosts = catalogue.mergedHosts(includeHistory: false)
    let hostAddresses = Set(hosts.map { $0.hostname.lowercased() })
    let missing = catalogue.savedHosts.filter { !hostAddresses.contains($0.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    expect(missing.isEmpty, "merged hosts cover every saved address (missing " + String(missing.count) + ")")
    let endpoints = Set(hosts.map { $0.hostname + ":" + String($0.port) + "/" + $0.username })
    if endpoints.count != hosts.count {
        let groups = Dictionary(grouping: hosts) { $0.hostname + ":" + String($0.port) + "/" + $0.username }
        print("termius duplicate endpoints: " + groups.filter { $0.value.count > 1 }.keys.sorted().prefix(6).joined(separator: ", "))
    }
    expect(endpoints.count == hosts.count, "merged hosts are unique per endpoint")
    for host in hosts.prefix(3) {
        print("termius host: \(host.name) -> \(host.username)@\(host.hostname):\(host.port) key=\(host.keyLabel ?? "-") password=\(host.password == nil ? "no" : "yes")")
    }

    // Import into a throwaway catalog.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("termius-check-" + UUID().uuidString)
    let keyDirectory = root.appendingPathComponent("Keys", isDirectory: true).path
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: root.appendingPathComponent("catalog.sqlite").path)
        let store = try HostStore(database: database)
        let secrets = InMemorySecretStore()
        let options = TermiusImportOptions(groupName: "Termius 检查", keyDirectory: keyDirectory)
        let summary = try TermiusImporter.apply(catalogue: catalogue, options: options, store: store, secrets: secrets)
        expect(summary.importedHosts > 0, "termius import creates hosts")
        expect(summary.importedKeys > 0, "termius import creates keys")
        expect(summary.importedKnownHosts > 0, "termius import creates known_hosts")
        let storedHosts = try store.hosts()
        expect(storedHosts.count == summary.importedHosts, "stored hosts match imported count")
        let groups = try store.groups()
        expect(groups.contains { $0.name == "Termius 检查" }, "termius group created")
        let keys = try store.privateKeys()
        expect(keys.count == summary.importedKeys, "stored keys match imported count")
        expect(summary.failedKeys.isEmpty, "termius keys all import")
        expect(keys.allSatisfy { ($0.storageRef ?? "").hasPrefix("file:") }, "imported keys reference files")
        for record in keys.prefix(6) {
            guard let reference = record.storageRef, reference.hasPrefix("file:") else { continue }
            let path = String(reference.dropFirst("file:".count))
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            expectEqual(permissions, 0o600, "imported key file is 0600")
        }
        let knownHosts = try store.hostKeys()
        expect(knownHosts.count >= summary.importedKnownHosts, "known hosts stored")
        expect(knownHosts.allSatisfy { $0.fingerprintSHA256.hasPrefix("SHA256:") }, "known hosts carry SHA256 fingerprints")
        let passwordHosts = storedHosts.filter { $0.authMethod == .password && $0.savesPassword }
        print("termius keys: skipped \(summary.skippedKeys) failed \(summary.failedKeys) noHost \(summary.knownHostsWithoutHostname)")
        print("termius import: hosts \(summary.importedHosts) keys \(summary.importedKeys) known \(summary.importedKnownHosts) passwords \(summary.passwordsStored) skipped \(summary.skippedHosts.count) passwordHosts \(passwordHosts.count)")

        // Re-running must not duplicate anything.
        let second = try TermiusImporter.apply(catalogue: catalogue, options: options, store: store, secrets: secrets)
        expectEqual(second.importedHosts, 0, "second import skips existing hosts")
    } catch {
        expect(false, "termius import round trip: \(error)")
    }
    try? FileManager.default.removeItem(at: root)
}
