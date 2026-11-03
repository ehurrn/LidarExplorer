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

// MARK: - TP5

/// TP5. A raster from the network reached the provider as a heap array: the COG path copied the resampler's pages
/// onto the heap for nothing (`StreamedRaster.grid`), the ImageServer's decode and the Terrarium cuts wrote arrays.
/// Its first shade then copied the array into a shared buffer, and its second copied it into pages on the provider
/// actor. Every producer writes pages now (`ElevationGrid.inPages`), so a fetched tile is zero-copy from its first
/// shade and the provider never copies it.
@MainActor
private func checkFetchedRastersAreBornInPages() async {
    print("\n--- TP5. every fetched raster is born in page-aligned pages: the first shade adopts it, no copy follows ---")

    // a. The COG path: the coordinator's grid is the resampler's pages.
    let fixture = tiledCOG(tilesAcross: 8, tilesDown: 8, side: 64)
    COGServiceURLProtocol.reset(file: fixture)
    let coordinator = ElevationTileCoordinator(transport: cogTransport())
    guard let geo = await coordinator.georeference(for: fixtureCOGURL) else {
        check("setup: the fixture georeferences", false)
        return
    }
    let centre = geo.coordinate(forPixel: SIMD2(256, 256))
    let z = 19
    let n = pow(2.0, Double(z))
    let tx = Int((centre.longitude + 180) / 360 * n)
    let ty = Int((1 - asinh(tan(centre.latitude * .pi / 180)) / .pi) / 2 * n)
    let tileRegion = TerrainTileOverlay.region(for: MKTileOverlayPath(x: tx, y: ty, z: z, contentScaleFactor: 1))
    let around = GeoRegion(center: centre, latitudeSpan: tileRegion.latitudeSpan * 8, longitudeSpan: tileRegion.longitudeSpan * 8)
    COGServiceURLProtocol.setProducts(productsJSON(url: fixtureCOGURL, around: around))
    let streamed = await coordinator.elevation(for: tileRegion, targetSamples: 128).value
    check("a COG raster's grid lies in the resampler's pages, not a heap copy", streamed?.isPageAligned == true,
          "\(String(describing: streamed?.isPageAligned))")

    // b. The ImageServer path: the decoded TIFF is voided into pages.
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailureURLProtocol.self]
    let tiff = Data(fixture)
    FailureURLProtocol.responseGenerator = {
        (tiff, HTTPURLResponse(url: URL(string: "https://elevation.nationalmap.gov/")!, statusCode: 200, httpVersion: "HTTP/1.1",
                               headerFields: ["Content-Type": "image/tiff"]), nil)
    }
    let imageServer = USGS3DEPService(transport: HTTPTransport(session: URLSession(configuration: config)))
    let served = await imageServer.elevation(for: tileRegion, targetSamples: 64)
    check("an ImageServer raster is voided into pages", served.value?.isPageAligned == true, "\(served)")
    FailureURLProtocol.responseGenerator = nil

    // c. The provider over the COG path: paged before its first shade, and no copy across two shades.
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-pipeline-pages-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = TerrainTileProvider(elevation: coordinator, gridCache: TileDiskCache(directory: directory))
    let key = "\(z)/\(tx)/\(ty)"
    let side = 512 + 2 * TerrainTileProvider.marginPixels
    let plane = side * side * MemoryLayout<Float>.stride
    let bitmap = 512 * 512 * 4
    let first = await provider.tileImage(x: tx, y: ty, z: z, region: tileRegion, pixels: 512)
    check("setup: the tile shades from the COG", first != nil)
    let pagedAfterOne = await provider.isRasterPageAligned(key)
    let shadesAfterOne = await provider.shadeCount(for: key)
    check("the tile is held in pages after its first shade", pagedAfterOne == true && shadesAfterOne == 1,
          "paged \(String(describing: pagedAfterOne)), \(shadesAfterOne) shades")
    let sizeAfterOne = await provider.memoryCacheSize()
    check("one plane and its bitmap, no heap array beside the pages", sizeAfterOne >= plane + bitmap && sizeAfterOne < 2 * plane + bitmap,
          "\(sizeAfterOne) bytes against a plane of \(plane) and a bitmap of \(bitmap)")
    var turned = await provider.currentSettings()
    turned.azimuthDegrees += 90
    await provider.update(turned)
    let second = await provider.tileImage(x: tx, y: ty, z: z, region: tileRegion, pixels: 512)
    let copies = await provider.pageAlignedCopies()
    check("the second shade copies nothing either", second != nil && copies == 0, "\(copies) copies")
    check("and the readouts read the pages", await provider.elevation(at: tileRegion.center).map { $0 >= 100 && $0 <= 740 } == true,
          "\(String(describing: await provider.elevation(at: tileRegion.center)))")

    // d. Terrarium, native (z14: the ancestor padded by replication) and upsampled (z19: the stand-in cut from it).
    let terrariumDirectory = harnessTemporaryDirectory.appendingPathComponent("tile-pipeline-pages-t-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: terrariumDirectory) }
    let slow = DelayedTerrainStub(base: SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1), delay: .seconds(3.5))
    let standIns = makeStandInProvider(native: slow, directory: terrariumDirectory)
    let (x14, y14, region14) = cahokiaTile(z: 14)
    _ = await standIns.tileImage(x: x14, y: y14, z: 14, region: region14, pixels: 512)
    check("a native Terrarium tile is padded into pages", await standIns.isRasterPageAligned("14/\(x14)/\(y14)") == true)
    let (x19, y19, region19) = cahokiaTile(z: 19)
    _ = await standIns.tileImage(x: x19, y: y19, z: 19, region: region19, pixels: 512)
    check("a stand-in cut from its Terrarium ancestor is cut into pages", await standIns.isRasterPageAligned("19/\(x19)/\(y19)") == true)
    check("and neither was copied", await standIns.pageAlignedCopies() == 0)
    await standIns.clear()
    HarvestNetworkProtocol.set(serving: nil)
}

// MARK: - TP6

/// Answers at once east of `slowWestOfMercatorX`, and after `delay` west of it: a native source that is slow for
/// some tiles of a view and not others, so one neighbourhood holds native tiles and stand-ins at once.
nonisolated struct WestSlowTerrainStub: ElevationProviding {
    let base: SyntheticTerrainStub
    let slowWestOfMercatorX: Double
    let delay: Duration

    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        let m = region.mercatorBounds
        if (m.minX + m.maxX) / 2 < slowWestOfMercatorX {
            try? await Task.sleep(for: delay)
        }
        return await base.elevation(for: region, targetSamples: targetSamples)
    }
}

/// TP6. A Terrarium stand-in's arrival bumped its eight neighbours' revision and re-shaded them, and the native
/// raster's arrival re-shaded them a second time, for nothing: a stand-in is its tile's share of a 256 px Terrarium
/// ancestor (16 px at z19, 128 px at z16), never the shape of a native tile, and `AnalysisRasterBuilder` reads a
/// neighbour only in the centre's shape, so the native neighbours' skirts never saw it. A stand-in now marks no
/// neighbour stale and is skipped outright by a native centre; a stand-in shaded as the centre still reads stand-in
/// neighbours of its own shape.
@MainActor
private func checkStandInsLeaveNativeNeighboursAlone() async {
    print("\n--- TP6. a stand-in neither invalidates nor feeds its native neighbours; its upgrade does, once ---")
    guard await MetalTerrainPipelineActor.shared.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    let directory = harnessTemporaryDirectory.appendingPathComponent("tile-pipeline-standin-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let centre = cahokiaNeighbour(dx: 0)
    let west = cahokiaNeighbour(dx: -1), farWest = cahokiaNeighbour(dx: -2), east = cahokiaNeighbour(dx: 1)
    let ground = SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1)
    let stub = WestSlowTerrainStub(base: ground, slowWestOfMercatorX: centre.region.mercatorBounds.minX, delay: .seconds(5))
    let provider = makeStandInProvider(native: stub, directory: directory)
    var relief = await provider.currentSettings()
    relief.style = .localRelief
    await provider.update(relief)
    let centreKey = "19/\(centre.x)/\(centre.y)", westKey = "19/\(west.x)/\(west.y)"
    let pushed = OSAllocatedUnfairLock<[String]>(initialState: [])
    await provider.setStaleTilesSink { keys in pushed.withLock { $0 += keys } }

    let first = await provider.tileImage(x: centre.x, y: centre.y, z: 19, region: centre.region, pixels: 512)
    let eastImage = await provider.tileImage(x: east.x, y: east.y, z: 19, region: east.region, pixels: 512)
    check("setup: the centre and its east neighbour shade from the native source", first != nil && eastImage != nil)
    await provider.settleStaleTiles()
    pushed.withLock { $0.removeAll() }

    // The west and far-west tiles are answered with stand-ins at the deadline; their upgrades land 5 s after the ask.
    async let westImage = provider.tileImage(x: west.x, y: west.y, z: 19, region: west.region, pixels: 512)
    async let farWestImage = provider.tileImage(x: farWest.x, y: farWest.y, z: 19, region: farWest.region, pixels: 512)
    let standIns = await (westImage, farWestImage)
    let running = await provider.upgradesInFlight()
    check("setup: the west tiles are answered with stand-ins", standIns.0 != nil && standIns.1 != nil
          && running == [westKey, "19/\(farWest.x)/\(farWest.y)"], "\(running)")
    await provider.settleStaleTiles()
    check("the stand-in's arrival marks no neighbour stale", pushed.withLock { $0 }.isEmpty, "\(pushed.withLock { $0 })")

    var turned = relief
    turned.azimuthDegrees += 1   // Local Relief ignores the sun; any change releases the bitmaps so the tiles shade again.
    await provider.update(turned)
    _ = await provider.tileImage(x: centre.x, y: centre.y, z: 19, region: centre.region, pixels: 512)
    let centreMissing = await provider.analysisMissingNeighbours(for: centreKey) ?? []
    check("the native centre reads its native east neighbour and treats the west stand-in as missing (by shape, and now by rule)",
          centreMissing.contains(SIMD2(-1, 0)) && !centreMissing.contains(SIMD2(1, 0)), "\(centreMissing)")
    _ = await provider.tileImage(x: west.x, y: west.y, z: 19, region: west.region, pixels: 512)
    let westMissing = await provider.analysisMissingNeighbours(for: westKey) ?? []
    check("the west stand-in, shaded as the centre, reads the far-west stand-in (the native centre is another shape)",
          !westMissing.contains(SIMD2(-1, 0)) && westMissing.contains(SIMD2(1, 0)), "\(westMissing)")

    pushed.withLock { $0.removeAll() }
    check("the west upgrade's arrival marks the centre stale", await tpEventually(7) { pushed.withLock { $0 }.contains(centreKey) })
    check("once", pushed.withLock { $0 }.filter { $0 == centreKey }.count == 1, "\(pushed.withLock { $0 })")
    _ = await provider.tileImage(x: centre.x, y: centre.y, z: 19, region: centre.region, pixels: 512)
    let afterUpgrade = await provider.analysisMissingNeighbours(for: centreKey) ?? []
    check("and the centre then reads the native west", !afterUpgrade.contains(SIMD2(-1, 0)), "\(afterUpgrade)")
    await provider.setStaleTilesSink(nil)
    await provider.clear()
    HarvestNetworkProtocol.set(serving: nil)
}

// MARK: - TP7

/// TP7. `RelightCache` kept a blend's base across sun steps only when the base ignored the sun and the layer read it
/// (Raking Light over Local Relief). The other way round, Sky-View or Local Relief draped over Raking Light, every
/// sun step produced the layer again: its passes, the costliest in the catalogue, for every tile on screen at every
/// step of a dial drag. A sun-invariant layer over a sun-lit base is now kept as the base is, and a relight encodes
/// the base and the blend alone.
@MainActor
private func checkRelightKeepsASunInvariantLayer() async {
    print("\n--- TP7. a relight keeps a sun-invariant layer over a sun-lit base ---")
    guard await MetalTerrainPipelineActor.shared.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let key = "\(scene.z)/\(scene.x)/\(scene.y)"
    var lit = await scene.provider.currentSettings()
    lit.style = .rakingLight
    lit.blend = LayerBlend(product: .skyView, mode: .multiply, opacity: 0.7)
    lit.azimuthDegrees = 315
    await scene.provider.update(lit)
    check("setup: the blend's base reads the sun and its layer does not", lit.blendsSunInvariantLayer && !lit.blendsSunInvariantBase)
    func pixels(_ image: CGImage?) -> TilePixels? {
        guard let image, let rgba = rgbaBytes(image) else { return nil }
        return TilePixels(width: image.width, height: image.height, rgba: rgba)
    }
    func nearlyEqual(_ a: TilePixels?, _ b: TilePixels?, within tolerance: Int = 1) -> Bool {
        guard let a, let b, a.width == b.width, a.height == b.height, a.rgba.count == b.rgba.count else { return false }
        return zip(a.rgba, b.rgba).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    let first = pixels(await scene.image())
    let afterFirst = await scene.provider.relightCounters()
    check("setup: the blend shades, stitching once and reusing nothing", first != nil && afterFirst.built == 1
          && afterFirst.reusedAnalysis == 0 && afterFirst.reusedLayer == 0, "\(afterFirst)")
    check("the tile keeps a relight cache", await scene.provider.relightCachedKeys() == [key])
    let sizeLit = await scene.provider.memoryCacheSize()

    var turned = lit
    turned.azimuthDegrees = 135
    await scene.provider.update(turned)
    let relit = pixels(await scene.image())
    let afterRelight = await scene.provider.relightCounters()
    check("the relight stitches nothing and reuses the raster and the layer, producing the base and the blend alone",
          relit != nil && afterRelight.built == 1 && afterRelight.reusedAnalysis == 1 && afterRelight.reusedLayer == 1
          && afterRelight.reusedBase == 0, "\(afterRelight)")
    check("and the picture changed with the sun", first != nil && relit != nil && first != relit)

    let fresh = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: fresh.directory) }
    await fresh.loadNeighbourhood()
    await fresh.provider.update(turned)
    let scratch = pixels(await fresh.image())
    check("the relit tile is the from-scratch render at the new sun, within a level per channel", nearlyEqual(relit, scratch),
          "relit \(relit?.width ?? 0) px, scratch \(scratch?.width ?? 0) px")
    let cacheBytes = await scene.provider.relightCacheBytes()
    let side = 512 + 2 * TerrainTileProvider.marginPixels
    check("the cache is counted by the memory budget: the raster and the layer's two planes, beyond the nine tiles' rasters",
          cacheBytes > 0 && sizeLit >= 9 * side * side * 4 + cacheBytes, "\(cacheBytes) cache bytes in \(sizeLit)")

    // Sky-view shading reads the layer's scalar: the raster is still kept across a sun step, the layer is not.
    var shaded = turned
    shaded.skyViewShading = 0.5
    await scene.provider.update(shaded)
    check("a sky-view shading change drops the cache", await scene.provider.relightCachedKeys().isEmpty)
    _ = await scene.image()
    var shadedTurned = shaded
    shadedTurned.azimuthDegrees = 200
    await scene.provider.update(shadedTurned)
    _ = await scene.image()
    let afterShaded = await scene.provider.relightCounters()
    check("with the overlay reading the layer's scalar, a sun step reuses the raster but produces the layer again",
          afterShaded.built == 2 && afterShaded.reusedAnalysis == 2 && afterShaded.reusedLayer == 1, "\(afterShaded)")
}

// MARK: - The section

@MainActor
func runTilePipelineChecks() async {
    print("\n=== Tile pipeline audit remediation (2026-11-01) ===")
    await checkCulledFetchStopsAtOnce()
    await checkUpgradeCapHoldsAtTheDeadline()
    await checkShadingAdmittedAFewAtATime()
    await checkWaitingTileShadesUnderTheNewestSun()
    await checkFetchedRastersAreBornInPages()
    await checkStandInsLeaveNativeNeighboursAlone()
    await checkRelightKeepsASunInvariantLayer()
}
