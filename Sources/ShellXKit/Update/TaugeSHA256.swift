import Foundation
import CryptoKit

/// Streaming SHA-256 for downloaded update archives.
///
/// The archive is read in 1 MiB chunks so a 20 MB download does not need to be
/// materialised in memory just to verify it.
public enum TaugeSHA256 {
    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
