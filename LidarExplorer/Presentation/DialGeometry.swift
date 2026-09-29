//
//  DialGeometry.swift
//  LidarExplorer
//
//  The geometry of a circular bearing dial: which bearing a touch asks for, and which compass detent a
//  bearing sits near; and when a drag on the sun dial writes the map's sun (SunDialCommit). Pure, so a drag
//  around the face is testable without a screen (the pattern of PencilRollAzimuth.swift).
//

import CoreGraphics
import Foundation

public nonisolated enum DialGeometry {

    /// A touch that goes down within this share of the dial's diameter of its centre has no bearing until it is a
    /// drag (``Drag``): the inner half of the face, where the readout sits ("315°", about 30 pt across on the 76 pt
    /// dial). A tap on the number to read it swung the sun to wherever the finger landed and re-shaded the map. A share,
    /// not points: the dial and its readout both grow with the text.
    public static let deadZoneShare: CGFloat = 0.25

    /// Once a drag swings the sun, only a touch within this many points of the centre has no bearing, where a hair's
    /// movement turns the bearing right round. The readout's zone reaches to 4 pt from the sun's orbit (3 pt into the
    /// sun itself on the 76 pt dial), so held for the whole drag it stalled a finger following the sun that drifted
    /// inward, then jumped the sun ahead when the finger came back out. (A touch that goes down on the sun has it at
    /// once: ``Drag``.)
    public static let followingDeadZoneRadius: CGFloat = 4

    /// How far, in points, a touch that went down on the readout may wander and still be a tap on it, not a drag.
    public static let tapSlop: CGFloat = 6

    /// The sun's centre orbits this many points inside the dial's rim, inside the ticks.
    public static let sunOrbitInset: CGFloat = 15
    /// The sun's radius in points: the view draws it this size, and a touch that goes down on it takes it.
    public static let sunRadius: CGFloat = 7

    /// Whether `point` is on the sun of a dial `diameter` points across (origin at its top-left corner) whose sun is at
    /// `azimuth` degrees: within ``sunRadius`` of the sun's centre, ``sunOrbitInset`` inside the rim.
    public static func isOnSun(_ point: CGPoint, azimuth: Double, diameter: CGFloat) -> Bool {
        guard azimuth.isFinite, point.x.isFinite, point.y.isFinite else { return false }
        let orbit = diameter / 2 - sunOrbitInset
        let radians = azimuth * .pi / 180
        let dx = point.x - (diameter / 2 + orbit * CGFloat(Foundation.sin(radians)))
        let dy = point.y - (diameter / 2 - orbit * CGFloat(Foundation.cos(radians)))
        return dx * dx + dy * dy <= sunRadius * sunRadius
    }

    /// The compass headings the azimuth haptics tick at, in degrees: the same list, so the dial snaps
    /// where the haptics tick.
    public static let compassDetents: [Double] = AzimuthDetents.headings

    /// The bearing, in degrees [0, 360), north up and clockwise, of `point` from the centre of a dial
    /// `diameter` points across whose origin is its top-left corner; `nil` inside the dead zone: the readout's
    /// (``deadZoneShare``), or only the centre's (``followingDeadZoneRadius``) for a drag already swinging the sun.
    public static func bearing(at point: CGPoint, diameter: CGFloat, following: Bool = false) -> Double? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let deadZone = following ? followingDeadZoneRadius : diameter * deadZoneShare
        guard dx * dx + dy * dy > deadZone * deadZone else { return nil }
        var degrees = Foundation.atan2(Double(dx), Double(-dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees == 360 ? 0 : degrees
    }

    /// One touch on the dial, from touch-down to lift: which bearing each of its samples asks for.
    ///
    /// The readout's dead zone holds only for a touch that went down on the readout and could still be a tap on the
    /// number. The drag follows from its first sample when it went down on the sun (``isOnSun(_:azimuth:diameter:)``,
    /// whose inner edge lies 3 pt inside the readout's zone) or the ring, and otherwise once it reaches the ring or has
    /// wandered further than ``tapSlop`` from where it went down; from then on only the centre's few points
    /// (``followingDeadZoneRadius``) have no bearing. Held to the tap's slop, a drag that grabbed the sun's inner edge
    /// left it still for the first 20 degrees, then jumped it to the finger.
    public struct Drag: Sendable, Equatable {
        public private(set) var start: CGPoint?
        public private(set) var isFollowing = false

        public init() {}

        /// The bearing this sample asks for (``DialGeometry/bearing(at:diameter:following:)``), or `nil` to leave the
        /// sun where it is. The first sample is the touch-down; `sunAzimuth` is where the dial draws the sun, read only
        /// then.
        public mutating func bearing(at point: CGPoint, diameter: CGFloat, sunAt sunAzimuth: Double? = nil) -> Double? {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            if let start {
                let dx = point.x - start.x, dy = point.y - start.y
                if dx * dx + dy * dy > DialGeometry.tapSlop * DialGeometry.tapSlop { isFollowing = true }
            } else {
                start = point
                if let sunAzimuth, DialGeometry.isOnSun(point, azimuth: sunAzimuth, diameter: diameter) { isFollowing = true }
            }
            guard let degrees = DialGeometry.bearing(at: point, diameter: diameter, following: isFollowing) else {
                return nil
            }
            isFollowing = true
            return degrees
        }
    }

    /// The compass detent within `tolerance` degrees of `azimuth`, measured around the circle, or `nil`.
    public static func nearestDetent(to azimuth: Double, tolerance: Double) -> Double? {
        var best: (detent: Double, distance: Double)?
        for detent in compassDetents {
            let distance = abs((azimuth - detent).remainder(dividingBy: 360))
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (detent, distance)
            }
        }
        return best?.detent
    }

    /// The whole degree, 0 to 359, that a readout shows for `azimuth` and VoiceOver speaks: a bearing that rounds
    /// up to 360 reads 0, and one that is not a number reads 0.
    public static func wholeDegrees(_ azimuth: Double) -> Int {
        guard azimuth.isFinite else { return 0 }
        var whole = azimuth.rounded().truncatingRemainder(dividingBy: 360)
        if whole < 0 { whole += 360 }
        return Int(whole)
    }

    /// The bearing one VoiceOver step from `azimuth`, clockwise or not: the next multiple of `step` degrees more
    /// than half a degree along, so a fractional bearing a drag left lands on the grid (and on the compass
    /// headings), and the whole-degree readout always moves. Wrapped into [0, 360).
    public static func adjustedBearing(from azimuth: Double, clockwise: Bool, step: Double = 5) -> Double {
        guard azimuth.isFinite, step > 0 else { return azimuth }
        let next = clockwise
            ? (((azimuth + 0.5) / step).rounded(.down) + 1) * step
            : (((azimuth - 0.5) / step).rounded(.up) - 1) * step
        var wrapped = next.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        return wrapped == 0 ? 0 : wrapped
    }
}

/// When a drag on the sun dial writes the map's sun (`TerrainViewerModel.azimuth`, which re-shades every tile on screen).
///
/// A leading and trailing throttle. A new whole degree is written at once when the last write is at least `interval`
/// old. Otherwise the newest bearing waits for one trailing write, due `interval` after the last, which later samples
/// update but never postpone. The debounce this replaces restarted its 60 ms wait on every sample, and a drag samples
/// every 8 to 17 ms, so the map re-lit only when the drag paused or lifted (the owner's report of 2026-09-28; the
/// barrel roll, which writes whole degrees, re-lit throughout). The dial writes the exact bearing on lift, as before.
public nonisolated struct SunDialCommit: Sendable {
    public enum Step: Equatable, Sendable {
        /// Write this bearing now.
        case write(Double)
        /// Hold it: write what ``fireTrailing(at:)`` returns at this time.
        case scheduleTrailing(at: TimeInterval)
        /// Nothing to do: the whole degree last written, a bearing that is not a number, or one a trailing write covers.
        case none
    }

    public let interval: TimeInterval
    private var lastWrite: TimeInterval?
    private var lastWholeDegree: Int?
    private var pending: Double?
    public private(set) var trailingDue: TimeInterval?

    public init(interval: TimeInterval = 0.05) { self.interval = interval }

    public mutating func sample(_ degrees: Double, at now: TimeInterval) -> Step {
        guard degrees.isFinite else { return .none }
        let whole = DialGeometry.wholeDegrees(degrees)
        // Back on the degree the map already shows: nothing is owed, not even a trailing write of an older bearing.
        guard whole != lastWholeDegree else { pending = nil; return .none }
        if let last = lastWrite, now >= last, now - last < interval - 1e-9 {
            pending = degrees
            guard trailingDue == nil else { return .none }
            trailingDue = last + interval
            return .scheduleTrailing(at: last + interval)
        }
        lastWrite = now
        lastWholeDegree = whole
        pending = nil
        return .write(degrees)
    }

    /// The trailing write came due: the bearing to write, or nil when nothing is owed any more.
    public mutating func fireTrailing(at now: TimeInterval) -> Double? {
        trailingDue = nil
        guard let value = pending else { return nil }
        pending = nil
        lastWrite = now
        lastWholeDegree = DialGeometry.wholeDegrees(value)
        return value
    }

    /// The drag ended: the next one starts afresh.
    public mutating func reset() { self = SunDialCommit(interval: interval) }
}
