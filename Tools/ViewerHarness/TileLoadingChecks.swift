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
          stats.minimum >= 150 && stats.maximum <= 200, "\(stats.minimum)...\(stats.maximum)")
    check("it is the fixture product", streamed.product.title == "fixture")
}

// MARK: - The section

@MainActor
func runTileLoadingChecks() async {
    print("\n=== Tile loading responsiveness ===")
    await checkCOGHeaderSingleFlight()
    await checkCoordinatorSingleFlight()
    await checkCOGTileDecodeAndNoData()
    await checkResampleOffActor()
}
