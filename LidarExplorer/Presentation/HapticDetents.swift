//
//  HapticDetents.swift
//  LidarExplorer
//
//  When a control should tick, decided apart from the hardware that ticks.
//
//  A dial or a scrub reports positions, not events, and a finger reports them faster than a Taptic Engine can answer.
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

/// Decides when a scrub across a profile meets a place where the ground's steepness crosses the slope chart's 20° line.
///
/// The break's thump (``BreakCrossingDetector``) marks a detected earthwork, so a line with none plays nothing however
/// steep it is: on lines over Monks Mound like the owner's the detector found no platform, their flat tops being wider
/// than its 40 m cap, and the owner felt nothing scrubbing across the slope line (2026-09-28). This marks, on any line,
/// each place where the steepness the Slope tab draws crosses its 20° flank line, rising or falling: a distance along
/// the profile, found between two of the line's samples. A scrub ticks on arriving within `tolerance` metres of one, as
/// at a break: once per arrival, not again while it hovers there or as it moves off, again once it has left and come
/// back, and once for a jump over one place or several.
public nonisolated struct SlopeCrossingDetector: Sendable {
    /// The slope chart's flank line, in degrees: the steepness the earthwork detector takes for a mound's flank
    /// (`TransectSignatureParameters.flankMinimumSlopeDegrees`). The chart draws its line here.
    public static let flankDegrees = 20.0

    /// How near, in metres along the profile, counts as on a place.
    public var tolerance: Double {
        get { arrivals.tolerance }
        set { arrivals.tolerance = newValue }
    }
    /// The places are arrived at as breaks are.
    private var arrivals: BreakCrossingDetector

    public init(tolerance: Double = 1.0) {
        arrivals = BreakCrossingDetector(tolerance: tolerance)
    }

    /// The distances along `line` (distance in metres and slope in degrees, in order along the profile) where its
    /// steepness, the slope's magnitude, crosses `degrees` either way, each found by straight interpolation between the
    /// two samples either side. A sample lying on the line counts as reaching it, so a line that touches it at one sample
    /// has one place there. A sample with no slope or no distance (no ground there) breaks the line: no place is found
    /// across it.
    public static func crossings(of line: [(distance: Double, slope: Double)], at degrees: Double = flankDegrees) -> [Double] {
        var places: [Double] = []
        var previous: (distance: Double, steepness: Double)?
        for sample in line {
            guard sample.distance.isFinite, sample.slope.isFinite else {
                previous = nil
                continue
            }
            let current = (distance: sample.distance, steepness: abs(sample.slope))
            defer { previous = current }
            // One side at or above the line and the other below it, so the two steepnesses differ.
            guard let before = previous, (before.steepness >= degrees) != (current.steepness >= degrees) else { continue }
            let share = (degrees - before.steepness) / (current.steepness - before.steepness)
            let place = before.distance + share * (current.distance - before.distance)
            // Touching the line at a sample reaches it and leaves it at that sample: one place.
            if places.last != place { places.append(place) }
        }
        return places
    }

    /// Whether moving the scrub to `distance` lands on or crosses a place where `line`, the slope chart's steepness,
    /// crosses the flank line (``crossings(of:at:)``). A distance that is not a number never ticks and is not taken as
    /// where the scrub is. The places are found afresh on each call: the chart's line is at most 384 samples.
    public mutating func update(to distance: Double, along line: [(distance: Double, slope: Double)]) -> Bool {
        arrivals.update(to: distance, breaks: Self.crossings(of: line))
    }

    /// Forgets where the scrub was, for when the finger lifts.
    public mutating func reset() {
        arrivals.reset()
    }
}

/// What a scrub along a profile's chart plays at each sample: the earthwork break's thump (``BreakCrossingDetector``)
/// or the slope line's tick (``SlopeCrossingDetector``), one cue at most.
public nonisolated struct ProfileScrubCues: Sendable {
    private var breakCrossings: BreakCrossingDetector
    private var slopeCrossings: SlopeCrossingDetector

    public init(tolerance: Double = 1.0) {
        breakCrossings = BreakCrossingDetector(tolerance: tolerance)
        slopeCrossings = SlopeCrossingDetector(tolerance: tolerance)
    }

    /// The cue moving the scrub to `distance`, in metres along the profile, plays, or nil. `breaks` are the breaks of the
    /// earthworks the panel shows, and `slopeLine` the steepness the slope chart draws (distance, degrees); either is
    /// empty where it does not apply. When one sample meets both, the break is played: the rarer mark, and one cue, since
    /// the Pencil plays both alike.
    public mutating func update(
        to distance: Double, breaks: [Double], slopeLine: [(distance: Double, slope: Double)]
    ) -> HapticCue? {
        // Both see every sample, neither skipped for the other: a detector that missed one would take the next sample
        // for an arrival at a place the scrub was already on.
        let atBreak = breakCrossings.update(to: distance, breaks: breaks)
        let atSlopeLine = slopeCrossings.update(to: distance, along: slopeLine)
        if atBreak { return .earthworkBreak }
        return atSlopeLine ? .slopeLine : nil
    }

    /// Forgets where the scrub was, for when the finger lifts.
    public mutating func reset() {
        breakCrossings.reset()
        slopeCrossings.reset()
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
