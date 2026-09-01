//
//  DetectionSupport.swift
//  LidarExplorer
//
//  Shared primitives for terrain feature detectors.
//

import Accelerate
import Foundation

/// Tunable detector parameters.
///
/// Every value is a physical quantity in metres or a dimensionless ratio —
/// never a grid-cell count. Cell counts silently change meaning when the
/// ground sample distance changes, which is how a threshold tuned on 1 m
/// lidar quietly stops working on a 10 m DEM.
public nonisolated struct DetectionOptions: Sendable, Equatable {

    /// Minimum height above the local background surface, in metres.
    public var minimumReliefMeters: Double = 0.8

    /// Maximum relief before a landform is more likely natural than built.
    public var maximumReliefMeters: Double = 30.0

    /// Smallest plausible horizontal extent, in metres.
    public var minimumExtentMeters: Double = 10.0

    /// Largest plausible horizontal extent, in metres.
    public var maximumExtentMeters: Double = 200.0

    /// Radius of the background-estimation window, in metres.
    ///
    /// Should comfortably exceed the largest feature of interest so the
    /// background represents regional terrain rather than absorbing the
    /// feature itself.
    public var backgroundRadiusMeters: Double = 120.0

    /// Minimum separation between two accepted candidates, in metres.
    public var minimumSeparationMeters: Double = 25.0

    /// Minimum prominence relative to the candidate's own relief, `0...1`.
    public var minimumProminenceRatio: Double = 0.35

    /// Detector score below which a candidate is discarded before
    /// corroboration is attempted.
    public var minimumDetectorScore: Double = 0.35

    public init() {}

    /// Defaults tuned for earthen mound complexes on 1–3 m DEMs.
    public static let `default` = DetectionOptions()
}

/// Raster helpers shared by the detectors.
public nonisolated enum RasterOps {

    /// Separable box blur over a NaN-aware raster.
    ///
    /// Implemented as two 1-D passes, so cost is O(width x height) and
    /// independent of the kernel radius. Voids are skipped rather than
    /// treated as zero — averaging a NaN as 0.0 would drag the background
    /// surface down near data gaps and manufacture apparent relief there.
    ///
    /// - Returns: Row-major means; `NaN` where no valid sample was in range.
    public static func boxBlur(
        _ source: [Float],
        width: Int,
        height: Int,
        radiusX: Int,
        radiusY: Int
    ) -> [Float] {
        guard width > 0, height > 0, source.count == width * height else { return source }
        let rx = max(radiusX, 0)
        let ry = max(radiusY, 0)
        if rx == 0 && ry == 0 { return source }

        // Horizontal pass, accumulating sums and valid counts.
        var hSum = [Float](repeating: 0, count: width * height)
        var hCount = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = y * width
            var runningSum: Float = 0
            var runningCount: Float = 0

            // Prime the window for x = 0.
            for x in 0...min(rx, width - 1) {
                let v = source[row + x]
                if !v.isNaN { runningSum += v; runningCount += 1 }
            }
            hSum[row] = runningSum
            hCount[row] = runningCount

            for x in 1..<width {
                let entering = x + rx
                let leaving = x - rx - 1
                if entering < width {
                    let v = source[row + entering]
                    if !v.isNaN { runningSum += v; runningCount += 1 }
                }
                if leaving >= 0 {
                    let v = source[row + leaving]
                    if !v.isNaN { runningSum -= v; runningCount -= 1 }
                }
                hSum[row + x] = runningSum
                hCount[row + x] = runningCount
            }
        }

        // Vertical pass over the horizontal partial sums.
        var out = [Float](repeating: .nan, count: width * height)
        for x in 0..<width {
            var runningSum: Float = 0
            var runningCount: Float = 0

            for y in 0...min(ry, height - 1) {
                runningSum += hSum[y * width + x]
                runningCount += hCount[y * width + x]
            }
            out[x] = runningCount > 0 ? runningSum / runningCount : .nan

            for y in 1..<height {
                let entering = y + ry
                let leaving = y - ry - 1
                if entering < height {
                    runningSum += hSum[entering * width + x]
                    runningCount += hCount[entering * width + x]
                }
                if leaving >= 0 {
                    runningSum -= hSum[leaving * width + x]
                    runningCount -= hCount[leaving * width + x]
                }
                out[y * width + x] = runningCount > 0 ? runningSum / runningCount : .nan
            }
        }
        return out
    }

    /// Elevation minus a smoothed background surface.
    ///
    /// This is the standard "local relief model" used in archaeological
    /// prospection: it removes regional slope so that a half-metre mound on a
    /// hillside is as visible as one on a floodplain. Detecting on raw
    /// elevation instead makes every candidate a function of regional
    /// topography, which is why hillside features were previously missed.
    public static func localRelief(
        of grid: ElevationGrid,
        backgroundRadiusMeters: Double
    ) -> [Float] {
        let rx = max(Int((backgroundRadiusMeters / max(grid.metersPerColumn, 0.01)).rounded()), 1)
        let ry = max(Int((backgroundRadiusMeters / max(grid.metersPerRow, 0.01)).rounded()), 1)

        let background = boxBlur(
            grid.samples, width: grid.width, height: grid.height, radiusX: rx, radiusY: ry
        )

        var relief = [Float](repeating: .nan, count: grid.count)
        for i in 0..<grid.count {
            let value = grid.samples[i]
            let base = background[i]
            if value.isNaN || base.isNaN { continue }
            relief[i] = value - base
        }
        return relief
    }
}
