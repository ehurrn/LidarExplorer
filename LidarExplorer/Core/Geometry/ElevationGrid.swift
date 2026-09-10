//
//  ElevationGrid.swift
//  LidarExplorer
//
//  The central raster type for all terrain analysis.
//

import Accelerate
import CoreLocation
import Darwin

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

    /// Fractional column and row coordinates within the raster for a coordinate.
    public func gridCoordinates(for coordinate: CLLocationCoordinate2D) -> (Double, Double) {
        let fx = region.longitudeSpan > 0
            ? (coordinate.longitude - region.minLongitude) / region.longitudeSpan : 0
        let fy = region.latitudeSpan > 0
            ? (region.maxLatitude - coordinate.latitude) / region.latitudeSpan : 0
        return (fx * Double(max(width - 1, 1)), fy * Double(max(height - 1, 1)))
    }

    /// The nearest grid index to a coordinate, or `nil` if outside the region.
    public func index(for coordinate: CLLocationCoordinate2D) -> (x: Int, y: Int)? {
        guard region.contains(coordinate) else { return nil }
        let (col, row) = gridCoordinates(for: coordinate)
        let x = Int(col.rounded())
        let y = Int(row.rounded())
        return (min(max(x, 0), width - 1), min(max(y, 0), height - 1))
    }

    /// Elevation sampled at a coordinate, or `nil` if outside or void.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        guard let idx = index(for: coordinate) else { return nil }
        return sample(x: idx.x, y: idx.y)
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
        var mean = 0.0
        var m2 = 0.0

        samples.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            let total = buf.count
            for i in 0..<total {
                let v = ptr[i]
                if v.isNaN {
                    voidCount += 1
                } else {
                    validCount += 1
                    if v < minimum { minimum = v }
                    if v > maximum { maximum = v }
                    let d = Double(v) - mean
                    mean += d / Double(validCount)
                    let d2 = Double(v) - mean
                    m2 += d * d2
                }
            }
        }

        guard validCount > 0 else {
            return Statistics(
                minimum: .nan, maximum: .nan, mean: .nan,
                standardDeviation: .nan, validCount: 0, voidCount: voidCount
            )
        }

        let variance = m2 / Double(validCount)
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

    /// The extent left after a `margin`-pixel skirt is removed, without
    /// removing it.
    ///
    /// Cropping used to be the only way to learn this, so every tile paid for
    /// a full row-by-row `memcpy` of its raster to find out where it actually
    /// sits. The skirt is a fixed number of pixels off each edge, and Web
    /// Mercator is linear in the projected plane, so the answer is four
    /// multiplications — the samples do not have to move for the bounds to
    /// shrink.
    ///
    /// Inset in projected metres rather than in degrees: latitude is nonlinear
    /// in Mercator, so trimming the same fraction off each end of a latitude
    /// *span* would put the tile in the wrong place, by more the further it is
    /// from the equator.
    public func croppedRegion(margin: Int) -> GeoRegion {
        guard margin > 0, width > margin * 2, height > margin * 2 else { return region }
        let m = region.mercatorBounds
        let dX = (m.maxX - m.minX) * Double(margin) / Double(width)
        let dY = (m.maxY - m.minY) * Double(margin) / Double(height)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX + dX, y: m.minY + dY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX - dX, y: m.maxY - dY)
        return GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
    }

    /// Trims a margin skirt from all four sides, adjusting dimensions and geographic region.
    ///
    /// Superseded on the render path. The display kernel reads its 3x3 window
    /// straight out of the padded buffer at `gid + margin` and dispatches over
    /// the destination tile only, so the skirt costs nothing to keep and this
    /// per-tile copy has no reason to run. Use ``croppedRegion(margin:)`` when
    /// only the bounds are wanted, which is the case that was driving it.
    @available(*, deprecated, message: "Pass margin to the shader instead; use croppedRegion(margin:) for bounds.")
    public func cropped(margin: Int) -> ElevationGrid {
        guard margin > 0, width > margin * 2, height > margin * 2 else { return self }
        let newWidth = width - margin * 2
        let newHeight = height - margin * 2
        let rowBytes = newWidth * MemoryLayout<Float>.stride

        let newSamples = [Float](unsafeUninitializedCapacity: newWidth * newHeight) { dstBuf, initializedCount in
            samples.withUnsafeBufferPointer { srcBuf in
                guard let srcBase = srcBuf.baseAddress,
                      let dstBase = dstBuf.baseAddress else { return }
                for y in 0..<newHeight {
                    let srcOffset = (y + margin) * width + margin
                    let dstOffset = y * newWidth
                    memcpy(dstBase + dstOffset, srcBase + srcOffset, rowBytes)
                }
            }
            initializedCount = newWidth * newHeight
        }

        return ElevationGrid(
            width: newWidth, height: newHeight,
            samples: newSamples, region: croppedRegion(margin: margin)
        )
    }
}
