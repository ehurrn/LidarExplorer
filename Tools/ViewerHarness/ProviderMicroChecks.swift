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
    await checkTileBurstConcurrency()
    await checkOffScreenTileCulling()
    await checkReloadKeepsTilesOnScreen()
    await checkAnalysisRasterBuilder()
    await checkElevationFallback()
    await checkProviderMemory()
    await checkMicroTopographyRouting()
    await checkMicroOverlaySettings()
    await checkTransectPipeline()
    await checkViewshedMosaic()
    await checkAnalyticalRaster()
    await checkMemoryPressure()
    await checkActiveGridRegistration()
    checkThalwegBuilder()
    await checkRenderBudgets()
    await checkSunControls()
}

/// A shaded tile's size and RGBA bytes, so tiles shaded under two settings
/// can be compared.
struct TilePixels: Equatable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    /// Mean red over the pixels whose centres `include` accepts, 0...255.
    func meanRed(where include: (_ x: Double, _ y: Double) -> Bool = { _, _ in true }) -> Double {
        var sum = 0.0, count = 0
        for y in 0..<height {
            for x in 0..<width where include(Double(x) + 0.5, Double(y) + 0.5) {
                sum += Double(rgba[(y * width + x) * 4])
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : .nan
    }
}

@MainActor
func checkSunControls() async {
    print("\n--- C7. sun controls ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    func shade(_ settings: TerrainStyleSettings) async -> TilePixels? {
        await scene.provider.update(settings)
        guard let image = await scene.image(), let rgba = rgbaBytes(image) else { return nil }
        return TilePixels(width: image.width, height: image.height, rgba: rgba)
    }

    // A sun control belongs on screen exactly where it changes the picture.
    // Every style is shaded under a baseline sun and again with one control
    // moved; a control offered to a style it leaves untouched, or one that
    // changes a style without being offered, is a mismatch.
    var direction: [String] = [], altitude: [String] = [], grazing: [String] = []
    var occlusion: (northwestSun: TilePixels, southeastSun: TilePixels, lowerSun: TilePixels)?
    for style in ReliefStyle.allCases {
        var baseline = TerrainStyleSettings()
        baseline.style = style
        baseline.azimuthDegrees = 315
        baseline.altitudeDegrees = 35
        baseline.rakingAltitudeDegrees = 10
        var turned = baseline
        turned.azimuthDegrees = 135
        var raised = baseline
        raised.altitudeDegrees = 60
        var lowered = baseline
        lowered.rakingAltitudeDegrees = 5
        guard let lit = await shade(baseline), let byDirection = await shade(turned),
              let byAltitude = await shade(raised), let byGrazing = await shade(lowered) else {
            check("\(style.rawValue) tiles shade under every sun setting", false)
            continue
        }
        func mismatch(offered: Bool, changed: Bool) -> String? {
            offered == changed ? nil : "\(style.rawValue) \(offered ? "offers it but ignores it" : "responds but hides it")"
        }
        if let m = mismatch(offered: style.usesSunDirection, changed: byDirection != lit) { direction.append(m) }
        if let m = mismatch(offered: style.usesSunAltitude, changed: byAltitude != lit) { altitude.append(m) }
        if let m = mismatch(offered: style.usesGrazingSunAltitude, changed: byGrazing != lit) { grazing.append(m) }
        if style == .directionalOcclusion { occlusion = (lit, byDirection, byGrazing) }
    }
    check("the dock's sun direction slider is offered exactly where it changes tiles", direction.isEmpty, "\(direction)")
    check("Sun Altitude is offered exactly where it changes tiles", altitude.isEmpty, "\(altitude)")
    check("Grazing Sun Altitude is offered exactly where it changes tiles", grazing.isEmpty, "\(grazing)")
    check("Multi-directional offers no sun direction: its four azimuths are fixed",
          !ReliefStyle.multiDirectional.usesSunDirection)

    if let occlusion {
        check("Directional Occlusion tiles come from the micro pipeline at native resolution (64 px at z19)",
              occlusion.northwestSun.width == 64, "\(occlusion.northwestSun.width) px")
        check("Directional Occlusion tiles change with the sun direction", occlusion.northwestSun != occlusion.southeastSun)
        // Split the tile on the northeast-southwest diagonal through the mound:
        // its shadow has to land on the half facing away from the sun.
        let k = cos(38.6605 * Double.pi / 180)
        let m = scene.region().mercatorBounds
        let moundX = 1 - 30 / k / (m.maxX - m.minX)
        func halves(_ tile: TilePixels) -> (northwest: Double, southeast: Double) {
            let cx = moundX * Double(tile.width), cy = 0.5 * Double(tile.height)
            return (tile.meanRed { x, y in (x - cx) + (y - cy) < 0 },
                    tile.meanRed { x, y in (x - cx) + (y - cy) > 0 })
        }
        let underNorthwest = halves(occlusion.northwestSun), underSoutheast = halves(occlusion.southeastSun)
        check("the mound's shadow falls southeast under a northwest sun and northwest under a southeast one",
              underNorthwest.southeast < underNorthwest.northwest && underSoutheast.northwest < underSoutheast.southeast,
              String(format: "NW sun: nw %.1f se %.1f; SE sun: nw %.1f se %.1f",
                     underNorthwest.northwest, underNorthwest.southeast, underSoutheast.northwest, underSoutheast.southeast))
        let lowerMean = occlusion.lowerSun.meanRed(), baselineMean = occlusion.northwestSun.meanRed()
        check("a lower grazing sun casts more Directional Occlusion shadow", lowerMean < baselineMean,
              String(format: "5° %.2f vs 10° %.2f", lowerMean, baselineMean))
    }

    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.style = .directionalOcclusion
    try? await Task.sleep(for: .milliseconds(80))
    model.rakingAltitude = 6
    try? await Task.sleep(for: .milliseconds(80))
    check("Grazing Sun Altitude reaches the provider while Directional Occlusion is shown",
          await scene.provider.currentSettings().rakingAltitudeDegrees == 6)
    try? FileManager.default.removeItem(at: scene.directory)
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
func checkMicroTopographyRouting() async {
    print("\n--- B9. micro-topography routing ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    // The fused display kernel has no case for micro-topography styles: it
    // shades raw elevation against the style's range, one saturated colour.
    var flat: [String] = []
    for style in ReliefStyle.allCases where style.microTopographyProduct != nil {
        var settings = TerrainStyleSettings()
        settings.style = style
        await scene.provider.update(settings)
        let image = await scene.image()
        check("\(style.rawValue) tiles come from the micro pipeline at native resolution (64 px at z19)",
              image?.width == 64, "\(image?.width ?? -1) px")
        if let image, let rgba = rgbaBytes(image),
           stride(from: 4, to: rgba.count, by: 4).allSatisfy({ rgba[$0..<$0 + 4] == rgba[0..<4] }) {
            flat.append(style.rawValue)
        }
    }
    check("every micro-topography style draws the mound rather than one flat colour", flat.isEmpty, "\(flat)")
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

nonisolated final class FailureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseGenerator: (@Sendable () -> (Data?, HTTPURLResponse?, (any Error)?))?

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        if let gen = Self.responseGenerator {
            let (data, response, error) = gen()
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                if let response {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override nonisolated func stopLoading() {}
}

@MainActor
func checkStaleNeighbourRefresh() async {
    print("\n--- B5. stale neighbour refresh ---")
    let store = TileImageStore()
    let path = MKTileOverlayPath(x: 1, y: 2, z: 19, contentScaleFactor: 2)
    let key = TerrainTileOverlayRenderer.key(path)
    if let ticket = store.beginLoad(key) {
        _ = store.finishLoad(key, image: onePixelImage(), ticket: ticket)
    }
    check("a drawn tile is not re-requested", store.beginLoad(key) == nil)
    check("marking stale reports only drawn tiles", store.markStale([key, "19/9/9"]) == [key])
    check("a stale tile keeps drawing its old image", store.image(for: key) != nil)
    check("a stale tile is requested again", store.partition([path], key: TerrainTileOverlayRenderer.key).missing.count == 1)
    let refresh = store.beginLoad(key)
    check("a stale tile may begin a reload", refresh != nil)
    if let refresh { _ = store.finishLoad(key, image: onePixelImage(), ticket: refresh) }
    check("a finished reload clears staleness", store.beginLoad(key) == nil)
    check("paths round-trip through keys",
          TerrainTileOverlayRenderer.path(forKey: key).map { $0.x == 1 && $0.y == 2 && $0.z == 19 } ?? false)

    // Task cancellation & tracking in TileImageStore
    let cancelStore = TileImageStore()
    let cancelKey = "19/1/2"
    let cancelTicket = cancelStore.beginLoad(cancelKey)
    check("a fresh tile can be claimed", cancelTicket != nil)
    let longTask = Task<Void, Never> {
        _ = try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
    if let cancelTicket { cancelStore.recordTask(longTask, for: cancelKey, ticket: cancelTicket) }
    check("in-flight task is tracked", cancelStore.inFlightTaskCount() == 1)
    cancelStore.invalidate()
    check("invalidate cancels in-flight tasks", longTask.isCancelled)
    check("invalidate clears in-flight task count", cancelStore.inFlightTaskCount() == 0)

    // Registering for an obsolete generation cancels immediately
    let staleTask = Task<Void, Never> {
        _ = try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
    // The ticket's generation is now obsolete.
    if let cancelTicket { cancelStore.recordTask(staleTask, for: cancelKey, ticket: cancelTicket) }
    check("recording task for obsolete generation cancels it", staleTask.isCancelled)

    // Finish load deregisters task
    let normalStore = TileImageStore()
    let normalTicket = normalStore.beginLoad(cancelKey)
    let normalTask = Task { }
    if let normalTicket {
        normalStore.recordTask(normalTask, for: cancelKey, ticket: normalTicket)
        _ = normalStore.finishLoad(cancelKey, image: onePixelImage(), ticket: normalTicket)
    }
    check("finishLoad clears task from in-flight storage", normalStore.inFlightTaskCount() == 0)

    // Finish load before recordTask drops task registration without leaking
    let earlyFinishStore = TileImageStore()
    let earlyKey = "19/1/3"
    let earlyTicket = earlyFinishStore.beginLoad(earlyKey)
    let earlyTask = Task { }
    if let earlyTicket {
        _ = earlyFinishStore.finishLoad(earlyKey, image: onePixelImage(), ticket: earlyTicket)
        earlyFinishStore.recordTask(earlyTask, for: earlyKey, ticket: earlyTicket)
    }
    check("finishLoad before recordTask does not leak task", earlyFinishStore.inFlightTaskCount() == 0)
    check("task is not cancelled when dropped after normal completion", !earlyTask.isCancelled)

    // USGS3DEPService circuit breaker
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailureURLProtocol.self]
    let mockSession = URLSession(configuration: config)
    let mockTransport = HTTPTransport(session: mockSession)
    let service = USGS3DEPService(transport: mockTransport)

    let testRegion1 = GeoRegion(center: CLLocationCoordinate2D(latitude: 37.0, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005)
    let testRegion2 = GeoRegion(center: CLLocationCoordinate2D(latitude: 37.1, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005)
    let testRegion3 = GeoRegion(center: CLLocationCoordinate2D(latitude: 37.2, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005)
    let testRegion4 = GeoRegion(center: CLLocationCoordinate2D(latitude: 37.3, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005)

    FailureURLProtocol.responseGenerator = { (nil, nil, URLError(.timedOut)) }

    _ = await service.elevation(for: testRegion1)
    check("1 failure does not trip circuit breaker", await !service.isCooldownActive())

    _ = await service.elevation(for: testRegion2)
    check("2 failures do not trip circuit breaker", await !service.isCooldownActive())

    _ = await service.elevation(for: testRegion3)
    check("3 consecutive failures trip circuit breaker", await service.isCooldownActive())

    let tripOutcome = await service.elevation(for: testRegion4)
    if case .unavailable(.transportFailure(_, let desc)) = tripOutcome {
        check("circuit breaker rejects subsequent request fast", desc.contains("circuit breaker open"))
    } else {
        check("circuit breaker rejects subsequent request fast", false)
    }

    await service.resetCooldown()
    check("resetCooldown resets circuit breaker", await !service.isCooldownActive())

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

/// R1-M1: a MapKit-like tile burst, driven through the exact claim/record/finish
/// sequence `TerrainTileOverlayRenderer.request(_:zoomScale:)` uses.
///
/// A fast flick pans the viewport without ever calling `reloadData()`, so
/// `TileImageStore`'s generation fence -- which only advances on a settings
/// reload -- cannot and does not cancel any of these tiles: every one runs to
/// completion regardless of whether it scrolled back off-screen. This check
/// measures what that costs downstream: whether the GPU surface pool (whose
/// 192 MB `idleByteLimit` only bounds *idle* buffers, not ones a live render
/// is holding) lets concurrently in-flight tiles pile up unbounded leases, or
/// leak one past the burst.
@MainActor
func checkTileBurstConcurrency() async {
    print("\n--- B10. MapKit-like tile burst concurrency (R1-M1) ---")
    let z = 19
    let baseX = 140_000, baseY = 206_000
    let cols = 6, rows = 4
    let tileCount = cols * rows
    let pixels = 512

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("burst-\(UUID().uuidString)")
    let provider = TerrainTileProvider(
        elevation: SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1),
        gridCache: TileDiskCache(directory: directory)
    )
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await provider.update(settings)

    let store = TileImageStore()
    let pipeline = MetalTerrainPipelineActor.shared
    let baselineLive = await pipeline.poolStatistics().liveLeases

    let monitor = Task<(peakInFlight: Int, peakLive: Int), Never> {
        var peakInFlight = 0
        var peakLive = 0
        while !Task.isCancelled {
            peakInFlight = max(peakInFlight, store.inFlightTaskCount())
            peakLive = max(peakLive, await pipeline.poolStatistics().liveLeases)
            try? await Task.sleep(nanoseconds: 250_000)
        }
        return (peakInFlight, peakLive)
    }

    var tasks: [Task<Void, Never>] = []
    for row in 0..<rows {
        for col in 0..<cols {
            let x = baseX + col, y = baseY + row
            let key = "\(z)/\(x)/\(y)"
            guard let ticket = store.beginLoad(key) else { continue }
            let region = TerrainTileOverlay.region(for: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2))
            let task = Task<Void, Never> {
                let image = await provider.tileImage(x: x, y: y, z: z, region: region, pixels: pixels)
                _ = store.finishLoad(key, image: image, ticket: ticket)
            }
            store.recordTask(task, for: key, ticket: ticket)
            tasks.append(task)
        }
    }

    check("every tile in the burst claimed the store (no dedup collision)", tasks.count == tileCount, "\(tasks.count)/\(tileCount)")
    for task in tasks { await task.value }
    monitor.cancel()
    let peak = await monitor.value
    let finalLive = await pipeline.poolStatistics().liveLeases

    check("no in-flight tiles remain once the burst drains", store.inFlightTaskCount() == 0)
    check(
        "the generation fence does not throttle a pan burst (no flight gate today)",
        peak.peakInFlight == tileCount, "\(peak.peakInFlight)/\(tileCount)"
    )
    // Each tile briefly holds two leases at once -- the stitched analysis
    // raster it renders from, and the display bitmap it renders to -- before
    // the first is released, so the realistic ceiling is roughly double the
    // burst size, not exactly it.
    check(
        "GPU live leases during the burst stay bounded by ~2x tile count (input + output overlap)",
        peak.peakLive - baselineLive <= tileCount * 2, "\(peak.peakLive) live vs \(tileCount) tiles"
    )
    // Each output CGImage's data provider retains its SurfaceLease by design
    // (MetalTerrainPipelineActor.swift: "the buffer is recycled only when the
    // image is released"), so every tile's surface is still legitimately
    // live here -- held by `store.images`, not leaked. That is exactly the
    // R1-M1 exposure: peak *active* GPU memory during a burst scales with
    // how many tiles are concurrently rendering or on screen, unbounded by
    // the 192 MB idle-only cap.
    check(
        "leases stay live while their images are held (zero-copy, not a leak)",
        finalLive - baselineLive == tileCount, "\(finalLive) vs baseline \(baselineLive)"
    )

    // Dropping the renderer's own cache is not enough: `TerrainTileProvider`
    // keeps a second, independent reference to every shaded bitmap in
    // `cache[key].rendered` (its `renderedOrder` LRU, capped at 48 --
    // `renderedLimit`), so the provider -- not the renderer's generation
    // fence -- is what actually bounds how many tiles' surfaces a sustained
    // pan can hold live at once. `store.invalidate()` alone does not touch
    // it; only a settings change (`update`, via `releaseAllBitmaps()`) or
    // memory pressure does.
    store.invalidate()
    let afterStoreInvalidate = await pipeline.poolStatistics().liveLeases
    check(
        "the provider's own bitmap cache -- not the store -- is what still holds them",
        afterStoreInvalidate == finalLive, "\(afterStoreInvalidate) vs \(finalLive) before invalidate"
    )

    await provider.update(TerrainStyleSettings())
    let afterProviderRelease = await pipeline.poolStatistics().liveLeases
    check(
        "leases release once the provider's bitmap cache is also cleared",
        afterProviderRelease == baselineLive, "\(afterProviderRelease) vs baseline \(baselineLive)"
    )
    print("        peak in-flight tile loads: \(peak.peakInFlight)/\(tileCount) · peak GPU live leases: \(peak.peakLive) (baseline \(baselineLive)) · held after store.invalidate(): \(afterStoreInvalidate - baselineLive) · provider renderedLimit caps this at 48")

    try? FileManager.default.removeItem(at: directory)
}

/// Off-screen tile culling: cancelling in-flight tiles a pan has carried well
/// outside the viewport, which the generation fence deliberately cannot do
/// (a pan changes no settings, so the generation never moves).
///
/// The two races this has to survive are both consequences of culling *not*
/// bumping the generation: a culled key can be claimed again immediately, so
/// claim identity -- not the generation -- is what decides whether a late
/// result still owns the bookkeeping it is about to retire.
@MainActor
func checkOffScreenTileCulling() async {
    print("\n--- B11. off-screen tile culling ---")
    let store = TileImageStore()
    let key = "19/5/5"
    let first = store.beginLoad(key)
    guard let first else { check("a fresh key can be claimed", false); return }

    let stranded = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
    store.recordTask(stranded, for: key, ticket: first)
    check("culling cancels the in-flight task", store.cancel(key) && stranded.isCancelled)
    check("a culled key leaves nothing in flight", store.inFlightTaskCount() == 0)
    check("culling an unknown key is a no-op", !store.cancel("19/9/9"))
    check("culling does not draw or discard imagery", store.image(for: key) == nil)

    // A culled tile is not stale, just unfinished: it may be claimed again,
    // and the new claim must survive the old task's late arrival.
    let second = store.beginLoad(key)
    guard let second else { check("a culled tile can be claimed again", false); return }
    check("a re-claim is a distinct claim", second.id != first.id)
    check("a cancelled task's late result is dropped",
          store.finishLoad(key, image: onePixelImage(), ticket: first) == .dropped)
    check("a late result does not retire the fresh claim", store.beginLoad(key) == nil)
    check("a late result does not draw over the fresh claim", store.image(for: key) == nil)
    check("the fresh claim still completes normally",
          store.finishLoad(key, image: onePixelImage(), ticket: second) == .drawn)
    check("the fresh claim's image is the one drawn", store.image(for: key) != nil)

    // Culling can land between `beginLoad` and `recordTask`, with no task yet
    // to cancel. The claim is dead either way, so the task must be cancelled
    // when it does arrive rather than left running off-screen.
    let racing = TileImageStore()
    let racedKey = "19/6/6"
    guard let racedTicket = racing.beginLoad(racedKey) else {
        check("a fresh key can be claimed (race store)", false); return
    }
    _ = racing.cancel(racedKey)
    let late = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
    racing.recordTask(late, for: racedKey, ticket: racedTicket)
    check("a task registered after its claim was culled is cancelled", late.isCancelled)
    check("a culled claim registers nothing", racing.inFlightTaskCount() == 0)

    // The geometry: which keys a viewport rect actually strands. The margin is
    // a whole viewport on every side, so a tile just past the edge -- where a
    // gesture reversal would bring it straight back -- is deliberately kept.
    let z = 19, bx = 140_000, by = 206_000
    let visible = TerrainTileOverlay.mapRect(
        for: MKTileOverlayPath(x: bx, y: by, z: z, contentScaleFactor: 2))
    let near = "\(z)/\(bx + 1)/\(by)"
    let far = "\(z)/\(bx + 50)/\(by)"
    let stray = "not-a-key"
    let outside = TerrainTileOverlayRenderer.keysOutside(
        visible, from: ["\(z)/\(bx)/\(by)", near, far, stray])
    check("a tile far outside the viewport is culled", outside.contains(far))
    check("the viewport's own tile is kept", !outside.contains("\(z)/\(bx)/\(by)"))
    check("a tile just past the edge is kept (margin absorbs overshoot)", !outside.contains(near))
    check("an unparseable key is kept rather than guessed at", !outside.contains(stray))
}

/// B12: a shading change must not blank the terrain.
///
/// Every azimuth step (a slider scrub, or an Apple Pencil Pro barrel roll while hovering) ends in
/// `reloadData()`. When that emptied the store, `canDraw` answered false for every rect until its
/// re-shaded tile landed, so MapKit drew nothing there: continuous input strobed the whole layer. A
/// tile on screen must keep drawing its old shading until the new one replaces it.
@MainActor
func checkReloadKeepsTilesOnScreen() async {
    print("\n--- B12. a shading change keeps on-screen tiles until their replacements land ---")
    let store = TileImageStore()
    let onScreen = "19/5/5", offScreen = "19/90/90", loading = "19/5/6"
    for key in [onScreen, offScreen] {
        if let ticket = store.beginLoad(key) { _ = store.finishLoad(key, image: onePixelImage(), ticket: ticket) }
    }
    guard let oldTicket = store.beginLoad(loading) else { check("a fresh key can be claimed", false); return }
    let oldTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
    store.recordTask(oldTask, for: loading, ticket: oldTicket)
    let oldImage = store.image(for: onScreen)

    store.invalidate(retaining: [onScreen, loading])
    check("an on-screen tile keeps its image through a reload", store.image(for: onScreen) === oldImage)
    check("an off-screen tile's image is released by a reload", store.image(for: offScreen) == nil)
    check("a reload still cancels loads under the old settings", oldTask.isCancelled)
    let path = TerrainTileOverlayRenderer.path(forKey: onScreen)!
    let (ready, missing) = store.partition([path], key: TerrainTileOverlayRenderer.key)
    check("a kept tile counts as drawable, so MapKit keeps showing it", ready)
    check("a kept tile is requested again under the new settings", missing.count == 1)
    check("an old-settings result is dropped, not drawn over the kept tile",
          store.finishLoad(loading, image: onePixelImage(), ticket: oldTicket) == .dropped)
    guard let fresh = store.beginLoad(onScreen) else { check("a kept tile can be claimed again", false); return }
    let replacement = onePixelImage()
    check("the re-shaded tile lands as current",
          store.finishLoad(onScreen, image: replacement, ticket: fresh) == .drawn)
    check("the re-shaded tile replaces the kept one", store.image(for: onScreen) === replacement)
    check("once replaced the tile is not requested again", store.beginLoad(onScreen) == nil)
    store.invalidate()
    check("a plain invalidate still drops every image", store.imageKeys().isEmpty)

    // The same through the real renderer: draw one tile, reload, and ask MapKit's question again.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    let renderer = TerrainTileOverlayRenderer(tileOverlay: TerrainTileOverlay(provider: scene.provider))
    let tileRect = TerrainTileOverlay.mapRect(
        for: MKTileOverlayPath(x: scene.x, y: scene.y, z: scene.z, contentScaleFactor: 1))
    // 0.5 screen points per map point is the z19 grid for 256-point tiles.
    let zoomScale: MKZoomScale = 0.5
    renderer.cullTiles(outsideVisible: tileRect)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !renderer.canDraw(tileRect, zoomScale: zoomScale) {
        try? await Task.sleep(for: .milliseconds(10))
    }
    check("the renderer draws the tile once it has loaded", renderer.canDraw(tileRect, zoomScale: zoomScale))
    renderer.reloadData()
    check("after a shading reload the renderer can still draw the on-screen tile at once",
          renderer.canDraw(tileRect, zoomScale: zoomScale))
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
        for style in ReliefStyle.allCases where style.microTopographyProduct != nil {
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

/// A little-endian classic TIFF's directory, read straight from the file's bytes rather than through the
/// writer's own constants: each tag's (type, count, offset of its 4-byte value field). SHORT and LONG
/// values sit inline in that field; DOUBLE arrays are an offset away.
struct TIFFDirectory {
    let bytes: [UInt8]
    let entries: [Int: (type: Int, count: Int, field: Int)]

    init?(_ data: Data) {
        let b = [UInt8](data)
        func w16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func w32(_ o: Int) -> Int { w16(o) | w16(o + 2) << 16 }
        guard b.count > 10, b[0] == 0x49, b[1] == 0x49, w16(2) == 42 else { return nil }
        let ifd = w32(4)
        guard ifd + 2 <= b.count, ifd + 2 + w16(ifd) * 12 <= b.count else { return nil }
        var found: [Int: (type: Int, count: Int, field: Int)] = [:]
        for i in 0..<w16(ifd) {
            let e = ifd + 2 + i * 12
            found[w16(e)] = (w16(e + 2), w32(e + 4), e + 8)
        }
        bytes = b
        entries = found
    }

    private func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    /// An inline SHORT or LONG value.
    func value(_ tag: Int) -> Int? {
        guard let e = entries[tag] else { return nil }
        return e.type == 3 ? u16(e.field) : (e.type == 4 ? u32(e.field) : nil)
    }

    /// The four inline bytes of a short ASCII value.
    func inlineBytes(_ tag: Int) -> [UInt8]? {
        guard let e = entries[tag], e.type == 2, e.count <= 4 else { return nil }
        return Array(bytes[e.field..<(e.field + 4)])
    }

    /// The DOUBLE array a tag's offset points at.
    func doubles(_ tag: Int) -> [Double] {
        guard let e = entries[tag], e.type == 12 else { return [] }
        let start = u32(e.field)
        guard start + e.count * 8 <= bytes.count else { return [] }
        return (0..<e.count).map { i in
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(bytes[start + i * 8 + k]) << UInt64(8 * k) }
            return Double(bitPattern: bits)
        }
    }
}

@MainActor
func checkAnalyticalRaster() async {
    print("\n--- C8. analytical raster for GeoTIFF export ---")
    guard await MetalTerrainPipelineActor.shared.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    // A 2.8 m mound in the middle of the centre tile: its centre 30 m west of that tile's east edge.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let region = scene.region()
    let k = cos(38.6605 * Double.pi / 180)
    let mound = GeoRegion.fromMercatorMeters(x: scene.seamX - 30 / k, y: scene.centerY)

    // --- Local relief: shape, georeferencing and content.
    guard let lrm = await scene.provider.analyticalRaster(for: region, product: .localRelief) else {
        check("the analytical LRM covers the requested region to within a cell, at 1 m cells", false, "no raster")
        return
    }
    let cell = lrm.groundSampleDistance
    let cellLatitude = cell / GeoRegion.metersPerDegreeLatitude, cellLongitude = cell / region.metersPerDegreeLongitude
    let coversRegion = abs(lrm.region.minLatitude - region.minLatitude) <= cellLatitude
        && abs(lrm.region.maxLatitude - region.maxLatitude) <= cellLatitude
        && abs(lrm.region.minLongitude - region.minLongitude) <= cellLongitude
        && abs(lrm.region.maxLongitude - region.maxLongitude) <= cellLongitude
    // The mosaic's cell is exactly 1 m here, so a node-registered grid reports 1 m to within GeoRegion's
    // degree length (0.17%). Registering by the window's outer bounds instead would read n/(n-1) larger
    // (about 1.7% at 60 columns) and put cells up to half a cell off, growing from the window's centre.
    check("the analytical LRM covers the requested region to within a cell, at the mosaic's 1 m cell",
          coversRegion && abs(cell - 1.0) < 0.005, "\(lrm.width)x\(lrm.height) at \(cell) m: \(lrm.region) for \(region)")

    let finite = lrm.samples.filter(\.isFinite)
    let peak = finite.max() ?? .nan
    let corners = [lrm[0, 0], lrm[lrm.width - 1, 0], lrm[0, lrm.height - 1], lrm[lrm.width - 1, lrm.height - 1]]
    check("the analytical LRM is finite, peaks at mound height and reads level on open ground",
          finite.count == lrm.samples.count && (1.0...2.9).contains(peak) && corners.allSatisfy { abs($0) < 0.3 },
          "\(finite.count)/\(lrm.samples.count) finite, peak \(peak), corners \(corners)")

    // A flat-topped mound's relief is strongest on the rim of its plateau, so the peak cell is not the
    // mound's centre; the centroid of the positive residual is, however the rim falls.
    var mass = 0.0, sumX = 0.0, sumY = 0.0
    for y in 0..<lrm.height {
        for x in 0..<lrm.width where lrm[x, y] > 0.3 {
            let v = Double(lrm[x, y])
            mass += v
            sumX += v * Double(x)
            sumY += v * Double(y)
        }
    }
    let fx = mass > 0 ? sumX / mass / Double(lrm.width - 1) : .nan
    let fy = mass > 0 ? sumY / mass / Double(lrm.height - 1) : .nan
    let north = (lrm.region.maxLatitude - fy * lrm.region.latitudeSpan - mound.latitude) * GeoRegion.metersPerDegreeLatitude
    let east = (lrm.region.minLongitude + fx * lrm.region.longitudeSpan - mound.longitude) * region.metersPerDegreeLongitude
    let off = (north * north + east * east).squareRoot()
    print(String(format: "        LRM relief centroid %.3f m from the mound (%.2f m cells)", off, cell))
    check("the LRM's relief centres on the mound's true position, within a quarter cell",
          off < 0.25, String(format: "%.3f m off", off))

    // --- Sky-view factor: a different product through the same bridge.
    let svf = await scene.provider.analyticalRaster(for: region, product: .skyView)
    let svfFinite = svf?.samples.filter(\.isFinite) ?? []
    let svfLow = svfFinite.min() ?? .nan, svfHigh = svfFinite.max() ?? .nan
    check("the analytical sky-view factor is a 0...1 fraction that dips beside the mound and reads open on flat ground",
          !svfFinite.isEmpty && svfFinite.count == svf?.samples.count && svfLow >= 0 && svfHigh <= 1.0001
            && svfLow < 0.99 && svfHigh > 0.99,
          "\(svfFinite.count) finite, range \(svfLow)...\(svfHigh)")

    // --- Export through the existing writer and read the file back.
    try? FileManager.default.createDirectory(at: scene.directory, withIntermediateDirectories: true)
    let tiff = scene.directory.appendingPathComponent("lrm.tif")
    var wrote = true
    do { try GeoTIFFWriter.shared.export(grid: lrm, to: tiff) } catch { wrote = false }
    let file = (try? Data(contentsOf: tiff)).flatMap { TIFFDirectory($0) }
    let expectedColumns = Int(region.widthMeters.rounded())
    check("the LRM exports as a 32-bit float GeoTIFF of the grid's size, about one column per metre, nodata NaN",
          wrote && file?.value(258) == 32 && file?.value(339) == 3
            && file?.value(256) == lrm.width && file?.value(257) == lrm.height
            && file?.inlineBytes(42113) == [0x6E, 0x61, 0x6E, 0x00] && abs(lrm.width - expectedColumns) <= 3,
          "wrote \(wrote), \(String(describing: file?.value(256)))x\(String(describing: file?.value(257))), "
            + "bits \(String(describing: file?.value(258))), format \(String(describing: file?.value(339))), expected ~\(expectedColumns) columns")
    let tiepoint = file?.doubles(33922) ?? [], pixelScale = file?.doubles(33550) ?? []
    let written = lrm.region.mercatorBounds, requested = region.mercatorBounds
    check("the GeoTIFF tiepoint and pixel scale place the raster on the requested region",
          tiepoint.count == 6 && tiepoint[3] == written.minX && tiepoint[4] == written.maxY
            && abs(tiepoint[3] - requested.minX) <= cell / k && abs(tiepoint[4] - requested.maxY) <= cell / k
            && pixelScale.count == 3 && (0.9...1.5).contains(pixelScale[0] * k) && (0.9...1.5).contains(pixelScale[1] * k),
          "tiepoint \(tiepoint), scale \(pixelScale)")

    // --- Every product that runs without extra input comes back at the LRM's size, with real values.
    var oddOnes: [String] = []
    for product in MicroTopographyProduct.allCases where product != .relativeElevation {
        let grid = await scene.provider.analyticalRaster(for: region, product: product)
        let sameSize = grid.map { $0.width == lrm.width && $0.height == lrm.height && abs($0.width - expectedColumns) <= 3 } ?? false
        if !sameSize || !(grid?.samples.contains(where: \.isFinite) ?? false) { oddOnes.append(product.rawValue) }
    }
    check("every product but the relative elevation model exports at the LRM's size with real values",
          oddOnes.isEmpty, "\(oddOnes)")

    // --- destinationSize caps the raster by coarsening the cell.
    let coarse = await scene.provider.analyticalRaster(for: region, product: .localRelief, destinationSize: 32)
    check("a small destinationSize coarsens the cells instead of exceeding it",
          coarse.map { $0.width <= 34 && $0.height <= 34 && (1.7...2.5).contains($0.groundSampleDistance) } ?? false,
          "\(coarse.map { "\($0.width)x\($0.height) at \($0.groundSampleDistance) m" } ?? "no raster")")

    // --- Nothing to export: no raster, and no trap.
    let cold = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: cold.directory) }
    let nothingCached = await cold.provider.analyticalRaster(for: cold.region(), product: .localRelief)
    check("with no cached tile covering the region there is nothing to export", nothingCached == nil)
    let notANumber = GeoRegion(minLatitude: .nan, maxLatitude: region.maxLatitude,
                               minLongitude: region.minLongitude, maxLongitude: region.maxLongitude)
    let unbounded = GeoRegion(minLatitude: region.minLatitude, maxLatitude: .infinity,
                              minLongitude: region.minLongitude, maxLongitude: region.maxLongitude)
    let nanRaster = await scene.provider.analyticalRaster(for: notANumber, product: .localRelief)
    let infiniteRaster = await scene.provider.analyticalRaster(for: unbounded, product: .localRelief)
    check("a region with a NaN or infinite bound yields no raster instead of trapping",
          nanRaster == nil && infiniteRaster == nil)
    let noThalweg = await scene.provider.analyticalRaster(for: region, product: .relativeElevation)
    check("a relative elevation model needs a river thalweg, which this call cannot supply, so it yields no raster",
          noThalweg == nil)
}

@MainActor
func checkMemoryPressure() async {
    print("\n--- C9. memory pressure ---")

    // The renderer's side: of the tiles it has drawn or is loading, which touch the visible rect.
    // A coarser tile over the same ground counts (it is still on screen mid-zoom); a far one does not.
    let z = 19, bx = 140_000, by = 206_000
    func farKey(_ dx: Int) -> String { "\(z)/\(bx + dx)/\(by)" }
    let visibleRect = TerrainTileOverlay.mapRect(for: MKTileOverlayPath(x: bx, y: by, z: z, contentScaleFactor: 2))
        .union(TerrainTileOverlay.mapRect(for: MKTileOverlayPath(x: bx + 1, y: by, z: z, contentScaleFactor: 2)))
    let coarserKey = "\(z - 1)/\(bx / 2)/\(by / 2)"
    let onScreen = TerrainTileOverlayRenderer.keysInside(
        visibleRect, from: [farKey(0), farKey(1), farKey(3), farKey(50), coarserKey, "not-a-key"])
    check("only tiles touching the visible rect count as visible, at any zoom",
          Set(onScreen) == [farKey(0), farKey(1), coarserKey], "\(onScreen)")

    guard await MetalTerrainPipelineActor.shared.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    // The same ground one zoom out and one zoom in, on the same provider.
    for zoom in [scene.z - 1, scene.z + 1] {
        let n = pow(2.0, Double(zoom))
        let x = Int((-90.0621 + 180) / 360 * n), y = Int((1 - asinh(tan(38.6605 * Double.pi / 180)) / .pi) / 2 * n)
        _ = await scene.provider.tileImage(
            x: x, y: y, z: zoom,
            region: TerrainTileOverlay.region(for: MKTileOverlayPath(x: x, y: y, z: zoom, contentScaleFactor: 2)), pixels: 512)
    }
    _ = await scene.provider.viewshed(at: scene.region().center, maxRadiusMeters: 100)
    func key(_ dx: Int) -> String { "\(scene.z)/\(scene.x + dx)/\(scene.y)" }
    let visible: Set<String> = [key(0), key(1)]

    let shaded = await scene.provider.renderedTileKeys()
    let cachedBefore = await scene.provider.cachedTileKeys()
    let bytesBefore = await scene.provider.memoryCacheSize()
    let idleBefore = await MetalTerrainPipelineActor.shared.poolStatistics().idleBytes
    let mosaicBefore = await scene.provider.holdsViewshedMosaic()
    let centerBefore = await scene.image().flatMap(rgbaBytes)
    let westBefore = await scene.image(dx: -1).flatMap(rgbaBytes)

    await scene.provider.handleMemoryPressure(visibleKeys: visible)

    let rendered = await scene.provider.renderedTileKeys()
    check("under pressure only the visible tiles keep their shaded bitmaps, whatever the zoom",
          shaded.count == 11 && rendered == visible, "\(shaded.count) shaded before, after: \(rendered.sorted())")
    let cached = await scene.provider.cachedTileKeys()
    check("the tile cache is halved but never loses a visible tile",
          cachedBefore.count > 5 && cached.count == cachedBefore.count / 2 && visible.isSubset(of: cached),
          "\(cachedBefore.count) cached before, \(cached.count) after")
    let bytesAfter = await scene.provider.memoryCacheSize()
    check("the pruned bitmaps' memory is released", bytesBefore - bytesAfter >= 9 * 1_000_000,
          "\(bytesBefore) -> \(bytesAfter) bytes")
    let mosaicAfter = await scene.provider.holdsViewshedMosaic()
    check("the cached viewshed mosaic is released", mosaicBefore && !mosaicAfter)
    let idleAfter = await MetalTerrainPipelineActor.shared.poolStatistics().idleBytes
    check("idle GPU pool memory is given back, after the bitmaps holding buffers were released",
          idleBefore > 0 && idleAfter == 0, "\(idleBefore) -> \(idleAfter) idle bytes")

    // Visible tiles stay served; a pruned tile is rebuilt on demand and is pixel-identical.
    let centerAfter = await scene.image().flatMap(rgbaBytes)
    let westAfter = await scene.image(dx: -1).flatMap(rgbaBytes)
    let reRendered = await scene.provider.renderedTileKeys()
    check("visible tiles are still served, and a pruned tile re-renders to identical pixels after the pool purge",
          centerBefore != nil && centerAfter == centerBefore && !rendered.contains(key(-1))
            && reRendered.contains(key(-1)) && westAfter != nil && westAfter == westBefore)

    // The system warning trims to whatever the renderer says is on screen, and to nothing if it says nothing.
    await scene.loadNeighbourhood()
    await scene.provider.setVisibleKeysSource { visible }
    await scene.provider.handleMemoryWarning()
    let afterWarning = await scene.provider.renderedTileKeys()
    await scene.provider.setVisibleKeysSource(nil)
    await scene.loadNeighbourhood()
    await scene.provider.handleMemoryWarning()
    let afterBlindWarning = await scene.provider.renderedTileKeys()
    check("a memory warning trims to the registered visible tiles, and to none when no source is registered",
          afterWarning == visible && afterBlindWarning.isEmpty,
          "with a source: \(afterWarning.sorted()); without: \(afterBlindWarning.sorted())")
}

@MainActor
func checkActiveGridRegistration() async {
    print("\n--- C10. elevation export registration ---")
    // The centre tile of a synthetic scene, neighbours cached: about 60 m across, which the mosaic builder
    // rasterises at its 1 m floor cell.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let tile = scene.region()
    let viewport = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: tile.latitudeSpan, longitudeDelta: tile.longitudeSpan))
    guard let grid = await scene.provider.activeGrid(covering: viewport) else {
        check("the elevation export is node-registered: 1 m cells and a region inset half a cell from the mosaic's edge",
              false, "no grid")
        return
    }

    // ElevationGrid and GeoTIFFWriter are node-registered: the first and last samples sit ON the region's
    // edges. The mosaic's cells are centred and it is centred on the viewport, so its samples span n - 1
    // cells: each edge of the region is (n - 1) / 2 cells from the viewport's centre, half a cell inside the
    // mosaic's outer edge at n / 2. Labelling the grid with that outer edge instead scales every cell by
    // n / (n - 1) and moves samples up to half a cell, growing from the centre out to the perimeter.
    let cell = grid.groundSampleDistance
    let center = tile.center
    let west = (center.longitude - grid.region.minLongitude) * tile.metersPerDegreeLongitude
    let east = (grid.region.maxLongitude - center.longitude) * tile.metersPerDegreeLongitude
    let south = (center.latitude - grid.region.minLatitude) * GeoRegion.metersPerDegreeLatitude
    let north = (grid.region.maxLatitude - center.latitude) * GeoRegion.metersPerDegreeLatitude
    let halfWidth = Double(grid.width - 1) / 2, halfHeight = Double(grid.height - 1) / 2
    let atCellCentres = abs(west - halfWidth) < 0.15 && abs(east - halfWidth) < 0.15
        && abs(south - halfHeight) < 0.15 && abs(north - halfHeight) < 0.15
    check("the elevation export is node-registered: 1 m cells and a region inset half a cell from the mosaic's edge",
          abs(cell - 1.0) < 0.005 && atCellCentres,
          String(format: "%dx%d, cell %.4f m; edges from the centre W %.2f E %.2f S %.2f N %.2f m, expected %.1f by %.1f",
                 grid.width, grid.height, cell, west, east, south, north, halfWidth, halfHeight))

    // A viewport that is not finite, or whose metres overflow, cannot be rasterised. With a finite latitude and an
    // infinite longitude span the radius is infinite, which the mosaic builder's Int conversion would trap on.
    let infinite = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: tile.latitudeSpan, longitudeDelta: .infinity))
    let overflowing = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: tile.latitudeSpan, longitudeDelta: 1e305))
    let notANumber = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: .nan, longitude: tile.center.longitude), span: viewport.span)
    var unwanted: [String] = []
    if await scene.provider.activeGrid(covering: infinite) != nil { unwanted.append("infinite span") }
    if await scene.provider.activeGrid(covering: overflowing) != nil { unwanted.append("overflowing span") }
    if await scene.provider.activeGrid(covering: notANumber) != nil { unwanted.append("NaN centre") }
    check("a viewport that is not finite, or whose metres overflow, yields no grid instead of trapping",
          unwanted.isEmpty, "grids returned for: \(unwanted)")
}


