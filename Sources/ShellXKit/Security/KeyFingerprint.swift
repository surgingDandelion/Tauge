import Foundation
import CryptoKit

/// Formats host key digests the way OpenSSH does, so users can compare what
/// ShellX shows with ssh-keygen -lf. Works on raw SSH public key blobs.
public enum KeyFingerprint {
    public static func sha256(_ blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        var base64 = Data(digest).base64EncodedString()
        while base64.hasSuffix("=") { base64.removeLast() }
        return "SHA256:" + base64
    }

    public static func md5(_ blob: Data) -> String {
        let digest = Insecure.MD5.hash(data: blob)
        return "MD5:" + Data(digest).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func matches(stored: String, blob: Data) -> Bool {
        let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == sha256(blob) || normalized == md5(blob)
    }
}
