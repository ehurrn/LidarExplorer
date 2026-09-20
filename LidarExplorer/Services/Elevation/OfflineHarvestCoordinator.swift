//
//  OfflineHarvestCoordinator.swift
//  LidarExplorer
//
//  Pre-downloads a geographic envelope so the map, spot inspection and transects work with no signal.
//
//  The coordinator knows nothing about where tiles come from or where they land. It enumerates the slippy-map
//  tiles a region needs, feeds them to a ``HarvestTileSource`` a few at a time, and keeps a manifest of what has
//  finished so an interrupted job picks up where it stopped. The map layer supplies the sources: one writes
//  elevation rasters under the very keys the renderer reads, one stores basemap imagery.
//

import Foundation

/// One Web Mercator tile: `z/x/y`, with y counted from the north.
public nonisolated struct HarvestTile: Sendable, Hashable, Codable {
    public let x: Int
    public let y: Int
    public let z: Int

    public init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// What a job downloads for each tile.
public nonisolated enum HarvestLayer: String, Sendable, Codable, CaseIterable {
    case elevation
    case basemap
}

public nonisolated struct HarvestConfiguration: Sendable, Equatable, Codable {
    public var region: GeoRegion
    public var minZ: Int
    public var maxZ: Int
    /// Tile edge, in pixels, the renderer will ask for. Cached rasters are keyed by it, so a harvest made at one
    /// size does not answer requests at another, and there is deliberately no default: the size is the device's
    /// (an iPad Pro 13" draws this overlay at about 1.477x and asks for 384 px, a 2x display for 512), so a guess
    /// would fill the cache with rasters the map never requests. Use ``TerrainTileProvider/observedTilePixels``.
    public var pixels: Int
    public var includeBasemaps: Bool

    public init(region: GeoRegion, minZ: Int, maxZ: Int, pixels: Int, includeBasemaps: Bool = false) {
        self.region = region
        self.minZ = minZ
        self.maxZ = maxZ
        self.pixels = pixels
        self.includeBasemaps = includeBasemaps
    }
}

/// How one tile fared.
public nonisolated enum HarvestTileOutcome: Sendable, Equatable {
    /// Fetched and written; `bytes` reached the disk.
    case stored(bytes: Int)
    /// Already on disk, so nothing was fetched.
    case alreadyCached
    /// Not stored. Includes tiles a source declines to keep, such as a degraded fallback.
    case failed(reason: String)
}

/// Fetches one kind of tile and puts it where the app will look for it.
public nonisolated protocol HarvestTileSource: Sendable {
    /// What one tile is expected to add to the disk cache, for sizing a job before it starts.
    func estimatedBytesPerTile(pixels: Int) -> Int64
    func harvest(_ tile: HarvestTile, pixels: Int) async -> HarvestTileOutcome
}

public nonisolated enum HarvestState: String, Sendable, Codable, Equatable {
    case completed
    case cancelled
}

public nonisolated struct HarvestProgress: Sendable, Equatable {
    /// Jobs finished successfully, including any a resumed manifest already held.
    public let completed: Int
    /// Jobs (a tile on a layer) the whole harvest comprises.
    public let total: Int
    /// Jobs that did not store. They are retried by a resumed run.
    public let failed: Int
    /// Bytes written this run divided by the time spent running, paused time excluded.
    public let kilobytesPerSecond: Double

    public var processed: Int { completed + failed }
}

public nonisolated struct HarvestSummary: Sendable, Equatable {
    public let jobID: UUID
    public let state: HarvestState
    public let total: Int
    public let completed: Int
    public let failed: Int
    /// Bytes written by this run alone.
    public let bytesStored: Int64
}

public nonisolated enum HarvestError: Error, Equatable {
    /// The job would not fit the disk cache, which would evict its own earliest tiles as it wrote its last.
    case exceedsCacheCapacity(estimatedBytes: Int64, capacityBytes: Int64)
    /// No readable manifest exists for the job being resumed.
    case manifestNotFound(UUID)
    /// The manifest was written for a different region, zoom range or tile size.
    case manifestMismatch(UUID)
    case basemapSourceUnavailable
    /// One coordinator runs one harvest at a time.
    case alreadyRunning
}

public actor OfflineHarvestCoordinator {

    // MARK: - Tile arithmetic

    /// Mercator's latitude limit: past it the projection leaves the square the tiles tile.
    private nonisolated static let mercatorLatitudeLimit = 85.0511287798066

    /// Tolerance, in tiles, when deciding which tile an edge belongs to.
    ///
    /// A tile's own region is computed from trigonometry, so its edges land a few ulps either side of the true
    /// tile boundary. Without a tolerance a region that exactly fits one tile would also claim its neighbour.
    private nonisolated static let edgeTolerance = 1e-9

    public nonisolated static let zoomRange = 0...22

    private nonisolated struct Level: Sendable {
        let z: Int
        let columns: ClosedRange<Int>
        let rows: ClosedRange<Int>

        var count: Int { columns.count * rows.count }
    }

    private nonisolated static func level(covering region: GeoRegion, z: Int) -> Level? {
        guard zoomRange.contains(z),
              region.minLatitude.isFinite, region.maxLatitude.isFinite,
              region.minLongitude.isFinite, region.maxLongitude.isFinite
        else { return nil }

        let n = Double(1 << z)
        func column(_ longitude: Double) -> Double {
            (min(max(longitude, -180), 180) + 180) / 360 * n
        }
        func row(_ latitude: Double) -> Double {
            let clamped = min(max(latitude, -mercatorLatitudeLimit), mercatorLatitudeLimit)
            return (1 - asinh(tan(clamped * .pi / 180)) / .pi) / 2 * n
        }
        func span(_ low: Double, _ high: Double) -> ClosedRange<Int> {
            let last = Int(n) - 1
            let first = min(max(Int((low + edgeTolerance).rounded(.down)), 0), last)
            let end = min(max(Int((high - edgeTolerance).rounded(.up)) - 1, first), last)
            return first...end
        }
        // North is the small row number.
        return Level(
            z: z,
            columns: span(column(region.minLongitude), column(region.maxLongitude)),
            rows: span(row(region.maxLatitude), row(region.minLatitude))
        )
    }

    private nonisolated static func levels(for configuration: HarvestConfiguration) -> [Level] {
        let low = max(configuration.minZ, zoomRange.lowerBound)
        let high = min(configuration.maxZ, zoomRange.upperBound)
        guard low <= high else { return [] }
        return (low...high).compactMap { level(covering: configuration.region, z: $0) }
    }

    /// Every tile of `region` at zoom `z`, row by row from the northwest.
    public nonisolated static func tiles(covering region: GeoRegion, z: Int) -> [HarvestTile] {
        guard let level = level(covering: region, z: z) else { return [] }
        return level.rows.flatMap { y in level.columns.map { HarvestTile(x: $0, y: y, z: z) } }
    }

    /// Every tile of a job, coarse zooms first so the map has something at every scale sooner.
    public nonisolated static func tiles(for configuration: HarvestConfiguration) -> [HarvestTile] {
        levels(for: configuration).flatMap { tiles(covering: configuration.region, z: $0.z) }
    }

    /// How many tiles a job covers, by arithmetic rather than enumeration.
    public nonisolated static func tileCount(for configuration: HarvestConfiguration) -> Int {
        levels(for: configuration).reduce(0) { $0 + $1.count }
    }

    /// The tiles of a job, addressed by position, so a planet-sized plan costs nothing until it is walked.
    private nonisolated struct Plan: Sendable {
        let levels: [Level]
        let tileCount: Int

        init(_ configuration: HarvestConfiguration) {
            levels = OfflineHarvestCoordinator.levels(for: configuration)
            tileCount = levels.reduce(0) { $0 + $1.count }
        }

        func tile(at index: Int) -> HarvestTile {
            var remaining = index
            for level in levels {
                if remaining < level.count {
                    let width = level.columns.count
                    return HarvestTile(
                        x: level.columns.lowerBound + remaining % width,
                        y: level.rows.lowerBound + remaining / width,
                        z: level.z)
                }
                remaining -= level.count
            }
            preconditionFailure("tile index \(index) is outside a plan of \(tileCount)")
        }
    }

    // MARK: - Manifest

    /// What survives an interruption: the job's identity and configuration, and each job that finished.
    private nonisolated struct Manifest: Codable {
        let id: UUID
        let configuration: HarvestConfiguration
        var completed: [String]
    }

    public nonisolated static func manifestURL(for jobID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("harvest_manifest_\(jobID.uuidString).json")
    }

    private nonisolated static func key(_ tile: HarvestTile, _ layer: HarvestLayer) -> String {
        "\(layer.rawValue)/\(tile.z)/\(tile.x)/\(tile.y)"
    }

    /// Longest the manifest may lag behind the work. Rewriting it per tile would make a large job quadratic in
    /// its size; a crash costs at most this long's worth of tiles, which a resumed run finds already on disk.
    private nonisolated static let manifestFlushInterval: Duration = .seconds(2)

    // MARK: - Limits

    public nonisolated static let maximumConcurrency = 6
    public nonisolated static let defaultConcurrency = 4

    /// How many tiles may be in flight at once.
    public let concurrencyLimit: Int

    private let elevation: any HarvestTileSource
    private let basemaps: (any HarvestTileSource)?
    private let manifestDirectory: URL
    private let cacheCapacityBytes: Int64?

    // MARK: - Run state

    private var isRunning = false
    private var isPaused = false
    private var cancelRequested = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [AsyncStream<HarvestProgress>.Continuation] = []

    private var startedAt = ContinuousClock.now
    private var pausedSince: ContinuousClock.Instant?
    private var pausedTotal: Duration = .zero

    public init(
        elevation: any HarvestTileSource,
        basemaps: (any HarvestTileSource)? = nil,
        manifestDirectory: URL,
        maxConcurrent: Int = OfflineHarvestCoordinator.defaultConcurrency,
        cacheCapacityBytes: Int64? = nil
    ) {
        self.elevation = elevation
        self.basemaps = basemaps
        self.manifestDirectory = manifestDirectory
        self.concurrencyLimit = min(max(maxConcurrent, 1), Self.maximumConcurrency)
        self.cacheCapacityBytes = cacheCapacityBytes
    }

    // MARK: - Sizing

    /// The tiles a job covers and what they are expected to add to the disk cache.
    public func estimateFootprint(for configuration: HarvestConfiguration) -> (tileCount: Int, estimatedBytes: Int64) {
        let count = Self.tileCount(for: configuration)
        var perTile = elevation.estimatedBytesPerTile(pixels: configuration.pixels)
        if configuration.includeBasemaps, let basemaps {
            perTile += basemaps.estimatedBytesPerTile(pixels: configuration.pixels)
        }
        let (bytes, overflow) = Int64(count).multipliedReportingOverflow(by: perTile)
        return (count, overflow ? Int64.max : bytes)
    }

    // MARK: - Progress

    /// Updates for the next harvest, ending when it does. Subscribe before calling ``harvest(_:resuming:progressHandler:)``.
    public func progress() -> AsyncStream<HarvestProgress> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: HarvestProgress.self, bufferingPolicy: .bufferingNewest(1024))
        subscribers.append(continuation)
        return stream
    }

    // MARK: - Control

    /// Stops starting tiles. Those already in flight finish and are recorded.
    public func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        pausedSince = ContinuousClock.now
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if let since = pausedSince { pausedTotal += ContinuousClock.now - since }
        pausedSince = nil
        releasePauseWaiters()
    }

    /// Stops starting tiles and ends the harvest once those in flight have finished. The manifest keeps what is
    /// done, and ``harvest(_:resuming:progressHandler:)`` with the job's id continues from it.
    public func cancel() {
        cancelRequested = true
        releasePauseWaiters()
    }

    private func releasePauseWaiters() {
        let waiting = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private var isStopping: Bool { cancelRequested || Task.isCancelled }

    private func waitWhilePaused() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                // The body runs on this actor, so nothing can slip between this test and the append.
                if isPaused, !isStopping {
                    pauseWaiters.append(waiter)
                } else {
                    waiter.resume()
                }
            }
        } onCancel: {
            Task { await self.releasePauseWaiters() }
        }
    }

    // MARK: - Harvest

    private struct JobResult: Sendable {
        let key: String
        let outcome: HarvestTileOutcome
    }

    /// Runs a harvest to the end, or until it is cancelled.
    ///
    /// Pass a `jobID` to continue an interrupted job: only what its manifest lacks is fetched, including
    /// anything that failed the first time.
    public func harvest(
        _ configuration: HarvestConfiguration,
        resuming jobID: UUID? = nil,
        progressHandler: (@Sendable (HarvestProgress) -> Void)? = nil
    ) async throws -> HarvestSummary {
        guard !isRunning else { throw HarvestError.alreadyRunning }
        let id: UUID
        let completedKeys: Set<String>
        do {
            (id, completedKeys) = try prepare(configuration, resuming: jobID)
        } catch {
            // Nobody is left waiting on a harvest that never started.
            finishSubscribers()
            throw error
        }

        isRunning = true
        isPaused = false
        cancelRequested = false
        pausedSince = nil
        pausedTotal = .zero
        startedAt = ContinuousClock.now
        defer {
            isRunning = false
            isPaused = false
            releasePauseWaiters()
            finishSubscribers()
        }

        let layers: [HarvestLayer] = configuration.includeBasemaps ? [.elevation, .basemap] : [.elevation]
        run = RunState(
            id: id, configuration: configuration, plan: Plan(configuration), layers: layers,
            completedKeys: completedKeys)
        writeManifest()
        report(to: progressHandler)

        let elevation = elevation
        let basemaps = basemaps
        let pixels = configuration.pixels
        await withTaskGroup(of: JobResult.self) { group in
            var active = 0
            while true {
                let stopping = isStopping
                if !stopping, !isPaused, active < concurrencyLimit, let job = run.nextPending() {
                    let source = job.layer == .elevation ? elevation : (basemaps ?? elevation)
                    group.addTask {
                        JobResult(key: job.key, outcome: await source.harvest(job.tile, pixels: pixels))
                    }
                    active += 1
                    continue
                }
                if active > 0 {
                    if let result = await group.next() {
                        active -= 1
                        // A source that gave up because the task was cancelled has not failed the tile.
                        run.record(result.outcome, forKey: result.key, cancelled: Task.isCancelled)
                        report(to: progressHandler)
                        if ContinuousClock.now - run.lastFlush >= Self.manifestFlushInterval { writeManifest() }
                    }
                    continue
                }
                if !stopping, isPaused {
                    await waitWhilePaused()
                    continue
                }
                break
            }
        }

        writeManifest()
        // Finished means every job was attempted, whatever a late cancel() says.
        return HarvestSummary(
            jobID: id,
            state: run.completed + run.failed >= run.total ? .completed : .cancelled,
            total: run.total,
            completed: run.completed,
            failed: run.failed,
            bytesStored: run.bytesStored)
    }

    /// Everything one harvest accumulates. Lives on the actor rather than in locals so the task group's body,
    /// which suspends between jobs, reaches it through isolation instead of by capture.
    private nonisolated struct RunState {
        let id: UUID
        let configuration: HarvestConfiguration
        let plan: Plan
        let layers: [HarvestLayer]
        var completedKeys: Set<String>
        var completed: Int
        var failed = 0
        var bytesStored: Int64 = 0
        var nextJob = 0
        var lastFlush = ContinuousClock.now

        /// Before any harvest has run: an empty plan.
        static let idle: RunState = {
            let empty = HarvestConfiguration(
                region: GeoRegion(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0), minZ: 1, maxZ: 0,
                pixels: 0)
            return RunState(id: UUID(), configuration: empty, plan: Plan(empty), layers: [], completedKeys: [])
        }()

        init(id: UUID, configuration: HarvestConfiguration, plan: Plan, layers: [HarvestLayer], completedKeys: Set<String>) {
            self.id = id
            self.configuration = configuration
            self.plan = plan
            self.layers = layers
            self.completedKeys = completedKeys
            self.completed = completedKeys.count
        }

        var total: Int { plan.tileCount * layers.count }

        /// The next job the manifest does not already hold.
        mutating func nextPending() -> (tile: HarvestTile, layer: HarvestLayer, key: String)? {
            while nextJob < total {
                let tile = plan.tile(at: nextJob / layers.count)
                let layer = layers[nextJob % layers.count]
                nextJob += 1
                let key = OfflineHarvestCoordinator.key(tile, layer)
                if !completedKeys.contains(key) { return (tile, layer, key) }
            }
            return nil
        }

        mutating func record(_ outcome: HarvestTileOutcome, forKey key: String, cancelled: Bool) {
            switch outcome {
            case .stored(let bytes):
                completed += 1
                bytesStored += Int64(bytes)
                completedKeys.insert(key)
            case .alreadyCached:
                completed += 1
                completedKeys.insert(key)
            case .failed:
                if !cancelled { failed += 1 }
            }
        }
    }

    private var run = RunState.idle

    private func report(to handler: (@Sendable (HarvestProgress) -> Void)?) {
        let update = HarvestProgress(
            completed: run.completed, total: run.total, failed: run.failed,
            kilobytesPerSecond: throughput(bytes: run.bytesStored))
        for subscriber in subscribers { subscriber.yield(update) }
        handler?(update)
    }

    /// Checks a job can run and finds where it starts: a new id, or a manifest's.
    private func prepare(
        _ configuration: HarvestConfiguration, resuming jobID: UUID?
    ) throws -> (id: UUID, completed: Set<String>) {
        if configuration.includeBasemaps, basemaps == nil { throw HarvestError.basemapSourceUnavailable }

        let estimate = estimateFootprint(for: configuration)
        if let capacity = cacheCapacityBytes, estimate.estimatedBytes > capacity {
            throw HarvestError.exceedsCacheCapacity(estimatedBytes: estimate.estimatedBytes, capacityBytes: capacity)
        }

        guard let jobID else { return (UUID(), []) }
        guard let data = try? Data(contentsOf: Self.manifestURL(for: jobID, in: manifestDirectory)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw HarvestError.manifestNotFound(jobID) }
        guard manifest.configuration == configuration else { throw HarvestError.manifestMismatch(jobID) }
        return (jobID, Set(manifest.completed))
    }

    private func finishSubscribers() {
        for subscriber in subscribers { subscriber.finish() }
        subscribers.removeAll()
    }

    private func throughput(bytes: Int64) -> Double {
        var paused = pausedTotal
        if let since = pausedSince { paused += ContinuousClock.now - since }
        let active = ContinuousClock.now - startedAt - paused
        let seconds = Double(active.components.seconds) + Double(active.components.attoseconds) / 1e18
        guard seconds > 0 else { return 0 }
        return Double(bytes) / 1000 / seconds
    }

    private func writeManifest() {
        let manifest = Manifest(id: run.id, configuration: run.configuration, completed: run.completedKeys.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL(for: run.id, in: manifestDirectory), options: .atomic)
        run.lastFlush = ContinuousClock.now
    }
}
