//
//  LocalGeoTIFFChecks.swift
//  ViewerHarness
//
//  Importing a user's own float GeoTIFF as an elevation source: what the decoder reads from the file, that the
//  provider resamples it onto the tile grid without moving a sample, that it refuses what it cannot read, and
//  that the tile provider prefers it over the cache and the network without pinning it to disk.
//

import CoreLocation
import Foundation
import MapKit
import simd

@MainActor
func runLocalGeoTIFFChecks() async {
    print("\n=== Local GeoTIFF ingestion ===")
    checkGeoKeyDecoding()
    await checkLocalRoundTrip()
    await checkLocalProjections()
    await checkLocalRefusals()
    await checkLocalCoverage()
    await checkLocalTileProvider()
    await checkLocalElevationImport()
}

// MARK: - Building test files

/// A minimal little-endian single-strip TIFF, with exactly the tags a test asks for and no more.
private struct TestTIFF {
    var width: Int
    var height: Int
    var floats: [Float] = []
    /// When set, the file holds 16-bit signed integers instead of floats.
    var int16s: [Int16] = []
    var scale: [Double]?
    var tiepoint: [Double]?
    var geoKeys: [UInt16]?
    var noData: String?
    var compression: UInt16 = 1

    func data() -> Data {
        let isInteger = !int16s.isEmpty
        var pixels = Data()
        if isInteger {
            for v in int16s { withUnsafeBytes(of: v.littleEndian) { pixels.append(contentsOf: $0) } }
        } else {
            for v in floats { withUnsafeBytes(of: v.bitPattern.littleEndian) { pixels.append(contentsOf: $0) } }
        }

        struct Entry {
            let tag: UInt16
            let type: UInt16
            let count: UInt32
            var value: UInt32
            var payload: Data?
        }
        func doubles(_ values: [Double]) -> Data {
            var d = Data()
            for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
            return d
        }
        var entries: [Entry] = [
            Entry(tag: 256, type: 4, count: 1, value: UInt32(width)),
            Entry(tag: 257, type: 4, count: 1, value: UInt32(height)),
            Entry(tag: 258, type: 3, count: 1, value: isInteger ? 16 : 32),
            Entry(tag: 259, type: 3, count: 1, value: UInt32(compression)),
            Entry(tag: 262, type: 3, count: 1, value: 1),
            Entry(tag: 273, type: 4, count: 1, value: 0),
            Entry(tag: 277, type: 3, count: 1, value: 1),
            Entry(tag: 278, type: 4, count: 1, value: UInt32(height)),
            Entry(tag: 279, type: 4, count: 1, value: UInt32(pixels.count)),
            Entry(tag: 339, type: 3, count: 1, value: isInteger ? 2 : 3),
        ]
        if let scale {
            entries.append(Entry(tag: 33550, type: 12, count: UInt32(scale.count), value: 0, payload: doubles(scale)))
        }
        if let tiepoint {
            entries.append(Entry(tag: 33922, type: 12, count: UInt32(tiepoint.count), value: 0, payload: doubles(tiepoint)))
        }
        if let geoKeys {
            var shorts = Data()
            for v in geoKeys { withUnsafeBytes(of: v.littleEndian) { shorts.append(contentsOf: $0) } }
            entries.append(Entry(tag: 34735, type: 3, count: UInt32(geoKeys.count), value: 0, payload: shorts))
        }
        if let noData {
            let bytes = Array(noData.utf8) + [0]
            if bytes.count <= 4 {
                let packed = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
                entries.append(Entry(tag: 42113, type: 2, count: UInt32(bytes.count), value: packed))
            } else {
                entries.append(Entry(tag: 42113, type: 2, count: UInt32(bytes.count), value: 0, payload: Data(bytes)))
            }
        }
        entries.sort { $0.tag < $1.tag }

        var cursor = (8 + 2 + entries.count * 12 + 4 + 3) & ~3
        for i in entries.indices {
            guard let payload = entries[i].payload else { continue }
            entries[i].value = UInt32(cursor)
            cursor = (cursor + payload.count + 3) & ~3
        }
        let stripOffset = cursor
        if let i = entries.firstIndex(where: { $0.tag == 273 }) { entries[i].value = UInt32(stripOffset) }

        var out = Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
        withUnsafeBytes(of: UInt16(entries.count).littleEndian) { out.append(contentsOf: $0) }
        for e in entries {
            withUnsafeBytes(of: e.tag.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: e.type.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: e.count.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: e.value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: [0, 0, 0, 0])
        for e in entries {
            guard let payload = e.payload else { continue }
            while out.count < Int(e.value) { out.append(0) }
            out.append(payload)
        }
        while out.count < stripOffset { out.append(0) }
        out.append(pixels)
        return out
    }
}

/// A GeoKeyDirectory holding the model type, raster type and, if given, a geographic or projected EPSG code.
private func geoKeyDirectory(model: UInt16, raster: UInt16, geographic: UInt16? = nil, projected: UInt16? = nil) -> [UInt16] {
    var keys: [(UInt16, UInt16)] = [(1024, model), (1025, raster)]
    if let geographic { keys.append((2048, geographic)) }
    if let projected { keys.append((3072, projected)) }
    var out: [UInt16] = [1, 1, 0, UInt16(keys.count)]
    for (id, value) in keys { out += [id, 0, 1, value] }
    return out
}

private func temporaryFile(_ name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalGeoTIFF_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
}

private func write(_ tiff: TestTIFF, as name: String = "test.tif") -> URL {
    let url = temporaryFile(name)
    try? tiff.data().write(to: url)
    return url
}

/// A 64 x 64 surface with structure at every scale, so a half-pixel shift or a transposed axis shows.
private func structuredGrid(nanPatch: Bool) -> ElevationGrid {
    var grid = sceneGrid(width: 64, height: 64, gsd: 1.0) { x, y in
        let fx = Float(x), fy = Float(y)
        let mound = 4 * exp(-((fx - 40) * (fx - 40) + (fy - 22) * (fy - 22)) / 60)
        return 100 + 0.05 * fx + 0.02 * fy + 1.5 * sin(fx * 0.31) * cos(fy * 0.23) + mound
    }
    if nanPatch {
        var samples = grid.samples
        for y in 20..<25 { for x in 20..<25 { samples[y * 64 + x] = .nan } }
        grid = ElevationGrid(width: 64, height: 64, samples: samples, region: grid.region)
    }
    return grid
}

private func mercatorRegion(minX: Double, minY: Double, maxX: Double, maxY: Double) -> GeoRegion {
    let southWest = GeoRegion.fromMercatorMeters(x: minX, y: minY)
    let northEast = GeoRegion.fromMercatorMeters(x: maxX, y: maxY)
    return GeoRegion(minLatitude: southWest.latitude, maxLatitude: northEast.latitude,
                     minLongitude: southWest.longitude, maxLongitude: northEast.longitude)
}

/// Both NaN, or within `tolerance`.
private func same(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool {
    (a.isNaN && b.isNaN) || (!a.isNaN && !b.isNaN && abs(a - b) <= tolerance)
}

private func loadError(_ url: URL) -> LocalGeoTIFFProvider.ImportError? {
    do {
        _ = try LocalGeoTIFFProvider(contentsOf: url)
        return nil
    } catch let error as LocalGeoTIFFProvider.ImportError {
        return error
    } catch {
        return .unreadable("\(error)")
    }
}

// MARK: - G1. What the decoder reads

@MainActor
private func checkGeoKeyDecoding() {
    print("\n--- G1. GeoKeyDirectory ---")
    let url = temporaryFile("written.tif")
    try? GeoTIFFWriter.shared.export(grid: structuredGrid(nanPatch: false), to: url)
    let written = (try? Data(contentsOf: url)).flatMap { try? FloatTIFFDecoder.decode($0) }
    check("the app's own GeoTIFF reads back as Float32, Projected, PixelIsPoint, EPSG:3857",
          written?.bitsPerSample == 32 && written?.sampleFormat == 3
          && written?.geoKeys == FloatTIFFDecoder.GeoKeys(
            modelType: 1, rasterType: 2, geographicEPSG: nil, projectedEPSG: 3857),
          "\(String(describing: written?.geoKeys))")

    let utm = TestTIFF(width: 4, height: 4, floats: [Float](repeating: 1, count: 16),
                       scale: [1, 1, 0], tiepoint: [0, 0, 0, 500_000, 4_000_000, 0],
                       geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 32615))
    let geographic = TestTIFF(width: 4, height: 4, floats: [Float](repeating: 1, count: 16),
                              scale: [0.001, 0.001, 0], tiepoint: [0, 0, 0, -90, 38, 0],
                              geoKeys: geoKeyDirectory(model: 2, raster: 1, geographic: 4326))
    let bare = TestTIFF(width: 4, height: 4, floats: [Float](repeating: 1, count: 16))
    func keys(_ tiff: TestTIFF) -> FloatTIFFDecoder.GeoKeys? { (try? FloatTIFFDecoder.decode(tiff.data()))?.geoKeys }
    check("a UTM file's projected code and PixelIsArea are read",
          keys(utm) == FloatTIFFDecoder.GeoKeys(modelType: 1, rasterType: 1, geographicEPSG: nil, projectedEPSG: 32615),
          "\(String(describing: keys(utm)))")
    check("a geographic file's code is read, and a file with no directory has none",
          keys(geographic) == FloatTIFFDecoder.GeoKeys(modelType: 2, rasterType: 1, geographicEPSG: 4326, projectedEPSG: nil)
          && keys(bare) == nil && (try? FloatTIFFDecoder.decode(bare.data())) != nil,
          "\(String(describing: keys(geographic))) \(String(describing: keys(bare)))")
    let int16 = TestTIFF(width: 2, height: 2, int16s: [1, 2, 3, 4])
    let decoded = try? FloatTIFFDecoder.decode(int16.data())
    check("the sample layout is exposed, so an integer file can be told from a float one",
          decoded?.bitsPerSample == 16 && decoded?.sampleFormat == 2, "\(String(describing: decoded?.sampleFormat))")
}

// MARK: - G2. Round trip and resampling

@MainActor
private func checkLocalRoundTrip() async {
    print("\n--- G2. reproducing the source ---")
    let source = structuredGrid(nanPatch: true)
    let url = temporaryFile("roundtrip.tif")
    try? GeoTIFFWriter.shared.export(grid: source, to: url)
    guard let provider = try? LocalGeoTIFFProvider(contentsOf: url) else {
        check("the app's own GeoTIFF loads as a local source", false, "\(String(describing: loadError(url)))")
        return
    }
    check("the file's size, name and footprint are those of the grid it was written from",
          provider.width == 64 && provider.height == 64 && provider.name == "roundtrip.tif"
          && abs(provider.footprint.minLatitude - source.region.minLatitude) < 1e-7
          && abs(provider.footprint.maxLatitude - source.region.maxLatitude) < 1e-7
          && abs(provider.footprint.minLongitude - source.region.minLongitude) < 1e-7
          && abs(provider.footprint.maxLongitude - source.region.maxLongitude) < 1e-7,
          "\(provider.width)x\(provider.height) \(provider.footprint)")

    // Asking for the source's own extent at its own size lands every output node on a source node.
    let result = await provider.elevation(for: source.region, targetSamples: 64)
    guard let grid = result.value else {
        check("the source's own extent is served", false, "\(result)")
        return
    }
    var worst: Float = 0
    var voidsMatch = true
    var valid = 0, voids = 0
    for i in 0..<source.count {
        if !same(grid.samples[i], source.samples[i], 0.001) { voidsMatch = false }
        if source.samples[i].isNaN { voids += 1 } else { valid += 1; worst = max(worst, abs(grid.samples[i] - source.samples[i])) }
    }
    check("every sample comes back within 0.001 m, and the 25-cell NaN patch stays NaN without spreading",
          grid.width == 64 && grid.height == 64 && voidsMatch && voids == 25 && valid == 4096 - 25 && worst < 0.001,
          "\(grid.width)x\(grid.height), worst \(worst), voids match \(voidsMatch)")
    check("the grid is labelled with the region that was asked for, and the source is the local file",
          grid.region == source.region && result.provenance?.source == .localFile,
          "\(String(describing: result.provenance?.source))")

    // A window inside the file, at a different density: against a bilinear reference worked out here.
    let m = source.region.mercatorBounds
    let sub = mercatorRegion(minX: m.minX + 0.31 * (m.maxX - m.minX), minY: m.minY + 0.27 * (m.maxY - m.minY),
                             maxX: m.minX + 0.68 * (m.maxX - m.minX), maxY: m.minY + 0.74 * (m.maxY - m.minY))
    let sm = sub.mercatorBounds
    let n = 40
    if let windowed = await provider.elevation(for: sub, targetSamples: n).value {
        var worstWindow: Float = 0
        var compared = 0, voidCells = 0
        for j in 0..<windowed.height {
            for i in 0..<windowed.width {
                let x = sm.minX + Double(i) * (sm.maxX - sm.minX) / Double(windowed.width - 1)
                let y = sm.maxY - Double(j) * (sm.maxY - sm.minY) / Double(windowed.height - 1)
                let col = (x - m.minX) / (m.maxX - m.minX) * 63, row = (m.maxY - y) / (m.maxY - m.minY) * 63
                let c0 = min(Int(col.rounded(.down)), 62), r0 = min(Int(row.rounded(.down)), 62)
                let fx = Float(col - Double(c0)), fy = Float(row - Double(r0))
                let corners = [source.samples[r0 * 64 + c0], source.samples[r0 * 64 + c0 + 1],
                               source.samples[(r0 + 1) * 64 + c0], source.samples[(r0 + 1) * 64 + c0 + 1]]
                let expected: Float = corners.contains { $0.isNaN } ? .nan
                    : corners[0] * (1 - fx) * (1 - fy) + corners[1] * fx * (1 - fy)
                        + corners[2] * (1 - fx) * fy + corners[3] * fx * fy
                let got = windowed.samples[j * windowed.width + i]
                if expected.isNaN { voidCells += 1 }
                if same(got, expected, 0.002) { compared += 1 } else { worstWindow = max(worstWindow, abs(got - expected)) }
            }
        }
        check("a window at another density matches an independent bilinear reference on every node",
              max(windowed.width, windowed.height) == n && min(windowed.width, windowed.height) > n / 2
              && compared == windowed.count && voidCells > 0 && voidCells < windowed.count,
              "\(windowed.width)x\(windowed.height): \(compared)/\(windowed.count) agree, worst \(worstWindow), \(voidCells) voids")
    } else {
        check("a window at another density matches an independent bilinear reference on every node", false, "nil")
    }

    // Shading the resampled grid is shading the source.
    let clean = structuredGrid(nanPatch: false)
    let cleanURL = temporaryFile("clean.tif")
    try? GeoTIFFWriter.shared.export(grid: clean, to: cleanURL)
    let pipeline = MetalTerrainPipelineActor()
    if await pipeline.isAvailable(),
       let cleanProvider = try? LocalGeoTIFFProvider(contentsOf: cleanURL),
       let served = await cleanProvider.elevation(for: clean.region, targetSamples: 64).value {
        var options = MicroTopographyOptions()
        options.sunAzimuthDegrees = 200
        var allEqual = true
        var worstShade: Float = 0
        var products = 0
        for product in [MicroTopographyProduct.rakingLight, .localRelief, .skyView, .curvature] {
            guard let a = await pipeline.render(product, raster: ElevationRaster(grid: clean), options: options),
                  let b = await pipeline.render(product, raster: ElevationRaster(grid: served), options: options)
            else { allEqual = false; continue }
            let mismatch = planeMismatch(a.scalar.values(), b.scalar.values())
            worstShade = max(worstShade, mismatch.maxDiff)
            if mismatch.voidMismatch != 0 || mismatch.maxDiff > 1e-4 { allEqual = false }
            products += 1
        }
        check("four micro-topography products of the imported grid match those of the source (< 1e-4)",
              allEqual && products == 4, "worst \(worstShade), \(products) products")
    } else {
        check("four micro-topography products of the imported grid match those of the source (< 1e-4)", false, "no pipeline or provider")
    }

    // Sizes.
    let wide = mercatorRegion(minX: m.minX, minY: m.minY, maxX: m.minX + (m.maxX - m.minX) * 0.8, maxY: m.minY + (m.maxY - m.minY) * 0.4)
    let wideGrid = await provider.elevation(for: wide, targetSamples: 50).value
    check("targetSamples is the count along the longer axis, and the other follows the region's shape",
          wideGrid?.width == 50 && abs((wideGrid?.height ?? 0) - 25) <= 1, "\(wideGrid?.width ?? 0)x\(wideGrid?.height ?? 0)")
    var refused = 0
    for bad in [1, 0, -3, 100_000] where await provider.elevation(for: source.region, targetSamples: bad).value == nil { refused += 1 }
    check("an unusable sample count is refused, where 50 is served", refused == 4 && wideGrid != nil, "\(refused) of 4 refused")
}

// MARK: - G3. Projections and registration

@MainActor
private func checkLocalProjections() async {
    print("\n--- G3. projections and registration ---")
    let centre = CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621)

    // UTM zone 15N, PixelIsArea, the way most survey GeoTIFFs arrive. The field is analytic in eastings and
    // northings, so any half-pixel shift, flipped axis or wrong zone shows as an error.
    let (e, n) = UTMProjection.forward(latitude: centre.latitude, longitude: centre.longitude, zone: 15, hemisphere: .north)
    let e0 = (e - 60).rounded(), n0 = (n + 50).rounded()
    func field(_ easting: Double, _ northing: Double) -> Float {
        Float(100 + 0.01 * (easting - e0) + 3 * sin((northing - n0) / 40))
    }
    var utmSamples = [Float](repeating: 0, count: 120 * 100)
    for r in 0..<100 { for c in 0..<120 { utmSamples[r * 120 + c] = field(e0 + Double(c) + 0.5, n0 - Double(r) - 0.5) } }
    let utmURL = write(TestTIFF(width: 120, height: 100, floats: utmSamples, scale: [1, 1, 0],
                                tiepoint: [0, 0, 0, e0, n0, 0],
                                geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 32615)), as: "utm15.tif")
    let region = GeoRegion(center: centre, latitudeSpan: 0.0004, longitudeSpan: 0.0005)
    if let utm = try? LocalGeoTIFFProvider(contentsOf: utmURL), let grid = await utm.elevation(for: region, targetSamples: 32).value {
        let bounds = region.mercatorBounds
        var worst: Float = 0, checked = 0
        for j in 0..<grid.height {
            for i in 0..<grid.width {
                let x = bounds.minX + Double(i) * (bounds.maxX - bounds.minX) / Double(grid.width - 1)
                let y = bounds.maxY - Double(j) * (bounds.maxY - bounds.minY) / Double(grid.height - 1)
                let ll = GeoRegion.fromMercatorMeters(x: x, y: y)
                let (ee, nn) = UTMProjection.forward(latitude: ll.latitude, longitude: ll.longitude, zone: 15, hemisphere: .north)
                let got = grid.samples[j * grid.width + i]
                if got.isNaN { continue }
                worst = max(worst, abs(got - field(ee, nn)))
                checked += 1
            }
        }
        check("a UTM 15N PixelIsArea file is resampled onto the Mercator tile grid to 0.002 m of its analytic field",
              grid.width * grid.height == checked && checked >= 900 && worst < 0.002, "\(checked) nodes of \(grid.width)x\(grid.height), worst \(worst)")
    } else {
        check("a UTM 15N PixelIsArea file is resampled onto the Mercator tile grid to 0.002 m of its analytic field", false, "did not load")
    }

    // Geographic degrees, PixelIsPoint: 0.00001 degrees is about 1.1 m north-south.
    let lon0 = centre.longitude - 0.0006, lat0 = centre.latitude + 0.0005
    func degreeField(_ lon: Double, _ lat: Double) -> Float { Float(200 + 3000 * (lon - lon0) + 2000 * (lat0 - lat)) }
    var degreeSamples = [Float](repeating: 0, count: 120 * 100)
    for r in 0..<100 { for c in 0..<120 { degreeSamples[r * 120 + c] = degreeField(lon0 + Double(c) * 1e-5, lat0 - Double(r) * 1e-5) } }
    let degreeURL = write(TestTIFF(width: 120, height: 100, floats: degreeSamples, scale: [1e-5, 1e-5, 0],
                                   tiepoint: [0, 0, 0, lon0, lat0, 0],
                                   geoKeys: geoKeyDirectory(model: 2, raster: 2, geographic: 4326)), as: "geographic.tif")
    if let degrees = try? LocalGeoTIFFProvider(contentsOf: degreeURL) {
        let probe = CLLocationCoordinate2D(latitude: centre.latitude - 0.00013, longitude: centre.longitude + 0.00021)
        let got = degrees.elevation(at: probe)
        check("a geographic (EPSG:4326) PixelIsPoint file answers at a point to 0.001 m of its analytic field",
              got.map { abs($0 - degreeField(probe.longitude, probe.latitude)) < 0.001 } == true,
              "\(String(describing: got)) vs \(degreeField(probe.longitude, probe.latitude))")
    } else {
        check("a geographic (EPSG:4326) PixelIsPoint file answers at a point to 0.001 m of its analytic field", false, "did not load")
    }

    // The same tiepoint and scale read two ways: PixelIsArea puts the first sample half a pixel inside it.
    let origin = GeoRegion.toMercatorMeters(centre)
    let s = 2.0
    func registered(_ raster: UInt16) -> LocalGeoTIFFProvider? {
        var samples = [Float](repeating: 0, count: 40 * 40)
        let shift = raster == 1 ? 0.5 : 0.0
        for r in 0..<40 { for c in 0..<40 { samples[r * 40 + c] = Float((Double(c) + shift) * s) } }   // its own x offset
        return try? LocalGeoTIFFProvider(contentsOf: write(TestTIFF(
            width: 40, height: 40, floats: samples, scale: [s, s, 0], tiepoint: [0, 0, 0, origin.x, origin.y, 0],
            geoKeys: geoKeyDirectory(model: 1, raster: raster, projected: 3857)), as: "registered\(raster).tif"))
    }
    let probe = GeoRegion.fromMercatorMeters(x: origin.x + 10.3 * s, y: origin.y - 10.3 * s)
    let area = registered(1)?.elevation(at: probe), point = registered(2)?.elevation(at: probe)
    check("PixelIsArea and PixelIsPoint files with one tiepoint differ by half a pixel, and both read true",
          area.map { abs($0 - Float(10.3 * s)) < 0.001 } == true && point.map { abs($0 - Float(10.3 * s)) < 0.001 } == true,
          "area \(String(describing: area)), point \(String(describing: point)), expected \(10.3 * s)")
}

// MARK: - G4. Refusals

@MainActor
private func checkLocalRefusals() async {
    print("\n--- G4. what is refused, and why ---")
    let floats = [Float](repeating: 100, count: 16)
    let good = TestTIFF(width: 4, height: 4, floats: floats, scale: [1, 1, 0], tiepoint: [0, 0, 0, -10_000_000, 4_700_000, 0],
                        geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 3857))
    check("a plain Float32 Web Mercator file is accepted, so the refusals below mean something",
          loadError(write(good)) == nil, "\(String(describing: loadError(write(good))))")

    let integer = TestTIFF(width: 4, height: 4, int16s: [Int16](repeating: 100, count: 16), scale: [1, 1, 0],
                           tiepoint: [0, 0, 0, -10_000_000, 4_700_000, 0],
                           geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 3857))
    check("a 16-bit integer DEM is refused as not Float32",
          loadError(write(integer)) == .notFloat32(bitsPerSample: 16, sampleFormat: 2), "\(String(describing: loadError(write(integer))))")

    var bare = good
    bare.scale = nil
    bare.tiepoint = nil
    bare.geoKeys = nil
    check("a file with no georeferencing is refused, not placed somewhere arbitrary",
          loadError(write(bare)) == .notGeoreferenced, "\(String(describing: loadError(write(bare))))")

    var noProjection = good
    noProjection.geoKeys = nil
    var unsaid = false
    if case .unsupportedProjection(let why) = loadError(write(noProjection)) { unsaid = why.contains("no coordinate system") }
    check("a placed file that never says what its coordinates are in is refused, since guessing would misplace it",
          unsaid, "\(String(describing: loadError(write(noProjection))))")

    var britishGrid = good
    britishGrid.geoKeys = geoKeyDirectory(model: 1, raster: 1, projected: 27700)
    var refusedProjection = false
    if case .unsupportedProjection(let why) = loadError(write(britishGrid)) { refusedProjection = why.contains("27700") }
    check("a British National Grid file (EPSG:27700) is refused naming its code, since only Web Mercator, UTM and degrees are handled",
          refusedProjection, "\(String(describing: loadError(write(britishGrid))))")

    var compressed = good
    compressed.compression = 5
    var readable = true
    if case .unreadable(let why) = loadError(write(compressed)) { readable = !why.lowercased().contains("compression") }
    check("a compressed file is refused with the reason", !readable, "\(String(describing: loadError(write(compressed))))")

    let garbage = temporaryFile("garbage.tif")
    try? Data((0..<200).map { UInt8($0 % 251) }).write(to: garbage)
    var garbageRefused = false
    if case .unreadable = loadError(garbage) { garbageRefused = true }
    var missingRefused = false
    if case .unreadable = loadError(temporaryFile("missing.tif")) { missingRefused = true }
    check("bytes that are not a TIFF, and a file that is not there, are unreadable, where a good file is not",
          garbageRefused && missingRefused && loadError(write(good)) == nil)

    // Voids: a declared sentinel, and values no ground has.
    var raw = [Float](repeating: 250, count: 30 * 30)
    for r in 5..<9 { for c in 5..<9 { raw[r * 30 + c] = -9999 } }
    raw[20 * 30 + 20] = 1e30
    raw[21 * 30 + 21] = Float.infinity
    let sentinel = TestTIFF(width: 30, height: 30, floats: raw, scale: [1, 1, 0], tiepoint: [0, 0, 0, -10_000_000, 4_700_000, 0],
                            geoKeys: geoKeyDirectory(model: 1, raster: 2, projected: 3857), noData: "-9999")
    let origin = mercatorRegion(minX: -10_000_000, minY: 4_700_000 - 29, maxX: -10_000_000 + 29, maxY: 4_700_000)
    if let provider = try? LocalGeoTIFFProvider(contentsOf: write(sentinel)),
       let grid = await provider.elevation(for: origin, targetSamples: 30).value {
        let sentinelVoids = (5..<9).allSatisfy { r in (5..<9).allSatisfy { c in grid.samples[r * 30 + c].isNaN } }
        check("the declared no-data value, an absurd elevation and an infinity all become voids, and nothing else does",
              sentinelVoids && grid.samples[20 * 30 + 20].isNaN && grid.samples[21 * 30 + 21].isNaN
              && grid.samples.filter(\.isNaN).count == 18 && grid.samples[0] == 250,
              "\(grid.samples.filter(\.isNaN).count) voids")
    } else {
        check("the declared no-data value, an absurd elevation and an infinity all become voids, and nothing else does", false, "did not load")
    }
}

// MARK: - G5. Coverage

@MainActor
private func checkLocalCoverage() async {
    print("\n--- G5. coverage ---")
    let source = structuredGrid(nanPatch: false)
    let url = temporaryFile("coverage.tif")
    try? GeoTIFFWriter.shared.export(grid: source, to: url)
    guard let provider = try? LocalGeoTIFFProvider(contentsOf: url) else {
        check("the coverage fixture loads", false)
        return
    }
    let m = source.region.mercatorBounds
    let width = m.maxX - m.minX, height = m.maxY - m.minY

    let far = mercatorRegion(minX: m.minX + 10 * width, minY: m.minY, maxX: m.maxX + 11 * width, maxY: m.maxY)
    let farResult = await provider.elevation(for: far, targetSamples: 32)
    var noCoverage = false
    if case .unavailable(.noCoverage(.localFile)) = farResult { noCoverage = true }
    check("a region nowhere near the file has no local coverage, and intersects() agrees",
          noCoverage && !provider.intersects(far) && provider.intersects(source.region),
          "\(farResult)")

    let straddling = mercatorRegion(minX: m.minX + 0.5 * width, minY: m.minY - 0.2 * height,
                                    maxX: m.maxX + 0.5 * width, maxY: m.minY + 0.5 * height)
    if let grid = await provider.elevation(for: straddling, targetSamples: 40).value {
        let bounds = straddling.mercatorBounds
        var insideOK = true, outsideOK = true, inside = 0, outside = 0
        for j in 0..<grid.height {
            for i in 0..<grid.width {
                let x = bounds.minX + Double(i) * (bounds.maxX - bounds.minX) / Double(grid.width - 1)
                let y = bounds.maxY - Double(j) * (bounds.maxY - bounds.minY) / Double(grid.height - 1)
                let covered = x >= m.minX + 1e-6 && x <= m.maxX - 1e-6 && y >= m.minY + 1e-6 && y <= m.maxY - 1e-6
                let uncovered = x < m.minX - 1e-6 || x > m.maxX + 1e-6 || y < m.minY - 1e-6 || y > m.maxY + 1e-6
                let value = grid.samples[j * grid.width + i]
                if covered { inside += 1; if value.isNaN { insideOK = false } }
                if uncovered { outside += 1; if !value.isNaN { outsideOK = false } }
            }
        }
        check("a region half over the file is finite where the file is and void where it is not",
              insideOK && outsideOK && inside > 100 && outside > 100, "inside ok \(insideOK), outside ok \(outsideOK), \(inside)/\(outside)")
    } else {
        check("a region half over the file is finite where the file is and void where it is not", false, "nil")
    }

    let larger = mercatorRegion(minX: m.minX - width, minY: m.minY - height, maxX: m.maxX + width, maxY: m.maxY + height)
    if let grid = await provider.elevation(for: larger, targetSamples: 60).value {
        let centre = grid.samples[(grid.height / 2) * grid.width + grid.width / 2]
        check("a region wider than the file has void margins and a finite middle",
              grid.samples[0].isNaN && grid.samples[grid.count - 1].isNaN && !centre.isNaN, "centre \(centre)")
    } else {
        check("a region wider than the file has void margins and a finite middle", false, "nil")
    }
}

// MARK: - G6. The tile provider

@MainActor
private func checkLocalTileProvider() async {
    print("\n--- G6. mounting into the tile provider ---")
    func path(_ tile: HarvestTile) -> MKTileOverlayPath { MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1) }
    func region(_ tile: HarvestTile) -> GeoRegion { TerrainTileOverlay.region(for: path(tile)) }
    func union(_ tiles: [HarvestTile]) -> GeoRegion {
        let regions = tiles.map(region)
        return GeoRegion(
            minLatitude: regions.map(\.minLatitude).min()!, maxLatitude: regions.map(\.maxLatitude).max()!,
            minLongitude: regions.map(\.minLongitude).min()!, maxLongitude: regions.map(\.maxLongitude).max()!)
    }
    func dem(_ area: GeoRegion, base: Float, name: String) -> LocalGeoTIFFProvider? {
        var samples = [Float](repeating: 0, count: 96 * 96)
        for y in 0..<96 { for x in 0..<96 { samples[y * 96 + x] = base + 0.01 * Float(x) } }
        let url = temporaryFile(name)
        try? GeoTIFFWriter.shared.export(grid: ElevationGrid(width: 96, height: 96, samples: samples, region: area), to: url)
        return try? LocalGeoTIFFProvider(contentsOf: url)
    }

    let tile = HarvestTile(x: 65490, y: 100500, z: 18)
    let elsewhere = HarvestTile(x: 65520, y: 100500, z: 18)
    let around = (-1...1).flatMap { dy in (-1...1).map { HarvestTile(x: tile.x + $0, y: tile.y + dy, z: 18) } }
    guard let local = dem(union(around), base: 500, name: "site.tif") else {
        check("the tile-provider fixture DEM loads", false)
        return
    }
    let pixels = 256
    let remote = CountingElevationStub()
    let directory = makeCacheDir()
    let cache = TileDiskCache(directory: directory)
    let provider = TerrainTileProvider(elevation: remote, gridCache: cache)
    _ = await provider.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
    _ = await provider.tileImage(x: elsewhere.x, y: elsewhere.y, z: 18, region: region(elsewhere), pixels: pixels)
    let centre = region(tile).center, elsewhereCentre = region(elsewhere).center
    let before = await provider.elevation(at: centre)
    let elsewhereBefore = await provider.elevation(at: elsewhereCentre)
    let callsBefore = remote.callCount

    let dropped = await provider.mountLocalElevation(local)
    let after = await provider.elevation(at: centre)
    let elsewhereAfter = await provider.elevation(at: elsewhereCentre)
    check("mounting drops the cached tiles under the DEM and leaves the others alone",
          dropped == 1 && after == nil && elsewhereBefore != nil && elsewhereAfter == elsewhereBefore,
          "\(dropped) dropped; after \(String(describing: after))")

    _ = await provider.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
    let served = await provider.elevation(at: centre)
    let expected = local.elevation(at: centre)
    check("the tile then shades from the local DEM, without asking the remote source",
          before.map { $0 > 300 && $0 < 400 } == true && served != nil && expected != nil
          && abs(served! - expected!) < 0.5 && abs(served! - before!) > 50 && remote.callCount == callsBefore,
          "before \(String(describing: before)), served \(String(describing: served)), local \(String(describing: expected)), calls \(callsBefore) -> \(remote.callCount)")

    // Not on disk: a cached remote raster would otherwise be served over the DEM, and a local one must not outlive it.
    let key = TerrainTileProvider.gridCacheKey(x: tile.x, y: tile.y, z: 18, pixels: pixels, margin: TerrainTileProvider.marginPixels)
    for _ in 0..<50 where !(await cache.contains(forKey: key)) { try? await Task.sleep(for: .milliseconds(20)) }
    let seeded = await cache.contains(forKey: key)
    let restarted = TerrainTileProvider(elevation: CountingElevationStub(), gridCache: TileDiskCache(directory: directory))
    _ = await restarted.mountLocalElevation(local)
    _ = await restarted.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
    let overDisk = await restarted.elevation(at: centre)
    try? await Task.sleep(for: .milliseconds(250))     // long enough for a write that should not happen to have happened
    let diskGrid = await cache.read(forKey: key).flatMap { ElevationGridCoder.decode($0) }
    check("a fresh provider with the remote raster already on disk still serves the DEM, and leaves that raster as it was",
          seeded && overDisk != nil && expected != nil && abs(overDisk! - expected!) < 0.5
          && diskGrid.map { !$0.source.contains("Local") && $0.grid.samples.allSatisfy { $0 < 480 } } == true,
          "seeded \(seeded), served \(String(describing: overDisk)), disk source \(String(describing: diskGrid?.source))")

    // Half covered: the DEM's part from the DEM, the rest from the remote source.
    let half = HarvestTile(x: 65500, y: 100510, z: 18)
    let halfRegion = region(half)
    let west = GeoRegion(minLatitude: halfRegion.minLatitude - 0.0005, maxLatitude: halfRegion.maxLatitude + 0.0005,
                         minLongitude: halfRegion.minLongitude - 0.001, maxLongitude: halfRegion.centerLongitude)
    let partialRemote = CountingElevationStub()
    let partial = TerrainTileProvider(elevation: partialRemote, gridCache: TileDiskCache(directory: makeCacheDir()))
    if let westDEM = dem(west, base: 800, name: "west.tif") {
        _ = await partial.mountLocalElevation(westDEM)
        _ = await partial.tileImage(x: half.x, y: half.y, z: 18, region: halfRegion, pixels: pixels)
        let inside = CLLocationCoordinate2D(latitude: halfRegion.centerLatitude,
                                            longitude: halfRegion.minLongitude + 0.25 * (halfRegion.maxLongitude - halfRegion.minLongitude))
        let outside = CLLocationCoordinate2D(latitude: halfRegion.centerLatitude,
                                             longitude: halfRegion.minLongitude + 0.75 * (halfRegion.maxLongitude - halfRegion.minLongitude))
        let insideValue = await partial.elevation(at: inside), outsideValue = await partial.elevation(at: outside)
        check("a tile half under the DEM takes the DEM's height there and the remote source's beyond it",
              insideValue.map { $0 > 790 && $0 < 830 } == true && outsideValue.map { $0 > 250 && $0 < 450 } == true
              && partialRemote.callCount == 1,
              "inside \(String(describing: insideValue)), outside \(String(describing: outsideValue)), \(partialRemote.callCount) remote calls")
    } else {
        check("a tile half under the DEM takes the DEM's height there and the remote source's beyond it", false, "no DEM")
    }

    // A harvest is for having the real data offline: a mounted DEM neither stands in for it nor lands on disk.
    let harvestRemote = CountingElevationStub()
    let harvestCache = TileDiskCache(directory: makeCacheDir())
    let harvesting = TerrainTileProvider(elevation: harvestRemote, gridCache: harvestCache)
    _ = await harvesting.mountLocalElevation(local)
    let harvestOutcome = await harvesting.elevationHarvestSource.harvest(tile, pixels: pixels)
    let harvestKey = TerrainTileProvider.gridCacheKey(x: tile.x, y: tile.y, z: 18, pixels: pixels, margin: TerrainTileProvider.marginPixels)
    let harvested = await harvestCache.read(forKey: harvestKey).flatMap { ElevationGridCoder.decode($0) }
    var stored = false
    if case .stored = harvestOutcome { stored = true }
    check("harvesting under a mounted DEM fetches and keeps the remote raster, not the DEM's",
          stored && harvestRemote.callCount == 1
          && harvested.map { !$0.source.contains("Local") && $0.grid.samples.allSatisfy { $0 < 480 } } == true,
          "\(harvestOutcome), \(harvestRemote.callCount) remote calls, disk source \(String(describing: harvested?.source))")

    // Unmount: back to the remote source.
    let unmounted = await provider.unmountLocalElevation()
    _ = await provider.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
    let reverted = await provider.elevation(at: centre)
    check("unmounting drops the DEM's tiles and the tile shades from the remote source again",
          unmounted == 1 && reverted.map { $0 > 300 && $0 < 400 } == true,
          "\(unmounted) dropped, reverted \(String(describing: reverted))")

    // One of two files removed: the other stays.
    let aroundElsewhere = (-1...1).flatMap { dy in (-1...1).map { HarvestTile(x: elsewhere.x + $0, y: elsewhere.y + dy, z: 18) } }
    if let east = dem(union(aroundElsewhere), base: 900, name: "east.tif") {
        let two = TerrainTileProvider(elevation: CountingElevationStub(), gridCache: TileDiskCache(directory: makeCacheDir()))
        _ = await two.mountLocalElevation(local)
        _ = await two.mountLocalElevation(east)
        _ = await two.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
        _ = await two.tileImage(x: elsewhere.x, y: elsewhere.y, z: 18, region: region(elsewhere), pixels: pixels)
        let both = await two.localElevationNames
        let westValue = await two.elevation(at: region(tile).center)
        let eastValue = await two.elevation(at: region(elsewhere).center)
        let droppedOne = await two.unmountLocalElevation(local)
        let remaining = await two.localElevationNames
        _ = await two.tileImage(x: tile.x, y: tile.y, z: 18, region: region(tile), pixels: pixels)
        let westReverted = await two.elevation(at: region(tile).center)
        let eastKept = await two.elevation(at: region(elsewhere).center)
        let droppedAgain = await two.unmountLocalElevation(local)
        let afterAgain = await two.localElevationNames
        check("removing one of two mounted files drops only its tiles: its ground shades from the remote source again and the other file's stays",
              both == ["east.tif", "site.tif"] && westValue.map({ $0 > 490 && $0 < 520 }) == true && eastValue.map({ $0 > 890 && $0 < 920 }) == true
              && droppedOne == 1 && remaining == ["east.tif"] && westReverted.map({ $0 > 300 && $0 < 400 }) == true
              && eastKept == eastValue,
              "names \(both) -> \(remaining); west \(String(describing: westValue)) -> \(String(describing: westReverted)); east \(String(describing: eastValue)) -> \(String(describing: eastKept)); \(droppedOne) dropped")
        check("removing a file that is not mounted does nothing",
              droppedAgain == 0 && afterAgain == ["east.tif"], "\(droppedAgain) dropped, \(afterAgain)")
    } else {
        check("removing one of two mounted files drops only its tiles", false, "no second DEM")
    }
}

// MARK: - G7. The viewer model

private func demFile(_ area: GeoRegion, base: Float, name: String) -> URL {
    var samples = [Float](repeating: 0, count: 64 * 64)
    for y in 0..<64 { for x in 0..<64 { samples[y * 64 + x] = base + 0.01 * Float(x) } }
    let url = temporaryFile(name)
    try? GeoTIFFWriter.shared.export(grid: ElevationGrid(width: 64, height: 64, samples: samples, region: area), to: url)
    return url
}

@MainActor
private func checkLocalElevationImport() async {
    print("\n--- G7. importing into the viewer model ---")
    let site = GeoRegion(center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621), latitudeSpan: 0.004, longitudeSpan: 0.005)
    let model = TerrainViewerModel()
    let before = model.terrainDataVersion
    let shadingBefore = model.terrainVersion
    await model.importLocalElevation(from: demFile(site, base: 120, name: "site.tif"))
    let names = await model.terrainProvider.localElevationNames
    let file = model.localElevationFiles.first
    check("importing a GeoTIFF mounts it, lists it, and has the map redraw its tiles once",
          model.localElevationFiles.count == 1 && file?.name == "site.tif" && file?.width == 64 && file?.height == 64
          && names == ["site.tif"] && model.terrainDataVersion == before + 1 && model.localElevationMessage == nil
          && !model.isImportingLocalElevation,
          "\(model.localElevationFiles.count) files, \(names), version \(before) -> \(model.terrainDataVersion), message \(String(describing: model.localElevationMessage))")

    let flown = model.pendingRegion
    let fits = flown.map { region in
        abs(region.center.latitude - site.centerLatitude) < 1e-4 && abs(region.center.longitude - site.centerLongitude) < 1e-4
            && region.span.latitudeDelta >= site.latitudeSpan && region.span.latitudeDelta < site.latitudeSpan * 1.5
            && region.span.longitudeDelta >= site.longitudeSpan && region.span.longitudeDelta < site.longitudeSpan * 1.5
    } ?? false
    check("the map is sent to the file: centred on it, all of it in view and not much more",
          fits && model.visibleRegion.center.latitude == flown?.center.latitude && model.visibleRegion.center.longitude == flown?.center.longitude,
          "\(String(describing: flown))")
    let footprint = file?.footprint
    check("the listed footprint is the file's ground",
          footprint.map { abs($0.centerLatitude - site.centerLatitude) < 1e-4 && abs($0.latitudeSpan - site.latitudeSpan) < 2e-4
                          && abs($0.longitudeSpan - site.longitudeSpan) < 2e-4 } == true,
          "\(String(describing: footprint))")

    // The same file name again replaces it; another name is added, newest first.
    let firstID = file?.id
    await model.importLocalElevation(from: demFile(site, base: 300, name: "site.tif"))
    let replaced = await model.terrainProvider.localElevationNames
    let afterReplace = model.localElevationFiles
    await model.importLocalElevation(from: demFile(site, base: 200, name: "second.tif"))
    let both = await model.terrainProvider.localElevationNames
    check("a file with the same name replaces the one imported before it, and a different name is added, newest first",
          afterReplace.count == 1 && afterReplace.first?.id != firstID && replaced == ["site.tif"]
          && model.localElevationFiles.map(\.name) == ["second.tif", "site.tif"] && both == ["second.tif", "site.tif"],
          "\(replaced), \(both), \(model.localElevationFiles.map(\.name))")

    // A limit on how many are held.
    for name in ["third.tif", "fourth.tif"] { await model.importLocalElevation(from: demFile(site, base: 100, name: name)) }
    let atLimit = model.localElevationFiles.count
    let versionAtLimit = model.terrainDataVersion
    await model.importLocalElevation(from: demFile(site, base: 100, name: "fifth.tif"))
    let refusedAtLimit = model.localElevationFiles.count == TerrainViewerModel.maxLocalElevationFiles
        && model.localElevationMessage?.contains("fifth.tif") == true && model.localElevationMessage?.contains("4") == true
        && model.terrainDataVersion == versionAtLimit
    await model.importLocalElevation(from: demFile(site, base: 500, name: "third.tif"))
    check("no more than 4 are held: a fifth is refused with the reason, nothing changes, but a file can still replace one of the same name",
          atLimit == 4 && refusedAtLimit && model.localElevationFiles.count == 4 && model.terrainDataVersion == versionAtLimit + 1
          && model.localElevationMessage == nil,
          "\(atLimit) held, refused \(refusedAtLimit), message \(String(describing: model.localElevationMessage))")

    // Removing.
    let removeID = model.localElevationFiles.last?.id
    let versionBeforeRemove = model.terrainDataVersion
    await model.removeLocalElevation(id: removeID ?? UUID())
    let afterRemove = await model.terrainProvider.localElevationNames
    let versionAfterRemove = model.terrainDataVersion
    await model.removeLocalElevation(id: UUID())
    check("removing a file unmounts just it and has the map redraw; an unknown file changes nothing",
          model.localElevationFiles.count == 3 && !model.localElevationFiles.contains { $0.id == removeID }
          && afterRemove.count == 3 && !afterRemove.contains("site.tif") && versionAfterRemove == versionBeforeRemove + 1
          && model.terrainDataVersion == versionAfterRemove,
          "\(afterRemove), version \(versionBeforeRemove) -> \(versionAfterRemove) -> \(model.terrainDataVersion)")
    await model.removeAllLocalElevation()
    let afterAll = await model.terrainProvider.localElevationNames
    let versionEmpty = model.terrainDataVersion
    await model.removeAllLocalElevation()
    check("removing all leaves none mounted and none listed, and removing from none does not redraw",
          model.localElevationFiles.isEmpty && afterAll.isEmpty && model.terrainDataVersion == versionEmpty && versionEmpty == versionAfterRemove + 1)
    // A data change must discard the map's tiles, not keep them drawn while they re-shade: the kept images were
    // shaded from data that is gone (a removed file's relief stayed on screen offline).
    check("mounting and removing files move the data token only, never the shading token that keeps tiles drawn",
          model.terrainVersion == shadingBefore, "shading token \(shadingBefore) -> \(model.terrainVersion)")

    // Refusals leave everything as it was and say why, naming the file.
    let refuseModel = TerrainViewerModel()
    let floats = [Float](repeating: 100, count: 16)
    let good = TestTIFF(width: 4, height: 4, floats: floats, scale: [1, 1, 0], tiepoint: [0, 0, 0, -10_000_000, 4_700_000, 0],
                        geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 3857))
    var integer = TestTIFF(width: 4, height: 4, int16s: [Int16](repeating: 100, count: 16), scale: [1, 1, 0],
                           tiepoint: [0, 0, 0, -10_000_000, 4_700_000, 0], geoKeys: geoKeyDirectory(model: 1, raster: 1, projected: 3857))
    integer.floats = []
    var bare = good
    bare.scale = nil
    bare.tiepoint = nil
    bare.geoKeys = nil
    var britishGrid = good
    britishGrid.geoKeys = geoKeyDirectory(model: 1, raster: 1, projected: 27700)
    let garbage = temporaryFile("garbage.tif")
    try? Data((0..<200).map { UInt8($0 % 251) }).write(to: garbage)
    let cases: [(String, URL, [String])] = [
        ("garbage.tif", garbage, ["could not be read"]),
        ("gone.tif", temporaryFile("gone.tif"), ["could not be read"]),
        ("integer.tif", write(integer, as: "integer.tif"), ["32-bit floating-point", "16-bit"]),
        ("bare.tif", write(bare, as: "bare.tif"), ["georeferenc"]),
        ("bng.tif", write(britishGrid, as: "bng.tif"), ["27700", "coordinate system"]),
    ]
    var problems: [String] = []
    for (name, url, phrases) in cases {
        let version = refuseModel.terrainDataVersion
        await refuseModel.importLocalElevation(from: url)
        let message = refuseModel.localElevationMessage ?? ""
        if !(message.contains(name) && phrases.allSatisfy { message.contains($0) } && refuseModel.localElevationFiles.isEmpty
             && refuseModel.terrainDataVersion == version && !refuseModel.isImportingLocalElevation) {
            problems.append("\(name): '\(message)'")
        }
    }
    await refuseModel.importLocalElevation(from: write(good, as: "good.tif"))
    check("a file that is refused (garbage, missing, integers, no georeference, an unsupported projection) mounts nothing, redraws nothing and says why, naming it",
          problems.isEmpty && refuseModel.localElevationFiles.count == 1 && refuseModel.localElevationMessage == nil,
          problems.joined(separator: "; "))

    // A raster whose longitudes run 190 to 190.003 (the 0...360 convention) must not send the map somewhere MapKit
    // cannot go: an out-of-range region raises an exception there.
    let eastern = TestTIFF(width: 4, height: 4, floats: [Float](repeating: 100, count: 16), scale: [0.001, 0.001, 0],
                           tiepoint: [0, 0, 0, 190.0, 38.0, 0], geoKeys: geoKeyDirectory(model: 2, raster: 1, geographic: 4326))
    let wrapModel = TerrainViewerModel()
    await wrapModel.importLocalElevation(from: write(eastern, as: "eastern.tif"))
    let wrapped = wrapModel.pendingRegion
    check("a raster on the 0 to 360 longitude convention sends the map to the same place inside -180...180, where MapKit can go",
          wrapModel.localElevationFiles.count == 1
          && wrapped.map { abs($0.center.longitude) <= 180 && abs($0.center.latitude) <= 90 && abs($0.center.longitude + 169.9985) < 0.01 } == true,
          "\(String(describing: wrapped)), \(String(describing: wrapModel.localElevationMessage))")

    // Two imports begun together import one: the second is not started while the first is reading.
    let together = TerrainViewerModel()
    let first = demFile(site, base: 100, name: "one.tif"), second = demFile(site, base: 200, name: "two.tif")
    let a = Task { await together.importLocalElevation(from: first) }
    let b = Task { await together.importLocalElevation(from: second) }
    await a.value
    await b.value
    check("two imports begun together import one, and afterwards a third can",
          together.localElevationFiles.count == 1 && !together.isImportingLocalElevation)
    await together.importLocalElevation(from: second)
    check("once one has finished another is taken", together.localElevationFiles.count == 2)

    // The words used for each kind of refusal.
    let unreadable = LocalGeoTIFFProvider.ImportError.unreadable("compression 5 is not supported").explanation(forFile: "a.tif")
    let notFloat = LocalGeoTIFFProvider.ImportError.notFloat32(bitsPerSample: 16, sampleFormat: 2).explanation(forFile: "b.tif")
    let unsigned = LocalGeoTIFFProvider.ImportError.notFloat32(bitsPerSample: 8, sampleFormat: 1).explanation(forFile: "b.tif")
    let unplaced = LocalGeoTIFFProvider.ImportError.notGeoreferenced.explanation(forFile: "c.tif")
    let projection = LocalGeoTIFFProvider.ImportError.unsupportedProjection("EPSG:2154 is not handled").explanation(forFile: "d.tif")
    check("each refusal is explained in words that name the file and say what is wrong",
          unreadable.contains("a.tif") && unreadable.contains("could not be read") && unreadable.contains("compression 5")
          && notFloat.contains("b.tif") && notFloat.contains("16-bit") && notFloat.contains(" signed integer") && !notFloat.contains("unsigned")
          && notFloat.contains("32-bit floating-point")
          && unsigned.contains("8-bit") && unsigned.contains(" unsigned integer")
          && unplaced.contains("c.tif") && unplaced.contains("georeferenc")
          && projection.contains("d.tif") && projection.contains("EPSG:2154") && projection.contains("coordinate system"),
          "\(unreadable) | \(notFloat) | \(unplaced) | \(projection)")
}
