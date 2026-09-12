import CoreLocation
import Foundation
import MapKit

var failures = 0
func check(_ n: String, _ ok: Bool, _ d: String = "") {
    print(ok ? "  PASS  \(n)" : "  FAIL  \(n) \(d)")
    if !ok { failures += 1 }
}

/// Slippy-map tile containing a coordinate at a zoom level.
func tilePath(lat: Double, lon: Double, z: Int) -> MKTileOverlayPath {
    let n = pow(2.0, Double(z))
    let x = Int((lon + 180.0) / 360.0 * n)
    let y = Int((1.0 - asinh(tan(lat * .pi / 180)) / .pi) / 2.0 * n)
    return MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2)
}

let cahokia = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)

@MainActor
func run() async {
    print("\n=== Tile geometry ===")
    // A tile must contain the coordinate used to derive it, at every zoom.
    for z in [10, 12, 14, 16] {
        let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: z)
        let region = TerrainTileOverlay.region(for: path)
        check("z\(z) tile contains its own coordinate", region.contains(cahokia),
              "lat \(region.minLatitude)..\(region.maxLatitude)")
    }
    // Tiles must halve in span with each zoom step.
    let wide = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 12))
    let tight = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 13))
    check("one zoom step halves the tile span",
          abs(wide.longitudeSpan / tight.longitudeSpan - 2) < 1e-9,
          "\(wide.longitudeSpan / tight.longitudeSpan)")
    // Adjacent tiles must abut exactly, or the terrain shows seams.
    let a = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 100, y: 200, z: 14, contentScaleFactor: 2))
    let b = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 101, y: 200, z: 14, contentScaleFactor: 2))
    let c = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 100, y: 201, z: 14, contentScaleFactor: 2))
    check("horizontally adjacent tiles abut", abs(a.maxLongitude - b.minLongitude) < 1e-12)
    check("vertically adjacent tiles abut", abs(a.minLatitude - c.maxLatitude) < 1e-12)

    print("\n=== Basemap overzoom deduplication ===")
    let basemap = HillshadeTileOverlay(basemap: .shadedRelief)
    let parentX = 2046
    let parentY = 3140
    let child1 = MKTileOverlayPath(x: parentX * 2, y: parentY * 2, z: 14, contentScaleFactor: 2)
    let child2 = MKTileOverlayPath(x: parentX * 2 + 1, y: parentY * 2, z: 14, contentScaleFactor: 2)
    let d1 = try? await basemap.loadTile(at: child1)
    let d2 = try? await basemap.loadTile(at: child2)
    check("child tile 1 loads", d1 != nil)
    check("child tile 2 loads", d2 != nil)
    if let d1, let d2 {
        check("adjacent overzoomed child tiles are distinct (not duplicate parent)", d1 != d2)
    }

    print("\n=== Tiered tile streaming (live) ===")
    let provider = TerrainTileProvider()

    // Browsing zooms must be fast, and detail must improve with zoom.
    var timings: [Int: Double] = [:]
    var resolutions: [Int: Double] = [:]
    for z in [11, 13, 15, 16, 18] {
        let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: z)
        let region = TerrainTileOverlay.region(for: path)
        let started = Date()
        let image = await provider.tileImage(
            x: path.x, y: path.y, z: path.z, region: region, pixels: 512
        )
        let elapsed = Date().timeIntervalSince(started)
        timings[z] = elapsed
        let source = TerrainTileProvider.sourceName(forZ: z)
        let px = z <= TerrariumTileService.maximumZ ? 256.0 : 512.0
        resolutions[z] = region.widthMeters / px
        let sourceLabel = source.padding(toLength: 22, withPad: " ", startingAt: 0)
        let sizeLabel = image == nil
            ? "NO DATA"
            : "\(image!.bytesPerRow * image!.height / 1024) KB"
        print("        " + "z\(z)".padding(toLength: 6, withPad: " ", startingAt: 0)
              + sourceLabel
              + String(format: "%7.0f m wide -> %5.2f m/px  %6.2fs  ",
                       region.widthMeters, region.widthMeters / px, elapsed)
              + sizeLabel)
        check("z\(z) tile renders", image != nil)
    }

    // The point of the tiered source: browsing must not stall.
    for z in [11, 13, 15, 16] {
        check("z\(z) tile is fast enough to browse (< 3s)", (timings[z] ?? 99) < 3.0,
              String(format: "%.2fs", timings[z] ?? -1))
    }
    if let r11 = resolutions[11], let r13 = resolutions[13],
       let r15 = resolutions[15], let r16 = resolutions[16],
       let r18 = resolutions[18] {
        check("detail improves monotonically with zoom",
              r11 > r13 && r13 > r15 && r15 > r16 && r16 > r18,
              "\(r11) / \(r13) / \(r15) / \(r16) / \(r18)")
        check("deepest tier reaches native resolution (< 1.5 m)", r18 < 1.5, "\(r18) m/px")
    }
    if let finest = await provider.finestResolution() {
        print(String(format: "        finest cached raster GSD: %.2f m/px", finest))
        check("finest raster GSD reaches 1 m", finest < 1.5, String(format: "%.2f m/px", finest))
    }

    print("\n=== Relighting uses the cache ===")
    // Re-shading must not refetch: that is what keeps the light controls live.
    let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 15)
    let region = TerrainTileOverlay.region(for: path)
    _ = await provider.tileImage(
        x: path.x, y: path.y, z: path.z, region: region, pixels: 512)   // warm

    var settings = TerrainStyleSettings()
    settings.style = .hillshade
    settings.azimuthDegrees = 135
    _ = await provider.update(settings)

    let started = Date()
    let relit = await provider.tileImage(
        x: path.x, y: path.y, z: path.z, region: region, pixels: 512)
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "        relight took %.3fs", elapsed))
    check("relight produces an image", relit != nil)
    check("relight is far faster than a fetch", elapsed < 1.0,
          String(format: "%.3fs", elapsed))

    print("\n=== Elevation readout from tiles ===")
    let elevation = await provider.elevation(at: cahokia)
    check("elevation available from cached tiles", elevation != nil)
    if let e = elevation {
        print(String(format: "        %.1f m at Monks Mound", e))
        check("elevation plausible for Cahokia", e > 110 && e < 200, "\(e)")
    }
    let spot = await provider.inspectSpot(at: cahokia)
    check("spot inspection available from cached tiles", spot != nil)
    if let spot {
        print(String(format: "        Spot: elev %.1f m, slope %.1f° (%@), aspect %.0f° (%@)",
                     spot.elevationMeters, spot.slopeDegrees, spot.slopePercentFormatted, spot.aspectDegrees, spot.compassDirection))
        check("spot elevation matches elevation readout", abs(spot.elevationMeters - (elevation ?? 0)) < 0.1)
        check("spot slope valid", !spot.slopeDegrees.isNaN && spot.slopeDegrees >= 0)
    }
    let far = await provider.elevation(
        at: CLLocationCoordinate2D(latitude: 45.0, longitude: -100.0))
    check("coordinate outside cached tiles reads nil", far == nil)
    let farSpot = await provider.inspectSpot(
        at: CLLocationCoordinate2D(latitude: 45.0, longitude: -100.0))
    check("spot outside cached tiles reads nil", farSpot == nil)

    print("\n=== Transect profile (bilinear sampling) ===")
    let profileEnd = CLLocationCoordinate2D(
        latitude: cahokia.latitude + 0.002, longitude: cahokia.longitude + 0.002)
    if let profile = await provider.profile(from: cahokia, to: profileEnd, sampleCount: 40) {
        check("profile produces the requested sample count", profile.points.count == 40,
              "\(profile.points.count)")
        check("profile distances are non-decreasing",
              zip(profile.points, profile.points.dropFirst()).allSatisfy { $0.distanceMeters <= $1.distanceMeters })
        check("profile total distance matches the last point",
              abs(profile.totalDistanceMeters - (profile.points.last?.distanceMeters ?? -1)) < 0.01)
        // Bilinear sampling should not be identical to a nearest-neighbour
        // readout at every single point along a real (non-axis-aligned)
        // transect -- if it always were, the swap would not have done
        // anything. Not every point need differ (some legitimately land near
        // a cell centre), but at least a few should.
        var distinctFromNearest = 0
        for p in profile.points {
            if let nearest = await provider.elevation(at: p.coordinate),
               abs(nearest - p.elevationMeters) > 0.001 {
                distinctFromNearest += 1
            }
        }
        print("        \(distinctFromNearest)/\(profile.points.count) points differ from nearest-neighbour")
        check("bilinear sampling measurably differs from nearest-neighbour somewhere along the transect",
              distinctFromNearest > 0)
    } else {
        check("profile available from cached tiles", false)
    }

    print("\n=== Openness / RRIM styles through the real tile provider ===")
    // Distinct from the RasterCompute-level checks in the offline harness:
    // this exercises the actual picker wiring in TerrainTileOverlow.shadeToImage
    // (the style switch, and the crop-to-display-margin logic in rrimImage(for:)
    // and opennessImage(for:settings:)), against a real cached tile.
    if await RasterCompute.shared.isRRIMAvailable() {
        // The reference size comes from the same cached raster shaded the
        // normal way, not a hardcoded literal: a tile's actual pixel size
        // depends on its source's native resolution (terrarium tiles are
        // natively 256x256, not whatever `pixels:` was asked for), so the
        // real invariant is that RRIM/openness crop to the same size the
        // standard renderTile path would for this identical raster -- not
        // any particular absolute number.
        if let referenceTile = await provider.tileImage(x: path.x, y: path.y, z: path.z, region: region, pixels: 512) {
            var rrimSettings = TerrainStyleSettings()
            rrimSettings.style = .rrim
            _ = await provider.update(rrimSettings)
            let rrimTile = await provider.tileImage(x: path.x, y: path.y, z: path.z, region: region, pixels: 512)
            check("RRIM style renders through the real tile provider", rrimTile != nil)
            if let rrimTile {
                check("RRIM tile is cropped to the same display size as the standard path",
                      rrimTile.width == referenceTile.width && rrimTile.height == referenceTile.height,
                      "\(rrimTile.width)x\(rrimTile.height) vs \(referenceTile.width)x\(referenceTile.height)")
            }

            var opennessSettings = TerrainStyleSettings()
            opennessSettings.style = .topographicOpenness
            _ = await provider.update(opennessSettings)
            let opennessTile = await provider.tileImage(x: path.x, y: path.y, z: path.z, region: region, pixels: 512)
            check("openness style renders through the real tile provider", opennessTile != nil)
            if let opennessTile {
                check("openness tile is cropped to the same display size as the standard path",
                      opennessTile.width == referenceTile.width && opennessTile.height == referenceTile.height,
                      "\(opennessTile.width)x\(opennessTile.height) vs \(referenceTile.width)x\(referenceTile.height)")
            }
        } else {
            check("reference tile available to size RRIM/openness against", false)
        }

        // Restore the style used by the sections below.
        _ = await provider.update(settings)
        _ = await provider.tileImage(x: path.x, y: path.y, z: path.z, region: region, pixels: 512)
    } else {
        print("        (skipped: no fused + RRIM pipeline)")
    }

    print("\n=== Elevation range fits the visible area (not continental) ===")
    let elevRegion = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 15))
    if let r = await provider.elevationRange(in: elevRegion) {
        let span = r.upperBound - r.lowerBound
        print(String(format: "        fitted range %.1f..%.1f m (span %.1f)", r.lowerBound, r.upperBound, span))
        check("elevation range is local, not continental", span < 500, "span \(span)")
        check("elevation range plausible for Cahokia", r.lowerBound > 100 && r.upperBound < 250, "\(r.lowerBound)..\(r.upperBound)")
    } else {
        check("elevation range available from cached tiles", false)
    }

    print("\n=== Adjacent tile seam continuity (z18) ===")
    let pathA = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 18)
    let pathB = MKTileOverlayPath(x: pathA.x + 1, y: pathA.y, z: 18, contentScaleFactor: 2)
    let regionA = TerrainTileOverlay.region(for: pathA)
    let regionB = TerrainTileOverlay.region(for: pathB)
    let imageA = await provider.tileImage(x: pathA.x, y: pathA.y, z: pathA.z, region: regionA, pixels: 512)
    let imageB = await provider.tileImage(x: pathB.x, y: pathB.y, z: pathB.z, region: regionB, pixels: 512)
    check("tile A (z18) renders", imageA != nil)
    check("tile B (z18) renders", imageB != nil)

    if let imageA, let imageB {
        // Read straight off the image now: there is no encoded payload to
        // decode, because nothing was encoded.
        check("tile A is exactly 512x512 retina",
              imageA.width == 512 && imageA.height == 512,
              "\(imageA.width)x\(imageA.height)")
        check("tile B is exactly 512x512 retina",
              imageB.width == 512 && imageB.height == 512,
              "\(imageB.width)x\(imageB.height)")

        // Elevation at shared boundary coordinate
        let midLat = (regionA.minLatitude + regionA.maxLatitude) / 2
        let boundaryCoord = CLLocationCoordinate2D(latitude: midLat, longitude: regionA.maxLongitude)
        let boundaryElev = await provider.elevation(at: boundaryCoord)
        check("elevation at shared tile boundary is valid", boundaryElev != nil, "\(String(describing: boundaryElev))")
    }
}

@MainActor
func runCOGCheck() async {
    print("\n=== COGByteReader (live USGS 3DEP COG, byte-range HTTP) ===")
    // A real, public 3DEP 1 m project tile -- discovered via the bucket's own
    // public ListObjectsV2 API, not guessed. Zone 16N, 10012x10012, LZW +
    // floating-point predictor, confirmed against GDAL when this was written.
    guard let url = URL(string:
        "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m/Projects/AL_25Co_B1_2017/TIFF/USGS_1m_x38y376_AL_25Co_B1_2017.tif"
    ) else {
        check("COG URL is well-formed", false)
        return
    }
    let reader = COGByteReader(url: url)

    do {
        let header = try await reader.header()
        check("header reports the known raster dimensions",
              header.width == 10012 && header.height == 10012,
              "\(header.width)x\(header.height)")
        check("header reports 256x256 tiles", header.tileWidth == 256 && header.tileLength == 256)
        check("header reports LZW compression with the floating-point predictor",
              header.compression == 5 && header.predictor == 3,
              "compression=\(header.compression) predictor=\(header.predictor)")
        check("header reports Float32 samples", header.sampleFormat == 3 && header.bitsPerSample == 32)
        check("header decodes the EPSG code from the GeoKey directory", header.epsgCode == 26916,
              "\(String(describing: header.epsgCode))")
        check("header parses GDAL_NODATA", header.noDataValue != nil && header.noDataValue! < -1e30,
              "\(String(describing: header.noDataValue))")

        // Tile 1115 (row 27, col 35) is real terrain, independently confirmed
        // via `gdal_translate -srcwin 8960 6912 256 256` when this was written.
        let tileIndex = 27 * header.tilesAcross + 35
        let (storage, tileWidth, tileHeight) = try await reader.fetchTile(tileIndex)
        check("fetched tile reports 256x256", tileWidth == 256 && tileHeight == 256)

        let floats = storage.pointer.bindMemory(to: Float.self, capacity: tileWidth * tileHeight)
        let row0 = (0..<8).map { floats[$0] }
        let expectedRow0: [Float] = [
            123.91963, 123.70096, 123.43201, 123.129395, 122.86242, 122.593124, 122.38384, 122.15388,
        ]
        check("live-fetched tile matches GDAL's independently decoded values",
              zip(row0, expectedRow0).allSatisfy { abs($0 - $1) < 0.001 },
              "\(row0) vs \(expectedRow0)")

        var voidCount = 0
        var minVal: Float = .infinity, maxVal: Float = -.infinity
        for i in 0..<(tileWidth * tileHeight) {
            let v = floats[i]
            if v.isNaN { voidCount += 1 } else { minVal = min(minVal, v); maxVal = max(maxVal, v) }
        }
        check("tile has zero voids inside this fully-covered footprint", voidCount == 0, "\(voidCount) voids")
        check("tile's elevation range matches GDAL's independently reported range",
              abs(minVal - 95.70592) < 0.001 && abs(maxVal - 131.43253) < 0.001,
              "min=\(minVal) max=\(maxVal)")

        // Geographic round trip: the region this tile covers must itself
        // resolve back to a pixel range covering the same tile.
        if let region = try await reader.tileRegion(col: 35, row: 27) {
            check("tileRegion produces a plausible extent for zone 16N (Alabama)",
                  region.centerLatitude > 30 && region.centerLatitude < 36
                    && region.centerLongitude > -89 && region.centerLongitude < -85,
                  "\(region.centerLatitude), \(region.centerLongitude)")
            if let (cols, rows) = try await reader.pixelRange(covering: region) {
                check("pixelRange(covering: tileRegion(...)) includes this tile's own footprint",
                      cols.contains(35 * 256 + 128) && rows.contains(27 * 256 + 128),
                      "cols=\(cols) rows=\(rows)")
            } else {
                check("pixelRange resolves for a UTM-projected COG", false)
            }
        } else {
            check("tileRegion resolves for a UTM-projected COG", false)
        }
    } catch {
        check("COGByteReader end-to-end fetch and decode", false, "\(error)")
    }
}


@MainActor
func runCoordinatorCheck() async {
    print("\n=== ElevationTileCoordinator (live: TNM discovery -> COG ranges -> GPU nodata -> Mercator resample) ===")
    let coordinator = ElevationTileCoordinator()
    // ~130 m across Monks Mound, Cahokia.
    let region = GeoRegion(center: CLLocationCoordinate2D(latitude: 38.66040, longitude: -90.06205),
                           latitudeSpan: 0.0012, longitudeSpan: 0.0015)
    let products = await coordinator.products(covering: region)
    check("The National Map lists 1 m DEM COGs over Cahokia", !products.isEmpty, "\(products.count)")
    if let first = products.first { print("        newest covering product: \(first.title) (\(first.publicationDate))") }

    let started = Date()
    guard let streamed = await coordinator.elevationRaster(for: region, width: 256, height: 256) else {
        check("coordinator streams and resamples a 256x256 raster", false, "nil")
        return
    }
    let cold = Date().timeIntervalSince(started)
    print(String(format: "        cold stream + resample: %.2f s from %@", cold, streamed.product.title))
    check("resampled raster has full 1 m coverage", streamed.validFraction > 0.99, "\(streamed.validFraction)")
    let relief = streamed.grid.statistics()
    print(String(format: "        resampled elevations %.2f..%.2f m", relief.minimum, relief.maximum))
    check("Monks Mound's ~30 m of relief survives the resample", relief.range > 20, "\(relief.range)")
    let stats = await coordinator.statistics()
    check("every fetched tile was nodata-normalised on the GPU in place", stats.gpuNormalizedTiles == stats.tileFetches && stats.tileFetches > 0, "\(stats)")

    let warmStart = Date()
    _ = await coordinator.elevationRaster(for: region, width: 256, height: 256)
    let warm = Date().timeIntervalSince(warmStart)
    check("a repeat request is served from the tile cache (< 100 ms)", warm < 0.1, String(format: "%.3f s", warm))
    check("a repeat request fetched no new tiles", await coordinator.statistics().tileFetches == stats.tileFetches)

    // Cross-check against the ImageServer's own reprojection of the same footprint.
    // The ImageServer renders a novel extent server-side and has been measured
    // at > 30 s cold, past the app transport's request timeout; give the
    // cross-check its own patient session.
    let patient = URLSessionConfiguration.default
    patient.timeoutIntervalForRequest = 150
    patient.timeoutIntervalForResource = 200
    let slowTransport = HTTPTransport(session: URLSession(configuration: patient))
    if let served = await USGS3DEPService(transport: slowTransport).elevation(for: region, targetSamples: 256).value {
        let cog = streamed.grid
        var sum = 0.0
        var count = 0
        for i in 0..<min(cog.samples.count, served.samples.count) where !cog.samples[i].isNaN && !served.samples[i].isNaN {
            sum += Double(abs(cog.samples[i] - served.samples[i]))
            count += 1
        }
        let mean = count > 0 ? sum / Double(count) : .nan
        let a = cog.statistics(), b = served.statistics()
        print(String(format: "        COG %.2f..%.2f m vs ImageServer %.2f..%.2f m; mean |diff| %.3f m over %d cells",
                     a.minimum, a.maximum, b.minimum, b.maximum, mean, count))
        check("COG resample agrees with the ImageServer to < 0.5 m mean absolute difference", mean < 0.5, "\(mean)")
    } else {
        print("        (ImageServer unavailable; cross-check skipped)")
    }

    // Native tile straight into the micro-topography pipeline, zero-copy.
    if let product = products.first, let geo = await coordinator.georeference(for: product.url) {
        let center = geo.pixel(for: region.center)
        if let tile = await coordinator.tile(product: product.url, column: Int(center.x) / geo.tileWidth, row: Int(center.y) / geo.tileHeight),
           let result = await MetalTerrainPipelineActor.shared.render(.localRelief, raster: tile.raster) {
            check("a streamed tile binds to the GPU zero-copy", result.elevationBinding == .zeroCopy, "\(result.elevationBinding)")
            print(String(format: "        LRM over a native 256x256 COG tile: %.2f ms GPU", result.gpuMilliseconds))
        } else {
            check("native streamed tile renders an LRM", false)
        }
    }

    // The provider's default elevation source: COG first, ImageServer fallback.
    // A throwaway disk cache keeps the tile genuinely cold.
    let coldCache = FileManager.default.temporaryDirectory.appendingPathComponent("cog-first-\(UUID().uuidString)")
    let liveProvider = TerrainTileProvider(gridCache: TileDiskCache(directory: coldCache))
    let tilePathZ19 = tilePath(lat: 38.66040, lon: -90.06205, z: 19)
    let coldStarted = Date()
    let liveTile = await liveProvider.tileImage(
        x: tilePathZ19.x, y: tilePathZ19.y, z: 19, region: TerrainTileOverlay.region(for: tilePathZ19), pixels: 512)
    let coldSeconds = Date().timeIntervalSince(coldStarted)
    print(String(format: "        cold z19 tile through the provider default: %.2f s", coldSeconds))
    check("a cold z19 tile streams through the COG-first default in < 8 s", liveTile != nil && coldSeconds < 8,
          String(format: "%.2f s", coldSeconds))
    try? FileManager.default.removeItem(at: coldCache)
}

await run()
await runCOGCheck()
await runCoordinatorCheck()
print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
