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
}
