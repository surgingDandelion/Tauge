import Foundation
import Crypto
import NIOCore
import NIOSSH

public struct HostKeyInfo: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let fingerprintSHA256: String
    public let fingerprintMD5: String
    public let openSSHPublicKey: String

    public init(host: String, port: Int, keyType: String, fingerprintSHA256: String, fingerprintMD5: String, openSSHPublicKey: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.fingerprintMD5 = fingerprintMD5
        self.openSSHPublicKey = openSSHPublicKey
    }
}

public enum HostKeyDecision: Sendable {
    case trust(remember: Bool)
    case reject
}

public typealias HostKeyValidator = @Sendable (HostKeyInfo) async -> HostKeyDecision

public enum HostKeyError: Error, LocalizedError {
    case rejected(HostKeyInfo)

    public var errorDescription: String? {
        switch self {
        case .rejected(let info):
            return "主机密钥校验失败：" + info.host + ":" + String(info.port) + " 的 " + info.keyType + " 指纹 " + info.fingerprintSHA256 + " 未被信任"
        }
    }
}

enum HostKeyUtility {
    static func info(host: String, port: Int, hostKey: NIOSSHPublicKey) -> HostKeyInfo {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ")
        let keyType = parts.first.map(String.init) ?? "unknown"
        var blob = Data()
        if parts.count > 1 {
            blob = Data(base64Encoded: String(parts[1])) ?? Data()
        }
        let sha = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let md5Bytes = Insecure.MD5.hash(data: blob).map { String(format: "%02x", $0) }
        return HostKeyInfo(host: host,
                           port: port,
                           keyType: keyType,
                           fingerprintSHA256: "SHA256:" + sha,
                           fingerprintMD5: "MD5:" + md5Bytes.joined(separator: ":"),
                           openSSHPublicKey: openSSH)
    }
}

final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let validator: HostKeyValidator

    init(host: String, port: Int, validator: @escaping HostKeyValidator) {
        self.host = host
        self.port = port
        self.validator = validator
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyUtility.info(host: host, port: port, hostKey: hostKey)
        Task {
            let decision = await validator(info)
                switch decision {
            case .trust:
                validationCompletePromise.succeed(())
            case .reject:
                validationCompletePromise.fail(HostKeyError.rejected(info))
            }
        }
    }
}
