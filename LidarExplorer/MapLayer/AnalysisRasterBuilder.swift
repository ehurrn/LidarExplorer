//
//  AnalysisRasterBuilder.swift
//  LidarExplorer
//
//  Stitches a map tile and its cached neighbours into one analysis raster.
//

import Foundation
import simd

/// One cached tile's padded raster.
public nonisolated struct AnalysisTileSource: Sendable {
    public let samples: [Float]
    public let paddedWidth: Int
    public let margin: Int

    public init(samples: [Float], paddedWidth: Int, margin: Int) {
        self.samples = samples
        self.paddedWidth = paddedWidth
        self.margin = margin
    }

    var destinationWidth: Int { paddedWidth - 2 * margin }
    var isSquare: Bool { samples.count == paddedWidth * paddedWidth }
}

/// A stitched, decimated raster in page-aligned storage the GPU adopts without a copy.
public nonisolated struct AnalysisRaster: Sendable {
    public let storage: COGMappedStorage
    public let geometry: RasterGeometry
    public let window: DestinationWindow
    public let decimation: Int
    /// Skirt width in tile pixels.
    public let skirt: Int
    /// Neighbour offsets the skirt needed but the cache lacked.
    public let missingNeighbours: [SIMD2<Int32>]

    public var raster: ElevationRaster {
        ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: geometry
        )
    }
}

public nonisolated enum AnalysisRasterBuilder {

    /// The largest power-of-two box that keeps analysis cells no finer than the
    /// source's native spacing, while the decimated tile stays a multiple of 4
    /// pixels wide (linear-texture alignment).
    public static func decimation(
        tileGroundSampleDistance mpp: Double, nativeGroundSampleDistance native: Double, destinationPixels dest: Int
    ) -> Int {
        var factor = 1
        while Double(factor * 2) * mpp <= native * 1.05, dest % (factor * 8) == 0 { factor *= 2 }
        return factor
    }

    /// Tile pixels of skirt covering `radiusMeters` plus a Horn window, rounded up
    /// to a multiple of `2 * decimation` and capped at one tile.
    public static func skirtPixels(
        radiusMeters: Float, groundSampleDistance mpp: Double, decimation f: Int, destinationPixels dest: Int
    ) -> Int {
        let unit = 2 * f
        let needed = Int((Double(radiusMeters) / mpp).rounded(.up)) + unit
        return min((needed + unit - 1) / unit * unit, dest / unit * unit)
    }

    /// The centre tile plus up to eight neighbours, box-decimated by `decimation`.
    ///
    /// Where a neighbour is missing, the centre tile's own padded skirt still
    /// answers its first `margin` pixels; beyond that the value is NaN, which every
    /// kernel treats as a void rather than as terrain.
    public static func build(
        center: AnalysisTileSource,
        skirt: Int,
        decimation f: Int,
        cellSizeX: Float,
        cellSizeY: Float,
        neighbours: [SIMD2<Int32>: AnalysisTileSource]
    ) -> AnalysisRaster? {
        let dest = center.destinationWidth
        let full = dest + 2 * skirt
        guard dest > 0, f > 0, skirt >= 0, skirt <= dest, full % f == 0, center.isSquare else { return nil }
        let outWidth = full / f
        guard let storage = COGMappedStorage(length: outWidth * outWidth * 4) else { return nil }
        let out = storage.pointer.bindMemory(to: Float.self, capacity: outWidth * outWidth)

        var tiles = [AnalysisTileSource?](repeating: nil, count: 9)
        tiles[4] = center
        var missing: [SIMD2<Int32>] = []
        if skirt > center.margin {
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let offset = SIMD2(Int32(dx), Int32(dy))
                    if let t = neighbours[offset], t.paddedWidth == center.paddedWidth, t.margin == center.margin, t.isSquare {
                        tiles[(dy + 1) * 3 + dx + 1] = t
                    } else {
                        missing.append(offset)
                    }
                }
            }
        }

        func sample(_ gx: Int, _ gy: Int) -> Float {
            let tx = gx < 0 ? -1 : (gx >= dest ? 1 : 0)
            let ty = gy < 0 ? -1 : (gy >= dest ? 1 : 0)
            if let t = tiles[(ty + 1) * 3 + tx + 1] {
                let lx = gx - tx * dest + t.margin, ly = gy - ty * dest + t.margin
                if lx >= 0, ly >= 0, lx < t.paddedWidth, ly < t.paddedWidth { return t.samples[ly * t.paddedWidth + lx] }
            }
            let m = center.margin
            guard gx >= -m, gy >= -m, gx < dest + m, gy < dest + m else { return .nan }
            return center.samples[(gy + m) * center.paddedWidth + gx + m]
        }

        for oy in 0..<outWidth {
            for ox in 0..<outWidth {
                var sum: Float = 0
                var count = 0
                for j in 0..<f {
                    for i in 0..<f {
                        let v = sample(ox * f + i - skirt, oy * f + j - skirt)
                        if !v.isNaN {
                            sum += v
                            count += 1
                        }
                    }
                }
                out[oy * outWidth + ox] = count > 0 ? sum / Float(count) : .nan
            }
        }

        return AnalysisRaster(
            storage: storage,
            geometry: RasterGeometry(width: outWidth, height: outWidth,
                                     cellSizeX: cellSizeX * Float(f), cellSizeY: cellSizeY * Float(f)),
            window: DestinationWindow(originX: skirt / f, originY: skirt / f, width: dest / f, height: dest / f),
            decimation: f, skirt: skirt, missingNeighbours: missing
        )
    }
}
