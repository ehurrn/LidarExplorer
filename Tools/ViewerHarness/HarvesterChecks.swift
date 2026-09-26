//
//  HarvesterChecks.swift
//  ViewerHarness
//
//  The offline bounding-box harvester: which tiles a region needs, what they weigh, how the coordinator
//  schedules, pauses, cancels and resumes them, and that the seeded disk cache answers with the network gone.
//

import CoreLocation
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

@MainActor
func runHarvesterChecks() async {
    print("\n=== Offline harvester ===")
    checkHarvestTileEnumeration()
    await checkHarvestFootprint()
    await checkHarvestScheduling()
    await checkHarvestPauseCancelResume()
    await checkHarvestSeedsTheDiskCache()
    await checkHarvestStoresBasemaps()
}

// MARK: - Fixtures

/// A stand-in tile source that records what it was asked for and how many calls overlapped.
nonisolated final class MockHarvestSource: HarvestTileSource, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HarvestTile] = []
    private var running = 0
    private var peakRunning = 0
    private var sizes: Set<Int> = []

    let bytesPerTile: Int
    let delayMilliseconds: Int
    let fails: @Sendable (HarvestTile) -> Bool
    let cached: @Sendable (HarvestTile) -> Bool

    init(
        bytesPerTile: Int = 1_000,
        delayMilliseconds: Int = 5,
        fails: @escaping @Sendable (HarvestTile) -> Bool = { _ in false },
        cached: @escaping @Sendable (HarvestTile) -> Bool = { _ in false }
    ) {
        self.bytesPerTile = bytesPerTile
        self.delayMilliseconds = delayMilliseconds
        self.fails = fails
        self.cached = cached
    }

    var calls: [HarvestTile] { lock.withLock { log } }
    var peak: Int { lock.withLock { peakRunning } }
    /// Every tile size, in pixels, this source was asked to harvest at.
    var pixelsSeen: Set<Int> { lock.withLock { sizes } }

    func estimatedBytesPerTile(pixels: Int) -> Int64 { Int64(bytesPerTile) }

    func harvest(_ tile: HarvestTile, pixels: Int) async -> HarvestTileOutcome {
        lock.withLock {
            log.append(tile)
            sizes.insert(pixels)
            running += 1
            peakRunning = max(peakRunning, running)
        }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        lock.withLock { running -= 1 }
        if fails(tile) { return .failed(reason: "mock failure") }
        if cached(tile) { return .alreadyCached }
        return .stored(bytes: bytesPerTile)
    }
}

/// 0.02 degrees square over the Illinois bluffs: z15 to z18 needs 12, 24, 80 and 300 tiles.
private let harvestRegion = GeoRegion(
    minLatitude: 38.650, maxLatitude: 38.670, minLongitude: -90.070, maxLongitude: -90.050
)

private func harvestManifestDirectory() -> URL {
    let dir = harnessTemporaryDirectory
        .appendingPathComponent("HarvestManifests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls until `condition` holds or `seconds` pass. A wait that can hang would turn a bug into a stuck harness.
@MainActor
private func harvestWait(seconds: Double = 10, until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

/// A value handed from an unstructured task to the checks, which poll for it rather than await the task.
///
/// Awaiting a task that a bug has left stuck would hang the harness; polling to a deadline turns the same bug
/// into a failed check.
nonisolated final class HarvestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ newValue: Value) { lock.withLock { stored = newValue } }
}

/// One harvest running as its own task.
@MainActor
final class HarvestRun {
    private let box = HarvestBox<Result<HarvestSummary, any Error>>()
    private var task: Task<Void, Never>?

    init(_ coordinator: OfflineHarvestCoordinator, _ configuration: HarvestConfiguration, resuming jobID: UUID? = nil) {
        let box = box
        task = Task {
            do {
                box.set(.success(try await coordinator.harvest(configuration, resuming: jobID)))
            } catch {
                box.set(.failure(error))
            }
        }
    }

    /// Cancels the task the harvest runs in, as a caller's own cancellation would.
    func cancelTask() { task?.cancel() }

    /// Waits up to `seconds` for the harvest to end, then reports how.
    func result(seconds: Double = 20) async -> Result<HarvestSummary, any Error>? {
        await harvestWait(seconds: seconds) { box.value != nil }
        return box.value
    }

    func summary(seconds: Double = 20) async -> HarvestSummary? {
        guard let outcome = await result(seconds: seconds), case .success(let summary) = outcome else { return nil }
        return summary
    }

    func error(seconds: Double = 20) async -> HarvestError? {
        guard let outcome = await result(seconds: seconds), case .failure(let error) = outcome else { return nil }
        return error as? HarvestError
    }
}

private func harvestPath(_ tile: HarvestTile) -> MKTileOverlayPath {
    MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1)
}

// MARK: - H1. Enumeration

@MainActor
private func checkHarvestTileEnumeration() {
    print("\n--- H1. tile enumeration ---")

    // Oracle values from the standard slippy-map formulae, worked out independently of the implementation.
    let expected: [(z: Int, x: ClosedRange<Int>, y: ClosedRange<Int>, count: Int)] = [
        (15, 8185...8187, 12561...12564, 12),
        (16, 16371...16374, 25123...25128, 24),
        (17, 32742...32749, 50247...50256, 80),
        (18, 65485...65499, 100494...100513, 300),
    ]
    for e in expected {
        let tiles = OfflineHarvestCoordinator.tiles(covering: harvestRegion, z: e.z)
        let inRange = tiles.allSatisfy { e.x.contains($0.x) && e.y.contains($0.y) && $0.z == e.z }
        check("a 0.02 degree region at z\(e.z) needs exactly \(e.count) tiles, x \(e.x), y \(e.y)",
              tiles.count == e.count && Set(tiles).count == e.count && inRange && !tiles.isEmpty,
              "\(tiles.count) tiles, first \(String(describing: tiles.first))")
    }

    let z18 = OfflineHarvestCoordinator.tiles(covering: harvestRegion, z: 18)
    check("tiles come out row by row, west to east, so a run is deterministic",
          z18.first == HarvestTile(x: 65485, y: 100494, z: 18)
          && z18.last == HarvestTile(x: 65499, y: 100513, z: 18)
          && z18.map { [$0.y, $0.x] } == z18.map { [$0.y, $0.x] }.sorted { $0.lexicographicallyPrecedes($1) },
          "\(String(describing: z18.first)) … \(String(describing: z18.last))")

    let all = OfflineHarvestCoordinator.tiles(for: HarvestConfiguration(region: harvestRegion, minZ: 15, maxZ: 18, pixels: 512))
    check("a zoom range enumerates every level, coarse first",
          all.count == 416 && all.first?.z == 15 && all.last?.z == 18
          && all.map(\.z) == all.map(\.z).sorted(),
          "\(all.count) tiles")

    // A tile's own region must harvest to that tile alone, float noise on its edges notwithstanding: this is
    // the region the renderer computes for the very tile it will later look up.
    var roundTrip = true
    var roundTripDetail = ""
    var probed = 0
    for z in [1, 3, 8, 15, 18] {
        let n = 1 << z
        for (x, y) in [(0, 0), (n - 1, n - 1), (n / 2, n / 3), (n - 1, 0), (n / 3, n - 1)] {
            let tile = HarvestTile(x: x, y: y, z: z)
            let found = OfflineHarvestCoordinator.tiles(
                covering: TerrainTileOverlay.region(for: harvestPath(tile)), z: z)
            probed += 1
            if found != [tile] {
                roundTrip = false
                roundTripDetail += " z\(z) \(x)/\(y) -> \(found.map { "\($0.x)/\($0.y)" })"
            }
        }
    }
    check("the region of a tile harvests to exactly that tile (\(probed) tiles, z1 to z18)",
          roundTrip && probed == 25, roundTripDetail)

    let neighbours = HarvestTile(x: 65490, y: 100500, z: 18)
    let a = TerrainTileOverlay.region(for: harvestPath(neighbours))
    let b = TerrainTileOverlay.region(for: harvestPath(HarvestTile(x: 65491, y: 100501, z: 18)))
    let block = GeoRegion(
        minLatitude: min(a.minLatitude, b.minLatitude), maxLatitude: max(a.maxLatitude, b.maxLatitude),
        minLongitude: min(a.minLongitude, b.minLongitude), maxLongitude: max(a.maxLongitude, b.maxLongitude))
    check("the union of a 2 x 2 block of tile regions harvests those four tiles",
          Set(OfflineHarvestCoordinator.tiles(covering: block, z: 18))
            == [HarvestTile(x: 65490, y: 100500, z: 18), HarvestTile(x: 65491, y: 100500, z: 18),
                HarvestTile(x: 65490, y: 100501, z: 18), HarvestTile(x: 65491, y: 100501, z: 18)])

    // z3 tile x2 y3 spans exactly -90..-45 degrees longitude and 0..40.979... degrees latitude.
    let across = GeoRegion(minLatitude: 10, maxLatitude: 20, minLongitude: -45.000001, maxLongitude: -44.999999)
    check("a sliver across a tile edge needs both tiles",
          OfflineHarvestCoordinator.tiles(covering: across, z: 3).map(\.x) == [2, 3],
          "\(OfflineHarvestCoordinator.tiles(covering: across, z: 3))")

    let world = GeoRegion(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180)
    check("the whole world is 1 tile at z0 and 16 at z2, with the poles clamped rather than trapped",
          OfflineHarvestCoordinator.tiles(covering: world, z: 0).count == 1
          && OfflineHarvestCoordinator.tiles(covering: world, z: 2).count == 16)
    let northPole = GeoRegion(minLatitude: 89.9, maxLatitude: 90, minLongitude: 0, maxLongitude: 10)
    check("a region at the pole stays on the top row",
          OfflineHarvestCoordinator.tiles(covering: northPole, z: 2) == [HarvestTile(x: 2, y: 0, z: 2)],
          "\(OfflineHarvestCoordinator.tiles(covering: northPole, z: 2))")
    let eastEdge = GeoRegion(minLatitude: 10, maxLatitude: 11, minLongitude: 179.9, maxLongitude: 180)
    check("a region ending on the antimeridian does not spill into a tile that does not exist",
          OfflineHarvestCoordinator.tiles(covering: eastEdge, z: 2).map(\.x) == [3],
          "\(OfflineHarvestCoordinator.tiles(covering: eastEdge, z: 2))")

    let nonFinite = GeoRegion(
        minLatitude: 38, maxLatitude: 39, minLongitude: -91, maxLongitude: Double.infinity)
    check("a non-finite region and an impossible zoom enumerate nothing rather than trapping",
          OfflineHarvestCoordinator.tiles(covering: nonFinite, z: 10).isEmpty
          && OfflineHarvestCoordinator.tiles(covering: harvestRegion, z: -1).isEmpty
          && OfflineHarvestCoordinator.tiles(covering: harvestRegion, z: 23).isEmpty
          && OfflineHarvestCoordinator.tiles(covering: harvestRegion, z: 10).count == 1)
}

// MARK: - H2. Footprint

@MainActor
private func checkHarvestFootprint() async {
    print("\n--- H2. footprint estimate ---")
    let elevation = MockHarvestSource(bytesPerTile: 1_000)
    let basemap = MockHarvestSource(bytesPerTile: 200)
    let coordinator = OfflineHarvestCoordinator(
        elevation: elevation, basemaps: basemap, manifestDirectory: harvestManifestDirectory())

    let config = HarvestConfiguration(region: harvestRegion, minZ: 15, maxZ: 18, pixels: 512)
    let estimate = await coordinator.estimateFootprint(for: config)
    check("the estimate counts the tiles the enumeration yields, and weighs each by the source",
          estimate.tileCount == 416 && estimate.estimatedBytes == 416_000,
          "\(estimate)")

    var withBasemaps = config
    withBasemaps.includeBasemaps = true
    let both = await coordinator.estimateFootprint(for: withBasemaps)
    check("including basemaps adds their tiles' weight",
          both.tileCount == 416 && both.estimatedBytes == 416 * 1_200, "\(both)")

    var backwards = config
    backwards.minZ = 18
    backwards.maxZ = 15
    let none = await coordinator.estimateFootprint(for: backwards)
    check("an inverted zoom range is an empty harvest",
          none.tileCount == 0 && none.estimatedBytes == 0 && estimate.tileCount == 416, "\(none)")

    // The whole world to z18 is ~9.2e10 tiles. Counting must be arithmetic, not enumeration.
    let world = HarvestConfiguration(
        region: GeoRegion(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180),
        minZ: 0, maxZ: 18, pixels: 512)
    let started = ContinuousClock.now
    let planet = await coordinator.estimateFootprint(for: world)
    let elapsed = ContinuousClock.now - started
    check("a planet-sized estimate counts all 91,625,968,981 tiles and weighs them",
          planet.tileCount == 91_625_968_981 && planet.estimatedBytes == 91_625_968_981 * 1_000,
          "\(planet)")
    check("… by arithmetic, in well under a second",
          elapsed < .seconds(1) && planet.tileCount == 91_625_968_981, "\(elapsed)")

    // A harvest that cannot fit the cache would evict its own earliest tiles as it wrote its last.
    let small = MockHarvestSource(bytesPerTile: 1_000)
    let tight = OfflineHarvestCoordinator(
        elevation: small, manifestDirectory: harvestManifestDirectory(), cacheCapacityBytes: 100_000)
    // Whoever is watching a harvest that will be refused must not be left waiting for updates that never come.
    let refusedStream = await tight.progress()
    let refusedWatcher = HarvestBox<Int>()
    Task {
        var seen = 0
        for await _ in refusedStream { seen += 1 }
        refusedWatcher.set(seen)
    }
    let refused = await HarvestRun(tight, config).error()
    check("a harvest larger than the disk cache is refused before a single tile is fetched",
          refused == .exceedsCacheCapacity(estimatedBytes: 416_000, capacityBytes: 100_000) && small.calls.isEmpty,
          "\(String(describing: refused)), \(small.calls.count) calls")

    await harvestWait(seconds: 5) { refusedWatcher.value != nil }
    check("a refused harvest ends its progress stream instead of leaving it open",
          refusedWatcher.value == 0 && refused != nil, "\(String(describing: refusedWatcher.value))")

    let noBasemaps = OfflineHarvestCoordinator(
        elevation: MockHarvestSource(), manifestDirectory: harvestManifestDirectory())
    let unavailable = await HarvestRun(noBasemaps, withBasemaps).error()
    check("asking for basemaps without a basemap source is an error, not a silent elevation-only harvest",
          unavailable == .basemapSourceUnavailable, "\(String(describing: unavailable))")
}

// MARK: - H3. Scheduling

@MainActor
private func checkHarvestScheduling() async {
    print("\n--- H3. scheduling, progress, manifest ---")
    let directory = harvestManifestDirectory()
    let failing: @Sendable (HarvestTile) -> Bool = { ($0.x + $0.y) % 7 == 0 }
    let elevation = MockHarvestSource(fails: failing, cached: { $0.x % 11 == 0 })
    let coordinator = OfflineHarvestCoordinator(elevation: elevation, manifestDirectory: directory)
    let config = HarvestConfiguration(region: harvestRegion, minZ: 16, maxZ: 17, pixels: 512)
    let tiles = OfflineHarvestCoordinator.tiles(for: config)
    let expectedFailures = tiles.filter { failing($0) }.count
    let expectedCached = tiles.filter { !failing($0) && $0.x % 11 == 0 }.count

    let stream = await coordinator.progress()
    let collector = HarvestBox<[HarvestProgress]>()
    Task {
        var seen: [HarvestProgress] = []
        for await update in stream { seen.append(update) }
        collector.set(seen)
    }
    let summary = await HarvestRun(coordinator, config).summary()
    await harvestWait(seconds: 5) { collector.value != nil }
    let updates = collector.value ?? []

    check("every tile is fetched exactly once",
          Set(elevation.calls).count == tiles.count && elevation.calls.count == tiles.count
          && Set(elevation.calls) == Set(tiles) && !tiles.isEmpty,
          "\(elevation.calls.count) calls for \(tiles.count) tiles")
    check("fetches overlap, but never beyond the concurrency bound of 4",
          elevation.peak > 1 && elevation.peak <= 4, "peak \(elevation.peak)")
    let clamped = OfflineHarvestCoordinator(
        elevation: MockHarvestSource(), manifestDirectory: directory, maxConcurrent: 50)
    let floored = OfflineHarvestCoordinator(
        elevation: MockHarvestSource(), manifestDirectory: directory, maxConcurrent: 0)
    let limits = [coordinator.concurrencyLimit, clamped.concurrencyLimit, floored.concurrencyLimit]
    check("the bound defaults to 4, is capped at 6 and never drops below 1", limits == [4, 6, 1], "\(limits)")

    check("failed tiles are counted and do not stop the harvest",
          summary?.state == .completed && summary?.failed == expectedFailures && expectedFailures > 0
          && summary?.total == tiles.count && summary?.completed == tiles.count - expectedFailures,
          "\(String(describing: summary)), expected \(expectedFailures) failures")

    let processed = updates.map { $0.completed + $0.failed }
    check("progress is reported for every tile, never goes backwards, and ends complete",
          updates.count >= tiles.count / 2 && processed == processed.sorted()
          && updates.last.map({ $0.completed + $0.failed == tiles.count && $0.total == tiles.count }) == true,
          "\(updates.count) updates, last \(String(describing: updates.last))")
    check("progress carries the failure count",
          updates.last?.failed == expectedFailures, "\(String(describing: updates.last))")
    let rates = updates.map(\.kilobytesPerSecond)
    check("throughput is finite, never negative, and positive once bytes have landed",
          rates.allSatisfy { $0.isFinite && $0 >= 0 } && (rates.last ?? 0) > 0,
          "\(rates.suffix(3))")
    check("tiles already on disk complete without adding to the bytes written",
          summary?.bytesStored == Int64(1_000 * (tiles.count - expectedFailures - expectedCached))
          && expectedCached > 0,
          "\(String(describing: summary?.bytesStored)), expected \(1_000 * (tiles.count - expectedFailures - expectedCached))")

    // The manifest is a file named for the job, recording what finished — and only that.
    if let jobID = summary?.jobID {
        let url = OfflineHarvestCoordinator.manifestURL(for: jobID, in: directory)
        let manifest = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let completed = Set((manifest?["completed"] as? [String]) ?? [])
        let expected = Set(tiles.filter { !failing($0) }.map { "elevation/\($0.z)/\($0.x)/\($0.y)" })
        check("the manifest is named harvest_manifest_<uuid>.json",
              url.lastPathComponent == "harvest_manifest_\(jobID.uuidString).json"
              && FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        check("the manifest lists every finished tile and none of the failures",
              completed == expected && !completed.isEmpty,
              "\(completed.count) recorded, \(expected.count) expected")
    } else {
        check("the manifest is named harvest_manifest_<uuid>.json", false, "no summary")
        check("the manifest lists every finished tile and none of the failures", false, "no summary")
    }

    // Both layers, one job.
    let layerDirectory = harvestManifestDirectory()
    let terrain = MockHarvestSource(bytesPerTile: 900, delayMilliseconds: 1)
    let imagery = MockHarvestSource(bytesPerTile: 100, delayMilliseconds: 1)
    let layered = OfflineHarvestCoordinator(elevation: terrain, basemaps: imagery, manifestDirectory: layerDirectory)
    let layeredConfig = HarvestConfiguration(region: harvestRegion, minZ: 16, maxZ: 16, pixels: 512, includeBasemaps: true)
    let layeredSummary = await HarvestRun(layered, layeredConfig).summary()
    check("with basemaps included every tile is fetched once per layer",
          layeredSummary?.total == 48 && layeredSummary?.completed == 48
          && Set(terrain.calls).count == 24 && terrain.calls.count == 24
          && Set(imagery.calls) == Set(terrain.calls) && imagery.calls.count == 24
          && layeredSummary?.bytesStored == Int64(24 * 1_000),
          "\(String(describing: layeredSummary)), \(terrain.calls.count)+\(imagery.calls.count) calls")
}

// MARK: - H4. Pause, cancel, resume

@MainActor
private func checkHarvestPauseCancelResume() async {
    print("\n--- H4. pause, cancel, resume ---")
    let config = HarvestConfiguration(region: harvestRegion, minZ: 16, maxZ: 17, pixels: 512)
    let tiles = OfflineHarvestCoordinator.tiles(for: config)
    check("the interruption fixture is the 24 + 80 tiles of z16 and z17", tiles.count == 104, "\(tiles.count)")

    // Pause: nothing new starts, and the harvest finishes once resumed.
    let pausedSource = MockHarvestSource(delayMilliseconds: 10)
    let pausable = OfflineHarvestCoordinator(elevation: pausedSource, manifestDirectory: harvestManifestDirectory())
    let running = HarvestRun(pausable, config)
    await harvestWait { pausedSource.calls.count >= 8 }
    await pausable.pause()
    try? await Task.sleep(for: .milliseconds(200))          // let anything in flight land
    let atPause = pausedSource.calls.count
    try? await Task.sleep(for: .milliseconds(250))
    let afterPause = pausedSource.calls.count
    check("while paused no new tile is started", afterPause == atPause && atPause < tiles.count,
          "\(atPause) -> \(afterPause) of \(tiles.count)")
    await pausable.resume()
    let resumed = await running.summary()
    check("resuming carries on to the end",
          tiles.count == 104 && resumed?.state == .completed && resumed?.completed == tiles.count
          && Set(pausedSource.calls) == Set(tiles) && pausedSource.calls.count == tiles.count,
          "\(String(describing: resumed)), \(pausedSource.calls.count) calls")

    // Cancel, then resume the same job from its manifest.
    let directory = harvestManifestDirectory()
    let failing: @Sendable (HarvestTile) -> Bool = { ($0.x + $0.y) % 5 == 0 }
    let first = MockHarvestSource(delayMilliseconds: 8, fails: failing)
    let interrupted = OfflineHarvestCoordinator(elevation: first, manifestDirectory: directory)
    let firstRun = HarvestRun(interrupted, config)
    await harvestWait { first.calls.count >= 25 }
    await interrupted.cancel()
    let stopped = await firstRun.summary()
    check("cancelling stops the harvest part-way and says so",
          stopped?.state == .cancelled && (stopped?.completed ?? tiles.count) < tiles.count
          && first.calls.count < tiles.count,
          "\(String(describing: stopped)), \(first.calls.count) calls")

    guard let stopped else {
        check("resuming fetches only what the manifest lacks", false, "no summary from the first run")
        check("resuming finishes the job, retrying earlier failures", false, "no summary from the first run")
        return
    }
    let manifestURL = OfflineHarvestCoordinator.manifestURL(for: stopped.jobID, in: directory)
    let done = Set(((try? Data(contentsOf: manifestURL))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["completed"] as? [String]) ?? [])

    let second = MockHarvestSource(delayMilliseconds: 1)
    let resumedCoordinator = OfflineHarvestCoordinator(elevation: second, manifestDirectory: directory)
    let finished = await HarvestRun(resumedCoordinator, config, resuming: stopped.jobID).summary()
    let refetched = Set(second.calls.map { "elevation/\($0.z)/\($0.x)/\($0.y)" })
    let everything = Set(tiles.map { "elevation/\($0.z)/\($0.x)/\($0.y)" })
    check("resuming fetches only what the manifest lacks, with nothing fetched twice",
          !done.isEmpty && refetched.isDisjoint(with: done) && refetched == everything.subtracting(done)
          && second.calls.count == refetched.count,
          "\(done.count) already done, \(refetched.count) refetched, \(everything.count) in all")
    check("resuming finishes the job under the same id, retrying what failed before",
          tiles.count == 104 && finished?.state == .completed && finished?.jobID == stopped.jobID
          && finished?.completed == tiles.count && finished?.failed == 0 && finished?.total == tiles.count,
          "\(String(describing: finished))")

    // Structured cancellation: cancelling the task that runs the harvest is enough.
    let scoped = MockHarvestSource(delayMilliseconds: 8)
    let scopedCoordinator = OfflineHarvestCoordinator(elevation: scoped, manifestDirectory: harvestManifestDirectory())
    let scopedRun = HarvestRun(scopedCoordinator, config)
    await harvestWait { scoped.calls.count >= 12 }
    scopedRun.cancelTask()
    let scopedSummary = await scopedRun.summary()
    check("cancelling the task that runs the harvest cancels it",
          scopedSummary?.state == .cancelled && scoped.calls.count < tiles.count,
          "\(String(describing: scopedSummary)), \(scoped.calls.count) calls")

    // One harvest at a time per coordinator: a second would corrupt the first's counts and progress.
    let busySource = MockHarvestSource(delayMilliseconds: 20)
    let busy = OfflineHarvestCoordinator(elevation: busySource, manifestDirectory: harvestManifestDirectory())
    let busyRun = HarvestRun(busy, config)
    await harvestWait { busySource.calls.count >= 4 }
    let refusedSecond = await HarvestRun(busy, config).error()
    await busy.cancel()
    let busySummary = await busyRun.summary()
    check("a second harvest on a busy coordinator is refused and leaves the first alone",
          refusedSecond == .alreadyRunning && busySummary?.state == .cancelled
          && Set(busySource.calls).count == busySource.calls.count,
          "\(String(describing: refusedSecond)), \(String(describing: busySummary))")

    // A manifest belongs to one configuration.
    var other = config
    other.maxZ = 18
    let mismatch = await HarvestRun(resumedCoordinator, other, resuming: stopped.jobID).error()
    let unknown = UUID()
    let missing = await HarvestRun(resumedCoordinator, config, resuming: unknown).error()
    check("a manifest cannot be resumed under a different configuration, or when it does not exist",
          mismatch == .manifestMismatch(stopped.jobID) && missing == .manifestNotFound(unknown),
          "\(String(describing: mismatch)), \(String(describing: missing))")
}

// MARK: - H5. Seeding the provider's disk cache

/// A network that is either down or serves one Terrarium tile for every URL, and counts what was asked of it.
nonisolated final class HarvestNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var served: Data?
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var asked = 0

    /// Points every session at this network: down when `data` is nil, otherwise answering every request with
    /// `data` and `status`.
    static func set(serving data: Data?, status code: Int = 200) {
        lock.withLock { served = data; status = code; asked = 0 }
    }
    static var requestCount: Int { lock.withLock { asked } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HarvestNetworkProtocol.self]
        return URLSession(configuration: config)
    }

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        let (body, code) = Self.lock.withLock { () -> (Data?, Int) in
            Self.asked += 1
            return (Self.served, Self.status)
        }
        guard let body, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                             headerFields: ["Content-Type": "image/png"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override nonisolated func stopLoading() {}
}

/// A flat 256 px Terrarium tile at `metres`: elevation = R * 256 + G + B / 256 - 32768.
func terrariumPNG(elevation metres: Int) -> Data {
    let side = 256
    let value = metres + 32768
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for i in 0..<side * side {
        pixels[i * 4] = UInt8(value / 256)
        pixels[i * 4 + 1] = UInt8(value % 256)
        pixels[i * 4 + 3] = 255
    }
    let image = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// The colour at the middle of an encoded image.
private func centrePixel(of data: Data) -> (r: Int, g: Int, b: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return true
    }
    return drawn ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : nil
}

private func isFailure(_ outcome: HarvestTileOutcome?) -> Bool {
    if case .failed = outcome { return true }
    return false
}

@MainActor
private func checkHarvestSeedsTheDiskCache() async {
    print("\n--- H5. seeding the provider's disk cache ---")
    let pixels = 256
    let margin = TerrainTileProvider.marginPixels
    let side = pixels + 2 * margin
    func gridKey(_ tile: HarvestTile, pixels: Int = 256) -> String {
        TerrainTileProvider.gridCacheKey(x: tile.x, y: tile.y, z: tile.z, pixels: pixels, margin: margin)
    }
    func path(_ tile: HarvestTile) -> MKTileOverlayPath {
        MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1)
    }

    // The disk cache: what the harvester needs to ask of it.
    let probe = ElevationGrid(width: 8, height: 8, samples: [Float](repeating: 1, count: 64), region: harvestRegion)
    let encodedSizes = ["3DEP 1m", "terrarium", "3DEP 4m (Overview)"].compactMap {
        ElevationGridCoder.encode(probe, source: $0)?.count
    }
    check("the coder reports the size it writes, whatever the source is called",
          Set(encodedSizes).count == 1 && encodedSizes.count == 3
          && ElevationGridCoder.encodedByteCount(width: 8, height: 8) == encodedSizes.first
          && ElevationGridCoder.encodedByteCount(width: 8, height: 8) == 4096 + 8 * 8 * 4,
          "\(encodedSizes), \(ElevationGridCoder.encodedByteCount(width: 8, height: 8))")

    let apiCache = TileDiskCache(directory: makeCacheDir())
    let heldBefore = await apiCache.contains(forKey: "grid_probe")
    let wrote = await apiCache.write(Data(repeating: 7, count: 100), forKey: "grid_probe")
    let heldAfter = await apiCache.contains(forKey: "grid_probe")
    let statistics = await apiCache.statistics()
    check("the cache says whether it holds a key without counting a hit or a miss",
          !heldBefore && wrote && heldAfter && statistics.reads == 0,
          "\(heldBefore) \(wrote) \(heldAfter) \(statistics.reads) reads")
    let unwritable = TileDiskCache(directory: URL(fileURLWithPath: "/dev/null/harvest"))
    check("a write that could not reach the disk says so",
          await unwritable.write(Data([1]), forKey: "grid_probe") == false && wrote)

    // Seed a small area at z16 to z18 through a real provider.
    let region = GeoRegion(
        center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621),
        latitudeSpan: 0.002, longitudeSpan: 0.002)
    let config = HarvestConfiguration(region: region, minZ: 16, maxZ: 18, pixels: pixels)
    let tiles = OfflineHarvestCoordinator.tiles(for: config)
    let directory = makeCacheDir()
    HarvestNetworkProtocol.set(serving: nil)
    let stub = CountingElevationStub()
    let cache = TileDiskCache(directory: directory)
    let provider = TerrainTileProvider(
        elevation: stub, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: cache)
    let seeded = await HarvestRun(
        OfflineHarvestCoordinator(elevation: provider.elevationHarvestSource, manifestDirectory: harvestManifestDirectory()),
        config).summary()
    check("a harvest fetches every tile of the area once and stores it",
          tiles.count >= 4 && seeded?.completed == tiles.count && seeded?.failed == 0
          && (seeded?.bytesStored ?? 0) > 0 && stub.callCount == tiles.count,
          "\(String(describing: seeded)), \(stub.callCount) fetches for \(tiles.count) tiles")

    var present = 0
    var decoded = 0
    var sizes: Set<Int> = []
    for tile in tiles {
        if await cache.contains(forKey: gridKey(tile)) { present += 1 }
        if let data = await cache.read(forKey: gridKey(tile)), let stored = ElevationGridCoder.decode(data),
           stored.grid.width == side, stored.grid.height == side {
            decoded += 1
            sizes.insert(data.count)
        }
    }
    check("each lands under the key the renderer reads, as a padded \(side) px raster",
          present == tiles.count && decoded == tiles.count && tiles.count >= 4, "\(present)/\(decoded) of \(tiles.count)")
    let estimate = provider.elevationHarvestSource.estimatedBytesPerTile(pixels: pixels)
    check("the size estimate is what a tile really occupies",
          sizes.count == 1 && estimate == Int64(sizes.first ?? -1)
          && estimate == Int64(ElevationGridCoder.encodedByteCount(width: side, height: side)),
          "estimate \(estimate), actual \(sizes)")

    let again = await HarvestRun(
        OfflineHarvestCoordinator(elevation: provider.elevationHarvestSource, manifestDirectory: harvestManifestDirectory()),
        config).summary()
    check("harvesting the same area again finds it all on disk and fetches nothing",
          again?.completed == tiles.count && again?.bytesStored == 0 && stub.callCount == tiles.count,
          "\(String(describing: again)), \(stub.callCount) fetches")

    // Cut the network and start a provider with nothing in memory: only the disk cache is left to answer.
    HarvestNetworkProtocol.set(serving: nil)
    let offlineSource = RecordingElevationStub(answers: false)
    let offline = TerrainTileProvider(
        elevation: offlineSource, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
        gridCache: TileDiskCache(directory: directory))
    var rendered = 0
    for tile in tiles where await offline.tileImage(
        x: tile.x, y: tile.y, z: tile.z, region: TerrainTileOverlay.region(for: path(tile)), pixels: pixels) != nil {
        rendered += 1
    }
    check("with the network cut, every harvested tile still renders",
          rendered == tiles.count && offlineSource.callCount == 0 && HarvestNetworkProtocol.requestCount == 0,
          "\(rendered)/\(tiles.count) rendered, \(offlineSource.callCount) elevation calls, \(HarvestNetworkProtocol.requestCount) requests")

    // The size to harvest at is the one the map asks for, which a device chooses (an iPad Pro 13" draws at about
    // 1.477x and so wants 384 px, not the 512 a retina phone does): the provider remembers what it was last asked.
    let observedByOffline = await offline.observedTilePixels
    let unasked = TerrainTileProvider(elevation: RecordingElevationStub(answers: false), gridCache: TileDiskCache(directory: makeCacheDir()))
    let observedBeforeAnyRequest = await unasked.observedTilePixels
    _ = await unasked.tileImage(x: 65490, y: 100500, z: 18, region: TerrainTileOverlay.region(for: MKTileOverlayPath(x: 65490, y: 100500, z: 18, contentScaleFactor: 1)), pixels: 384)
    let observedAfterRequest = await unasked.observedTilePixels
    check("the provider remembers the tile size the map last asked for, and has none before any request",
          observedByOffline == pixels && observedBeforeAnyRequest == nil && observedAfterRequest == 384
          && TerrainTileOverlayRenderer.tilePixels(tileSize: 256, contentScaleFactor: 1.477) == 384,
          "\(String(describing: observedByOffline)) \(String(describing: observedBeforeAnyRequest)) \(String(describing: observedAfterRequest))")

    // Controls: the offline provider really has no other way to answer.
    let outside = HarvestTile(x: (tiles.last?.x ?? 0) + 50, y: tiles.last?.y ?? 0, z: 18)
    let missing = await offline.tileImage(
        x: outside.x, y: outside.y, z: outside.z, region: TerrainTileOverlay.region(for: path(outside)), pixels: pixels)
    check("a tile that was never harvested does not render offline, and the provider did try its sources",
          missing == nil && offlineSource.callCount > 0, "\(offlineSource.callCount) calls")
    let last = tiles.last ?? outside
    // A fresh provider, so only the disk can answer: the memory cache is keyed by tile alone, not by size.
    let otherSizeProvider = TerrainTileProvider(
        elevation: RecordingElevationStub(answers: false),
        terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
        gridCache: TileDiskCache(directory: directory))
    let otherSize = await otherSizeProvider.tileImage(
        x: last.x, y: last.y, z: last.z, region: TerrainTileOverlay.region(for: path(last)), pixels: 512)
    check("a harvest at one tile size answers that size only",
          rendered == tiles.count && otherSize == nil, "\(rendered) rendered at 256; at 512: \(otherSize != nil)")

    // A tile that only a degraded fallback could supply must not be pinned to disk.
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 120))
    let degradedCache = TileDiskCache(directory: makeCacheDir())
    let degraded = TerrainTileProvider(
        elevation: RecordingElevationStub(answers: false),
        terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: degradedCache)
    let degradedOutcome = await degraded.elevationHarvestSource.harvest(last, pixels: pixels)
    let degradedKept = await degradedCache.contains(forKey: gridKey(last))
    check("a tile only a degraded fallback could supply is refused, not kept",
          isFailure(degradedOutcome) && HarvestNetworkProtocol.requestCount > 0 && !degradedKept,
          "\(degradedOutcome), \(HarvestNetworkProtocol.requestCount) requests")

    // Terrarium's own zooms are cacheable and answer offline afterwards.
    let native = HarvestTile(x: 8186, y: 12562, z: 15)
    let nativeOutcome = await degraded.elevationHarvestSource.harvest(native, pixels: pixels)
    HarvestNetworkProtocol.set(serving: nil)
    let nativeOffline = TerrainTileProvider(
        elevation: RecordingElevationStub(answers: false),
        terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: degradedCache)
    let nativeImage = await nativeOffline.tileImage(
        x: native.x, y: native.y, z: native.z, region: TerrainTileOverlay.region(for: path(native)), pixels: pixels)
    check("a z15 tile comes from Terrarium, is kept, and renders offline afterwards",
          nativeOutcome == .stored(bytes: ElevationGridCoder.encodedByteCount(width: side, height: side))
          && nativeImage != nil && HarvestNetworkProtocol.requestCount == 0,
          "\(nativeOutcome), image \(nativeImage != nil), \(HarvestNetworkProtocol.requestCount) requests")

    // A write that fails is a failed tile, never a stored one.
    let unwritableProvider = TerrainTileProvider(
        elevation: CountingElevationStub(), gridCache: TileDiskCache(directory: URL(fileURLWithPath: "/dev/null/harvest")))
    let unwritableOutcome = await unwritableProvider.elevationHarvestSource.harvest(last, pixels: pixels)
    let writableOutcome = await provider.elevationHarvestSource.harvest(
        HarvestTile(x: last.x + 1, y: last.y, z: last.z), pixels: pixels)
    var writable = false
    if case .stored = writableOutcome { writable = true }
    check("a tile that could not be written is reported as failed, where the same fetch to a good disk is stored",
          isFailure(unwritableOutcome) && writable, "\(unwritableOutcome) vs \(writableOutcome)")
}

// MARK: - H6. Basemap tiles

@MainActor
private func checkHarvestStoresBasemaps() async {
    print("\n--- H6. basemap tiles ---")
    let png = terrariumPNG(elevation: 120)
    func key(_ tile: HarvestTile, _ basemap: TerrainBasemap = .imagery) -> String {
        TerrainBasemap.harvestKey(basemap, tile)
    }
    func path(_ tile: HarvestTile) -> MKTileOverlayPath {
        MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1)
    }

    check("a basemap tile's URL follows the service's z/y/x order",
          TerrainBasemap.imagery.tileURL(x: 5, y: 7, z: 3)?.absoluteString
            == "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/3/7/5",
          "\(String(describing: TerrainBasemap.imagery.tileURL(x: 5, y: 7, z: 3)))")
    let sample = HarvestTile(x: 5, y: 7, z: 3)
    let keys = TerrainBasemap.allCases.map { key(sample, $0) }
    check("each basemap keeps its tiles under its own filename-safe key",
          Set(keys).count == TerrainBasemap.allCases.count
          && keys.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } },
          "\(keys)")

    // One tile: fetched once, stored, then found on disk.
    let cache = TileDiskCache(directory: makeCacheDir())
    HarvestNetworkProtocol.set(serving: png)
    let source = BasemapHarvestSource(basemap: .imagery, cache: cache, session: HarvestNetworkProtocol.session)
    let tile = HarvestTile(x: 16371, y: 25123, z: 16)
    let first = await source.harvest(tile, pixels: 512)
    let second = await source.harvest(tile, pixels: 512)
    let held = await cache.contains(forKey: key(tile))
    check("a basemap tile is fetched once, stored, and then found on disk",
          first == .stored(bytes: png.count) && second == .alreadyCached && held
          && HarvestNetworkProtocol.requestCount == 1,
          "\(first), \(second), held \(held), \(HarvestNetworkProtocol.requestCount) requests")

    // Past the service's depth the overlay slices the deepest tile, so that is the tile to keep.
    let deep = TileDiskCache(directory: makeCacheDir())
    HarvestNetworkProtocol.set(serving: png)
    let deepSource = BasemapHarvestSource(basemap: .imagery, cache: deep, session: HarvestNetworkProtocol.session)
    let child = HarvestTile(x: 65484, y: 100492, z: 18)
    let sibling = HarvestTile(x: 65485, y: 100493, z: 18)
    let childOutcome = await deepSource.harvest(child, pixels: 512)
    let siblingOutcome = await deepSource.harvest(sibling, pixels: 512)
    let ancestor = HarvestTile(x: 16371, y: 25123, z: 16)
    let ancestorHeld = await deep.contains(forKey: key(ancestor))
    let childHeld = await deep.contains(forKey: key(child))
    check("z18 basemap tiles are served from one z16 ancestor, fetched once for all its children",
          childOutcome == .stored(bytes: png.count) && siblingOutcome == .alreadyCached
          && ancestorHeld && !childHeld && HarvestNetworkProtocol.requestCount == 1,
          "\(childOutcome), \(siblingOutcome), ancestor \(ancestorHeld), child \(childHeld), \(HarvestNetworkProtocol.requestCount) requests")

    // What must not be kept.
    let refusing = TileDiskCache(directory: makeCacheDir())
    HarvestNetworkProtocol.set(serving: Data("not found".utf8), status: 404)
    let refusingSource = BasemapHarvestSource(basemap: .imagery, cache: refusing, session: HarvestNetworkProtocol.session)
    let notFound = await refusingSource.harvest(tile, pixels: 512)
    let errorPageKept = await refusing.contains(forKey: key(tile))
    HarvestNetworkProtocol.set(serving: nil)
    HarvestNetworkProtocol.set(serving: Data("<html>Sign in to the network</html>".utf8))
    let portal = await refusingSource.harvest(tile, pixels: 512)
    let portalKept = await refusing.contains(forKey: key(tile))
    HarvestNetworkProtocol.set(serving: nil)
    let unreachable = await refusingSource.harvest(tile, pixels: 512)
    check("an error page, a captive portal or a dead network is a failed tile, and nothing is stored",
          first == .stored(bytes: png.count)
          && isFailure(notFound) && isFailure(portal) && isFailure(unreachable) && !errorPageKept && !portalKept,
          "\(notFound), \(portal), \(unreachable), kept \(errorPageKept)/\(portalKept)")

    // Cut the network: the overlay answers from what was harvested.
    HarvestNetworkProtocol.set(serving: nil)
    let overlay = HillshadeTileOverlay(basemap: .imagery, session: HarvestNetworkProtocol.session, harvestedTiles: cache)
    let direct = try? await overlay.loadTile(at: path(tile))
    check("with the network cut, a harvested basemap tile loads from disk, byte for byte",
          direct == png && HarvestNetworkProtocol.requestCount == 0,
          "\(direct?.count ?? -1) bytes, \(HarvestNetworkProtocol.requestCount) requests")
    let deepOverlay = HillshadeTileOverlay(basemap: .imagery, session: HarvestNetworkProtocol.session, harvestedTiles: deep)
    let zoomed = try? await deepOverlay.loadTile(at: path(child))
    // The harvested tile is flat (R 128, G 120, B 0); real imagery is not, so the colour ties the slice to it.
    let sliced = zoomed.flatMap(centrePixel)
    check("… and so does an overzoomed child, sliced from the harvested ancestor",
          sliced.map { abs($0.r - 128) < 8 && abs($0.g - 120) < 8 && $0.b < 8 } == true
          && HarvestNetworkProtocol.requestCount == 0,
          "\(String(describing: sliced)), \(HarvestNetworkProtocol.requestCount) requests")
    let stranger = HarvestTile(x: 16400, y: 25123, z: 16)
    let strangerData = try? await overlay.loadTile(at: path(stranger))
    check("a tile that was never harvested still fails offline, after the overlay tried the network",
          strangerData == nil && HarvestNetworkProtocol.requestCount > 0, "\(HarvestNetworkProtocol.requestCount) requests")

    // Both layers in one job.
    let region = GeoRegion(
        center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621), latitudeSpan: 0.002, longitudeSpan: 0.002)
    let config = HarvestConfiguration(region: region, minZ: 16, maxZ: 16, pixels: 256, includeBasemaps: true)
    let tiles = OfflineHarvestCoordinator.tiles(for: config)
    let terrainCache = TileDiskCache(directory: makeCacheDir())
    let imageryCache = TileDiskCache(directory: makeCacheDir())
    HarvestNetworkProtocol.set(serving: png)
    let provider = TerrainTileProvider(elevation: CountingElevationStub(), gridCache: terrainCache)
    let both = OfflineHarvestCoordinator(
        elevation: provider.elevationHarvestSource,
        basemaps: BasemapHarvestSource(basemap: .imagery, cache: imageryCache, session: HarvestNetworkProtocol.session),
        manifestDirectory: harvestManifestDirectory())
    let summary = await HarvestRun(both, config).summary()
    var terrainHeld = 0
    var imageryHeld = 0
    for t in tiles {
        if await terrainCache.contains(
            forKey: TerrainTileProvider.gridCacheKey(x: t.x, y: t.y, z: t.z, pixels: 256, margin: TerrainTileProvider.marginPixels)) {
            terrainHeld += 1
        }
        if await imageryCache.contains(forKey: key(t)) { imageryHeld += 1 }
    }
    check("one job fills both caches: elevation rasters and basemap tiles for every tile",
          !tiles.isEmpty && summary?.total == 2 * tiles.count && summary?.completed == 2 * tiles.count
          && terrainHeld == tiles.count && imageryHeld == tiles.count,
          "\(String(describing: summary)), terrain \(terrainHeld), imagery \(imageryHeld) of \(tiles.count)")
}
