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
///
/// The samples live in one ``ElevationSampleStorage``: a heap array, or page-aligned pages Metal adopts without a
/// copy and the readers here read in place. Readers in a loop take ``withUnsafeSamples(_:)`` or the subscripts;
/// ``samples`` is the array itself for heap storage and a copy for paged storage.
public nonisolated struct ElevationGrid: Sendable, Equatable {

    /// Column count. Always > 0 for a non-empty grid.
    public let width: Int
    /// Row count.
    public let height: Int
    /// Where the row-major samples, in metres, live: `count == width * height`. `Float.nan` marks a void.
    public let storage: ElevationSampleStorage
    /// The geographic extent this raster covers.
    public let region: GeoRegion

    /// Row-major samples in metres, `count == width * height`. `Float.nan` marks a void. The array itself for a
    /// heap-backed grid; a fresh copy of the pages for a page-aligned one, so not for a loop (use
    /// ``withUnsafeSamples(_:)`` or the subscripts there).
    public var samples: [Float] { storage.array }

    /// Creates a grid, trapping only on an inconsistent buffer length —
    /// a programmer error that must never reach production.
    public init(width: Int, height: Int, samples: [Float], region: GeoRegion) {
        precondition(
            samples.count == width * height,
            "ElevationGrid buffer is \(samples.count) samples but \(width)x\(height) requires \(width * height)"
        )
        self.width = width
        self.height = height
        self.storage = ElevationSampleStorage(heap: samples)
        self.region = region
    }

    /// A grid over `storage`, which must hold exactly `width * height` samples.
    public init(width: Int, height: Int, storage: ElevationSampleStorage, region: GeoRegion) {
        precondition(
            storage.count == width * height,
            "ElevationGrid storage is \(storage.count) samples but \(width)x\(height) requires \(width * height)"
        )
        self.width = width
        self.height = height
        self.storage = storage
        self.region = region
    }

    /// The same grid over `storage`, which must hold the same number of samples: a page-aligned copy taking the
    /// heap array's place.
    public func replacingStorage(_ storage: ElevationSampleStorage) -> ElevationGrid {
        ElevationGrid(width: width, height: height, storage: storage, region: region)
    }

    /// Whether the samples lie in pages Metal adopts without a copy.
    public var isPageAligned: Bool { storage.isPageAligned }

    public var count: Int { width * height }
    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Equal when the shape, the extent and every sample agree, as `[Float]` equality has it: a void never equals
    /// itself, so a grid with one is equal to no grid, as before the storage class.
    public static func == (lhs: ElevationGrid, rhs: ElevationGrid) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height, lhs.region == rhs.region else { return false }
        if lhs.storage === rhs.storage { return lhs.withUnsafeSamples { !$0.contains { $0.isNaN } } }
        return lhs.withUnsafeSamples { a in rhs.withUnsafeSamples { b in a.elementsEqual(b) } }
    }

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
    @inline(__always)
    public subscript(x: Int, y: Int) -> Float {
        storage[y * width + x]
    }

    /// Bounds-checked access returning `nil` outside the raster.
    @inline(__always)
    public func sample(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let value = storage[y * width + x]
        return value.isNaN ? nil : value
    }

    /// True when the sample at this index carries real data.
    @inline(__always)
    public func isValid(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return !storage[y * width + x].isNaN
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

    /// Bilinearly-interpolated elevation at a coordinate.
    ///
    /// ``elevation(at:)`` snaps to the nearest cell, which is the right
    /// choice for a spot readout (it reports an actual measured sample, not a
    /// blend). A transect profile instead walks a continuous line across the
    /// raster, and snapping every step to its nearest cell puts visible
    /// staircase steps in the plotted line at coarser resolutions -- this
    /// interpolates between the four surrounding cells instead.
    ///
    /// Conservative around voids: if any of the four neighbours is missing or
    /// `NaN`, this returns `nil` rather than blending across the gap. Void
    /// pixels are a distinct feature of the terrain and averaging over one
    /// would fabricate a value that erases it.
    public func interpolatedElevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        guard region.contains(coordinate) else { return nil }
        let (col, row) = gridCoordinates(for: coordinate)
        let x0 = Int(floor(col))
        let y0 = Int(floor(row))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        guard
            let v00 = sample(x: x0, y: y0), let v10 = sample(x: x1, y: y0),
            let v01 = sample(x: x0, y: y1), let v11 = sample(x: x1, y: y1)
        else { return nil }

        let fx = Float(col - Double(x0))
        let fy = Float(row - Double(y0))
        let top = v00 + (v10 - v00) * fx
        let bottom = v01 + (v11 - v01) * fx
        return top + (bottom - top) * fy
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
    /// One scalar pass with a running (Welford) mean and variance in `Double`.
    /// Deliberately not `vDSP`: it has no NaN-aware reductions, so a single
    /// void poisons `vDSP_meanv`. Its one caller validates an ImageServer
    /// raster per network fetch, where this pass is noise.
    public func statistics() -> Statistics {
        guard count > 0 else {
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

        withUnsafeSamples { buf in
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

    /// Borrows the contiguous backing buffer, for Accelerate and Metal upload, in place whichever way it is held.
    @inline(__always)
    public func withUnsafeSamples<R>(
        _ body: (UnsafeBufferPointer<Float>) throws -> R
    ) rethrows -> R {
        try storage.withUnsafeBufferPointer(body)
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

/// Where an ``ElevationGrid``'s samples live: a `[Float]` on the heap, or page-aligned pages (`mmap` or
/// `vm_allocate`: a cache file's ``MappedFile`` mapping, a ``COGMappedStorage`` region) that Metal adopts without a
/// copy (``ElevationSamples/mapped(base:mappedLength:sampleOffset:owner:)``) and the CPU reads in place.
///
/// One plane serves both. A tile from disk used to hold its mapping for the shader beside a heap copy for the
/// readouts, and a tile from the network a heap array beside a page-aligned copy made at its second shade: two planes
/// a tile, both counted by the memory budget. Immutable once made, so `@unchecked Sendable` holds.
public nonisolated final class ElevationSampleStorage: @unchecked Sendable {
    public enum Backing: @unchecked Sendable {
        case heap([Float])
        /// `base` is page-aligned and `mappedLength` whole pages; the samples start `sampleOffset` bytes in and `owner`
        /// keeps the pages mapped.
        case pages(base: UnsafeMutableRawPointer, mappedLength: Int, sampleOffset: Int, owner: AnyObject)
    }

    public let backing: Backing
    /// How many samples the storage holds.
    public let count: Int

    public init(heap samples: [Float]) {
        backing = .heap(samples)
        count = samples.count
    }

    /// `count` samples read from `base + sampleOffset`, which `mappedLength` must cover; nil otherwise.
    public init?(base: UnsafeMutableRawPointer, mappedLength: Int, sampleOffset: Int, count: Int, owner: AnyObject) {
        guard count >= 0, sampleOffset >= 0, mappedLength >= sampleOffset + count * MemoryLayout<Float>.stride else { return nil }
        backing = .pages(base: base, mappedLength: mappedLength, sampleOffset: sampleOffset, owner: owner)
        self.count = count
    }

    /// Whether the samples lie in pages Metal adopts without a copy.
    public var isPageAligned: Bool {
        if case .pages = backing { return true }
        return false
    }

    /// Bytes this storage holds: the array's, or the whole mapping's.
    public var byteCount: Int {
        switch backing {
        case .heap(let samples): samples.count * MemoryLayout<Float>.stride
        case .pages(_, let mappedLength, _, _): mappedLength
        }
    }

    /// The samples as an array: the array itself for heap storage, a copy of the pages otherwise.
    public var array: [Float] {
        switch backing {
        case .heap(let samples): return samples
        case .pages(let base, _, let sampleOffset, _):
            let pointer = UnsafeRawPointer(base + sampleOffset).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
    }

    /// The samples as the shader takes them: the pages to adopt, or the array to copy once into a shared buffer.
    public var elevationSamples: ElevationSamples {
        switch backing {
        case .heap(let samples): .array(samples)
        case .pages(let base, let mappedLength, let sampleOffset, let owner):
            .mapped(base: base, mappedLength: mappedLength, sampleOffset: sampleOffset, owner: owner)
        }
    }

    /// Borrows the samples in place, whichever way they are held.
    @inline(__always)
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        switch backing {
        case .heap(let samples):
            return try samples.withUnsafeBufferPointer(body)
        case .pages(let base, _, let sampleOffset, let owner):
            let pointer = UnsafeRawPointer(base + sampleOffset).assumingMemoryBound(to: Float.self)
            return try withExtendedLifetime(owner) { try body(UnsafeBufferPointer(start: pointer, count: count)) }
        }
    }

    @inline(__always)
    public subscript(index: Int) -> Float {
        switch backing {
        case .heap(let samples): return samples[index]
        case .pages(let base, _, let sampleOffset, _):
            return UnsafeRawPointer(base + sampleOffset).load(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
        }
    }
}
