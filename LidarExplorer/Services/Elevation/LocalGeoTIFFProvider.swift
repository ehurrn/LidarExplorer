//
//  LocalGeoTIFFProvider.swift
//  LidarExplorer
//
//  A user's own elevation raster as an elevation source: a survey, a drone model, or a national DEM.
//
//  The file is decoded once and held as node-registered samples in its own coordinate system. A request is
//  answered by resampling onto the grid the tile pipeline expects, uniform in Web Mercator across the requested
//  region with samples on its edges, so one source serves a tile at any zoom and every shader runs over it
//  unchanged. Each output node is mapped back into the file's coordinates and read by bilinear interpolation,
//  which is exact where the two grids coincide and never invents data across a void.
//
//  Scope, stated because it is narrower than "any GeoTIFF": single-band, uncompressed, 32-bit float, up to
//  4096 x 4096 (the decoder's limits), in Web Mercator, UTM (WGS84, NAD83) or plain latitude and longitude.
//  Anything else is refused with the reason rather than read wrongly.
//

import CoreLocation
import Foundation

public nonisolated final class LocalGeoTIFFProvider: ElevationProviding, Sendable {

    public enum ImportError: Error, Equatable, Sendable {
        /// Not a TIFF this app can decode, or not there: compressed, over 4096 px, multi-band, truncated.
        case unreadable(String)
        /// A raster of integers, or of some width other than 32-bit float.
        case notFloat32(bitsPerSample: Int, sampleFormat: Int)
        /// No tiepoint and pixel scale, so nothing says where on Earth the raster is.
        case notGeoreferenced
        /// Placed, but in a coordinate system this app cannot project, or in none at all.
        case unsupportedProjection(String)
    }

    private enum CoordinateSystem: Sendable {
        case webMercator
        case utm(zone: Int, hemisphere: UTMProjection.Hemisphere)
        /// Degrees: x is longitude, y is latitude.
        case geographic
    }

    /// The file's name, for display.
    public let name: String
    public let width: Int
    public let height: Int
    /// Bounds, in latitude and longitude, of the ground the samples span.
    public let footprint: GeoRegion

    private let samples: [Float]
    private let system: CoordinateSystem
    /// Position of sample (0, 0) in the file's coordinates, and the spacing between samples.
    private let originX: Double
    private let originY: Double
    private let stepX: Double
    private let stepY: Double

    /// Decodes `url` on the calling thread. Use ``load(from:)`` from the main actor: a 4096 x 4096 file is 64 MB.
    public init(contentsOf url: URL) throws {
        name = url.lastPathComponent

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable("the file could not be read: \(error.localizedDescription)")
        }
        let raster: FloatTIFFDecoder.Raster
        do {
            raster = try FloatTIFFDecoder.decode(data)
        } catch let error as FloatTIFFDecoder.DecodeError {
            throw ImportError.unreadable(error.description)
        } catch {
            throw ImportError.unreadable("\(error)")
        }

        guard raster.sampleFormat == 3, raster.bitsPerSample == 32 else {
            throw ImportError.notFloat32(bitsPerSample: raster.bitsPerSample, sampleFormat: raster.sampleFormat)
        }
        guard let transform = raster.geoTransform else { throw ImportError.notGeoreferenced }
        guard let keys = raster.geoKeys else {
            throw ImportError.unsupportedProjection("the file declares no coordinate system")
        }
        system = try Self.coordinateSystem(for: keys)

        width = raster.width
        height = raster.height
        stepX = transform.pixelSizeX
        stepY = transform.pixelSizeY
        // The decoder returns the tiepoint's position for pixel (0, 0). PixelIsPoint names that pixel's centre;
        // PixelIsArea names its corner, so the sample itself sits half a pixel inside.
        let insetX = keys.isPixelIsPoint ? 0 : transform.pixelSizeX / 2
        let insetY = keys.isPixelIsPoint ? 0 : transform.pixelSizeY / 2
        originX = transform.originX + insetX
        originY = transform.originY - insetY

        // Voids: the declared sentinel, anything that is not a number, and elevations no ground has.
        let sentinel = raster.noDataValue
        samples = raster.samples.map { value in
            guard value.isFinite, MicroTopographyReference.validElevationRange.contains(value), value != sentinel
            else { return .nan }
            return value
        }

        let far = (width - 1, height - 1)
        let corners = [(0, 0), (far.0, 0), (0, far.1), far]
        var latitudes: [Double] = [], longitudes: [Double] = []
        for (column, row) in corners {
            let x = originX + Double(column) * stepX, y = originY - Double(row) * stepY
            let coordinate = Self.coordinate(x: x, y: y, in: system)
            latitudes.append(coordinate.latitude)
            longitudes.append(coordinate.longitude)
        }
        guard latitudes.allSatisfy({ $0.isFinite && abs($0) <= 90 }), longitudes.allSatisfy({ $0.isFinite && abs($0) <= 360 }) else {
            throw ImportError.notGeoreferenced
        }
        footprint = GeoRegion(minLatitude: latitudes.min()!, maxLatitude: latitudes.max()!,
                              minLongitude: longitudes.min()!, maxLongitude: longitudes.max()!)
    }

    /// Decodes off the caller's thread.
    public static func load(from url: URL) async throws -> LocalGeoTIFFProvider {
        try await Task.detached(priority: .userInitiated) { try LocalGeoTIFFProvider(contentsOf: url) }.value
    }

    // MARK: - Coordinate systems

    private static func coordinateSystem(for keys: FloatTIFFDecoder.GeoKeys) throws -> CoordinateSystem {
        // NAD83 and ETRS89 differ from WGS84 by about a metre, which is under the noise of the terrain the app shows.
        let geographic: Set<Int> = [4326, 4269, 4258]
        if keys.modelType == 2 || (keys.projectedEPSG == nil && keys.geographicEPSG != nil) {
            guard let code = keys.geographicEPSG, geographic.contains(code) else {
                throw ImportError.unsupportedProjection("geographic coordinate system EPSG:\(keys.geographicEPSG.map(String.init) ?? "unknown")")
            }
            return .geographic
        }
        guard let code = keys.projectedEPSG, code != 32767 else {
            throw ImportError.unsupportedProjection("a user-defined projected coordinate system")
        }
        if [3857, 900913, 102100].contains(code) { return .webMercator }
        if let utm = UTMProjection.zone(forEPSG: code) { return .utm(zone: utm.zone, hemisphere: utm.hemisphere) }
        throw ImportError.unsupportedProjection(
            "EPSG:\(code) is not handled; only Web Mercator (3857), UTM zones and latitude/longitude are")
    }

    private static func coordinate(x: Double, y: Double, in system: CoordinateSystem) -> (latitude: Double, longitude: Double) {
        switch system {
        case .webMercator:
            let c = GeoRegion.fromMercatorMeters(x: x, y: y)
            return (c.latitude, c.longitude)
        case .utm(let zone, let hemisphere):
            return UTMProjection.inverse(easting: x, northing: y, zone: zone, hemisphere: hemisphere)
        case .geographic:
            return (y, x)
        }
    }

    private func position(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        switch system {
        case .webMercator:
            let m = GeoRegion.toMercatorMeters(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            return (m.x, m.y)
        case .utm(let zone, let hemisphere):
            let p = UTMProjection.forward(latitude: latitude, longitude: longitude, zone: zone, hemisphere: hemisphere)
            return (p.easting, p.northing)
        case .geographic:
            return (longitude, latitude)
        }
    }

    // MARK: - Sampling

    /// Bilinear elevation at a position in the file's coordinates, or NaN outside the samples or across a void.
    ///
    /// A position within a millionth of a pixel of a node is that node, so a request that lands on the samples
    /// returns them exactly and a void beside a sample never contaminates it. The tolerance has to clear the noise
    /// of a region's round trip through latitude and longitude, about a nanometre in a metre, with room to spare;
    /// the error it admits is below a micrometre of position.
    private func value(x: Double, y: Double) -> Float {
        let column = (x - originX) / stepX, row = (originY - y) / stepY
        let slack = 1e-6
        guard column >= -slack, column <= Double(width - 1) + slack, row >= -slack, row <= Double(height - 1) + slack
        else { return .nan }
        let c = min(max(column, 0), Double(width - 1)), r = min(max(row, 0), Double(height - 1))

        var c0 = Int(c.rounded(.down)), r0 = Int(r.rounded(.down))
        var fx = c - Double(c0), fy = r - Double(r0)
        let snap = 1e-6
        if fx < snap { fx = 0 } else if fx > 1 - snap { c0 += 1; fx = 0 }
        if fy < snap { fy = 0 } else if fy > 1 - snap { r0 += 1; fy = 0 }
        let c1 = min(c0 + 1, width - 1), r1 = min(r0 + 1, height - 1)

        func at(_ column: Int, _ row: Int) -> Double { Double(samples[row * width + column]) }
        let v00 = at(c0, r0)
        if fx == 0 && fy == 0 { return Float(v00) }
        if fy == 0 {
            let v10 = at(c1, r0)
            return Float(v00 * (1 - fx) + v10 * fx)
        }
        if fx == 0 {
            let v01 = at(c0, r1)
            return Float(v00 * (1 - fy) + v01 * fy)
        }
        let v10 = at(c1, r0), v01 = at(c0, r1), v11 = at(c1, r1)
        return Float(v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + v01 * (1 - fx) * fy + v11 * fx * fy)
    }

    /// The elevation at a point, or `nil` outside the file or over a void.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        let p = position(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let v = value(x: p.x, y: p.y)
        return v.isNaN ? nil : v
    }

    /// Whether `region` overlaps the ground this file covers.
    public func intersects(_ region: GeoRegion) -> Bool {
        region.minLatitude <= footprint.maxLatitude && region.maxLatitude >= footprint.minLatitude
            && region.minLongitude <= footprint.maxLongitude && region.maxLongitude >= footprint.minLongitude
    }

    /// A grid over `region`, `targetSamples` across its longer side in Web Mercator, samples on its edges.
    ///
    /// Void wherever the file has no data or `region` reaches beyond it. Unavailable when nothing in the region
    /// is covered, so a caller can fall back to another source instead of shading an empty tile.
    public func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        guard (2...8192).contains(targetSamples) else {
            return .unavailable(.implausible(.localFile, description: "\(targetSamples) samples requested"))
        }
        guard intersects(region) else { return .unavailable(.noCoverage(.localFile)) }
        let bounds = region.mercatorBounds
        let spanX = bounds.maxX - bounds.minX, spanY = bounds.maxY - bounds.minY
        guard spanX.isFinite, spanY.isFinite, spanX > 0, spanY > 0 else {
            return .unavailable(.implausible(.localFile, description: "a region with no extent"))
        }

        let columns = spanX >= spanY ? targetSamples : max(2, Int((Double(targetSamples) * spanX / spanY).rounded()))
        let rows = spanX >= spanY ? max(2, Int((Double(targetSamples) * spanY / spanX).rounded())) : targetSamples
        var output = [Float](repeating: .nan, count: columns * rows)
        var covered = false
        for j in 0..<rows {
            let y = bounds.maxY - Double(j) * spanY / Double(rows - 1)
            for i in 0..<columns {
                let x = bounds.minX + Double(i) * spanX / Double(columns - 1)
                let v: Float
                if case .webMercator = system {
                    v = value(x: x, y: y)
                } else {
                    let ll = GeoRegion.fromMercatorMeters(x: x, y: y)
                    let p = position(latitude: ll.latitude, longitude: ll.longitude)
                    v = value(x: p.x, y: p.y)
                }
                output[j * columns + i] = v
                if !v.isNaN { covered = true }
            }
        }
        guard covered else { return .unavailable(.noCoverage(.localFile)) }
        return .observed(
            ElevationGrid(width: columns, height: rows, samples: output, region: region),
            Provenance(source: .localFile))
    }
}
