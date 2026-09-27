//
//  ElevationProfile.swift
//  LidarExplorer
//
//  Data structures representing a 2D cross-sectional elevation profile along a transect.
//

import CoreLocation
import Foundation

/// A single sample point along a cross-sectional elevation profile.
public nonisolated struct ElevationProfilePoint: Sendable, Identifiable, Equatable {
    public let id: Int
    /// Cumulative distance from the start of the transect in metres.
    public let distanceMeters: Double
    /// Ground elevation in metres; NaN where there is no ground to read (a transect drag's live profile over tiles
    /// not drawn yet).
    public let elevationMeters: Float
    /// Geographic coordinate of this sample point.
    public let coordinate: CLLocationCoordinate2D
    /// Whether this point was sampled from native high-resolution LiDAR (vs. regional fallback).
    public let isHighResolution: Bool

    public init(
        id: Int,
        distanceMeters: Double,
        elevationMeters: Float,
        coordinate: CLLocationCoordinate2D,
        isHighResolution: Bool = true
    ) {
        self.id = id
        self.distanceMeters = distanceMeters
        self.elevationMeters = elevationMeters
        self.coordinate = coordinate
        self.isHighResolution = isHighResolution
    }

    public static func == (lhs: ElevationProfilePoint, rhs: ElevationProfilePoint) -> Bool {
        lhs.id == rhs.id
            && abs(lhs.distanceMeters - rhs.distanceMeters) < 0.01
            && (abs(lhs.elevationMeters - rhs.elevationMeters) < 0.01
                || (lhs.elevationMeters.isNaN && rhs.elevationMeters.isNaN))
            && lhs.isHighResolution == rhs.isHighResolution
    }
}

/// A complete 2-point cross-sectional elevation profile across terrain.
///
/// A point with no ground (a NaN elevation) is a gap: it counts toward the length, never toward the climb, descent,
/// elevation range or steepest slope, and it breaks the pair on either side of it, as `TransectAnalysis` treats a void.
public nonisolated struct ElevationProfile: Sendable, Equatable {
    public let start: CLLocationCoordinate2D
    public let end: CLLocationCoordinate2D
    public let totalDistanceMeters: Double
    public let elevationGainMeters: Double
    public let elevationLossMeters: Double
    public let minElevationMeters: Float
    public let maxElevationMeters: Float
    /// Steepest slope encountered along the transect in degrees (0...90).
    public let maxSlopeDegrees: Float
    public let points: [ElevationProfilePoint]

    public init(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        points: [ElevationProfilePoint]
    ) {
        self.start = start
        self.end = end
        self.points = points

        let totalDist = points.last?.distanceMeters ?? 0
        self.totalDistanceMeters = totalDist

        var gain = 0.0
        var loss = 0.0
        var minElev = Float.greatestFiniteMagnitude
        var maxElev = -Float.greatestFiniteMagnitude
        var maxSlope: Float = 0

        for i in 0..<points.count {
            let p = points[i]
            guard p.elevationMeters.isFinite else { continue }
            if p.elevationMeters < minElev { minElev = p.elevationMeters }
            if p.elevationMeters > maxElev { maxElev = p.elevationMeters }

            if i > 0, points[i - 1].elevationMeters.isFinite {
                let prev = points[i - 1]
                let dDist = p.distanceMeters - prev.distanceMeters
                let dElev = Double(p.elevationMeters - prev.elevationMeters)

                if dElev > 0 {
                    gain += dElev
                } else {
                    loss += abs(dElev)
                }

                if dDist > 0.1 {
                    let slopeRad = atan(abs(dElev) / dDist)
                    let slopeDeg = Float(slopeRad * 180.0 / .pi)
                    if slopeDeg > maxSlope { maxSlope = slopeDeg }
                }
            }
        }

        self.elevationGainMeters = gain
        self.elevationLossMeters = loss
        self.minElevationMeters = minElev == Float.greatestFiniteMagnitude ? 0 : minElev
        self.maxElevationMeters = maxElev == -Float.greatestFiniteMagnitude ? 0 : maxElev
        self.maxSlopeDegrees = min(maxSlope, 90.0)
    }

    /// The unbroken runs of ground along the profile: each point that has ground, by id, mapped to the index of its
    /// run. A point with no ground belongs to none and ends the run before it, so a chart draws a gap there, not a line
    /// to sea level or across the hole.
    public var groundRuns: [Int: Int] {
        var runs: [Int: Int] = [:]
        var run = 0
        var inRun = false
        for p in points {
            if p.elevationMeters.isFinite {
                runs[p.id] = run
                inRun = true
            } else if inRun {
                run += 1
                inRun = false
            }
        }
        return runs
    }

    public static func == (lhs: ElevationProfile, rhs: ElevationProfile) -> Bool {
        lhs.start.latitude == rhs.start.latitude
            && lhs.start.longitude == rhs.start.longitude
            && lhs.end.latitude == rhs.end.latitude
            && lhs.end.longitude == rhs.end.longitude
            && lhs.points == rhs.points
    }
}
