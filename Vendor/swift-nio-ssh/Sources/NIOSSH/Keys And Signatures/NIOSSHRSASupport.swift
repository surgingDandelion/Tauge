//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// RSA (rsa-sha2-256 / rsa-sha2-512) user authentication, as defined by RFC 8332.
//
// This file is a ShellX addition: upstream swift-nio-ssh only implements Ed25519
// and ECDSA keys. RFC 8332 keeps the "ssh-rsa" public key format unchanged and
// only adds new signature algorithm names, so everything here is layered on top
// of the existing key encoding.
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore

/// The RSA signature algorithms defined by RFC 8332.
public enum NIOSSHRSASignatureAlgorithm: String, Sendable, Hashable, CaseIterable {
    /// RSA with PKCS#1 v1.5 padding and a SHA-256 digest.
    case rsaSHA2_256 = "rsa-sha2-256"

    /// RSA with PKCS#1 v1.5 padding and a SHA-512 digest.
    case rsaSHA2_512 = "rsa-sha2-512"

    /// The public key format identifier shared by every RSA key.
    public static let publicKeyFormatName = "ssh-rsa"

    /// The number of digest bytes this algorithm signs.
    internal var digestByteCount: Int {
        switch self {
        case .rsaSHA2_256:
            return 32
        case .rsaSHA2_512:
            return 64
        }
    }

    /// The algorithm matching a raw digest of the given length, if any.
    internal static func forDigestLength(_ length: Int) -> NIOSSHRSASignatureAlgorithm? {
        switch length {
        case 32:
            return .rsaSHA2_256
        case 64:
            return .rsaSHA2_512
        default:
            return nil
        }
    }

    /// Parses an RSA signature algorithm name.
    internal static func from<Bytes: Collection>(name: Bytes) -> NIOSSHRSASignatureAlgorithm? where Bytes.Element == UInt8 {
        for algorithm in NIOSSHRSASignatureAlgorithm.allCases where name.elementsEqual(algorithm.rawValue.utf8) {
            return algorithm
        }
        return nil
    }
}

/// Builds the PKCS#1 `RSAPrivateKey` structure that `Security.framework` (and most other
/// crypto stacks) expect when importing an RSA private key from OpenSSH key material.
public enum NIOSSHRSAPrivateKeyDER {
    public static func make(
        modulus: Data,
        exponent: Data,
        privateExponent: Data,
        prime1: Data,
        prime2: Data,
        exponent1: Data,
        exponent2: Data,
        coefficient: Data
    ) -> Data {
        var contents: [UInt8] = []
        contents += NIOSSHRSADER.encodeInteger(Data([0]))
        contents += NIOSSHRSADER.encodeInteger(modulus)
        contents += NIOSSHRSADER.encodeInteger(exponent)
        contents += NIOSSHRSADER.encodeInteger(privateExponent)
        contents += NIOSSHRSADER.encodeInteger(prime1)
        contents += NIOSSHRSADER.encodeInteger(prime2)
        contents += NIOSSHRSADER.encodeInteger(exponent1)
        contents += NIOSSHRSADER.encodeInteger(exponent2)
        contents += NIOSSHRSADER.encodeInteger(coefficient)
        return Data(NIOSSHRSADER.encodeSequence(contents))
    }
}

/// Minimal ASN.1 DER support for the key blobs `Security.framework` consumes and produces.
internal enum NIOSSHRSADER {
    /// Strips the leading zero bytes of a big-endian unsigned integer.
    static func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var index = 0
        while index < bytes.count && bytes[index] == 0 {
            index += 1
        }
        return Array(bytes[index...])
    }

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: value), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// Encodes a non-negative integer as an ASN.1 INTEGER.
    static func encodeInteger(_ value: Data) -> [UInt8] {
        var bytes = stripLeadingZeros([UInt8](value))
        if bytes.isEmpty {
            bytes = [0]
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return [0x02] + encodeLength(bytes.count) + bytes
    }

    static func encodeSequence(_ contents: [UInt8]) -> [UInt8] {
        [0x30] + encodeLength(contents.count) + contents
    }

    /// Wraps a raw RSA public key in the PKCS#1 `RSAPublicKey` structure.
    static func wrapPublicKey(modulus: Data, exponent: Data) -> Data {
        Data(encodeSequence(encodeInteger(modulus) + encodeInteger(exponent)))
    }

    /// Parses a PKCS#1 `RSAPublicKey` structure into its modulus and exponent.
    static func parseRSAPublicKey(_ der: Data) -> (modulus: Data, exponent: Data)? {
        let bytes = [UInt8](der)
        var index = 0
        guard let outer = self.readElement(bytes, index: &index, end: bytes.count), outer.tag == 0x30 else {
            return nil
        }

        var contentsIndex = 0
        guard
            let modulus = self.readElement(outer.contents, index: &contentsIndex, end: outer.contents.count),
            modulus.tag == 0x02,
            let exponent = self.readElement(outer.contents, index: &contentsIndex, end: outer.contents.count),
            exponent.tag == 0x02
        else {
            return nil
        }

        return (Data(stripLeadingZeros(modulus.contents)), Data(stripLeadingZeros(exponent.contents)))
    }

    private static func readElement(_ bytes: [UInt8], index: inout Int, end: Int) -> (tag: UInt8, contents: [UInt8])? {
        guard index < end else {
            return nil
        }
        let tag = bytes[index]
        index += 1

        guard index < end else {
            return nil
        }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount > 0, byteCount <= 8, index + byteCount <= end else {
                return nil
            }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }

        guard length >= 0, index + length <= end else {
            return nil
        }
        let contents = Array(bytes[index..<(index + length)])
        index += length
        return (tag, contents)
    }
}

#if canImport(Security)

@preconcurrency import Security

extension NIOSSHRSASignatureAlgorithm {
    /// The `Security` signature algorithm for signing an already-computed digest.
    internal var digestSignatureAlgorithm: SecKeyAlgorithm {
        switch self {
        case .rsaSHA2_256:
            return .rsaSignatureDigestPKCS1v15SHA256
        case .rsaSHA2_512:
            return .rsaSignatureDigestPKCS1v15SHA512
        }
    }

    /// The `Security` signature algorithm for signing a message (hashing it internally).
    internal var messageSignatureAlgorithm: SecKeyAlgorithm {
        switch self {
        case .rsaSHA2_256:
            return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaSHA2_512:
            return .rsaSignatureMessagePKCS1v15SHA512
        }
    }
}

/// A wrapper that lets us store a `SecKey` inside the `Sendable` `NIOSSHPrivateKey`.
public final class NIOSSHRSAPrivateKeyBox: @unchecked Sendable {
    public let key: SecKey

    public init(key: SecKey) {
        self.key = key
    }

    /// Creates a private key box from a PKCS#1 `RSAPrivateKey` DER structure.
    public static func makePrivateKey(pkcs1DER: Data) throws -> NIOSSHRSAPrivateKeyBox {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &error) else {
            let reason = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw NIOSSHError.rsaSignatureFailure(reason: "could not create RSA private key: \(reason)")
        }
        return NIOSSHRSAPrivateKeyBox(key: key)
    }

    internal func signature(for data: Data, algorithm: NIOSSHRSASignatureAlgorithm) throws -> Data {
        try self.signature(for: data, using: algorithm.messageSignatureAlgorithm)
    }

    internal func signature(forDigest digest: Data, algorithm: NIOSSHRSASignatureAlgorithm) throws -> Data {
        try self.signature(for: digest, using: algorithm.digestSignatureAlgorithm)
    }

    private func signature(for data: Data, using secAlgorithm: SecKeyAlgorithm) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(self.key, secAlgorithm, data as CFData, &error) else {
            let reason = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw NIOSSHError.rsaSignatureFailure(reason: reason)
        }
        return signature as Data
    }
}

extension NIOSSHPrivateKey {
    /// Creates a private key from an RSA private key provided by `Security`.
    public init(rsaKey key: SecKey, algorithm: NIOSSHRSASignatureAlgorithm = .rsaSHA2_256) {
        self.init(backingKey: .rsa(NIOSSHRSAPrivateKeyBox(key: key), algorithm))
    }

    /// Creates a private key from a PKCS#1 `RSAPrivateKey` DER structure.
    public init(rsaPrivateKeyDER: Data, algorithm: NIOSSHRSASignatureAlgorithm = .rsaSHA2_256) throws {
        let box = try NIOSSHRSAPrivateKeyBox.makePrivateKey(pkcs1DER: rsaPrivateKeyDER)
        self.init(backingKey: .rsa(box, algorithm))
    }

    /// The RSA signature algorithm this key signs with, or nil for non-RSA keys.
    public var rsaSignatureAlgorithm: NIOSSHRSASignatureAlgorithm? {
        if case .rsa(_, let algorithm) = self.backingKey {
            return algorithm
        }
        return nil
    }

    /// A copy of this RSA key that signs with `algorithm`, or nil for non-RSA keys.
    public func withRSASignatureAlgorithm(_ algorithm: NIOSSHRSASignatureAlgorithm) -> NIOSSHPrivateKey? {
        guard case .rsa(let box, _) = self.backingKey else {
            return nil
        }
        return NIOSSHPrivateKey(backingKey: .rsa(box, algorithm))
    }

    /// Derives the RSA public key for a `SecKey` private key.
    internal static func rsaPublicKey(
        for key: SecKey,
        algorithm: NIOSSHRSASignatureAlgorithm
    ) -> NIOSSHPublicKey {
        guard let publicKey = SecKeyCopyPublicKey(key),
            let rawData = SecKeyCopyExternalRepresentation(publicKey, nil),
            let parsed = NIOSSHRSADER.parseRSAPublicKey(rawData as Data)
        else {
            preconditionFailure("Could not derive the RSA public key from the private key")
        }

        return NIOSSHPublicKey(
            backingKey: .rsa(modulus: parsed.modulus, exponent: parsed.exponent, algorithm: algorithm)
        )
    }
}

extension NIOSSHPublicKey {
    /// The `SecKey` for this RSA public key, or nil for non-RSA keys.
    internal func rsaSecKey() -> SecKey? {
        guard case .rsa(let modulus, let exponent, _) = self.backingKey else {
            return nil
        }
        let der = NIOSSHRSADER.wrapPublicKey(modulus: modulus, exponent: exponent)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
    }

    /// Verifies an RSA signature over a message.
    internal func isValidRSASignature(
        _ signature: Data,
        algorithm: NIOSSHRSASignatureAlgorithm,
        for data: Data
    ) -> Bool {
        guard let key = self.rsaSecKey() else {
            return false
        }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key,
            algorithm.messageSignatureAlgorithm,
            data as CFData,
            signature as CFData,
            &error
        )
    }

    /// Verifies an RSA signature over an already-computed digest.
    internal func isValidRSASignature(
        _ signature: Data,
        algorithm: NIOSSHRSASignatureAlgorithm,
        forDigest digest: Data
    ) -> Bool {
        guard let key = self.rsaSecKey() else {
            return false
        }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key,
            algorithm.digestSignatureAlgorithm,
            digest as CFData,
            signature as CFData,
            &error
        )
    }
}

#endif
