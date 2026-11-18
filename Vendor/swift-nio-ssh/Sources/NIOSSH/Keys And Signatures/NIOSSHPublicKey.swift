//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat

/// An SSH public key.
///
/// This object identifies a single SSH server or user. It is used as part of the SSH handshake and key exchange process,
/// is presented to clients that want to validate that they are communicating with the appropriate server, and is also used
/// to validate users.
///
/// This key is not capable of signing, only verifying.
public struct NIOSSHPublicKey: Sendable, Hashable {
    /// The actual key structure used to perform the key operations.
    internal var backingKey: BackingKey

    internal init(backingKey: BackingKey) {
        self.backingKey = backingKey
    }

    /// Create a ``NIOSSHPublicKey`` from the OpenSSH public key string.
    public init(openSSHPublicKey: String) throws {
        // The OpenSSH public key format is like this: "algorithm-id base64-encoded-key comments"
        //
        // We split on spaces, no more than twice. We then check if we know about the algorithm identifier and, if we
        // do, we parse the key.
        var components = ArraySlice(
            openSSHPublicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        )
        guard let keyIdentifier = components.popFirst(), let keyData = components.popFirst() else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "invalid number of sections")
        }
        guard let rawBytes = Data(base64Encoded: String(keyData)) else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "could not base64-decode string")
        }

        var buffer = ByteBufferAllocator().buffer(capacity: rawBytes.count)
        buffer.writeContiguousBytes(rawBytes)
        guard let key = try buffer.readSSHHostKey() else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "incomplete key data")
        }
        guard key.keyPrefix.elementsEqual(keyIdentifier.utf8) else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "inconsistent key type within openssh key format")
        }
        self = key
    }

    /// Encapsulate a ``NIOSSHCertifiedPublicKey`` in a ``NIOSSHPublicKey``.
    ///
    /// This initializer can be used to "wrap" a ``NIOSSHCertifiedPublicKey`` into the interface of ``NIOSSHPublicKey``.
    /// It is typically used in cases where the fact that the key is certified is not relevant.
    public init(_ certifiedKey: NIOSSHCertifiedPublicKey) {
        self.backingKey = .certified(certifiedKey)
    }
}

extension NIOSSHPublicKey {
    /// Verifies that a given `NIOSSHSignature` was created by the holder of the private key associated with this
    /// public key.
    internal func isValidSignature<DigestBytes: Digest>(_ signature: NIOSSHSignature, for digest: DigestBytes) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                switch sig {
                case .byteBuffer(let buf):
                    return key.isValidSignature(buf.readableBytesView, for: digestPtr)
                case .data(let d):
                    return key.isValidSignature(d, for: digestPtr)
                }
            }
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: digest)
        case (.rsa, .rsa(let sig, let algorithm)):
            #if canImport(Security)
            let digestBytes = digest.withUnsafeBytes { Data($0) }
            return self.isValidRSASignature(sig, algorithm: algorithm, forDigest: digestBytes)
            #else
            return false
            #endif
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false
        }
    }

    internal func isValidSignature(_ signature: NIOSSHSignature, for bytes: ByteBuffer) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(.byteBuffer(let buf))):
            return key.isValidSignature(buf.readableBytesView, for: bytes.readableBytesView)
        case (.ed25519(let key), .ed25519(.data(let buf))):
            return key.isValidSignature(buf, for: bytes.readableBytesView)
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: bytes)
        case (.rsa, .rsa(let sig, let algorithm)):
            #if canImport(Security)
            return self.isValidRSASignature(sig, algorithm: algorithm, for: Data(bytes.readableBytesView))
            #else
            return false
            #endif
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false
        }
    }

    internal func isValidSignature(_ signature: NIOSSHSignature, for payload: UserAuthSignablePayload) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(.byteBuffer(let sig))):
            return key.isValidSignature(sig.readableBytesView, for: payload.bytes.readableBytesView)
        case (.ed25519(let key), .ed25519(.data(let sig))):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: payload)
        case (.rsa, .rsa(let sig, let algorithm)):
            #if canImport(Security)
            return self.isValidRSASignature(sig, algorithm: algorithm, for: Data(payload.bytes.readableBytesView))
            #else
            return false
            #endif
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false
        }
    }
}

// swift-format-ignore: DontRepeatTypeInStaticProperties
extension NIOSSHPublicKey {
    /// The various key types that can be used with NIOSSH.
    internal enum BackingKey {
        case ed25519(Curve25519.Signing.PublicKey)
        case ecdsaP256(P256.Signing.PublicKey)
        case ecdsaP384(P384.Signing.PublicKey)
        case ecdsaP521(P521.Signing.PublicKey)
        case certified(NIOSSHCertifiedPublicKey)  // This case recursively contains `NIOSSHPublicKey`.

        /// An RSA public key used with the RFC 8332 signature algorithms.
        case rsa(modulus: Data, exponent: Data, algorithm: NIOSSHRSASignatureAlgorithm)
    }

    /// The prefix of an Ed25519 public key.
    internal static let ed25519PublicKeyPrefix = "ssh-ed25519".utf8

    /// The prefix of a P256 ECDSA public key.
    internal static let ecdsaP256PublicKeyPrefix = "ecdsa-sha2-nistp256".utf8

    /// The prefix of a P384 ECDSA public key.
    internal static let ecdsaP384PublicKeyPrefix = "ecdsa-sha2-nistp384".utf8

    /// The prefix of a P521 ECDSA public key.
    internal static let ecdsaP521PublicKeyPrefix = "ecdsa-sha2-nistp521".utf8

    /// The public key format identifier of an RSA public key.
    internal static let rsaPublicKeyPrefix = "ssh-rsa".utf8

    internal var keyPrefix: String.UTF8View {
        switch self.backingKey {
        case .ed25519:
            return Self.ed25519PublicKeyPrefix
        case .ecdsaP256:
            return Self.ecdsaP256PublicKeyPrefix
        case .ecdsaP384:
            return Self.ecdsaP384PublicKeyPrefix
        case .ecdsaP521:
            return Self.ecdsaP521PublicKeyPrefix
        case .certified(let base):
            return base.keyPrefix
        case .rsa:
            return Self.rsaPublicKeyPrefix
        }
    }

    /// Whether this is an RSA public key.
    internal var isRSA: Bool {
        if case .rsa = self.backingKey {
            return true
        }
        return false
    }

    /// The public key algorithm name to advertise in user authentication requests.
    ///
    /// RFC 8332 keeps the "ssh-rsa" public key format, but the "public key algorithm name" field of
    /// SSH_MSG_USERAUTH_REQUEST carries "rsa-sha2-256"/"rsa-sha2-512" when those signature
    /// algorithms are used.
    internal var userAuthAlgorithmName: String.UTF8View {
        switch self.backingKey {
        case .rsa(_, _, let algorithm):
            return algorithm.rawValue.utf8
        default:
            return self.keyPrefix
        }
    }

    /// Whether `algorithmName` from a USERAUTH_REQUEST is consistent with this key.
    internal func matchesUserAuthAlgorithmName<Bytes: Collection>(_ algorithmName: Bytes) -> Bool
    where Bytes.Element == UInt8 {
        if algorithmName.elementsEqual(self.keyPrefix) {
            return true
        }
        return self.isRSA && NIOSSHRSASignatureAlgorithm.from(name: algorithmName) != nil
    }

    /// Returns a copy of this key that carries `algorithmName` for user authentication.
    ///
    /// The public key blob itself does not encode which RFC 8332 signature algorithm the peer
    /// intends to use, so the server must re-attach the name from the request before rebuilding
    /// the signed payload (otherwise rsa-sha2-512 requests would be verified as rsa-sha2-256).
    internal func stampingUserAuthAlgorithmName<Bytes: Collection>(_ algorithmName: Bytes) -> NIOSSHPublicKey
    where Bytes.Element == UInt8 {
        guard case .rsa(let modulus, let exponent, _) = self.backingKey,
            let algorithm = NIOSSHRSASignatureAlgorithm.from(name: algorithmName)
        else {
            return self
        }
        return NIOSSHPublicKey(backingKey: .rsa(modulus: modulus, exponent: exponent, algorithm: algorithm))
    }

    /// Whether a USERAUTH_REQUEST public key algorithm name is one we know about.
    internal static func isKnownUserAuthAlgorithm<Bytes: Collection>(_ algorithmName: Bytes) -> Bool
    where Bytes.Element == UInt8 {
        if Self.knownAlgorithms.contains(where: { $0.elementsEqual(algorithmName) }) {
            return true
        }
        return NIOSSHRSASignatureAlgorithm.from(name: algorithmName) != nil
    }

    internal static var knownAlgorithms: [String.UTF8View] {
        [
            Self.ed25519PublicKeyPrefix, Self.ecdsaP384PublicKeyPrefix, Self.ecdsaP256PublicKeyPrefix,
            Self.ecdsaP521PublicKeyPrefix, Self.rsaPublicKeyPrefix,
        ]
    }
}

extension NIOSSHPublicKey.BackingKey: Equatable {
    static func == (lhs: NIOSSHPublicKey.BackingKey, rhs: NIOSSHPublicKey.BackingKey) -> Bool {
        // We implement equatable in terms of the key representation.
        switch (lhs, rhs) {
        case (.ed25519(let lhs), .ed25519(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP256(let lhs), .ecdsaP256(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP384(let lhs), .ecdsaP384(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP521(let lhs), .ecdsaP521(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.certified(let lhs), .certified(let rhs)):
            return lhs == rhs
        case (
            .rsa(let lhsModulus, let lhsExponent, _), .rsa(let rhsModulus, let rhsExponent, _)
        ):
            return lhsModulus == rhsModulus && lhsExponent == rhsExponent
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.certified, _),
            (.rsa, _):
            return false
        }
    }
}

extension NIOSSHPublicKey.BackingKey: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .ed25519(let pkey):
            hasher.combine(1)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP256(let pkey):
            hasher.combine(2)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP384(let pkey):
            hasher.combine(3)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP521(let pkey):
            hasher.combine(4)
            hasher.combine(pkey.rawRepresentation)
        case .certified(let pkey):
            hasher.combine(5)
            hasher.combine(pkey)
        case .rsa(let modulus, let exponent, _):
            hasher.combine(6)
            hasher.combine(modulus)
            hasher.combine(exponent)
        }
    }
}

extension ByteBuffer {
    /// Writes an SSH host key to this `ByteBuffer`.
    @discardableResult
    mutating func writeSSHHostKey(_ key: NIOSSHPublicKey) -> Int {
        var writtenBytes = 0

        switch key.backingKey {
        case .ed25519(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ed25519PublicKeyPrefix)
            writtenBytes += self.writeEd25519PublicKey(baseKey: key)
        case .ecdsaP256(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP256PublicKeyPrefix)
            writtenBytes += self.writeECDSAP256PublicKey(baseKey: key)
        case .ecdsaP384(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP384PublicKeyPrefix)
            writtenBytes += self.writeECDSAP384PublicKey(baseKey: key)
        case .ecdsaP521(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix)
            writtenBytes += self.writeECDSAP521PublicKey(baseKey: key)
        case .certified(let key):
            return self.writeCertifiedKey(key)
        case .rsa(let modulus, let exponent, _):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.rsaPublicKeyPrefix)
            writtenBytes += self.writeRSAPublicKey(modulus: modulus, exponent: exponent)
        }

        return writtenBytes
    }

    /// Writes an SSH host key to this `ByteBuffer`, without a prefix.
    ///
    /// This is mostly used as part of the certified key structure.
    @discardableResult
    mutating func writePublicKeyWithoutPrefix(_ key: NIOSSHPublicKey) -> Int {
        switch key.backingKey {
        case .ed25519(let key):
            return self.writeEd25519PublicKey(baseKey: key)
        case .ecdsaP256(let key):
            return self.writeECDSAP256PublicKey(baseKey: key)
        case .ecdsaP384(let key):
            return self.writeECDSAP384PublicKey(baseKey: key)
        case .ecdsaP521(let key):
            return self.writeECDSAP521PublicKey(baseKey: key)
        case .certified:
            preconditionFailure("Certified keys are the only callers of this method, and cannot contain themselves")
        case .rsa(let modulus, let exponent, _):
            return self.writeRSAPublicKey(modulus: modulus, exponent: exponent)
        }
    }

    mutating func readSSHHostKey() throws -> NIOSSHPublicKey? {
        try self.rewindOnNilOrError { buffer in
            // The wire format always begins with an SSH string containing the key format identifier. Let's grab that.
            guard let keyIdentifierBytes = buffer.readSSHString() else {
                return nil
            }

            // Now we need to check if they match our supported key algorithms.
            return try buffer.readPublicKeyWithoutPrefixForIdentifier(keyIdentifierBytes.readableBytesView)
        }
    }

    mutating func readPublicKeyWithoutPrefixForIdentifier<Bytes: Collection>(
        _ keyIdentifierBytes: Bytes
    ) throws -> NIOSSHPublicKey? where Bytes.Element == UInt8 {
        try self.rewindOnNilOrError { buffer in
            if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ed25519PublicKeyPrefix) {
                return try buffer.readEd25519PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP256PublicKeyPrefix) {
                return try buffer.readECDSAP256PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP384PublicKeyPrefix) {
                return try buffer.readECDSAP384PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix) {
                return try buffer.readECDSAP521PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.rsaPublicKeyPrefix)
                || NIOSSHRSASignatureAlgorithm.from(name: keyIdentifierBytes) != nil
            {
                // RFC 8332: the key format is always "ssh-rsa", but the algorithm name in a user
                // auth request may be "rsa-sha2-256"/"rsa-sha2-512".
                return try buffer.readRSAPublicKey()
            } else {
                // We don't know this public key type. Maybe the certified keys do.
                return try buffer.readCertifiedKeyWithoutKeyPrefix(keyIdentifierBytes).map(NIOSSHPublicKey.init)
            }
        }
    }

    private mutating func writeEd25519PublicKey(baseKey: Curve25519.Signing.PublicKey) -> Int {
        // For Ed25519 the key format is  Q as a String.
        self.writeSSHString(baseKey.rawRepresentation)
    }

    private mutating func writeECDSAP256PublicKey(baseKey: P256.Signing.PublicKey) -> Int {
        // For ECDSA-P256, the key format is the string "nistp256", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp256".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    private mutating func writeECDSAP384PublicKey(baseKey: P384.Signing.PublicKey) -> Int {
        // For ECDSA-P384, the key format is the string "nistp384", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp384".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    private mutating func writeECDSAP521PublicKey(baseKey: P521.Signing.PublicKey) -> Int {
        // For ECDSA-P521, the key format is the string "nistp521", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp521".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    private mutating func writeRSAPublicKey(modulus: Data, exponent: Data) -> Int {
        // For RSA the key format is `mpint e` followed by `mpint n`.
        var writtenBytes = 0
        writtenBytes += self.writePositiveMPInt(exponent)
        writtenBytes += self.writePositiveMPInt(modulus)
        return writtenBytes
    }

    /// A helper function that reads an RSA public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readRSAPublicKey() throws -> NIOSSHPublicKey? {
        // For RSA the key format is `mpint e` followed by `mpint n`.
        guard let exponentBytes = self.readSSHString(), let modulusBytes = self.readSSHString() else {
            return nil
        }

        // The signature algorithm is only used for signing, so the default is fine here: verification
        // uses the algorithm carried by the signature itself.
        return NIOSSHPublicKey(
            backingKey: .rsa(
                modulus: Data(modulusBytes.readableBytesView),
                exponent: Data(exponentBytes.readableBytesView),
                algorithm: .rsaSHA2_256
            )
        )
    }

    /// A helper function that reads an Ed25519 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readEd25519PublicKey() throws -> NIOSSHPublicKey? {
        // For ed25519 the key format is just Q encoded as a String.
        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try Curve25519.Signing.PublicKey(rawRepresentation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ed25519(key))
    }

    /// A helper function that reads an ECDSA P-256 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP256PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P256, the key format is the string "nistp256" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp256".utf8) else {
            let unexpectedParameter =
                domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P256.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP256(key))
    }

    /// A helper function that reads an ECDSA P-384 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP384PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P384, the key format is the string "nistp384" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp384".utf8) else {
            let unexpectedParameter =
                domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P384.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP384(key))
    }

    /// A helper function that reads an ECDSA P-521 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP521PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P521, the key format is the string "nistp521" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp521".utf8) else {
            let unexpectedParameter =
                domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P521.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP521(key))
    }

    /// A helper function for complex readers that will reset a buffer on nil or on error, as though the read
    /// never occurred.
    internal mutating func rewindOnNilOrError<T>(_ body: (inout ByteBuffer) throws -> T?) rethrows -> T? {
        let originalSelf = self

        let returnValue: T?
        do {
            returnValue = try body(&self)
        } catch {
            self = originalSelf
            throw error
        }

        if returnValue == nil {
            self = originalSelf
        }

        return returnValue
    }
}

extension String {
    /// Takes a NIOSSHPublicKey and turns it into OpenSSH public key string in the format of "algorithm-id base64-encoded-key"
    public init(openSSHPublicKey: NIOSSHPublicKey) {
        var buffer = ByteBuffer()
        buffer.writeSSHHostKey(openSSHPublicKey)
        let next = Data(buffer.readableBytesView).base64EncodedString()
        let publicKeyString = String(openSSHPublicKey.keyPrefix) + " " + next
        self = publicKeyString
    }
}
