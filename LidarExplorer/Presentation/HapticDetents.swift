//
//  HapticDetents.swift
//  LidarExplorer
//
//  When a control should tick, decided apart from the hardware that ticks.
//
//  A slider reports positions, not events, and a finger reports them faster than a Taptic Engine can answer.
//  Turning those streams into "tick now" is a matter of geometry and timing, which is testable on any host; the
//  manager that owns the feedback generators only asks these types and fires.
//

import Foundation

/// The compass detents of a sun-azimuth dial.
public nonisolated enum AzimuthDetents {
    /// The eight compass headings: N, NE, E, SE, S, SW, W, NW.
    public static let headings: [Double] = [0, 45, 90, 135, 180, 225, 270, 315]
    /// Half-width of a detent, in degrees.
    public static let window = 1.5

    private static func wrapped(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// The heading whose window contains `degrees`, as an index into ``headings``.
    private static func window(containing degrees: Double) -> Int? {
        headings.indices.first { index in
            var offset = abs(degrees - headings[index])
            if offset > 180 { offset = 360 - offset }
            return offset <= window
        }
    }

    /// The heading a move from `previous` to `current` newly reaches, as an index into ``headings``, or `nil`.
    ///
    /// A tick is for arriving: entering a heading's window, or passing over it between two readings when a fast
    /// drag skips the window altogether. Moving about inside a window, or leaving it, is silent. Angles are
    /// taken modulo 360; a value that is not a number never ticks and is treated as no previous position.
    public static func detent(from previous: Double?, to current: Double) -> Int? {
        guard current.isFinite else { return nil }
        let now = wrapped(current)
        let before = previous.flatMap { $0.isFinite ? wrapped($0) : nil }
        let insideBefore = before.flatMap { window(containing: $0) }

        if let entered = window(containing: now), entered != insideBefore { return entered }
        guard let before else { return nil }

        // Passed over a heading without landing in its window: it lies between the two, the shorter way round.
        var delta = now - before
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        guard delta != 0 else { return nil }
        var passed: (index: Int, distance: Double)?
        for index in headings.indices where index != insideBefore {
            var offset = headings[index] - before
            if offset > 180 { offset -= 360 } else if offset <= -180 { offset += 360 }
            let between = delta > 0 ? (offset > 0 && offset <= delta) : (offset < 0 && offset >= delta)
            // Of several passed, the one nearest the end of the move.
            if between, passed == nil || abs(offset) > passed!.distance { passed = (index, abs(offset)) }
        }
        return passed?.index
    }
}

/// Decides when a scrub across a profile meets a break in an earthwork signature.
public nonisolated struct BreakCrossingDetector: Sendable {
    /// How near, in metres, counts as on a break.
    public var tolerance: Double
    private var previous: Double?

    public init(tolerance: Double = 1.0) {
        self.tolerance = tolerance
    }

    /// Whether moving the scrub to `distance` lands on or crosses any of `breaks`.
    ///
    /// Once per arrival: a finger resting on a break, or jittering across it, does not repeat, but leaving and
    /// coming back does, and a jump over one break or several is a single tick. A distance or a break that is not
    /// a number is ignored.
    public mutating func update(to distance: Double, breaks: [Double]) -> Bool {
        guard distance.isFinite else { return false }
        defer { previous = distance }
        var hit = false
        for position in breaks where position.isFinite {
            let onNow = abs(distance - position) <= tolerance
            let onBefore = previous.map { abs($0 - position) <= tolerance } ?? false
            let straddled = previous.map { ($0 - position) * (distance - position) < 0 } ?? false
            if !onBefore && (onNow || straddled) { hit = true }
        }
        return hit
    }

    /// Forgets where the scrub was, for when the finger lifts.
    public mutating func reset() {
        previous = nil
    }
}

/// A minimum gap between ticks, so a fast gesture cannot queue more feedback than the hardware can play.
public nonisolated struct HapticThrottle: Sendable {
    public let minimumInterval: TimeInterval
    private var lastFire: TimeInterval?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Whether a tick at `now` may fire. One that may records itself; one that may not is dropped, not queued,
    /// and does not move the clock. A clock that steps backwards is trusted afresh rather than waited out.
    public mutating func allows(at now: TimeInterval) -> Bool {
        // A nanosecond of slack, so a tick exactly one interval later is not lost to rounding.
        if let last = lastFire, now >= last, now - last < minimumInterval - 1e-9 { return false }
        lastFire = now
        return true
    }
}
