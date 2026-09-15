//
//  ProviderMicroChecks.swift
//  ViewerHarness
//
//  Provider-level checks for the micro-topography integration, on synthetic
//  terrain that is continuous across tile edges.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import simd

/// Flat ground at 120 m with an optional platform mound: 20 m flat top, 2.8 m
/// high, 25 degree flanks. Elevation is a function of Web Mercator position, so
/// neighbouring tiles agree exactly where they meet.
nonisolated struct SyntheticTerrainStub: ElevationProviding {
    let moundCenterMercator: SIMD2<Double>?
    let groundMetersPerMercatorMeter: Double

    func elevation(for region: GeoRegion, targetSamples count: Int) async -> Evidence<ElevationGrid> {
        let m = region.mercatorBounds
        var samples = [Float](repeating: 120, count: count * count)
        if let c = moundCenterMercator {
            let run = 2.8 / tan(25 * Double.pi / 180)
            for y in 0..<count {
                let my = m.maxY - (Double(y) + 0.5) * (m.maxY - m.minY) / Double(count)
                for x in 0..<count {
                    let mx = m.minX + (Double(x) + 0.5) * (m.maxX - m.minX) / Double(count)
                    let gx: Double = (mx - c.x) * groundMetersPerMercatorMeter
                    let gy: Double = (my - c.y) * groundMetersPerMercatorMeter
                    let r: Double = (gx * gx + gy * gy).squareRoot()
                    if r <= 10 {
                        samples[y * count + x] += 2.8
                    } else if r <= 10 + run {
                        samples[y * count + x] += Float(2.8 - (r - 10) / run * 2.8)
                    }
                }
            }
        }
        return .observed(ElevationGrid(width: count, height: count, samples: samples, region: region),
                         Provenance(source: .usgs3DEP))
    }
}

struct SyntheticTileScene {
    let provider: TerrainTileProvider
    let x: Int
    let y: Int
    let z: Int
    let directory: URL

    func region(dx: Int = 0, dy: Int = 0) -> GeoRegion {
        TerrainTileOverlay.region(for: MKTileOverlayPath(x: x + dx, y: y + dy, z: z, contentScaleFactor: 2))
    }

    /// Mercator x of the centre tile's east edge.
    var seamX: Double { region().mercatorBounds.maxX }
    /// Mercator y of the centre tile's middle row.
    var centerY: Double { (region().mercatorBounds.minY + region().mercatorBounds.maxY) / 2 }

    @discardableResult
    func image(dx: Int = 0, dy: Int = 0) async -> CGImage? {
        await provider.tileImage(x: x + dx, y: y + dy, z: z, region: region(dx: dx, dy: dy), pixels: 512)
    }

    func loadNeighbourhood(rings: Int = 1) async {
        for dy in -rings...rings {
            for dx in -rings...rings { await image(dx: dx, dy: dy) }
        }
    }
}

/// A tile scene over Cahokia; `moundOffsetFromSeamMeters` places the mound
/// centre that many ground metres east of the centre tile's east edge.
@MainActor
func makeSyntheticScene(moundOffsetFromSeamMeters: Double?, z: Int = 19) -> SyntheticTileScene {
    let latitude = 38.6605, longitude = -90.0621
    let n = pow(2.0, Double(z))
    let x = Int((longitude + 180) / 360 * n)
    let y = Int((1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n)
    let region = TerrainTileOverlay.region(for: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2))
    let k = cos(latitude * .pi / 180)
    let center = moundOffsetFromSeamMeters.map {
        SIMD2(region.mercatorBounds.maxX + $0 / k, (region.mercatorBounds.minY + region.mercatorBounds.maxY) / 2)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-micro-\(UUID().uuidString)")
    let provider = TerrainTileProvider(
        elevation: SyntheticTerrainStub(moundCenterMercator: center, groundMetersPerMercatorMeter: k),
        gridCache: TileDiskCache(directory: directory)
    )
    return SyntheticTileScene(provider: provider, x: x, y: y, z: z, directory: directory)
}

@MainActor
func runProviderMicroChecks() async {
    print("\n=== Provider micro-topography integration ===")
    await checkRelativeElevationTiles()
    await checkViewshedSnapshot()
    await checkSeamSemantics()
    await checkStaleNeighbourRefresh()
    await checkAnalysisRasterBuilder()
    await checkElevationFallback()
    await checkProviderMemory()
    await checkRedReliefRouting()
    await checkMicroOverlaySettings()
    await checkTransectPipeline()
    await checkViewshedMosaic()
    checkThalwegBuilder()
    await checkRenderBudgets()
}

nonisolated final class RecordingElevationStub: ElevationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let answers: Bool

    init(answers: Bool) { self.answers = answers }

    var callCount: Int { lock.withLock { calls } }

    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        lock.withLock { calls += 1 }
        guard answers else { return .unavailable(.noCoverage(.usgs3DEP)) }
        return .observed(ElevationGrid(width: 2, height: 2, samples: [1, 2, 3, 4], region: region), Provenance(source: .usgs3DEP))
    }
}

@MainActor
func checkElevationFallback() async {
    print("\n--- B7. COG-first elevation ---")
    let region = GeoRegion(minLatitude: 38.66, maxLatitude: 38.661, minLongitude: -90.06, maxLongitude: -90.059)
    let cog = RecordingElevationStub(answers: true), server = RecordingElevationStub(answers: true)
    _ = await FallbackElevationProvider(primary: cog, fallback: server).elevation(for: region, targetSamples: 2)
    check("the COG source answers first and the ImageServer is not asked", cog.callCount == 1 && server.callCount == 0)
    let empty = RecordingElevationStub(answers: false), backup = RecordingElevationStub(answers: true)
    let served = await FallbackElevationProvider(primary: empty, fallback: backup).elevation(for: region, targetSamples: 2)
    check("the ImageServer answers where no COG covers", served.value != nil && backup.callCount == 1)
    check("the provider's default source is COG-first", TerrainTileProvider.defaultElevationSourceDescription == "COG → ImageServer")
}

@MainActor
func checkProviderMemory() async {
    print("\n--- B8. provider memory ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    await scene.loadNeighbourhood()
    let megabytes = await scene.provider.memoryCacheSize() / 1_048_576
    check("9 shaded 512 px tiles hold < 25 MB (no eager derivative planes)", megabytes < 25, "\(megabytes) MB")
    let spot = await scene.provider.inspectSpot(at: scene.region().center)
    check("spot inspection still reports slope without cached derivatives", spot.map { !$0.slopeDegrees.isNaN } ?? false)
    check("the tile cache budget leaves room under the 500 MB app ceiling",
          TerrainTileProvider.maxMemoryCacheBytes <= 256 * 1024 * 1024)
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkRedReliefRouting() async {
    print("\n--- B9. RRIM routing ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .rrim
    await scene.provider.update(settings)
    check("RRIM tiles come from the micro pipeline at native resolution (64 px at z19)", await scene.image()?.width == 64)
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkAnalysisRasterBuilder() async {
    print("\n--- B6. analysis raster builder ---")
    let dest = 8, margin = 2, padded = dest + 2 * margin
    /// Global value encodes row and column, so a wrong source shows up as a wrong number.
    func tile(_ tx: Int, _ ty: Int) -> AnalysisTileSource {
        var s = [Float](repeating: 0, count: padded * padded)
        for py in 0..<padded {
            for px in 0..<padded {
                let gx = tx * dest + px - margin, gy = ty * dest + py - margin
                s[py * padded + px] = Float(gy * 1000 + gx)
            }
        }
        return AnalysisTileSource(samples: s, paddedWidth: padded, margin: margin)
    }
    var all: [SIMD2<Int32>: AnalysisTileSource] = [:]
    for dy in -1...1 {
        for dx in -1...1 where !(dx == 0 && dy == 0) { all[SIMD2(Int32(dx), Int32(dy))] = tile(dx, dy) }
    }

    if let full = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: all) {
        let values = full.pointer!.assumingMemoryBound(to: Float.self)
        var wrong = 0
        for oy in 0..<16 {
            for ox in 0..<16 where values[oy * 16 + ox] != Float((oy - 4) * 1000 + (ox - 4)) { wrong += 1 }
        }
        check("stitching reads every skirt pixel from the right neighbour", wrong == 0, "\(wrong) wrong")
        check("the destination window sits at the skirt", full.window == DestinationWindow(originX: 4, originY: 4, width: 8, height: 8))
        check("a full neighbourhood reports nothing missing", full.missingNeighbours.isEmpty)
    } else {
        check("the analysis raster builds", false)
    }
    if let half = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 2, cellSizeX: 1, cellSizeY: 1, neighbours: all) {
        let v = half.pointer!.assumingMemoryBound(to: Float.self)
        let expected: Float = (Float(-4 * 1000 - 4) + Float(-4 * 1000 - 3) + Float(-3 * 1000 - 4) + Float(-3 * 1000 - 3)) / 4
        check("decimation box-averages source pixels", half.geometry.width == 8 && abs(v[0] - expected) < 1e-3, "\(v[0])")
        check("decimated cells are proportionally larger", half.geometry.cellSizeX == 2 && half.window.width == 4)
    }
    var withoutEast = all
    withoutEast[SIMD2(1, 0)] = nil
    if let gap = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: withoutEast) {
        let v = gap.pointer!.assumingMemoryBound(to: Float.self)
        check("a missing neighbour is reported", gap.missingNeighbours.contains(SIMD2(1, 0)))
        check("the centre's own skirt still answers next to a missing neighbour", v[4 * 16 + 4 + dest] == Float(0 * 1000 + dest))
        check("beyond the centre's skirt a missing neighbour is a void, not replicated terrain", v[4 * 16 + 4 + dest + margin].isNaN)
    }
    check("z19 oversampled 3DEP decimates 8x to reach 1 m",
          AnalysisRasterBuilder.decimation(tileGroundSampleDistance: 0.1165, nativeGroundSampleDistance: 1, destinationPixels: 512) == 8)
    check("native tiles are not decimated",
          AnalysisRasterBuilder.decimation(tileGroundSampleDistance: 1.2, nativeGroundSampleDistance: 1.2, destinationPixels: 256) == 1)
    let skirt = AnalysisRasterBuilder.skirtPixels(radiusMeters: 25, groundSampleDistance: 0.1165, decimation: 8, destinationPixels: 512)
    check("the skirt covers the radius and keeps the decimated width a multiple of 4",
          Double(skirt) * 0.1165 >= 25 && ((512 + 2 * skirt) / 8) % 4 == 0, "\(skirt)")

    // An iPad Pro 13" (M5) draws the overlay at contentScaleFactor ~1.477, so
    // tiles came out Int(256 * 1.477) = 378 px. A 1 m tile that wide cannot
    // decimate, and a zero-radius product's 2 px skirt left the stitched raster
    // 382 wide, tripping the builder's multiple-of-4 assertion on device.
    for scale in [1.0, 1.25, 1.4765625, 2.0, 3.0] as [CGFloat] {
        let pixels = TerrainTileOverlayRenderer.tilePixels(tileSize: 256, contentScaleFactor: scale)
        var misaligned: [Int] = []
        for mpp in [1.0, 0.1165] {
            for radius: Float in [0, 5, 25] {
                let f = AnalysisRasterBuilder.decimation(
                    tileGroundSampleDistance: mpp, nativeGroundSampleDistance: max(mpp, 1), destinationPixels: pixels)
                let s = AnalysisRasterBuilder.skirtPixels(
                    radiusMeters: radius, groundSampleDistance: mpp, decimation: f, destinationPixels: pixels)
                let width = (pixels + 2 * s) / f
                if width % 4 != 0 { misaligned.append(width) }
            }
        }
        check("@\(scale)x tiles (\(pixels) px) stitch analysis rasters a multiple of 4 wide",
              misaligned.isEmpty, "widths \(misaligned)")
    }
    check("integral scales keep their tile sizes (256 / 512 / 768 px)",
          [1.0, 2.0, 3.0].map { TerrainTileOverlayRenderer.tilePixels(tileSize: 256, contentScaleFactor: $0) } == [256, 512, 768])

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    let cold = await scene.image()
    settings.azimuthDegrees += 1
    await scene.provider.update(settings)
    let started = Date()
    _ = await scene.image()
    let warmMs = Date().timeIntervalSince(started) * 1000
    print(String(format: "        warm LRM tile at z19: %.1f ms", warmMs))
    check("an LRM tile at z19 is analysed at native 1 m (64 px)", cold?.width == 64, "\(cold?.width ?? -1)")
    check("an LRM tile renders in under 8 ms warm", warmMs < 8, String(format: "%.1f ms", warmMs))
    settings.contourInterval = .halfMeter
    await scene.provider.update(settings)
    check("with contours the composite returns to display resolution", await scene.image()?.width == 512)
    try? FileManager.default.removeItem(at: scene.directory)
}

func onePixelImage() -> CGImage {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

@MainActor
func checkStaleNeighbourRefresh() async {
    print("\n--- B5. stale neighbour refresh ---")
    let store = TileImageStore()
    let path = MKTileOverlayPath(x: 1, y: 2, z: 19, contentScaleFactor: 2)
    let key = TerrainTileOverlayRenderer.key(path)
    let generation = store.beginLoad(key) ?? -1
    _ = store.finishLoad(key, image: onePixelImage(), generation: generation)
    check("a drawn tile is not re-requested", store.beginLoad(key) == nil)
    check("marking stale reports only drawn tiles", store.markStale([key, "19/9/9"]) == [key])
    check("a stale tile keeps drawing its old image", store.image(for: key) != nil)
    check("a stale tile is requested again", store.partition([path], key: TerrainTileOverlayRenderer.key).missing.count == 1)
    let refresh = store.beginLoad(key)
    check("a stale tile may begin a reload", refresh != nil)
    _ = store.finishLoad(key, image: onePixelImage(), generation: refresh ?? -1)
    check("a finished reload clears staleness", store.beginLoad(key) == nil)
    check("paths round-trip through keys",
          TerrainTileOverlayRenderer.path(forKey: key).map { $0.x == 1 && $0.y == 2 && $0.z == 19 } ?? false)

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    await scene.image()
    _ = await scene.provider.takeStaleTiles()
    await scene.image(dx: 1)
    let stale = await scene.provider.takeStaleTiles()
    check("a neighbour's arrival marks the shaded tile stale", stale.contains("\(scene.z)/\(scene.x)/\(scene.y)"), "\(stale)")
    check("stale tiles drain once", await scene.provider.takeStaleTiles().isEmpty)
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkViewshedSnapshot() async {
    print("\n--- B3. viewshed snapshot ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -40)
    await scene.loadNeighbourhood()
    let observer = scene.region().center
    guard let snapshot = await scene.provider.viewshed(at: observer, maxRadiusMeters: 80) else {
        check("provider viewshed renders", false, "nil")
        return
    }
    check("the snapshot region contains the observer", snapshot.region.contains(observer))
    check("the snapshot region matches the mask's pixel grid",
          snapshot.result.mask.width == snapshot.result.display.width && snapshot.result.mask.width > 0)
    check("the observer's own cell is visible", snapshot.result.mask.values().contains(1))
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkSeamSemantics() async {
    print("\n--- B4. seam semantics ---")
    func signatures(moundOffset: Double?) async -> [TransectSignature] {
        let scene = makeSyntheticScene(moundOffsetFromSeamMeters: moundOffset)
        await scene.image()
        await scene.image(dx: 1)
        let k = cos(38.6605 * Double.pi / 180)
        let start = GeoRegion.fromMercatorMeters(x: scene.seamX - 45 / k, y: scene.centerY)
        let end = GeoRegion.fromMercatorMeters(x: scene.seamX + 45 / k, y: scene.centerY)
        let analysis = await scene.provider.analyzeTransect(from: start, to: end)
        try? FileManager.default.removeItem(at: scene.directory)
        return analysis?.signatures ?? []
    }
    check("flat ground across a same-zoom seam raises no signature", await signatures(moundOffset: nil).isEmpty)
    check("a platform whose edge sits on a same-zoom seam is still detected",
          await signatures(moundOffset: -10).filter { $0.kind == .platformMound }.count == 1)

    let lat = 38.6553, span = 0.0005
    func grid(_ minLon: Double, _ maxLon: Double, gsd: Double) -> ElevationGrid {
        let region = GeoRegion(minLatitude: lat, maxLatitude: lat + span, minLongitude: minLon, maxLongitude: maxLon)
        let w = Int((region.widthMeters / gsd).rounded()) + 1, h = Int((region.heightMeters / gsd).rounded()) + 1
        return ElevationGrid(width: w, height: h, samples: [Float](repeating: 100, count: w * h), region: region)
    }
    let west = grid(-90.0630, -90.0621, gsd: 0.5)
    let eastCoarse = grid(-90.0621, -90.0612, gsd: 2.0)
    let eastFine = grid(-90.0621, -90.0612, gsd: 0.5)
    let origin = CLLocationCoordinate2D(latitude: lat + span / 2, longitude: -90.0621)
    let mixed = TileMosaicField(origin: origin, layers: [
        .init(grid: west, bounds: west.region), .init(grid: eastCoarse, bounds: eastCoarse.region),
    ])
    let uniform = TileMosaicField(origin: origin, layers: [
        .init(grid: west, bounds: west.region), .init(grid: eastFine, bounds: eastFine.region),
    ])
    check("a 0.5 m / 2 m boundary is a resolution seam", mixed.isResolutionSeam(point: SIMD2(0, 0)))
    check("a 0.5 m / 0.5 m boundary is not", !uniform.isResolutionSeam(point: SIMD2(0, 0)))
}

@MainActor
func checkRelativeElevationTiles() async {
    print("\n--- B2. REM tiles ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .relativeElevation
    await scene.provider.update(settings)
    check("a REM tile renders with no drawn thalweg (flat water plane)", await scene.image() != nil)

    let r = scene.region()
    settings.thalweg = [
        ThalwegPoint(latitude: r.maxLatitude, longitude: r.minLongitude, waterSurface: 119.5),
        ThalwegPoint(latitude: r.minLatitude, longitude: r.maxLongitude, waterSurface: 119.0),
    ]
    await scene.provider.update(settings)
    check("a REM tile renders against a drawn thalweg", await scene.image() != nil)

    let m = r.mercatorBounds
    let pixel = (m.maxX - m.minX) / 512
    let firstPixel = GeoRegion.fromMercatorMeters(x: m.minX + 0.5 * pixel, y: m.maxY - 0.5 * pixel)
    let vertices = TerrainTileProvider.thalwegVertices(
        [ThalwegPoint(latitude: firstPixel.latitude, longitude: firstPixel.longitude, waterSurface: 5)],
        fallbackSurface: 0, tileBounds: m, destinationPixels: 512, skirt: 16, cellSizeX: 0.1, cellSizeY: 0.1)
    check("a thalweg point on the tile's first pixel centre lands on the skirt origin",
          vertices.count == 1 && abs(vertices[0].x - 1.6) < 1e-3 && abs(vertices[0].y - 1.6) < 1e-3, "\(vertices)")
    check("no thalweg means one flat-plane vertex",
          TerrainTileProvider.thalwegVertices([], fallbackSurface: 42, tileBounds: m, destinationPixels: 512,
                                              skirt: 16, cellSizeX: 0.1, cellSizeY: 0.1).map(\.waterSurface) == [42])
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkMicroOverlaySettings() async {
    print("\n--- C1. overlays and grazing light ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.style = .rakingLight
    model.rakingAltitude = 7
    model.showsHabitationMask = true
    model.skyViewShading = 0.5
    try? await Task.sleep(for: .milliseconds(80))
    let settings = await scene.provider.currentSettings()
    check("grazing altitude reaches the provider", settings.rakingAltitudeDegrees == 7)
    check("overlay toggles reach the provider", settings.showsHabitationMask && settings.skyViewShading == 0.5)
    check("custom overlays count as custom shading", model.hasCustomShading)
    await scene.loadNeighbourhood()
    check("a tile with the habitation overlay composites at display resolution", await scene.image()?.width == 512)
    model.resetShading()
    check("reset restores overlay defaults",
          model.rakingAltitude == TerrainViewerModel.Defaults.rakingAltitude && !model.showsHabitationMask && model.skyViewShading == 0)
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkTransectPipeline() async {
    print("\n--- C3. transect pipeline ---")
    var points: [ElevationProfilePoint] = (0..<2_000).map {
        ElevationProfilePoint(id: $0, distanceMeters: Double($0) * 0.5, elevationMeters: 100,
                              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
    }
    points[1_234] = ElevationProfilePoint(id: 1_234, distanceMeters: 617, elevationMeters: 98.8,
                                          coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
    let decimated = ProfileDecimation.minMax(points, maxCount: 384)
    check("min-max decimation respects the point budget", decimated.count <= 384, "\(decimated.count)")
    check("a one-sample ditch survives decimation", decimated.contains { $0.elevationMeters == 98.8 })
    check("decimation keeps distance order", zip(decimated, decimated.dropFirst()).allSatisfy { $0.distanceMeters <= $1.distanceMeters })

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    await scene.loadNeighbourhood(rings: 2)
    let r = scene.region()
    let field = await scene.provider.transectMosaic(around: r.center, and: CLLocationCoordinate2D(latitude: r.center.latitude, longitude: r.maxLongitude))
    check("the transect field holds only tiles near the line", field.layers.count <= 6, "\(field.layers.count) of 25")
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkViewshedMosaic() async {
    print("\n--- C4. viewshed mosaic ---")
    check("resolution tiers: 1 m to 1 km, 2.5 m to 2.5 km, 5 m beyond",
          MercatorMosaicBuilder.tieredCellSize(radiusMeters: 800) == 1
            && MercatorMosaicBuilder.tieredCellSize(radiusMeters: 2_000) == 2.5
            && MercatorMosaicBuilder.tieredCellSize(radiusMeters: 4_000) == 5)
    let coarse = makeGrid(width: 100, height: 100, gsd: 20, base: 50)
    let fine = makeGrid(width: 81, height: 81, gsd: 1, base: 60)
    let layers = [TileMosaicField.Layer(grid: coarse, bounds: coarse.region), TileMosaicField.Layer(grid: fine, bounds: fine.region)]
    if let mosaic = MercatorMosaicBuilder.build(center: fine.region.center, radiusMeters: 5_000, finestGroundSampleDistance: 1, layers: layers) {
        let v = mosaic.storage.pointer.assumingMemoryBound(to: Float.self)
        let c = mosaic.pixel(for: fine.region.center)
        check("a 5 km mosaic stays within 2048² and a multiple of 4", mosaic.size <= 2048 && mosaic.size % 4 == 0, "\(mosaic.size)")
        let fineIdx = Int(c.y) * mosaic.size + Int(c.x)
        check("the finest layer wins where it covers", v[fineIdx] == 60)
        let coarseIdx = (Int(c.y) + 100) * mosaic.size + Int(c.x)
        check("coarser layers fill elsewhere", v[coarseIdx] == 50)
        check("ground outside every layer is a void", v[0].isNaN)
    } else {
        check("viewshed mosaic builds", false)
    }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -40)
    await scene.loadNeighbourhood(rings: 2)
    if let wide = await scene.provider.viewshed(at: scene.region().center, maxRadiusMeters: 300) {
        let spanMeters = wide.region.widthMeters
        check("a 300 m viewshed covers ~600 m of ground", abs(spanMeters - 600) < 40, String(format: "%.0f m", spanMeters))
        check("the observer sees its own neighbourhood", wide.result.mask.values().filter { $0 > 0.5 }.count > 1_000)
    } else {
        check("provider mosaic viewshed renders", false)
    }
    try? FileManager.default.removeItem(at: scene.directory)
}

@MainActor
func checkThalwegBuilder() {
    print("\n--- C5. thalweg builder ---")
    var valley = sceneGrid(width: 200, height: 200, gsd: 1.0) { x, y in 100 + 0.2 * Float(abs(x - 100)) - 0.01 * Float(y) }
    var samples = valley.samples
    for y in 90...92 { samples[y * 200 + 100] += 3 }   // a bridge deck over the channel
    valley = ElevationGrid(width: 200, height: 200, samples: samples, region: valley.region)
    let drawn = [valley.coordinate(x: 103, y: 10), valley.coordinate(x: 103, y: 190)]
    let points = ThalwegBuilder.build(drawn: drawn) { valley.interpolatedElevation(at: $0) }
    check("a 180 m line densifies to ~15 m spacing", (12...15).contains(points.count), "\(points.count)")
    let (_, row0) = valley.gridCoordinates(for: points[0].coordinate)
    check("vertices snap to the channel floor, not the bank 3 m away",
          points.allSatisfy { p in
              let (_, row) = valley.gridCoordinates(for: p.coordinate)
              return abs(p.waterSurface - (100 - 0.01 * Float(row))) < 0.25
          }, "row0 \(row0)")
    check("the water surface falls monotonically downstream (bridge removed)",
          zip(points, points.dropFirst()).allSatisfy { $0.waterSurface >= $1.waterSurface })
    check("fewer than two drawn points build nothing", ThalwegBuilder.build(drawn: [drawn[0]]) { _ in 1 }.isEmpty)
}

@MainActor
func checkRenderBudgets() async {
    print("\n--- C6. per-zoom tile render budget (warm, ms) ---")
    for z in [18, 19, 20] {
        let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30, z: z)
        await scene.loadNeighbourhood()
        var row: [String] = []
        var settings = TerrainStyleSettings()
        for style in [ReliefStyle.localRelief, .rrim, .skyView, .rakingLight, .relativeElevation] {
            settings.style = style
            await scene.provider.update(settings)
            _ = await scene.image()
            settings.azimuthDegrees += 1
            await scene.provider.update(settings)
            let started = Date()
            let image = await scene.image()
            let ms = Date().timeIntervalSince(started) * 1000
            row.append("\(style.rawValue) \(String(format: "%.1f", ms))")
            check("z\(z) \(style.rawValue) renders within 16 ms warm", image != nil && ms < 16, String(format: "%.1f ms", ms))
        }
        print("        z\(z): " + row.joined(separator: " · "))
        try? FileManager.default.removeItem(at: scene.directory)
    }
}


