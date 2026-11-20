import Foundation

/// A Termius identity profile (label + username + optional password).
public struct TermiusIdentity: Sendable, Equatable {
    public var label: String
    public var username: String
    public var password: String?

    public init(label: String, username: String, password: String? = nil) {
        self.label = label
        self.username = username
        self.password = password
    }
}

/// A Termius key vault entry.
public struct TermiusKey: Sendable, Equatable {
    public var label: String
    public var privateKeyPEM: String
    public var publicKey: String?
    public var passphrase: String?

    public init(label: String, privateKeyPEM: String, publicKey: String? = nil, passphrase: String? = nil) {
        self.label = label
        self.privateKeyPEM = privateKeyPEM
        self.publicKey = publicKey
        self.passphrase = passphrase
    }
}

/// A Termius known_hosts record.
public struct TermiusKnownHost: Sendable, Equatable {
    public var hostnames: [String]
    public var keyType: String
    public var base64: String

    public init(hostnames: [String], keyType: String, base64: String) {
        self.hostnames = hostnames
        self.keyType = keyType
        self.base64 = base64
    }
}

/// One entry of the Termius connection history, used to recover ports, users and tags.
public struct TermiusHistoryEntry: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var title: String?
    public var tags: [String]
    public var startupCommand: String?
    public var charset: String?

    public init(host: String, port: Int, username: String? = nil, title: String? = nil, tags: [String] = [], startupCommand: String? = nil, charset: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.title = title
        self.tags = tags
        self.startupCommand = startupCommand
        self.charset = charset
    }
}

/// A host saved in the Termius host list.
public struct TermiusSavedHost: Sendable, Equatable {
    public var label: String
    public var address: String
    public var osName: String?

    public init(label: String, address: String, osName: String? = nil) {
        self.label = label
        self.address = address
        self.osName = osName
    }
}

/// A host ready to be created in Tauge, already merged with identity and history data.
public struct TermiusImportedHost: Sendable, Equatable, Identifiable {
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyLabel: String?
    public var tags: [String]
    public var startupCommand: String?
    public var encoding: TextEncodingKind?
    public var identityLabel: String?
    public var fromHistory: Bool

    public var id: String {
        hostname + ":" + String(port) + "/" + username + "/" + name
    }

    public init(name: String, hostname: String, port: Int, username: String, password: String? = nil, keyLabel: String? = nil, tags: [String] = [], startupCommand: String? = nil, encoding: TextEncodingKind? = nil, identityLabel: String? = nil, fromHistory: Bool = false) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
        self.keyLabel = keyLabel
        self.tags = tags
        self.startupCommand = startupCommand
        self.encoding = encoding
        self.identityLabel = identityLabel
        self.fromHistory = fromHistory
    }
}

/// Everything readable from a local Termius vault.
public struct TermiusCatalogue: Sendable {
    public var savedHosts: [TermiusSavedHost]
    public var identities: [TermiusIdentity]
    public var keys: [TermiusKey]
    public var knownHosts: [TermiusKnownHost]
    public var history: [TermiusHistoryEntry]
    public var groupLabels: [String]
    public var snippetLabels: [String]
    public var sourceDirectory: String
    public var scannedFiles: Int
    public var ciphertextCount: Int
    public var decryptedCount: Int

    public init(savedHosts: [TermiusSavedHost] = [], identities: [TermiusIdentity] = [], keys: [TermiusKey] = [], knownHosts: [TermiusKnownHost] = [], history: [TermiusHistoryEntry] = [], groupLabels: [String] = [], snippetLabels: [String] = [], sourceDirectory: String = "", scannedFiles: Int = 0, ciphertextCount: Int = 0, decryptedCount: Int = 0) {
        self.savedHosts = savedHosts
        self.identities = identities
        self.keys = keys
        self.knownHosts = knownHosts
        self.history = history
        self.groupLabels = groupLabels
        self.snippetLabels = snippetLabels
        self.sourceDirectory = sourceDirectory
        self.scannedFiles = scannedFiles
        self.ciphertextCount = ciphertextCount
        self.decryptedCount = decryptedCount
    }

    /// Merge saved hosts and (optionally) history-only hosts with identities and keys.
    ///
    /// Termius stores the username/password in the identity vault and the port in the
    /// connection history, so a host is rebuilt from up to three records that share a label
    /// or an address.
    public func mergedHosts(includeHistory: Bool = true, preferredKeyLabel: String? = nil) -> [TermiusImportedHost] {
        var identitiesByLabel: [String: TermiusIdentity] = [:]
        for identity in identities {
            identitiesByLabel[identity.label.lowercased()] = identity
        }
        var identitiesByUser: [String: TermiusIdentity] = [:]
        for identity in identities {
            identitiesByUser[identity.username.lowercased()] = identity
        }
        var historyByHost: [String: [TermiusHistoryEntry]] = [:]
        for entry in history {
            historyByHost[entry.host.lowercased(), default: []].append(entry)
        }
        var keyLabels = Set(keys.map { $0.label.lowercased() })

        var result: [TermiusImportedHost] = []
        var seen = Set<String>()
        var savedEndpoints = Set<String>()

        for saved in savedHosts {
            let address = saved.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let entries = historyByHost[address.lowercased()] ?? []
            let entry = preferredHistoryEntry(for: saved, entries: entries)
            let identity = identitiesByLabel[saved.label.lowercased()]
                ?? entry.flatMap { e in e.username.flatMap { identitiesByUser[$0.lowercased()] } }
            let username = identity?.username ?? entry?.username ?? "root"
            let keyLabel = resolveKeyLabel(for: saved.label, identity: identity, keyLabels: keyLabels, preferred: preferredKeyLabel)
            let host = TermiusImportedHost(
                name: saved.label.isEmpty ? address : saved.label,
                hostname: address,
                port: entry?.port ?? 22,
                username: username,
                password: identity?.password,
                keyLabel: keyLabel,
                tags: entry?.tags ?? [],
                startupCommand: entry?.startupCommand,
                encoding: Self.encoding(for: entry?.charset),
                identityLabel: identity?.label,
                fromHistory: false
            )
            let endpoint = address.lowercased() + ":" + String(host.port) + "/" + username.lowercased()
            guard seen.insert(endpoint).inserted else { continue }
            savedEndpoints.insert(endpoint)
            result.append(host)
        }

        if includeHistory {
            for entry in history {
                let address = entry.host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty else { continue }
                let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { continue }
                if savedEndpoints.contains(address.lowercased() + ":" + String(entry.port) + "/" + (entry.username ?? "root").lowercased()) {
                    continue
                }
                let identity = entry.username.flatMap { identitiesByUser[$0.lowercased()] }
                    ?? identitiesByLabel[title.lowercased()]
                let keyLabel = resolveKeyLabel(for: title, identity: identity, keyLabels: keyLabels, preferred: preferredKeyLabel)
                let host = TermiusImportedHost(
                    name: title,
                    hostname: address,
                    port: entry.port,
                    username: identity?.username ?? entry.username ?? "root",
                    password: identity?.password,
                    keyLabel: keyLabel,
                    tags: entry.tags,
                    startupCommand: entry.startupCommand,
                    encoding: Self.encoding(for: entry.charset),
                    identityLabel: identity?.label,
                    fromHistory: true
                )
                let endpoint = address.lowercased() + ":" + String(host.port) + "/" + host.username.lowercased()
                guard seen.insert(endpoint).inserted else { continue }
                result.append(host)
            }
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func preferredHistoryEntry(for saved: TermiusSavedHost, entries: [TermiusHistoryEntry]) -> TermiusHistoryEntry? {
        guard !entries.isEmpty else { return nil }
        if let titled = entries.first(where: { ($0.title ?? "").caseInsensitiveCompare(saved.label) == .orderedSame }) {
            return titled
        }
        if let named = entries.first(where: { ($0.username ?? "").isEmpty == false }) {
            return named
        }
        return entries.first
    }

    private func resolveKeyLabel(for label: String, identity: TermiusIdentity?, keyLabels: Set<String>, preferred: String?) -> String? {
        let candidates = [identity?.label ?? "", label]
        for candidate in candidates {
            let lowered = candidate.lowercased()
            if !lowered.isEmpty, keyLabels.contains(lowered) {
                return candidate
            }
        }
        if let preferred, keyLabels.contains(preferred.lowercased()) {
            return preferred
        }
        // A single key in the vault is almost always the key every host uses.
        if keyLabels.count == 1, let only = keys.first?.label {
            return only
        }
        return nil
    }

    static func encoding(for charset: String?) -> TextEncodingKind? {
        guard let charset else { return nil }
        let normalized = charset.lowercased()
        if normalized.contains("gb") || normalized.contains("936") || normalized.contains("18030") {
            return .gbk
        }
        if normalized.contains("utf") {
            return .utf8
        }
        return nil
    }
}

/// Errors raised while reading a Termius vault.
public enum TermiusVaultError: Error, LocalizedError, Equatable {
    case databaseNotFound(String)
    case keyUnavailable(String)
    case noRecords
    case unsupportedLayout(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let detail):
            return L("没有找到 Termius 的本地数据库。") + detail
        case .keyUnavailable(let detail):
            return L("无法读取 Termius 的本地加密密钥。") + detail
        case .noRecords:
            return L("Termius 数据库里没有可导入的记录。可能还没有登录过任何账号。")
        case .unsupportedLayout(let detail):
            return L("Termius 数据库格式无法识别：") + detail
        }
    }
}

/// Reads and decrypts the local Termius vault (Electron IndexedDB + NaCl secretbox).
public enum TermiusVaultReader {
    /// Directories that may contain a usable Termius IndexedDB store, newest first.
    public static func candidateDirectories() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support/Termius/IndexedDB/file__0.indexeddb.leveldb",
            home + "/Library/Containers/com.termius.mac/Data/Library/Application Support/Termius/IndexedDB/file__0.indexeddb.leveldb",
            home + "/Library/Containers/com.termius.mac/Data/Library/Application Support/Termius/IndexedDB"
        ]
    }

    /// Reads the vault, trying each candidate directory until one decrypts.
    public static func readWithKeychain() throws -> TermiusCatalogue {
        let key = try localKey()
        return try read(key: key)
    }

    /// The 32 byte secretbox key Termius keeps in the login keychain.
    public static func localKey() throws -> [UInt8] {
        if let key = keyFromKeychain() {
            return key
        }
        let message = L("可以在终端执行 security find-generic-password -s Termius -a localKey -w 取出密钥后粘贴到下面的输入框。")
        throw TermiusVaultError.keyUnavailable(message)
    }

    /// Decodes an exported key string (44 characters of base64) into the raw 32 bytes.
    public static func decodeKey(_ text: String) throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        guard let data = Data(base64Encoded: trimmed), data.count == Salsa20Poly1305.keyByteCount else {
            throw TermiusVaultError.keyUnavailable(L("密钥应为 44 个 base64 字符（32 字节），实际长度 ") + String(trimmed.count) + "。")
        }
        return [UInt8](data)
    }

    private static func keyFromKeychain() -> [UInt8]? {
        let services = ["Termius", "Termius Safe Storage", "Termius (MAS)"]
        let accounts = ["localKey", "QClaw Key", "safeStorage"]
        for service in services {
            for account in accounts {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                guard status == errSecSuccess else { continue }
                if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    if let key = try? decodeKey(text) {
                        return key
                    }
                }
            }
        }
        return nil
    }

    /// Decrypts every candidate directory and returns the first catalogue that contains records.
    public static func read(key: [UInt8]) throws -> TermiusCatalogue {
        var firstError: Error?
        var best: TermiusCatalogue?
        for directory in candidateDirectories() {
            do {
                let catalogue = try read(directory: directory, key: key)
                if catalogue.decryptedCount > 0 {
                    if best == nil || catalogue.decryptedCount > (best?.decryptedCount ?? 0) {
                        best = catalogue
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let best, best.decryptedCount > 0, !(best.savedHosts.isEmpty && best.history.isEmpty && best.identities.isEmpty && best.keys.isEmpty && best.knownHosts.isEmpty) {
            return best
        }
        if let best, best.decryptedCount > 0 {
            return best
        }
        if let firstError { throw firstError }
        throw TermiusVaultError.noRecords
    }

    /// Decrypts one specific IndexedDB directory.
    public static func read(directory: String, key: [UInt8]) throws -> TermiusCatalogue {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            throw TermiusVaultError.databaseNotFound(L("路径不存在：") + directory)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let databaseFiles = entries.filter { name in
            let lower = name.lowercased()
            return (lower.hasSuffix(".ldb") || lower.hasSuffix(".log") || lower.hasSuffix(".sst"))
                && !name.hasPrefix("MANIFEST") && !name.hasPrefix("LOG") && !name.hasPrefix("CURRENT") && !name.hasPrefix("LOCK")
        }
        guard !databaseFiles.isEmpty else {
            throw TermiusVaultError.databaseNotFound(L("目录里没有 LevelDB 数据文件：") + directory)
        }
        let manifestPath = directory + "/MANIFEST-000001"
        let manifests = entries.filter { $0.hasPrefix("MANIFEST") }
        let manifest = manifests.isEmpty ? manifestPath : directory + "/" + manifests[0]

        var catalogue = TermiusCatalogue()
        catalogue.sourceDirectory = directory
        catalogue.scannedFiles = databaseFiles.count

        var seenPlaintext = Set<String>()
        var blobs: [[UInt8]] = []
        for name in databaseFiles {
            let path = directory + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            blobs.append(contentsOf: Self.base64Blobs(in: data))
        }
        if let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifest)) {
            blobs.append(contentsOf: Self.base64Blobs(in: manifestData))
        }
        catalogue.ciphertextCount = blobs.count

        for blob in blobs {
            guard let plaintext = Self.plaintext(from: blob, key: key) else { continue }
            catalogue.decryptedCount += 1
            guard seenPlaintext.insert(plaintext).inserted else { continue }
            guard let data = plaintext.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { continue }
            Self.absorb(dictionary, into: &catalogue)
        }
        return catalogue
    }

    private static func absorb(_ dictionary: [String: Any], into catalogue: inout TermiusCatalogue) {
        let label = Self.string(dictionary["label"])
            ?? Self.string(dictionary["title"])
            ?? ""

        if let connectionType = Self.string(dictionary["connection_type"]) {
            guard connectionType.lowercased() == "ssh" else { return }
            guard let host = Self.string(dictionary["host"]), !host.isEmpty else { return }
            let port = Self.int(dictionary["port"]) ?? 22
            let username = Self.string(dictionary["user_name"]).flatMap { $0.isEmpty ? nil : $0 }
            catalogue.history.append(TermiusHistoryEntry(
                host: host,
                port: port == 0 ? 22 : port,
                username: username,
                title: Self.string(dictionary["title"]),
                tags: Self.stringArray(dictionary["tags"]),
                startupCommand: Self.string(dictionary["startup_command"]).flatMap { $0.isEmpty ? nil : $0 },
                charset: Self.string(dictionary["charset"])
            ))
            return
        }

        if let privateKey = Self.string(dictionary["private_key"]), privateKey.contains("BEGIN ") {
            let passphrase = Self.string(dictionary["passphrase"]).flatMap { $0.isEmpty ? nil : $0 }
            catalogue.keys.append(TermiusKey(
                label: label.isEmpty ? "Termius Key" : label,
                privateKeyPEM: privateKey,
                publicKey: Self.string(dictionary["public_key"]),
                passphrase: passphrase
            ))
            return
        }

        if let hostnamesValue = dictionary["hostnames"], let keyBlob = Self.string(dictionary["key"]) {
            let names = Self.stringArray(hostnamesValue)
            let parts = keyBlob.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return }
            catalogue.knownHosts.append(TermiusKnownHost(
                hostnames: names,
                keyType: String(parts[0]),
                base64: String(parts[1])
            ))
            return
        }

        if let script = Self.string(dictionary["script"]) {
            catalogue.snippetLabels.append(label.isEmpty ? script.prefix(24).description : label)
            return
        }

        if let address = Self.string(dictionary["address"]), !address.isEmpty {
            catalogue.savedHosts.append(TermiusSavedHost(
                label: label.isEmpty ? address : label,
                address: address,
                osName: Self.string(dictionary["os_name"])
            ))
            return
        }

        if let username = Self.string(dictionary["username"]), !username.isEmpty {
            let password = Self.string(dictionary["password"]).flatMap { $0.isEmpty ? nil : $0 }
            catalogue.identities.append(TermiusIdentity(
                label: label.isEmpty ? username : label,
                username: username,
                password: password
            ))
            return
        }

        if dictionary["hostname"] != nil, dictionary["port"] != nil, dictionary["type"] != nil {
            return
        }

        if !label.isEmpty, dictionary.count <= 3, dictionary["version"] != nil || dictionary["label"] != nil {
            if !catalogue.groupLabels.contains(label) {
                catalogue.groupLabels.append(label)
            }
        }
    }

    // MARK: - LevelDB helpers

    private static let base64Alphabet: Set<UInt8> = {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        return Set(characters.utf8)
    }()

    static func base64Blobs(in data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        guard bytes.count > 2 else { return [] }
        var results: [[UInt8]] = []
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x42, bytes[index + 1] == 0x41 {
                var end = index + 2
                while end < bytes.count, base64Alphabet.contains(bytes[end]) {
                    end += 1
                }
                let length = end - index
                if length >= 40, let decoded = decodeBase64(bytes[index..<end]) {
                    results.append(decoded)
                }
                index = max(end, index + 2)
            } else {
                index += 1
            }
        }
        return results
    }

    private static func decodeBase64(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        let text = String(decoding: Array(slice), as: UTF8.self)
        if let data = Data(base64Encoded: text) {
            return [UInt8](data)
        }
        let remainder = text.count % 4
        if remainder != 0 {
            let padded = text + String(repeating: "=", count: 4 - remainder)
            if let data = Data(base64Encoded: padded) {
                return [UInt8](data)
            }
        }
        return nil
    }

    static func plaintext(from blob: [UInt8], key: [UInt8]) -> String? {
        guard blob.count > 2 + Salsa20Poly1305.nonceByteCount else { return nil }
        let version = blob[0]
        guard version == 4 || version == 3 else { return nil }
        let nonceStart = 2
        let nonce = Array(blob[nonceStart..<(nonceStart + Salsa20Poly1305.nonceByteCount)])
        let sealed = Array(blob[(nonceStart + Salsa20Poly1305.nonceByteCount)...])
        guard sealed.count >= Salsa20Poly1305.tagByteCount else { return nil }
        guard let message = try? Salsa20Poly1305.open(ciphertext: sealed, nonce: nonce, key: key) else {
            return nil
        }
        guard message.first == 0x7B || message.first == 0x5B else { return nil }
        return String(data: Data(message), encoding: .utf8)
    }

    // MARK: - JSON helpers

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let array = value as? [String] { return array.filter { !$0.isEmpty } }
        if let array = value as? [Any] {
            return array.compactMap { element in
                if let text = element as? String { return text }
                if let dictionary = element as? [String: Any] {
                    return string(dictionary["label"]) ?? string(dictionary["name"]) ?? string(dictionary["title"])
                }
                return nil
            }
        }
        if let text = value as? String, !text.isEmpty {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}
