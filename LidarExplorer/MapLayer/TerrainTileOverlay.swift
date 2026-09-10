//
//  TerrainTileOverlay.swift
//  LidarExplorer
//
//  Streams GPU-shaded terrain as map tiles, with detail following zoom.
//

import CoreGraphics
import CoreLocation
import MapKit
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
    /// and reading across it in the shader makes the joins invisible — the
    /// skirt is never removed from the buffer, only left outside the dispatch.
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
    /// The one disk tier: elevation rasters, keyed only by tile.
    ///
    /// There used to be a second tier holding rendered tiles, and it existed
    /// only to hide the cost of producing one. That cost was 8-18 ms of CPU
    /// derivative loops, colour lookups, contour evaluation and PNG encoding;
    /// the fused kernel now does the same work in well under a millisecond
    /// from a raster already in memory, which is faster than opening a file
    /// and reading an uncompressed tile back off flash.
    ///
    /// Retiring it removes more than a cache. A rendered tile is keyed by
    /// everything that changes a pixel — azimuth, altitude, contour interval,
    /// palette, and in `.elevation` the view-adaptive range — so it needed a
    /// settle timer, a coalescing queue and a write ceiling purely to stop a
    /// slider drag from writing a generation of every visible tile to flash.
    /// A raster is presentation-invariant: one cached 3DEP tile answers every
    /// azimuth, every palette and every contour setting, with no key to
    /// invalidate and nothing to debounce.
    private let gridCache: TileDiskCache

    private var settings = TerrainStyleSettings()
    /// Cached derivatives per tile, so relighting costs no network.
    private var cache: [String: CachedTile] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 160

    /// Tiles currently holding a shaded bitmap, most recent last.
    ///
    /// Separate from `cacheOrder` and much shorter, because the two hold very
    /// different things. A cached raster is ~272 KB and answers every setting;
    /// a shaded bitmap is ~1 MB of uncompressed RGBA that answers exactly one.
    /// Enough of them to cover a viewport and its immediate surroundings keeps
    /// a pan smooth, and past that the cheapest thing to do with a bitmap is
    /// throw it away and dispatch the kernel again.
    private var renderedOrder: [String] = []
    private let renderedLimit = 48

    /// Disk budget for elevation rasters — roughly 1,800 tiles at 272 KB.
    ///
    /// The whole of what the app spends on disk, since the rendered-tile tier
    /// was retired: its 150 MB went here rather than away, so the footprint is
    /// unchanged and every byte of it now answers any shading the user picks.
    private nonisolated static let gridCacheBytes: Int64 = 500 * 1024 * 1024

    private nonisolated static let gridCacheDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("TerrainGrids", isDirectory: true)
    }()

    /// Whether a raster from `source` is worth persisting.
    ///
    /// When 3DEP fails the tile is upsampled from a terrarium ancestor so the
    /// map does not show a hole. Caching that would outlive the outage that
    /// produced it and pin low-detail data over ground that has real 1 m
    /// coverage, so degraded results are used and discarded.
    nonisolated static func isCacheableSource(_ source: String) -> Bool {
        !source.contains("fallback")
    }
    /// In-flight fetches for ancestor tiles, deduplicating simultaneous child requests.
    private var inFlightAncestors: [String: Task<ElevationGrid?, Never>] = [:]

    private struct CachedTile {
        /// The *padded* raster: the tile plus its skirt, exactly as fetched.
        ///
        /// Held uncropped because nothing downstream needs it cropped any
        /// more. The shader reads its 3x3 window at `gid + margin`, and the
        /// display bounds come from ``ElevationGrid/croppedRegion(margin:)``,
        /// which is four multiplications rather than a row-by-row `memcpy` of
        /// every tile the app has ever downloaded.
        let grid: ElevationGrid
        let products: ReliefProducts
        let source: String
        let margin: Int
        /// Bounds of the tile itself, skirt excluded.
        let displayRegion: GeoRegion
        /// The mapping `grid` was decoded from, when it came from disk.
        ///
        /// Kept so a re-render hands Metal the very pages the cache file
        /// occupies instead of copying the samples in again. Nil for a raster
        /// that arrived over the network.
        let mapped: MappedFile?
        let sampleOffset: Int
        /// Robust (2nd/98th percentile) elevation extent, computed once so the
        /// visible-area range for the .elevation style is cheap to union.
        let elevationLow: Float
        let elevationHigh: Float
        /// The shaded tile, in the shared buffer the GPU wrote it into.
        var rendered: CGImage? = nil

        init(
            grid: ElevationGrid,
            products: ReliefProducts,
            source: String,
            margin: Int,
            mapped: MappedFile? = nil,
            sampleOffset: Int = 0
        ) {
            self.grid = grid
            self.products = products
            self.source = source
            self.margin = margin
            self.displayRegion = grid.croppedRegion(margin: margin)
            self.mapped = mapped
            self.sampleOffset = sampleOffset
            let extent = ReliefRenderer.robustRange(of: grid.samples)
            self.elevationLow = extent.lowerBound
            self.elevationHigh = extent.upperBound
        }

        /// Where the shader should read this tile's samples from.
        var samples: ElevationSamples {
            if let mapped {
                return .mapped(
                    base: mapped.base,
                    mappedLength: mapped.mappedLength,
                    sampleOffset: sampleOffset,
                    owner: mapped
                )
            }
            return .array(grid.samples)
        }
    }

    public init(
        elevation: (any ElevationProviding)? = nil,
        terrarium: TerrariumTileService? = nil,
        raster: RasterCompute? = nil,
        report: (@Sendable (TileEvent) -> Void)? = nil,
        gridCache: TileDiskCache? = nil
    ) {
        self.elevation = elevation ?? USGS3DEPService()
        self.terrarium = terrarium ?? TerrariumTileService()
        self.raster = raster ?? RasterCompute()
        self.report = report
        self.gridCache = gridCache ?? TileDiskCache(
            directory: Self.gridCacheDirectory,
            maxDiskBytes: Self.gridCacheBytes,
            targetDiskBytes: Self.gridCacheBytes * 4 / 5
        )

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
        #endif
    }

    /// Halves the cache, keeping the most recently used tiles.
    ///
    /// Shaded bitmaps go first and entirely: they are the largest thing held
    /// per tile and the cheapest to rebuild, so under pressure there is no
    /// argument for keeping any of them.
    private func evictUnderPressure() {
        releaseAllBitmaps()
        let target = cache.count / 2
        while cacheOrder.count > target {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Drops every shaded bitmap, keeping the rasters they were shaded from.
    private func releaseAllBitmaps() {
        for key in renderedOrder { cache[key]?.rendered = nil }
        renderedOrder.removeAll()
    }

    /// Records that `key` now holds a bitmap, evicting the oldest past the cap.
    private func noteRendered(_ key: String) {
        if let index = renderedOrder.firstIndex(of: key) {
            renderedOrder.remove(at: index)
        }
        renderedOrder.append(key)
        while renderedOrder.count > renderedLimit {
            cache[renderedOrder.removeFirst()]?.rendered = nil
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
            let r = tile.displayRegion
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
        releaseAllBitmaps()
        return true
    }

    /// Produces one shaded tile, or `nil` if it cannot be built.
    ///
    /// The elevation source is chosen by zoom, which is what makes browsing
    /// fluid and deep zoom detailed:
    ///
    ///  - up to z17, served from Terrarium (native up to z15, ~0.2s each;
    ///    upsampled ancestor crops at z16-17)
    ///  - z18 and beyond, the 3DEP ImageServer at native 1 m resolution,
    ///    10-18s for a novel extent but covering a small area by then,
    ///    with MapKit showing the upsampled tile until it lands
    ///
    /// What comes back is a `CGImage` over the shared buffer the GPU shaded
    /// into. Nothing is encoded on the way out and nothing has to be decoded
    /// on the way in: the renderer draws these bytes directly.
    public func tileImage(
        x: Int, y: Int, z: Int,
        region: GeoRegion,
        pixels: Int
    ) async -> CGImage? {
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

        if let existing = cached.rendered {
            noteRendered(key)
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName,
                outcome: .cached,
                duration: Date().timeIntervalSince(started),
                resolution: cached.grid.groundSampleDistance,
                byteCount: existing.bytesPerRow * existing.height,
                backend: cached.products.backend
            ))
            return existing
        }

        // Snapshot the settings once, after the fetch, and derive everything
        // downstream from it. `loadTile` awaits network I/O, so `settings` can
        // change underneath a tile in flight, and a tile has to be shaded with
        // one coherent set of values rather than a mixture.
        let currentSettings = settings

        guard let image = await shadeToImage(cached, settings: currentSettings) else {
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName, outcome: .failed,
                duration: Date().timeIntervalSince(started)
            ))
            return nil
        }

        // Only keep it if the settings it was shaded with are still current;
        // otherwise it is already stale and would be served once before the
        // reload that supersedes it.
        if currentSettings == settings {
            cache[key]?.rendered = image
            noteRendered(key)
        }

        report?(TileEvent(
            z: z, x: x, y: y, source: sourceName,
            outcome: wasCached ? .cached : .fetched,
            duration: Date().timeIntervalSince(started),
            resolution: cached.grid.groundSampleDistance,
            byteCount: image.bytesPerRow * image.height,
            backend: cached.products.backend
        ))
        return image
    }

    /// Bounds of a cached tile's imagery, skirt excluded.
    ///
    /// Purely analytic — the samples never move — so a caller can position a
    /// tile without any part of it being copied.
    public func displayRegion(x: Int, y: Int, z: Int) -> GeoRegion? {
        cache["\(z)/\(x)/\(y)"]?.displayRegion
    }

    /// Shades a cached raster, on the GPU where it can be.
    ///
    /// The fused kernel is one dispatch producing finished premultiplied
    /// pixels in shared memory. When it is unavailable — no Metal device, or a
    /// GPU that will not back a texture with a buffer — the CPU path still
    /// produces the same picture from the derivatives already computed, and
    /// that is the only place the skirt is still cropped away.
    private func shadeToImage(
        _ tile: CachedTile, settings: TerrainStyleSettings
    ) async -> CGImage? {
        let request = TerrainRenderRequest(
            style: settings.style,
            azimuthDegrees: settings.azimuthDegrees,
            altitudeDegrees: settings.altitudeDegrees,
            contourIntervalMeters: settings.contourInterval.meters,
            range: Self.displayRange(for: settings),
            palette: settings.palette,
            margin: tile.margin
        )

        if let bitmap = await raster.renderTile(
            samples: tile.samples,
            paddedWidth: tile.grid.width,
            paddedHeight: tile.grid.height,
            metersPerColumn: tile.grid.metersPerColumn,
            metersPerRow: tile.grid.metersPerRow,
            request: request
        ), let image = bitmap.makeImage() {
            return image
        }

        return Self.cpuRender(
            tile.grid, products: tile.products, margin: tile.margin, settings: settings
        )
    }

    /// The value range a style maps across its colour ramp.
    ///
    /// Fixed per style rather than per tile, except for `.elevation`. A
    /// per-tile range would normalise each tile against its own contrast, so a
    /// flat tile beside a rugged one would be stretched to look equally
    /// textured and the seam would be obvious.
    nonisolated static func displayRange(
        for settings: TerrainStyleSettings
    ) -> ClosedRange<Float> {
        switch settings.style {
        case .hillshade: 0...1
        case .multiDirectional: 0...0.18
        case .slope: 0...45
        // Shared range supplied by the viewer from the visible area's extent —
        // one range for all on-screen tiles, so the tint stays continuous yet
        // fits the local elevation instead of a washed-out continental scale.
        case .elevation: settings.elevationRange ?? (-100 ... 4500)
        }
    }

    /// Rasters awaiting a disk write, keyed by cache key so a repeated tile
    /// collapses onto one entry.
    private var pendingGridWrites: [String: Data] = [:]

    /// The single in-flight drain, if any.
    private var gridWriteDrain: Task<Void, Never>?

    /// Ceiling on encoded rasters held for writing.
    ///
    /// Each is ~272 KB, so an unbounded queue here is expensive per entry. The
    /// disk cache is best-effort: refusing a write costs one later re-fetch,
    /// where growing without a ceiling costs a Jetsam kill.
    nonisolated static let pendingGridWriteLimit = 64

    /// One fetched raster, before shading.
    ///
    /// Always the *padded* grid — the tile plus its skirt. Horn's 3x3 kernel
    /// cannot evaluate a raster's outermost ring, so derivatives are computed
    /// across the skirt and cropped afterwards; caching the padded form means
    /// a restored tile takes the identical path to a freshly fetched one.
    private struct FetchedRaster {
        let padded: ElevationGrid
        let source: String
    }

    /// Disk key for a tile's elevation raster.
    ///
    /// Deliberately carries nothing about shading: that independence is the
    /// whole point. `pixels` and the margin are in it because they determine
    /// the raster's dimensions.
    nonisolated static func gridCacheKey(x: Int, y: Int, z: Int, pixels: Int, margin: Int) -> String {
        "grid_\(z)_\(x)_\(y)_p\(pixels)_m\(margin)"
    }

    /// Fetches elevation for a tile and computes its derivatives.
    private func loadTile(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int
    ) async -> CachedTile? {
        let margin = Self.marginPixels
        let gridKey = Self.gridCacheKey(x: x, y: y, z: z, pixels: pixels, margin: margin)

        // Mapped, not read. `Data(contentsOf:)` allocated the whole file on
        // the heap, and decoding then copied it a second time into a `[UInt8]`
        // and a third into the sample array. Mapping is one page-aligned
        // region the kernel faults in on demand: one copy to build the grid
        // the readouts need, and none at all for the samples the shader reads,
        // which it takes straight out of these pages.
        if let mapped = await gridCache.map(forKey: gridKey),
           let header = ElevationGridCoder.decodeHeader(mapped.bytes),
           let decoded = ElevationGridCoder.decode(mapped.bytes) {
            guard !Task.isCancelled else { return nil }
            let products = await raster.reliefProducts(for: decoded.grid)
            return CachedTile(
                grid: decoded.grid,
                products: products,
                source: decoded.source,
                margin: margin,
                // Only a page-aligned payload can back a Metal buffer; a
                // `LEG1` file left over from an earlier build decodes fine but
                // takes the copying path.
                mapped: header.isPageAligned ? mapped : nil,
                sampleOffset: header.sampleOffset
            )
        }

        guard let fetched = await fetchRaster(
            x: x, y: y, z: z, region: region, pixels: pixels, margin: margin
        ) else { return nil }

        if Self.isCacheableSource(fetched.source),
           let encoded = ElevationGridCoder.encode(fetched.padded, source: fetched.source) {
            queueGridWrite(encoded, forKey: gridKey)
        }

        return await shade(fetched, margin: margin)
    }

    /// Queues an encoded raster for writing.
    func queueGridWrite(_ data: Data, forKey key: String) {
        if pendingGridWrites[key] == nil,
           pendingGridWrites.count >= Self.pendingGridWriteLimit { return }
        pendingGridWrites[key] = data

        guard gridWriteDrain == nil else { return }
        gridWriteDrain = Task { [weak self] in await self?.drainGridWrites() }
    }

    /// Writes queued rasters one at a time.
    ///
    /// No settle window, unlike rendered tiles: a raster does not depend on
    /// shading settings, so nothing can supersede it and there is nothing to
    /// wait for.
    private func drainGridWrites() async {
        while let next = pendingGridWrites.first {
            pendingGridWrites.removeValue(forKey: next.key)
            await gridCache.write(next.value, forKey: next.key)
        }
        // Reached only with the queue empty, and no suspension separates that
        // check from this assignment, so a raster queued afterwards cannot
        // find a drain that has already stopped.
        gridWriteDrain = nil
    }

    /// Derives shading products from a raster, skirt and all.
    ///
    /// Nothing is cropped here any more. Both the raster and its derivatives
    /// stay padded, `margin` travels with them, and the two row-by-row copies
    /// that used to strip the skirt off every downloaded tile — one for the
    /// grid, one for each of three derivative planes — simply do not happen.
    private func shade(_ fetched: FetchedRaster, margin: Int) async -> CachedTile? {
        guard !Task.isCancelled else { return nil }
        let products = await raster.reliefProducts(for: fetched.padded)
        return CachedTile(
            grid: fetched.padded,
            products: products,
            source: fetched.source,
            margin: margin
        )
    }

    /// Fetches a tile's padded raster from whichever source suits its zoom.
    private func fetchRaster(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int, margin: Int
    ) async -> FetchedRaster? {
        if z < Self.nativeDetailZ {
            return await fetchTerrariumRaster(
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
            return FetchedRaster(padded: grid, source: "3DEP 1m")
        }

        // If the task was cancelled (user panned away), don't waste
        // resources fetching a fallback tile for a discarded viewport.
        guard !Task.isCancelled else { return nil }

        // Graceful degradation: when 3DEP fails (network timeout, error,
        // or void/outside coverage), fall back to upsampling from the
        // Terrarium ancestor at maximumZ so MapKit doesn't leave a hole.
        return await fetchTerrariumRaster(
            x: x, y: y, z: z, region: region, margin: margin,
            source: "3DEP 1m (fallback to terrarium)"
        )
    }

    /// Fetches a padded raster from Terrarium (native to z15, or upsampled ancestor).
    private func fetchTerrariumRaster(
        x: Int, y: Int, z: Int, region: GeoRegion, margin: Int, source: String
    ) async -> FetchedRaster? {
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
            // padByReplication and cropped(margin:) inset and outset by the
            // same Web Mercator span, so shade() recovers `ancestor` exactly.
            return FetchedRaster(
                padded: Self.padByReplication(ancestor, margin: margin), source: source
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

        return FetchedRaster(
            padded: ElevationGrid(
                width: paddedW, height: paddedH, samples: paddedSamples, region: paddedRegion
            ),
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

    /// Elevation at a coordinate, from whichever cached tile covers it best.
    ///
    /// Prefers the finest tile available, so the readout matches what is on
    /// screen rather than some coarser cached ancestor.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        var best: (resolution: Double, value: Float)?
        for entry in cache.values {
            // Bounded by the tile proper, not by the padded raster: the skirt
            // overlaps its neighbours, and a coordinate should be answered by
            // the tile that actually displays it.
            guard entry.displayRegion.contains(coordinate),
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
            guard entry.displayRegion.contains(coord) else { continue }
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
                guard entry.displayRegion.contains(coord),
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
        renderedOrder.removeAll()
    }

    /// Bytes held on disk, or `nil` if the cache cannot be read.
    ///
    /// A directory that cannot be enumerated makes the figure unknown rather
    /// than smaller: reporting an unreadable cache as an empty one tells the
    /// user their tiles are gone.
    public func diskCacheSize() async -> Int64? {
        await gridCache.measureDiskUsage()
    }

    /// Hit/miss tallies for the tier that decides whether a tile is refetched.
    public func diskCacheStatistics() async -> TileDiskCache.Statistics {
        await gridCache.statistics()
    }

    public func clearDiskCache() async {
        await gridCache.clear()
        clear()
    }

    // MARK: - CPU fallback rendering

    /// Shades a padded tile on the CPU, for devices the display kernel cannot
    /// run on.
    ///
    /// Deliberately the slow path, and the only one left that moves memory to
    /// remove a skirt: it works from the derivative arrays that were computed
    /// anyway, trims them and the elevation to the destination tile, and hands
    /// the result to the same colour ramps the palette texture is built from.
    /// A device that reaches here draws the same picture, just not as cheaply.
    private nonisolated static func cpuRender(
        _ grid: ElevationGrid,
        products: ReliefProducts,
        margin: Int,
        settings: TerrainStyleSettings
    ) -> CGImage? {
        autoreleasepool {
            let width = products.width - margin * 2
            let height = products.height - margin * 2
            guard width > 0, height > 0 else { return nil }

            let values: [Float]
            switch settings.style {
            case .hillshade:
                values = TerrainAnalysis.hillshade(
                    products.derivatives,
                    azimuthDegrees: settings.azimuthDegrees,
                    altitudeDegrees: settings.altitudeDegrees
                )
            case .multiDirectional:
                values = products.multiDirectionalRelief
            case .slope:
                values = products.slopeDegrees
            case .elevation:
                values = grid.samples
            }

            return ReliefRenderer.image(
                from: trim(values, width: products.width, margin: margin),
                width: width,
                height: height,
                style: settings.style,
                range: displayRange(for: settings),
                elevation: trim(grid.samples, width: grid.width, margin: margin),
                contourInterval: settings.contourInterval,
                palette: settings.palette
            )
        }
    }

    /// Copies the destination tile out of a padded plane.
    private nonisolated static func trim(
        _ source: [Float], width: Int, margin: Int
    ) -> [Float] {
        guard margin > 0 else { return source }
        let height = source.count / max(width, 1)
        let w = width - margin * 2
        let h = height - margin * 2
        guard w > 0, h > 0 else { return source }
        return [Float](unsafeUninitializedCapacity: w * h) { dst, initialized in
            source.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                for y in 0..<h {
                    (dstBase + y * w).initialize(
                        from: srcBase + (y + margin) * width + margin, count: w
                    )
                }
            }
            initialized = w * h
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
/// The overlay itself no longer *produces* anything: it describes the tile
/// grid and carries the provider, and ``TerrainTileOverlayRenderer`` draws
/// from it. That split is what removes the image codec from the tile path —
/// see the renderer.
///
/// `nonisolated` because MapKit touches these members from background queues
/// and the superclass declares its own nonisolated.
public nonisolated final class TerrainTileOverlay: MKTileOverlay {

    let provider: TerrainTileProvider

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

    /// Never the path a tile actually takes.
    ///
    /// `MKTileOverlay` requires *something* here when `urlTemplate` is nil, and
    /// the base implementation would assert. Tiles are produced by
    /// ``TerrainTileOverlayRenderer`` instead, which is the whole point: this
    /// method can only answer in `Data`, and answering in `Data` is what forced
    /// a PNG encode on the way out and a decode on the way back in.
    public override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        throw CocoaError(.featureUnsupported)
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

    /// The projected extent of a tile, for positioning its imagery.
    static func mapRect(for path: MKTileOverlayPath) -> MKMapRect {
        let side = MKMapSize.world.width / pow(2.0, Double(path.z))
        return MKMapRect(
            x: Double(path.x) * side, y: Double(path.y) * side, width: side, height: side
        )
    }
}

/// Draws terrain tiles from uncompressed pixels the GPU just produced.
///
/// ## Why this exists
///
/// `MKTileOverlay.loadTile(at:)` can only answer in `Data`, and MapKit reads
/// that answer as an encoded image. So a tile that already existed as raw
/// premultiplied RGBA had to be run through ImageIO to become a PNG, handed
/// over, and immediately inflated back into the same bytes on a MapKit
/// background thread before being uploaded as a texture — 8-18 ms of
/// compression and decompression per tile, for a payload that never left the
/// process and never needed to be a file.
///
/// Overriding the renderer sidesteps the codec entirely. `draw(_:zoomScale:in:)`
/// takes a `CGContext`, and a `CGImage` backed by a shared `MTLBuffer` can be
/// drawn straight into it: the bytes the compute kernel wrote are the bytes
/// Core Graphics reads.
///
/// The cost of the override is that `MKTileOverlayRenderer`'s own tile
/// bookkeeping goes with it — which tiles a `mapRect` covers, and when to ask
/// for them — so that is reimplemented here from the zoom scale.
public nonisolated final class TerrainTileOverlayRenderer: MKTileOverlayRenderer {

    private let terrainOverlay: TerrainTileOverlay

    /// Ready tiles and in-flight requests, keyed `z/x/y`.
    ///
    /// MapKit calls `canDraw` and `draw` from several background queues at
    /// once, so this is behind a lock rather than an actor: both of those are
    /// synchronous and cannot await.
    ///
    /// Every operation is a synchronous method rather than a bare lock/unlock
    /// pair, because the completion side runs inside a `Task` and taking a
    /// lock directly across an async context is not allowed — nor would it be
    /// safe, since a suspension could move the unlock to another thread.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: CGImage] = [:]
        private var inFlight: Set<String> = []
        /// Bumped by `reloadData()`; results from an earlier generation are
        /// dropped rather than drawn under settings that have moved on.
        private var generation = 0

        func image(for key: String) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return images[key]
        }

        /// Splits `paths` into those that can be drawn now and those that
        /// cannot, under one acquisition rather than one per tile.
        func partition(
            _ paths: [MKTileOverlayPath], key: (MKTileOverlayPath) -> String
        ) -> (ready: Bool, missing: [MKTileOverlayPath]) {
            lock.lock()
            defer { lock.unlock() }
            var ready = false
            var missing: [MKTileOverlayPath] = []
            for path in paths {
                if images[key(path)] != nil { ready = true } else { missing.append(path) }
            }
            return (ready, missing)
        }

        /// Claims a tile for loading, or returns `nil` if it is already
        /// in flight or already drawn.
        func beginLoad(_ key: String) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard images[key] == nil, !inFlight.contains(key) else { return nil }
            inFlight.insert(key)
            return generation
        }

        /// Records a finished load. Returns `true` if the result is still
        /// wanted — a reload since `generation` makes it stale.
        func finishLoad(_ key: String, image: CGImage?, generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            inFlight.remove(key)
            guard let image, generation == self.generation else { return false }
            images[key] = image
            return true
        }

        /// Drops everything and moves to a new generation.
        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            images.removeAll()
            inFlight.removeAll()
        }
    }
    private let store = Store()

    /// A weak handle to the renderer that survives the crossing into a
    /// detached task.
    ///
    /// `MKOverlayRenderer` is not `Sendable` and cannot be made so, but
    /// `setNeedsDisplayInMapRect:zoomScale:` is exactly the API MapKit
    /// documents for signalling from wherever the data arrived. Weak, so a
    /// renderer torn down mid-load — the overlay removed, the layer switched
    /// off — is not kept alive by a request it no longer has any use for.
    private struct WeakRenderer: @unchecked Sendable {
        weak var renderer: TerrainTileOverlayRenderer?
    }

    public init(overlay: TerrainTileOverlay) {
        self.terrainOverlay = overlay
        super.init(tileOverlay: overlay)
    }

    /// Discards every drawn tile and redraws.
    ///
    /// Called after a shading change. The provider still holds each tile's
    /// raster, so this re-shades from memory rather than refetching.
    public override func reloadData() {
        store.invalidate()
        setNeedsDisplay()
    }

    public override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let paths = tilePaths(in: mapRect, zoomScale: zoomScale)
        guard !paths.isEmpty else { return false }

        let (ready, missing) = store.partition(paths, key: Self.key)
        for path in missing { request(path, zoomScale: zoomScale) }
        // Drawing the tiles that are ready beats drawing nothing while one
        // straggler loads: a partially filled rect fills in as the rest land.
        return ready
    }

    public override func draw(
        _ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext
    ) {
        let paths = tilePaths(in: mapRect, zoomScale: zoomScale)
        guard !paths.isEmpty else { return }

        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        for path in paths {
            guard let image = store.image(for: Self.key(path)) else {
                request(path, zoomScale: zoomScale)
                continue
            }

            let rect = self.rect(for: TerrainTileOverlay.mapRect(for: path))
            // Core Graphics draws images from the bottom left; the overlay
            // context has y increasing downward, so each tile is flipped about
            // its own rect rather than the whole context being inverted.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + rect.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    /// Asks the provider for one tile, then invalidates just its rect.
    private func request(_ path: MKTileOverlayPath, zoomScale: MKZoomScale) {
        let key = Self.key(path)
        guard let generation = store.beginLoad(key) else { return }

        let provider = terrainOverlay.provider
        let region = TerrainTileOverlay.region(for: path)
        // MapKit asks for @2x tiles on retina, landing at 512px.
        let pixels = Int(terrainOverlay.tileSize.width * max(path.contentScaleFactor, 1))

        let handle = WeakRenderer(renderer: self)
        Task { [store] in
            let image = await provider.tileImage(
                x: path.x, y: path.y, z: path.z, region: region, pixels: pixels
            )
            guard store.finishLoad(key, image: image, generation: generation) else { return }
            handle.renderer?.setNeedsDisplay(
                TerrainTileOverlay.mapRect(for: path), zoomScale: zoomScale
            )
        }
    }

    private nonisolated static func key(_ path: MKTileOverlayPath) -> String {
        "\(path.z)/\(path.x)/\(path.y)"
    }

    /// Every tile of the overlay's grid that `mapRect` touches.
    private func tilePaths(in mapRect: MKMapRect, zoomScale: MKZoomScale) -> [MKTileOverlayPath] {
        let z = Self.zoomLevel(
            for: zoomScale,
            tileSize: terrainOverlay.tileSize.width,
            clampedTo: terrainOverlay.minimumZ...terrainOverlay.maximumZ
        )
        let count = Int(pow(2.0, Double(z)))
        let side = MKMapSize.world.width / Double(count)

        // Half-open in projected space: a rect ending exactly on a tile edge
        // covers the tile before it, not the one after.
        let minX = max(Int(floor(mapRect.minX / side)), 0)
        let minY = max(Int(floor(mapRect.minY / side)), 0)
        let maxX = min(Int(ceil(mapRect.maxX / side)) - 1, count - 1)
        let maxY = min(Int(ceil(mapRect.maxY / side)) - 1, count - 1)
        guard minX <= maxX, minY <= maxY else { return [] }

        let scale = contentScaleFactor
        var paths: [MKTileOverlayPath] = []
        paths.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                paths.append(
                    MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: scale)
                )
            }
        }
        return paths
    }

    /// The tile zoom level a zoom scale corresponds to.
    ///
    /// `MKZoomScale` is screen points per map point, so a tile grid `n` levels
    /// deep than the world tile is drawn at scale `2^-n` times the tile's own
    /// pixel size. Rounding rather than truncating picks the level whose tiles
    /// are closest to 1:1 on screen, which is what avoids requesting a level
    /// finer than the display can show.
    private nonisolated static func zoomLevel(
        for zoomScale: MKZoomScale, tileSize: CGFloat, clampedTo bounds: ClosedRange<Int>
    ) -> Int {
        let tilesAcrossWorld = MKMapSize.world.width / Double(max(tileSize, 1))
        let worldLevel = log2(tilesAcrossWorld)
        let scale = Double(zoomScale)
        let offset = scale > 0 ? (log2(scale) + 0.5).rounded(.down) : 0
        let level = Int((worldLevel + offset).rounded())
        return min(max(level, bounds.lowerBound), bounds.upperBound)
    }
}
