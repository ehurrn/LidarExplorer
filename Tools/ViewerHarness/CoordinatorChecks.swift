//
//  CoordinatorChecks.swift
//  ViewerHarness
//
//  Offline checks for the COG streaming coordinator's pure pieces.
//

import CoreLocation
import Foundation
import simd

@MainActor
func runCoordinatorOfflineChecks() async {
    print("\n=== ElevationTileCoordinator (offline: resampling, ranking, zero-copy decode) ===")

    // --- In-place LZW + predictor match the array path on the real fixture.
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cog_tile_lzw_fp_256x256.bin")
    if let compressed = try? Data(contentsOf: fixtureURL),
       let reference = TIFFLZWDecoder.decode([UInt8](compressed), expectedByteCount: 256 * 256 * 4),
       let storage = COGMappedStorage(length: 256 * 256 * 4) {
        let destination = UnsafeMutableRawBufferPointer(start: storage.pointer, count: 256 * 256 * 4)
        let ok = compressed.withUnsafeBytes { TIFFLZWDecoder.decode($0, into: destination) }
        let bytesMatch = ok && memcmp(storage.pointer, reference, reference.count) == 0
        check("LZW decodes straight into page-aligned storage, byte-identical to the array path", bytesMatch)
        TIFFFloatingPointPredictor.decodeInPlace(destination, width: 256, height: 256)
        let expected = TIFFFloatingPointPredictor.decode(reference, width: 256, height: 256)
        check("the predictor reverses in place, byte-identical to the copying path",
              memcmp(storage.pointer, expected, expected.count) == 0)
        let first = storage.pointer.load(as: Float.self)
        check("in-place decode reproduces GDAL's first sample", abs(first - 123.91963) < 0.001, "\(first)")
    } else {
        check("COG fixture decodes for the in-place comparison", false)
    }

    // --- Resampling a synthetic zone-15 COG onto a Mercator footprint.
    // Elevation is linear in pixel coordinates, which bilinear interpolation
    // reproduces exactly -- so any error is placement, not interpolation.
    let anchor = UTMProjection.forward(latitude: 38.66, longitude: -90.06, zone: 15, hemisphere: .north)
    let geo = COGGeoreference(
        zone: 15, hemisphere: .north,
        tiepointX: (anchor.easting / 1).rounded(.down) - 256, tiepointY: (anchor.northing / 1).rounded(.up) + 256,
        pixelSizeX: 1, pixelSizeY: 1, width: 512, height: 512, tileWidth: 256, tileHeight: 256, noDataValue: nil
    )
    func synthetic(_ px: Double, _ py: Double) -> Double { 100 + 0.05 * px - 0.02 * py }
    var tiles: [[Float]] = []
    for row in 0..<2 {
        for column in 0..<2 {
            var t = [Float](repeating: 0, count: 256 * 256)
            for y in 0..<256 { for x in 0..<256 {
                t[y * 256 + x] = Float(synthetic(Double(column * 256 + x), Double(row * 256 + y)))
            } }
            tiles.append(t)
        }
    }
    tiles[3][100 * 256 + 100] = .nan   // void at source pixel (356, 356)

    let center = geo.coordinate(forPixel: SIMD2(256, 256))
    let region = GeoRegion(center: center, latitudeSpan: 0.0025, longitudeSpan: 0.0032)
    let size = 200
    var output = [Float](repeating: .nan, count: size * size)
    let written = output.withUnsafeMutableBufferPointer { out in
        tiles.withUnsafeBufferPointer { _ in
            COGResampler.resample(region: region, width: size, height: size, georeference: geo, into: out.baseAddress!) { column, row in
                guard column >= 0, column < 2, row >= 0, row < 2 else { return nil }
                return tiles[row * 2 + column].withUnsafeBufferPointer { $0.baseAddress! }
            }
        }
    }
    let m = region.mercatorBounds
    var maxError = 0.0
    var nanNearVoid = false
    for oy in stride(from: 0, to: size, by: 7) {
        for ox in stride(from: 0, to: size, by: 7) {
            let c = GeoRegion.fromMercatorMeters(
                x: m.minX + (Double(ox) + 0.5) * (m.maxX - m.minX) / Double(size),
                y: m.maxY - (Double(oy) + 0.5) * (m.maxY - m.minY) / Double(size))
            let p = geo.pixel(for: c)
            let v = output[oy * size + ox]
            if abs(p.x - 356) < 1 && abs(p.y - 356) < 1 {
                if v.isNaN { nanNearVoid = true }
                continue
            }
            if !v.isNaN { maxError = max(maxError, abs(Double(v) - synthetic(p.x, p.y))) }
        }
    }
    check("resampling covers the footprint", written > size * size * 99 / 100, "\(written)")
    check("block-interpolated UTM placement matches exact projection (< 1 mm of synthetic relief)", maxError < 0.001, "\(maxError)")
    let voidProbe = geo.coordinate(forPixel: SIMD2(356.2, 356.3))
    let (vx, vy) = (
        Int(((GeoRegion.toMercatorMeters(voidProbe).x - m.minX) / (m.maxX - m.minX) * Double(size)).rounded(.down)),
        Int(((m.maxY - GeoRegion.toMercatorMeters(voidProbe).y) / (m.maxY - m.minY) * Double(size)).rounded(.down))
    )
    check("a source void stays a void rather than being blended away",
          nanNearVoid || output[vy * size + vx].isNaN, "sample at \(vx),\(vy) = \(output[vy * size + vx])")

    // Georeference round trip.
    let probe = CLLocationCoordinate2D(latitude: 38.6601, longitude: -90.0599)
    let back = geo.coordinate(forPixel: geo.pixel(for: probe))
    check("pixel <-> coordinate round trip is exact to 1e-7 degrees",
          abs(back.latitude - probe.latitude) < 1e-7 && abs(back.longitude - probe.longitude) < 1e-7)
    check("tile coverage lists the 2x2 tiles a central region straddles", geo.tiles(covering: region).count == 4,
          "\(geo.tiles(covering: region))")

    // --- Product ranking: containing beats merely intersecting; newest wins.
    let target = GeoRegion(minLatitude: 38.66, maxLatitude: 38.661, minLongitude: -90.06, maxLongitude: -90.059)
    let old = DEMProduct(title: "old", url: URL(string: "https://x/old.tif")!,
                         bounds: GeoRegion(minLatitude: 38.6, maxLatitude: 38.7, minLongitude: -90.1, maxLongitude: -90.0),
                         publicationDate: "2019-01-01")
    let new = DEMProduct(title: "new", url: URL(string: "https://x/new.tif")!,
                         bounds: old.bounds, publicationDate: "2024-06-01")
    let partial = DEMProduct(title: "partial", url: URL(string: "https://x/partial.tif")!,
                             bounds: GeoRegion(minLatitude: 38.6605, maxLatitude: 38.7, minLongitude: -90.1, maxLongitude: -90.0),
                             publicationDate: "2026-01-01")
    let far = DEMProduct(title: "far", url: URL(string: "https://x/far.tif")!,
                         bounds: GeoRegion(minLatitude: 40, maxLatitude: 41, minLongitude: -90.1, maxLongitude: -90.0),
                         publicationDate: "2026-01-01")
    let ranked = ElevationTileCoordinator.rank([partial, old, far, new], for: target).map(\.title)
    check("products rank containing-then-newest, dropping ones that miss", ranked == ["new", "old", "partial"], "\(ranked)")
    let cell = ElevationTileCoordinator.queryCell(for: target)
    check("discovery queries snap to a shared 0.05 degree cell",
          abs(cell.minLatitude - 38.65) < 1e-9 && abs(cell.maxLongitude + 90.05) < 1e-9, "\(cell)")
}
