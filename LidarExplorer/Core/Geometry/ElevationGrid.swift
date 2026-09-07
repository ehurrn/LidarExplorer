//
//  ElevationGrid.swift
//  LidarExplorer
//
//  The central raster type for all terrain analysis.
//

import Accelerate
import CoreLocation

/// A georeferenced, row-major raster of terrain elevations in metres.
///
/// ## Why not `[[Double]]`
///
/// The previous representation was an array of arrays of `Double`. That is
/// wrong on four counts, and every one of them is load-bearing here:
///
/// 1. **Not contiguous.** `[[Double]]` is an array of independent heap
///    buffers. Neither Accelerate nor Metal can consume it without a copy,
///    and every row access is a pointer indirection.
/// 2. **Twice the width for no precision.** DEM vertical accuracy is
///    centimetre-scale at best. `Float` carries a 24-bit mantissa — around
///    0.5 mm of resolution at 8 000 m of elevation. `Double` buys nothing
///    and halves cache residency.
/// 3. **No georeferencing.** Callers had to thread a separate region through
///    every function and re-derive metres-per-cell independently, which is
///    exactly where scale bugs breed.
/// 4. **No nodata.** Real DEMs have voids. Encoding them as `0.0` silently
///    turns a data gap into a sea-level cliff and manufactures false
///    detections along its edges.
///
/// Voids are represented as `Float.nan` and are excluded from every
/// statistic and every detector.
public nonisolated struct ElevationGrid: Sendable, Equatable {

    /// Column count. Always > 0 for a non-empty grid.
    public let width: Int
    /// Row count.
    public let height: Int
    /// Row-major samples in metres, `count == width * height`.
    /// `Float.nan` marks a void.
    public let samples: [Float]
    /// The geographic extent this raster covers.
    public let region: GeoRegion

    /// Creates a grid, trapping only on an inconsistent buffer length —
    /// a programmer error that must never reach production.
    public init(width: Int, height: Int, samples: [Float], region: GeoRegion) {
        precondition(
            samples.count == width * height,
            "ElevationGrid buffer is \(samples.count) samples but \(width)x\(height) requires \(width * height)"
        )
        self.width = width
        self.height = height
        self.samples = samples
        self.region = region
    }

    public var count: Int { width * height }
    public var isEmpty: Bool { width == 0 || height == 0 }

    // MARK: - Ground sample distance

    /// East–west ground distance between adjacent columns, in metres.
    public var metersPerColumn: Double {
        width > 1 ? region.widthMeters / Double(width - 1) : region.widthMeters
    }

    /// North–south ground distance between adjacent rows, in metres.
    public var metersPerRow: Double {
        height > 1 ? region.heightMeters / Double(height - 1) : region.heightMeters
    }

    /// Mean ground sample distance, for detectors that assume square cells.
    public var groundSampleDistance: Double {
        (metersPerColumn + metersPerRow) / 2
    }

    // MARK: - Element access

    /// Unchecked access. Callers must guarantee bounds; used in hot loops.
    @inlinable
    public subscript(x: Int, y: Int) -> Float {
        samples[y * width + x]
    }

    /// Bounds-checked access returning `nil` outside the raster.
    @inlinable
    public func sample(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let value = samples[y * width + x]
        return value.isNaN ? nil : value
    }

    /// True when the sample at this index carries real data.
    @inlinable
    public func isValid(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return !samples[y * width + x].isNaN
    }

    // MARK: - Georeferencing

    /// The geographic coordinate at the centre of a grid cell.
    ///
    /// Row 0 is the *northern* edge, matching raster convention and the
    /// row order returned by every DEM service this app talks to.
    public func coordinate(x: Int, y: Int) -> CLLocationCoordinate2D {
        let fx = width > 1 ? Double(x) / Double(width - 1) : 0.5
        let fy = height > 1 ? Double(y) / Double(height - 1) : 0.5
        return CLLocationCoordinate2D(
            latitude: region.maxLatitude - fy * region.latitudeSpan,
            longitude: region.minLongitude + fx * region.longitudeSpan
        )
    }

    /// The nearest grid index to a coordinate, or `nil` if outside the region.
    public func index(for coordinate: CLLocationCoordinate2D) -> (x: Int, y: Int)? {
        guard region.contains(coordinate) else { return nil }
        let fx = region.longitudeSpan > 0
            ? (coordinate.longitude - region.minLongitude) / region.longitudeSpan : 0
        let fy = region.latitudeSpan > 0
            ? (region.maxLatitude - coordinate.latitude) / region.latitudeSpan : 0
        let x = Int((fx * Double(max(width - 1, 1))).rounded())
        let y = Int((fy * Double(max(height - 1, 1))).rounded())
        return (min(max(x, 0), width - 1), min(max(y, 0), height - 1))
    }

    // MARK: - Statistics

    /// Summary statistics over valid samples only.
    public struct Statistics: Sendable, Equatable {
        public let minimum: Float
        public let maximum: Float
        public let mean: Float
        public let standardDeviation: Float
        /// Number of samples carrying real data.
        public let validCount: Int
        /// Number of `NaN` voids.
        public let voidCount: Int

        public var range: Float { maximum - minimum }
        /// Fraction of the raster carrying real data, 0...1.
        public var coverage: Double {
            let total = validCount + voidCount
            return total > 0 ? Double(validCount) / Double(total) : 0
        }
    }

    /// Computes statistics, skipping voids.
    ///
    /// Uses Accelerate on the fast path when the raster is void-free, and
    /// falls back to a compacting pass when it is not — `vDSP` has no
    /// NaN-aware reductions, and letting a NaN into `vDSP_meanv` poisons
    /// the entire result.
    public func statistics() -> Statistics {
        guard !samples.isEmpty else {
            return Statistics(
                minimum: 0, maximum: 0, mean: 0,
                standardDeviation: 0, validCount: 0, voidCount: 0
            )
        }

        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var validCount = 0
        var voidCount = 0
        var sum = 0.0

        for value in samples {
            if value.isNaN {
                voidCount += 1
            } else {
                validCount += 1
                if value < minimum { minimum = value }
                if value > maximum { maximum = value }
                sum += Double(value)
            }
        }

        guard validCount > 0 else {
            return Statistics(
                minimum: .nan, maximum: .nan, mean: .nan,
                standardDeviation: .nan, validCount: 0, voidCount: voidCount
            )
        }

        let mean = sum / Double(validCount)
        var sumSquaredDeviation = 0.0
        for value in samples where !value.isNaN {
            let deviation = Double(value) - mean
            sumSquaredDeviation += deviation * deviation
        }
        let variance = sumSquaredDeviation / Double(validCount)

        return Statistics(
            minimum: minimum,
            maximum: maximum,
            mean: Float(mean),
            standardDeviation: Float(variance.squareRoot()),
            validCount: validCount,
            voidCount: voidCount
        )
    }

    // MARK: - Buffer access

    /// Borrows the contiguous backing buffer, for Accelerate and Metal upload.
    @inlinable
    public func withUnsafeSamples<R>(
        _ body: (UnsafeBufferPointer<Float>) throws -> R
    ) rethrows -> R {
        try samples.withUnsafeBufferPointer(body)
    }

    /// Trims a margin skirt from all four sides, adjusting dimensions and geographic region.
    public func cropped(margin: Int) -> ElevationGrid {
        guard margin > 0, width > margin * 2, height > margin * 2 else { return self }
        let newWidth = width - margin * 2
        let newHeight = height - margin * 2

        var newSamples = [Float](repeating: .nan, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let srcOffset = (y + margin) * width + margin
            let dstOffset = y * newWidth
            newSamples.replaceSubrange(
                dstOffset..<(dstOffset + newWidth),
                with: samples[srcOffset..<(srcOffset + newWidth)]
            )
        }

        // Adjust region inwards proportionally in Web Mercator coordinates.
        let m = region.mercatorBounds
        let spanX = m.maxX - m.minX
        let spanY = m.maxY - m.minY
        let dX = spanX * Double(margin) / Double(width)
        let dY = spanY * Double(margin) / Double(height)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX + dX, y: m.minY + dY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX - dX, y: m.maxY - dY)
        let newRegion = GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )

        return ElevationGrid(
            width: newWidth, height: newHeight,
            samples: newSamples, region: newRegion
        )
    }
}
