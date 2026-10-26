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

/// T1. Before: concurrent `header()` calls on a reader whose header was not yet cached each ran `loadHeader()`, two
/// range GETs apiece (a 1 m COG's tile tables do not fit the first 16 KB), queued ahead of the tile ranges.
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

// MARK: - The section

@MainActor
func runTileLoadingChecks() async {
    print("\n=== Tile loading responsiveness ===")
    await checkCOGHeaderSingleFlight()
}
