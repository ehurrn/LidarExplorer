//
//  OfflineHarvestController.swift
//  LidarExplorer
//
//  What the offline-download screen decides and shows, apart from the screen.
//
//  It sizes a job before it starts, and refuses one that cannot be done: until the map has asked for a tile size
//  (cached rasters are keyed by it, and a download made at another would fill the disk with tiles the map never
//  asks for), or when it would not fit the cache it fills. The two caches a job can fill have limits of their own,
//  so each is checked against its own, not the two against one. It runs the job through the coordinator, keeps the
//  screen from auto-locking while it does (a locked iPad suspends the downloads), and remembers a job that was
//  cancelled or had failures so it can be resumed from its manifest.
//

import Foundation
import Observation

@MainActor
@Observable
public final class OfflineHarvestController {

    /// What the controller needs from the app, so that a harness can stand in for all of it.
    public struct Environment: Sendable {
        public var elevation: any HarvestTileSource
        /// The basemap that can be kept, or nil when there is none (Apple's imagery cannot be).
        public var basemaps: (any HarvestTileSource)?
        public var basemapName: String?
        /// The tile size the map last asked for; nil until it has asked.
        public var observedPixels: @Sendable () async -> Int?
        public var manifestDirectory: URL
        public var elevationCapacityBytes: Int64
        public var basemapCapacityBytes: Int64
        /// Called with true when a download starts and false when it ends, however it ends.
        public var keepAwake: @MainActor @Sendable (Bool) -> Void

        public init(
            elevation: any HarvestTileSource, basemaps: (any HarvestTileSource)? = nil, basemapName: String? = nil,
            observedPixels: @escaping @Sendable () async -> Int?, manifestDirectory: URL,
            elevationCapacityBytes: Int64, basemapCapacityBytes: Int64,
            keepAwake: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            self.elevation = elevation
            self.basemaps = basemaps
            self.basemapName = basemapName
            self.observedPixels = observedPixels
            self.manifestDirectory = manifestDirectory
            self.elevationCapacityBytes = elevationCapacityBytes
            self.basemapCapacityBytes = basemapCapacityBytes
            self.keepAwake = keepAwake
        }
    }

    /// What a job would add to the disk, by the cache it goes to.
    public struct Estimate: Equatable, Sendable {
        public var tileCount: Int
        public var elevationBytes: Int64
        public var basemapBytes: Int64
        public var totalBytes: Int64 { elevationBytes &+ basemapBytes }
    }

    /// Why a job cannot start.
    public enum Blocker: Equatable, Sendable {
        case tileSizeUnknown
        case tooLarge(cache: String, estimatedBytes: Int64, capacityBytes: Int64)

        public var message: String {
            switch self {
            case .tileSizeUnknown:
                "Pan or zoom the map once so the app learns what tile size to download, then open this screen again."
            case .tooLarge(let cache, let estimated, let capacity):
                "The \(cache) for this area would need about \(Self.bytes(estimated)), but the \(cache) cache holds "
                    + "\(Self.bytes(capacity)). Choose a smaller area or fewer zoom levels."
            }
        }

        private static func bytes(_ count: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        }
    }

    public enum Phase: Equatable {
        case idle
        case running
        case paused
        case finished(HarvestSummary)
        case failed(String)
    }

    /// The zoom levels a job may span: below 8 a tile is a country, and 20 is the deepest the map draws in earnest.
    public static let zoomLimits = 8...20

    public var environment: Environment
    public var region: GeoRegion
    // Each assigns only when it has something to change: under `@Observable` an assignment in a `didSet` goes back
    // through the property's setter and runs the observer again, so an unconditional one never ends.
    public var minZ: Int {
        didSet {
            let clamped = Self.clamped(minZ)
            if clamped != minZ { minZ = clamped }
            if minZ > maxZ { maxZ = minZ }
        }
    }
    public var maxZ: Int {
        didSet {
            let clamped = Self.clamped(maxZ)
            if clamped != maxZ { maxZ = clamped }
            if maxZ < minZ { minZ = maxZ }
        }
    }
    public var includeBasemaps = false

    public private(set) var estimate: Estimate?
    public private(set) var blocker: Blocker?
    public private(set) var phase: Phase = .idle
    public private(set) var progress: HarvestProgress?

    private var pixels: Int?
    private var coordinator: OfflineHarvestCoordinator?
    private var isStarting = false

    private struct Interrupted {
        let id: UUID
        let configuration: HarvestConfiguration
    }
    /// The last job that was cancelled or had tiles fail, which resuming continues from its manifest.
    private var interrupted: Interrupted?

    public init(region: GeoRegion, minZ: Int = 15, maxZ: Int = 19, environment: Environment) {
        self.region = region
        self.minZ = Self.clamped(minZ)
        self.maxZ = max(Self.clamped(maxZ), Self.clamped(minZ))
        self.environment = environment
    }

    private static func clamped(_ zoom: Int) -> Int {
        min(max(zoom, zoomLimits.lowerBound), zoomLimits.upperBound)
    }

    public var canIncludeBasemaps: Bool { environment.basemaps != nil }
    public var isBusy: Bool { phase == .running || phase == .paused }
    /// Whether a job can start now: sized, nothing blocking it, and none already running.
    public var canStart: Bool { blocker == nil && estimate != nil && !isBusy }
    public var canResume: Bool { interrupted != nil && !isBusy }

    /// Zoom levels for an area of the given width on a map of the given width: two below the map's own to two above,
    /// so the ground can be zoomed into offline. Falls back to z15...19 when the span is not a size.
    public static func defaultZoomRange(longitudeSpan: Double, viewportWidthPoints: Double = 1024) -> ClosedRange<Int> {
        var centre = 17
        if longitudeSpan.isFinite, longitudeSpan > 0, viewportWidthPoints.isFinite, viewportWidthPoints > 0 {
            let zoom = log2(360 / longitudeSpan) + log2(viewportWidthPoints / 256)
            if zoom.isFinite { centre = Int(zoom.rounded()) }
        }
        return clamped(centre - 2)...clamped(centre + 2)
    }

    /// Takes a new area, with zoom levels to suit its size. Ignored while a job is running.
    public func choose(region: GeoRegion, viewportWidthPoints: Double) {
        guard !isBusy else { return }
        self.region = region
        let zooms = Self.defaultZoomRange(longitudeSpan: region.longitudeSpan, viewportWidthPoints: viewportWidthPoints)
        minZ = zooms.lowerBound
        maxZ = zooms.upperBound
        estimate = nil
        blocker = nil
        // The last job's summary is not this area's. The job itself stays resumable, from its own configuration.
        phase = .idle
        progress = nil
    }

    // MARK: - Sizing

    /// Sizes the job as it stands, and says what blocks it, if anything.
    public func refreshEstimate() async {
        pixels = await environment.observedPixels()
        guard let pixels else {
            estimate = nil
            blocker = .tileSizeUnknown
            return
        }
        let configuration = HarvestConfiguration(region: region, minZ: minZ, maxZ: maxZ, pixels: pixels)
        let count = OfflineHarvestCoordinator.tileCount(for: configuration)
        let wantsBasemaps = includeBasemaps && environment.basemaps != nil
        let elevationBytes = Self.bytes(count, each: environment.elevation.estimatedBytesPerTile(pixels: pixels))
        let basemapBytes = wantsBasemaps ? Self.bytes(count, each: environment.basemaps?.estimatedBytesPerTile(pixels: pixels) ?? 0) : 0
        estimate = Estimate(tileCount: count, elevationBytes: elevationBytes, basemapBytes: basemapBytes)

        if elevationBytes > environment.elevationCapacityBytes {
            blocker = .tooLarge(cache: "elevation", estimatedBytes: elevationBytes, capacityBytes: environment.elevationCapacityBytes)
        } else if basemapBytes > environment.basemapCapacityBytes {
            blocker = .tooLarge(cache: "basemap", estimatedBytes: basemapBytes, capacityBytes: environment.basemapCapacityBytes)
        } else {
            blocker = nil
        }
    }

    private static func bytes(_ count: Int, each: Int64) -> Int64 {
        let (total, overflow) = Int64(count).multipliedReportingOverflow(by: each)
        return overflow ? Int64.max : total
    }

    // MARK: - Running

    /// Sizes the job, and runs it to its end unless something blocks it or one is already running.
    public func start() async {
        guard !isBusy, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await refreshEstimate()
        guard blocker == nil, let pixels else { return }
        let configuration = HarvestConfiguration(
            region: region, minZ: minZ, maxZ: maxZ, pixels: pixels,
            includeBasemaps: includeBasemaps && environment.basemaps != nil)
        await run(configuration, resuming: nil)
    }

    /// Continues the last job that was cancelled or had tiles fail, fetching only what its manifest lacks.
    public func resumeInterrupted() async {
        guard !isBusy, !isStarting, let job = interrupted else { return }
        isStarting = true
        defer { isStarting = false }
        await run(job.configuration, resuming: job.id)
    }

    private func run(_ configuration: HarvestConfiguration, resuming jobID: UUID?) async {
        let coordinator = OfflineHarvestCoordinator(
            elevation: environment.elevation,
            basemaps: configuration.includeBasemaps ? environment.basemaps : nil,
            manifestDirectory: environment.manifestDirectory)
        self.coordinator = coordinator
        progress = nil
        phase = .running
        environment.keepAwake(true)
        defer {
            self.coordinator = nil
            environment.keepAwake(false)
        }

        let updates = await coordinator.progress()
        let watcher = Task { for await update in updates { self.progress = update } }
        do {
            let summary = try await coordinator.harvest(configuration, resuming: jobID)
            await watcher.value                      // the stream ends with the harvest, so the last update lands first
            phase = .finished(summary)
            interrupted = summary.state == .cancelled || summary.failed > 0
                ? Interrupted(id: summary.jobID, configuration: configuration) : nil
        } catch {
            watcher.cancel()
            phase = .failed(Self.message(for: error))
            // A job that could not be resumed will not be able to be next time either.
            if jobID != nil { interrupted = nil }
        }
    }

    public func pause() {
        guard phase == .running, let coordinator else { return }
        phase = .paused
        Task { await coordinator.pause() }
    }

    public func resume() {
        guard phase == .paused, let coordinator else { return }
        phase = .running
        Task { await coordinator.resume() }
    }

    /// Stops the job once the tiles in flight have finished. What is done is kept and can be resumed.
    public func cancel() {
        guard isBusy, let coordinator else { return }
        Task { await coordinator.cancel() }
    }

    private static func message(for error: any Error) -> String {
        switch error as? HarvestError {
        case .exceedsCacheCapacity?:
            "This download is larger than the space kept for it."
        case .manifestNotFound?:
            "The record of what had already been downloaded could not be found, so that download cannot be resumed. Start it again."
        case .manifestMismatch?:
            "The area or zoom levels are not the ones that download was made for, so it cannot be resumed."
        case .basemapSourceUnavailable?:
            "The basemap cannot be downloaded."
        case .alreadyRunning?:
            "A download is already running."
        case nil:
            error.localizedDescription
        }
    }
}
