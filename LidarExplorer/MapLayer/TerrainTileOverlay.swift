//
//  TerrainTileOverlay.swift
//  LidarExplorer
//
//  Streams GPU-shaded terrain as map tiles, with detail following zoom.
//

import CoreGraphics
import CoreLocation
import ImageIO
import MapKit
import UniformTypeIdentifiers
import os

/// Shading parameters for the terrain layer.
public nonisolated struct TerrainStyleSettings: Sendable, Equatable {
    public var style: ReliefStyle = .multiDirectional
    public var azimuthDegrees: Double = 315
    public var altitudeDegrees: Double = 35
    /// Absolute-elevation colour range for the `.elevation` style, shared by
    /// every on-screen tile so the hypsometric tint is continuous (no seams).
    /// The viewer recomputes it from the visible area's loaded tiles, so a flat
    /// region is not washed out against a continental range. `nil` falls back
    /// to a continental default before any tile has reported its extent.
    public var elevationRange: ClosedRange<Float>? = nil
    public var contourInterval: ContourInterval = .off
    public var palette: HypsometricPalette = .topo

    public init() {}
}

/// Fetches, shades, and caches one terrain tile at a time.
///
/// Elevation and its derivatives are cached per tile, so changing the light
/// direction re-renders from memory instead of refetching — the same reason
/// the single-raster viewer kept its grid around, now applied per tile.
public actor TerrainTileProvider {

    /// Pixels of overlap fetched beyond each tile edge.
    ///
    /// Horn's 3x3 kernel cannot evaluate the outermost ring of a raster, so a
    /// tile shaded in isolation carries a one-pixel dead border. Seen across
    /// a whole screen that reads as a grid of seams. Fetching a small skirt
    /// and cropping it away after shading makes the joins invisible.
    private nonisolated static let marginPixels = 4

    /// Native ground sample distance of the source, in metres.
    private nonisolated static let nativeResolution = 1.0

    /// Deepest zoom served from 3DEP's native 1 m. Below this, terrarium
    /// is served (native to z15, upsampled above).
    ///
    /// Set to 18, not 16: the 3DEP dynamic ImageServer renders each novel
    /// extent server-side (measured ~3.5s per cold z17 tile, longer on
    /// device), so pushing it down to z16 filled ordinary high-zoom browsing
    /// with slow load-gaps that read as holes. Terrarium tiles are pre-rendered
    /// and return in ~0.2s, so z16-17 now fill instantly; 3DEP's native 1 m
    /// still engages at z18+, where the user has deliberately zoomed in for
    /// maximum detail and far fewer tiles are on screen.
    public nonisolated static let nativeDetailZ = 18

    /// Human-readable source descriptor for a tile at zoom level `z`.
    public nonisolated static func sourceName(forZ z: Int) -> String {
        if z < nativeDetailZ {
            return "terrarium"
        } else {
            return "3DEP 1m"
        }
    }

    private let elevation: any ElevationProviding
    private let terrarium: TerrariumTileService
    private let raster: RasterCompute
    /// Optional observer for the in-app debug panel. Nil in normal use, so
    /// instrumentation costs nothing when the panel is closed.
    private let report: (@Sendable (TileEvent) -> Void)?
    private let diskCache: TileDiskCache

    private var settings = TerrainStyleSettings()
    /// Cached derivatives per tile, so relighting costs no network.
    private var cache: [String: CachedTile] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 160
    /// How long settings must hold still before a render is written to disk.
    ///
    /// Long enough to sit out a slider drag or a pan, short enough that
    /// ordinary browsing still fills the cache promptly. Panning alone does
    /// not change settings, so normal tile loads are only delayed, never
    /// skipped.
    private nonisolated static let writeSettleDelay = Duration.milliseconds(400)
    /// In-flight fetches for ancestor tiles, deduplicating simultaneous child requests.
    private var inFlightAncestors: [String: Task<ElevationGrid?, Never>] = [:]

    private struct CachedTile {
        let grid: ElevationGrid
        let products: ReliefProducts
        let source: String
        /// Robust (2nd/98th percentile) elevation extent, computed once so the
        /// visible-area range for the .elevation style is cheap to union.
        let elevationLow: Float
        let elevationHigh: Float
        var renderedPNG: Data? = nil

        init(grid: ElevationGrid, products: ReliefProducts, source: String) {
            self.grid = grid
            self.products = products
            self.source = source
            let extent = ReliefRenderer.robustRange(of: grid.samples)
            self.elevationLow = extent.lowerBound
            self.elevationHigh = extent.upperBound
        }
    }

    public init(
        elevation: (any ElevationProviding)? = nil,
        terrarium: TerrariumTileService? = nil,
        raster: RasterCompute? = nil,
        report: (@Sendable (TileEvent) -> Void)? = nil,
        diskCache: TileDiskCache? = nil
    ) {
        self.elevation = elevation ?? USGS3DEPService()
        self.terrarium = terrarium ?? TerrariumTileService()
        self.raster = raster ?? RasterCompute()
        self.report = report
        self.diskCache = diskCache ?? TileDiskCache()

        // Evict half the cache under memory pressure to avoid Jetsam kills.
        // The notification is delivered on any thread; we bounce into the
        // actor to mutate cache safely.
        #if canImport(UIKit)
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                await self?.evictUnderPressure()
            }
        }
        // Renders inside the settle window would otherwise be lost when the
        // app is suspended, so close it early on the way out.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willResignActiveNotification
            ) {
                await self?.flushPendingWrites()
            }
        }
        #endif
    }

    /// Halves the cache, keeping the most recently used tiles.
    private func evictUnderPressure() {
        let target = cache.count / 2
        while cacheOrder.count > target {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Robust elevation extent across cached tiles overlapping `region`.
    ///
    /// Used by the `.elevation` style so its ramp fits what is on screen. The
    /// union of already-computed per-tile extents keeps this cheap. Returns
    /// `nil` when no covering tile is cached yet (caller keeps its fallback).
    public func elevationRange(in region: GeoRegion) -> ClosedRange<Float>? {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for tile in cache.values {
            let r = tile.grid.region
            guard r.minLatitude <= region.maxLatitude, r.maxLatitude >= region.minLatitude,
                  r.minLongitude <= region.maxLongitude, r.maxLongitude >= region.minLongitude
            else { continue }
            if tile.elevationLow.isFinite { low = min(low, tile.elevationLow) }
            if tile.elevationHigh.isFinite { high = max(high, tile.elevationHigh) }
        }
        guard low <= high else { return nil }
        return low...high
    }

    /// Applies new shading settings. Returns `true` if anything changed.
    @discardableResult
    public func update(_ newSettings: TerrainStyleSettings) -> Bool {
        guard newSettings != settings else { return false }
        settings = newSettings
        for key in cache.keys {
            cache[key]?.renderedPNG = nil
        }
        return true
    }

    /// Disk-cache key for one tile under a given set of shading settings.
    ///
    /// Every input that changes a pixel is in the key, so a cached image can
    /// never be served for settings it was not rendered with. It is a pure
    /// function of a settings *snapshot* rather than a read of `settings`,
    /// because a tile fetch spans network I/O during which the viewer may
    /// push new settings: the key has to be derived from the same snapshot
    /// the render used, not from whatever is current when the key is built.
    nonisolated static func diskCacheKey(
        x: Int, y: Int, z: Int, settings: TerrainStyleSettings
    ) -> String {
        let base: String
        switch settings.style {
        case .hillshade:
            base = "tile_\(z)_\(x)_\(y)_hillshade_\(Int(settings.azimuthDegrees))_\(Int(settings.altitudeDegrees))"
        case .multiDirectional:
            base = "tile_\(z)_\(x)_\(y)_multiDirectional"
        case .slope:
            base = "tile_\(z)_\(x)_\(y)_slope"
        case .elevation:
            let lo = Int(settings.elevationRange?.lowerBound ?? -100)
            let hi = Int(settings.elevationRange?.upperBound ?? 4500)
            base = "tile_\(z)_\(x)_\(y)_elevation_\(lo)_\(hi)"
        }
        return "\(base)_contour_\(settings.contourInterval.rawValue)_pal_\(settings.palette.rawValue)"
    }

    /// Renders one tile as PNG data, or `nil` if it cannot be produced.
    ///
    /// The elevation source is chosen by zoom, which is what makes browsing
    /// fluid and deep zoom detailed:
    ///
    ///  - up to z17, served from Terrarium (native up to z15, ~0.2s each;
    ///    upsampled ancestor crops at z16-17)
    ///  - z18 and beyond, the 3DEP ImageServer at native 1 m resolution,
    ///    10-18s for a novel extent but covering a small area by then,
    ///    with MapKit showing the upsampled tile until it lands
    public func tileImageData(
        x: Int, y: Int, z: Int,
        region: GeoRegion,
        pixels: Int
    ) async -> Data? {
        let key = "\(z)/\(x)/\(y)"
        let started = Date()

        let cached: CachedTile
        let wasCached: Bool
        if let hit = cache[key] {
            cached = hit
            wasCached = true
            promote(key)
        } else {
            guard let entry = await loadTile(x: x, y: y, z: z, region: region, pixels: pixels)
            else {
                let outcome: TileEvent.Outcome = Task.isCancelled ? .cancelled : .failed
                report?(TileEvent(
                    z: z, x: x, y: y, source: Self.sourceName(forZ: z), outcome: outcome,
                    duration: Date().timeIntervalSince(started)
                ))
                return nil
            }
            store(entry, for: key)
            cached = entry
            wasCached = false
        }

        let sourceName = cached.source

        if let existingData = cached.renderedPNG {
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName,
                outcome: .cached,
                duration: Date().timeIntervalSince(started),
                resolution: cached.grid.groundSampleDistance,
                byteCount: existingData.count,
                backend: cached.products.backend
            ))
            return existingData
        }

        // Snapshot the settings once, after the fetch, and derive everything
        // downstream from it. `loadTile` awaits network I/O, so `settings` can
        // change underneath a tile in flight; keying the read and the write off
        // a pre-fetch value stored images under settings they were not
        // rendered with.
        let currentSettings = settings
        let diskKey = Self.diskCacheKey(x: x, y: y, z: z, settings: currentSettings)

        if let diskData = await diskCache.read(forKey: diskKey) {
            cache[key]?.renderedPNG = diskData
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName,
                outcome: .cached,
                duration: Date().timeIntervalSince(started),
                resolution: cached.grid.groundSampleDistance,
                byteCount: diskData.count,
                backend: .disk
            ))
            return diskData
        }

        let products = cached.products
        let samples = cached.grid.samples

        guard let data = Self.renderPNG(
            products: products,
            samples: samples,
            settings: currentSettings
        ) else {
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName, outcome: .failed,
                duration: Date().timeIntervalSince(started)
            ))
            return nil
        }
        cache[key]?.renderedPNG = data
        schedulePersist(data, tile: key, diskKey: diskKey, renderedWith: currentSettings)

        report?(TileEvent(
            z: z, x: x, y: y, source: sourceName,
            outcome: wasCached ? .cached : .fetched,
            duration: Date().timeIntervalSince(started),
            resolution: cached.grid.groundSampleDistance,
            byteCount: data.count,
            backend: cached.products.backend
        ))
        return data
    }

    /// A render waiting for its settle window to close.
    private struct PendingWrite {
        let diskKey: String
        let data: Data
        let settings: TerrainStyleSettings
        let queuedAt: Date
    }

    /// Renders awaiting a disk write, keyed by tile (`z/x/y`) rather than by
    /// disk key, so a tile re-rendered while its predecessor is still waiting
    /// replaces it instead of queueing beside it.
    ///
    /// Dragging the azimuth slider re-renders every visible tile per settled
    /// value, and in `.elevation` an ordinary pan moves the shared range that
    /// is part of the key, so one settle window can hold several generations
    /// of every visible tile at ~41 KB each. Only the newest render of a tile
    /// can ever be written, so only it is worth holding — this app already
    /// halves its tile cache on memory warnings, and a queue that grew with
    /// scrub duration would push the other way.
    private var pendingWrites: [String: PendingWrite] = [:]

    /// The single in-flight settle timer, if any.
    private var pendingFlush: Task<Void, Never>?

    /// Ceiling on retained renders. Distinct tiles do not coalesce with each
    /// other, so a fast zoom across many tiles still needs a hard stop. The
    /// disk cache is best-effort: dropping a write costs only a later
    /// re-render, where an unbounded queue costs a Jetsam kill.
    nonisolated static let pendingWriteLimit = 256

    /// Queues a rendered tile for a disk write once settings hold still.
    func schedulePersist(
        _ data: Data, tile: String, diskKey: String, renderedWith snapshot: TerrainStyleSettings
    ) {
        // Replacing an existing entry is always allowed; only genuinely new
        // tiles can push the queue against its ceiling. At the ceiling the
        // render just produced is the one the user is most likely looking at,
        // so the stale head of the queue goes instead — during a fast zoom
        // those are tiles already panned away from.
        if pendingWrites[tile] == nil, pendingWrites.count >= Self.pendingWriteLimit {
            if let oldest = pendingWrites.min(by: { $0.value.queuedAt < $1.value.queuedAt })?.key {
                pendingWrites.removeValue(forKey: oldest)
            }
        }
        pendingWrites[tile] = PendingWrite(
            diskKey: diskKey, data: data, settings: snapshot, queuedAt: Date()
        )

        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.writeSettleDelay)
            await self?.flushPendingWrites()
        }
    }

    /// Writes everything queued whose settings are still current.
    func flushPendingWrites() async {
        pendingFlush = nil
        let batch = pendingWrites
        pendingWrites.removeAll()
        for entry in batch.values where entry.settings == settings {
            await diskCache.write(entry.data, forKey: entry.diskKey)
        }
    }

    /// Fetches elevation for a tile and computes its derivatives.
    private func loadTile(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int
    ) async -> CachedTile? {
        let margin = Self.marginPixels

        if z < Self.nativeDetailZ {
            return await loadTerrariumTile(
                x: x, y: y, z: z, region: region, margin: margin,
                source: Self.sourceName(forZ: z)
            )
        }

        // Native-resolution path: fetch a real skirt in Web Mercator rather than inventing one.
        let m = region.mercatorBounds
        let spanX = m.maxX - m.minX
        let spanY = m.maxY - m.minY
        let padX = spanX * Double(margin) / Double(pixels)
        let padY = spanY * Double(margin) / Double(pixels)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX - padX, y: m.minY - padY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX + padX, y: m.maxY + padY)
        let expanded = GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
        let samples = pixels + margin * 2

        if let grid = await elevation
            .elevation(for: expanded, targetSamples: samples).value {
            guard !Task.isCancelled else { return nil }
            let products = await raster.reliefProducts(for: grid)
            let croppedGrid = grid.cropped(margin: margin)
            let croppedProducts = Self.crop(products, margin: margin)
            return CachedTile(
                grid: croppedGrid,
                products: croppedProducts,
                source: "3DEP 1m"
            )
        }

        // If the task was cancelled (user panned away), don't waste
        // resources fetching a fallback tile for a discarded viewport.
        guard !Task.isCancelled else { return nil }

        // Graceful degradation: when 3DEP fails (network timeout, error,
        // or void/outside coverage), fall back to upsampling from the
        // Terrarium ancestor at maximumZ so MapKit doesn't leave a hole.
        return await loadTerrariumTile(
            x: x, y: y, z: z, region: region, margin: margin,
            source: "3DEP 1m (fallback to terrarium)"
        )
    }

    /// Loads a tile from Terrarium (native zoom up to 15, or upsampled ancestor).
    private func loadTerrariumTile(
        x: Int, y: Int, z: Int, region: GeoRegion, margin: Int, source: String
    ) async -> CachedTile? {
        guard !Task.isCancelled else { return nil }
        let sourceZ = min(z, TerrariumTileService.maximumZ)
        let scale = 1 << (z - sourceZ)
        let sourceX = x / scale
        let sourceY = y / scale
        let ancestorKey = "\(sourceZ)/\(sourceX)/\(sourceY)"

        let ancestorGrid: ElevationGrid?
        if let existingTask = inFlightAncestors[ancestorKey] {
            ancestorGrid = await existingTask.value
        } else {
            let task = Task<ElevationGrid?, Never> { [terrarium] in
                let sourceRegion = TerrainTileOverlay.region(
                    for: MKTileOverlayPath(x: sourceX, y: sourceY, z: sourceZ, contentScaleFactor: 1)
                )
                return await terrarium.elevation(x: sourceX, y: sourceY, z: sourceZ, region: sourceRegion).value
            }
            inFlightAncestors[ancestorKey] = task
            ancestorGrid = await task.value
            inFlightAncestors.removeValue(forKey: ancestorKey)
        }

        guard let ancestor = ancestorGrid else { return nil }

        if scale == 1 {
            let padded = Self.padByReplication(ancestor, margin: margin)
            let products = await raster.reliefProducts(for: padded)
            return CachedTile(
                grid: ancestor,
                products: Self.crop(products, margin: margin),
                source: source
            )
        }

        // When the request is deeper than terrarium goes, take just the
        // part of the ancestor covering this tile, extracting the skirt
        // directly from the ancestor to avoid replication seams.
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

        let paddedGrid = ElevationGrid(
            width: paddedW, height: paddedH, samples: paddedSamples, region: paddedRegion
        )
        let products = await raster.reliefProducts(for: paddedGrid)
        let croppedGrid = paddedGrid.cropped(margin: margin)
        let croppedProducts = Self.crop(products, margin: margin)
        return CachedTile(
            grid: croppedGrid,
            products: croppedProducts,
            source: source
        )
    }


    /// Grows a grid by repeating its edge samples outward.
    nonisolated static func padByReplication(
        _ grid: ElevationGrid, margin: Int
    ) -> ElevationGrid {
        guard margin > 0, grid.width > 0, grid.height > 0 else { return grid }
        let w = grid.width + margin * 2
        let h = grid.height + margin * 2
        var out = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            let sy = min(max(y - margin, 0), grid.height - 1)
            for x in 0..<w {
                let sx = min(max(x - margin, 0), grid.width - 1)
                out[y * w + x] = grid.samples[sy * grid.width + sx]
            }
        }
        // Adjust in Web Mercator to preserve exact square coordinates.
        let m = grid.region.mercatorBounds
        let spanX = m.maxX - m.minX
        let spanY = m.maxY - m.minY
        let padX = spanX * Double(margin) / Double(grid.width)
        let padY = spanY * Double(margin) / Double(grid.height)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX - padX, y: m.minY - padY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX + padX, y: m.maxY + padY)
        let region = GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
        return ElevationGrid(width: w, height: h, samples: out, region: region)
    }

    /// Trims the skirt from computed rasters.
    nonisolated static func crop(_ products: ReliefProducts, margin: Int) -> ReliefProducts {
        guard margin > 0,
              products.width > margin * 2, products.height > margin * 2
        else { return products }
        let w = products.width - margin * 2
        let h = products.height - margin * 2

        func trim(_ source: [Float]) -> [Float] {
            [Float](unsafeUninitializedCapacity: w * h) { dstBuffer, initializedCount in
                source.withUnsafeBufferPointer { srcBuffer in
                    guard let srcBase = srcBuffer.baseAddress,
                          let dstBase = dstBuffer.baseAddress else { return }
                    for y in 0..<h {
                        let srcOffset = (y + margin) * products.width + margin
                        let dstOffset = y * w
                        (dstBase + dstOffset).initialize(from: srcBase + srcOffset, count: w)
                    }
                }
                initializedCount = w * h
            }
        }

        return ReliefProducts(
            slopeDegrees: trim(products.slopeDegrees),
            aspectDegrees: trim(products.aspectDegrees),
            multiDirectionalRelief: trim(products.multiDirectionalRelief),
            width: w, height: h,
            backend: products.backend
        )
    }

    /// Elevation at a coordinate, from whichever cached tile covers it best.
    ///
    /// Prefers the finest tile available, so the readout matches what is on
    /// screen rather than some coarser cached ancestor.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        var best: (resolution: Double, value: Float)?
        for entry in cache.values {
            guard entry.grid.region.contains(coordinate),
                  let index = entry.grid.index(for: coordinate),
                  let value = entry.grid.sample(x: index.x, y: index.y)
            else { continue }
            let resolution = entry.grid.groundSampleDistance
            if best == nil || resolution < best!.resolution {
                best = (resolution, value)
            }
        }
        return best?.value
    }

    /// Inspects spot elevation, slope, and aspect at a coordinate using cached tiles.
    /// Prefers the finest available tile.
    public func inspectSpot(at coord: CLLocationCoordinate2D) -> SpotInspection? {
        var best: (resolution: Double, spot: SpotInspection)?
        for entry in cache.values {
            guard entry.grid.region.contains(coord) else { continue }
            guard let elev = entry.grid.elevation(at: coord) else { continue }
            let (col, row) = entry.grid.gridCoordinates(for: coord)
            let c = min(max(Int(round(col)), 0), entry.grid.width - 1)
            let r = min(max(Int(round(row)), 0), entry.grid.height - 1)
            let idx = r * entry.grid.width + c
            guard idx < entry.products.slopeDegrees.count, idx < entry.products.aspectDegrees.count else { continue }
            let slope = entry.products.slopeDegrees[idx]
            let aspect = entry.products.aspectDegrees[idx]
            let spot = SpotInspection(
                coordinate: coord,
                elevationMeters: elev,
                slopeDegrees: slope,
                aspectDegrees: aspect
            )
            let resolution = entry.grid.groundSampleDistance
            if best == nil || resolution < best!.resolution {
                best = (resolution, spot)
            }
        }
        return best?.spot
    }

    /// Ground sample distance of the finest cached tile, for display.
    public func finestResolution() -> Double? {
        cache.values.map(\.grid.groundSampleDistance).min()
    }

    /// Generates a 2-point elevation profile transect with tiered sampling.
    public func profile(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        sampleCount: Int = 100
    ) async -> ElevationProfile? {
        let count = max(sampleCount, 2)
        let mStart = GeoRegion.toMercatorMeters(start)
        let mEnd = GeoRegion.toMercatorMeters(end)
        let dx = mEnd.x - mStart.x
        let dy = mEnd.y - mStart.y
        let totalDistance = (dx * dx + dy * dy).squareRoot()
        guard totalDistance > 1.0 else { return nil }

        var points: [ElevationProfilePoint] = []
        points.reserveCapacity(count)

        var lastValidElevation: Float = 0
        var hasValidElevation = false

        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            let currX = mStart.x + t * dx
            let currY = mStart.y + t * dy
            let coord = GeoRegion.fromMercatorMeters(x: currX, y: currY)
            let dist = t * totalDistance

            var best: (resolution: Double, value: Float)?
            for entry in cache.values {
                guard entry.grid.region.contains(coord),
                      let index = entry.grid.index(for: coord),
                      let value = entry.grid.sample(x: index.x, y: index.y)
                else { continue }
                let resolution = entry.grid.groundSampleDistance
                if best == nil || resolution < best!.resolution {
                    best = (resolution, value)
                }
            }

            if let best {
                lastValidElevation = best.value
                hasValidElevation = true
                points.append(ElevationProfilePoint(
                    id: i,
                    distanceMeters: dist,
                    elevationMeters: best.value,
                    coordinate: coord,
                    isHighResolution: best.resolution <= 2.0
                ))
            } else if hasValidElevation {
                points.append(ElevationProfilePoint(
                    id: i,
                    distanceMeters: dist,
                    elevationMeters: lastValidElevation,
                    coordinate: coord,
                    isHighResolution: false
                ))
            } else {
                points.append(ElevationProfilePoint(
                    id: i,
                    distanceMeters: dist,
                    elevationMeters: 0,
                    coordinate: coord,
                    isHighResolution: false
                ))
            }
        }

        guard hasValidElevation else { return nil }
        return ElevationProfile(start: start, end: end, points: points)
    }

    /// Drops cached imagery. Derivatives are kept — only shading changed.
    public func clear() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    public func diskCacheSize() async -> Int64? {
        await diskCache.measureDiskUsage()
    }

    /// Hit/miss tallies for the disk tier since launch.
    public func diskCacheStatistics() async -> TileDiskCache.Statistics {
        await diskCache.statistics()
    }

    public func clearDiskCache() async {
        await diskCache.clear()
        clear()
    }

    // MARK: - Rendering

    private nonisolated static func render(
        products: ReliefProducts,
        samples: [Float],
        settings: TerrainStyleSettings
    ) -> CGImage? {
        let values: [Float]
        let range: ClosedRange<Float>?

        switch settings.style {
        case .hillshade:
            values = TerrainAnalysis.hillshade(
                products.derivatives,
                azimuthDegrees: settings.azimuthDegrees,
                altitudeDegrees: settings.altitudeDegrees
            )
            range = 0...1
        case .multiDirectional:
            values = products.multiDirectionalRelief
            // Fixed range, not per-tile. A per-tile range would normalise each
            // tile against its own contrast, so a flat tile beside a rugged
            // one would be stretched to look equally textured and the seam
            // would be obvious.
            range = 0...0.18
        case .slope:
            values = products.slopeDegrees
            range = 0...45
        case .elevation:
            values = samples
            // Shared range supplied by the viewer from the visible area's
            // extent — one range for all on-screen tiles, so the tint stays
            // continuous (no per-tile seams) yet fits the local elevation
            // instead of a washed-out continental scale. Falls back to a
            // continental range until the first tiles report their extent.
            range = settings.elevationRange ?? (-100 ... 4500)
        }

        return ReliefRenderer.image(
            from: values,
            width: products.width,
            height: products.height,
            style: settings.style,
            range: range,
            elevation: samples,
            contourInterval: settings.contourInterval,
            palette: settings.palette
        )
    }

    private nonisolated static func renderPNG(
        products: ReliefProducts,
        samples: [Float],
        settings: TerrainStyleSettings
    ) -> Data? {
        autoreleasepool {
            guard let image = render(products: products, samples: samples, settings: settings) else {
                return nil
            }
            return pngData(from: image)
        }
    }

    private nonisolated static func pngData(from image: CGImage) -> Data? {
        autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }

    private func promote(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    private func store(_ tile: CachedTile, for key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
        cache[key] = tile
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

/// Terrain shading delivered as map tiles.
///
/// Being an `MKTileOverlay` is the whole point: MapKit already decides which
/// tiles a view needs, requests them as the user pans, discards them when
/// they leave, and swaps detail levels as the zoom changes. Reimplementing
/// that on top of a single full-view raster is what made the previous design
/// need an explicit "Load terrain" button and feel like a modal operation.
///
/// `nonisolated` because MapKit calls `loadTile` from a background queue and
/// the superclass declares its members nonisolated.
public nonisolated final class TerrainTileOverlay: MKTileOverlay {

    private let provider: TerrainTileProvider

    public init(provider: TerrainTileProvider) {
        self.provider = provider
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 256, height: 256)
        self.canReplaceMapContent = false
        // Generous, because maximumZ is a hard cutoff rather than an
        // upsample hint: if MapKit needs a deeper tile than this it draws
        // nothing at all. On a retina display it asks about two levels
        // deeper than the apparent zoom — z21 for an apparent z19 — so a tight
        // cap silently blanked the whole layer. Depth is handled in the
        // provider instead, by source selection.
        self.minimumZ = 6
        self.maximumZ = 21
    }

    /// Produces one shaded terrain tile.
    ///
    /// Overrides the **async** form. `loadTileAtPath:result:` is annotated
    /// `NS_SWIFT_ASYNC(2)` in MapKit's headers, so Swift imports it primarily
    /// as `func loadTile(at:) async throws -> Data`. Overriding the
    /// completion-handler spelling compiles — that form is still exposed —
    /// but MapKit dispatches through the async entry point, so the override
    /// was never reached and no tile was ever requested.
    public override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        let region = Self.region(for: path)
        // MapKit asks for @2x tiles on retina, landing at 512px.
        let pixels = Int(tileSize.width * max(path.contentScaleFactor, 1))

        guard let data = await provider.tileImageData(
            x: path.x, y: path.y, z: path.z, region: region, pixels: pixels
        ) else {
            // No data here is a fact — ocean, or outside coverage — but the
            // async form has no way to say "nothing" except by throwing.
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    /// Geographic bounds of a Web Mercator tile.
    static func region(for path: MKTileOverlayPath) -> GeoRegion {
        let n = pow(2.0, Double(path.z))
        let lonMin = Double(path.x) / n * 360 - 180
        let lonMax = Double(path.x + 1) / n * 360 - 180
        // Inverse Mercator: latitude is nonlinear in tile row.
        let latMax = atan(sinh(.pi * (1 - 2 * Double(path.y) / n))) * 180 / .pi
        let latMin = atan(sinh(.pi * (1 - 2 * Double(path.y + 1) / n))) * 180 / .pi
        return GeoRegion(
            minLatitude: latMin, maxLatitude: latMax,
            minLongitude: lonMin, maxLongitude: lonMax
        )
    }
}
