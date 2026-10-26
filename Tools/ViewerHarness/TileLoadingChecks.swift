//
//  TileLoadingChecks.swift
//  ViewerHarness
//
//  The tile-loading pipeline's responsiveness (the 2026-10-26 reviews): one fetch per header and per tile under a
//  burst, CPU work kept off the hub actors, the disk cache's I/O off its actor, fetched rasters held page-aligned, the
//  stale-neighbour settle window, and the prompt Terrarium answer with a native upgrade behind it.
//

import CoreLocation
import Foundation
import MapKit
import os

// MARK: - A COG service in memory

/// Serves one in-memory COG to range requests (as a web server would: a range past the end is clamped, one starting
/// past it is empty) and one product listing to The National Map's host, and counts the range requests. The
/// counters are locked because the coordinator fetches tiles concurrently.
nonisolated final class COGServiceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var file: [UInt8] = []
    nonisolated(unsafe) private static var products = Data()
    nonisolated(unsafe) private static var ranges = 0

    static func reset(file: [UInt8], productsJSON: Data = Data()) {
        lock.withLock { self.file = file; products = productsJSON; ranges = 0 }
    }
    static func setProducts(_ json: Data) { lock.withLock { products = json } }
    static var rangeRequests: Int { lock.withLock { ranges } }

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        guard let url = request.url else { return }
        if url.host() == "tnmaccess.nationalmap.gov" {
            respond(Self.lock.withLock { Self.products }, status: 200)
            return
        }
        let file = Self.lock.withLock { () -> [UInt8] in Self.ranges += 1; return Self.file }
        var lower = 0, upper = file.count
        if let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") {
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                lower = a
                upper = min(b + 1, file.count)
            }
        }
        respond(lower < upper ? Data(file[lower..<upper]) : Data(), status: 206)
    }
    override nonisolated func stopLoading() {}

    private func respond(_ body: Data, status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A transport over ``COGServiceURLProtocol``.
func cogTransport() -> HTTPTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [COGServiceURLProtocol.self]
    return HTTPTransport(session: URLSession(configuration: config))
}

nonisolated let fixtureCOGURL = URL(string: "https://cog.test/fixture.tif")!

/// A one-band Float32 COG in UTM 15N at 1 m, `tilesAcross` x `tilesDown` tiles of `side` px, each tile flat at
/// `100 + 10 * index`. `voidsInTile` puts the nodata sentinel, an infinity and a NaN in that tile's first three samples.
func tiledCOG(tilesAcross: Int, tilesDown: Int, side: Int, voidsInTile: Int? = nil) -> [UInt8] {
    let entries: [TIFFFixture.Entry] = [
        .long(256, [tilesAcross * side]), .long(257, [tilesDown * side]),
        .short(258, [32]), .short(259, [1]), .short(262, [1]), .short(277, [1]),
        .short(284, [1]), .long(322, [side]), .long(323, [side]), .short(339, [3]),
        .double(33550, [1, 1, 0]),
        .double(33922, [0, 0, 0, 500_000, 4_280_000, 0]),
        .short(34735, [1, 1, 0, 1, 3072, 0, 1, 32615]),
        .ascii(42113, "-32767"),
    ]
    var tiles: [[UInt8]] = []
    for index in 0..<(tilesAcross * tilesDown) {
        var samples = [Float](repeating: Float(100 + index * 10), count: side * side)
        if index == voidsInTile {
            samples[0] = -32767
            samples[1] = .infinity
            samples[2] = .nan
        }
        tiles.append(TIFFFixture.tile(samples))
    }
    return TIFFFixture.build([TIFFFixture.IFD(entries: entries, tiles: tiles)])
}

/// A National Map product listing of one product, `url`, whose bounds hold `region` with a margin.
nonisolated func productsJSON(url: URL, around region: GeoRegion) -> Data {
    let json = """
    {"items":[{"title":"fixture","downloadURL":"\(url.absoluteString)","publicationDate":"2024-01-01",\
    "boundingBox":{"minX":\(region.minLongitude - 0.01),"maxX":\(region.maxLongitude + 0.01),\
    "minY":\(region.minLatitude - 0.01),"maxY":\(region.maxLatitude + 0.01)}}]}
    """
    return Data(json.utf8)
}

/// The tile over Cahokia at `z`, as `makeSyntheticScene` places it.
nonisolated func cahokiaTile(z: Int) -> (x: Int, y: Int, region: GeoRegion) {
    let latitude = 38.6605, longitude = -90.0621
    let n = pow(2.0, Double(z))
    let x = Int((longitude + 180) / 360 * n)
    let y = Int((1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n)
    return (x, y, TerrainTileOverlay.region(for: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2)))
}

/// Fails every request after 100 ms, counting them: the 3DEP ImageServer on a bad day.
nonisolated final class DelayedFailureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override nonisolated func stopLoading() {}
}

/// Answers after `delay`: a native source slower than the prompt-answer budget.
nonisolated struct DelayedTerrainStub: ElevationProviding {
    let base: SyntheticTerrainStub
    let delay: Duration

    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        try? await Task.sleep(for: delay)
        return await base.elevation(for: region, targetSamples: targetSamples)
    }
}

/// Polls `condition` every 10 ms until it holds or `seconds` pass; returns whether it held.
private func eventually(_ seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// T1. Before: concurrent `header()` calls on a reader whose header was not yet cached each ran `loadHeader()`, one or two
/// range GETs apiece (two for a 1 m COG, whose tile tables do not fit the first 16 KB), queued ahead of the tile ranges.
@MainActor
private func checkCOGHeaderSingleFlight() async {
    print("\n--- T1. one header fetch per COG, however many tiles ask at once ---")
    let file = tiledCOG(tilesAcross: 2, tilesDown: 1, side: 8)
    COGServiceURLProtocol.reset(file: file)
    let alone = COGByteReader(url: fixtureCOGURL, transport: cogTransport())
    let header = try? await alone.header()
    let requestsForOne = COGServiceURLProtocol.rangeRequests
    check("setup: the fixture's header parses", header != nil && requestsForOne > 0, "\(requestsForOne) requests")

    COGServiceURLProtocol.reset(file: file)
    let shared = COGByteReader(url: fixtureCOGURL, transport: cogTransport())
    let parsed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<8 { group.addTask { (try? await shared.header()) != nil } }
        var count = 0
        for await ok in group where ok { count += 1 }
        return count
    }
    check("eight concurrent header() calls on a fresh reader all parse", parsed == 8, "\(parsed)")
    check("and issue the range GETs of one call, not eight",
          COGServiceURLProtocol.rangeRequests == requestsForOne,
          "\(COGServiceURLProtocol.rangeRequests) vs \(requestsForOne)")
}

/// T2. `tile()` checked `inFlightTiles` and then awaited the georeference; every caller for the same tile passed the
/// check during that await and started its own fetch and decode. `georeference()` had the same gap around its header
/// fetch. (After Task 2 the header check passes already, since the reader shares the load; `tileFetches == 1` is the
/// red one.)
@MainActor
private func checkCoordinatorSingleFlight() async {
    print("\n--- T2. one georeference and one fetch per COG tile under a concurrent burst ---")
    let file = tiledCOG(tilesAcross: 2, tilesDown: 2, side: 8)

    COGServiceURLProtocol.reset(file: file)
    let alone = ElevationTileCoordinator(transport: cogTransport())
    check("setup: the fixture georeferences", await alone.georeference(for: fixtureCOGURL) != nil)
    let headerRequestsForOne = COGServiceURLProtocol.rangeRequests

    COGServiceURLProtocol.reset(file: file)
    let coordinator = ElevationTileCoordinator(transport: cogTransport())
    let resolved = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<8 { group.addTask { await coordinator.georeference(for: fixtureCOGURL) != nil } }
        var n = 0
        for await ok in group where ok { n += 1 }
        return n
    }
    check("eight concurrent georeference() calls resolve", resolved == 8, "\(resolved)")
    check("and fetch the header once", COGServiceURLProtocol.rangeRequests == headerRequestsForOne,
          "\(COGServiceURLProtocol.rangeRequests) vs \(headerRequestsForOne)")

    COGServiceURLProtocol.reset(file: file)
    let fresh = ElevationTileCoordinator(transport: cogTransport())
    let answered = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<8 { group.addTask { await fresh.tile(product: fixtureCOGURL, column: 1, row: 1) != nil } }
        var n = 0
        for await ok in group where ok { n += 1 }
        return n
    }
    let stats = await fresh.statistics()
    check("eight concurrent tile() calls for one tile all answer", answered == 8, "\(answered)")
    check("from one fetch: the single-flight holds across the georeference await", stats.tileFetches == 1, "\(stats.tileFetches)")
    check("and one range GET for the tile beyond the header's",
          COGServiceURLProtocol.rangeRequests == headerRequestsForOne + 1,
          "\(COGServiceURLProtocol.rangeRequests) vs \(headerRequestsForOne + 1)")
}

/// T3. A COG tile's LZW decode, predictor and byte swap run off the reader actor, with the file's nodata sentinel and
/// anything that is no elevation rewritten to NaN in the same pass, so the coordinator no longer pays a GPU round trip
/// per tile to do that. This pins the result; the move off the actor is structural.
@MainActor
private func checkCOGTileDecodeAndNoData() async {
    print("\n--- T3. a COG tile decodes off the reader actor with its voids already NaN ---")
    COGServiceURLProtocol.reset(file: tiledCOG(tilesAcross: 2, tilesDown: 1, side: 8, voidsInTile: 1))
    let coordinator = ElevationTileCoordinator(transport: cogTransport())
    guard let tile = await coordinator.tile(product: fixtureCOGURL, column: 1, row: 0) else {
        check("the voided tile streams", false)
        return
    }
    let floats = tile.storage.pointer.assumingMemoryBound(to: Float.self)
    check("the sentinel, an infinity and a NaN read as voids", floats[0].isNaN && floats[1].isNaN && floats[2].isNaN,
          "\(floats[0]) \(floats[1]) \(floats[2])")
    check("the tile's other samples are its elevation", floats[3] == 110 && floats[63] == 110, "\(floats[3]) \(floats[63])")
    check("the tile is 8 x 8 at 1 m", tile.width == 8 && tile.height == 8 && tile.cellSizeX == 1)
    let stats = await coordinator.statistics()
    check("one fetch", stats.tileFetches == 1, "\(stats.tileFetches)")
}

/// T4. The bilinear resample of a map tile (70K cells, four reads each) ran on the coordinator actor, serialising
/// every tile of a burst behind it. It runs detached now; this pins what it produces over a real product listing.
@MainActor
private func checkResampleOffActor() async {
    print("\n--- T4. a map tile's raster resamples off the coordinator actor ---")
    let file = tiledCOG(tilesAcross: 4, tilesDown: 4, side: 32)
    COGServiceURLProtocol.reset(file: file)
    let coordinator = ElevationTileCoordinator(transport: cogTransport())
    guard let geo = await coordinator.georeference(for: fixtureCOGURL) else {
        check("setup: the fixture georeferences", false)
        return
    }
    let centre = geo.coordinate(forPixel: SIMD2(64, 64))
    let region = GeoRegion(
        center: centre, latitudeSpan: 40 / GeoRegion.metersPerDegreeLatitude,
        longitudeSpan: 40 / (GeoRegion.metersPerDegreeLatitude * cos(centre.latitude * .pi / 180)))
    COGServiceURLProtocol.setProducts(productsJSON(url: fixtureCOGURL, around: region))
    guard let streamed = await coordinator.elevationRaster(for: region, width: 32, height: 32) else {
        check("the raster streams", false)
        return
    }
    check("the footprint is covered", streamed.validFraction > 0.99, "\(streamed.validFraction)")
    let stats = streamed.grid.statistics()
    check("its values are the fixture's four central tiles (flat 150, 160, 190, 200) and their blends",
          stats.minimum == 150 && stats.maximum == 200, "\(stats.minimum)...\(stats.maximum)")
    check("it is the fixture product", streamed.product.title == "fixture")
}

/// T5. `TerrariumTileService` is an actor whose only state is its session, yet it decoded each PNG inside its
/// isolation, so the 8 tiles the session fetches at once decoded one at a time. The decode is detached now.
/// This pins the result; the move off the actor is structural.
@MainActor
private func checkTerrariumDecodeOffActor() async {
    print("\n--- T5. Terrarium tiles decode off the service actor ---")
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 250))
    let service = TerrariumTileService(session: HarvestNetworkProtocol.session)
    let (x, y, region) = cahokiaTile(z: 14)
    let decoded = await withTaskGroup(of: Float?.self, returning: [Float].self) { group in
        for i in 0..<8 {
            group.addTask {
                // One region for all eight: only `samples` is read, so the mismatch for x + i does not matter.
                let samples = await service.elevation(x: x + i, y: y, z: 14, region: region).value?.samples
                return samples.flatMap { $0.indices.contains(1000) ? $0[1000] : nil }
            }
        }
        var out: [Float] = []
        for await v in group { if let v { out.append(v) } }
        return out
    }
    check("eight concurrent tiles decode to the encoded elevation", decoded.count == 8 && decoded.allSatisfy { $0 == 250 }, "\(decoded)")
    HarvestNetworkProtocol.set(serving: nil)
}

/// T6. `USGS3DEPService` had no in-flight map: the read-back, the harvester and the fallback chain could each start a
/// 10-18 s `exportImage` for the same key, and each failure counted against the circuit breaker. The transport retries
/// once, so one logical call is at most two requests.
@MainActor
private func check3DEPRequestsCoalesce() async {
    print("\n--- T6. concurrent requests for one 3DEP extent share a fetch ---")
    DelayedFailureURLProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DelayedFailureURLProtocol.self]
    let service = USGS3DEPService(transport: HTTPTransport(session: URLSession(configuration: config)))
    let region = GeoRegion(center: CLLocationCoordinate2D(latitude: 37.0, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 { group.addTask { _ = await service.elevation(for: region, targetSamples: 64) } }
    }
    check("four concurrent calls for one extent issue one request and its one retry, not eight",
          DelayedFailureURLProtocol.requestCount == 2, "\(DelayedFailureURLProtocol.requestCount)")
    check("and count one failure against the circuit breaker, not four", await !service.isCooldownActive())

    // A caller cancelled while the shared fetch runs leaves it to the others; when the last one goes, the fetch is
    // cancelled too, so a culled tile's request does not hold a connection for the ImageServer's 12-25 s.
    DelayedFailureURLProtocol.reset()
    let culled = Task { await service.elevation(for: GeoRegion(center: CLLocationCoordinate2D(latitude: 37.5, longitude: -119.0), latitudeSpan: 0.005, longitudeSpan: 0.005), targetSamples: 64) }
    // 120 ms: the first request has failed at 100 ms and the transport sleeps its 0.1-0.5 s backoff, whose retry cannot
    // start before 200 ms. A cancel landing early (mid-request) also counts one request, so either way one is issued.
    try? await Task.sleep(for: .milliseconds(120))
    culled.cancel()
    let outcome = await culled.value
    check("the last waiter's cancellation cancels the shared fetch, which answers cancelled and skips the retry",
          { if case .unavailable(.transportFailure(_, let text)) = outcome { return text == "cancelled" } else { return false } }()
          && DelayedFailureURLProtocol.requestCount == 1,
          "\(outcome) after \(DelayedFailureURLProtocol.requestCount) request(s)")
    check("and the breaker is untouched by it", await !service.isCooldownActive())
}

/// T7. Every write (temp file, copy, rename) and the prune's directory walk ran on the cache actor, so each
/// `map(forKey:)` of the opening burst waited behind them. Both run detached now; the accounting stays on the actor.
/// The usage is measured before the first write, so no background measurement ever runs and every prune below is the awaited one.
@MainActor
private func checkDiskCacheWritesOffActor() async {
    print("\n--- T7. the disk cache writes and prunes off its actor, with the same accounting ---")
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-loading-cache-\(UUID().uuidString)", isDirectory: true)
    let cache = TileDiskCache(directory: directory, maxDiskBytes: 150_000, targetDiskBytes: 100_000)
    let payload = Data(repeating: 1, count: 100_000)
    check("setup: the fresh directory measures empty", await cache.measureDiskUsage() == 0)
    check("the first write lands", await cache.write(payload, forKey: "entry-0"))
    let wroteSecond = await cache.write(payload, forKey: "entry-1")
    let firstGone = !(await cache.contains(forKey: "entry-0"))
    let secondHeld = await cache.contains(forKey: "entry-1")
    check("a second write lands and prunes the oldest", wroteSecond && firstGone && secondHeld,
          "wrote \(wroteSecond), entry-0 gone \(firstGone), entry-1 held \(secondHeld)")
    let wroteThird = await cache.write(payload, forKey: "entry-2")
    let secondGone = !(await cache.contains(forKey: "entry-1"))
    let thirdHeld = await cache.contains(forKey: "entry-2")
    check("a third write lands and prunes again", wroteThird && secondGone && thirdHeld,
          "wrote \(wroteThird), entry-1 gone \(secondGone), entry-2 held \(thirdHeld)")
    check("usage is one entry", await cache.measureDiskUsage() == 100_000, "\(await cache.measureDiskUsage() ?? -1)")
    check("a mapped read of the survivor sees its bytes", (await cache.map(forKey: "entry-2"))?.fileLength == 100_000)
    try? FileManager.default.removeItem(at: directory)
}

/// T8. A z6-15 tile's padded raster (272 KB at 256 px, 1 MB at 512) was written to the 500 MB grid cache although the
/// same tile sits in the Terrarium URLCache as a ~30 KB PNG and rebuilds in a millisecond; by recency it then evicted
/// the z16+ rasters that cost 1-18 s to fetch. The harvest is unchanged: it stores every level, protected.
@MainActor
private func checkTerrariumRastersNotWrittenToDisk() async {
    print("\n--- T8. Terrarium rasters are not written to the disk tile cache; native rasters are ---")
    check("the rule: terrarium below z16 is not worth a slot",
          !TerrainTileProvider.isWorthCachingOnDisk(source: "terrarium", z: 14)
          && TerrainTileProvider.isWorthCachingOnDisk(source: TerrainTileProvider.sourceName(forZ: 18), z: 18)
          && !TerrainTileProvider.isWorthCachingOnDisk(source: "3DEP 1m (fallback to terrarium)", z: 18))
    check("the harvest's rule is untouched: terrarium may still be kept", TerrainTileProvider.isCacheableSource("terrarium"))

    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 200))
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-loading-grid-\(UUID().uuidString)", isDirectory: true)
    let cache = TileDiskCache(directory: directory)
    let provider = TerrainTileProvider(
        elevation: SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1),
        terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: cache)
    let margin = TerrainTileProvider.marginPixels
    let coarse = cahokiaTile(z: 14)
    let coarseImage = await provider.tileImage(x: coarse.x, y: coarse.y, z: 14, region: coarse.region, pixels: 512)
    check("a z14 tile draws", coarseImage != nil)
    let fine = cahokiaTile(z: 19)
    let fineImage = await provider.tileImage(x: fine.x, y: fine.y, z: 19, region: fine.region, pixels: 512)
    check("a z19 tile draws", fineImage != nil)
    let fineKey = TerrainTileProvider.gridCacheKey(x: fine.x, y: fine.y, z: 19, pixels: 512, margin: margin)
    check("the z19 raster reaches the disk", await eventually { await cache.contains(forKey: fineKey) })
    let coarseKey = TerrainTileProvider.gridCacheKey(x: coarse.x, y: coarse.y, z: 14, pixels: 512, margin: margin)
    check("the z14 raster does not", await !cache.contains(forKey: coarseKey))
    HarvestNetworkProtocol.set(serving: nil)
    try? FileManager.default.removeItem(at: directory)
}

/// T9. A tile from the network was held as `[Float]`, so every shade allocated an `MTLBuffer` and copied 1 MB into
/// it (48 tiles x 60 Hz during a sun-dial drag); a tile from disk adopted its mapping zero-copy but the budget never
/// counted that mapping. Now a tile's second shade copies its samples once into page-aligned pages the shader adopts
/// from then on, and the budget counts that copy and a disk tile's mapping alike. A tile shaded once holds one plane.
@MainActor
private func checkFetchedTilesAreHeldPageAligned() async {
    print("\n--- T9. a re-shaded tile is held in page-aligned pages the shader adopts, and the budget counts them ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    let side = 512 + 2 * TerrainTileProvider.marginPixels
    let plane = side * side * MemoryLayout<Float>.stride
    let bitmap = 512 * 512 * 4
    let first = await scene.image()
    check("setup: the tile shades", first != nil)
    let afterOne = await scene.provider.memoryCacheSize()
    check("shaded once, the entry holds one plane and its bitmap, no copy", afterOne < 2 * plane, "\(afterOne) bytes against two planes of \(plane)")
    var turned = await scene.provider.currentSettings()
    turned.azimuthDegrees += 90
    await scene.provider.update(turned)
    let second = await scene.image()
    check("setup: the tile shades again under a new sun", second != nil)
    let afterTwo = await scene.provider.memoryCacheSize()
    check("shaded twice, the entry holds its heap grid, its page-aligned copy and its bitmap",
          afterTwo >= 2 * plane + bitmap, "\(afterTwo) bytes against \(2 * plane + bitmap)")
    // Two older neighbours, then the centre asked for again (a bitmap hit, which promotes it to newest): a memory
    // warning halves the cache oldest first, so the neighbours go and the centre stays to show what it gave back.
    let east = await scene.image(dx: 1)
    let farEast = await scene.image(dx: 2)
    let promoted = await scene.image()
    check("setup: two neighbours load and the centre is promoted", east != nil && farEast != nil && promoted != nil)
    await scene.provider.handleMemoryPressure(visibleKeys: [])
    let afterPressure = await scene.provider.memoryCacheSize()
    let centreKey = "\(scene.z)/\(scene.x)/\(scene.y)"
    let centreKept = await scene.provider.cachedTileKeys().contains(centreKey)
    check("a memory warning gives the re-shade copy and the bitmap back and keeps the raster (one plane, the centre still cached)",
          centreKept && afterPressure == plane, "\(afterPressure) bytes against one plane of \(plane), centre kept \(centreKept)")
}

/// T10. The robust (2nd/98th percentile) extent was computed for every tile on the actor although only the
/// `.elevation` style and the REM's fallback surface read it; the encode/decode copies and the Terrarium crop ran there
/// too. The extent is computed on first need now and the rest runs detached. This pins the extent's answer.
@MainActor
private func checkElevationExtentOnFirstNeed() async {
    print("\n--- T10. the robust elevation extent is computed when asked for; this pins its answer ---")
    // The mound 30 m west of the east seam sits inside the centre tile: its 2.8 m flat top (radius 10 m) is ~9 % of the
    // ~60 m tile, well above the 2 % tail, so the 98th percentile is the top exactly and the 2nd the 120 m ground.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    let shaded = await scene.image()
    check("setup: the tile shades", shaded != nil)
    let range = await scene.provider.elevationRange(in: scene.region())
    check("the visible range reads the flat ground as its floor and the mound above it",
          range.map { $0.lowerBound == 120 && $0.upperBound > 120 && $0.upperBound <= 122.8 } ?? false, "\(String(describing: range))")
    let again = await scene.provider.elevationRange(in: scene.region())
    check("asked twice, the same", again == range)
}

/// T11. The renderer drained the provider's stale tiles only on a load that drew; a load dropped by a cull or failed
/// returned first, and if it was the last in flight its neighbours kept their partial-neighbourhood seam until the
/// next shading change. The provider now pushes stale tiles to a sink the renderer registers, and the pull after a
/// load runs whatever became of it.
@MainActor
private func checkStaleTilesArePushed() async {
    print("\n--- T11. stale tiles are pushed to the renderer, not only pulled after a drawn load ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 35)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    let pushed = OSAllocatedUnfairLock<[String]>(initialState: [])
    await scene.provider.setStaleTilesSink { keys in pushed.withLock { $0 += keys } }
    await scene.image()
    await scene.image(dx: 1)
    await scene.provider.settleStaleTiles()
    let centre = "\(scene.z)/\(scene.x)/\(scene.y)"
    let seen = pushed.withLock { $0 }
    check("the centre tile is pushed once its neighbour lands", seen.contains(centre), "\(seen)")
    let held = await scene.provider.takeStaleTiles()
    check("what was pushed is not also held for a pull", held.isEmpty, "\(held)")
    await scene.provider.setStaleTilesSink(nil)
}

/// T12. Each arriving tile dropped eight neighbours' bitmaps and bumped their revision at once, so during a viewport
/// load a tile was re-shaded once per neighbour arrival (up to nine times) and its renders in flight were thrown
/// away. The revision still moves at once (a render in flight read a partial neighbourhood and must not be kept), but
/// the re-shade waits for the burst to quiet: one window, one re-shade per tile. The bitmap stays drawn meanwhile.
@MainActor
private func checkStaleSettleWindow() async {
    print("\n--- T12. neighbour staleness settles once per burst, keeping the old picture meanwhile ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 35)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    await scene.provider.setStaleSettleWindow(.seconds(60))
    let centre = "\(scene.z)/\(scene.x)/\(scene.y)"
    await scene.image()
    await scene.image(dx: 1)
    let immediate = await scene.provider.takeStaleTiles()
    check("right after the neighbour lands, nothing is stale yet: the change waits on the settle window (held open here)",
          immediate.isEmpty, "\(immediate)")
    let stillDrawn = await scene.provider.renderedTileKeys()
    check("and the centre tile's bitmap is still held, so a re-request draws the old picture", stillDrawn.contains(centre))
    await scene.image(dy: 1)
    await scene.provider.settleStaleTiles()
    let stale = await scene.provider.takeStaleTiles()
    check("once settled, the centre tile is among the stale tiles", stale.contains(centre), "\(stale)")
    let afterSettle = await scene.provider.renderedTileKeys()
    check("and its bitmap has gone, so the re-request shades it again", !afterSettle.contains(centre))
    await scene.image()
    let shades = await scene.provider.shadeCount(for: centre)
    check("re-requested, the centre is shaded a second time for its two neighbours, not a third", shades == 2, "shades: \(shades)")
    let again = await scene.provider.takeStaleTiles()
    check("settling twice adds nothing", again.isEmpty)
}

/// T13. Where no COG covers a z16+ tile, the FallbackElevationProvider waited out the ImageServer (12 s x 2 attempts)
/// before anything was shown. The native fetch now races a 2 s budget; past it the Terrarium ancestor is shown and the
/// native raster upgrades the tile when it lands.
@MainActor
private func checkPromptAnswerThenUpgrade() async {
    print("\n--- T13. a slow native source is answered from Terrarium within the budget, then upgraded ---")
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 200))
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-loading-upgrade-\(UUID().uuidString)", isDirectory: true)
    let cache = TileDiskCache(directory: directory)
    let ground = SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1)   // flat 120 m
    let provider = TerrainTileProvider(
        elevation: DelayedTerrainStub(base: ground, delay: .seconds(3)),
        terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: cache)
    let pushed = OSAllocatedUnfairLock<[String]>(initialState: [])
    await provider.setStaleTilesSink { keys in pushed.withLock { $0 += keys } }
    let (x, y, region) = cahokiaTile(z: 19)
    let key = "19/\(x)/\(y)"

    let started = ContinuousClock.now
    let first = await provider.tileImage(x: x, y: y, z: 19, region: region, pixels: 512)
    let elapsed = ContinuousClock.now - started
    check("the tile is answered from Terrarium within the budget", first != nil && elapsed < .seconds(2.8), "\(elapsed)")
    check("and reads the stand-in's ground meanwhile", await provider.elevation(at: region.center).map { abs($0 - 200) < 1 } ?? false,
          "\(String(describing: await provider.elevation(at: region.center)))")

    check("when the native raster lands, the tile is pushed stale", await eventually(5) { pushed.withLock { $0 }.contains(key) })
    check("and its raster is the native one", await provider.elevation(at: region.center).map { abs($0 - 120) < 1 } ?? false,
          "\(String(describing: await provider.elevation(at: region.center)))")
    check("a re-request shades it again", await provider.tileImage(x: x, y: y, z: 19, region: region, pixels: 512) != nil)
    let gridKey = TerrainTileProvider.gridCacheKey(x: x, y: y, z: 19, pixels: 512, margin: TerrainTileProvider.marginPixels)
    check("the native raster reaches the disk; the stand-in never did", await eventually { await cache.contains(forKey: gridKey) })

    HarvestNetworkProtocol.set(serving: nil)
    await provider.setStaleTilesSink(nil)
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - The section

@MainActor
func runTileLoadingChecks() async {
    print("\n=== Tile loading responsiveness ===")
    await checkCOGHeaderSingleFlight()
    await checkCoordinatorSingleFlight()
    await checkCOGTileDecodeAndNoData()
    await checkResampleOffActor()
    await checkTerrariumDecodeOffActor()
    await check3DEPRequestsCoalesce()
    await checkDiskCacheWritesOffActor()
    await checkTerrariumRastersNotWrittenToDisk()
    await checkFetchedTilesAreHeldPageAligned()
    await checkElevationExtentOnFirstNeed()
    await checkStaleTilesArePushed()
    await checkStaleSettleWindow()
    await checkPromptAnswerThenUpgrade()
}
