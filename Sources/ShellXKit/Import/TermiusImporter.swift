import Foundation

/// Knobs for turning a Termius catalogue into Tauge hosts.
public struct TermiusImportOptions: Sendable {
    public var groupName: String
    public var includeHistoryHosts: Bool
    public var importKeys: Bool
    public var importKnownHosts: Bool
    public var importPasswords: Bool
    public var keyDirectory: String
    /// When set, only these host ids (TermiusImportedHost.id) are imported.
    public var selectedHostIDs: Set<String>?

    public init(
        groupName: String = "Termius",
        includeHistoryHosts: Bool = true,
        importKeys: Bool = true,
        importKnownHosts: Bool = true,
        importPasswords: Bool = true,
        keyDirectory: String = TermiusImporter.defaultKeyDirectory(),
        selectedHostIDs: Set<String>? = nil
    ) {
        self.groupName = groupName
        self.includeHistoryHosts = includeHistoryHosts
        self.importKeys = importKeys
        self.importKnownHosts = importKnownHosts
        self.importPasswords = importPasswords
        self.keyDirectory = keyDirectory
        self.selectedHostIDs = selectedHostIDs
    }
}

/// What happened during an import.
public struct TermiusImportSummary: Sendable {
    public var groupName: String
    public var groupID: UUID?
    public var importedHosts: Int = 0
    public var importedKeys: Int = 0
    public var importedKnownHosts: Int = 0
    public var skippedHosts: [String] = []
    public var skippedKeys: [String] = []
    public var passwordsStored: Int = 0
    public var failedKeys: [String] = []
    public var knownHostsWithoutHostname: Int = 0
}

/// Writes a Termius catalogue into the Tauge catalog and keychain.
public enum TermiusImporter {
    public static func defaultKeyDirectory() -> String {
        let base = HostStore.defaultDatabaseURL().deletingLastPathComponent()
        return base.appendingPathComponent("Keys", isDirectory: true).path
    }

    @discardableResult
    public static func apply(
        catalogue: TermiusCatalogue,
        options: TermiusImportOptions,
        store: HostStore,
        secrets: SecretStore
    ) throws -> TermiusImportSummary {
        var summary = TermiusImportSummary(groupName: options.groupName)

        let existingGroups = try store.groups()
        let group: HostGroup
        if let match = existingGroups.first(where: { $0.name == options.groupName && $0.parentID == nil }) {
            group = match
        } else {
            let created = HostGroup(name: options.groupName, sortIndex: (existingGroups.filter { $0.parentID == nil }.map(\.sortIndex).max() ?? -1) + 1)
            try store.save(group: created)
            group = created
        }
        summary.groupID = group.id

        var keyRecords: [String: PrivateKeyRecord] = [:]
        var keyPassphrases: [String: String] = [:]
        if options.importKeys, !catalogue.keys.isEmpty {
            let existingKeys = try store.privateKeys()
            var existingNames = Set(existingKeys.map { $0.name.lowercased() })
            try FileManager.default.createDirectory(atPath: options.keyDirectory, withIntermediateDirectories: true)

            for termiusKey in catalogue.keys {
                // Same name and same material: reuse. Same name but a different
                // key (Termius happily keeps two "id_rsa" entries) gets a suffix.
                if existingNames.contains(termiusKey.label.lowercased()),
                   let record = existingKeys.first(where: { $0.name.caseInsensitiveCompare(termiusKey.label) == .orderedSame }),
                   Self.sameKeyMaterial(record, pem: termiusKey.privateKeyPEM) {
                    summary.skippedKeys.append(termiusKey.label)
                    keyRecords[termiusKey.label.lowercased()] = record
                    if let passphrase = termiusKey.passphrase { keyPassphrases[termiusKey.label.lowercased()] = passphrase }
                    continue
                }
                let name = Self.uniqueKeyName(base: termiusKey.label, taken: existingNames)
                let fileName = sanitizedFileName(name) + ".pem"
                let path = (options.keyDirectory as NSString).appendingPathComponent(fileName)
                do {
                    try writeKeyFile(termiusKey.privateKeyPEM, to: path)
                } catch {
                    summary.failedKeys.append(termiusKey.label + "：" + error.localizedDescription)
                    continue
                }
                var publicKeyOpenSSH = ""
                var fingerprint = ""
                var hasPassphrase = termiusKey.passphrase?.isEmpty == false
                if let parsed = try? SSHKeyParser.parse(path: path, passphrase: termiusKey.passphrase) {
                    publicKeyOpenSSH = parsed.publicKeyOpenSSH
                    if let blob = Data(base64Encoded: Self.base64Body(parsed.publicKeyOpenSSH)) {
                        fingerprint = KeyFingerprint.sha256(blob)
                    }
                    hasPassphrase = false
                } else if (try? SSHKeyParser.parse(path: path, passphrase: nil)) != nil {
                    hasPassphrase = false
                } else {
                    hasPassphrase = true
                }
                let record = PrivateKeyRecord(
                    name: name,
                    publicKeyOpenSSH: publicKeyOpenSSH,
                    fingerprintSHA256: fingerprint,
                    hasPassphrase: hasPassphrase,
                    storageRef: "file:" + path
                )
                try store.save(privateKey: record)
                existingNames.insert(name.lowercased())
                if keyRecords[termiusKey.label.lowercased()] == nil {
                    keyRecords[termiusKey.label.lowercased()] = record
                }
                keyRecords[name.lowercased()] = record
                if let passphrase = termiusKey.passphrase, !passphrase.isEmpty {
                    keyPassphrases[termiusKey.label.lowercased()] = passphrase
                    try? secrets.setSecret(passphrase, for: .privateKey(record.id))
                }
                summary.importedKeys += 1
            }
        }

        let existingHosts = try store.hosts()
        var existingKeysByEndpoint = Set(existingHosts.map { endpointKey(hostname: $0.hostname, port: $0.port, username: $0.username) })
        let merged = catalogue.mergedHosts(includeHistory: options.includeHistoryHosts)
        let hostsToImport = merged.filter { host in
            guard let selection = options.selectedHostIDs else { return true }
            return selection.contains(host.id)
        }
        var sortIndex = (try store.hosts().filter { $0.groupID == group.id }.map(\.sortIndex).max() ?? -1) + 1

        for candidate in hostsToImport {
            let endpoint = endpointKey(hostname: candidate.hostname, port: candidate.port, username: candidate.username)
            if existingKeysByEndpoint.contains(endpoint) {
                summary.skippedHosts.append(candidate.name + "（" + candidate.hostname + "）")
                continue
            }
            let record = candidate.keyLabel.flatMap { keyRecords[$0.lowercased()] }
            var host = SSHHost(
                groupID: group.id,
                name: candidate.name,
                hostname: candidate.hostname,
                port: candidate.port,
                username: candidate.username,
                authMethod: record != nil ? .privateKey : .password,
                sortIndex: sortIndex
            )
            host.keyID = record?.id
            host.tags = candidate.tags
            host.encoding = candidate.encoding
            host.startupCommand = candidate.startupCommand
            if record == nil, let password = candidate.password, !password.isEmpty {
                host.savesPassword = true
                if options.importPasswords {
                    try? secrets.setSecret(password, for: .hostPassword(host.id))
                    summary.passwordsStored += 1
                }
            }
            if let record, let passphrase = keyPassphrases[candidate.keyLabel?.lowercased() ?? ""] {
                try? secrets.setSecret(passphrase, for: .hostPassphrase(host.id))
            }
            if record != nil, host.tags.isEmpty {
                host.tags = []
            }
            host.notes = ""
            try store.save(host: host)
            existingKeysByEndpoint.insert(endpoint)
            summary.importedHosts += 1
            sortIndex += 1
        }

        if options.importKnownHosts, !catalogue.knownHosts.isEmpty {
            let existing = try store.hostKeys()
            var existingIDs = Set(existing.map(\.id))
            for entry in catalogue.knownHosts {
                guard let blob = Data(base64Encoded: entry.base64) else { continue }
                let fingerprint = KeyFingerprint.sha256(blob)
                var imported = false
                for rawName in entry.hostnames.isEmpty ? [""] : entry.hostnames {
                    let hostPort = normalizeHostPort(rawName)
                    guard !hostPort.isEmpty else { continue }
                    let record = KnownHostEntry(
                        hostPort: hostPort,
                        keyType: entry.keyType,
                        fingerprintSHA256: fingerprint,
                        publicKeyBase64: entry.base64
                    )
                    if existingIDs.contains(record.id) { continue }
                    try store.save(hostKey: record)
                    existingIDs.insert(record.id)
                    imported = true
                }
                if imported {
                    summary.importedKnownHosts += 1
                } else if entry.hostnames.isEmpty {
                    summary.knownHostsWithoutHostname += 1
                }
            }
        }

        return summary
    }

    private static func sameKeyMaterial(_ record: PrivateKeyRecord, pem: String) -> Bool {
        guard let reference = record.storageRef, reference.hasPrefix("file:") else { return false }
        let path = String(reference.dropFirst("file:".count))
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return existing.trimmingCharacters(in: .whitespacesAndNewlines) == pem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueKeyName(base: String, taken: Set<String>) -> String {
        if !taken.contains(base.lowercased()) { return base }
        var index = 2
        while taken.contains((base + "-" + String(index)).lowercased()) { index += 1 }
        return base + "-" + String(index)
    }

    static func sanitizedFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var result = ""
        for scalar in name.unicodeScalars {
            result.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "termius-key" : trimmed
    }

    static func writeKeyFile(_ text: String, to path: String) throws {
        var payload = text
        if !payload.hasSuffix("\n") { payload += "\n" }
        guard let data = payload.data(using: .utf8) else {
            throw TermiusVaultError.unsupportedLayout("私钥不是合法的 UTF-8 文本")
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func base64Body(_ openSSH: String) -> String {
        let parts = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    static func endpointKey(hostname: String, port: Int, username: String) -> String {
        hostname.lowercased() + ":" + String(port) + "/" + username.lowercased()
    }

    /// Termius stores known hosts either as a bare hostname, host:port or [host]:port.
    static func normalizeHostPort(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.hasPrefix("[") {
            if let closing = text.firstIndex(of: "]") {
                let host = String(text[text.index(after: text.startIndex)..<closing])
                let rest = text[text.index(after: closing)...]
                if rest.hasPrefix(":"), !rest.dropFirst().isEmpty {
                    return host + ":" + String(rest.dropFirst())
                }
                return host + ":22"
            }
        }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, !text.hasPrefix(":") {
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, Int(parts[1]) != nil {
                return text
            }
        }
        return text + ":22"
    }
}
