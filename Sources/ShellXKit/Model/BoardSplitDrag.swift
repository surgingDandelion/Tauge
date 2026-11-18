import CoreGraphics

/// Tracks one divider drag.
///
/// The measurement has to happen in window coordinates: the divider itself
/// slides while it is dragged, so a delta taken in the divider's own coordinate
/// space shrinks back to zero on every frame and the drag feels stuck.
public struct BoardSplitDragTracker: Sendable {
    public private(set) var start: CGPoint?

    public init() {}

    public var isTracking: Bool { start != nil }

    public mutating func begin(at point: CGPoint) {
        start = point
    }

    /// Distance from the drag origin along the divider's axis.
    public func delta(to point: CGPoint, axis: BoardSplitAxis) -> CGFloat? {
        guard let start else { return nil }
        switch axis {
        case .horizontal: return point.x - start.x
        case .vertical: return point.y - start.y
        }
    }

    public mutating func end() {
        start = nil
    }
}
