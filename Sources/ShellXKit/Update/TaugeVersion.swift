import Foundation

/// A semantic version parsed from a Git tag or the app's Info.plist.
///
/// Tags in this repository are `vMAJOR.MINOR.PATCH`, but releases created by
/// hand may omit the `v` or the patch component, so both forms are accepted.
/// Build metadata (`+...`) is ignored when comparing; a pre-release
/// (`-beta.1`) sorts before the corresponding final release.
public struct TaugeVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: [String]

    public static let zero = TaugeVersion(parts: [0, 0, 0], prerelease: [])

    public init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        // Build metadata never participates in precedence.
        if let plus = value.firstIndex(of: "+") {
            value = String(value[..<plus])
        }
        var prerelease: [String] = []
        if let dash = value.firstIndex(of: "-") {
            let suffix = String(value[value.index(after: dash)...])
            value = String(value[..<dash])
            guard !suffix.isEmpty else { return nil }
            prerelease = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var parts: [Int] = []
        for field in fields {
            guard !field.isEmpty,
                  field.allSatisfy({ $0.isNumber }),
                  let number = Int(field),
                  number >= 0 else { return nil }
            parts.append(number)
        }
        while parts.count < 3 { parts.append(0) }
        self.init(parts: parts, prerelease: prerelease)
    }

    private init(parts: [Int], prerelease: [String]) {
        self.components = parts
        self.prerelease = prerelease
    }

    public var description: String {
        let core = components.map(String.init).joined(separator: ".")
        guard !prerelease.isEmpty else { return core }
        return core + "-" + prerelease.joined(separator: ".")
    }

    public static func == (lhs: TaugeVersion, rhs: TaugeVersion) -> Bool {
        guard lhs.prerelease == rhs.prerelease else { return false }
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return true
    }

    public static func < (lhs: TaugeVersion, rhs: TaugeVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // A final release is newer than any pre-release of the same core version.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (.some(l), .some(r)):
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left < right
            }
        }
        return false
    }
}

/// Facts read from the running app bundle. Kept in ShellXKit so the updater,
/// the About panel and the command-line diagnostics all agree.
public enum TaugeAppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.shellx.app"
    }
}
