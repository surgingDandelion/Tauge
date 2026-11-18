import Foundation
import Darwin

public enum LocalFileError: Error, LocalizedError {
    case notFound(String)
    case permissionDenied(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "No such file or directory: " + path
        case .permissionDenied(let path): return "Permission denied: " + path
        case .failed(let message): return message
        }
    }
}

/// Local filesystem operations used by the left pane of the SFTP browser and by
/// uploads/downloads. Kept synchronous: callers run it on a background queue.
public struct LocalFileService: Sendable {
    public init() {}

    public static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public static var defaultStartDirectory: String {
        let candidates = [
            homeDirectory + "/Downloads",
            homeDirectory + "/Desktop",
            homeDirectory + "/Documents",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return homeDirectory
    }

    public func list(directory: String, showHidden: Bool) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: directory)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: options)
        } catch {
            throw mapError(error, path: directory)
        }
        var entries: [FileEntry] = []
        entries.reserveCapacity(contents.count)
        for fileURL in contents {
            let path = fileURL.path
            if let entry = try? entry(for: path, name: fileURL.lastPathComponent) {
                entries.append(entry)
            }
        }
        return entries
    }

    public func entry(for path: String, name: String? = nil) throws -> FileEntry {
        var info = stat()
        let result = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard result == 0 else {
            if errno == ENOENT { throw LocalFileError.notFound(path) }
            if errno == EACCES { throw LocalFileError.permissionDenied(path) }
            throw LocalFileError.failed("lstat failed for " + path + " (errno " + String(errno) + ")")
        }

        let mode = info.st_mode & 0o7777
        let kind: FileEntry.Kind
        if (info.st_mode & S_IFMT) == S_IFDIR {
            kind = .directory
        } else if (info.st_mode & S_IFMT) == S_IFLNK {
            kind = .symlink
        } else if (info.st_mode & S_IFMT) == S_IFREG {
            kind = .file
        } else {
            kind = .other
        }

        var linkTarget: String? = nil
        var effectiveKind = kind
        if kind == .symlink {
            linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            var targetInfo = stat()
            if stat(path, &targetInfo) == 0, (targetInfo.st_mode & S_IFMT) == S_IFDIR {
                effectiveKind = .symlink
            }
        }

        let displayName = name ?? (path as NSString).lastPathComponent
        return FileEntry(path: path,
                         name: displayName,
                         kind: effectiveKind,
                         size: Int64(info.st_size),
                         mode: UInt16(mode),
                         owner: Self.ownerName(info.st_uid),
                         group: Self.groupName(info.st_gid),
                         modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                         linkTarget: linkTarget,
                         isHidden: displayName.hasPrefix("."))
    }

    public func createDirectory(at path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: path)
        }
    }

    public func createEmptyFile(at path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw LocalFileError.failed("Unable to create file at " + path)
        }
    }

    public func remove(at path: String, recursive: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw LocalFileError.notFound(path)
        }
        do {
            if isDirectory.boolValue && recursive {
                try FileManager.default.removeItem(atPath: path)
            } else if isDirectory.boolValue {
                try FileManager.default.removeItem(atPath: path)
            } else {
                try FileManager.default.removeItem(atPath: path)
            }
        } catch {
            throw mapError(error, path: path)
        }
    }

    public func rename(_ path: String, to newPath: String) throws {
        do {
            try FileManager.default.moveItem(atPath: path, toPath: newPath)
        } catch {
            throw mapError(error, path: path)
        }
    }

    public func setPermissions(_ path: String, mode: UInt16) throws {
        if chmod(path, mode_t(mode)) != 0 {
            if errno == ENOENT { throw LocalFileError.notFound(path) }
            if errno == EACCES { throw LocalFileError.permissionDenied(path) }
            throw LocalFileError.failed("chmod failed for " + path)
        }
    }

    public func attributes(of path: String) -> (size: Int64, modified: Date)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (Int64(info.st_size), Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    public func readData(at path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw mapError(error, path: path)
        }
    }

    public func writeData(_ data: Data, to path: String, atomically: Bool = true) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: atomically ? .atomic : [])
        } catch {
            throw mapError(error, path: path)
        }
    }

    /// Recursively lists files (not directories) under a directory, for
    /// recursive uploads.
    public func enumerateFiles(root: String, includeHidden: Bool = false) throws -> [(absolutePath: String, relativePath: String, size: Int64)] {
        // Resolve symlinks (on macOS /var is a symlink to /private/var) so the
        // prefix comparison below produces relative paths instead of absolute ones.
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: rootURL,
                                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                             options: options) else {
            throw LocalFileError.notFound(root)
        }
        var results: [(String, String, Int64)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let absolute = fileURL.resolvingSymlinksInPath().path
            let base = rootURL.path
            var relative = absolute
            if relative.hasPrefix(base) {
                relative = String(relative.dropFirst(base.count))
                if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            }
            results.append((absolute, relative, Int64(values?.fileSize ?? 0)))
        }
        return results
    }

    private func mapError(_ error: Error, path: String) -> LocalFileError {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound(path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissionDenied(path)
        default:
            return .failed(nsError.localizedDescription)
        }
    }

    static func ownerName(_ uid: uid_t) -> String? {
        guard let pointer = getpwuid(uid) else { return String(uid) }
        return String(cString: pointer.pointee.pw_name)
    }

    static func groupName(_ gid: gid_t) -> String? {
        guard let pointer = getgrgid(gid) else { return String(gid) }
        return String(cString: pointer.pointee.gr_name)
    }
}
