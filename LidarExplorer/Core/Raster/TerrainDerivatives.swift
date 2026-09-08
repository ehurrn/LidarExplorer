//
//  TerrainDerivatives.swift
//  LidarExplorer
//
//  Slope, aspect, and hillshade over an ElevationGrid.
//

import Accelerate
import Foundation

/// First-order terrain derivatives computed from an ``ElevationGrid``.
///
/// All products are row-major rasters matching the source grid's dimensions.
/// Voids in the source propagate as `Float.nan` rather than being interpolated
/// away, so downstream detectors can refuse to score over a data gap.
public nonisolated struct TerrainDerivatives: Sendable {
    /// Steepest descent, in degrees from horizontal. `0` is flat.
    public let slopeDegrees: [Float]
    /// Downslope compass direction, in degrees clockwise from north.
    public let aspectDegrees: [Float]
    public let width: Int
    public let height: Int
}

/// Pure-function terrain analysis.
///
/// Every entry point is `nonisolated` and free of shared mutable state, so
/// callers may run these concurrently across regions without coordination.
public nonisolated enum TerrainAnalysis {

    /// Horn's 3x3 method for slope and aspect.
    ///
    /// Horn (1981) is the estimator used by GDAL, ArcGIS, and QGIS. Matching
    /// it means our slope rasters are directly comparable to the reference
    /// tooling archaeologists already trust, which matters far more here than
    /// squeezing out a marginally cheaper kernel.
    ///
    /// Border cells and any cell whose 3x3 neighbourhood contains a void are
    /// emitted as `NaN`.
    public static func derivatives(of grid: ElevationGrid) -> TerrainDerivatives {
        let w = grid.width
        let h = grid.height
        var slope = [Float](repeating: .nan, count: max(w * h, 0))
        var aspect = [Float](repeating: .nan, count: max(w * h, 0))

        guard w >= 3, h >= 3 else {
            return TerrainDerivatives(
                slopeDegrees: slope, aspectDegrees: aspect, width: w, height: h
            )
        }

        // Ground sample distance differs between axes away from the equator.
        let cellX = Float(grid.metersPerColumn)
        let cellY = Float(grid.metersPerRow)
        guard cellX > 0, cellY > 0 else {
            return TerrainDerivatives(
                slopeDegrees: slope, aspectDegrees: aspect, width: w, height: h
            )
        }

        // Hoisted so the inner loop multiplies by a reciprocal instead of
        // dividing (a divide per cell is ~500k divides on a 512-tile).
        let inv8CellX: Float = 1 / (8 * cellX)
        let inv8CellY: Float = 1 / (8 * cellY)
        let radToDeg: Float = 180 / .pi

        grid.withUnsafeSamples { src in
            slope.withUnsafeMutableBufferPointer { slopeOut in
                aspect.withUnsafeMutableBufferPointer { aspectOut in
                    for y in 1..<(h - 1) {
                        let rowAbove = (y - 1) * w
                        let row = y * w
                        let rowBelow = (y + 1) * w
                        for x in 1..<(w - 1) {
                            let a = src[rowAbove + x - 1], b = src[rowAbove + x], c = src[rowAbove + x + 1]
                            let d = src[row + x - 1], center = src[row + x], f = src[row + x + 1]
                            let g = src[rowBelow + x - 1], hh = src[rowBelow + x], i = src[rowBelow + x + 1]

                            // A void anywhere in the kernel — including the
                            // centre cell itself, which Horn's formula never
                            // reads — invalidates the cell. Without the centre
                            // check an isolated void surrounded by valid data
                            // would render opaque over missing terrain.
                            if center.isNaN || a.isNaN || b.isNaN || c.isNaN || d.isNaN
                                || f.isNaN || g.isNaN || hh.isNaN || i.isNaN {
                                continue
                            }

                            // Horn's weighted finite differences.
                            let dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) * inv8CellX
                            let dzdy = ((g + 2 * hh + i) - (a + 2 * b + c)) * inv8CellY

                            let rise = (dzdx * dzdx + dzdy * dzdy).squareRoot()
                            slopeOut[row + x] = atan(rise) * radToDeg

                            // Compass aspect: 0 = north, increasing clockwise.
                            // Flat cells have no defined aspect. Foundation's
                            // atan2(0,0) is 0 (unlike Metal's NaN), but guard
                            // it anyway so both backends behave identically.
                            var deg: Float
                            if dzdx == 0 && dzdy == 0 {
                                deg = 0
                            } else {
                                deg = 90 - atan2(dzdy, -dzdx) * radToDeg
                            }
                            if deg < 0 { deg += 360 }
                            if deg >= 360 { deg -= 360 }
                            aspectOut[row + x] = deg
                        }
                    }
                }
            }
        }

        return TerrainDerivatives(
            slopeDegrees: slope, aspectDegrees: aspect, width: w, height: h
        )
    }

    /// Lambertian hillshade for a single illumination direction.
    ///
    /// - Parameters:
    ///   - azimuthDegrees: Light compass direction, clockwise from north.
    ///   - altitudeDegrees: Light elevation above the horizon.
    /// - Returns: Row-major relief in `0...1`; `NaN` where terrain is unknown.
    public static func hillshade(
        _ derivatives: TerrainDerivatives,
        azimuthDegrees: Double = 315,
        altitudeDegrees: Double = 45
    ) -> [Float] {
        let zenith = Float((90 - altitudeDegrees) * .pi / 180)
        // Azimuth stays in the compass convention, because `aspectDegrees` is
        // also compass (0 = north, increasing clockwise). Applying the
        // familiar ESRI `360 - az + 90` rotation to only one of the two mixes
        // conventions and collapses the cosine term: with light from the east
        // it returns 0 for both an east- and a west-facing slope, so a ridge
        // lit across its axis comes out flatter than one lit along it.
        // Differencing two compass bearings is correct and self-consistent.
        let lightAzimuth = Float(
            azimuthDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        )
        let cosZenith = cos(zenith)
        let sinZenith = sin(zenith)

        var out = [Float](repeating: .nan, count: derivatives.slopeDegrees.count)
        for index in derivatives.slopeDegrees.indices {
            let slopeDeg = derivatives.slopeDegrees[index]
            let aspectDeg = derivatives.aspectDegrees[index]
            if slopeDeg.isNaN || aspectDeg.isNaN { continue }

            let slope = slopeDeg * .pi / 180
            let aspect = aspectDeg * .pi / 180
            let value = cosZenith * cos(slope)
                + sinZenith * sin(slope) * cos(lightAzimuth - aspect)
            out[index] = max(0, min(1, value))
        }
        return out
    }

    /// Multi-directional relief: per-cell standard deviation of hillshades
    /// taken from several azimuths.
    ///
    /// A single light direction is blind to any feature whose long axis runs
    /// parallel to it — the classic reason a linear earthwork disappears from
    /// one hillshade and is obvious in the next. Taking the spread across
    /// directions surfaces exactly those anisotropic features: a cell that
    /// looks bright from one bearing and dark from another has directional
    /// structure, while natural slopes respond uniformly.
    ///
    /// - Returns: Row-major standard deviation per cell; `NaN` where unknown.
    public static func multiDirectionalRelief(
        _ derivatives: TerrainDerivatives,
        azimuths: [Double] = [45, 135, 225, 315],
        altitudeDegrees: Double = 30
    ) -> [Float] {
        guard azimuths.count > 1 else {
            return [Float](repeating: .nan, count: derivatives.slopeDegrees.count)
        }

        let zenith = Float((90 - altitudeDegrees) * .pi / 180)
        let cosZenith = cos(zenith)
        let sinZenith = sin(zenith)
        let lightAzimuths = azimuths.map {
            Float($0.truncatingRemainder(dividingBy: 360) * .pi / 180)
        }
        let n = Float(lightAzimuths.count)

        var out = [Float](repeating: .nan, count: derivatives.slopeDegrees.count)
        for index in derivatives.slopeDegrees.indices {
            let slopeDeg = derivatives.slopeDegrees[index]
            let aspectDeg = derivatives.aspectDegrees[index]
            if slopeDeg.isNaN || aspectDeg.isNaN { continue }

            let slope = slopeDeg * .pi / 180
            let aspect = aspectDeg * .pi / 180
            let baseCos = cosZenith * cos(slope)
            let baseSin = sinZenith * sin(slope)

            var sum: Float = 0
            var sumSquares: Float = 0
            for lightAzimuth in lightAzimuths {
                let value = max(0, min(1, baseCos + baseSin * cos(lightAzimuth - aspect)))
                sum += value
                sumSquares += value * value
            }
            let mean = sum / n
            out[index] = max(0, sumSquares / n - mean * mean).squareRoot()
        }
        return out
    }
}
