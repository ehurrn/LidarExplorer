//
//  HarvestControllerChecks.swift
//  ViewerHarness
//
//  The offline-download screen's logic without the screen: what a job would cost, when it may not start, and what
//  running, pausing, cancelling and resuming it does to what the user sees, to the tiles fetched and to the
//  screen's auto-lock.
//
//  A stuck harvest must fail a check, not hang the harness, so every wait is a poll to a deadline.
//

import CoreLocation
import Foundation

@MainActor
func runHarvestControllerChecks() async {
    print("\n=== Offline download screen ===")
    await checkDownloadEstimate()
    checkDownloadZoomChoices()
    await checkDownloadRuns()
    await checkDownloadControl()
}

// MARK: - Fixtures

/// 0.02 degrees square: z15 needs 12 tiles and z16 needs 24, so z15 to z16 is 36 and z15 to z17 is 116.
let downloadRegion = GeoRegion(minLatitude: 38.650, maxLatitude: 38.670, minLongitude: -90.070, maxLongitude: -90.050)

nonisolated final class AwakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []
    func record(_ awake: Bool) { lock.withLock { log.append(awake) } }
    var states: [Bool] { lock.withLock { log } }
}

/// A switch that a source's failure rule reads while a run is in flight.
private nonisolated final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
    var value: Bool { lock.withLock { isOn } }
    func set(_ newValue: Bool) { lock.withLock { isOn = newValue } }
}

func manifestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManifests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func manifestFiles(_ directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("harvest_manifest_") }
}

func makeController(
    elevation: MockHarvestSource, basemaps: MockHarvestSource? = nil, pixels: Int? = 384,
    elevationCapacity: Int64 = 500_000_000, basemapCapacity: Int64 = 256_000_000,
    minZ: Int = 15, maxZ: Int = 16, awake: AwakeLog = AwakeLog(), directory: URL = manifestDirectory()
) -> OfflineHarvestController {
    OfflineHarvestController(
        region: downloadRegion, minZ: minZ, maxZ: maxZ,
        environment: OfflineHarvestController.Environment(
            elevation: elevation, basemaps: basemaps, basemapName: basemaps == nil ? nil : "Shaded relief",
            observedPixels: { pixels }, manifestDirectory: directory,
            elevationAvailableBytes: { elevationCapacity }, basemapAvailableBytes: { basemapCapacity },
            keepAwake: { awake.record($0) }))
}

/// Polls to a deadline.
func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

func summary(of controller: OfflineHarvestController) -> HarvestSummary? {
    if case .finished(let summary) = controller.phase { return summary }
    return nil
}

func isFinished(_ controller: OfflineHarvestController) -> Bool { summary(of: controller) != nil }

// MARK: - D1. What a job costs, and when it may not start

@MainActor
private func checkDownloadEstimate() async {
    print("\n--- D1. the estimate and what blocks a start ---")
    let elevation = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let basemaps = MockHarvestSource(bytesPerTile: 200, delayMilliseconds: 1)
    let controller = makeController(elevation: elevation, basemaps: basemaps)
    await controller.refreshEstimate()
    let plain = controller.estimate
    controller.includeBasemaps = true
    await controller.refreshEstimate()
    let withBasemaps = controller.estimate
    check("the estimate is the tiles of the area and zooms weighed by what each source keeps: 36 tiles and 36,000 bytes, and 7,200 more when the basemap is asked for",
          plain == .init(tileCount: 36, elevationBytes: 36_000, basemapBytes: 0)
          && withBasemaps == .init(tileCount: 36, elevationBytes: 36_000, basemapBytes: 7_200)
          && withBasemaps?.totalBytes == 43_200,
          "\(String(describing: plain)) \(String(describing: withBasemaps))")
    controller.includeBasemaps = false
    controller.maxZ = 17
    await controller.refreshEstimate()
    check("another zoom level means more tiles: z15 to z17 is 116", controller.estimate?.tileCount == 116, "\(String(describing: controller.estimate))")

    // Apple's imagery cannot be kept, so there is no basemap source and asking for one changes nothing.
    let appleOnly = makeController(elevation: MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1), basemaps: nil)
    appleOnly.includeBasemaps = true
    await appleOnly.refreshEstimate()
    check("with no basemap that can be kept, asking for one adds nothing to the estimate, and the screen can tell",
          !appleOnly.canIncludeBasemaps && appleOnly.estimate == .init(tileCount: 36, elevationBytes: 36_000, basemapBytes: 0)
          && appleOnly.blocker == nil, "\(String(describing: appleOnly.estimate))")

    // The tile size is the map's, and until the map has asked for one there is none to download at.
    let blindSource = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let awake = AwakeLog()
    let blind = makeController(elevation: blindSource, pixels: nil, awake: awake)
    await blind.refreshEstimate()
    await blind.start()
    check("until the map has asked for a tile size nothing can start: it is a blocker that says what to do, and starting fetches nothing",
          blind.blocker == .tileSizeUnknown && !blind.canStart && blind.phase == .idle && blindSource.calls.isEmpty
          && awake.states.isEmpty && blind.blocker?.message.contains("Pan or zoom") == true,
          "\(String(describing: blind.blocker)), \(blind.phase)")

    // Each cache has its own limit.
    let huge = MockHarvestSource(bytesPerTile: 20_000_000, delayMilliseconds: 1)
    let tooBig = makeController(elevation: huge)
    await tooBig.refreshEstimate()
    await tooBig.start()
    let message = tooBig.blocker?.message ?? ""
    check("a job larger than the elevation cache is refused before anything is fetched, naming the cache and both sizes",
          tooBig.blocker == .tooLarge(cache: "elevation", estimatedBytes: 720_000_000, availableBytes: 500_000_000)
          && huge.calls.isEmpty && tooBig.phase == .idle && !tooBig.canStart
          && message.contains("elevation") && message.contains("720 MB") && message.contains("500 MB"),
          "\(String(describing: tooBig.blocker)) '\(message)'")

    let heavyBasemap = MockHarvestSource(bytesPerTile: 10_000_000, delayMilliseconds: 1)
    let basemapBound = makeController(elevation: MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1), basemaps: heavyBasemap)
    basemapBound.includeBasemaps = true
    await basemapBound.refreshEstimate()
    let refusedBasemap = basemapBound.blocker
    basemapBound.includeBasemaps = false
    await basemapBound.refreshEstimate()
    check("a basemap larger than its own cache is refused naming it, and is fine when the basemap is not asked for",
          refusedBasemap == .tooLarge(cache: "basemap", estimatedBytes: 360_000_000, availableBytes: 256_000_000)
          && basemapBound.blocker == nil && basemapBound.canStart, "\(String(describing: refusedBasemap))")

    let fitsElevation = MockHarvestSource(bytesPerTile: 11_000_000, delayMilliseconds: 1)
    let fitsBasemap = MockHarvestSource(bytesPerTile: 6_000_000, delayMilliseconds: 1)
    let separate = makeController(elevation: fitsElevation, basemaps: fitsBasemap)
    separate.includeBasemaps = true
    await separate.refreshEstimate()
    check("two caches, two limits: 396 MB of elevation and 216 MB of basemap each fit their own cache, though together they exceed either, and are allowed",
          separate.blocker == nil && separate.canStart && separate.estimate?.totalBytes == 612_000_000,
          "\(String(describing: separate.blocker)), \(String(describing: separate.estimate))")
}

// MARK: - D2. Choosing zooms

@MainActor
private func checkDownloadZoomChoices() {
    print("\n--- D2. choosing zoom levels ---")
    let controller = makeController(elevation: MockHarvestSource(delayMilliseconds: 1), minZ: 15, maxZ: 16)
    controller.minZ = 18
    let raised = (controller.minZ, controller.maxZ)
    controller.maxZ = 12
    let lowered = (controller.minZ, controller.maxZ)
    controller.minZ = 3
    controller.maxZ = 30
    let clamped = (controller.minZ, controller.maxZ)
    check("the zoom range keeps its order and stays within 8 to 20: raising the start raises the end, lowering the end lowers the start",
          raised == (18, 18) && lowered == (12, 12) && clamped == (8, 20) && OfflineHarvestController.zoomLimits == 8...20,
          "\(raised) \(lowered) \(clamped)")

    let street = OfflineHarvestController.defaultZoomRange(longitudeSpan: 0.0086, viewportWidthPoints: 1032)
    let continent = OfflineHarvestController.defaultZoomRange(longitudeSpan: 20, viewportWidthPoints: 1032)
    let doorstep = OfflineHarvestController.defaultZoomRange(longitudeSpan: 1e-7, viewportWidthPoints: 1032)
    let unknown = [Double.nan, 0, -1, .infinity].map { OfflineHarvestController.defaultZoomRange(longitudeSpan: $0, viewportWidthPoints: 1032) }
    let chosen = makeController(elevation: MockHarvestSource(delayMilliseconds: 1), minZ: 8, maxZ: 8)
    chosen.choose(region: downloadRegion, viewportWidthPoints: 1032)
    check("choosing an area sets the zoom levels to suit its size: 0.02 degrees across on a 1032 point map is z14 to z18",
          chosen.region == downloadRegion && (chosen.minZ, chosen.maxZ) == (14, 18) && chosen.estimate == nil,
          "\((chosen.minZ, chosen.maxZ))")
    check("the default zooms run from two levels below the map's to two above it, held within 8 to 20, and fall back when the span is not a size",
          street == 15...19 && continent == 8...8 && doorstep == 20...20 && unknown.allSatisfy { $0 == 15...19 },
          "\(street) \(continent) \(doorstep) \(unknown)")
}

// MARK: - D3. Running

@MainActor
private func checkDownloadRuns() async {
    print("\n--- D3. running a job ---")
    let awake = AwakeLog()
    let directory = manifestDirectory()
    let elevation = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let controller = makeController(elevation: elevation, pixels: 384, awake: awake, directory: directory)
    await controller.start()
    let done = summary(of: controller)
    check("a harvest runs to the end at the tile size the map is using: every tile once, all completed, progress at the total, the manifest on disk",
          done?.state == .completed && done?.total == 36 && done?.completed == 36 && done?.failed == 0
          && elevation.calls.count == 36 && Set(elevation.calls).count == 36 && elevation.pixelsSeen == [384]
          && controller.progress?.completed == 36 && controller.progress?.total == 36 && manifestFiles(directory).count == 1,
          "\(String(describing: done)), \(elevation.calls.count) calls, sizes \(elevation.pixelsSeen), \(manifestFiles(directory).count) manifests")
    check("the screen is kept awake for the length of the download and let go of at its end", awake.states == [true, false], "\(awake.states)")
    controller.choose(region: downloadRegion, viewportWidthPoints: 1032)
    check("choosing an area after a job clears that job's summary and progress, which are not the new area's",
          controller.phase == .idle && controller.progress == nil && controller.estimate == nil, "\(controller.phase)")

    let otherSize = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let retina = makeController(elevation: otherSize, pixels: 512)
    await retina.start()
    check("the tile size is whatever the map last asked for, not a constant", otherSize.pixelsSeen == [512], "\(otherSize.pixelsSeen)")

    let landscape = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let basemapLayer = MockHarvestSource(bytesPerTile: 200, delayMilliseconds: 1)
    let both = makeController(elevation: landscape, basemaps: basemapLayer)
    both.includeBasemaps = true
    await both.start()
    let bothDone = summary(of: both)
    check("with the basemap asked for, both layers are fetched for every tile: 72 jobs",
          bothDone?.total == 72 && bothDone?.completed == 72 && landscape.calls.count == 36 && basemapLayer.calls.count == 36,
          "\(String(describing: bothDone)), \(landscape.calls.count) + \(basemapLayer.calls.count)")

    let noBasemap = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1)
    let apple = makeController(elevation: noBasemap, basemaps: nil)
    apple.includeBasemaps = true
    await apple.start()
    check("asking for a basemap that cannot be kept downloads the elevation alone, and does not fail",
          summary(of: apple)?.total == 36 && summary(of: apple)?.state == .completed && noBasemap.calls.count == 36)

    let slow = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 20)
    let twice = makeController(elevation: slow)
    let first = Task { await twice.start() }
    await waitUntil { !slow.calls.isEmpty }
    await twice.start()
    await waitUntil { isFinished(twice) }
    await first.value
    check("starting again while a job runs is ignored, not run beside it: 36 tiles, once each",
          slow.calls.count == 36 && Set(slow.calls).count == 36 && summary(of: twice)?.state == .completed,
          "\(slow.calls.count) calls")
}

// MARK: - D4. Pause, cancel, resume

@MainActor
private func checkDownloadControl() async {
    print("\n--- D4. pause, cancel and resume ---")

    // Pausing.
    let pausing = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 40)
    let pausingAwake = AwakeLog()
    let controller = makeController(elevation: pausing, awake: pausingAwake)
    let run = Task { await controller.start() }
    await waitUntil { pausing.calls.count >= 4 }
    controller.pause()
    let pausedPhase = controller.phase
    try? await Task.sleep(for: .milliseconds(250))
    let held = pausing.calls.count
    try? await Task.sleep(for: .milliseconds(300))
    let stillHeld = pausing.calls.count
    let stayedAwake = pausingAwake.states
    controller.resume()
    await waitUntil { isFinished(controller) }
    await run.value
    check("pausing stops new tiles from starting, keeps the screen awake, and resuming finishes the job with every tile fetched once",
          pausedPhase == .paused && held == stillHeld && held < 36 && stayedAwake == [true]
          && pausing.calls.count == 36 && Set(pausing.calls).count == 36 && summary(of: controller)?.completed == 36
          && pausingAwake.states == [true, false],
          "\(pausedPhase), held \(held) / \(stillHeld), \(pausing.calls.count) calls, \(pausingAwake.states)")

    // Cancelling, then resuming what is left.
    let directory = manifestDirectory()
    let cancelling = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 40)
    let cancelAwake = AwakeLog()
    let cancelled = makeController(elevation: cancelling, awake: cancelAwake, directory: directory)
    let cancelRun = Task { await cancelled.start() }
    await waitUntil { cancelling.calls.count >= 4 }
    cancelled.cancel()
    await waitUntil { isFinished(cancelled) }
    await cancelRun.value
    let partial = summary(of: cancelled)
    let afterCancel = cancelAwake.states
    await cancelled.resumeInterrupted()
    let resumed = summary(of: cancelled)
    check("cancelling ends the job with what is done kept and the screen let go; resuming fetches only what is missing: 36 tiles in all, none twice",
          partial?.state == .cancelled && (partial?.completed ?? 0) > 0 && (partial?.completed ?? 36) < 36 && afterCancel == [true, false]
          && resumed?.state == .completed && resumed?.completed == 36 && cancelling.calls.count == 36
          && Set(cancelling.calls).count == 36 && cancelAwake.states == [true, false, true, false],
          "\(String(describing: partial)) then \(String(describing: resumed)), \(cancelling.calls.count) calls")

    // Failures are counted, and resuming retries just those.
    let failing = Switch(true)
    let flaky = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1, fails: { failing.value && ($0.x + $0.y) % 5 == 0 })
    let retrying = makeController(elevation: flaky)
    let plan = OfflineHarvestCoordinator.tiles(for: HarvestConfiguration(region: downloadRegion, minZ: 15, maxZ: 16, pixels: 384))
    let expectedFailures = plan.filter { ($0.x + $0.y) % 5 == 0 }.count
    await retrying.start()
    let firstPass = summary(of: retrying)
    failing.set(false)
    await retrying.resumeInterrupted()
    let secondPass = summary(of: retrying)
    check("tiles that fail are counted and the job still ends; resuming fetches just those again and completes",
          expectedFailures > 0 && firstPass?.failed == expectedFailures && firstPass?.completed == 36 - expectedFailures
          && flaky.calls.count == 36 + expectedFailures && secondPass?.failed == 0 && secondPass?.completed == 36,
          "\(expectedFailures) expected, first \(String(describing: firstPass)), \(flaky.calls.count) calls, second \(String(describing: secondPass))")

    // A job that cannot be resumed says so and lets the screen go.
    let lostDirectory = manifestDirectory()
    let lostSource = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 40)
    let lostAwake = AwakeLog()
    let lost = makeController(elevation: lostSource, awake: lostAwake, directory: lostDirectory)
    let lostRun = Task { await lost.start() }
    await waitUntil { lostSource.calls.count >= 4 }
    lost.cancel()
    await waitUntil { isFinished(lost) }
    await lostRun.value
    for file in manifestFiles(lostDirectory) { try? FileManager.default.removeItem(at: file) }
    await lost.resumeInterrupted()
    var failureMessage = ""
    if case .failed(let text) = lost.phase { failureMessage = text }
    check("resuming a job whose manifest is gone fails with a reason, lets the screen go, and leaves the screen free to start again",
          !failureMessage.isEmpty && !lost.isBusy && lostAwake.states == [true, false, true, false],
          "'\(failureMessage)', \(lost.phase), \(lostAwake.states)")
    let callsBefore = lostSource.calls.count
    await lost.resumeInterrupted()
    check("a job that could not be resumed is forgotten, so resuming again does nothing rather than failing again",
          lostSource.calls.count == callsBefore && lostAwake.states.count == 4 && !lost.isBusy,
          "\(lostAwake.states)")
}
