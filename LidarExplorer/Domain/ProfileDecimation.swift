//
//  ProfileDecimation.swift
//  LidarExplorer
//
//  Keeps chart point counts bounded without hiding narrow features.
//

import Foundation

public nonisolated enum ProfileDecimation {
    /// Min-max decimation: each bucket contributes its lowest and highest point, in
    /// distance order, so a one-sample ditch between display points still reaches
    /// the chart. At most `maxCount` points.
    public static func minMax(_ points: [ElevationProfilePoint], maxCount: Int) -> [ElevationProfilePoint] {
        guard points.count > maxCount, maxCount >= 4 else { return points }
        let buckets = maxCount / 2
        let size = Double(points.count) / Double(buckets)
        var out: [ElevationProfilePoint] = []
        out.reserveCapacity(buckets * 2)
        for b in 0..<buckets {
            let lower = Int((Double(b) * size).rounded(.down))
            let upper = min(Int((Double(b + 1) * size).rounded(.down)), points.count)
            guard lower < upper else { continue }
            let slice = points[lower..<upper]
            guard let low = slice.min(by: { $0.elevationMeters < $1.elevationMeters }),
                  let high = slice.max(by: { $0.elevationMeters < $1.elevationMeters }) else { continue }
            if low.id == high.id {
                out.append(low)
            } else {
                out.append(contentsOf: low.distanceMeters <= high.distanceMeters ? [low, high] : [high, low])
            }
        }
        return out
    }

    /// The slope chart's line: how steep the ground is (the slope's magnitude, whichever way it falls) at `samples` out
    /// to `distance` metres, at most `maxCount` points, each the steepest sample of its stretch. A one-sample peak
    /// reaches the chart, and the line's peak is the steepest sample the chart covers, the Max Slope the panel reads
    /// beside it. Samples with no slope, and those past `distance` (mid-drag, a stale analysis of a longer line; half
    /// an analysis step of slack), are left out.
    public static func steepness(
        _ samples: [ProfileSample], upTo distance: Double, maxCount: Int
    ) -> [(distance: Double, slope: Double)] {
        let limit = distance + 0.5
        let points: [(distance: Double, slope: Double)] = samples.compactMap { sample in
            guard sample.slopeDegrees.isFinite, Double(sample.distance) <= limit else { return nil }
            return (Double(sample.distance), Double(abs(sample.slopeDegrees)))
        }
        guard points.count > maxCount, maxCount >= 1 else { return points }
        let size = Double(points.count) / Double(maxCount)
        var out: [(distance: Double, slope: Double)] = []
        out.reserveCapacity(maxCount)
        for b in 0..<maxCount {
            let lower = Int((Double(b) * size).rounded(.down))
            let upper = min(Int((Double(b + 1) * size).rounded(.down)), points.count)
            guard lower < upper, let steepest = points[lower..<upper].max(by: { $0.slope < $1.slope }) else { continue }
            out.append(steepest)
        }
        return out
    }
}
