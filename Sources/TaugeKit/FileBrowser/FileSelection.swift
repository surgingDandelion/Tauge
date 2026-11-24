import Foundation

/// Row selection semantics shared by the local and remote browser panes.
///
/// A plain click replaces the selection, ⌘ toggles a single row, ⇧ extends from
/// the anchor (the last row clicked without ⇧), and ⌘⇧ adds that range to what
/// was already selected. The anchor survives ⇧ clicks so repeated ⇧ clicks grow
/// the same range instead of collapsing it to one row.
public enum FileSelection {
    public enum Mode: Equatable, Sendable {
        case replace
        case toggle
        case extend
        case extendAdding

        public init(command: Bool, shift: Bool) {
            if shift {
                self = command ? .extendAdding : .extend
            } else {
                self = command ? .toggle : .replace
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let selection: Set<String>
        public let anchor: String?

        public init(selection: Set<String>, anchor: String?) {
            self.selection = selection
            self.anchor = anchor
        }
    }

    /// - Parameters:
    ///   - path: the row that received the click.
    ///   - order: every visible row, in the order the list displays it.
    ///   - selection: the selection before the click.
    ///   - anchor: last row clicked without ⇧; nil after a navigation.
    ///   - mode: modifier combination turned into a selection mode.
    public static func outcome(clicked path: String,
                               order: [String],
                               selection: Set<String>,
                               anchor: String?,
                               mode: Mode) -> Outcome {
        switch mode {
        case .replace:
            return Outcome(selection: [path], anchor: path)
        case .toggle:
            var next = selection
            if next.contains(path) {
                next.remove(path)
            } else {
                next.insert(path)
            }
            return Outcome(selection: next, anchor: path)
        case .extend, .extendAdding:
            // A shift click after navigating (or after the anchor row vanished)
            // behaves like a plain click rather than selecting a random range.
            guard let rows = range(from: anchor ?? path, to: path, order: order) else {
                return Outcome(selection: [path], anchor: path)
            }
            let next = mode == .extendAdding ? selection.union(rows) : Set(rows)
            return Outcome(selection: next, anchor: anchor ?? path)
        }
    }

    /// An action on a selected row applies to the visible selection. An action
    /// on any other row applies only to that row.
    public static func actionEntries(for row: FileEntry,
                                     in visibleEntries: [FileEntry],
                                     selection: Set<String>) -> [FileEntry] {
        guard selection.contains(row.path) else { return [row] }
        let selectedRows = visibleEntries.filter { selection.contains($0.path) }
        guard selectedRows.count > 1, selectedRows.contains(where: { $0.path == row.path }) else {
            return [row]
        }
        return selectedRows
    }

    private static func range(from anchor: String, to path: String, order: [String]) -> [String]? {
        if anchor == path { return [path] }
        guard let start = order.firstIndex(of: anchor),
              let end = order.firstIndex(of: path) else { return nil }
        return (start <= end ? start...end : end...start).map { order[$0] }
    }
}
