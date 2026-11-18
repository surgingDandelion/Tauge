import Foundation
import Crypto
import NIOSSH

public enum SSHKeyError: Error, LocalizedError {
    case fileNotFound(String)
    case unsupported(String)
    case encrypted
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "找不到私钥文件：" + path
        case .unsupported(let message):
            return message
        case .encrypted:
            return "私钥已加密，请输入私钥口令。"
        case .malformed(let message):
            return "私钥格式无法解析：" + message
        }
    }
}

public struct ParsedPrivateKey: Sendable {
    public let key: NIOSSHPrivateKey
    public let keyType: String
    public let comment: String?
    public let publicKeyOpenSSH: String
}

/// Parses OpenSSH private keys (openssh-key-v1) and PEM PKCS#1 / PKCS#8 / SEC1 keys for
/// Ed25519, ECDSA P-256/P-384/P-521 and RSA keys.
///
/// RSA keys are used for user authentication with the RFC 8332 signature algorithms
/// (`rsa-sha2-256` / `rsa-sha2-512`); the legacy `ssh-rsa` (SHA-1) signature is never used.
public enum SSHKeyParser {
    public static func parse(
        path: String,
        passphrase: String? = nil,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm = .rsaSHA2_512
    ) throws -> ParsedPrivateKey {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SSHKeyError.fileNotFound(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SSHKeyError.fileNotFound(path)
        }
        return try parse(data: data, passphrase: passphrase, rsaAlgorithm: rsaAlgorithm)
    }

    public static func parse(
        data: Data,
        passphrase: String? = nil,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm = .rsaSHA2_512
    ) throws -> ParsedPrivateKey {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN ") else {
            throw SSHKeyError.malformed("不是 PEM 或 OpenSSH 私钥")
        }
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(text: text, passphrase: passphrase, rsaAlgorithm: rsaAlgorithm)
        }
        if text.contains("BEGIN RSA PRIVATE KEY") {
            return try parsePKCS1(text: text, rsaAlgorithm: rsaAlgorithm)
        }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw SSHKeyError.encrypted
        }
        if text.contains("BEGIN PRIVATE KEY") {
            return try parsePKCS8(text: text, rsaAlgorithm: rsaAlgorithm)
        }
        if text.contains("BEGIN EC PRIVATE KEY") {
            return try parseSEC1(text: text)
        }
        throw SSHKeyError.unsupported("不支持的私钥格式，仅支持 OpenSSH 格式与 PEM（Ed25519 / ECDSA / RSA）。")
    }

    // MARK: - OpenSSH container

    private static func parseOpenSSH(
        text: String,
        passphrase: String?,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm
    ) throws -> ParsedPrivateKey {
        var reader = SSHKeyByteReader(bytes: try base64Body(text, label: "OPENSSH PRIVATE KEY"))
        let magic = "openssh-key-v1"
        let magicBytes = try reader.readBytes(magic.utf8.count)
        guard String(bytes: magicBytes, encoding: .utf8) == magic else {
            throw SSHKeyError.malformed("缺少 openssh-key-v1 标识")
        }
        _ = try reader.readBytes(1)
        let cipherName = try reader.readUTF8String()
        _ = try reader.readUTF8String()
        _ = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount >= 1 else { throw SSHKeyError.malformed("私钥不包含任何密钥") }
        var firstPublicBlob = [UInt8]()
        for index in 0..<Int(keyCount) {
            let blob = try reader.readString()
            if index == 0 { firstPublicBlob = blob }
        }
        guard cipherName == "none" else {
            if passphrase == nil { throw SSHKeyError.encrypted }
            throw SSHKeyError.unsupported("暂不支持带口令的 OpenSSH 私钥，请使用 ssh-keygen -p -N \"\" -f <keyfile> 移除口令，或改用未加密密钥。")
        }
        let privateSection = try reader.readString()
        var keyReader = SSHKeyByteReader(bytes: privateSection)
        _ = try keyReader.readUInt32()
        _ = try keyReader.readUInt32()
        let keyType = try keyReader.readUTF8String()
        switch keyType {
        case "ssh-ed25519":
            _ = try keyReader.readString()
            let privateBlob = try keyReader.readString()
            let comment = try? keyReader.readUTF8String()
            guard privateBlob.count >= 64 else { throw SSHKeyError.malformed("Ed25519 私钥长度不正确") }
            let seed = Data(privateBlob.prefix(32))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return try finish(key: NIOSSHPrivateKey(ed25519Key: key), keyType: keyType, comment: comment)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try keyReader.readString()
            _ = try keyReader.readString()
            let scalar = try keyReader.readString()
            let comment = try? keyReader.readUTF8String()
            return try makeECDSAKey(keyType: keyType, scalar: scalar, comment: comment)
        case "ssh-rsa":
            let modulus = try keyReader.readString()
            let exponent = try keyReader.readString()
            let privateExponent = try keyReader.readString()
            let coefficient = try keyReader.readString()
            let prime1 = try keyReader.readString()
            let prime2 = try keyReader.readString()
            let comment = try? keyReader.readUTF8String()
            let parsed = try makeRSAKey(
                modulus: modulus,
                exponent: exponent,
                privateExponent: privateExponent,
                coefficient: coefficient,
                prime1: prime1,
                prime2: prime2,
                algorithm: rsaAlgorithm,
                comment: comment
            )
            let expected = "ssh-rsa " + Data(firstPublicBlob).base64EncodedString()
            guard parsed.publicKeyOpenSSH == expected else {
                throw SSHKeyError.malformed("RSA 公钥与私钥不匹配")
            }
            return parsed
        default:
            throw SSHKeyError.unsupported("不支持的私钥类型：" + keyType)
        }
    }

    // MARK: - PEM

    private static func parsePKCS8(
        text: String,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm
    ) throws -> ParsedPrivateKey {
        let der = try base64Body(text, label: "PRIVATE KEY")
        var outer = DERReader(bytes: der)
        let sequence = try outer.expect(tag: 0x30)
        var body = DERReader(bytes: sequence)
        _ = try body.expect(tag: 0x02)
        let algorithm = try body.expect(tag: 0x30)
        let privateBytes = try body.expect(tag: 0x04)
        var algorithmReader = DERReader(bytes: algorithm)
        let oid = try algorithmReader.expect(tag: 0x06)

        if isRSAOID(oid) {
            return try makeRSAKey(
                pkcs1DER: Data(privateBytes),
                algorithm: rsaAlgorithm,
                comment: nil
            )
        }

        if isEd25519OID(oid) {
            var inner = DERReader(bytes: privateBytes)
            let nested = try inner.expect(tag: 0x04)
            guard nested.count >= 32 else { throw SSHKeyError.malformed("Ed25519 私钥长度不正确") }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(nested.prefix(32)))
            return try finish(key: NIOSSHPrivateKey(ed25519Key: key), keyType: "ssh-ed25519", comment: nil)
        }

        let curve = try curveFor(oid: oid)
        return try makeECDSAKey(keyType: curve.0, scalar: try ecScalar(fromPKCS8: privateBytes), comment: nil)
    }

    /// Parses a PKCS#1 "BEGIN RSA PRIVATE KEY" PEM block.
    private static func parsePKCS1(
        text: String,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm
    ) throws -> ParsedPrivateKey {
        let der = try base64Body(text, label: "RSA PRIVATE KEY")
        return try makeRSAKey(pkcs1DER: Data(der), algorithm: rsaAlgorithm, comment: nil)
    }

    private static func parseSEC1(text: String) throws -> ParsedPrivateKey {
        let der = try base64Body(text, label: "EC PRIVATE KEY")
        var outer = DERReader(bytes: der)
        let sequence = try outer.expect(tag: 0x30)
        var body = DERReader(bytes: sequence)
        _ = try body.expect(tag: 0x02)
        let scalar = try body.expect(tag: 0x04)
        var curveName: (String, Int)?
        while let next = try? body.next() {
            if next.tag == 0xA0 {
                var parameters = DERReader(bytes: next.value)
                if let oid = try? parameters.expect(tag: 0x06) {
                    if let found = try? curveFor(oid: oid) {
                        curveName = found
                    }
                }
            }
        }
        guard let curve = curveName else {
            throw SSHKeyError.malformed("无法识别 ECDSA 曲线")
        }
        return try makeECDSAKey(keyType: curve.0, scalar: scalar, comment: nil)
    }

    private static func ecScalar(fromPKCS8 privateBytes: [UInt8]) throws -> [UInt8] {
        var reader = DERReader(bytes: privateBytes)
        let sequence = try reader.expect(tag: 0x30)
        var body = DERReader(bytes: sequence)
        _ = try body.expect(tag: 0x02)
        return try body.expect(tag: 0x04)
    }

    private static func isEd25519OID(_ oid: [UInt8]) -> Bool {
        oid == [0x2B, 0x65, 0x70]
    }

    /// rsaEncryption (1.2.840.113549.1.1.1).
    private static func isRSAOID(_ oid: [UInt8]) -> Bool {
        oid == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    }

    private static func curveFor(oid: [UInt8]) throws -> (String, Int) {
        switch oid {
        case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]:
            return ("ecdsa-sha2-nistp256", 32)
        case [0x2B, 0x81, 0x04, 0x00, 0x22]:
            return ("ecdsa-sha2-nistp384", 48)
        case [0x2B, 0x81, 0x04, 0x00, 0x23]:
            return ("ecdsa-sha2-nistp521", 66)
        default:
            throw SSHKeyError.unsupported("不支持的 ECDSA 曲线")
        }
    }

    private static func makeECDSAKey(keyType: String, scalar: [UInt8], comment: String?) throws -> ParsedPrivateKey {
        let size: Int
        switch keyType {
        case "ecdsa-sha2-nistp256": size = 32
        case "ecdsa-sha2-nistp384": size = 48
        case "ecdsa-sha2-nistp521": size = 66
        default: throw SSHKeyError.unsupported("不支持的私钥类型：" + keyType)
        }
        let trimmed = Array(scalar.suffix(size))
        var padded = [UInt8](repeating: 0, count: max(0, size - trimmed.count))
        padded.append(contentsOf: trimmed)
        let data = Data(padded)
        switch keyType {
        case "ecdsa-sha2-nistp256":
            return try finish(key: NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: data)),
                              keyType: keyType, comment: comment)
        case "ecdsa-sha2-nistp384":
            return try finish(key: NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: data)),
                              keyType: keyType, comment: comment)
        default:
            return try finish(key: NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: data)),
                              keyType: keyType, comment: comment)
        }
    }

    // MARK: - RSA

    /// Wraps an already-encoded PKCS#1 `RSAPrivateKey` DER structure.
    private static func makeRSAKey(
        pkcs1DER: Data,
        algorithm: NIOSSHRSASignatureAlgorithm,
        comment: String?
    ) throws -> ParsedPrivateKey {
        let key: NIOSSHPrivateKey
        do {
            key = try NIOSSHPrivateKey(rsaPrivateKeyDER: pkcs1DER, algorithm: algorithm)
        } catch {
            throw SSHKeyError.malformed("RSA 私钥无法导入（" + (error.localizedDescription) + "）")
        }
        return try finish(key: key, keyType: "ssh-rsa", comment: comment)
    }

    /// Builds a PKCS#1 `RSAPrivateKey` from the fields of an OpenSSH private key.
    ///
    /// OpenSSH stores `n, e, d, iqmp, p, q`; PKCS#1 additionally wants
    /// `dP = d mod (p - 1)` and `dQ = d mod (q - 1)`.
    private static func makeRSAKey(
        modulus: [UInt8],
        exponent: [UInt8],
        privateExponent: [UInt8],
        coefficient: [UInt8],
        prime1: [UInt8],
        prime2: [UInt8],
        algorithm: NIOSSHRSASignatureAlgorithm,
        comment: String?
    ) throws -> ParsedPrivateKey {
        let prime1Value = SSHBigUInt(bytes: prime1)
        let prime2Value = SSHBigUInt(bytes: prime2)
        let privateValue = SSHBigUInt(bytes: privateExponent)
        guard !prime1Value.isZero, !prime2Value.isZero, !privateValue.isZero else {
            throw SSHKeyError.malformed("RSA 私钥缺少必需的参数")
        }
        let exponent1 = SSHBigUInt.modulo(privateValue, prime1Value.subtractingOne())
        let exponent2 = SSHBigUInt.modulo(privateValue, prime2Value.subtractingOne())
        let der = NIOSSHRSAPrivateKeyDER.make(
            modulus: Data(modulus),
            exponent: Data(exponent),
            privateExponent: Data(privateExponent),
            prime1: Data(prime1),
            prime2: Data(prime2),
            exponent1: exponent1.data,
            exponent2: exponent2.data,
            coefficient: Data(coefficient)
        )
        return try makeRSAKey(pkcs1DER: der, algorithm: algorithm, comment: comment)
    }

    private static func finish(key: NIOSSHPrivateKey, keyType: String, comment: String?) throws -> ParsedPrivateKey {
        let openSSH = String(openSSHPublicKey: key.publicKey)
        return ParsedPrivateKey(key: key, keyType: keyType, comment: comment, publicKeyOpenSSH: openSSH)
    }

    private static func base64Body(_ text: String, label: String) throws -> [UInt8] {
        let begin = "-----BEGIN " + label + "-----"
        let end = "-----END " + label + "-----"
        guard let beginRange = text.range(of: begin), let endRange = text.range(of: end),
              beginRange.upperBound <= endRange.lowerBound else {
            throw SSHKeyError.malformed("缺少 PEM 头尾标记")
        }
        let body = text[beginRange.upperBound..<endRange.lowerBound]
        let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned) else {
            throw SSHKeyError.malformed("Base64 内容无效")
        }
        return [UInt8](data)
    }
}

struct SSHKeyByteReader {
    let bytes: [UInt8]
    var index = 0

    mutating func readUInt32() throws -> UInt32 {
        let chunk = try readBytes(4)
        return (UInt32(chunk[0]) << 24) | (UInt32(chunk[1]) << 16) | (UInt32(chunk[2]) << 8) | UInt32(chunk[3])
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index + count <= bytes.count else {
            throw SSHKeyError.malformed("私钥数据被截断")
        }
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    mutating func readString() throws -> [UInt8] {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }

    mutating func readUTF8String() throws -> String {
        let raw = try readString()
        return String(bytes: raw, encoding: .utf8) ?? ""
    }
}

/// Minimal arbitrary-precision unsigned integer, just big enough to compute the
/// CRT parameters (`d mod (p - 1)`) that PKCS#1 requires for RSA private keys.
struct SSHBigUInt {
    /// Little-endian 32-bit limbs, without trailing zero limbs.
    var words: [UInt32] = []

    init() {}

    init(bytes: [UInt8]) {
        var words: [UInt32] = []
        var chunk: UInt32 = 0
        var shift = 0
        for byte in bytes.reversed() {
            chunk |= UInt32(byte) << UInt32(shift)
            shift += 8
            if shift == 32 {
                words.append(chunk)
                chunk = 0
                shift = 0
            }
        }
        if shift > 0 {
            words.append(chunk)
        }
        while let last = words.last, last == 0 {
            words.removeLast()
        }
        self.words = words
    }

    var isZero: Bool {
        words.isEmpty
    }

    var bitLength: Int {
        guard let last = words.last else { return 0 }
        return words.count * 32 - last.leadingZeroBitCount
    }

    var data: Data {
        guard !words.isEmpty else { return Data([0]) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(words.count * 4)
        for word in words.reversed() {
            bytes.append(UInt8((word >> 24) & 0xFF))
            bytes.append(UInt8((word >> 16) & 0xFF))
            bytes.append(UInt8((word >> 8) & 0xFF))
            bytes.append(UInt8(word & 0xFF))
        }
        var index = 0
        while index < bytes.count && bytes[index] == 0 {
            index += 1
        }
        return Data(bytes[index...])
    }

    /// Returns -1, 0 or 1 the way `Comparable` would.
    func compare(_ other: SSHBigUInt) -> Int {
        if words.count != other.words.count {
            return words.count < other.words.count ? -1 : 1
        }
        var index = words.count - 1
        while index >= 0 {
            if words[index] != other.words[index] {
                return words[index] < other.words[index] ? -1 : 1
            }
            index -= 1
        }
        return 0
    }

    mutating func subtract(_ other: SSHBigUInt) {
        var borrow: Int64 = 0
        for index in 0..<words.count {
            let rhs = index < other.words.count ? Int64(other.words[index]) : 0
            var difference = Int64(words[index]) - rhs - borrow
            if difference < 0 {
                difference += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            words[index] = UInt32(truncatingIfNeeded: difference)
        }
        while let last = words.last, last == 0 {
            words.removeLast()
        }
    }

    func subtractingOne() -> SSHBigUInt {
        var result = self
        var index = 0
        while index < result.words.count {
            if result.words[index] > 0 {
                result.words[index] -= 1
                break
            }
            result.words[index] = UInt32.max
            index += 1
        }
        while let last = result.words.last, last == 0 {
            result.words.removeLast()
        }
        return result
    }

    func shiftedLeft(insertingBitAtBottom bit: Bool) -> SSHBigUInt {
        if words.isEmpty {
            var result = SSHBigUInt()
            if bit { result.words = [1] }
            return result
        }
        var result = words
        var carry: UInt32 = bit ? 1 : 0
        for index in 0..<result.count {
            let nextCarry = result[index] >> 31
            result[index] = (result[index] << 1) | carry
            carry = nextCarry
        }
        if carry != 0 {
            result.append(carry)
        }
        var output = SSHBigUInt()
        output.words = result
        return output
    }

    /// `value mod modulus` computed with plain binary long division.
    static func modulo(_ value: SSHBigUInt, _ modulus: SSHBigUInt) -> SSHBigUInt {
        guard !modulus.isZero else { return SSHBigUInt() }
        var remainder = SSHBigUInt()
        let bits = value.bitLength
        var index = bits - 1
        while index >= 0 {
            let word = value.words[index >> 5]
            let bit = (word >> UInt32(index & 31)) & 1 == 1
            remainder = remainder.shiftedLeft(insertingBitAtBottom: bit)
            if remainder.compare(modulus) >= 0 {
                remainder.subtract(modulus)
            }
            index -= 1
        }
        return remainder
    }
}

struct DERReader {
    let bytes: [UInt8]
    var index = 0

    mutating func next() throws -> (tag: UInt8, value: [UInt8]) {
        let tag = try readByte()
        var length = Int(try readByte())
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount > 0, byteCount <= 4 else { throw SSHKeyError.malformed("DER 长度无效") }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(try readByte())
            }
        }
        guard index + length <= bytes.count else { throw SSHKeyError.malformed("DER 数据被截断") }
        let value = Array(bytes[index..<(index + length)])
        index += length
        return (tag, value)
    }

    mutating func expect(tag: UInt8) throws -> [UInt8] {
        let element = try next()
        guard element.tag == tag else {
            throw SSHKeyError.malformed("DER 标签不匹配（期望 " + String(tag) + "，实际 " + String(element.tag) + "）")
        }
        return element.value
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < bytes.count else { throw SSHKeyError.malformed("DER 数据被截断") }
        let byte = bytes[index]
        index += 1
        return byte
    }
}
