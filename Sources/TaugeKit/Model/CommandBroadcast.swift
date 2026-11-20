import Foundation

/// Command broadcast ("synchronised input"): bytes typed in one workspace pane
/// are replayed into the other live panes.
///
/// The rule lives here, away from the UI, so it can be checked without running
/// an app: the pane that produced the bytes already received them, a pane that
/// is not connected would drop them silently, and the list is returned in
/// display order so a replay is deterministic.
public enum CommandBroadcast {
    /// One pane as far as a broadcast is concerned.
    public struct Pane: Equatable, Sendable {
        public let id: UUID
        public let isConnected: Bool

        public init(id: UUID, isConnected: Bool) {
            self.id = id
            self.isConnected = isConnected
        }
    }

    /// Panes that should receive bytes typed in `origin`.
    ///
    /// - Parameters:
    ///   - origin: the pane the user typed in; it is never echoed back.
    ///   - panes: every pane of the workspace, in display order.
    /// - Returns: the connected panes other than the origin, in the same order.
    public static func recipients(origin: UUID, panes: [Pane]) -> [UUID] {
        panes
            .filter { $0.id != origin && $0.isConnected }
            .map(\.id)
    }

    /// How many panes a keystroke from `origin` would reach right now.
    public static func recipientCount(origin: UUID?, panes: [Pane]) -> Int {
        guard let origin else { return 0 }
        return recipients(origin: origin, panes: panes).count
    }
}
