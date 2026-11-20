import Foundation

/// Resolves the color a host should display.
///
/// A host's own color always wins. When it has none, the nearest enclosing
/// group with a color supplies the tint. Older builds copied a group color onto
/// every host in the group; `isInherited` recognises those mirrored values so
/// group edits can release them again instead of pinning the old accent.
public enum HostColor {
    public enum Source: Equatable, Sendable {
        case host
        case group(id: UUID, name: String)
    }

    public struct Resolution: Equatable, Sendable {
        public let hex: String
        public let source: Source

        public init(hex: String, source: Source) {
            self.hex = hex
            self.source = source
        }
    }

    /// Explicit host color, then the closest ancestor group color, then nil.
    public static func resolve(host: SSHHost, groups: [HostGroup]) -> Resolution? {
        if let hex = normalized(host.colorHex) {
            return Resolution(hex: hex, source: .host)
        }
        var visited: Set<UUID> = []
        var groupID = host.groupID
        while let id = groupID, visited.insert(id).inserted {
            guard let group = groups.first(where: { $0.id == id }) else { break }
            if let hex = normalized(group.colorHex) {
                return Resolution(hex: hex, source: .group(id: group.id, name: group.name))
            }
            groupID = group.parentID
        }
        return nil
    }

    /// The color a host would inherit from `groupID` and its ancestors.
    public static func inheritedHex(forGroupID groupID: UUID?, groups: [HostGroup]) -> String? {
        var visited: Set<UUID> = []
        var current = groupID
        while let id = current, visited.insert(id).inserted {
            guard let group = groups.first(where: { $0.id == id }) else { break }
            if let hex = normalized(group.colorHex) { return hex }
            current = group.parentID
        }
        return nil
    }

    /// True when two stored values describe the same color. Used to tell a
    /// group color that was mirrored onto a host from a deliberate host choice.
    public static func isInherited(_ hostHex: String?, from groupHex: String?) -> Bool {
        guard let host = normalized(hostHex), let group = normalized(groupHex) else { return false }
        return host == group
    }

    /// Trims, validates and upper-cases a `#RRGGBB` value. Empty and malformed
    /// strings become nil so a blank database cell does not hide a group color.
    public static func normalized(_ hex: String?) -> String? {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return "#" + value.uppercased()
    }
}
