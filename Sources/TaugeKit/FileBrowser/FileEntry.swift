import Foundation

/// Unified representation of a local or remote file row so both panes of the
/// SFTP browser can share the same table, sorting and formatting code.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case file
        case directory
        case symlink
        case other
    }

    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var mode: UInt16?
    public var owner: String?
    public var group: String?
    public var modified: Date?
    public var linkTarget: String?
    public var isHidden: Bool

    public var id: String { path }

    public init(path: String,
                name: String,
                kind: Kind,
                size: Int64 = 0,
                mode: UInt16? = nil,
                owner: String? = nil,
                group: String? = nil,
                modified: Date? = nil,
                linkTarget: String? = nil,
                isHidden: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.mode = mode
        self.owner = owner
        self.group = group
        self.modified = modified
        self.linkTarget = linkTarget
        self.isHidden = isHidden
    }

    public var isDirectory: Bool { kind == .directory }
    public var isSymlink: Bool { kind == .symlink }
    public var isFile: Bool { kind == .file }

    public var displayPermissions: String {
        FileAttributeFormatter.symbolic(mode: mode, kind: kind)
    }

    public var displayOctal: String {
        FileAttributeFormatter.octal(mode: mode)
    }

    public var displaySize: String {
        isDirectory ? "--" : FileAttributeFormatter.size(size)
    }

    public var displayDate: String {
        guard let modified else { return "--" }
        return FileAttributeFormatter.shortDate(modified)
    }

    /// Full timestamp for tooltips, where there is room for the whole value.
    public var fullDate: String {
        guard let modified else { return "--" }
        return FileAttributeFormatter.dateFormatter.string(from: modified)
    }
}

public enum FileAttributeFormatter {
    public static func symbolic(mode: UInt16?, kind: FileEntry.Kind) -> String {
        let typeCharacter: String
        switch kind {
        case .directory: typeCharacter = "d"
        case .symlink: typeCharacter = "l"
        case .file: typeCharacter = "-"
        case .other: typeCharacter = "?"
        }
        guard let mode else { return typeCharacter + "?????????" }
        var result = typeCharacter
        let bits: [(UInt16, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (bit, character) in bits {
            result += (mode & bit) != 0 ? character : "-"
        }
        return result
    }

    public static func octal(mode: UInt16?) -> String {
        guard let mode else { return "---" }
        return String(mode & 0o7777, radix: 8)
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// Column-sized timestamp: this year only needs month/day and time, older
    /// entries trade the time for the year (18 characters do not fit a 96pt cell,
    /// and a truncated "17:4…" is worse than no time at all).
    public static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if sameYear { return shortFormatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    public static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return String(bytes) + " B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024.0
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        let formatted = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return formatted + " " + units[unitIndex]
    }

    public static func speed(bytesPerSecond: Double) -> String {
        size(Int64(max(0, bytesPerSecond))) + "/s"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        if seconds < 60 { return String(Int(seconds)) + "s" }
        if seconds < 3600 {
            return String(Int(seconds) / 60) + "m " + String(Int(seconds) % 60) + "s"
        }
        return String(Int(seconds) / 3600) + "h " + String((Int(seconds) % 3600) / 60) + "m"
    }
}

public enum FileSortField: String, CaseIterable, Sendable {
    case name
    case size
    case modified
    case kind

    public var displayName: String {
        switch self {
        case .name: return L("名称")
        case .size: return L("大小")
        case .modified: return L("修改时间")
        case .kind: return L("类型")
        }
    }
}

public struct FileSortOrder: Sendable, Equatable {
    public var field: FileSortField
    public var ascending: Bool

    public init(field: FileSortField = .name, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result: ComparisonResult
            switch field {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                result = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            case .modified:
                let left = lhs.modified ?? .distantPast
                let right = rhs.modified ?? .distantPast
                result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .kind:
                result = lhs.kind.rawValue.compare(rhs.kind.rawValue)
            }
            if result == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

public enum POSIXPath {
    public static func join(_ base: String, _ component: String) -> String {
        if component.hasPrefix("/") { return normalize(component) }
        if base.isEmpty || base == "." { return normalize(component) }
        if base == "/" { return normalize("/" + component) }
        return normalize(base + "/" + component)
    }

    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(component))
            }
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(_ path: String) -> String {
        (normalize(path) as NSString).lastPathComponent
    }

    public static func isDescendant(_ candidate: String, of parent: String) -> Bool {
        let normalizedCandidate = normalize(candidate)
        let normalizedParent = normalize(parent)
        if normalizedCandidate == normalizedParent { return true }
        let prefix = normalizedParent.hasSuffix("/") ? normalizedParent : normalizedParent + "/"
        return normalizedCandidate.hasPrefix(prefix)
    }

    /// Produces a non-colliding name inside a directory, following the
    /// "name (1).ext" convention on macOS.
    public static func uniqueName(for name: String, existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? base + " (" + String(index) + ")" : base + " (" + String(index) + ")." + ext
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }
}
