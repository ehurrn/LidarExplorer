//
//  MercatorMosaicBuilder.swift
//  LidarExplorer
//
//  Rasterises cached tiles onto one Mercator-aligned grid for wide-area analysis.
//

import CoreLocation
import Foundation
import simd

/// A square, Mercator-aligned elevation grid in page-aligned storage.
public nonisolated struct MercatorMosaic: Sendable {
    public let storage: COGMappedStorage
    public let size: Int
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double
    /// Ground metres per cell at the mosaic centre.
    public let cellSizeMeters: Float

    /// The mosaic's outer edge: where an image laid over it belongs. For a grid of its samples use
    /// ``nodeRegisteredRegion``.
    public var region: GeoRegion {
        let sw = GeoRegion.fromMercatorMeters(x: minX, y: minY)
        let ne = GeoRegion.fromMercatorMeters(x: maxX, y: maxY)
        return GeoRegion(minLatitude: sw.latitude, maxLatitude: ne.latitude, minLongitude: sw.longitude, maxLongitude: ne.longitude)
    }

    /// The region a node-registered ``ElevationGrid`` over the whole mosaic must carry: the extent of the cell
    /// *centres*, half a cell in from ``region``'s outer edge.
    ///
    /// ``ElevationGrid`` and ``GeoTIFFWriter`` place the first and last samples ON the region's edges. Labelling
    /// the mosaic's samples with ``region`` instead scales every cell by n / (n - 1) and moves samples up to
    /// half a cell, growing from the centre out to the perimeter.
    public var nodeRegisteredRegion: GeoRegion {
        nodeRegisteredRegion(columns: 0..<size, rows: 0..<size)
    }

    /// The same for the block of cells `columns` by `rows` (rows count down from the top edge, as raster rows
    /// do), for a grid over a window of the mosaic. Both ranges must be non-empty.
    public func nodeRegisteredRegion(columns: Range<Int>, rows: Range<Int>) -> GeoRegion {
        let cellX = (maxX - minX) / Double(size)
        let cellY = (maxY - minY) / Double(size)
        let southWest = GeoRegion.fromMercatorMeters(
            x: minX + (Double(columns.lowerBound) + 0.5) * cellX, y: maxY - (Double(rows.upperBound) - 0.5) * cellY)
        let northEast = GeoRegion.fromMercatorMeters(
            x: minX + (Double(columns.upperBound) - 0.5) * cellX, y: maxY - (Double(rows.lowerBound) + 0.5) * cellY)
        return GeoRegion(
            minLatitude: southWest.latitude, maxLatitude: northEast.latitude,
            minLongitude: southWest.longitude, maxLongitude: northEast.longitude)
    }

    public var raster: ElevationRaster {
        ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: RasterGeometry(width: size, height: size, cellSizeX: cellSizeMeters, cellSizeY: cellSizeMeters)
        )
    }

    /// Fractional pixel coordinates (centres at integers) of a coordinate.
    public func pixel(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        let p = GeoRegion.toMercatorMeters(coordinate)
        return SIMD2(Float((p.x - minX) / (maxX - minX) * Double(size) - 0.5),
                     Float((maxY - p.y) / (maxY - minY) * Double(size) - 0.5))
    }
}

public nonisolated enum MercatorMosaicBuilder {
    /// Ground cell for a viewshed radius: 1 m to 1 km, 2.5 m to 2.5 km, 5 m beyond.
    public static func tieredCellSize(radiusMeters: Double) -> Double {
        radiusMeters <= 1_000 ? 1 : (radiusMeters <= 2_500 ? 2.5 : 5)
    }

    /// Layers are drawn coarse to fine, so finer layers overwrite where they answer.
    public static func build(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        finestGroundSampleDistance: Double,
        maximumSize: Int = 2048,
        layers: [TileMosaicField.Layer]
    ) -> MercatorMosaic? {
        guard radiusMeters > 0, maximumSize >= 4 else { return nil }
        var cell = max(tieredCellSize(radiusMeters: radiusMeters), finestGroundSampleDistance)
        var size = Int((2 * radiusMeters / cell).rounded(.up))
        size = min(max((size + 3) / 4 * 4, 4), maximumSize / 4 * 4)
        cell = max(cell, 2 * radiusMeters / Double(size))

        let k = cos(center.latitude * .pi / 180)
        let half = Double(size) * cell / 2 / k
        let c = GeoRegion.toMercatorMeters(center)
        let minX = c.x - half, maxX = c.x + half, minY = c.y - half, maxY = c.y + half
        guard let storage = COGMappedStorage(length: size * size * 4) else { return nil }
        let out = storage.pointer.bindMemory(to: Float.self, capacity: size * size)
        out.initialize(repeating: .nan, count: size * size)
        let pixel = (maxX - minX) / Double(size)

        for layer in layers.sorted(by: { $0.grid.groundSampleDistance > $1.grid.groundSampleDistance }) {
            let b = layer.bounds.mercatorBounds
            let x0 = max(Int(((b.minX - minX) / pixel).rounded(.down)), 0)
            let x1 = min(Int(((b.maxX - minX) / pixel).rounded(.up)), size)
            let y0 = max(Int(((maxY - b.maxY) / pixel).rounded(.down)), 0)
            let y1 = min(Int(((maxY - b.minY) / pixel).rounded(.up)), size)
            guard x0 < x1, y0 < y1 else { continue }
            for py in y0..<y1 {
                let my = maxY - (Double(py) + 0.5) * pixel
                for px in x0..<x1 {
                    let coordinate = GeoRegion.fromMercatorMeters(x: minX + (Double(px) + 0.5) * pixel, y: my)
                    guard layer.bounds.contains(coordinate), let v = layer.grid.interpolatedElevation(at: coordinate) else { continue }
                    out[py * size + px] = v
                }
            }
        }
        return MercatorMosaic(storage: storage, size: size, minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                              cellSizeMeters: Float(cell))
    }
}
