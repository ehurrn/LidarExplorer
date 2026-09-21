//
//  OfflineStoreChecks.swift
//  ViewerHarness
//
//  What was downloaded for offline use has to outlast the tile cache it is written through: the cache is a
//  least-recently-used store that prunes itself whenever ordinary browsing fills it, and a download is by definition
//  the tiles nobody has looked at lately. Protected entries are outside its cap, its pruning and its clearing.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
func runOfflineStoreChecks() async {
    print("\n=== Offline storage that outlasts the tile cache ===")
    await checkProtectedEntries()
    checkOfflineBudget()
    await checkProtectedAvailability()
    await checkHarvestedTilesOutlastBrowsing()
    await checkBasemapTilesAreProtected()
    await checkControllerSizesAgainstWhatIsLeft()
    checkManifestRemoval()
    await checkModelStorageRows()
}

private func fileNames(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

/// Polls to a deadline for something the cache does in the background: it measures itself off its own actor on the first
/// write and prunes when that shows it over its cap, so a fixed sleep is either slow or, on a busy machine, too short.
private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
}

private func heldCount(_ cache: TileDiskCache, prefix: String, of count: Int) async -> Int {
    var held = 0
    for i in 0..<count where await cache.contains(forKey: "\(prefix)_\(i)") { held += 1 }
    return held
}

// MARK: - S1. Protected entries

@MainActor
private func checkProtectedEntries() async {
    print("\n--- S1. protected entries in the disk cache ---")
    let directory = makeCacheDir(), vault = makeCacheDir()
    let cache = TileDiskCache(directory: directory, maxDiskBytes: 1_000_000, targetDiskBytes: 800_000, protectedDirectory: vault)
    let tile = Data(repeating: 0xAB, count: 40_000)

    // 20 protected tiles first (800,000 bytes), so they are the oldest thing in the cache.
    var wroteAll = true
    for i in 0..<20 {
        wroteAll = await cache.write(tile, forKey: "kept_\(i)", protected: true) && wroteAll
        try? await Task.sleep(for: .milliseconds(3))
    }
    // Then ordinary browsing: 60 tiles, 2.4 MB, more than twice the cap.
    for i in 0..<60 {
        _ = await cache.write(tile, forKey: "seen_\(i)")
        try? await Task.sleep(for: .milliseconds(i == 0 ? 400 : 3))
    }
    await waitFor { await heldCount(cache, prefix: "seen", of: 60) < 60 }

    var kept = 0, readBack = 0, mapped = 0
    for i in 0..<20 {
        if await cache.contains(forKey: "kept_\(i)") { kept += 1 }
        if await cache.read(forKey: "kept_\(i)") == tile { readBack += 1 }
        if await cache.map(forKey: "kept_\(i)") != nil { mapped += 1 }
    }
    var seen = 0
    for i in 0..<60 where await cache.contains(forKey: "seen_\(i)") { seen += 1 }
    check("protected entries survive ordinary browsing filling the cache and being pruned, and are found by contains, read and map",
          wroteAll && kept == 20 && readBack == 20 && mapped == 20 && seen > 0 && seen < 60,
          "written \(wroteAll), held \(kept), read \(readBack), mapped \(mapped); \(seen) of 60 ordinary tiles left")

    let ordinaryFiles = fileNames(directory)
    let vaultFiles = fileNames(vault)
    check("they live in the folder they were given, apart from the cache's own",
          vaultFiles.count == 20 && vaultFiles.allSatisfy { $0.hasPrefix("kept_") }
          && !ordinaryFiles.contains { $0.hasPrefix("kept_") } && ordinaryFiles.allSatisfy { $0.hasPrefix("seen_") },
          "vault \(vaultFiles.count) files, cache \(ordinaryFiles.count) files")

    let ordinaryUsage = await cache.measureDiskUsage()
    let protectedUsage = await cache.protectedUsage()
    check("the cache's size is what ordinary browsing holds, and the protected bytes are counted on their own",
          (ordinaryUsage ?? .max) <= 1_000_000 && protectedUsage == 800_000, "\(String(describing: ordinaryUsage)) and \(String(describing: protectedUsage))")

    let statistics = await cache.statistics()
    check("a protected entry read is a hit like any other", statistics.hits >= 40, "\(statistics.hits) hits")

    await cache.clear()
    var afterClear = 0
    for i in 0..<20 where await cache.contains(forKey: "kept_\(i)") { afterClear += 1 }
    var seenAfterClear = 0
    for i in 0..<60 where await cache.contains(forKey: "seen_\(i)") { seenAfterClear += 1 }
    check("clearing the tile cache empties the ordinary tiles and leaves the protected ones", afterClear == 20 && seenAfterClear == 0,
          "\(afterClear) protected and \(seenAfterClear) ordinary left")

    await cache.removeProtected()
    var afterRemoval = 0
    for i in 0..<20 where await cache.contains(forKey: "kept_\(i)") { afterRemoval += 1 }
    let usageAfterRemoval = await cache.protectedUsage()
    check("removing the protected entries removes them all, and the usage says so",
          afterRemoval == 0 && usageAfterRemoval == 0, "\(afterRemoval) left, usage \(String(describing: usageAfterRemoval))")

    // With no folder given they sit in one of their own beside the cache's tiles, and are as safe there.
    let inner = makeCacheDir()
    let plain = TileDiskCache(directory: inner, maxDiskBytes: 200_000, targetDiskBytes: 100_000)
    for i in 0..<3 { _ = await plain.write(tile, forKey: "kept_\(i)", protected: true) }
    for i in 0..<12 {
        _ = await plain.write(tile, forKey: "seen_\(i)")
        try? await Task.sleep(for: .milliseconds(i == 0 ? 300 : 3))
    }
    await waitFor { await heldCount(plain, prefix: "seen", of: 12) < 12 }
    await plain.clear()
    var defaultKept = 0
    for i in 0..<3 where await plain.contains(forKey: "kept_\(i)") { defaultKept += 1 }
    check("without a folder of their own, protected entries are still safe from pruning and clearing", defaultKept == 3, "\(defaultKept) of 3")

    // A key the tile cache already holds is not kept twice: writing it protected replaces the ordinary copy.
    let twiceDirectory = makeCacheDir(), twiceVault = makeCacheDir()
    let twice = TileDiskCache(directory: twiceDirectory, maxDiskBytes: 1_000_000, targetDiskBytes: 800_000, protectedDirectory: twiceVault)
    _ = await twice.write(tile, forKey: "both")
    let sizeWithOrdinary = await twice.measureDiskUsage()
    _ = await twice.write(tile, forKey: "both", protected: true)
    let sizeAfter = await twice.measureDiskUsage()
    check("writing a key protected that the tile cache holds replaces the ordinary copy: the bytes are kept once",
          sizeWithOrdinary == 40_000 && sizeAfter == 0 && fileNames(twiceVault).count == 1 && fileNames(twiceDirectory).isEmpty,
          "\(String(describing: sizeWithOrdinary)) -> \(String(describing: sizeAfter)), vault \(fileNames(twiceVault)), cache \(fileNames(twiceDirectory))")

    // Pinning a key that is protected already leaves one copy: a tile fetched into the tile cache while it was being
    // downloaded is dropped, not kept beside it.
    let dupDirectory = makeCacheDir(), dupVault = makeCacheDir()
    let dup = TileDiskCache(directory: dupDirectory, maxDiskBytes: 1_000_000, targetDiskBytes: 800_000, protectedDirectory: dupVault)
    _ = await dup.write(tile, forKey: "twice", protected: true)
    _ = await dup.write(tile, forKey: "twice")
    let pinnedAgain = await dup.pin(forKey: "twice")
    let dupUsage = await dup.measureDiskUsage()
    check("pinning a key that is protected already drops the tile cache's duplicate and keeps the bytes once",
          pinnedAgain && dupUsage == 0 && fileNames(dupVault).count == 1 && fileNames(dupDirectory).isEmpty,
          "\(pinnedAgain), tile cache \(String(describing: dupUsage)) bytes, vault \(fileNames(dupVault))")

    // A store that has never held anything has no folder yet: that is zero bytes, not an error, and asking does not make one.
    let unmade = FileManager.default.temporaryDirectory.appendingPathComponent("never-made-\(UUID().uuidString)")
    let fresh = TileDiskCache(directory: makeCacheDir(), protectedDirectory: unmade)
    let freshUsage = await fresh.protectedUsage()
    await fresh.removeProtected()
    let freshHas = await fresh.contains(forKey: "anything")
    check("a store that has never held anything reports zero bytes, and asking about it does not make its folder",
          freshUsage == 0 && !freshHas && !FileManager.default.fileExists(atPath: unmade.path),
          "\(String(describing: freshUsage)), folder made \(FileManager.default.fileExists(atPath: unmade.path))")

    // What is kept is downloadable again, so it stays out of backups, which is what the guidelines ask of anything outside Caches.
    let excluded = (try? twiceVault.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
    check("the protected folder is excluded from backup", excluded == true, "\(String(describing: excluded))")

    let unwritable = TileDiskCache(directory: URL(fileURLWithPath: "/dev/null/offline"))
    check("a protected write that could not reach the disk says so", await unwritable.write(Data([1]), forKey: "k", protected: true) == false)
}

// MARK: - S2. Budget

@MainActor
private func checkOfflineBudget() {
    print("\n--- S2. what may still be kept offline ---")
    func left(_ budget: Int64, _ used: Int64, free: Int64, reserve: Int64 = 1_000) -> Int64 {
        OfflineStorageBudget.remaining(budget: budget, used: used, freeDiskBytes: free, reserve: reserve)
    }
    check("what may still be kept is the budget less what is kept, and no more than the disk has beyond a reserve",
          left(2_000, 500, free: 10_000) == 1_500 && left(2_000, 0, free: 1_500) == 500 && left(2_000, 0, free: 3_000) == 2_000,
          "\(left(2_000, 500, free: 10_000)) \(left(2_000, 0, free: 1_500)) \(left(2_000, 0, free: 3_000))")
    check("it is never negative: a budget overspent, or a disk with less free than the reserve, leaves nothing",
          left(2_000, 3_000, free: 10_000) == 0 && left(2_000, 0, free: 500) == 0 && left(2_000, 0, free: -5) == 0
          && left(0, 0, free: 10_000) == 0)
    check("nonsense in does not trap: extremes and negatives",
          left(Int64.max, Int64.min, free: Int64.max, reserve: Int64.min) >= 0 && left(Int64.min, Int64.max, free: Int64.min, reserve: Int64.max) == 0
          && left(-1, -1, free: -1) == 0)
    let free = OfflineStorageBudget.freeDiskBytes(near: FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-made"))
    check("free space is read for a folder that does not exist yet, from the volume it will be on, and a place with no volume gives none",
          (free ?? 0) > 0 && OfflineStorageBudget.freeDiskBytes(near: URL(fileURLWithPath: "/dev/null/offline/Protected")) == nil,
          "\(String(describing: free))")
    check("the budgets are what the screen promises: 2 GB of elevation, 1 GB of basemap, and 1 GB of the disk left alone",
          OfflineStorageBudget.elevationBudgetBytes == 2 * 1024 * 1024 * 1024 && OfflineStorageBudget.basemapBudgetBytes == 1024 * 1024 * 1024
          && OfflineStorageBudget.freeSpaceReserveBytes == 1024 * 1024 * 1024)
}

@MainActor
private func checkProtectedAvailability() async {
    let cache = TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir())
    let tile = Data(repeating: 1, count: 40_000)
    for i in 0..<5 { _ = await cache.write(tile, forKey: "kept_\(i)", protected: true) }
    let open = await cache.protectedAvailable(budget: 1_000_000, reserve: 0)
    let spent = await cache.protectedAvailable(budget: 150_000, reserve: 0)
    let reserved = await cache.protectedAvailable(budget: 1_000_000, reserve: Int64.max)
    check("what a cache may still keep is its budget less its protected bytes, and nothing when the reserve is the whole disk",
          open == 800_000 && spent == 0 && reserved == 0, "\(open), \(spent), \(reserved)")
    // The disk limits it too: a reserve that leaves only about 100 MB free leaves about 100 MB to keep, of a 1 GB budget. The
    // margin is wide because free space moves while this runs (a build writing beside it moved it by hundreds of KB between
    // two calls); a disk that ignored the limit would offer the whole budget, nearly 1 GB.
    let free = OfflineStorageBudget.freeDiskBytes(near: FileManager.default.temporaryDirectory) ?? 0
    let squeezed = await cache.protectedAvailable(budget: 1_000_000_000, reserve: free - 100_000_000)
    check("the free space on the disk limits what may be kept, beyond the budget",
          free > 2_000_000_000 && squeezed > 0 && squeezed < 900_000_000, "free \(free), left \(squeezed)")
}

// MARK: - S3. A download outlasts browsing

@MainActor
private func checkHarvestedTilesOutlastBrowsing() async {
    print("\n--- S3. a harvested area outlasts ordinary browsing ---")
    let pixels = 256
    let margin = TerrainTileProvider.marginPixels
    func gridKey(_ tile: HarvestTile) -> String {
        TerrainTileProvider.gridCacheKey(x: tile.x, y: tile.y, z: tile.z, pixels: pixels, margin: margin)
    }
    func region(_ tile: HarvestTile) -> GeoRegion {
        TerrainTileOverlay.region(for: MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1))
    }
    let area = GeoRegion(center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621), latitudeSpan: 0.002, longitudeSpan: 0.002)
    let tiles = OfflineHarvestCoordinator.tiles(for: HarvestConfiguration(region: area, minZ: 16, maxZ: 18, pixels: pixels))

    // A tile cache that holds about two rasters (282,880 bytes each) and prunes down to one.
    let directory = makeCacheDir(), vault = makeCacheDir()
    let cache = TileDiskCache(directory: directory, maxDiskBytes: 600_000, targetDiskBytes: 450_000, protectedDirectory: vault)
    HarvestNetworkProtocol.set(serving: nil)
    let stub = CountingElevationStub()
    let provider = TerrainTileProvider(
        elevation: stub, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: cache)
    let manifests = makeCacheDir()
    let seeded = await HarvestRun(
        OfflineHarvestCoordinator(elevation: provider.elevationHarvestSource, manifestDirectory: manifests),
        HarvestConfiguration(region: area, minZ: 16, maxZ: 18, pixels: pixels)).summary()
    check("the harvest stores the whole area, well past what the tile cache alone would hold",
          tiles.count >= 4 && seeded?.completed == tiles.count && seeded?.failed == 0, "\(String(describing: seeded)) of \(tiles.count)")

    // Browsing somewhere else fills the ordinary cache many times over.
    let far = HarvestTile(x: tiles[0].x + 400, y: tiles[0].y + 400, z: 17)
    for k in 0..<12 {
        let t = HarvestTile(x: far.x + k, y: far.y, z: 17)
        _ = await provider.tileImage(x: t.x, y: t.y, z: t.z, region: region(t), pixels: pixels)
    }
    func browsedHeld() async -> Int {
        var held = 0
        for k in 0..<12 where await cache.contains(forKey: gridKey(HarvestTile(x: far.x + k, y: far.y, z: 17))) { held += 1 }
        return held
    }
    await waitFor { await browsedHeld() < 12 }
    let browsedLeft = await browsedHeld()
    var kept = 0
    for tile in tiles where await cache.contains(forKey: gridKey(tile)) { kept += 1 }
    check("after browsing has filled and pruned the cache, every harvested tile is still on disk",
          browsedLeft < 12 && kept == tiles.count, "\(kept) of \(tiles.count) harvested, \(browsedLeft) of 12 browsed left")

    // What was kept is counted, and can be removed without touching what browsing cached.
    let keptBytes = await provider.offlineElevationBytes()
    check("the downloaded elevation is counted on its own, and is what the harvest reported storing",
          keptBytes == seeded?.bytesStored && (keptBytes ?? 0) > 0, "\(String(describing: keptBytes)) vs \(String(describing: seeded?.bytesStored))")

    // A fresh provider with the network cut draws them without a request.
    let offlineSource = CountingElevationStub()
    let offline = TerrainTileProvider(
        elevation: offlineSource, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
        gridCache: TileDiskCache(directory: directory, maxDiskBytes: 600_000, targetDiskBytes: 450_000, protectedDirectory: vault))
    var drawn = 0
    for tile in tiles where await offline.tileImage(x: tile.x, y: tile.y, z: tile.z, region: region(tile), pixels: pixels) != nil { drawn += 1 }
    check("and a provider started afterwards with no network draws them all without fetching anything",
          drawn == tiles.count && offlineSource.callCount == 0, "\(drawn) of \(tiles.count) drawn, \(offlineSource.callCount) fetches")

    let browsedBefore = browsedLeft
    await provider.removeOfflineElevation()
    var keptAfterRemoval = 0
    for tile in tiles where await cache.contains(forKey: gridKey(tile)) { keptAfterRemoval += 1 }
    var browsedAfterRemoval = 0
    for k in 0..<12 where await cache.contains(forKey: gridKey(HarvestTile(x: far.x + k, y: far.y, z: 17))) { browsedAfterRemoval += 1 }
    let bytesAfterRemoval = await provider.offlineElevationBytes()
    check("removing the downloaded elevation removes every harvested tile and only those: what browsing cached is still there",
          keptAfterRemoval == 0 && bytesAfterRemoval == 0 && browsedAfterRemoval == browsedBefore,
          "\(keptAfterRemoval) harvested left, \(String(describing: bytesAfterRemoval)) bytes, browsed \(browsedBefore) -> \(browsedAfterRemoval)")

    // A tile the map already had is pinned by the harvest, not fetched again.
    let pinDirectory = makeCacheDir(), pinVault = makeCacheDir()
    let pinCache = TileDiskCache(directory: pinDirectory, maxDiskBytes: 600_000, targetDiskBytes: 450_000, protectedDirectory: pinVault)
    let pinStub = CountingElevationStub()
    let pinning = TerrainTileProvider(
        elevation: pinStub, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: pinCache)
    let tile = tiles[0]
    _ = await pinning.tileImage(x: tile.x, y: tile.y, z: tile.z, region: region(tile), pixels: pixels)
    for _ in 0..<300 where !(await pinCache.contains(forKey: gridKey(tile))) { try? await Task.sleep(for: .milliseconds(10)) }
    let callsBefore = pinStub.callCount
    let ordinaryHadIt = !fileNames(pinDirectory).filter { $0.hasSuffix(".cache") }.isEmpty
    let outcome = await pinning.elevationHarvestSource.harvest(tile, pixels: pixels)
    let movedOut = fileNames(pinDirectory).filter { $0.hasSuffix(".cache") }.isEmpty
    let movedIn = fileNames(pinVault).filter { $0.hasSuffix(".cache") }.count == 1
    await pinCache.clear()
    let stillHeld = await pinCache.contains(forKey: gridKey(tile))
    check("harvesting a tile the map already had keeps it without fetching it again, and it survives the tile cache being cleared",
          outcome == .alreadyCached && pinStub.callCount == callsBefore && stillHeld,
          "\(outcome), \(callsBefore) -> \(pinStub.callCount) fetches, held after clearing \(stillHeld)")
    check("it is moved into protected storage rather than copied: the tile cache no longer has it, and the bytes are kept once",
          ordinaryHadIt && movedOut && movedIn, "had \(ordinaryHadIt), left the cache \(movedOut), in the vault \(movedIn)")

    // What the download may add is what is left of the elevation budget, and the disk's own room.
    let room = await provider.offlineElevationAvailableBytes()
    let disk = OfflineStorageBudget.freeDiskBytes(near: vault) ?? Int64.max
    let spare = max(disk - OfflineStorageBudget.freeSpaceReserveBytes, 0)
    let budgetLimited = room == OfflineStorageBudget.elevationBudgetBytes
    let diskLimited = abs(room - spare) < 100_000_000       // free space moves while this runs
    check("what may still be downloaded is the elevation budget when the disk has the room for it, and what the disk can spare when it has not",
          budgetLimited || diskLimited, "room \(room), budget \(OfflineStorageBudget.elevationBudgetBytes), disk can spare \(spare)")
}

// MARK: - S4. Basemaps

@MainActor
private func checkBasemapTilesAreProtected() async {
    print("\n--- S4. basemap tiles ---")
    let cache = TileDiskCache(directory: makeCacheDir(), maxDiskBytes: 100_000, targetDiskBytes: 50_000, protectedDirectory: makeCacheDir())
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 120))
    let source = BasemapHarvestSource(basemap: .imagery, cache: cache, session: HarvestNetworkProtocol.session)
    let tile = HarvestTile(x: 16371, y: 25123, z: 16)
    let outcome = await source.harvest(tile, pixels: 512)
    await cache.clear()
    let held = await cache.contains(forKey: TerrainBasemap.harvestKey(.imagery, tile))
    var stored = false
    if case .stored = outcome { stored = true }
    check("a harvested basemap tile is kept where clearing the tile cache does not reach", stored && held, "\(outcome), held \(held)")

    // A tile an earlier version left in the ordinary cache is kept as it is, without being fetched again.
    let legacyDirectory = makeCacheDir(), legacyVault = makeCacheDir()
    let legacy = TileDiskCache(directory: legacyDirectory, maxDiskBytes: 100_000, targetDiskBytes: 50_000, protectedDirectory: legacyVault)
    let key = TerrainBasemap.harvestKey(.imagery, tile)
    _ = await legacy.write(Data(repeating: 9, count: 2_000), forKey: key)
    HarvestNetworkProtocol.set(serving: nil)
    let before = HarvestNetworkProtocol.requestCount
    let pinned = await BasemapHarvestSource(basemap: .imagery, cache: legacy, session: HarvestNetworkProtocol.session).harvest(tile, pixels: 512)
    let requests = HarvestNetworkProtocol.requestCount - before
    await legacy.clear()
    let stillThere = await legacy.contains(forKey: key)
    check("a basemap tile already in the tile cache is kept by moving it, with no request, and survives clearing",
          pinned == .alreadyCached && requests == 0 && stillThere && fileNames(legacyDirectory).isEmpty && fileNames(legacyVault).count == 1,
          "\(pinned), \(requests) requests, held \(stillThere), cache \(fileNames(legacyDirectory)), vault \(fileNames(legacyVault))")
}

// MARK: - S5. The controller

private nonisolated final class Room: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    private var asked = 0
    init(_ bytes: Int64) { self.bytes = bytes }
    /// Reading it is being asked.
    var value: Int64 { lock.withLock { asked += 1; return bytes } }
    var timesAsked: Int { lock.withLock { asked } }
    func set(_ newValue: Int64) { lock.withLock { bytes = newValue } }
}

@MainActor
private func checkControllerSizesAgainstWhatIsLeft() async {
    print("\n--- S5. the download screen sizes a job against what may still be kept ---")
    let elevationRoom = Room(Int64.max / 2), basemapRoom = Room(Int64.max / 2)
    let controller = OfflineHarvestController(
        region: downloadRegion, minZ: 15, maxZ: 16,
        environment: OfflineHarvestController.Environment(
            elevation: MockHarvestSource(bytesPerTile: 20_000_000, delayMilliseconds: 1),
            basemaps: MockHarvestSource(bytesPerTile: 10_000_000, delayMilliseconds: 1), basemapName: "Shaded relief",
            observedPixels: { 384 }, manifestDirectory: manifestDirectory(),
            elevationAvailableBytes: { elevationRoom.value }, basemapAvailableBytes: { basemapRoom.value },
            keepAwake: { _ in }))
    await controller.refreshEstimate()
    let estimate = controller.estimate?.elevationBytes ?? 0
    check("with room to spare a job of 36 tiles at 20 MB is sized and not blocked",
          controller.blocker == nil && controller.canStart && estimate == 720_000_000, "\(String(describing: controller.estimate))")

    elevationRoom.set(estimate / 2)
    await controller.refreshEstimate()
    let refused = controller.blocker
    let message = refused?.message ?? ""
    check("the room is asked afresh each time a job is sized: once earlier downloads have used it, the same job is refused, saying how much more fits and where to make room",
          refused == .tooLarge(cache: "elevation", estimatedBytes: estimate, availableBytes: estimate / 2) && !controller.canStart
          && message.contains("elevation") && message.contains("720 MB") && message.contains("360 MB")
          && message.contains("more") && message.contains("Settings"),
          "\(String(describing: refused)) '\(message)'")

    elevationRoom.set(estimate)
    await controller.refreshEstimate()
    let exact = controller.blocker
    elevationRoom.set(estimate - 1)
    await controller.refreshEstimate()
    let oneShort = controller.blocker
    check("a job exactly as large as what is left is allowed, and one byte over is not",
          exact == nil && oneShort == .tooLarge(cache: "elevation", estimatedBytes: estimate, availableBytes: estimate - 1),
          "\(String(describing: exact)) / \(String(describing: oneShort))")

    elevationRoom.set(Int64.max / 2)
    let askedBefore = basemapRoom.timesAsked
    await controller.refreshEstimate()
    let askedWithout = basemapRoom.timesAsked - askedBefore
    controller.includeBasemaps = true
    basemapRoom.set(controller.estimate?.basemapBytes ?? 0)
    await controller.refreshEstimate()
    let basemapBytes = controller.estimate?.basemapBytes ?? 0
    basemapRoom.set(basemapBytes - 1)
    await controller.refreshEstimate()
    let basemapRefused = controller.blocker
    controller.includeBasemaps = false
    await controller.refreshEstimate()
    check("the basemap has its own room, asked only when the job includes a basemap, and a job that leaves it out is not held up by it",
          askedWithout == 0 && basemapBytes == 360_000_000
          && basemapRefused == .tooLarge(cache: "basemap", estimatedBytes: basemapBytes, availableBytes: basemapBytes - 1)
          && controller.blocker == nil,
          "asked \(askedWithout), \(basemapBytes), \(String(describing: basemapRefused)), \(String(describing: controller.blocker))")

    // Removing what was downloaded must take resuming with it: a manifest would skip tiles that are gone.
    let directory = manifestDirectory()
    let slow = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 40)
    let interrupted = makeController(elevation: slow, directory: directory)
    let run = Task { await interrupted.start() }
    await waitUntil { slow.calls.count >= 4 }
    interrupted.forgetDownloads()                       // a job is running: ignored
    let ignoredWhileRunning = interrupted.isBusy && !manifestFiles(directory).isEmpty && interrupted.phase == .running
    interrupted.cancel()
    await waitUntil { isFinished(interrupted) }
    await run.value
    let couldResume = interrupted.canResume && !manifestFiles(directory).isEmpty
    interrupted.forgetDownloads()
    check("forgetting downloads is ignored while a job runs; once it has stopped, it makes the job unresumable, deletes its manifest and clears the last result",
          ignoredWhileRunning && couldResume && !interrupted.canResume && manifestFiles(directory).isEmpty
          && interrupted.phase == .idle && interrupted.progress == nil,
          "running \(ignoredWhileRunning), could resume \(couldResume), now \(interrupted.canResume), \(manifestFiles(directory).count) manifests, \(interrupted.phase)")
    let callsBefore = slow.calls.count
    await interrupted.resumeInterrupted()
    check("resuming afterwards does nothing", slow.calls.count == callsBefore && interrupted.phase == .idle, "\(slow.calls.count - callsBefore) calls, \(interrupted.phase)")
    await interrupted.start()
    check("and a job started afterwards fetches every tile again",
          slow.calls.count - callsBefore == 36 && summary(of: interrupted)?.completed == 36, "\(slow.calls.count - callsBefore) calls")
}

// MARK: - S6. Manifests

@MainActor
private func checkManifestRemoval() {
    print("\n--- S6. manifests ---")
    let directory = manifestDirectory()
    let ids = [UUID(), UUID()]
    for id in ids { try? Data("{}".utf8).write(to: OfflineHarvestCoordinator.manifestURL(for: id, in: directory)) }
    try? Data("keep".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    try? Data("{}".utf8).write(to: directory.appendingPathComponent("other.json"))
    OfflineHarvestCoordinator.removeManifests(in: directory)
    let left = fileNames(directory)
    OfflineHarvestCoordinator.removeManifests(in: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
    check("removing manifests deletes harvest manifests and nothing else, and a folder that is not there is no trouble",
          left == ["notes.txt", "other.json"], "\(left)")
}

// MARK: - S7. The model's storage rows

@MainActor
private func checkModelStorageRows() async {
    print("\n--- S7. the storage rows and removing downloads ---")
    let gridCache = TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir())
    // The basemap store's folder is not there yet, as it is on a device that has never downloaded anything.
    let basemapCache = TileDiskCache(
        directory: makeCacheDir(), protectedDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("basemaps-\(UUID().uuidString)"))
    let manifests = manifestDirectory()
    let provider = TerrainTileProvider(
        elevation: CountingElevationStub(), terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session), gridCache: gridCache)
    let model = TerrainViewerModel(
        terrainProvider: provider, offlineLocations: .init(basemapCache: basemapCache, manifestDirectory: manifests))

    let bytes = { (count: Int64) in ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    await model.refreshDiskCacheStats()
    check("with nothing downloaded the row says so, and there is nothing to remove",
          model.offlineDownloadsSizeFormatted == "None" && !model.hasOfflineDownloads, "'\(model.offlineDownloadsSizeFormatted)'")

    for i in 0..<3 { _ = await gridCache.write(Data(repeating: 1, count: 10_000), forKey: "grid_\(i)", protected: true) }
    for i in 0..<2 { _ = await basemapCache.write(Data(repeating: 2, count: 5_000), forKey: "base_\(i)", protected: true) }
    _ = await gridCache.write(Data(repeating: 3, count: 7_000), forKey: "browsed")
    await model.refreshDiskCacheStats()
    check("Offline Downloads counts elevation and basemap together, apart from the tile cache",
          model.offlineDownloadsSizeFormatted == bytes(40_000) && model.hasOfflineDownloads
          && model.diskCacheSizeFormatted == bytes(7_000),
          "downloads '\(model.offlineDownloadsSizeFormatted)', tiles '\(model.diskCacheSizeFormatted)'")

    // Clearing the tile cache leaves the downloads, and the row still counts them.
    await model.clearDiskCache()
    check("clearing the tile cache leaves the downloads and the row still counts them",
          model.offlineDownloadsSizeFormatted == bytes(40_000) && model.hasOfflineDownloads, "'\(model.offlineDownloadsSizeFormatted)'")

    _ = await gridCache.write(Data(repeating: 4, count: 7_000), forKey: "browsed_again")

    // A running download blocks removal.
    let slow = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 40)
    let directoryForJob = manifests
    let controller = makeController(elevation: slow, directory: directoryForJob)
    let idleBefore = model.isDownloadingOffline
    model.offlineHarvestController = controller
    let run = Task { await controller.start() }
    await waitUntil { slow.calls.count >= 4 }
    let downloadingWhileRunning = model.isDownloadingOffline
    let refusedWhileRunning = await model.removeOfflineDownloads()
    let heldWhileRunning = await gridCache.protectedUsage()
    controller.cancel()
    await waitUntil { isFinished(controller) }
    await run.value
    check("the model knows a download is running while it is, and not before or after",
          !idleBefore && downloadingWhileRunning && !model.isDownloadingOffline,
          "before \(idleBefore), running \(downloadingWhileRunning), after \(model.isDownloadingOffline)")
    check("removal is refused while a download is running, and removes nothing",
          !refusedWhileRunning && heldWhileRunning == 30_000 && controller.canResume,
          "returned \(refusedWhileRunning), \(String(describing: heldWhileRunning)) held")

    // Then it removes everything downloaded and the job records, and the job cannot be resumed.
    let hadManifests = !manifestFiles(manifests).isEmpty
    let removed = await model.removeOfflineDownloads()
    let elevationLeft = await gridCache.protectedUsage()
    let basemapLeft = await basemapCache.protectedUsage()
    let browsedStill = await gridCache.contains(forKey: "browsed_again")
    check("once it has stopped, removal takes the elevation, the basemap tiles and the job records, and leaves the tile cache",
          removed && hadManifests && elevationLeft == 0 && basemapLeft == 0 && manifestFiles(manifests).isEmpty && browsedStill
          && !controller.canResume,
          "returned \(removed), manifests before \(hadManifests), left \(String(describing: elevationLeft))/\(String(describing: basemapLeft)), tile cache kept \(browsedStill)")
    check("and the row says so",
          model.offlineDownloadsSizeFormatted == "None" && !model.hasOfflineDownloads, "'\(model.offlineDownloadsSizeFormatted)'")

    // On a fresh launch no download screen has been made, so no controller is there to forget its job; the records of earlier
    // launches' jobs are still on disk, and removal deletes them itself.
    let earlierJobs = manifestDirectory()
    for _ in 0..<2 { try? Data("{}".utf8).write(to: OfflineHarvestCoordinator.manifestURL(for: UUID(), in: earlierJobs)) }
    let freshModel = TerrainViewerModel(
        terrainProvider: TerrainTileProvider(
            elevation: CountingElevationStub(), terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
            gridCache: TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir())),
        offlineLocations: .init(basemapCache: TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir()),
                                manifestDirectory: earlierJobs))
    let hadEarlier = manifestFiles(earlierJobs).count == 2 && freshModel.offlineHarvestController == nil
    let removedEarlier = await freshModel.removeOfflineDownloads()
    check("with no download screen made yet, removal still deletes the job records that earlier launches left",
          hadEarlier && removedEarlier && manifestFiles(earlierJobs).isEmpty,
          "had \(hadEarlier), returned \(removedEarlier), \(manifestFiles(earlierJobs).count) left")

    // Two removals at once: one runs and the other declines, and the model says while it is deleting.
    let busyModel = TerrainViewerModel(
        terrainProvider: TerrainTileProvider(
            elevation: CountingElevationStub(), terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
            gridCache: TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir())),
        offlineLocations: .init(basemapCache: TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir()),
                                manifestDirectory: manifestDirectory()))
    let idleFlag = busyModel.isRemovingOfflineDownloads
    async let firstRemoval = busyModel.removeOfflineDownloads()
    async let secondRemoval = busyModel.removeOfflineDownloads()
    let outcomes = await [firstRemoval, secondRemoval]
    check("two removals at once do not overlap: one runs and the other declines, and the model is not left saying it is deleting",
          !idleFlag && outcomes.filter { $0 }.count == 1 && !busyModel.isRemovingOfflineDownloads,
          "idle \(idleFlag), outcomes \(outcomes), still removing \(busyModel.isRemovingOfflineDownloads)")

    // A store that cannot be read is not an empty one: the row does not claim there is nothing, and removal stays available.
    let lockedVault = makeCacheDir()
    let lockedBasemaps = TileDiskCache(directory: makeCacheDir(), protectedDirectory: lockedVault)
    _ = await lockedBasemaps.write(Data(repeating: 5, count: 1_000), forKey: "base_0", protected: true)
    let lockedModel = TerrainViewerModel(
        terrainProvider: TerrainTileProvider(
            elevation: CountingElevationStub(), terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
            gridCache: TileDiskCache(directory: makeCacheDir(), protectedDirectory: makeCacheDir())),
        offlineLocations: .init(basemapCache: lockedBasemaps, manifestDirectory: manifestDirectory()))
    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedVault.path)
    await lockedModel.refreshDiskCacheStats()
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedVault.path)
    check("a store that cannot be read shows a dash, not none, and can still be removed",
          lockedModel.offlineDownloadsSizeFormatted == "—" && lockedModel.hasOfflineDownloads,
          "'\(lockedModel.offlineDownloadsSizeFormatted)', removable \(lockedModel.hasOfflineDownloads)")
}
