import Foundation

/// Payload of a drag that starts on a remote SFTP row.
///
/// `path` is the row under the pointer, so a payload written by an older build
/// (or read by one) still identifies a single item. `paths` carries the whole
/// selection, which is what lets one drag queue several files instead of only the
/// grabbed row.
public struct RemoteDragPayload: Codable, Equatable, Sendable {
    public static let typeIdentifier = "com.tauge.remote-path"

    public var hostID: String?
    public var path: String
    public var paths: [String]?
    /// Identifies the exact pane, so a drop onto another pane becomes a
    /// server-to-server relay instead of a download.
    public var paneID: String?

    public init(hostID: String? = nil, path: String, paths: [String]? = nil, paneID: String? = nil) {
        self.hostID = hostID
        self.path = path
        self.paths = paths
        self.paneID = paneID
    }

    /// The selected rows in pane order, with the grabbed row appended when the
    /// payload only names one. Empty and repeated paths are dropped.
    public var allPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in (paths ?? []) + [path] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

/// Payload of a drag that starts on a local file row.
///
/// AppKit delivers one `.fileURL` per drag item, and SwiftUI's `onDrag` exposes
/// a single item, so the extra rows of a multi-row selection travel in this
/// payload next to the URL of the grabbed row.
public struct LocalDragPayload: Codable, Equatable, Sendable {
    public static let typeIdentifier = "com.tauge.local-paths"

    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }

    /// Trimmed, non-empty, order-preserving unique paths.
    public var allPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in paths {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
