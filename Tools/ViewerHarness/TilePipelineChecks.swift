//
//  TilePipelineChecks.swift
//  ViewerHarness
//
//  The 2026-11-01 tile pipeline audit's confirmed findings: a culled fetch stops at once, the upgrade cap holds at
//  the deadline, shading is admitted a few tiles at a time, every fetched raster is born in pages, a stand-in leaves
//  its native neighbours alone, a relight keeps a sun-invariant layer, the robust extent reads in place, and the
//  source name says the level read.
//

import CoreLocation
import Foundation
import MapKit
import os

/// Polls `condition` every 10 ms until it holds or `seconds` pass; returns whether it held.
private func tpEventually(_ seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// The z19 tile `dx` east of the Cahokia tile, and its region.
private func cahokiaNeighbour(dx: Int, dy: Int = 0) -> (x: Int, y: Int, region: GeoRegion) {
    let (x, y, _) = cahokiaTile(z: 19)
    let path = MKTileOverlayPath(x: x + dx, y: y + dy, z: 19, contentScaleFactor: 1)
    return (x + dx, y + dy, TerrainTileOverlay.region(for: path))
}

/// A provider over `native` with Terrarium served from memory, and a fresh disk cache under `directory`.
@MainActor
private func makeStandInProvider(native: any ElevationProviding, directory: URL) -> TerrainTileProvider {
    HarvestNetworkProtocol.set(serving: terrariumPNG(elevation: 200))
    return TerrainTileProvider(
        elevation: native, terrarium: TerrariumTileService(session: HarvestNetworkProtocol.session),
        gridCache: TileDiskCache(directory: directory))
}

// MARK: - TP1

/// TP1. A tile's load task cancelled by the cull (`cullTiles(outsideVisible:)`) reached `native.cancel()` only once
/// `first(of:within:)` returned at the 2 s deadline, and on the branch with no stand-in (eight upgrades running, the
/// read-back, the harvester) only once the whole native fetch had returned: the ImageServer's 12-20 s of work ran on
/// for ground the map had left. Both suspensions now wake on cancellation and cancel the native task at once.
@MainActor
private func checkCulledFetchStopsAtOnce() async {
    print("\n--- TP1. a culled fetch cancels its native request at once, not at the deadline ---")
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-pipeline-cancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let native = CancellableTerrainStub(base: SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1), delay: .seconds(4))
    let provider = makeStandInProvider(native: native, directory: directory)
    let (x, y, region) = cahokiaTile(z: 19)

    // a. A prompt load (the map's): the race against the budget.
    let load = Task { await provider.tileImage(x: x, y: y, z: 19, region: region, pixels: 512) }
    try? await Task.sleep(for: .milliseconds(100))
    load.cancel()
    check("a prompt load cancelled 100 ms in cancels its native request within 500 ms",
          await tpEventually(0.5) { native.cancelled >= 1 }, "\(native.cancelled) cancelled")
    check("and answers nothing", await load.value == nil)
    check("with no upgrade left behind", await provider.upgradesInFlight().isEmpty, "\(await provider.upgradesInFlight())")

    // b. A load with no stand-in (the harvester's): the plain await of the native task.
    let harvest = Task { await provider.harvestTile(x: x + 1, y: y, z: 19, pixels: 512) }
    try? await Task.sleep(for: .milliseconds(100))
    harvest.cancel()
    check("a harvest cancelled 100 ms in cancels its native request within 500 ms",
          await tpEventually(0.5) { native.cancelled >= 2 }, "\(native.cancelled) cancelled")
    if case .failed = await harvest.value {
        check("and fails as cancelled", true)
    } else {
        check("and fails as cancelled", false)
    }
    HarvestNetworkProtocol.set(serving: nil)
}

// MARK: - TP2

/// TP2. `upgradeLimit` was checked before the race against the budget, so a burst of tiles all passed it at t = 0 and
/// all registered upgrades at the deadline, and a tile asked for while eight ran skipped the race and waited the
/// native fetch out with no stand-in. The cap is enforced at the deadline now: a stand-in past it waits in a queue
/// for a slot, which the next upgrade to land or be cancelled gives it, and every prompt request races the budget.
@MainActor
private func checkUpgradeCapHoldsAtTheDeadline() async {
    print("\n--- TP2. the upgrade cap holds under a burst; a tile past it is answered with a stand-in ---")
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-pipeline-cap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ground = SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1)   // flat 120 m
    let provider = makeStandInProvider(native: DelayedTerrainStub(base: ground, delay: .seconds(3.5)), directory: directory)
    let burst = 12
    let tiles = (0..<burst).map { cahokiaNeighbour(dx: $0) }
    let keys = tiles.map { "19/\($0.x)/\($0.y)" }

    let started = ContinuousClock.now
    let answered = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for tile in tiles {
            group.addTask { await provider.tileImage(x: tile.x, y: tile.y, z: 19, region: tile.region, pixels: 512) != nil }
        }
        var count = 0
        for await ok in group where ok { count += 1 }
        return count
    }
    let elapsed = ContinuousClock.now - started
    check("twelve tiles asked for at once are all answered within the budget", answered == burst && elapsed < .seconds(2.8),
          "\(answered) answered in \(elapsed)")
    let running = await provider.upgradesInFlight()
    check("eight upgrades run at the deadline, not twelve", running.count == TerrainTileProvider.upgradeLimit, "\(running.count)")
    let queued = await provider.queuedUpgradeKeys()
    check("and the other four wait for a slot", Set(queued) == Set(keys).subtracting(running) && queued.count == burst - TerrainTileProvider.upgradeLimit,
          "\(queued.count) queued")

    // A thirteenth tile asked for while eight run: a stand-in within the budget, not the native fetch's 3.5 s.
    let late = cahokiaNeighbour(dx: burst)
    let askedLate = ContinuousClock.now
    let lateImage = await provider.tileImage(x: late.x, y: late.y, z: 19, region: late.region, pixels: 512)
    let lateElapsed = ContinuousClock.now - askedLate
    check("a tile asked for while eight upgrades run is answered with a stand-in within the budget",
          lateImage != nil && lateElapsed < .seconds(2.8), "\(lateElapsed)")

    // The eight land, the four queued start and land, the late one lands: every tile ends native.
    let allNative = await tpEventually(9) {
        for tile in tiles + [late] {
            guard let value = await provider.elevation(at: tile.region.center), abs(value - 120) < 1 else { return false }
        }
        return true
    }
    check("when the eight land the queued four start, and every tile ends with its native raster", allNative)
    let leftQueued = await provider.queuedUpgradeKeys()
    let leftRunning = await provider.upgradesInFlight()
    check("with nothing left queued or running", leftQueued.isEmpty && leftRunning.isEmpty, "\(leftQueued) \(leftRunning)")
    HarvestNetworkProtocol.set(serving: nil)
}

// MARK: - TP3

/// TP3. Nothing bounded how many tiles were between their settings snapshot and the GPU: a flick asked for every
/// tile it swept past and each one's command buffer was committed before the cull cancelled it. Shading is admitted
/// a few tiles at a time now (`TerrainTileProvider.shadingLimit`), first come first served, and a tile cancelled
/// while it waits never reaches the GPU.
@MainActor
private func checkShadingAdmittedAFewAtATime() async {
    print("\n--- TP3. shading is admitted a few tiles at a time; a tile cancelled while waiting is never shaded ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    check("the gate admits four tiles at once", TerrainTileProvider.shadingLimit == 4, "\(TerrainTileProvider.shadingLimit)")
    await scene.provider.setShadingLimit(1)
    await scene.provider.holdShadingSlot()

    let offsets = (0..<12).map { ($0 % 4 - 1, $0 / 4 - 1) }
    let loads = offsets.map { (dx, dy) in Task { await scene.image(dx: dx, dy: dy) } }
    check("twelve requests wait at the held gate", await tpEventually { await scene.provider.shadingWaiterCount() == 12 },
          "\(await scene.provider.shadingWaiterCount()) waiting")
    for load in loads.dropFirst() { load.cancel() }
    check("cancelling eleven leaves one waiting", await tpEventually { await scene.provider.shadingWaiterCount() == 1 },
          "\(await scene.provider.shadingWaiterCount()) waiting")
    var cancelledAnswers = 0
    for load in loads.dropFirst() where await load.value == nil { cancelledAnswers += 1 }
    check("and the eleven answer nothing", cancelledAnswers == 11, "\(cancelledAnswers)")

    await scene.provider.releaseShadingHold()
    check("released, the one left shades", await loads[0].value != nil)
    var shaded = 0
    for (dx, dy) in offsets where await scene.provider.shadeCount(for: "\(scene.z)/\(scene.x + dx)/\(scene.y + dy)") > 0 { shaded += 1 }
    check("one tile was shaded, the eleven never were", shaded == 1, "\(shaded) shaded")
    let waitingAfter = await scene.provider.shadingWaiterCount()
    let inFlightAfter = await scene.provider.shadingInFlightCount()
    check("the gate is empty again", waitingAfter == 0 && inFlightAfter == 0, "\(waitingAfter) waiting, \(inFlightAfter) in flight")
    await scene.provider.setShadingLimit(nil)
}

// MARK: - TP4

/// TP4. A tile took its settings snapshot as soon as its raster was in hand, so a 20 Hz dial drag committed every
/// visible tile to the GPU under a sun the dial had already left, then again for each step after. A tile admitted
/// from the gate snapshots the settings then: shaded once under the newest sun, its bitmap answers the re-request the
/// reload makes.
@MainActor
private func checkWaitingTileShadesUnderTheNewestSun() async {
    print("\n--- TP4. a tile admitted from the gate is shaded under the settings current then, once ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    let key = "\(scene.z)/\(scene.x)/\(scene.y)"
    var west = await scene.provider.currentSettings()
    west.style = .hillshade
    west.azimuthDegrees = 270
    await scene.provider.update(west)
    await scene.provider.setShadingLimit(1)
    await scene.provider.holdShadingSlot()
    let load = Task { await scene.image() }
    check("the tile waits at the gate", await tpEventually { await scene.provider.shadingWaiterCount() == 1 })
    var east = west
    east.azimuthDegrees = 90
    await scene.provider.update(east)
    await scene.provider.releaseShadingHold()
    let image = await load.value
    check("released, it shades", image != nil)
    let shadesAfterRelease = await scene.provider.shadeCount(for: key)
    let keptBitmap = await scene.provider.renderedTileKeys().contains(key)
    check("once, under the sun current at admission, and its bitmap is kept", shadesAfterRelease == 1 && keptBitmap,
          "\(shadesAfterRelease) shades, kept \(keptBitmap)")
    _ = await scene.image()
    check("so the re-request after the reload is a cache hit", await scene.provider.shadeCount(for: key) == 1)

    let fresh = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: fresh.directory) }
    await fresh.provider.update(east)
    let scratch = await fresh.image()
    let a = image.flatMap { rgbaBytes($0) }, b = scratch.flatMap { rgbaBytes($0) }
    check("and the picture is the from-scratch render under the new sun", a != nil && a == b)
    await scene.provider.setShadingLimit(nil)
}

// MARK: - The section

@MainActor
func runTilePipelineChecks() async {
    print("\n=== Tile pipeline audit remediation (2026-11-01) ===")
    await checkCulledFetchStopsAtOnce()
    await checkUpgradeCapHoldsAtTheDeadline()
    await checkShadingAdmittedAFewAtATime()
    await checkWaitingTileShadesUnderTheNewestSun()
}
