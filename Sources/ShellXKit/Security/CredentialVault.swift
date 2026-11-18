import Foundation
import CryptoKit
import CommonCrypto

public enum VaultError: Error, LocalizedError, Equatable {
    case passwordTooShort(minimum: Int)
    case unsupportedVersion(Int)
    case derivationFailed(Int32)
    case decryptionFailed
    case malformed

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort(let minimum):
            return "Password must be at least \(minimum) characters"
        case .unsupportedVersion(let version):
            return "Unsupported vault version \(version)"
        case .derivationFailed(let status):
            return "Key derivation failed (\(status))"
        case .decryptionFailed:
            return "Unable to decrypt: wrong password or corrupted file"
        case .malformed:
            return "Encrypted payload is malformed"
        }
    }
}

/// Versioned AES-256-GCM container used for exporting hosts with credentials.
/// The key comes from PBKDF2-HMAC-SHA256 so a shared export can be protected by
/// a passphrase rather than the machine keychain.
public struct SealedBox: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let kdfName = "pbkdf2-hmac-sha256"

    public var version: Int
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data

    public init(version: Int = SealedBox.currentVersion,
                kdf: String = SealedBox.kdfName,
                iterations: Int,
                salt: Data,
                nonce: Data,
                ciphertext: Data,
                tag: Data) {
        self.version = version
        self.kdf = kdf
        self.iterations = iterations
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SealedBox {
        do {
            return try JSONDecoder().decode(SealedBox.self, from: data)
        } catch {
            throw VaultError.malformed
        }
    }
}

public enum CredentialVault {
    public static let defaultIterations = 210_000
    public static let minimumPasswordLength = 8

    public static func seal(_ plaintext: Data,
                            password: String,
                            iterations: Int = CredentialVault.defaultIterations,
                            additionalData: Data? = nil) throws -> SealedBox {
        guard password.count >= minimumPasswordLength else {
            throw VaultError.passwordTooShort(minimum: minimumPasswordLength)
        }
        let salt = randomBytes(count: 16)
        let symmetricKey = try deriveKey(password: password, salt: salt, iterations: iterations)
        let aad = additionalData ?? Data("shellx-export-v1".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad)
        return SealedBox(iterations: iterations,
                         salt: salt,
                         nonce: Data(sealed.nonce),
                         ciphertext: sealed.ciphertext,
                         tag: sealed.tag)
    }

    public static func open(_ box: SealedBox,
                            password: String,
                            additionalData: Data? = nil) throws -> Data {
        guard box.version == SealedBox.currentVersion else {
            throw VaultError.unsupportedVersion(box.version)
        }
        guard box.kdf == SealedBox.kdfName else { throw VaultError.malformed }
        let symmetricKey = try deriveKey(password: password, salt: box.salt, iterations: box.iterations)
        let aad = additionalData ?? Data("shellx-export-v1".utf8)
        do {
            let nonce = try AES.GCM.Nonce(data: box.nonce)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: box.ciphertext, tag: box.tag)
            return try AES.GCM.open(sealed, using: symmetricKey, authenticating: aad)
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    public static func deriveKey(password: String,
                                 salt: Data,
                                 iterations: Int) throws -> SymmetricKey {
        guard !salt.isEmpty else { throw VaultError.malformed }
        guard iterations > 0 else { throw VaultError.malformed }
        var derived = Data(count: 32)
        let passwordChars = Array(password.utf8CString)
        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                let saltPointer = saltBytes.bindMemory(to: UInt8.self).baseAddress
                return passwordChars.withUnsafeBufferPointer { passwordBuffer -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBuffer.baseAddress,
                                         passwordChars.count - 1,
                                         saltPointer,
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations),
                                         output.bindMemory(to: UInt8.self).baseAddress,
                                         output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.derivationFailed(status) }
        return SymmetricKey(data: derived)
    }

    public static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in 0..<count { bytes[index] = UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes)
    }
}
