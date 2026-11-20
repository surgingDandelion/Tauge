import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        case .invalidData:
            return "Keychain returned malformed data"
        }
    }
}

/// Thin wrapper around the generic-password keychain used for legacy migration
/// and explicit keychain-backed callers. The normal app path stores secrets in
/// the encrypted local vault; nothing secret is ever written to the SQLite
/// catalog.
public struct Keychain {
    public static let defaultService = "com.tauge.credentials"

    public let service: String
    /// Whether Security may present the login-keychain authentication sheet.
    ///
    /// The app-local vault is the source of truth for current builds. Its
    /// keychain adapter is non-interactive so a stale legacy item can never
    /// interrupt startup or reconnects with a password prompt after a rebuild.
    public let allowsAuthenticationUI: Bool

    public init(service: String = Keychain.defaultService, allowsAuthenticationUI: Bool = true) {
        self.service = service
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    private func applyAuthenticationPolicy(to query: inout [String: Any]) {
        guard !allowsAuthenticationUI else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // Keep the Security-level fail-fast policy as well. The context covers
        // modern authentication flows; this flag explicitly rejects any
        // legacy path that would otherwise present an authorization sheet.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        applyAuthenticationPolicy(to: &query)
        return query
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.invalidData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func string(for account: String) throws -> String? {
        guard let data = try data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ data: Data?, for account: String) throws {
        guard let data else {
            try remove(account)
            return
        }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func setString(_ value: String?, for account: String) throws {
        try set(value?.data(using: .utf8), for: account)
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func accounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        applyAuthenticationPolicy(to: &query)
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let array = items as? [[String: Any]] else { return [] }
            return array.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
