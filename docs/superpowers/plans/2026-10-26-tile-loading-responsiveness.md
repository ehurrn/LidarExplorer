# Tile Loading Responsiveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-10-26):** complete. Branch `claude/magical-bardeen-pjwbyj` on `main` at 8dd32a2, draft PR #58, one
> commit per task: the scaffold e71e99c, then a11c500 (Task 2) to f7fee08 (Task 13) from the cloud session, which
> compiled no Swift; then on the Mac cf0bcd0 (the Task 13 compile break, see below), d33ba93 (Task 14), e84eaac
> (Task 15) and e78e443 (T2 hardened after a mutant slipped it), each check red first. Harness 1721 to 1784 PASS / 0
> FAIL, ALL CHECKS PASSED at e78e443; Debug Simulator build for the iPad Pro 11-inch (M5) BUILD SUCCEEDED, no Swift
> warnings. The plan was written against `main` with
> every "Expected:" line a prediction; they held, with the departures listed under "Where the code differs from this
> text" before the Verification table. This block, that section and the three after it are the record.

**Goal:** Make the terrain tile pipeline answer the map sooner and stall less: no duplicate fetches under a burst, no
CPU work serialised on the hub actors, no per-shade raster copies, no re-shade storm when a neighbourhood lands, and a
prompt Terrarium answer while a slow native fetch finishes behind it.

**Architecture:** Fifteen findings from the two 2026-10-26 code reviews (the first review's 1-10 and the second's
1-10 overlap heavily; deduplicated below) land as fourteen tasks on the existing pipeline: `COGByteReader` →
`ElevationTileCoordinator` → `USGS3DEPService` / `TerrariumTileService` → `TileDiskCache` → `TerrainTileProvider` →
`RasterCompute` → `TerrainTileOverlayRenderer`. Nothing is restructured. The recurring moves are: single-flight a
check-then-await-then-cache; run pure CPU work in `Task.detached` the way `microPipelineImage` already does for
stitching (the only `Sendable` values cross: `Data`, `[UInt8]`, `COGMappedStorage`, `ElevationGrid`); hold fetched
samples in page-aligned pages so every shade is zero-copy; batch neighbour staleness behind a settle window; race the
native fetch against a budget and upgrade later.

**Tech Stack:** Swift 6 (`-strict-concurrency=complete -default-isolation MainActor`, upcoming features
`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`), Metal, MapKit. Verification is the host-compiled
regression harness `Tools/run-harness.sh` (needs Xcode on a Mac; `HARNESS_ONLY=<name>` runs one section) and the
Simulator `xcodebuild` recorded in `STATUS.md`.

---

## The findings, deduplicated, and where each lands

| # | Finding (review 1 / review 2 numbers) | Task |
|---|---|---|
| A | `COGByteReader.header()` and `ElevationTileCoordinator.georeference` are check-then-await-then-cache; `tile()` lets concurrent callers past its single-flight during the georeference await (R1-1, R2-2) | 2, 3 |
| B | `TerrainTileOverlayRenderer.request()` returns on `.dropped`/`.failed` before draining stale tiles (R1-2) | 12 |
| C | Every arriving tile drops eight neighbours' bitmaps at once; a viewport re-shades each tile up to nine times (R1-3) | 13 |
| D | `FallbackElevationProvider` waits out the ImageServer before Terrarium is tried; the z15 placeholder stays 20 s (R1-4) | 14 |
| E | LZW decode runs on the `COGByteReader` actor, the resample on the coordinator actor (R1-5, R2-1) | 4, 5 |
| F | A fetched tile is held as `[Float]`, so every shade allocates and copies an `MTLBuffer` (R1-6, R2-5) | 10 |
| G | Terrarium PNG decode runs on the `TerrariumTileService` actor (R1-7, R2-6) | 6 |
| H | A disk-loaded tile's mapping is not counted against the memory budget (R1-8) | 10 |
| I | Grid writes inherit the tile's priority and all disk-cache I/O runs on the `TileDiskCache` actor (R1-9, R2-3) | 8 |
| J | `cullTiles` re-parses every key string per frame (R1-10) | 15 |
| K | Terrarium rasters (z6-15) fill the 500 MB grid cache and evict the expensive z16+ rasters (R2-4) | 9 |
| L | `USGS3DEPService` has no in-flight coalescing and decodes on its actor (R2-7) | 7 |
| M | A GPU round trip per COG tile just to rewrite nodata, read back on the CPU anyway (R2-8) | 4 |
| N | `robustRange`, encode/decode copies and the Terrarium crop run on the `TerrainTileProvider` actor (R2-9) | 11 |
| O | Basemap tiles wait on the harvest cache actor; overzoom re-encodes JPEG (R2-10) | declined, see below |

**Declined, with reasons.** O part 1 (every basemap tile awaits `harvested.read`) is contention on the `TileDiskCache`
actor, and Task 8 takes the writes and the prune off that actor, which leaves the read a microsecond hop plus two
`ENOENT` opens; an in-memory "nothing harvested" flag would save those two opens at the cost of a second source of
truth for the protected directory, which is not worth it. O part 2 (JPEG re-encode of overzoomed sub-tiles) needs a
custom `MKOverlayRenderer` for the basemap, as the terrain layer has: a separate feature, out of a responsiveness
pass. N's local-file zip-merge (`fetchRaster`) stays on the actor: it runs only for a mounted GeoTIFF that partly
covers a tile, which is rare, and moving it means making the local provider's result cross an isolation boundary for
no measured gain. All three are listed under "Follow-ups" at the end.

**One memory trade the owner should know about (Task 10).** Holding a network-fetched tile's samples in page-aligned
pages for zero-copy shading costs one extra copy of the raster per tile in memory (1.08 MB at 512 px) for as long as
the tile is cached, in exchange for no 1 MB allocation and copy per shade (48 of them per frame during a sun-dial
drag). The memory budget then counts it correctly (finding H), so the 256 MB cap holds fewer tiles than it nominally
did, which were never that many in reality. If this is not wanted, Task 10 can be limited to the accounting fix.

## Verification constraints

- Each task ends with a partial harness run, `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`, plus any section the
  task touched (`ProviderMicro` for Tasks 12-14, `COGReader` for Task 4, `OfflineStore,Harvester` for Task 8). A
  partial run never prints ALL CHECKS PASSED; look for `0 FAIL` in its summary.
- Red first: each task's check is written and run before the change where the check can be red (it fails to
  compile against the old API, or asserts the new behaviour). Tasks 4, 5, 6, 7 and 8 move work off actors without
  changing results; their checks are regression guards and are expected to pass before and after, which the task
  says.
- The last task runs the full harness (expect ALL CHECKS PASSED, 1721 + the new checks) and the Simulator build with
  no Swift warnings, and records both in this file and `STATUS.md`. Logs go under `build-review/` (gitignored).
- Commit per task. The owner asked for one commit on the last remediation; if that is still preferred, squash at the
  end with `git rebase -i` is not available here, so use `git reset --soft <base> && git commit`.

## File structure

| File | Change |
|---|---|
| `Tools/ViewerHarness/TileLoadingChecks.swift` | **Create.** Section "Tile loading responsiveness", checks T1-T14, with a URL protocol that serves a COG and a product listing, fixture builders and a delayed stub |
| `Tools/run-harness.sh` | Add the new check file to `SOURCES` |
| `Tools/ViewerHarness/main.swift` | Register the section |
| `Tools/ViewerHarness/ProviderMicroChecks.swift` | B5, B10, B18, B20: settle before taking stale tiles |
| `Tools/LiveCheck/main.swift` | Drop the GPU-nodata assertion |
| `LidarExplorer/Services/Elevation/COGByteReader.swift` | Header single-flight; decode and nodata off the actor |
| `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift` | Georeference single-flight; tile() re-check; CPU nodata (no `pipeline`); resample off the actor |
| `LidarExplorer/Services/Elevation/TerrariumTileService.swift` | Decode off the actor |
| `LidarExplorer/Services/Elevation/ElevationService.swift` | In-flight coalescing; decode off the actor |
| `LidarExplorer/Services/Storage/TileDiskCache.swift` | Writes and prune off the actor |
| `LidarExplorer/MapLayer/TerrainTileOverlay.swift` | Provider: disk-worth rule, `AlignedSamples`, off-actor tile build, lazy extent, stale sink, settle window, prompt answer with upgrade, drain at utility. Renderer: `redrawStale`, request drains always, parsed paths. Store: paths per key |

---

### Task 1: Harness scaffold for the new section

**Files:**
- Create: `Tools/ViewerHarness/TileLoadingChecks.swift`
- Modify: `Tools/run-harness.sh` (the `SOURCES` list, before `Tools/ViewerHarness/main.swift`)
- Modify: `Tools/ViewerHarness/main.swift:2444` (after the `COGReaderChecks` section)

- [ ] **Step 1: Create the check file with its helpers and an empty section**

```swift
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

// MARK: - The section

@MainActor
func runTileLoadingChecks() async {
    print("\n=== Tile loading responsiveness ===")
}
```

- [ ] **Step 2: Register the file in the build and the run**

In `Tools/run-harness.sh`, in `SOURCES=(`, insert before `Tools/ViewerHarness/main.swift \`:

```bash
  Tools/ViewerHarness/TileLoadingChecks.swift \
```

In `Tools/ViewerHarness/main.swift`, after line 2444 (`await harnessSection("COGReaderChecks") { await runCOGReaderChecks() }`):

```swift
    await harnessSection("TileLoadingChecks") { await runTileLoadingChecks() }
```

- [ ] **Step 3: Run the empty section**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh 2>&1 | tee build-review/tl-task1.log`
Expected: the partial-run banner names `TileLoadingChecks.swift`, `=== Tile loading responsiveness ===` prints, summary shows `0 FAIL` (0 checks run in this section).

- [ ] **Step 4: Commit**

```bash
git add Tools/ViewerHarness/TileLoadingChecks.swift Tools/run-harness.sh Tools/ViewerHarness/main.swift
git commit -m "harness: a section for the tile-loading responsiveness checks, with an in-memory COG service"
```

---

### Task 2: One header fetch per COG, however many tiles ask at once

**Files:**
- Modify: `LidarExplorer/Services/Elevation/COGByteReader.swift:148-162` (`cachedHeader`, `header()`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add to `TileLoadingChecks.swift`, and add `await checkCOGHeaderSingleFlight()` to `runTileLoadingChecks()`:

```swift
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
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: `FAIL  and issue the range GETs of one call, not eight 8 vs 1` (or `16 vs 2` if the fixture's tag data spills past the first range).

- [ ] **Step 3: Single-flight the header load**

Replace lines 148-162 of `COGByteReader.swift` (from `private var cachedHeader: Header?` through the end of `header()`):

```swift
    private var cachedHeader: Header?
    /// The header load in flight, so a burst of tiles over a product not yet seen shares one set of range GETs. Each
    /// caller used to find `cachedHeader` nil while the first was suspended in `loadHeader()` and fetch its own: with
    /// ~35 map tiles over a new product that was ~70 GETs queued on the host's 8 connections ahead of the tile ranges.
    private var headerLoad: Task<Header, any Error>?

    public init(url: URL, transport: HTTPTransport = .shared) {
        self.url = url
        self.transport = transport
    }

    /// Parses (and caches) the file's TIFF header, first IFD, and the tags a
    /// COG reader needs. Issues one HTTP range request in the common case;
    /// a second, only if this file's tag data does not fit the first. Concurrent
    /// callers share the one load in flight.
    public func header() async throws -> Header {
        if let cachedHeader { return cachedHeader }
        if let headerLoad { return try await headerLoad.value }
        let load = Task { try await loadHeader() }
        headerLoad = load
        defer { headerLoad = nil }
        let parsed = try await load.value
        cachedHeader = parsed
        return parsed
    }
```

(The `init` moves down past the new property so the stored properties stay together; nothing else about it changes.)

- [ ] **Step 4: Run it green**

Run: `HARNESS_ONLY=TileLoading,COGReader ./Tools/run-harness.sh`
Expected: T1 PASS x3, Q1-Q5 unchanged, `0 FAIL`.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Elevation/COGByteReader.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "COG reader: one header load shared by every caller in flight"
```

---

### Task 3: One georeference and one fetch per COG tile under a burst

**Files:**
- Modify: `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift:420-427` (state), `:520-557` (`georeference`), `:561-595` (`tile`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await checkCoordinatorSingleFlight()`:

```swift
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
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: `FAIL  from one fetch: the single-flight holds across the georeference await 8`.

- [ ] **Step 3: Single-flight the georeference and re-check after the await in tile()**

Add to the coordinator's state (after `private var inFlightTiles: [TileKey: Task<StreamedTile?, Never>] = [:]`):

```swift
    private var inFlightGeoreferences: [GeoKey: Task<COGGeoreference?, Never>] = [:]
```

Replace `georeference(for:overviewLevel:)` (lines 520-557) with:

```swift
    /// The product's georeference, or `nil` (remembered) when its COG is not
    /// one this reader supports -- older 3DEP projects are striped or not UTM.
    /// Concurrent callers for one product share the load in flight.
    public func georeference(for product: URL, overviewLevel: Int = 0) async -> COGGeoreference? {
        let key = GeoKey(product: product, overviewLevel: overviewLevel)
        if let known = georeferences[key] {
            if let idx = georeferenceOrder.firstIndex(of: key) {
                georeferenceOrder.remove(at: idx)
                georeferenceOrder.append(key)
            }
            return known
        }
        guard !unusableProducts.contains(product) else { return nil }
        if let running = inFlightGeoreferences[key] { return await running.value }
        let load = Task { await self.loadGeoreference(key) }
        inFlightGeoreferences[key] = load
        let geo = await load.value
        inFlightGeoreferences[key] = nil
        return geo
    }

    /// Reads the header and remembers what it says, for one product and level at a time.
    private func loadGeoreference(_ key: GeoKey) async -> COGGeoreference? {
        let product = key.product, overviewLevel = key.overviewLevel
        do {
            let header = try await reader(for: product).header(forOverview: overviewLevel)
            guard let geo = COGGeoreference(header: header), header.sampleFormat == 3, header.bitsPerSample == 32 else {
                if overviewLevel == 0 {
                    unusableProducts.insert(product)
                }
                return nil
            }
            while georeferences.count >= Self.maxGeoreferences, !georeferenceOrder.isEmpty {
                let victim = georeferenceOrder.removeFirst()
                georeferences.removeValue(forKey: victim)
            }
            georeferences[key] = geo
            georeferenceOrder.append(key)
            return geo
        } catch COGError.transportFailure(let text) {
            Log.network.error("COG header fetch failed: \(text, privacy: .public)")
            return nil
        } catch {
            if overviewLevel == 0 {
                unusableProducts.insert(product)
            }
            Log.geospatial.notice("COG unusable (\(String(describing: error), privacy: .public)): \(product.lastPathComponent, privacy: .public)")
            return nil
        }
    }
```

In `tile(product:column:row:overviewLevel:)`, after the `guard let geo = await georeference(...)` statement and before `let reader = reader(for: product)`, insert:

```swift
        // The georeference await let other callers for this tile in: one may have started the fetch, or finished it.
        if let hit = tileCache[key] {
            promote(key)
            return hit
        }
        if let running = inFlightTiles[key] { return await running.value }
```

- [ ] **Step 4: Run it green**

Run: `HARNESS_ONLY=TileLoading,Coordinator ./Tools/run-harness.sh`
Expected: T2 PASS x5, the coordinator's offline section unchanged, `0 FAIL`.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "COG coordinator: single-flight the georeference, and re-check the tile single-flight after its await"
```

---

### Task 4: Decode and nodata off the reader actor, on the CPU; no GPU nodata pass

**Files:**
- Modify: `LidarExplorer/Services/Elevation/COGByteReader.swift:164-236` (`fetchTile`, `fetchTileStorage`)
- Modify: `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift` (`StreamedTile`, class doc, `Statistics`, state, `init`, `tile()`, `normalizeOnCPU`)
- Modify: `Tools/LiveCheck/main.swift:363`
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

Why both at once: the GPU pass (finding M) exists only because `fetchTileStorage` left sentinels in place for it; once the reader normalises on the CPU inside the same off-actor pass, the coordinator's hop onto `MetalTerrainPipelineActor` per tile has nothing left to do.

- [ ] **Step 1: Write the check**

Add, and register `await checkCOGTileDecodeAndNoData()`:

```swift
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
```

- [ ] **Step 2: Run it**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: T3 passes already (the GPU pass or the CPU fallback normalises today). It stays as the guard for the rewrite.

- [ ] **Step 3: Move the reader's decode off the actor and fold the nodata pass in**

Replace `fetchTile` and `fetchTileStorage` in `COGByteReader.swift` (lines 164-236) with:

```swift
    /// Fetches, decompresses, and un-predicts one tile, landing the decoded
    /// `Float32` samples in page-aligned memory ready for `ElevationSamples.mapped`,
    /// with the file's nodata sentinel already rewritten to NaN.
    public func fetchTile(_ tileIndex: Int, overviewLevel: Int = 0) async throws -> (storage: COGMappedStorage, width: Int, height: Int) {
        try await fetchTileStorage(tileIndex, overviewLevel: overviewLevel, normalizingNoData: true)
    }

    /// Fetches one tile and decodes it straight into page-aligned storage.
    ///
    /// The range response is handed to the LZW decoder as the `Data` it
    /// arrived in, the decoder writes directly into the storage Metal adopts
    /// with `bytesNoCopy`, and the floating-point predictor is reversed in
    /// place -- the decoded samples are never materialised anywhere else.
    ///
    /// Sentinels are left exactly as the file stores them (``Header/noDataValue``).
    public func fetchTileStorage(_ tileIndex: Int, overviewLevel: Int = 0) async throws -> (storage: COGMappedStorage, width: Int, height: Int) {
        try await fetchTileStorage(tileIndex, overviewLevel: overviewLevel, normalizingNoData: false)
    }

    private func fetchTileStorage(
        _ tileIndex: Int, overviewLevel: Int, normalizingNoData: Bool
    ) async throws -> (storage: COGMappedStorage, width: Int, height: Int) {
        let h = try await header(forOverview: overviewLevel)
        guard tileIndex >= 0, tileIndex < h.tileOffsets.count else {
            throw COGError.unsupportedLayout("tile index \(tileIndex) out of range")
        }
        guard h.sampleFormat == 3, h.bitsPerSample == 32 else {
            throw COGError.unsupportedLayout("expected Float32 samples, got format \(h.sampleFormat)/\(h.bitsPerSample)-bit")
        }
        guard h.compression == 1 || h.compression == 5 else {
            throw COGError.unsupportedLayout("unsupported compression \(h.compression)")
        }

        let offset = Int(h.tileOffsets[tileIndex])
        let byteCount = Int(h.tileByteCounts[tileIndex])
        guard byteCount > 0 else {
            throw COGError.malformedHeader("tile \(tileIndex) has zero byte count")
        }
        let compressed = try await rangeGetData(offset..<(offset + byteCount))

        // Decoded off this actor. The LZW pass, the predictor and the byte swap are 1-3 ms of CPU a tile; on the
        // actor they ran one at a time behind every other tile's header and range request for this product, so a
        // viewport's ~200 tiles cost ~0.5 s of pure queueing before the first was done.
        return try await Task.detached(priority: .userInitiated) {
            let tile = try Self.decode(compressed, header: h, tileIndex: tileIndex)
            if normalizingNoData {
                Self.normalizeNoData(tile.storage, count: tile.width * tile.height, noDataValue: h.noDataValue)
            }
            return tile
        }.value
    }

    /// Decompresses one tile's bytes into fresh page-aligned storage and reverses the predictor and the byte order
    /// in place. Pure: it touches nothing of the reader's, so it may run anywhere.
    nonisolated static func decode(
        _ compressed: Data, header h: Header, tileIndex: Int
    ) throws -> (storage: COGMappedStorage, width: Int, height: Int) {
        let expectedRaw = h.tileWidth * h.tileLength * 4
        guard let storage = COGMappedStorage(length: expectedRaw) else {
            throw COGError.decodeFailure("could not allocate \(expectedRaw) bytes for tile \(tileIndex)")
        }
        let destination = UnsafeMutableRawBufferPointer(start: storage.pointer, count: expectedRaw)

        switch h.compression {
        case 1:
            guard compressed.count >= expectedRaw else {
                throw COGError.decodeFailure("uncompressed tile \(tileIndex) short by \(expectedRaw - compressed.count) bytes")
            }
            compressed.withUnsafeBytes { src in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<expectedRaw]))
            }
        default:
            let decoded = compressed.withUnsafeBytes { TIFFLZWDecoder.decode($0, into: destination) }
            guard decoded else {
                throw COGError.decodeFailure("LZW decode failed for tile \(tileIndex)")
            }
        }

        if h.predictor == 3 {
            TIFFFloatingPointPredictor.decodeInPlace(
                destination, width: h.tileWidth, height: h.tileLength, littleEndian: h.littleEndian)
        }
        if !h.littleEndian {
            // Samples are in the file's byte order; the GPU reads host order.
            for i in stride(from: 0, to: expectedRaw, by: 4) {
                let bits = storage.pointer.load(fromByteOffset: i, as: UInt32.self)
                storage.pointer.storeBytes(of: bits.byteSwapped, toByteOffset: i, as: UInt32.self)
            }
        }
        return (storage, h.tileWidth, h.tileLength)
    }

    /// Rewrites the file's sentinel, and anything that is no elevation (an infinity, a float's extreme standing in
    /// for a missing nodata tag, -9999 where the tag says -32767), to NaN. The one rule every path shares.
    nonisolated static func normalizeNoData(_ storage: COGMappedStorage, count: Int, noDataValue: Float?) {
        let floats = storage.pointer.assumingMemoryBound(to: Float.self)
        let valid = MicroTopographyReference.validElevationRange
        for i in 0..<count {
            let v = floats[i]
            if !v.isFinite || v == noDataValue || !valid.contains(v) { floats[i] = .nan }
        }
    }
```

- [ ] **Step 4: Take the GPU pass out of the coordinator**

In `ElevationTileCoordinator.swift`:

1. `StreamedTile`: delete the `normalizedOnGPU` property, its doc comment, its `init` parameter and assignment. The
   resulting init signature is
   `init(product:column:row:overviewLevel:storage:width:height:cellSizeX:cellSizeY:)`.
2. Class doc, pipeline step 4: replace with
   `/// 4. **Nodata** — the reader rewrites sentinels to NaN on the CPU in that same memory, in the decode pass, before the tile is published.`
3. `Statistics`: delete `gpuNormalizedTiles`.
4. State: delete `private let pipeline: MetalTerrainPipelineActor` and `private var gpuNormalizedTiles = 0`.
5. `init`: becomes

```swift
    public init(transport: HTTPTransport = .shared) {
        self.transport = transport
    }
```

6. `statistics()`: `Statistics(cachedTiles: tileCache.count, cachedBytes: cachedBytes, tileFetches: tileFetches)`.
7. `tile(...)`: replace from `let reader = reader(for: product)` to the end of the method with

```swift
        let reader = reader(for: product)
        let index = row * geo.tilesAcross + column
        tileFetches += 1
        let task = Task<StreamedTile?, Never> {
            guard let decoded = try? await reader.fetchTile(index, overviewLevel: overviewLevel) else { return nil }
            return StreamedTile(
                product: product, column: column, row: row, overviewLevel: overviewLevel, storage: decoded.storage,
                width: decoded.width, height: decoded.height,
                cellSizeX: Float(geo.pixelSizeX), cellSizeY: Float(geo.pixelSizeY)
            )
        }
        inFlightTiles[key] = task
        let result = await task.value
        inFlightTiles[key] = nil
        if let result { store(result, for: key) }
        return result
    }
```

8. Delete `nonisolated static func normalizeOnCPU(...)` (the reader's `normalizeNoData` is the one rule now).
9. The method doc above `tile(...)`: `/// One native or overview tile, decoded into page-aligned memory with its voids already NaN.`

In `Tools/LiveCheck/main.swift:363` replace the GPU assertion with:

```swift
    check("the coordinator fetched tiles for the raster", stats.tileFetches > 0, "\(stats)")
```

- [ ] **Step 5: Run green**

Run: `HARNESS_ONLY=TileLoading,COGReader,Coordinator,RasterStorage ./Tools/run-harness.sh`
Expected: `0 FAIL`. (Q1 asserts `fetchTile` voids the sentinel; it goes through the new path.) The live check is
host-compiled only by `Tools/run-live-check.sh`, which also runs it against the real services, so it is not built
here: Task 16 records it as edited and unrun, as `STATUS.md` already does for that tool.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/Services/Elevation/COGByteReader.swift LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift Tools/LiveCheck/main.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "COG tiles: decode and void off the reader actor on the CPU; the GPU nodata pass goes"
```

---

### Task 5: The Mercator resample off the coordinator actor

**Files:**
- Modify: `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift` (`elevationRaster(for:width:height:overviewLevel:)`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the check**

Add, and register `await checkResampleOffActor()`:

```swift
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
```

- [ ] **Step 2: Run it**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: T4 passes already (guard for the rewrite). If `the raster streams` fails, the product bbox or coverage
check is the cause: print `region` and compare with `ElevationTileCoordinator.coverage`.

- [ ] **Step 3: Detach the resample**

In `elevationRaster`, replace the block from `let url = product.url` through the closing of `withExtendedLifetime` with:

```swift
            let url = product.url
            let fill = contributor != nil
            // Off this actor: a 520 x 520 resample is 2-4 ms of CPU, and run here it held every tile() cache hit and
            // georeference lookup of the burst behind it. Only Sendable values cross; the output pointer is re-derived
            // from the storage inside.
            let added = await Task.detached(priority: .userInitiated) {
                let output = storage.pointer.bindMemory(to: Float.self, capacity: width * height)
                return withExtendedLifetime(fetched) {
                    COGResampler.resample(
                        region: region, width: width, height: height, georeference: geo,
                        into: output, fillOnlyVoids: fill
                    ) { column, row in
                        fetched[TileKey(product: url, column: column, row: row, overviewLevel: overviewLevel)]
                            .map { UnsafePointer($0.storage.pointer.assumingMemoryBound(to: Float.self)) }
                    }
                }
            }.value
```

Leave the earlier `let output = storage.pointer.bindMemory(...)` and `output.initialize(...)` at the top of the
method as they are: the detached closure must not capture that pointer (it is not `Sendable`), which is why it
re-derives its own.

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,Coordinator ./Tools/run-harness.sh`
Expected: `0 FAIL`.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "COG coordinator: resample map tiles off the actor"
```

---

### Task 6: Terrarium PNG decode off its actor

**Files:**
- Modify: `LidarExplorer/Services/Elevation/TerrariumTileService.swift:78` (`elevation(x:y:z:region:)`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the check**

Add, and register `await checkTerrariumDecodeOffActor()`:

```swift
/// T5. `TerrariumTileService` is an actor whose only state is its session, yet it decoded each PNG inside its
/// isolation, so the 8 tiles the session fetches at once decoded one at a time. The decode is detached now.
@MainActor
private func checkTerrariumDecodeOffActor() async {
    print("\n--- T5. Terrarium tiles decode off the service actor ---")
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 250))
    let service = TerrariumTileService(session: HarvestNetworkProtocol.session)
    let (x, y, region) = cahokiaTile(z: 14)
    let decoded = await withTaskGroup(of: Float?.self, returning: [Float].self) { group in
        for i in 0..<8 {
            group.addTask { await service.elevation(x: x + i, y: y, z: 14, region: region).value?.samples[1000] }
        }
        var out: [Float] = []
        for await v in group { if let v { out.append(v) } }
        return out
    }
    check("eight concurrent tiles decode to the encoded elevation", decoded.count == 8 && decoded.allSatisfy { $0 == 250 }, "\(decoded)")
    HarvestNetworkProtocol.set(serving: nil)
}
```

- [ ] **Step 2: Run it**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: T5 passes already (guard).

- [ ] **Step 3: Detach the decode**

In `elevation(x:y:z:region:)`, replace

```swift
            guard let grid = Self.decode(data, region: region) else {
```

with

```swift
            // Off the actor: the CGImageSource decode, the redraw and 65K float conversions are 1-3 ms a tile, and the
            // session answers up to 8 at once. The actor protects nothing they need.
            guard let grid = await Task.detached(priority: .userInitiated) { Self.decode(data, region: region) }.value else {
```

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,Harvester ./Tools/run-harness.sh`
Expected: `0 FAIL`.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Elevation/TerrariumTileService.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Terrarium: decode tiles off the service actor"
```

---

### Task 7: 3DEP ImageServer requests coalesce per extent; decode off the actor

**Files:**
- Modify: `LidarExplorer/Services/Elevation/ElevationService.swift` (state near `:85`, `elevation(for:targetSamples:)` `:177-283`, `GridOutcome`, `makeGrid`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await check3DEPRequestsCoalesce()`:

```swift
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
    check("four concurrent calls for one extent issue one request (plus its one retry), not four",
          DelayedFailureURLProtocol.requestCount <= 2, "\(DelayedFailureURLProtocol.requestCount)")
    check("and count one failure against the circuit breaker, not four", await !service.isCooldownActive())
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: `FAIL ... issue one request ... 8` and `FAIL  and count one failure against the circuit breaker, not four`.

- [ ] **Step 3: Coalesce and detach**

Add to the service's state (after `private var failureCooldownUntil: ContinuousClock.Instant?`):

```swift
    /// Fetches in flight by cache key, so the read-back, the harvester and the fallback chain asking for one extent
    /// at once share a single ImageServer request (10-18 s cold) and a single breaker count.
    private var inFlight: [String: Task<Evidence<ElevationGrid>, Never>] = [:]
```

Change `private enum GridOutcome` to `private enum GridOutcome: Sendable`, and `private static func makeGrid(` to
`private nonisolated static func makeGrid(` (it is pure; the detached closures below call it).

Replace `elevation(for:targetSamples:)` from `// Check persistent disk cache before network fetch` down to the end of
the method with the following, so that the method ends:

```swift
        if let running = inFlight[key] { return await running.value }
        let fetch = Task { await self.fetch(region: region, targetSamples: targetSamples, key: key) }
        inFlight[key] = fetch
        let outcome = await fetch.value
        inFlight[key] = nil
        return outcome
    }

    /// The disk tier, the circuit breaker and the network, for one key at a time
    /// (``elevation(for:targetSamples:)`` coalesces the callers).
    private func fetch(region: GeoRegion, targetSamples: Int, key: String) async -> Evidence<ElevationGrid> {
        // The disk tier, decoded off the actor: a TIFF decode plus the void scan is 1-5 ms, and on the actor it held
        // every memory-cache hit behind it.
        if let diskDir = Self.diskCacheDirectory {
            let fileURL = diskDir.appendingPathComponent(Self.diskFilename(for: key))
            let restored = await Task.detached(priority: .userInitiated) { () -> GridOutcome? in
                guard let diskData = try? Data(contentsOf: fileURL),
                      let raster = try? FloatTIFFDecoder.decode(diskData) else { return nil }
                return Self.makeGrid(from: raster, requestedRegion: region)
            }.value
            switch restored {
            case .success(let grid)?:
                store(grid, for: key)
                Log.geospatial.debug("Elevation disk cache hit for \(key, privacy: .public)")
                return .observed(grid, Provenance(source: .usgs3DEP, servedFromCacheAt: Date()))
            case .failure?:
                try? FileManager.default.removeItem(at: fileURL)
            case nil:
                break
            }
        }

        // If the circuit breaker tripped due to consecutive failures, decline immediately
        // during the cooldown so fallback pipelines (e.g. Terrarium upsampling) trigger
        // without blocking the queue.
        if let cooldown = failureCooldownUntil {
            if ContinuousClock.now < cooldown {
                return .unavailable(.transportFailure(.usgs3DEP, description: "circuit breaker open"))
            } else {
                failureCooldownUntil = nil
            }
        }

        // Size the request in Web Mercator (EPSG:3857) projected metres.
        // In EPSG:3857, tile bounds are inherently square, matching MKTileOverlay
        // and basemaps precisely and eliminating non-uniform vertical stretching.
        let samples = min(max(targetSamples, 16), Self.maxSamplesPerAxis)
        let m = region.mercatorBounds

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "bbox", value: "\(m.minX),\(m.minY),\(m.maxX),\(m.maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "\(samples),\(samples)"),
            .init(name: "format", value: "tiff"),
            .init(name: "pixelType", value: "F32"),
            .init(name: "noData", value: "\(Int(Self.noDataValue))"),
            .init(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            .init(name: "interpolation", value: "RSP_BilinearInterpolation"),
            .init(name: "f", value: "image"),
        ]

        guard let url = components.url else {
            return .unavailable(.transportFailure(.usgs3DEP, description: "could not build request URL"))
        }

        Log.geospatial.info("Fetching 3DEP \(samples)x\(samples) for \(region.cacheKey, privacy: .public)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let result = await transport.data(for: request, maxAttempts: 2)

        switch result {
        case .failure(let error):
            if error != .cancelled {
                recordFailure()
            }
            Log.geospatial.error("3DEP fetch failed: \(error.description, privacy: .public)")
            return .unavailable(.transportFailure(.usgs3DEP, description: error.description))

        case .success(let data):
            let decoded = await Task.detached(priority: .userInitiated) { () -> (grid: GridOutcome?, error: String?) in
                do {
                    let raster = try FloatTIFFDecoder.decode(data)
                    return (Self.makeGrid(from: raster, requestedRegion: region), nil)
                } catch {
                    return (nil, (error as? FloatTIFFDecoder.DecodeError)?.description ?? error.localizedDescription)
                }
            }.value
            guard let gridOutcome = decoded.grid else {
                recordFailure()
                let text = decoded.error ?? "undecodable"
                Log.geospatial.error("3DEP raster undecodable: \(text, privacy: .public)")
                return .unavailable(.undecodable(.usgs3DEP, description: text))
            }

            recordSuccess()

            switch gridOutcome {
            case .success(let grid):
                store(grid, for: key)
                if let diskDir = Self.diskCacheDirectory {
                    let fileURL = diskDir.appendingPathComponent(Self.diskFilename(for: key))
                    writesSincePrune += 1
                    let prune = writesSincePrune >= Self.pruneInterval
                    if prune { writesSincePrune = 0 }
                    Task.detached(priority: .utility) {
                        try? data.write(to: fileURL, options: .atomic)
                        if prune { Self.pruneDiskCacheIfNeeded() }
                    }
                }
                return .observed(grid, Provenance(source: .usgs3DEP, acquired: nil))
            case .failure(let reason):
                return .unavailable(reason)
            }
        }
    }
```

(The coverage guard and the memory-cache hit stay at the top of `elevation(for:targetSamples:)` as they are; the
circuit-breaker check moves into `fetch` so a coalesced waiter gets the same answer the leader got.)

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro ./Tools/run-harness.sh`
Expected: T6 PASS x2; B5's circuit-breaker checks (three sequential failures on three regions trip it) still pass;
`0 FAIL`.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Elevation/ElevationService.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "3DEP service: coalesce requests per extent, decode off the actor"
```

---

### Task 8: The disk cache's writes and prune off its actor; the grid drain at utility priority

**Files:**
- Modify: `LidarExplorer/Services/Storage/TileDiskCache.swift` (`write`, `writeProtected`, `pruneIfNeeded`, `adoptMeasurement`)
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift:1301-1310` (`queueGridWrite`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the check**

Add, and register `await checkDiskCacheWritesOffActor()`:

```swift
/// T7. Every write (temp file, copy, rename) and the prune's directory walk ran on the cache actor, so each
/// `map(forKey:)` of the opening burst waited behind them. Both run detached now; the accounting stays on the actor.
/// The usage is measured first so the prune decisions below do not depend on when the background measurement lands.
@MainActor
private func checkDiskCacheWritesOffActor() async {
    print("\n--- T7. the disk cache writes and prunes off its actor, with the same accounting ---")
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-loading-cache-\(UUID().uuidString)", isDirectory: true)
    let cache = TileDiskCache(directory: directory, maxDiskBytes: 150_000, targetDiskBytes: 100_000)
    let payload = Data(repeating: 1, count: 100_000)
    check("the first write lands", await cache.write(payload, forKey: "entry-0"))
    check("setup: usage measured", await cache.measureDiskUsage() == 100_000)
    check("a second write lands and prunes the oldest", await cache.write(payload, forKey: "entry-1")
          && !(await cache.contains(forKey: "entry-0")) && (await cache.contains(forKey: "entry-1")))
    check("a third write lands and prunes again", await cache.write(payload, forKey: "entry-2")
          && !(await cache.contains(forKey: "entry-1")) && (await cache.contains(forKey: "entry-2")))
    check("usage is one entry", await cache.measureDiskUsage() == 100_000, "\(await cache.measureDiskUsage() ?? -1)")
    check("a mapped read of the survivor sees its bytes", (await cache.map(forKey: "entry-2"))?.fileLength == 100_000)
    try? FileManager.default.removeItem(at: directory)
}
```

- [ ] **Step 2: Run it**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: T7 passes already (guard).

- [ ] **Step 3: Move the syscalls off the actor**

In `TileDiskCache.swift` replace `write(_:forKey:protected:)` with:

```swift
    /// Writes `data` under `key`. Best-effort for the tile path, which simply fetches again; the result is for
    /// callers, such as the offline harvester, that must know whether the bytes reached the disk.
    ///
    /// A `protected` write goes to protected storage instead: it counts against no cap, prunes nothing, and stays
    /// until ``removeProtected()``. A copy the tile cache already held under the key is dropped, so the bytes are
    /// kept once.
    ///
    /// The write itself runs off this actor: an atomic write is a temp file, a 272 KB copy and a rename, and done
    /// here it held every `map(forKey:)` of the opening burst behind it. Only the bookkeeping is isolated.
    @discardableResult
    public func write(_ data: Data, forKey key: String, protected: Bool = false) async -> Bool {
        let name = Self.fileName(forKey: key)
        if protected { return await writeProtected(data, name: name) }
        guard await Self.writeFile(data, to: cacheDirectory.appendingPathComponent(name)) else { return false }
        touch(name)
        guard let known = knownDiskBytes else {
            beginMeasurementIfNeeded()
            return true
        }
        let projected = known + Int64(data.count)
        knownDiskBytes = projected
        if projected > maxDiskBytes {
            await pruneIfNeeded()
        }
        return true
    }

    /// Writes atomically, off the actor. Whether the bytes reached the disk.
    private nonisolated static func writeFile(_ data: Data, to url: URL) async -> Bool {
        await Task.detached(priority: .utility) { (try? data.write(to: url, options: .atomic)) != nil }.value
    }
```

Replace `writeProtected(_:name:)` with:

```swift
    private func writeProtected(_ data: Data, name: String) async -> Bool {
        do {
            try prepareProtectedDirectory()
        } catch {
            protectedFolderReady = false
            return false
        }
        guard await Self.writeFile(data, to: protectedURL(forName: name)) else {
            protectedFolderReady = false
            return false
        }
        discardOrdinaryCopy(named: name)
        return true
    }
```

Change `adoptMeasurement` to `private func adoptMeasurement(_ total: Int64?) async` and its last statement to
`if total > maxDiskBytes { await pruneIfNeeded() }`. (`beginMeasurementIfNeeded` already awaits it.)

Replace `pruneIfNeeded()` with:

```swift
    /// Guards against a second prune while one walks the directory.
    private var isPruning = false

    /// Brings the directory under its cap, oldest first. The walk, the sort and the removals run off the actor over a
    /// snapshot of this session's recency; what they found and removed is adopted here. Measured at ~25 ms for 1,800
    /// files cold on a device, which on the actor stalled every concurrent tile read.
    private func pruneIfNeeded() async {
        guard !isPruning else { return }
        isPruning = true
        defer { isPruning = false }
        let directory = cacheDirectory, snapshot = recency, cap = maxDiskBytes, target = targetDiskBytes
        let result = await Task.detached(priority: .utility) {
            Self.prune(directory: directory, recency: snapshot, maxBytes: cap, targetBytes: target, fileManager: FileManager())
        }.value
        guard let result else { return }
        knownDiskBytes = result.remainingBytes
        for name in result.removed { recency.removeValue(forKey: name) }
    }

    private nonisolated struct PruneResult: Sendable {
        let remainingBytes: Int64
        let removed: [String]
    }

    /// The walk: every plain file's size and last use (an in-session access wins; anything untouched this launch is
    /// ordered by modification date), then removals oldest first until `targetBytes`, only if over `maxBytes`.
    /// `nil` if the directory cannot be enumerated.
    private nonisolated static func prune(
        directory: URL, recency: [String: Date], maxBytes: Int64, targetBytes: Int64, fileManager: FileManager
    ) -> PruneResult? {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        ) else { return nil }

        struct Entry {
            let url: URL
            let name: String
            let size: Int64
            let lastUsed: Date
        }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in fileURLs {
            // A folder here is not an entry, and the protected one must never be offered for eviction.
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
               values.isDirectory != true,
               let size = values.fileSize {
                let name = url.lastPathComponent
                entries.append(Entry(url: url, name: name, size: Int64(size),
                                     lastUsed: recency[name] ?? values.contentModificationDate ?? Date.distantPast))
                total += Int64(size)
            }
        }
        guard total > maxBytes else { return PruneResult(remainingBytes: total, removed: []) }

        entries.sort { $0.lastUsed < $1.lastUsed }
        var removed: [String] = []
        for entry in entries {
            guard total > targetBytes else { break }
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed.append(entry.name)
            }
        }
        return PruneResult(remainingBytes: total, removed: removed)
    }
```

In `TerrainTileOverlay.swift` `queueGridWrite`, change

```swift
        gridWriteDrain = Task { [weak self] in await self?.drainGridWrites() }
```

to

```swift
        // Utility, not the requesting tile's priority: a raster written is a raster already shaded, and the disk
        // reads of the tiles still loading should not queue behind it.
        gridWriteDrain = Task(priority: .utility) { [weak self] in await self?.drainGridWrites() }
```

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,OfflineStore,Harvester,HarvestFailure,core ./Tools/run-harness.sh`
Expected: `0 FAIL`. S1-S7 exercise protected writes, pinning and pruning; "Tile Disk Cache Performance Hygiene" in
`core` exercises the cache directly. If a check there awaited a prune's effect synchronously, it now needs the
`waitFor`/`eventually` pattern S3 already uses; fix the check, not the cache.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Storage/TileDiskCache.swift LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile disk cache: writes and the prune off the actor; the grid drain runs at utility"
```

---

### Task 9: Terrarium rasters stay out of the disk tile cache

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift:235-237` (after `isCacheableSource`), `:1284-1299` (`fetchedTile`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await checkTerrariumRastersNotWrittenToDisk()`:

```swift
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
    check("a z14 tile draws", await provider.tileImage(x: coarse.x, y: coarse.y, z: 14, region: coarse.region, pixels: 512) != nil)
    let fine = cahokiaTile(z: 19)
    check("a z19 tile draws", await provider.tileImage(x: fine.x, y: fine.y, z: 19, region: fine.region, pixels: 512) != nil)
    let fineKey = TerrainTileProvider.gridCacheKey(x: fine.x, y: fine.y, z: 19, pixels: 512, margin: margin)
    check("the z19 raster reaches the disk", await eventually { await cache.contains(forKey: fineKey) })
    let coarseKey = TerrainTileProvider.gridCacheKey(x: coarse.x, y: coarse.y, z: 14, pixels: 512, margin: margin)
    check("the z14 raster does not", await !cache.contains(forKey: coarseKey))
    HarvestNetworkProtocol.set(serving: nil)
    try? FileManager.default.removeItem(at: directory)
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: does not compile (`isWorthCachingOnDisk` undefined). That is the red.

- [ ] **Step 3: Add the rule and apply it on the map path**

After `isCacheableSource` (line 237) add:

```swift
    /// Whether a raster fetched for a map tile at `z` from `source` is worth a slot in the disk tile cache.
    ///
    /// ``isCacheableSource(_:)`` says whether a raster may be kept at all (a degraded fallback or a local file's may
    /// not, by the harvest either). This asks, of those that may, whether keeping it buys anything: a z16+ raster
    /// saves a 1-18 s 3DEP fetch, while a Terrarium tile below ``nativeDetailZ`` is rebuilt in a millisecond from the
    /// ~30 KB PNG ``TerrariumTileService/sharedURLCache`` already holds. Written here it took nine times that room
    /// and, as the entry most recently used, pushed the expensive rasters out first. The harvest is not this: it
    /// stores every level, protected, for offline use (``harvestTile(x:y:z:pixels:)``).
    nonisolated static func isWorthCachingOnDisk(source: String, z: Int) -> Bool {
        isCacheableSource(source) && z >= nativeDetailZ
    }
```

In `fetchedTile`, change `if Self.isCacheableSource(fetched.source),` to `if Self.isWorthCachingOnDisk(source: fetched.source, z: z),`.

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,OfflineStore,Harvester,core ./Tools/run-harness.sh`
Expected: `0 FAIL` (S3 browses at z17 and harvests z16-18; main.swift's fallback checks read `isCacheableSource`,
which is unchanged).

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile provider: Terrarium rasters are not written to the disk tile cache"
```

---

### Task 10: Fetched tiles held page-aligned for zero-copy shading; the budget counts the mapping

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift:248-335` (`CachedTile`), `:1253-1282` (`diskTile`), `:1331-1340` (`shade`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await checkFetchedTilesAreHeldPageAligned()`:

```swift
/// T9. A tile from the network was held as `[Float]`, so every shade allocated an `MTLBuffer` and copied 1 MB into
/// it (48 tiles x 60 Hz during a sun-dial drag); a tile from disk adopted its mapping zero-copy but the budget never
/// counted that mapping. Now both hold page-aligned samples the shader adopts, and both count them.
@MainActor
private func checkFetchedTilesAreHeldPageAligned() async {
    print("\n--- T9. a fetched tile is held in page-aligned pages the shader adopts, and the budget counts them ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    check("setup: the tile shades", await scene.image() != nil)
    let plane = (512 + 2 * TerrainTileProvider.marginPixels) * (512 + 2 * TerrainTileProvider.marginPixels) * MemoryLayout<Float>.stride
    let held = await scene.provider.memoryCacheSize()
    check("the entry counts its heap grid and its page-aligned copy (two planes) besides the bitmap",
          held >= 2 * plane, "\(held) bytes against two planes of \(plane)")
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: `FAIL ... two planes ... 2130176 bytes against two planes of 1081600` (one plane plus a 1 MB bitmap is under two planes).

- [ ] **Step 3: Replace `mapped`/`sampleOffset` with `AlignedSamples`**

Before `private struct CachedTile` insert:

```swift
    /// Page-aligned samples the shader adopts without a copy: the cache file's mapping for a tile from disk, an
    /// anonymous mapping filled once for a tile from the network. `@unchecked Sendable`: the memory is written once,
    /// before the entry exists, and read only; `owner` keeps it mapped.
    private struct AlignedSamples: @unchecked Sendable {
        let base: UnsafeMutableRawPointer
        let mappedLength: Int
        let sampleOffset: Int
        let owner: AnyObject

        init(file: MappedFile, sampleOffset: Int) {
            base = file.base
            mappedLength = file.mappedLength
            self.sampleOffset = sampleOffset
            owner = file
        }

        /// `samples` copied once into fresh pages, or `nil` if they cannot be mapped. One copy here, instead of one
        /// `makeBuffer` and `memcpy` per shade (``RasterCompute/renderTile``'s `.array` path).
        init?(copying samples: [Float]) {
            let bytes = samples.count * MemoryLayout<Float>.stride
            guard let storage = COGMappedStorage(length: bytes) else { return nil }
            samples.withUnsafeBytes { src in
                if let s = src.baseAddress { storage.pointer.copyMemory(from: s, byteCount: bytes) }
            }
            base = storage.pointer
            mappedLength = storage.length
            sampleOffset = 0
            owner = storage
        }
    }
```

In `CachedTile`:

1. Replace the `mapped` and `sampleOffset` properties (and their doc comment) with:

```swift
        /// Where the shader and the analysis builder read this tile's samples: the cache file's own pages for a tile
        /// from disk, a page-aligned copy made once for a tile from the network. Nil only if the copy could not be mapped.
        let aligned: AlignedSamples?
```

2. Change the `init` signature's `mapped: MappedFile? = nil, sampleOffset: Int = 0` to `aligned: AlignedSamples? = nil`,
   and its body's `self.mapped = mapped` / `self.sampleOffset = sampleOffset` to
   `self.aligned = aligned ?? AlignedSamples(copying: grid.samples)`.
3. Replace `samples`, `analysisSource` and `byteCount` with:

```swift
        /// Where the shader should read this tile's samples from.
        var samples: ElevationSamples {
            if let aligned {
                return .mapped(
                    base: aligned.base, mappedLength: aligned.mappedLength,
                    sampleOffset: aligned.sampleOffset, owner: aligned.owner)
            }
            return .array(grid.samples)
        }

        /// The raster as the analysis builder reads it: straight out of the page-aligned samples the shader adopts, the
        /// sample array otherwise.
        var analysisSource: AnalysisTileSource {
            if let aligned, aligned.mappedLength >= aligned.sampleOffset + grid.count * MemoryLayout<Float>.stride {
                let pointer = UnsafeRawPointer(aligned.base + aligned.sampleOffset).assumingMemoryBound(to: Float.self)
                return AnalysisTileSource(pointer: pointer, paddedWidth: grid.width, margin: margin, owner: aligned.owner)
            }
            return AnalysisTileSource(samples: grid.samples, paddedWidth: grid.width, margin: margin)
        }

        /// Bytes this entry holds: the padded raster on the heap, its page-aligned copy or mapping, any derivative
        /// planes, and a shaded bitmap. The mapping was not counted before, so disk-loaded tiles ran the budget about
        /// half over.
        var byteCount: Int {
            let plane = grid.samples.count * MemoryLayout<Float>.stride
            let planes = 1 + (products.map { 3 + ($0.normalX == nil ? 0 : 3) } ?? 0)
            return plane * planes + (aligned?.mappedLength ?? 0) + (rendered.map { $0.bytesPerRow * $0.height } ?? 0)
        }
```

In `diskTile`, replace the `return CachedTile(...)` with:

```swift
        return CachedTile(
            grid: decoded.grid,
            source: decoded.source,
            margin: margin,
            // Only a page-aligned payload can back a Metal buffer; a `LEG1` file left over from an earlier build decodes
            // fine and gets a page-aligned copy like a network tile.
            aligned: header.isPageAligned ? AlignedSamples(file: mapped, sampleOffset: header.sampleOffset) : nil
        )
```

`shade(_:margin:)` needs no change (it passes no `mapped`).

- [ ] **Step 4: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro,RasterStorage,InteractiveAnalysis ./Tools/run-harness.sh`
Expected: `0 FAIL`. B8 (provider memory) and C9 (memory pressure) count bytes: if either asserts an exact figure
that the second plane moves, re-derive the figure in the check from `CachedTile`'s new accounting (the plane twice)
rather than loosening it.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile provider: fetched tiles are held page-aligned for zero-copy shading, and the budget counts the pages"
```

---

### Task 11: Tile building off the provider actor; the robust range on first need

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`CachedTile` extent, `elevationRange(in:)`, `microPipelineImage` fallback surface, `diskTile`, `fetchedTile`, `shade`, `fetchTerrariumRaster`, `FetchedRaster`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the check**

Add, and register `await checkElevationExtentOnFirstNeed()`:

```swift
/// T10. The robust (2nd/98th percentile) extent was computed for every tile on the actor although only the
/// `.elevation` style and the REM's fallback surface read it; the encode/decode copies and the Terrarium crop ran there
/// too. The extent is computed on first need now and the rest runs detached. This pins the extent's answer.
@MainActor
private func checkElevationExtentOnFirstNeed() async {
    print("\n--- T10. the robust elevation extent is computed when asked for, and the tile builds off the actor ---")
    // The mound 30 m west of the east seam sits inside the centre tile (its radius is ~16 m), covering ~14 % of it,
    // so the 98th percentile rises above the 120 m ground. East of the seam it would not be in this tile at all.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    check("setup: the tile shades", await scene.image() != nil)
    let range = await scene.provider.elevationRange(in: scene.region())
    check("the visible range reads the flat ground as its floor and the mound above it",
          range.map { $0.lowerBound == 120 && $0.upperBound > 120 && $0.upperBound <= 122.8 } ?? false, "\(String(describing: range))")
    check("asked twice, the same", await scene.provider.elevationRange(in: scene.region()) == range)
}
```

- [ ] **Step 2: Run it**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: passes already (guard).

- [ ] **Step 3: The extent on first need**

In `CachedTile`, replace the `elevationLow`/`elevationHigh` properties and their doc with:

```swift
        /// Robust (2nd/98th percentile) elevation extent, computed on first need (``TerrainTileProvider/elevationExtent(for:)``):
        /// only the `.elevation` style's visible range and the REM's fallback surface read it, and computing it for
        /// every tile sampled and sorted 2048 floats on the actor per arrival.
        var elevationExtent: ClosedRange<Float>?
```

Delete the three lines in `CachedTile.init` that computed `extent` and assigned `elevationLow`/`elevationHigh`.

Add to the provider, before `elevationRange(in:)`:

```swift
    /// The robust elevation extent of a cached tile, computed on first need and kept with the entry.
    private func elevationExtent(for key: String) -> ClosedRange<Float>? {
        guard let tile = cache[key] else { return nil }
        if let extent = tile.elevationExtent { return extent }
        let extent = ReliefRenderer.robustRange(of: tile.grid.samples)
        cache[key]?.elevationExtent = extent
        return extent
    }
```

Replace `elevationRange(in:)` with:

```swift
    public func elevationRange(in region: GeoRegion) -> ClosedRange<Float>? {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for key in Array(cache.keys) {
            guard let r = cache[key]?.displayRegion,
                  r.minLatitude <= region.maxLatitude, r.maxLatitude >= region.minLatitude,
                  r.minLongitude <= region.maxLongitude, r.maxLongitude >= region.minLongitude,
                  let extent = elevationExtent(for: key)
            else { continue }
            if extent.lowerBound.isFinite { low = min(low, extent.lowerBound) }
            if extent.upperBound.isFinite { high = max(high, extent.upperBound) }
        }
        guard low <= high else { return nil }
        return low...high
    }
```

In `microPipelineImage`, replace `fallbackSurface: settings.elevationRange?.lowerBound ?? tile.elevationLow,` with
`fallbackSurface: settings.elevationRange?.lowerBound ?? elevationExtent(for: "\(z)/\(x)/\(y)")?.lowerBound ?? 0,`.

- [ ] **Step 4: Build tiles off the actor**

Mark the two value types `Sendable`: `private struct FetchedRaster: Sendable` and
`private struct CachedTile: @unchecked Sendable` (its `rendered: CGImage?` is set only on the actor; the struct
crosses only freshly built, before any mutation).

Add the helper to the provider (near `offActor`'s first use, after `queueGridWrite`):

```swift
    /// Runs `work` off this actor on the cooperative pool, at the priority of the tiles on screen. For the CPU a tile
    /// costs before it can be shaded: on the actor a burst's two 1 MB copies, decode and crop per tile ran one at a
    /// time and held every cache-hit request behind them. Only `Sendable` values go in and out.
    private nonisolated static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
```

Replace `diskTile`'s tail (from `guard !coveredLocally` to the end) with:

```swift
        let coveredLocally = localSources.contains { $0.intersects(region) }
        guard !coveredLocally, let mapped = await gridCache.map(forKey: gridKey) else { return nil }
        return await Self.offActor {
            guard let header = ElevationGridCoder.decodeHeader(mapped.bytes),
                  let decoded = ElevationGridCoder.decode(mapped.bytes) else { return nil }
            return CachedTile(
                grid: decoded.grid,
                source: decoded.source,
                margin: margin,
                // Only a page-aligned payload can back a Metal buffer; a `LEG1` file left over from an earlier build
                // decodes fine and gets a page-aligned copy like a network tile.
                aligned: header.isPageAligned ? AlignedSamples(file: mapped, sampleOffset: header.sampleOffset) : nil
            )
        }
    }
```

Replace `fetchedTile` and delete `shade(_:margin:)`:

```swift
    /// A tile's raster fetched from its sources (``fetchRaster(x:y:z:region:pixels:margin:)``), built into its cache
    /// entry off the actor, and queued for the disk tile cache where it is worth keeping there.
    private func fetchedTile(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int
    ) async -> CachedTile? {
        let margin = Self.marginPixels
        guard let fetched = await fetchRaster(
            x: x, y: y, z: z, region: region, pixels: pixels, margin: margin
        ) else { return nil }
        guard !Task.isCancelled else { return nil }

        let keep = Self.isWorthCachingOnDisk(source: fetched.source, z: z)
        let built = await Self.offActor { () -> (tile: CachedTile, encoded: Data?) in
            (CachedTile(grid: fetched.padded, source: fetched.source, margin: margin),
             keep ? ElevationGridCoder.encode(fetched.padded, source: fetched.source) : nil)
        }
        if let encoded = built.encoded {
            queueGridWrite(encoded, forKey: Self.gridCacheKey(x: x, y: y, z: z, pixels: pixels, margin: margin))
        }
        return built.tile
    }
```

In `fetchTerrariumRaster`, replace everything from `guard let ancestor = ancestorGrid else { return nil }` to the end
of the method with:

```swift
        guard let ancestor = ancestorGrid else { return nil }
        // The pad or crop loops run off the actor: ~70K sample moves per tile that held the burst's other requests.
        return await Self.offActor {
            Self.terrariumRaster(from: ancestor, x: x, y: y, scale: scale, region: region, margin: margin, source: source)
        }
    }

    /// A tile's padded raster cut from its Terrarium ancestor: the ancestor itself, padded by replication, when the
    /// tile is the ancestor (`scale == 1`); otherwise the tile's share of it with the skirt taken from the ancestor
    /// directly, so there are no replication seams. Pure.
    private nonisolated static func terrariumRaster(
        from ancestor: ElevationGrid, x: Int, y: Int, scale: Int, region: GeoRegion, margin: Int, source: String
    ) -> FetchedRaster? {
        if scale == 1 {
            // padByReplication and cropped(margin:) inset and outset by the
            // same Web Mercator span, so the entry recovers `ancestor` exactly.
            return FetchedRaster(padded: padByReplication(ancestor, margin: margin), source: source)
        }

        let childCol = x % scale
        let childRow = y % scale
        let x0 = childCol * ancestor.width / scale
        let x1 = (childCol + 1) * ancestor.width / scale
        let y0 = childRow * ancestor.height / scale
        let y1 = (childRow + 1) * ancestor.height / scale
        let w = x1 - x0
        let h = y1 - y0
        guard w >= 2, h >= 2 else { return nil }

        let paddedW = w + margin * 2
        let paddedH = h + margin * 2
        var paddedSamples = [Float](repeating: .nan, count: paddedW * paddedH)
        for py in 0..<paddedH {
            let ay = min(max(y0 - margin + py, 0), ancestor.height - 1)
            let srcRow = ay * ancestor.width
            let dstRow = py * paddedW
            for px in 0..<paddedW {
                let ax = min(max(x0 - margin + px, 0), ancestor.width - 1)
                paddedSamples[dstRow + px] = ancestor.samples[srcRow + ax]
            }
        }

        let m = region.mercatorBounds
        let spanX = m.maxX - m.minX
        let spanY = m.maxY - m.minY
        let padX = spanX * Double(margin) / Double(w)
        let padY = spanY * Double(margin) / Double(h)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX - padX, y: m.minY - padY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX + padX, y: m.maxY + padY)
        let paddedRegion = GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
        return FetchedRaster(
            padded: ElevationGrid(width: paddedW, height: paddedH, samples: paddedSamples, region: paddedRegion),
            source: source
        )
    }
```

- [ ] **Step 5: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro,InteractiveAnalysis,Harvester ./Tools/run-harness.sh`
Expected: `0 FAIL`. If the compiler rejects `CachedTile` crossing the detached boundary, the `@unchecked Sendable`
from Step 4 is missing; if it rejects `mapped` inside the closure, `MappedFile` is already `@unchecked Sendable`, so
check the capture list.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile provider: build tiles off the actor; the robust extent on first need"
```

---

### Task 12: Stale tiles reach the renderer on every outcome, pushed as well as pulled

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (provider: sink state, `store()`; renderer: `request`, `registerVisibleKeysSource`, new `redrawStale`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await checkStaleTilesArePushed()`:

```swift
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
    check("the centre tile is pushed once its neighbour lands", pushed.withLock { $0 }.contains(centre), "\(pushed.withLock { $0 })")
    check("what was pushed is not also held for a pull", await scene.provider.takeStaleTiles().isEmpty)
    await scene.provider.setStaleTilesSink(nil)
}
```

(`settleStaleTiles()` lands in Task 13; until then add it as a no-op `public func settleStaleTiles() {}` next to
`takeStaleTiles()` so this task compiles, and let Task 13 give it its body.)

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: does not compile (`setStaleTilesSink` undefined).

- [ ] **Step 3: The provider pushes**

Add to the provider after `takeStaleTiles()`:

```swift
    /// Where stale tiles are pushed as they settle: the renderer, which marks and redraws them. With none set they
    /// wait for ``takeStaleTiles()``. Pushed, because the pull after a load is not enough: a tile upgraded from a
    /// stand-in (``completeUpgrade``), or made stale by the last load in flight, has nothing coming to pull it.
    private var staleTilesSink: (@Sendable ([String]) -> Void)?

    public func setStaleTilesSink(_ sink: (@Sendable ([String]) -> Void)?) { staleTilesSink = sink }

    /// Hands the stale set to the sink, if there is one.
    private func publishStaleTiles() {
        guard let sink = staleTilesSink, !staleTiles.isEmpty else { return }
        let keys = Array(staleTiles)
        staleTiles.removeAll()
        sink(keys)
    }

    public func settleStaleTiles() {}   // Task 13 gives this its body.
```

At the end of `store(_:for:)`, after the neighbour loop, add `publishStaleTiles()`.

- [ ] **Step 4: The renderer registers its sink and drains on every outcome**

In `registerVisibleKeysSource()`, inside the `Task { ... }` that sets the sources, add
`await provider.setStaleTilesSink { handle.renderer?.redrawStale($0) }`.

Add to the renderer, after `cullTiles`:

```swift
    /// Marks `keys` stale in the store and invalidates their rects, so MapKit asks for them again while they keep
    /// drawing their old image. The provider pushes keys here as they settle; the pull after each load is the backstop
    /// for the first loads, before the sink is registered.
    func redrawStale(_ keys: [String]) {
        for staleKey in store.markStale(keys) {
            if let stalePath = Self.path(forKey: staleKey) {
                setNeedsDisplay(TerrainTileOverlay.mapRect(for: stalePath))
            }
        }
    }
```

Replace the body of `request(_:zoomScale:)` from `let handle = WeakRenderer(renderer: self)` to the end with:

```swift
        registerVisibleKeysSource()
        let handle = WeakRenderer(renderer: self)
        let task = Task { [store] in
            let image = await provider.tileImage(
                x: path.x, y: path.y, z: path.z, region: region, pixels: pixels
            )
            let outcome = store.finishLoad(key, image: image, ticket: ticket)
            switch outcome {
            case .dropped:
                break
            case .failed:
                // The superseded image was released: redraw so MapKit stops showing it.
                handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: path), zoomScale: zoomScale)
            case .drawn, .drawnButStale:
                handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: path), zoomScale: zoomScale)
                if outcome == .drawnButStale {
                    handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: path))
                }
            }
            // Whatever became of this load, the tiles its raster made stale are redrawn: a load dropped or failed used
            // to return before this, and when it was the last in flight its neighbours kept the seam for good.
            handle.renderer?.redrawStale(await provider.takeStaleTiles())
        }
        store.recordTask(task, for: key, ticket: ticket)
    }
```

- [ ] **Step 5: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro ./Tools/run-harness.sh`
Expected: `0 FAIL`. B13/B14 drive the real renderer and now register a sink; with Task 13 not yet in, `store()`
publishes at once, so nothing they assert changes.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Terrain renderer: stale tiles are pushed by the provider and drained after every load"
```

---

### Task 13: A settle window for neighbour staleness

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (provider: state, `store()`, `update()`, `settleStaleTiles()`)
- Modify: `Tools/ViewerHarness/ProviderMicroChecks.swift` (B5 ~543, B10 ~617, B18 ~1600, B20 ~1709)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `await checkStaleSettleWindow()`:

```swift
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
    let centre = "\(scene.z)/\(scene.x)/\(scene.y)"
    await scene.image()
    await scene.image(dx: 1)
    check("right after the neighbour lands, nothing is stale yet (the window is \(TerrainTileProvider.staleSettleWindow))",
          await scene.provider.takeStaleTiles().isEmpty)
    check("and the centre tile's bitmap is still held, so a re-request draws the old picture",
          await scene.provider.renderedTileKeys().contains(centre))
    await scene.image(dy: 1)
    await scene.provider.settleStaleTiles()
    let stale = await scene.provider.takeStaleTiles()
    check("once settled, the centre tile is stale exactly once for its two neighbours", stale.filter { $0 == centre }.count == 1, "\(stale)")
    check("and its bitmap has gone, so the re-request shades it again", await !scene.provider.renderedTileKeys().contains(centre))
    check("settling twice adds nothing", await scene.provider.takeStaleTiles().isEmpty)
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: does not compile (`staleSettleWindow` undefined); after adding only that constant, `FAIL  right after the neighbour lands, nothing is stale yet`.

- [ ] **Step 3: The window**

Add to the provider's state, after `private var staleTiles: Set<String> = []`:

```swift
    /// Tiles whose neighbourhood changed since they were shaded, waiting for the burst to quiet before they are
    /// re-shaded (``settleStaleTiles()``). Their bitmaps stay drawn meanwhile.
    private var pendingStaleTiles: Set<String> = []
    private var staleSettle: Task<Void, Never>?

    /// How long after the first neighbour of a burst lands the stale tiles are re-shaded. A viewport's tiles land
    /// over a few hundred milliseconds; re-shading each tile as every one of its neighbours arrived shaded it up to
    /// nine times for one settled picture and threw away its renders in flight. One window per burst re-shades each
    /// tile about once, and 150 ms is under what the eye needs to notice the seam it fixes.
    public nonisolated static let staleSettleWindow: Duration = .milliseconds(150)
```

In `store(_:for:)`, replace the neighbour loop body (from `guard cache[neighbourKey] != nil else { continue }` to
the loop's end) and the `publishStaleTiles()` added in Task 12 with:

```swift
                guard cache[neighbourKey] != nil else { continue }
                // Counted now: a render of the neighbour in flight read a partial neighbourhood and its picture must
                // not be kept (tileImage checks the revision). Re-shaded later, with the burst (``settleStaleTiles``).
                cache[neighbourKey]?.neighbourRevision += 1
                pendingStaleTiles.insert(neighbourKey)
            }
        }
        scheduleStaleSettle()
```

Replace the Task 12 placeholder `settleStaleTiles()` and add the scheduler, after `publishStaleTiles()`:

```swift
    /// Starts the settle window if none is running and something waits on it.
    private func scheduleStaleSettle() {
        guard staleSettle == nil, !pendingStaleTiles.isEmpty else { return }
        staleSettle = Task { [weak self] in
            try? await Task.sleep(for: Self.staleSettleWindow)
            await self?.settleStaleTiles()
        }
    }

    /// Moves the tiles waiting on the settle window to the stale set now, dropping their bitmaps, and pushes them to
    /// the renderer where one is registered. The window's own end, and the harness's way past the wait.
    public func settleStaleTiles() {
        staleSettle?.cancel()
        staleSettle = nil
        for key in pendingStaleTiles where cache[key] != nil {
            cache[key]?.rendered = nil
            renderedOrder.removeAll { $0 == key }
            staleTiles.insert(key)
        }
        pendingStaleTiles.removeAll()
        publishStaleTiles()
    }
```

In `update(_:)`, after `staleTiles.removeAll()`, add `pendingStaleTiles.removeAll()` (a shading change re-shades
everything anyway).

- [ ] **Step 4: Teach the four existing checks to settle first**

In `Tools/ViewerHarness/ProviderMicroChecks.swift`:

- B5 (around line 543): before `let stale = await scene.provider.takeStaleTiles()` insert `await scene.provider.settleStaleTiles()`.
- B10 (around line 617): change `let stale = store.markStale(await provider.takeStaleTiles())` to
  `await provider.settleStaleTiles()` on its own line followed by the unchanged `let stale = ...`.
- B18 (around line 1600): before `stale = await scene.provider.takeStaleTiles()` insert `await scene.provider.settleStaleTiles()`.
- B20 (around line 1709): before `let stale = await scene.provider.takeStaleTiles()` insert `await scene.provider.settleStaleTiles()`.

- [ ] **Step 5: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro ./Tools/run-harness.sh`
Expected: `0 FAIL`. B18 still reproduces its race (the revision bump is unchanged) and its second render still
stitches the neighbour in.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/ProviderMicroChecks.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile provider: neighbour staleness settles once per burst behind a 150 ms window"
```

---

### Task 14: A prompt Terrarium answer while the native fetch finishes behind it

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (provider: constants and state, `loadTile`, `fetchedTile`, `fetchRaster`, `fetchRemoteRaster`, new `completeUpgrade`, `clear()`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

Design. At z16+ the native source is `FallbackElevationProvider(COG, ImageServer)`: about 1 s cold where a COG covers
the tile, 12-25 s where the ImageServer must answer, and the map showed a z15 placeholder throughout. The native
fetch now races a budget (`promptAnswerBudget`, 2 s). Answered in time, nothing changes. Otherwise the tile is built
from its Terrarium ancestor at once, with a source string carrying `upgradingSuffix` (which contains "fallback", so
it is never written to disk), and the native fetch keeps running as an upgrade: when it lands, the raster is written
to disk, replaces the stand-in in the memory cache if it is still there, and the tile is marked stale so the renderer
re-shades it from the real ground. Only the map path (`loadTile`) asks promptly: the read-back, the harvester and the
local-file merge want the real raster or nothing. At most `upgradeLimit` upgrades run at once; past it the tile waits
as before.

- [ ] **Step 1: Write the failing check**

Add, and register `await checkPromptAnswerThenUpgrade()`:

```swift
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
    check("and reads the stand-in's ground meanwhile", await provider.elevation(at: region.center).map { abs($0 - 200) < 1 } ?? false)

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
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: `FAIL  the tile is answered from Terrarium within the budget ... 3.0x seconds`, and the stand-in and push checks fail.

- [ ] **Step 3: Constants and state**

Add to the provider's state, after the stale-settle state from Task 13:

```swift
    /// How long a z16+ tile waits for its native source before the map is shown its Terrarium ancestor and the native
    /// raster is finished behind it (``completeUpgrade``). The COG path answers in about a second cold; the ImageServer
    /// behind it takes 10-18 s for a novel extent, and that wait showed as a z15 placeholder.
    public nonisolated static let promptAnswerBudget: Duration = .seconds(2)
    /// Native fetches still running for tiles the map was shown a stand-in for, by tile key.
    private var upgrades: [String: Task<Void, Never>] = [:]
    /// At most this many at once: a flick across uncovered ground must not queue a hundred 12 s ImageServer requests.
    nonisolated static let upgradeLimit = 8
    /// What a stand-in's source ends with. Contains "fallback", so ``isCacheableSource(_:)`` keeps it off the disk.
    nonisolated static let upgradingSuffix = " (fallback to terrarium, upgrading)"

    private enum PromptAnswer: Sendable {
        case answered(ElevationGrid?)
        case budgetRanOut
    }
```

- [ ] **Step 4: Thread `promptly` from the map path to the remote fetch**

`loadTile`: change `return await fetchedTile(x: x, y: y, z: z, region: region, pixels: pixels)` to
`return await fetchedTile(x: x, y: y, z: z, region: region, pixels: pixels, promptly: true)`.

`fetchedTile`: add the parameter `promptly: Bool = false` after `pixels: Int`, and pass it on:
`await fetchRaster(x: x, y: y, z: z, region: region, pixels: pixels, margin: margin, promptly: promptly)`.
(`fetchForReadBack` calls `fetchedTile` without it and so gets the real raster or nothing, as before.)

`fetchRaster`: add `promptly: Bool = false` after `margin: Int`; pass it to the first `fetchRemoteRaster` call (no
local file); leave the merge branch's call without it (a stand-in merged into a local file's raster would be replaced
whole by the upgrade, losing the file's part).

- [ ] **Step 5: The race, the stand-in and the upgrade**

Replace `fetchRemoteRaster` with:

```swift
    /// A tile's padded raster from whichever remote source suits its zoom.
    ///
    /// `promptly`: the map is waiting. Past ``promptAnswerBudget`` the tile's Terrarium ancestor is returned as a
    /// stand-in and the native fetch runs on as an upgrade (``completeUpgrade``). Off, the native answer is awaited.
    private func fetchRemoteRaster(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int, margin: Int, promptly: Bool = false
    ) async -> FetchedRaster? {
        if z < Self.nativeDetailZ {
            return await fetchTerrariumRaster(
                x: x, y: y, z: z, region: region, margin: margin,
                source: Self.sourceName(forZ: z)
            )
        }

        // Native-resolution path: fetch a real skirt in Web Mercator rather than inventing one.
        let expanded = Self.paddedRegion(region, pixels: pixels, margin: margin)
        let samples = pixels + margin * 2
        let key = "\(z)/\(x)/\(y)"
        let native = Task { [elevation] in await elevation.elevation(for: expanded, targetSamples: samples).value }

        let answer: PromptAnswer
        if promptly, upgrades[key] == nil, upgrades.count < Self.upgradeLimit {
            answer = await Self.first(of: native, within: Self.promptAnswerBudget)
        } else {
            answer = .answered(await native.value)
        }
        // If the task was cancelled (user panned away), don't waste
        // resources fetching a fallback tile for a discarded viewport.
        guard !Task.isCancelled else {
            native.cancel()
            return nil
        }

        switch answer {
        case .answered(let grid?):
            return FetchedRaster(padded: grid, source: Self.sourceName(forZ: z))
        case .answered(nil):
            // Graceful degradation: when 3DEP fails (network timeout, error,
            // or void/outside coverage), fall back to upsampling from the
            // Terrarium ancestor at maximumZ so MapKit doesn't leave a hole.
            return await fetchTerrariumRaster(
                x: x, y: y, z: z, region: region, margin: margin,
                source: "\(Self.sourceName(forZ: z)) (fallback to terrarium)"
            )
        case .budgetRanOut:
            // Show the ancestor now; finish the native raster behind it. With no ancestor either, wait as before.
            guard let standIn = await fetchTerrariumRaster(
                x: x, y: y, z: z, region: region, margin: margin,
                source: "\(Self.sourceName(forZ: z))\(Self.upgradingSuffix)"
            ) else {
                guard let grid = await native.value, !Task.isCancelled else { return nil }
                return FetchedRaster(padded: grid, source: Self.sourceName(forZ: z))
            }
            upgrades[key] = Task { [weak self] in
                let grid = await native.value
                await self?.completeUpgrade(x: x, y: y, z: z, pixels: pixels, margin: margin, key: key, grid: grid)
            }
            return standIn
        }
    }

    /// `native`'s answer if it comes within `budget`, else `.budgetRanOut`; the task runs on either way.
    ///
    /// Not a task group: awaiting a `Task`'s value is not interrupted by cancellation, so a group racing it against a
    /// sleep would wait for the fetch regardless. A continuation resumed once, by whichever finishes first.
    private nonisolated static func first(of native: Task<ElevationGrid?, Never>, within budget: Duration) async -> PromptAnswer {
        let gate = OSAllocatedUnfairLock<CheckedContinuation<PromptAnswer, Never>?>(initialState: nil)
        @Sendable func settle(_ answer: PromptAnswer) {
            let taken: CheckedContinuation<PromptAnswer, Never>? = gate.withLock { held in
                let continuation = held
                held = nil
                return continuation
            }
            taken?.resume(returning: answer)
        }
        return await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
            let timer = Task {
                try? await Task.sleep(for: budget)
                settle(.budgetRanOut)
            }
            Task {
                settle(.answered(await native.value))
                timer.cancel()
            }
        }
    }

    /// The native raster for a tile shown a stand-in has landed: keep it for the disk, replace the stand-in where the
    /// tile is still held, and have the renderer re-shade it (and, as for any arrival, its neighbours).
    private func completeUpgrade(x: Int, y: Int, z: Int, pixels: Int, margin: Int, key: String, grid: ElevationGrid?) async {
        upgrades[key] = nil
        guard let grid else { return }
        let source = Self.sourceName(forZ: z)
        let keep = Self.isWorthCachingOnDisk(source: source, z: z)
        let built = await Self.offActor { () -> (tile: CachedTile, encoded: Data?) in
            (CachedTile(grid: grid, source: source, margin: margin),
             keep ? ElevationGridCoder.encode(grid, source: source) : nil)
        }
        if let encoded = built.encoded {
            queueGridWrite(encoded, forKey: Self.gridCacheKey(x: x, y: y, z: z, pixels: pixels, margin: margin))
        }
        // Only a stand-in is replaced: a raster another path has put under the key meanwhile (a mounted file, a
        // reload) stands. A stand-in evicted meanwhile is simply gone; the disk now has the real raster for its return.
        guard let held = cache[key], held.source.hasSuffix(Self.upgradingSuffix) else { return }
        store(built.tile, for: key)
        pendingStaleTiles.insert(key)
        scheduleStaleSettle()
    }
```

In `clear()`, after `cache.removeAll()`, add:

```swift
        for upgrade in upgrades.values { upgrade.cancel() }
        upgrades.removeAll()
```

- [ ] **Step 6: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro,OfflineStore,Harvester ./Tools/run-harness.sh`
Expected: `0 FAIL`. B15 (superseded terrain), B19 (read-back), S3 and the harvester checks use stubs that answer at
once, so the budget never runs out for them; `SlowElevationStub` in `core` delays by milliseconds, well under it.
Run `HARNESS_ONLY=core` too.

- [ ] **Step 7: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Tile provider: a slow native source is shown from Terrarium within 2 s and upgraded when it lands"
```

---

### Task 15: The renderer culls from paths parsed once, not per frame

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`TileImageStore`: `paths`, `beginLoad`, `finishLoad`, `cancel`, `evict`, `invalidate(retainingWhere:)`, new `inFlightEntries`; renderer: `cullTiles`, `trimForMemoryWarning`, `shouldCancel`, `shouldKeep`)
- Test: `Tools/ViewerHarness/TileLoadingChecks.swift`

- [ ] **Step 1: Write the failing check**

Add, and register `checkCullingUsesParsedPaths()` (synchronous: `checkCullingUsesParsedPaths()` without `await`):

```swift
/// T14. `cullTiles` runs on every region-change frame and re-parsed every held key (split, three Int parses, a rect)
/// with a throwaway one-element array per in-flight key, holding the store's lock through the eviction pass. The store
/// now keeps each key's path from the claim, and the predicates take a path.
@MainActor
private func checkCullingUsesParsedPaths() {
    print("\n--- T14. culling reads paths parsed once at claim time ---")
    let store = TileImageStore()
    let key = "19/5/5"
    guard let ticket = store.beginLoad(key) else { check("setup: the key is claimed", false); return }
    let entries = store.inFlightEntries()
    check("an in-flight entry carries its parsed path", entries.count == 1 && entries[0].key == key
          && entries[0].path.map { $0.z == 19 && $0.x == 5 && $0.y == 5 } == true)
    _ = store.finishLoad(key, image: onePixelImage(), ticket: ticket)
    var seen: [String: MKTileOverlayPath?] = [:]
    _ = store.evict(where: { k, p in seen[k] = p; return false })
    check("eviction sees the drawn key's path", seen[key]??.z == 19)
    let released = store.evict(where: { _, _ in true })
    check("the path goes with the image", released == 1 && store.inFlightEntries().isEmpty && store.imageKeys().isEmpty)

    let z = 19, bx = 140_000, by = 206_000
    let visible = TerrainTileOverlay.mapRect(for: MKTileOverlayPath(x: bx, y: by, z: z, contentScaleFactor: 2))
    for (dx, cancelled) in [(0, false), (1, false), (50, true)] {
        let path = MKTileOverlayPath(x: bx + dx, y: by, z: z, contentScaleFactor: 1)
        check("shouldCancel over a path agrees with the key form (dx \(dx))",
              TerrainTileOverlayRenderer.shouldCancel(path, visible: visible, drawnLevels: z...z) == cancelled
              && TerrainTileOverlayRenderer.shouldCancel("\(z)/\(bx + dx)/\(by)", visible: visible, drawnLevels: z...z) == cancelled)
    }
}
```

- [ ] **Step 2: Run it red**

Run: `HARNESS_ONLY=TileLoading ./Tools/run-harness.sh`
Expected: does not compile (`inFlightEntries`, the two-argument `evict`, `shouldCancel(_ path:)`).

- [ ] **Step 3: The store keeps paths**

In `TileImageStore`, add after `private var inFlightTasks`:

```swift
    /// Each key's tile path, parsed once when it is claimed and kept while the key is drawn or in flight: what the
    /// renderer's per-frame culling reads instead of parsing every key again.
    private var paths: [String: MKTileOverlayPath] = [:]

    /// Drops the parsed path of a key that is neither drawn nor in flight. Under the lock.
    private func forgetPathIfUnused(_ key: String) {
        if images[key] == nil, inFlight[key] == nil { paths.removeValue(forKey: key) }
    }
```

In `beginLoad`, after `inFlight[key] = Claim(...)`, add:

```swift
        if paths[key] == nil, let path = TerrainTileOverlayRenderer.path(forKey: key) { paths[key] = path }
```

In `finishLoad`, replace the `guard let image else { ... }` block with the one below, so a nil result that leaves
the key neither drawn nor in flight also drops its path. (The earlier `guard let claim ... else { return .dropped }`
is untouched: that claim was not this one's, and the key is still owned by another.)

```swift
        guard let image else {
            guard superseded.remove(key) != nil else {
                forgetPathIfUnused(key)
                return .dropped
            }
            images.removeValue(forKey: key)
            staleMarks.removeValue(forKey: key)
            forgetPathIfUnused(key)
            return .failed
        }
```

In `cancel`, after `cancelledClaimIDs.insert(claim.id)`, add `forgetPathIfUnused(key)`.

Add after `inFlightKeys()`:

```swift
    /// Keys with a load in flight right now, each with its path as parsed at claim time (nil for a key that does not parse).
    func inFlightEntries() -> [(key: String, path: MKTileOverlayPath?)] {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.keys.map { ($0, paths[$0]) }
    }
```

Replace `evict(where:)` with:

```swift
    /// Releases every drawn image `release` names, with its stale mark, and returns how many went. Loads in
    /// flight are left alone: culling decides those. The decision runs under the store's lock, so a tile that
    /// lands meanwhile is judged too rather than thrown away unseen. `release` is handed the key's parsed path, so
    /// the pass costs no parsing under the lock.
    @discardableResult
    func evict(where release: (String, MKTileOverlayPath?) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let doomed = images.keys.filter { release($0, paths[$0]) }
        for key in doomed {
            images.removeValue(forKey: key)
            superseded.remove(key)
            if inFlight[key] == nil { staleMarks.removeValue(forKey: key) }
            forgetPathIfUnused(key)
        }
        return doomed.count
    }
```

In `invalidate(retainingWhere:)`, after `images = images.filter { keep($0.key) }`, add
`paths = paths.filter { images[$0.key] != nil || inFlight[$0.key] != nil }`.

- [ ] **Step 4: The renderer's predicates take paths**

Add path forms of the two predicates and make the key forms thin wrappers. Replace `shouldCancel(_ key:...)` with:

```swift
    /// Whether a load in flight is worth stopping: its tile lies a whole viewport beyond the screen (see
    /// ``keysOutside(_:from:margin:)``), or at a level MapKit no longer draws and no placeholder needs. Over
    /// the same ground after a zoom-out, position alone would let each such load run its fetch to the end and
    /// then hold the image.
    nonisolated static func shouldCancel(_ path: MKTileOverlayPath, visible: MKMapRect, drawnLevels: ClosedRange<Int>?) -> Bool {
        let grown = visible.insetBy(dx: -visible.size.width, dy: -visible.size.height)
        if !intersectsWrapped(TerrainTileOverlay.mapRect(for: path), grown) { return true }
        guard let drawnLevels else { return false }
        return path.z > drawnLevels.upperBound || path.z < drawnLevels.lowerBound - placeholderLevels
    }

    /// The key form. A key that does not parse is kept.
    nonisolated static func shouldCancel(_ key: String, visible: MKMapRect, drawnLevels: ClosedRange<Int>?) -> Bool {
        guard let path = path(forKey: key) else { return false }
        return shouldCancel(path, visible: visible, drawnLevels: drawnLevels)
    }
```

Replace `shouldKeep(_ key:...)` with:

```swift
    /// Whether a drawn tile is worth its surface: it lies within `margin` viewports of `visible`, and at
    /// `drawnLevels` or up to ``placeholderLevels`` coarser than the coarsest of them.
    ///
    /// MapKit only asks for the level it is drawing, so a tile at any other level is never re-requested and,
    /// once kept, would be kept for good. A finer tile under the view after a zoom-out is never drawn, so it
    /// goes. A coarser one is what the renderer draws, cropped, while the level being drawn is still loading.
    /// Without a rect or a level that test is skipped: before the first region change, every tile held came
    /// from the one view shown.
    nonisolated static func shouldKeep(
        _ path: MKTileOverlayPath, visible: MKMapRect?, drawnLevels: ClosedRange<Int>?, margin: Double
    ) -> Bool {
        if let drawnLevels, path.z > drawnLevels.upperBound || path.z < drawnLevels.lowerBound - placeholderLevels {
            return false
        }
        guard let visible else { return true }
        let grown = visible.insetBy(dx: -visible.size.width * margin, dy: -visible.size.height * margin)
        return intersectsWrapped(TerrainTileOverlay.mapRect(for: path), grown)
    }

    /// The key form. A key that does not parse is not kept.
    nonisolated static func shouldKeep(
        _ key: String, visible: MKMapRect?, drawnLevels: ClosedRange<Int>?, margin: Double
    ) -> Bool {
        guard let path = path(forKey: key) else { return false }
        return shouldKeep(path, visible: visible, drawnLevels: drawnLevels, margin: margin)
    }
```

In `cullTiles`, replace the cancel loop and the evict call with:

```swift
        var cancelled = 0
        for entry in store.inFlightEntries() {
            guard let path = entry.path, Self.shouldCancel(path, visible: visible, drawnLevels: levels) else { continue }
            if store.cancel(entry.key) { cancelled += 1 }
        }
        // Drawn tiles the view has left, or at a level MapKit no longer draws, give their surfaces back now
        // rather than at the next shading change, which may never come. A key that does not parse is not kept.
        let released = store.evict(where: { _, path in
            guard let path else { return true }
            return !Self.shouldKeep(path, visible: visible, drawnLevels: levels, margin: Self.keepMargin)
        })
```

In `trimForMemoryWarning`, replace the evict call with:

```swift
        let released = store.evict(where: { _, path in
            guard let path else { return true }
            return !Self.shouldKeep(path, visible: rect, drawnLevels: levels, margin: 0)
        })
```

- [ ] **Step 5: Run green**

Run: `HARNESS_ONLY=TileLoading,ProviderMicro ./Tools/run-harness.sh`
Expected: `0 FAIL`. B11 and B13 use the key forms of `keysOutside`, `keysToKeep` and `shouldKeep`, which are unchanged in behaviour.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/TileLoadingChecks.swift
git commit -m "Terrain renderer: cull from paths parsed once at claim time"
```

---

### Task 16: Full gates and the record

**Files:**
- Modify: `docs/superpowers/plans/2026-10-26-tile-loading-responsiveness.md` (the Status block and a Verification table)
- Modify: `STATUS.md` (the harness and build rows)

- [ ] **Step 1: Full harness**

Run: `./Tools/run-harness.sh 2>&1 | tee build-review/tl-full.log`
Expected: `ALL CHECKS PASSED`, PASS count 1721 plus the new T1-T14 checks (about 45), `0 FAIL`.

- [ ] **Step 2: Simulator build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project LidarExplorer.xcodeproj \
  -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPad Pro 11-inch (M5)" \
  -derivedDataPath build-review/DerivedData build 2>&1 | tee build-review/tl-sim.log | grep -E "warning:|error:|BUILD"
```

Expected: `BUILD SUCCEEDED`, no `warning:` lines from Swift sources. The live check (`Tools/LiveCheck/main.swift`)
is outside both this build and the harness; `Tools/run-live-check.sh` compiles and runs it against the real services
in one go, so it stays unrun and the record says so.

- [ ] **Step 3: Mutation evidence (optional, as the earlier remediations did)**

With Tasks 2, 3, 7, 9, 10, 12, 13, 14 and 15 stashed in turn (`git stash` of the one file, run
`HARNESS_ONLY=TileLoading`, `git stash pop`), T1, T2, T6, T8, T9, T11, T12, T13 and T14 go red respectively. Record
which did in the table below.

- [ ] **Step 4: Record**

Update this file's Status block to: complete, the commit range, the harness count and the build result, and add:

```markdown
## Where the code differs from this text

The snippets above were written without a compiler. What landed differs in these places, each by design or by a
compiler's say; the checks named are the ones that pin the behaviour.

- **The Task 13 compile break (cf0bcd0).** f7fee08 added a diagnostic override of the settle window initialised as
  `private var settleWindow: Duration = Self.staleSettleWindow`, and Swift rejects `Self` in a stored property
  initializer of an actor ("covariant 'Self' type cannot be referenced"); Xcode Cloud's nightly failed on it, and so did
  the first harness and Simulator builds on the Mac. It now names `TerrainTileProvider.staleSettleWindow`. The same
  commit silences the one Swift warning the branch had, from Task 6: a detached task's trailing closure inside a `guard`
  condition is "confusable with the body of the statement", so the decode is bound to a `let` first. Not the
  `[weak self]` settle task the cloud session suspected, which compiles as written.
- **Task 5.** The detached resample captures `let tiles = fetched`, bound before the task: a `var` cannot be captured
  by a `@Sendable` closure.
- **Task 7.** The in-flight map holds a `SharedFetch` (the task and a waiter count) rather than the task alone. A
  waiter's cancellation runs `abandon(key:task:)` through `withTaskCancellationHandler`, and the last waiter to go
  cancels the shared fetch, so a culled tile's request no longer holds one of the host's eight connections for the
  ImageServer's 12-25 s; the transport then answers `.cancelled`, which does not count against the breaker. T6 has two
  checks for this beyond the plan's.
- **Task 10.** A network tile is not copied into aligned pages when it is built. `alignedForShading(_:settings:)`
  makes the copy at the tile's second shade, and only for the styles the fused kernel shades (a micro-topography
  product reads the raster on the CPU and would not adopt it). A tile shaded once, which is most of browsing, holds its
  heap raster alone; a tile re-shaded (a sun-dial drag, a settle) pays the plane once and never the per-shade
  `makeBuffer` and copy again. A disk tile reads the cache file's pages from its first shade, as planned. T9 counts
  shades through `shadeCount(for:)`.
- **Task 11.** The REM's fallback surface reads the memoised extent while the entry is still cached and, after an
  eviction during the awaits, the robust range of the copy in hand; never the plan's constant 0.
- **Task 13.** The settle task returns if it was cancelled before it ran (a newer window may be running). Two
  diagnostics, `setStaleSettleWindow(_:)` and `shadeCount(for:)`, let T12 hold the window open and count the centre
  tile's shades (two, for two neighbours, not three). The harness settles before taking stale tiles in seven checks
  (B5, B10, B17, B18, B20, B22 and C1), not the four the task names.
- **Task 14.** The upgrade task awaits the native fetch under a cancellation handler that cancels it, and
  `completeUpgrade` returns at once when cancelled, so `clear()` stops the ImageServer request and writes nothing to
  disk for a cache that is gone. With no Terrarium ancestor either, a request cancelled meanwhile returns before
  waiting out the native fetch.
- **Task 15.** T14's first check is three bound sub-expressions: the compiler would not type-check the one expression
  the plan wrote.
- **Task 4, left behind.** `MetalTerrainPipelineActor.normalizeNoDataInPlace(_:)` has no callers now that nodata is
  voided on the CPU; it stays until a pass removes it (follow-up below).

## Verification

| Gate | Result |
|---|---|
| `./Tools/run-harness.sh` | 1784 PASS / 0 FAIL, ALL CHECKS PASSED at e78e443 (`build-review/tl-full-final.log`); 1721 on `main` plus the 63 checks of T1-T14. 1783 at e84eaac (`tl-full.log`), 1771 at cf0bcd0 (`tl-full-fix13.log`); f7fee08 did not compile (`tl-full-f7fee08.log`) |
| Simulator build | `xcodebuild` Debug, iPad Pro 11-inch (M5), at e78e443: BUILD SUCCEEDED, no Swift warnings (`build-review/tl-sim-final.log`; the same at e84eaac, `tl-sim.log`). The morning's first build at f7fee08 failed before any Swift compiled: this Xcode-beta (27A5252f) had no Metal Toolchain (`tl-sim-f7fee08.log`), so the Swift was checked with the shader excluded (`EXCLUDED_SOURCE_FILE_NAMES=*.metal`, `tl-sim-nometal-*.log`: f7fee08 failed on the `Self` initializer, cf0bcd0, d33ba93 and e84eaac succeeded); by 11:04 the toolchain was mounted as a system MobileAsset and the final build compiled the shader |
| Mutation | Each task's fix undone in turn at e84eaac, `HARNESS_ONLY=TileLoading` (`build-review/tl-mutant-*.log`; the reverse patch of a task's commit where it still applied, a one-line hand edit where later tasks had rewritten its hunks, since `git stash` of one task is not possible once the file carries the others). Red: T1 with Task 2's header join reverted (8 range GETs against 1); T6 with Task 7 reverted (four checks); T8 with the disk-worth rule's zoom test removed (two); T9 with the second-shade copy never made; T11 with the sink never called (and T13's push); T12 with `store()` settling at once instead of scheduling the window (two); T13 with Task 14's commit reverted (three); T14 does not compile with Task 15's commit reverted (`inFlightEntries` gone). **T2 did not catch its mutant at first:** with the georeference join removed, all 62 checks still passed, because the reader's header single-flight (Task 2) keeps the range-request count at one; e78e443 adds `georeferenceLoads` to the coordinator's statistics and a T2 check that eight concurrent callers parse once, which is red with the join gone (8 against 1). Tasks 4, 5, 6, 8 and 11 move work without changing results and have no mutant, as planned |

## Unverified

- Seen in the Simulator (iPad Pro 11-inch (M5), 9a1017f, 2026-10-26, `build-review/sim-2026-10-26/`): over the Olympic
  peninsula interior (47.80, -123.60; no 1 m COG on The National Map, so the ImageServer must answer) at z18, every
  tile of a pan burst came back at 2,023-2,029 ms as "3DEP 1m (fallback to terrarium, upgrading)" at 3.29 m/px and was
  re-shaded as "3DEP 1m" at 0.20 m/px in 15-45 ms once the ImageServer raster landed, once per tile; 56 fetched, 0
  failed, 0 cancelled, mean 1.89 s; the seam in the stand-in picture 3 s after the pan was gone 18 s after it. Cahokia
  at launch drew its 1 m detail within seconds (the COG path). Not on a device: the figures (2 s, 150 ms, 8 upgrades)
  are untested there, and the Simulator's Metal runs in blit mode.
- The per-shade saving of Task 10 and the memory a re-shaded tile's aligned plane costs on a device.
- Xcode Cloud's nightly, which failed on f7fee08, has not been seen green on the fix.

## Follow-ups (not done)

- Basemap overlay (finding O): an in-memory "nothing harvested" flag to skip the two `ENOENT` opens per tile; a
  renderer-based overzoom in place of the JPEG re-encode.
- The local-file zip-merge in `fetchRaster` still runs on the provider actor.
- `ElevationGrid` could read a disk-loaded tile's samples through its mapping instead of a heap copy, which would
  halve what a cached tile holds; it touches every CPU reader of the grid.
- ~~Remove `MetalTerrainPipelineActor.normalizeNoDataInPlace(_:)`, now that nothing calls it.~~ Done, 9a1017f; the kernel
  stays, since `render` still runs it for a raster flagged `needsNoDataNormalization`. The live check ran the same day:
  69 PASS / 0 FAIL (`build-review/live-check-2026-10-26.log`).
```

In `STATUS.md`, in the "Build & verification status" table, prepend to the harness row's result and the build
row's result a dated entry in the existing style (`✅ Latest, 2026-10-26 at <sha>: ...`), and add one line to the
file's change log naming this plan.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-10-26-tile-loading-responsiveness.md STATUS.md
git commit -m "record: the tile-loading responsiveness pass, its gates and what is unverified"
```

---

## Self-review

**Spec coverage.** Findings A-N each map to a task above (table at the top); O is declined with reasons and listed
as a follow-up. The two reviews' overlapping items (R1-1/R2-2, R1-5/R2-1, R1-6/R2-5, R1-7/R2-6) land once each.

**Placeholders.** None: every step that changes code shows the code; every check is written out; expected outputs
are stated (as predictions, per the Status block).

**Type consistency.** `AlignedSamples(file:sampleOffset:)` / `AlignedSamples(copying:)` (Task 10) are what Task 11's
`diskTile` and `fetchedTile` construct; `isWorthCachingOnDisk(source:z:)` (Task 9) is what Tasks 11 and 14 call;
`offActor(_:)` (Task 11) is what Task 14's `completeUpgrade` calls; `settleStaleTiles()` is declared empty in Task 12
and given its body in Task 13, and `pendingStaleTiles` / `scheduleStaleSettle()` (Task 13) are what Task 14 inserts
into; `setStaleTilesSink(_:)` and `publishStaleTiles()` (Task 12) are what Task 13's settle calls; `inFlightEntries()`
and the two-argument `evict(where:)` (Task 15) are what `cullTiles` and T14 call; `COGByteReader.fetchTile` keeps its
signature and Task 4's coordinator calls it; `ElevationTileCoordinator(transport:)` (Task 4) is what every harness
check constructs from Task 3 on (the `pipeline:` default argument exists until Task 4 removes it, so Task 3's check
compiles both before and after).
