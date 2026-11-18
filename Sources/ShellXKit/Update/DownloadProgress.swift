import Foundation

/// Snapshot of an in-flight update download.
///
/// The updater used to show a bare spinner, which said nothing about a 30 MB
/// archive on a slow link. `URLSession` hands byte counters to a task
/// delegate; this value type turns them into what the UI needs (a fraction, a
/// remaining byte count, an estimate) and stays pure so the checks can drive
/// it without a network.
public struct ArchiveDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    /// The size the server advertised, or `0` when it never said (chunked or
    /// compressed on the fly).
    public let totalBytes: Int64

    public init(bytesReceived: Int64, totalBytes: Int64) {
        self.bytesReceived = max(0, bytesReceived)
        self.totalBytes = max(0, totalBytes)
    }

    /// `nil` when the total is unknown, so the UI can fall back to an
    /// indeterminate bar instead of inventing a percentage.
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    public var isComplete: Bool {
        totalBytes > 0 && bytesReceived >= totalBytes
    }

    public var remainingBytes: Int64 {
        max(0, totalBytes - bytesReceived)
    }

    /// Seconds left at `bytesPerSecond`, or `nil` when there is nothing to
    /// estimate (unknown size, finished, or a transfer that has stalled to a
    /// standstill).
    public func remainingTime(bytesPerSecond: Double) -> TimeInterval? {
        guard bytesPerSecond > 0, totalBytes > bytesReceived else { return nil }
        return Double(totalBytes - bytesReceived) / bytesPerSecond
    }
}

/// Exponentially smoothed byte rate.
///
/// `URLSession` delivers chunks in bursts — a fast link drops a megabyte in one
/// callback and then goes quiet — so the raw delta flaps between "0 B/s" and a
/// nonsense number. Feeding every sample through a simple EMA keeps the label
/// readable while still decaying within a second or two of a real stall.
public struct DownloadRateMeter: Sendable {
    private var previousBytes: Int64?
    private var previousTime: TimeInterval?
    private var smoothed: Double = 0
    private let weight: Double

    /// `weight` is how much each new sample counts (0…1]; the rest is history.
    public init(weight: Double = 0.3) {
        self.weight = min(1, max(0.01, weight))
    }

    public var bytesPerSecond: Double { smoothed }

    public mutating func reset() {
        previousBytes = nil
        previousTime = nil
        smoothed = 0
    }

    @discardableResult
    public mutating func update(bytes: Int64, at time: TimeInterval) -> Double {
        guard let lastBytes = previousBytes, let lastTime = previousTime else {
            previousBytes = bytes
            previousTime = time
            return smoothed
        }
        // Duplicate timestamps and a counter that went backwards (a retried
        // request) carry no usable delta; keep the last estimate.
        guard time > lastTime, bytes >= lastBytes else { return smoothed }
        let instant = Double(bytes - lastBytes) / (time - lastTime)
        smoothed = smoothed > 0 ? smoothed * (1 - weight) + instant * weight : instant
        previousBytes = bytes
        previousTime = time
        return smoothed
    }
}

/// Rate-limits progress callbacks.
///
/// A 30 MB archive arrives in hundreds of chunks; republishing every one of
/// them would wake the main actor for no visible benefit. Five updates per
/// second is already more than a bar and a speed label can show.
public struct ProgressThrottle: Sendable {
    public var minimumInterval: TimeInterval
    private var lastEmission: TimeInterval?

    public init(minimumInterval: TimeInterval = 0.2) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public mutating func shouldEmit(at time: TimeInterval) -> Bool {
        if let last = lastEmission, time - last < minimumInterval { return false }
        lastEmission = time
        return true
    }
}
