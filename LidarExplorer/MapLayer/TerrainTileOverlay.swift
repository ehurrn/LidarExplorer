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

/// A thalweg vertex with the water-surface elevation sampled beneath it.
public nonisolated struct ThalwegPoint: Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var waterSurface: Float

    public init(latitude: Double, longitude: Double, waterSurface: Float) {
        self.latitude = latitude
        self.longitude = longitude
        self.waterSurface = waterSurface
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

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
    public var microTopographyOptions: MicroTopographyOptions = MicroTopographyOptions()
    /// Sun altitude for the grazing-light styles, `.rakingLight` and
    /// `.directionalOcclusion`, degrees; grazing light sits at 5–15.
    public var rakingAltitudeDegrees: Double = 10
    public var showsHabitationMask = false
    /// 0...1 strength of sky-view ambient occlusion over micro styles.
    public var skyViewShading: Float = 0
    /// River centreline for `.relativeElevation`. Empty detrends against a flat
    /// water plane at the visible minimum elevation.
    public var thalweg: [ThalwegPoint] = []

    public init() {}

    /// The options `product` runs with under these settings: the tuned options, with the low-sun products
    /// taking the dock's sun direction and Grazing Sun Altitude.
    public func analysisOptions(for product: MicroTopographyProduct) -> MicroTopographyOptions {
        var options = microTopographyOptions
        if product == .rakingLight {
            options.sunAzimuthDegrees = Float(azimuthDegrees)
            options.sunAltitudeDegrees = Float(rakingAltitudeDegrees)
        } else if product == .directionalOcclusion {
            options.directionalOcclusionAzimuthDegrees = Float(azimuthDegrees)
            options.directionalOcclusionAltitudeDegrees = Float(rakingAltitudeDegrees)
        }
        return options
    }
}

/// A viewshed with the geographic extent of the raster it was computed over,
/// so the mask can be placed on the map pixel for pixel.
public nonisolated struct ProviderViewshed: Sendable {
    public let result: ViewshedResult
    public let region: GeoRegion
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

    /// Deepest zoom served from 3DEP. With COG pyramid overviews, z16 (level 2, ~4m)
    /// and z17 (level 1, ~2m) stream directly via ranged GETs, while z18+ streams native 1m (level 0).
    /// Below z16, terrarium is served (native to z15, upsampled above).
    public nonisolated static let nativeDetailZ = 16

    /// What `init(elevation: nil)` streams z16+ tiles from.
    public nonisolated static let defaultElevationSourceDescription = "COG → ImageServer"

    /// Human-readable source descriptor for a tile at zoom level `z`.
    public nonisolated static func sourceName(forZ z: Int) -> String {
        if z < nativeDetailZ {
            return "terrarium"
        } else if z == 16 {
            return "3DEP 4m (Overview)"
        } else if z == 17 {
            return "3DEP 2m (Overview)"
        } else {
            return "3DEP 1m"
        }
    }

    private let elevation: any ElevationProviding
    private let terrarium: TerrariumTileService
    private let raster: RasterCompute
    private let microPipeline: MetalTerrainPipelineActor
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
    /// Budget for everything cached tiles hold: padded rasters, any derivative
    /// planes computed for the CPU fallback, and shaded bitmaps. The GPU surface
    /// pool and the COG tile cache are capped separately.
    public nonisolated static let maxMemoryCacheBytes: Int = 256 * 1024 * 1024
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

    /// Tiles whose shading read a neighbour that has since arrived; drained by
    /// the renderer, which redraws them in the background.
    private var staleTiles: Set<String> = []

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
        /// Derivative planes, computed only when the CPU fallback needs them:
        /// every GPU path shades straight from elevation.
        var products: ReliefProducts?
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
            products: ReliefProducts? = nil,
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

        /// Bytes this entry holds: the padded raster, any derivative planes, and
        /// a shaded bitmap.
        var byteCount: Int {
            let plane = grid.samples.count * MemoryLayout<Float>.stride
            let planes = 1 + (products.map { 3 + ($0.normalX == nil ? 0 : 3) } ?? 0)
            return plane * planes + (rendered.map { $0.bytesPerRow * $0.height } ?? 0)
        }
    }

    public init(
        elevation: (any ElevationProviding)? = nil,
        terrarium: TerrariumTileService? = nil,
        raster: RasterCompute? = nil,
        microPipeline: MetalTerrainPipelineActor? = nil,
        report: (@Sendable (TileEvent) -> Void)? = nil,
        gridCache: TileDiskCache? = nil
    ) {
        // Native 1 m COGs first (a few ranged GETs, ~1 s cold); the ImageServer's
        // seamless mosaic answers wherever no single COG covers the tile.
        self.elevation = elevation ?? FallbackElevationProvider(
            primary: ElevationTileCoordinator.shared, fallback: USGS3DEPService())
        self.terrarium = terrarium ?? TerrariumTileService()
        self.raster = raster ?? RasterCompute()
        self.microPipeline = microPipeline ?? .shared
        self.report = report
        self.gridCache = gridCache ?? TileDiskCache(
            directory: Self.gridCacheDirectory,
            maxDiskBytes: Self.gridCacheBytes,
            targetDiskBytes: Self.gridCacheBytes * 4 / 5
        )

        // Trim under memory pressure to avoid Jetsam kills, sparing what is on
        // screen. The notification is delivered on any thread; we bounce into
        // the actor to mutate cache safely.
        #if canImport(UIKit)
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                await self?.handleMemoryWarning()
            }
        }
        #endif
    }

    /// Trims memory when the system asks for it back, sparing what is on screen.
    ///
    /// `visibleKeys` names the tiles being shown. Shaded bitmaps outside it go first and entirely: they
    /// are the largest thing held per tile and the cheapest to rebuild. The cached viewshed mosaic goes
    /// too, and the tile cache is halved, oldest first, without ever losing a visible tile. Idle Metal
    /// pool memory is purged last, because the buffer behind a shaded bitmap only becomes idle once that
    /// bitmap has been released.
    ///
    /// Everything dropped is rebuilt on demand from what remains (a bitmap from its raster, a raster from
    /// disk), so a pruned tile costs a re-render, not a blank. With no visible keys, every bitmap goes.
    public func handleMemoryPressure(visibleKeys: Set<String>) async {
        Log.engine.notice("OS memory warning: purging idle pools and trimming tile caches")
        for key in renderedOrder where !visibleKeys.contains(key) { cache[key]?.rendered = nil }
        renderedOrder.removeAll { !visibleKeys.contains($0) }
        viewshedMosaicCache = nil

        let target = cache.count / 2
        var index = 0
        while cacheOrder.count > target, index < cacheOrder.count {
            let key = cacheOrder[index]
            if visibleKeys.contains(key) {
                index += 1
            } else {
                cacheOrder.remove(at: index)
                cache.removeValue(forKey: key)
            }
        }
        await microPipeline.purgeIdlePools()
    }

    /// Where to ask which tiles are on screen; registered by the renderer that is showing them.
    private var visibleKeysSource: (@Sendable () -> Set<String>)?

    public func setVisibleKeysSource(_ source: (@Sendable () -> Set<String>)?) {
        visibleKeysSource = source
    }

    /// The system's memory warning: ``handleMemoryPressure(visibleKeys:)`` with whatever the registered
    /// source says is on screen, or with nothing when none is registered, which drops every bitmap.
    func handleMemoryWarning() async {
        await handleMemoryPressure(visibleKeys: visibleKeysSource?() ?? [])
    }

    // Diagnostics and tests: what the caches hold right now.
    func renderedTileKeys() -> Set<String> { Set(cache.filter { $0.value.rendered != nil }.keys) }
    func cachedTileKeys() -> Set<String> { Set(cache.keys) }
    func holdsViewshedMosaic() -> Bool { viewshedMosaicCache != nil }

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
        staleTiles.removeAll()
        return true
    }

    public func currentSettings() -> TerrainStyleSettings { settings }

    /// Tiles whose shading read a neighbour that has since arrived. The renderer
    /// redraws these in the background, keeping the old image until then.
    public func takeStaleTiles() -> [String] {
        defer { staleTiles.removeAll() }
        return Array(staleTiles)
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
                backend: cache[key]?.products?.backend ?? .gpu
            ))
            return existing
        }

        // A tile culled while its raster was in flight stops here, after the
        // raster is cached and before any shading. The fetch is already paid
        // for and answers every setting, so it is kept; the GPU work it would
        // feed is what a tile off the edge of the screen has no use for.
        guard !Task.isCancelled else {
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName, outcome: .cancelled,
                duration: Date().timeIntervalSince(started)
            ))
            return nil
        }

        // Snapshot the settings once, after the fetch, and derive everything
        // downstream from it. `loadTile` awaits network I/O, so `settings` can
        // change underneath a tile in flight, and a tile has to be shaded with
        // one coherent set of values rather than a mixture.
        let currentSettings = settings

        guard let image = await shadeToImage(cached, x: x, y: y, z: z, settings: currentSettings) else {
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
            enforceMemoryBudget()
        }

        report?(TileEvent(
            z: z, x: x, y: y, source: sourceName,
            outcome: wasCached ? .cached : .fetched,
            duration: Date().timeIntervalSince(started),
            resolution: cached.grid.groundSampleDistance,
            byteCount: image.bytesPerRow * image.height,
            backend: cache[key]?.products?.backend ?? .gpu
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
        _ tile: CachedTile, x: Int, y: Int, z: Int, settings: TerrainStyleSettings
    ) async -> CGImage? {
        switch settings.style {
        case .topographicOpenness: return await opennessImage(for: tile, settings: settings)
        // Keyed on the product, not a list of styles that goes stale: the fused
        // kernel has no case for these and would shade them as raw elevation.
        case let style where style.microTopographyProduct != nil:
            if let image = await microPipelineImage(for: tile, x: x, y: y, z: z, settings: settings) { return image }
            // Only RRIM has an older route when the micro pipeline is unavailable.
            return style == .rrim ? await rrimImage(for: tile) : nil
        default: break
        }

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

        guard let products = await ensureProducts(for: "\(z)/\(x)/\(y)", tile: tile) else { return nil }
        return Self.cpuRender(
            tile.grid, products: products, margin: tile.margin, settings: settings
        )
    }

    /// Derivative planes for a tile, computed on first need and kept.
    ///
    /// Only the CPU fallback reads them: computing seven planes for every tile on
    /// load held about seven times each raster in memory for nothing.
    private func ensureProducts(for key: String, tile: CachedTile) async -> ReliefProducts? {
        if let existing = cache[key]?.products ?? tile.products { return existing }
        let computed = await raster.reliefProducts(for: tile.grid)
        if cache[key] != nil {
            cache[key]?.products = computed
            enforceMemoryBudget()
        }
        return computed
    }

    /// RRIM, cropped from the padded raster down to the tile's display area.
    ///
    /// `rrimImage` (like `opennessProducts`) has no notion of a display
    /// margin -- it composites the whole grid it is given. This crops the
    /// result the same `tile.margin` pixels the fused kernel discards
    /// internally, so the skirt does not show up as an extra border.
    ///
    /// Known limitation: openness's search radius (15 cells by default) is
    /// larger than a tile's fetch margin (a handful of cells, sized for the
    /// Horn kernel's 3x3 window). Cells within roughly one radius of a tile
    /// edge see less real neighbouring terrain than a tile-agnostic query
    /// would, and read softer than they should -- a visible seam at coarser
    /// zooms. Fixing that means fetching a radius-sized skirt specifically
    /// for these two styles, which the tile cache does not do today.
    private func rrimImage(for tile: CachedTile) async -> CGImage? {
        guard let bitmap = await raster.rrimImage(for: tile.grid), let full = bitmap.makeImage() else {
            return nil
        }
        let margin = tile.margin
        guard margin > 0 else { return full }
        let destWidth = tile.grid.width - margin * 2
        let destHeight = tile.grid.height - margin * 2
        guard destWidth > 0, destHeight > 0 else { return full }
        return full.cropping(to: CGRect(x: margin, y: margin, width: destWidth, height: destHeight))
    }

    /// Differential topographic openness, coloured and cropped to the tile's
    /// display area. Same skirt caveat as ``rrimImage(for:)``.
    private func opennessImage(for tile: CachedTile, settings: TerrainStyleSettings) async -> CGImage? {
        guard let openness = await raster.opennessProducts(for: tile.grid) else { return nil }
        let margin = tile.margin
        let paddedWidth = tile.grid.width
        let destWidth = paddedWidth - margin * 2
        let destHeight = tile.grid.height - margin * 2
        guard destWidth > 0, destHeight > 0 else { return nil }

        var differential = [Float](repeating: 0, count: destWidth * destHeight)
        for y in 0..<destHeight {
            let srcRow = (y + margin) * paddedWidth
            let dstRow = y * destWidth
            for x in 0..<destWidth {
                let srcIdx = srcRow + x + margin
                let pos = openness.positive.pointer[srcIdx]
                let neg = openness.negative.pointer[srcIdx]
                differential[dstRow + x] = (pos.isNaN || neg.isNaN) ? .nan : (pos - neg) * 0.5
            }
        }
        return ReliefRenderer.image(
            from: differential, width: destWidth, height: destHeight,
            style: .topographicOpenness, range: Self.displayRange(for: settings)
        )
    }

    /// Micro-topography product rendered through ``MetalTerrainPipelineActor``.
    ///
    /// The tile and its cached neighbours are stitched into an analysis raster
    /// whose skirt covers only this product's neighbourhood, box-decimated to the
    /// source's native spacing -- an oversampled 3DEP tile gains nothing from
    /// 0.12 m cells but pays for them per ray and per tap. Stitching runs off the
    /// provider actor into page-aligned storage the GPU adopts without a copy,
    /// and the composite returns to display resolution when overlays are drawn.
    private func microPipelineImage(
        for tile: CachedTile, x: Int, y: Int, z: Int, settings: TerrainStyleSettings
    ) async -> CGImage? {
        guard let product = settings.style.microTopographyProduct else { return nil }
        guard !Task.isCancelled else { return nil }

        // Forward contour overlays when the user has them enabled.
        var overlays = CompositeOverlays()
        if settings.contourInterval != .off {
            overlays.contourIntervalMeters = settings.contourInterval.meters
            overlays.indexIntervalMeters = settings.contourInterval.indexIntervalMeters
        }
        overlays.habitationOpacity = settings.showsHabitationMask ? 0.75 : 0
        overlays.skyViewStrength = settings.skyViewShading
        // The low-sun products share the dock's sun direction and Grazing Sun Altitude.
        let options = settings.analysisOptions(for: product)

        let dest = tile.grid.width - tile.margin * 2
        let mpp = tile.grid.groundSampleDistance
        let factor = AnalysisRasterBuilder.decimation(
            tileGroundSampleDistance: mpp,
            nativeGroundSampleDistance: Self.nativeGroundSampleDistance(source: tile.source, gridSpacing: mpp),
            destinationPixels: dest)
        let skirt = AnalysisRasterBuilder.skirtPixels(
            radiusMeters: Self.neighbourhoodRadius(product: product, options: options, overlays: overlays),
            groundSampleDistance: mpp, decimation: factor, destinationPixels: dest)
        var collected: [SIMD2<Int32>: AnalysisTileSource] = [:]
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                if let n = cache["\(z)/\(x + dx)/\(y + dy)"] {
                    collected[SIMD2(Int32(dx), Int32(dy))] = AnalysisTileSource(
                        samples: n.grid.samples, paddedWidth: n.grid.width, margin: n.margin)
                }
            }
        }
        let neighbours = collected
        let center = AnalysisTileSource(samples: tile.grid.samples, paddedWidth: tile.grid.width, margin: tile.margin)
        let cellX = Float(tile.grid.metersPerColumn), cellY = Float(tile.grid.metersPerRow)
        let outDimension = (dest + 2 * skirt) / factor
        // Last exit before the surface lease and the stitching pass — the two
        // most expensive things a stranded tile could still go on to do.
        guard !Task.isCancelled else { return nil }
        let lease = await microPipeline.leasedSurface(
            for: .r32Float,
            dimensions: SIMD2(Int32(outDimension), Int32(outDimension))
        )
        // Built off the provider actor: tile fetches and other tiles keep flowing meanwhile.
        guard let analysis = await Task.detached(priority: .userInitiated, operation: {
            AnalysisRasterBuilder.build(
                center: center,
                skirt: skirt,
                decimation: factor,
                cellSizeX: cellX,
                cellSizeY: cellY,
                neighbours: neighbours,
                lease: lease
            )
        }).value else { return nil }

        // The actor declines REM without a thalweg; with none drawn, detrend
        // against a flat water plane at the visible (or tile) minimum.
        let thalweg = product == .relativeElevation
            ? Self.thalwegVertices(
                settings.thalweg,
                fallbackSurface: settings.elevationRange?.lowerBound ?? tile.elevationLow,
                tileBounds: tile.displayRegion.mercatorBounds,
                destinationPixels: dest, skirt: skirt,
                cellSizeX: cellX, cellSizeY: cellY, decimation: factor)
            : []
        guard let result = await microPipeline.render(
            product, raster: analysis.raster, window: analysis.window, options: options,
            thalweg: thalweg, overlays: overlays, outputScale: overlays.isEmpty ? 1 : factor
        ) else { return nil }
        return result.display.makeImage()
    }

    /// How far a product (and its overlays) reads beyond each cell, in metres.
    nonisolated static func neighbourhoodRadius(
        product: MicroTopographyProduct, options: MicroTopographyOptions, overlays: CompositeOverlays
    ) -> Float {
        var radius: Float
        switch product {
        case .localRelief: radius = options.lrmRadiusMeters
        case .redRelief, .positiveOpenness, .negativeOpenness: radius = options.opennessRadiusMeters
        case .skyView: radius = options.svfRadiusMeters
        case .habitation: radius = options.habitationRadiusMeters
        case .directionalOcclusion: radius = options.directionalOcclusionDistanceMeters
        case .differenceOfGaussians: radius = options.dogSigma2Meters * 3
        case .vectorRuggedness: radius = 5
        case .rakingLight, .relativeElevation, .curvature: radius = 0
        }
        if overlays.habitationOpacity > 0 { radius = max(radius, options.habitationRadiusMeters) }
        if overlays.skyViewStrength > 0 { radius = max(radius, options.svfRadiusMeters) }
        return radius
    }

    /// 3DEP map tiles are resampled from 1 m lidar; every other source is native.
    nonisolated static func nativeGroundSampleDistance(source: String, gridSpacing: Double) -> Double {
        source.hasPrefix("3DEP") && !source.contains("fallback") ? max(gridSpacing, 1.0) : gridSpacing
    }

    /// Thalweg vertices in a stitched analysis raster's frame (x east from column
    /// 0, y south from row 0, metres). With no drawn thalweg, one vertex at
    /// `fallbackSurface` detrends against a flat water plane.
    nonisolated static func thalwegVertices(
        _ points: [ThalwegPoint],
        fallbackSurface: Float,
        tileBounds m: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        destinationPixels: Int,
        skirt: Int,
        cellSizeX: Float,
        cellSizeY: Float,
        decimation: Int = 1
    ) -> [ThalwegVertex] {
        guard !points.isEmpty else {
            return fallbackSurface.isFinite ? [ThalwegVertex(x: 0, y: 0, waterSurface: fallbackSurface)] : []
        }
        let pixelX = (m.maxX - m.minX) / Double(destinationPixels)
        let pixelY = (m.maxY - m.minY) / Double(destinationPixels)
        return points.map { point in
            let p = GeoRegion.toMercatorMeters(point.coordinate)
            // Decimated cell centres sit half a box in from their first source pixel.
            let boxOffset = Double(decimation - 1) / 2
            let column = (p.x - m.minX) / pixelX + Double(skirt) - 0.5 - boxOffset
            let row = (m.maxY - p.y) / pixelY + Double(skirt) - 0.5 - boxOffset
            return ThalwegVertex(x: Float(column) * cellSizeX, y: Float(row) * cellSizeY, waterSurface: point.waterSurface)
        }
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
        // Differential openness (positive minus negative), degrees either
        // side of "flat". Fixed rather than per-tile for the same reason as
        // the other non-elevation styles: a continuous scale across tiles.
        case .topographicOpenness: -20...20
        // Unused: RRIM composites its own fixed colour mapping and never
        // reaches the palette-driven range logic this feeds.
        case .rrim: 0...1
        case .localRelief: (-3)...3
        case .skyView: 0...1
        case .rakingLight: 0...1
        case .relativeElevation: (-5)...10
        case .curvature: (-0.05)...0.05
        case .directionalOcclusion: 0...1
        case .positiveOpenness: 60...100
        case .negativeOpenness: 60...100
        case .vectorRuggedness: 0...0.015
        case .differenceOfGaussians: (-2)...2
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
            return CachedTile(
                grid: decoded.grid,
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

    /// Wraps a fetched raster, skirt and all, for the cache.
    ///
    /// Nothing is cropped and nothing is derived: the raster stays padded,
    /// `margin` travels with it, and derivative planes wait for the CPU fallback
    /// to ask for them (see ``ensureProducts(for:tile:)``).
    private func shade(_ fetched: FetchedRaster, margin: Int) async -> CachedTile? {
        guard !Task.isCancelled else { return nil }
        return CachedTile(
            grid: fetched.padded,
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
            return FetchedRaster(padded: grid, source: Self.sourceName(forZ: z))
        }

        // If the task was cancelled (user panned away), don't waste
        // resources fetching a fallback tile for a discarded viewport.
        guard !Task.isCancelled else { return nil }

        // Graceful degradation: when 3DEP fails (network timeout, error,
        // or void/outside coverage), fall back to upsampling from the
        // Terrarium ancestor at maximumZ so MapKit doesn't leave a hole.
        return await fetchTerrariumRaster(
            x: x, y: y, z: z, region: region, margin: margin,
            source: "\(Self.sourceName(forZ: z)) (fallback to terrarium)"
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

    /// Snaps a hand-drawn river polyline to the local channel floor with a monotonic water surface.
    public func thalweg(from drawn: [CLLocationCoordinate2D]) -> [ThalwegPoint] {
        ThalwegBuilder.build(drawn: drawn) { self.elevation(at: $0) }
    }

    /// Inspects spot elevation, slope, and aspect at a coordinate using cached tiles.
    /// Prefers the finest available tile. Evaluates slope and aspect using the 3x3 Horn stencil.
    public func inspectSpot(at coord: CLLocationCoordinate2D) async -> SpotInspection? {
        var best: (resolution: Double, spot: SpotInspection)?
        for entry in cache.values {
            guard entry.displayRegion.contains(coord) else { continue }
            guard let elev = entry.grid.elevation(at: coord) else { continue }
            let (col, row) = entry.grid.gridCoordinates(for: coord)
            let c = min(max(Int(round(col)), 0), entry.grid.width - 1)
            let r = min(max(Int(round(row)), 0), entry.grid.height - 1)

            let (slope, aspect) = Self.hornSlopeAspect(entry.grid, x: c, y: r)

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

    /// Horn slope and aspect at one cell -- the arithmetic of `horn_slope_aspect`
    /// in `TerrainKernels.metal`. NaN at the raster edge or beside a void.
    nonisolated static func hornSlopeAspect(_ grid: ElevationGrid, x: Int, y: Int) -> (slope: Float, aspect: Float) {
        guard x >= 1, y >= 1, x + 1 < grid.width, y + 1 < grid.height else { return (.nan, .nan) }
        let w = grid.width, z = grid.samples
        let a = z[(y - 1) * w + x - 1], b = z[(y - 1) * w + x], c = z[(y - 1) * w + x + 1]
        let d = z[y * w + x - 1], e = z[y * w + x], f = z[y * w + x + 1]
        let g = z[(y + 1) * w + x - 1], h = z[(y + 1) * w + x], i = z[(y + 1) * w + x + 1]
        guard ![a, b, c, d, e, f, g, h, i].contains(where: \.isNaN) else { return (.nan, .nan) }
        let dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) / Float(8 * grid.metersPerColumn)
        let dzdy = ((g + 2 * h + i) - (a + 2 * b + c)) / Float(8 * grid.metersPerRow)
        let slope = atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi
        guard dzdx != 0 || dzdy != 0 else { return (slope, 0) }
        var aspect = 90 - atan2(dzdy, -dzdx) * 180 / .pi
        if aspect < 0 { aspect += 360 }
        if aspect >= 360 { aspect -= 360 }
        return (slope, aspect)
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

            // Bilinear, not nearest-neighbour: a transect walks a continuous
            // line across the raster, and snapping each step to its nearest
            // cell puts visible staircase steps in the plotted profile,
            // especially where the tile's resolution is coarse relative to
            // the sample spacing.
            var best: (resolution: Double, value: Float)?
            for entry in cache.values {
                guard entry.displayRegion.contains(coord),
                      let value = entry.grid.interpolatedElevation(at: coord)
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

    /// Assembles cached terrain tiles covering the start and end coordinates into an ElevationTransect field.
    public func transectMosaic(
        around start: CLLocationCoordinate2D, and end: CLLocationCoordinate2D, paddingMeters: Double = 20
    ) -> TileMosaicField {
        let bounds = GeoRegion(
            minLatitude: min(start.latitude, end.latitude), maxLatitude: max(start.latitude, end.latitude),
            minLongitude: min(start.longitude, end.longitude), maxLongitude: max(start.longitude, end.longitude)
        ).expanded(byMeters: paddingMeters)
        let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
            let r = entry.displayRegion
            guard r.minLatitude <= bounds.maxLatitude, r.maxLatitude >= bounds.minLatitude,
                  r.minLongitude <= bounds.maxLongitude, r.maxLongitude >= bounds.minLongitude else { return nil }
            return TileMosaicField.Layer(grid: entry.grid, bounds: r)
        }
        let origin = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2,
                                            longitude: (start.longitude + end.longitude) / 2)
        return TileMosaicField(origin: origin, layers: layers)
    }

    /// Produces a full micro-topographic transect analysis with curvature, slopes, and detected earthwork signatures.
    public func analyzeTransect(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        stepDistance: Float = 0.5,
        parameters: TransectSignatureParameters = TransectSignatureParameters()
    ) -> TransectAnalysis? {
        let mosaic = transectMosaic(around: start, and: end)
        let engine = ElevationTransectEngine(field: mosaic, parameters: parameters)
        let analysis = engine.analyze(from: start, to: end, stepDistance: stepDistance)
        return analysis.samples.isEmpty ? nil : analysis
    }

    /// Produces a fast decimated profile (max 256 samples) for 120 Hz interactive touch/pencil dragging.
    public func previewTransect(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        maxPoints: Int = 256
    ) -> [ProfileSample] {
        let mosaic = transectMosaic(around: start, and: end)
        let engine = ElevationTransectEngine(field: mosaic)
        return engine.previewProfile(from: start, to: end, maxPoints: maxPoints)
    }

    /// The last mosaic, reused while the observer stays in its inner quarter (a dragged pin).
    private var viewshedMosaicCache: (mosaic: MercatorMosaic, center: CLLocationCoordinate2D, radius: Float)?

    /// Computes a radial-sweep GPU viewshed from an observer coordinate across cached terrain tiles.
    public func viewshed(
        at observer: CLLocationCoordinate2D,
        eyeHeight: Float = 2.0,
        targetHeight: Float = 0.5,
        maxRadiusMeters: Float = 2500
    ) async -> ProviderViewshed? {
        let mosaic: MercatorMosaic
        if let cached = viewshedMosaicCache, cached.radius == maxRadiusMeters,
           Geodesy.distance(from: cached.center, to: observer) < Double(maxRadiusMeters) * 0.25 {
            mosaic = cached.mosaic
        } else {
            let reach = GeoRegion(center: observer, latitudeSpan: 0, longitudeSpan: 0).expanded(byMeters: Double(maxRadiusMeters) * 1.3)
            let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
                let r = entry.displayRegion
                guard r.minLatitude <= reach.maxLatitude, r.maxLatitude >= reach.minLatitude,
                      r.minLongitude <= reach.maxLongitude, r.maxLongitude >= reach.minLongitude else { return nil }
                return TileMosaicField.Layer(grid: entry.grid, bounds: r)
            }
            guard let finest = layers.map(\.grid.groundSampleDistance).min() else { return nil }
            let radius = Double(maxRadiusMeters)
            guard let built = await Task.detached(priority: .userInitiated, operation: {
                MercatorMosaicBuilder.build(center: observer, radiusMeters: radius, finestGroundSampleDistance: finest, layers: layers)
            }).value else { return nil }
            viewshedMosaicCache = (built, observer, maxRadiusMeters)
            mosaic = built
        }
        let p = mosaic.pixel(for: observer)
        guard let result = await microPipeline.viewshed(
            raster: mosaic.raster,
            observerColumn: p.x,
            observerRow: p.y,
            eyeHeight: eyeHeight,
            targetHeight: targetHeight,
            maxRadiusMeters: maxRadiusMeters
        ) else { return nil }
        return ProviderViewshed(result: result, region: mosaic.region)
    }

    /// Aggregates currently rendered DEM tiles covering `region` into a single Float32 `ElevationGrid`,
    /// node-registered so ``GeoTIFFWriter`` places it on the ground exactly.
    public func activeGrid(covering region: MKCoordinateRegion) async -> ElevationGrid? {
        let geo = GeoRegion(
            center: region.center,
            latitudeSpan: region.span.latitudeDelta,
            longitudeSpan: region.span.longitudeDelta
        )
        guard geo.minLatitude.isFinite, geo.maxLatitude.isFinite,
              geo.minLongitude.isFinite, geo.maxLongitude.isFinite else {
            return nil
        }
        let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
            let r = entry.displayRegion
            guard r.minLatitude <= geo.maxLatitude, r.maxLatitude >= geo.minLatitude,
                  r.minLongitude <= geo.maxLongitude, r.maxLongitude >= geo.minLongitude else { return nil }
            return TileMosaicField.Layer(grid: entry.grid, bounds: r)
        }
        guard !layers.isEmpty else { return nil }
        guard let finest = layers.map(\.grid.groundSampleDistance).min() else { return nil }
        let radius = max(geo.widthMeters, geo.heightMeters) * 0.5
        // Finite bounds can still overflow to an infinite radius in metres, which the builder cannot size.
        guard radius > 0, radius.isFinite else { return nil }
        guard let built = await Task.detached(priority: .userInitiated, operation: {
            MercatorMosaicBuilder.build(
                center: region.center,
                radiusMeters: radius,
                finestGroundSampleDistance: finest,
                maximumSize: 2048,
                layers: layers
            )
        }).value else { return nil }

        let sampleCount = built.size * built.size
        let samples = Array(UnsafeBufferPointer(
            start: built.storage.pointer.bindMemory(to: Float.self, capacity: sampleCount),
            count: sampleCount
        ))
        // Node-registered: the region spans the mosaic's cell centres, not its outer edge.
        return ElevationGrid(width: built.size, height: built.size, samples: samples, region: built.nodeRegisteredRegion)
    }

    /// `product` computed over `region` from the cached tiles, as a float raster a GIS can use: the viewport's
    /// analytical layer, ready for ``GeoTIFFWriter``.
    ///
    /// Kernels read beyond each cell, so the mosaic is built over `region` padded by the product's own
    /// neighbourhood radius (as the tile path pads each tile with a skirt) and only the requested window is
    /// rendered: values along the edge see the ground they would inside a tile. Cells are at least 1 m, the
    /// mosaic builder's floor and 3DEP's native resolution, and coarser when `region` would need more than
    /// `destinationSize` cells on its longer side.
    ///
    /// The grid is node-registered like every ``ElevationGrid``: its region spans the window's cell centres,
    /// so the exported GeoTIFF sits on the ground and not half a cell off it.
    ///
    /// Returns `nil` when no cached tile covers `region`, a bound is not finite, or the pipeline is
    /// unavailable, and for `.relativeElevation`, which needs a river thalweg this call cannot take.
    public func analyticalRaster(
        for region: GeoRegion,
        product: MicroTopographyProduct,
        options: MicroTopographyOptions = MicroTopographyOptions(),
        destinationSize: Int = 1024
    ) async -> ElevationGrid? {
        guard region.minLatitude.isFinite, region.maxLatitude.isFinite,
              region.minLongitude.isFinite, region.maxLongitude.isFinite, destinationSize >= 4 else { return nil }
        let longestSide = max(region.widthMeters, region.heightMeters)
        let skirt = Double(Self.neighbourhoodRadius(product: product, options: options, overlays: CompositeOverlays())) + 2
        guard longestSide.isFinite, longestSide > 0, skirt.isFinite, skirt >= 0 else { return nil }

        let reach = region.expanded(byMeters: skirt)
        let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
            let r = entry.displayRegion
            guard r.minLatitude <= reach.maxLatitude, r.maxLatitude >= reach.minLatitude,
                  r.minLongitude <= reach.maxLongitude, r.maxLongitude >= reach.minLongitude else { return nil }
            return TileMosaicField.Layer(grid: entry.grid, bounds: r)
        }
        let coversRegion = layers.contains { layer in
            let r = layer.bounds
            return r.minLatitude <= region.maxLatitude && r.maxLatitude >= region.minLatitude
                && r.minLongitude <= region.maxLongitude && r.maxLongitude >= region.minLongitude
        }
        guard coversRegion, let finest = layers.map(\.grid.groundSampleDistance).min() else { return nil }

        let radius = max(reach.widthMeters, reach.heightMeters) / 2
        let cellFloor = max(finest, longestSide / Double(destinationSize))
        let cell = max(MercatorMosaicBuilder.tieredCellSize(radiusMeters: radius), cellFloor)
        let skirtCells = Int(min((skirt / cell).rounded(.up), 4096))
        let maximumSize = min(destinationSize + 2 * skirtCells + 8, 4096)
        let center = reach.center
        guard let mosaic = await Task.detached(priority: .userInitiated, operation: {
            MercatorMosaicBuilder.build(
                center: center, radiusMeters: radius, finestGroundSampleDistance: cellFloor,
                maximumSize: maximumSize, layers: layers)
        }).value else { return nil }

        // The requested region's cells in the mosaic, rounded outward so the window covers it.
        let pixel = (mosaic.maxX - mosaic.minX) / Double(mosaic.size)
        let wanted = region.mercatorBounds
        func cells(_ value: Double) -> Int? { value.isFinite ? Int(min(max(value, 0), Double(mosaic.size))) : nil }
        guard pixel.isFinite, pixel > 0,
              let x0 = cells(((wanted.minX - mosaic.minX) / pixel).rounded(.down)),
              let x1 = cells(((wanted.maxX - mosaic.minX) / pixel).rounded(.up)),
              let y0 = cells(((mosaic.maxY - wanted.maxY) / pixel).rounded(.down)),
              let y1 = cells(((mosaic.maxY - wanted.minY) / pixel).rounded(.up)),
              x0 < x1, y0 < y1 else { return nil }

        guard let result = await microPipeline.render(
            product, raster: mosaic.raster,
            window: DestinationWindow(originX: x0, originY: y0, width: x1 - x0, height: y1 - y0),
            options: options
        ) else { return nil }
        // The product plane is exactly the window; anything else would misplace every cell.
        let plane = result.scalar
        guard plane.width == x1 - x0, plane.height == y1 - y0 else { return nil }

        return ElevationGrid(
            width: plane.width, height: plane.height, samples: plane.values(),
            region: mosaic.nodeRegisteredRegion(columns: x0..<x1, rows: y0..<y1))
    }

    /// Drops cached imagery. Derivatives are kept — only shading changed.
    public func clear() {
        cache.removeAll()
        cacheOrder.removeAll()
        renderedOrder.removeAll()
        viewshedMosaicCache = nil
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
            case .topographicOpenness, .rrim, .localRelief, .skyView, .rakingLight, .relativeElevation, .curvature,
                 .directionalOcclusion, .positiveOpenness, .negativeOpenness, .vectorRuggedness, .differenceOfGaussians:
                // No CPU fallback: both need the GPU compute path (a
                // per-pixel multi-direction raymarch this renderer has no
                // CPU equivalent for). A device without Metal cannot show
                // these styles, the same failure mode opennessProducts/
                // rrimImage already have on their own.
                return nil
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
        viewshedMosaicCache = nil
        enforceMemoryBudget()

        // Neighbourhood styles read across tile edges, so a tile shaded before
        // this one arrived saw a partial neighbourhood: drop its bitmap and let
        // the renderer redraw it in the background.
        guard settings.style.microTopographyProduct != nil else { return }
        let parts = key.split(separator: "/")
        guard parts.count == 3, let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { return }
        for dx in -1...1 {
            for dy in -1...1 where !(dx == 0 && dy == 0) {
                let neighbourKey = "\(z)/\(x + dx)/\(y + dy)"
                guard cache[neighbourKey] != nil else { continue }
                cache[neighbourKey]?.rendered = nil
                renderedOrder.removeAll { $0 == neighbourKey }
                staleTiles.insert(neighbourKey)
            }
        }
    }

    /// Bytes cached tiles hold: rasters, derivative planes, shaded bitmaps.
    public func memoryCacheSize() -> Int {
        cache.values.reduce(0) { $0 + $1.byteCount }
    }

    /// Evicts least-recently-used tiles until both the byte budget and the tile
    /// count fit. The most recent tile always stays.
    private func enforceMemoryBudget() {
        var total = memoryCacheSize()
        while (total > Self.maxMemoryCacheBytes || cacheOrder.count > cacheLimit), cacheOrder.count > 1 {
            let oldest = cacheOrder.removeFirst()
            renderedOrder.removeAll { $0 == oldest }
            if let evicted = cache.removeValue(forKey: oldest) { total -= evicted.byteCount }
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

/// Ready tiles, in-flight requests and background redraws, keyed `z/x/y`.
///
/// MapKit calls `canDraw` and `draw` from several background queues at once,
/// so this is behind a lock rather than an actor: both of those are synchronous
/// and cannot await.
///
/// Every operation is a synchronous method rather than a bare lock/unlock pair,
/// because the completion side runs inside a `Task` and taking a lock directly
/// across an async context is not allowed — nor would it be safe, since a
/// suspension could move the unlock to another thread.
nonisolated final class TileImageStore: @unchecked Sendable {
    enum LoadOutcome: Equatable { case dropped, drawn, drawnButStale }

    /// What one `beginLoad` claim is answered with.
    ///
    /// Two independent identities, because two different things can obsolete a
    /// tile. `generation` is settings currency, shared by every key and bumped
    /// only by ``invalidate()``: a tile shaded under superseded settings is
    /// dropped rather than drawn. `id` is claim identity, unique per call:
    /// viewport culling cancels a single key *without* moving the generation,
    /// since a pan changes no settings, so the key can be claimed again at the
    /// same generation and the two claims would otherwise be indistinguishable
    /// — letting the cancelled task's late arrival retire bookkeeping that now
    /// belongs to the live one.
    struct Ticket: Sendable, Equatable {
        let id: Int
        let generation: Int
    }

    private struct Claim { let id: Int; let generation: Int; let markClock: UInt64 }

    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var inFlight: [String: Claim] = [:]
    private var inFlightTasks: [String: Task<Void, Never>] = [:]
    /// key -> markClock value when it was last marked stale.
    private var staleMarks: [String: UInt64] = [:]
    private var markClock: UInt64 = 0
    /// Bumped by `reloadData()`; results from an earlier generation are
    /// dropped rather than drawn under settings that have moved on.
    private var generation = 0
    private var nextClaimID = 0
    /// Claims cancelled before their task was registered.
    ///
    /// Culling can land in the window between `beginLoad` and `recordTask`,
    /// where there is no task to cancel yet. Without this the task would arrive
    /// to find its claim gone and, since the generation still matches, be left
    /// running for a tile nobody is waiting for. Drained by whichever of
    /// `recordTask`/`finishLoad` sees the id next, so it holds at most the
    /// handful of claims currently in that window.
    private var cancelledClaimIDs: Set<Int> = []

    func image(for key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    /// Whether anything in `paths` is drawable now, and which paths need a
    /// request (absent, or drawn but stale), under one acquisition.
    func partition(
        _ paths: [MKTileOverlayPath], key: (MKTileOverlayPath) -> String
    ) -> (ready: Bool, missing: [MKTileOverlayPath]) {
        lock.lock()
        defer { lock.unlock() }
        var ready = false
        var missing: [MKTileOverlayPath] = []
        for path in paths {
            let k = key(path)
            if images[k] != nil { ready = true }
            if images[k] == nil || staleMarks[k] != nil { missing.append(path) }
        }
        return (ready, missing)
    }

    /// Claims a tile for loading, or returns `nil` if it is already in flight
    /// or drawn and current.
    func beginLoad(_ key: String) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard images[key] == nil || staleMarks[key] != nil, inFlight[key] == nil else { return nil }
        nextClaimID += 1
        inFlight[key] = Claim(id: nextClaimID, generation: generation, markClock: markClock)
        return Ticket(id: nextClaimID, generation: generation)
    }

    /// Associates an asynchronous load task with an in-flight claim.
    ///
    /// Cancels the task immediately if the settings generation has moved on, or
    /// if the claim was culled while the task was being spawned. A claim that
    /// merely finished already drops its registration without cancelling —
    /// there is nothing left to stop.
    func recordTask(_ task: Task<Void, Never>, for key: String, ticket: Ticket) {
        lock.lock()
        let culled = cancelledClaimIDs.remove(ticket.id) != nil
        guard !culled, self.generation == ticket.generation,
              inFlight[key]?.id == ticket.id, !task.isCancelled
        else {
            let obsolete = culled || self.generation != ticket.generation
            lock.unlock()
            if obsolete { task.cancel() }
            return
        }
        let previous = inFlightTasks.updateValue(task, forKey: key)
        lock.unlock()
        previous?.cancel()
    }

    /// Records a finished load. Returns `.drawn` if drawn and current,
    /// `.drawnButStale` if an invalidation arrived while in-flight, or
    /// `.dropped` if the settings moved on, or this claim was culled or
    /// superseded.
    func finishLoad(_ key: String, image: CGImage?, ticket: Ticket) -> LoadOutcome {
        lock.lock()
        defer { lock.unlock() }
        cancelledClaimIDs.remove(ticket.id)
        // Retire only what this claim still owns. After a cull and a re-request
        // the entry in flight belongs to a newer claim, and clearing it here
        // would strand a task that is still running.
        guard let claim = inFlight[key], claim.id == ticket.id else { return .dropped }
        inFlight.removeValue(forKey: key)
        inFlightTasks.removeValue(forKey: key)
        guard let image, ticket.generation == generation else { return .dropped }
        images[key] = image
        if let mark = staleMarks[key], mark > claim.markClock {
            return .drawnButStale
        }
        staleMarks.removeValue(forKey: key)
        return .drawn
    }

    /// Cancels one in-flight load, leaving everything else alone. Returns
    /// whether there was a claim to cancel.
    ///
    /// Unlike ``invalidate()`` this keeps drawn imagery and does not touch the
    /// generation: a culled tile is not stale, it is simply not worth finishing
    /// while it sits off-screen, and it may be claimed again the moment it
    /// comes back.
    @discardableResult
    func cancel(_ key: String) -> Bool {
        lock.lock()
        guard let claim = inFlight.removeValue(forKey: key) else {
            lock.unlock()
            return false
        }
        cancelledClaimIDs.insert(claim.id)
        let task = inFlightTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
        return true
    }

    /// Keys with a load in flight right now.
    func inFlightKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(inFlight.keys)
    }

    /// Keys of the tiles holding a drawn image.
    func imageKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(images.keys)
    }

    /// Marks drawn tiles for a background redraw; returns the keys that were drawn.
    func markStale(_ keys: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var redraw: [String] = []
        for key in keys where images[key] != nil || inFlight[key] != nil {
            markClock &+= 1
            staleMarks[key] = markClock
            if images[key] != nil { redraw.append(key) }
        }
        return redraw
    }

    /// Number of active in-flight tasks (for testing).
    func inFlightTaskCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightTasks.count
    }

    /// Drops everything and moves to a new generation, cancelling all in-flight tasks.
    func invalidate() {
        lock.lock()
        let tasksToCancel = Array(inFlightTasks.values)
        inFlightTasks.removeAll()
        generation += 1
        images.removeAll()
        inFlight.removeAll()
        staleMarks.removeAll()
        cancelledClaimIDs.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
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

    /// The overlay, already retained by the superclass.
    ///
    /// Read through `MKOverlayRenderer.overlay` rather than stored again.
    /// Storing it forced a custom `init(overlay:)`, whose Objective-C selector
    /// `initWithOverlay:` collides with `MKOverlayRenderer`'s own designated
    /// initializer of that name — so Swift replaced the real one with a trap,
    /// and MapKit constructing the renderer walked straight into it. Inheriting
    /// `init(tileOverlay:)` untouched is what avoids that.
    private var terrainOverlay: TerrainTileOverlay { overlay as! TerrainTileOverlay }

    private let store = TileImageStore()

    /// The rect on screen as `cullTiles(outsideVisible:)` last saw it, and whether the provider has been
    /// told where to ask for it. Guarded by a lock: the provider reads it from its own executor.
    private let visibleLock = NSLock()
    private var visibleRect: MKMapRect?
    private var isRegisteredWithProvider = false

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

    deinit {
        store.invalidate()
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
        registerVisibleKeysSource()
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
        guard let ticket = store.beginLoad(key) else { return }

        let provider = terrainOverlay.provider
        let region = TerrainTileOverlay.region(for: path)
        let pixels = Self.tilePixels(tileSize: terrainOverlay.tileSize.width, contentScaleFactor: path.contentScaleFactor)

        let handle = WeakRenderer(renderer: self)
        let task = Task { [store] in
            let image = await provider.tileImage(
                x: path.x, y: path.y, z: path.z, region: region, pixels: pixels
            )
            let outcome = store.finishLoad(key, image: image, ticket: ticket)
            guard outcome != .dropped else { return }
            handle.renderer?.setNeedsDisplay(
                TerrainTileOverlay.mapRect(for: path), zoomScale: zoomScale
            )
            if outcome == .drawnButStale {
                handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: path))
            }
            // Neighbourhood styles read across tile edges: redraw tiles shaded
            // before a neighbour they needed had arrived, keeping their current
            // image on screen until the replacement lands.
            let stale = await provider.takeStaleTiles()
            for staleKey in store.markStale(stale) {
                if let stalePath = TerrainTileOverlayRenderer.path(forKey: staleKey) {
                    handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: stalePath))
                }
            }
        }
        store.recordTask(task, for: key, ticket: ticket)
    }

    /// Cancels tiles a pan has carried well outside `visible`.
    ///
    /// The generation fence cannot do this: it moves only on a shading change,
    /// and a pan changes no shading, so without this every tile a flick sweeps
    /// past runs to completion — streaming, decompressing and dispatching GPU
    /// work for ground that left the screen milliseconds ago.
    ///
    /// Driven from `mapViewDidChangeVisibleRegion`, which fires continuously
    /// during a gesture.
    public func cullTiles(outsideVisible visible: MKMapRect) {
        visibleLock.withLock { visibleRect = visible }
        registerVisibleKeysSource()
        var cancelled = 0
        for key in Self.keysOutside(visible, from: store.inFlightKeys()) {
            if store.cancel(key) { cancelled += 1 }
        }
        // Only when something was actually stopped: this runs on every region
        // change, which during a flick is every frame.
        if cancelled > 0 {
            Log.geospatial.debug("Culled \(cancelled, privacy: .public) off-screen tile request(s)")
        }
    }

    /// The tiles this renderer has drawn or is loading that touch the visible rect: what the provider
    /// must spare when the system asks for memory back. Empty until the first region change reports a rect.
    ///
    /// Callable from any thread: it reads only lock-guarded state and the store.
    public func visibleTileKeys() -> Set<String> {
        guard let rect = visibleLock.withLock({ visibleRect }) else { return [] }
        return Set(Self.keysInside(rect, from: store.imageKeys() + store.inFlightKeys()))
    }

    /// Tells the provider, once, where to ask which tiles are on screen. Holding the renderer weakly, a
    /// renderer that has gone away answers with none, so the provider then drops every bitmap.
    ///
    /// Done here rather than in an initializer: the superclass initializer is deliberately inherited
    /// untouched (see ``terrainOverlay``).
    private func registerVisibleKeysSource() {
        let isFirst = visibleLock.withLock { () -> Bool in
            let first = !isRegisteredWithProvider
            isRegisteredWithProvider = true
            return first
        }
        guard isFirst else { return }
        let handle = WeakRenderer(renderer: self)
        let provider = terrainOverlay.provider
        Task { await provider.setVisibleKeysSource { handle.renderer?.visibleTileKeys() ?? [] } }
    }

    /// Which of `keys` name tiles lying entirely outside `rect` grown by
    /// `margin` times its own size on every side.
    ///
    /// The margin is what keeps this from thrashing. A gesture reversal, or
    /// MapKit's own slight lag behind the live rect, routinely carries a tile
    /// just past the edge and straight back; cancelling those would trade GPU
    /// work for a repeated network fetch, which is the worse end to waste. Only
    /// tiles a whole viewport away — which a reversal cannot reach before the
    /// next region change — are worth stopping.
    ///
    /// A key that does not parse is kept: this decides what to *stop*, and
    /// guessing in that direction costs work that was already paid for.
    nonisolated static func keysOutside(
        _ rect: MKMapRect, from keys: [String], margin: Double = 1
    ) -> [String] {
        let grown = rect.insetBy(dx: -rect.size.width * margin, dy: -rect.size.height * margin)
        return keys.filter { key in
            guard let path = path(forKey: key) else { return false }
            return !TerrainTileOverlay.mapRect(for: path).intersects(grown)
        }
    }

    /// Pixels per side for a tile drawn at `contentScaleFactor`, rounded up to a
    /// multiple of 64.
    ///
    /// MapKit does not always hand the renderer an integral scale: an iPad Pro
    /// 13" (M5) draws this overlay at ~1.477, which truncated to 378 px. The
    /// analysis path decimates by powers of two and stitches rasters that must
    /// be a multiple of 4 wide, and 378 gave it neither, so a 1 m tile never
    /// decimated and a raking-light tile tripped the builder's assertion. The
    /// scale is rounded to the nearest pixel first so float noise cannot bump
    /// 512 to 576; 256, 512 and 768 are unchanged.
    nonisolated static func tilePixels(tileSize: CGFloat, contentScaleFactor: CGFloat) -> Int {
        let exact = Int((tileSize * max(contentScaleFactor, 1)).rounded())
        return (exact + 63) / 64 * 64
    }

    /// Which of `keys` name tiles that touch `rect`, at any zoom: a coarser tile over the same ground is
    /// still on screen mid-zoom. The counterpart of ``keysOutside(_:from:margin:)``, but this decides what
    /// to *keep*, so a key that does not parse is not kept.
    nonisolated static func keysInside(_ rect: MKMapRect, from keys: [String]) -> [String] {
        keys.filter { key in
            guard let path = path(forKey: key) else { return false }
            return TerrainTileOverlay.mapRect(for: path).intersects(rect)
        }
    }

    nonisolated static func key(_ path: MKTileOverlayPath) -> String {
        "\(path.z)/\(path.x)/\(path.y)"
    }

    /// The tile path a `z/x/y` key names, for invalidating its map rect.
    nonisolated static func path(forKey key: String) -> MKTileOverlayPath? {
        let parts = key.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return MKTileOverlayPath(x: parts[1], y: parts[2], z: parts[0], contentScaleFactor: 1)
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
