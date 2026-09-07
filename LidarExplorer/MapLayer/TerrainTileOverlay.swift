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
    /// — either its own tile, or the deepest ancestor upsampled, which is
    /// still far better than waiting 10+ seconds per tile while panning.
    public nonisolated static let nativeDetailZ = 18

    /// Human-readable source descriptor for a tile at zoom level `z`.
    public nonisolated static func sourceName(forZ z: Int) -> String {
        if z < nativeDetailZ {
            return z <= TerrariumTileService.maximumZ ? "terrarium" : "terrarium (upsampled)"
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

    private var settings = TerrainStyleSettings()
    /// Cached derivatives per tile, so relighting costs no network.
    private var cache: [String: CachedTile] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 160
    /// In-flight fetches for ancestor tiles, deduplicating simultaneous child requests.
    private var inFlightAncestors: [String: Task<ElevationGrid?, Never>] = [:]

    private struct CachedTile {
        let grid: ElevationGrid
        let products: ReliefProducts
        let source: String
    }

    public init(
        elevation: (any ElevationProviding)? = nil,
        terrarium: TerrariumTileService? = nil,
        raster: RasterCompute? = nil,
        report: (@Sendable (TileEvent) -> Void)? = nil
    ) {
        self.elevation = elevation ?? USGS3DEPService()
        self.terrarium = terrarium ?? TerrariumTileService()
        self.raster = raster ?? RasterCompute()
        self.report = report
    }

    /// Applies new shading settings. Returns `true` if anything changed.
    @discardableResult
    public func update(_ newSettings: TerrainStyleSettings) -> Bool {
        guard newSettings != settings else { return false }
        settings = newSettings
        return true
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

        guard let image = render(cached) else {
            report?(TileEvent(
                z: z, x: x, y: y, source: sourceName, outcome: .failed,
                duration: Date().timeIntervalSince(started)
            ))
            return nil
        }
        let data = Self.pngData(from: image)

        report?(TileEvent(
            z: z, x: x, y: y, source: sourceName,
            outcome: wasCached ? .cached : .fetched,
            duration: Date().timeIntervalSince(started),
            resolution: cached.grid.groundSampleDistance,
            byteCount: data?.count,
            backend: cached.products.backend
        ))
        return data
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

        // Native-resolution path: fetch a real skirt rather than inventing one.
        let latPad = region.latitudeSpan * Double(margin) / Double(pixels)
        let lonPad = region.longitudeSpan * Double(margin) / Double(pixels)
        let expanded = GeoRegion(
            minLatitude: region.minLatitude - latPad,
            maxLatitude: region.maxLatitude + latPad,
            minLongitude: region.minLongitude - lonPad,
            maxLongitude: region.maxLongitude + lonPad
        )
        let nativeSamples = Int(expanded.widthMeters / Self.nativeResolution)
        let samples = min(pixels + margin * 2, max(nativeSamples, 64))

        if let grid = await elevation
            .elevation(for: expanded, targetSamples: samples).value {
            let products = await raster.reliefProducts(for: grid)
            let croppedGrid = grid.cropped(margin: margin)
            let croppedProducts = Self.crop(products, margin: margin)
            return CachedTile(
                grid: croppedGrid,
                products: croppedProducts,
                source: "3DEP 1m"
            )
        }

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

        // When the request is deeper than terrarium goes, take just the
        // part of the ancestor covering this tile.
        let grid = scale == 1 ? ancestor : Self.subgrid(of: ancestor, covering: region)
        // Terrarium tiles arrive with no overlap, so the outermost ring
        // has no neighbourhood for Horn's kernel. Replicating the edge
        // before shading and cropping after costs nothing and avoids a
        // dead border on every tile, which would read as a grid of seams.
        guard grid.width >= 4, grid.height >= 4 else { return nil }
        let padded = Self.padByReplication(grid, margin: margin)
        let products = await raster.reliefProducts(for: padded)
        return CachedTile(
            grid: grid,
            products: Self.crop(products, margin: margin),
            source: source
        )
    }

    /// Extracts the part of a grid covering a sub-region.
    ///
    /// Used when the map asks for a tile deeper than the source publishes:
    /// the containing ancestor is fetched and the relevant quarter (or
    /// sixteenth) taken from it. The samples are the ancestor's, so this is
    /// upsampling rather than new detail — but it is immediate, where the
    /// native-resolution service would take ten seconds or more per tile.
    nonisolated static func subgrid(
        of grid: ElevationGrid, covering region: GeoRegion
    ) -> ElevationGrid {
        let source = grid.region
        guard source.latitudeSpan > 0, source.longitudeSpan > 0 else { return grid }

        func column(_ longitude: Double) -> Int {
            let f = (longitude - source.minLongitude) / source.longitudeSpan
            return min(max(Int((f * Double(grid.width)).rounded(.down)), 0), grid.width - 1)
        }
        func row(_ latitude: Double) -> Int {
            // Row 0 is the northern edge.
            let f = (source.maxLatitude - latitude) / source.latitudeSpan
            return min(max(Int((f * Double(grid.height)).rounded(.down)), 0), grid.height - 1)
        }

        let x0 = column(region.minLongitude)
        let x1 = max(column(region.maxLongitude), x0 + 1)
        let y0 = row(region.maxLatitude)
        let y1 = max(row(region.minLatitude), y0 + 1)

        let w = min(x1 - x0, grid.width - x0)
        let h = min(y1 - y0, grid.height - y0)
        guard w > 0, h > 0 else { return grid }

        var out = [Float](repeating: .nan, count: w * h)
        for yy in 0..<h {
            let src = (y0 + yy) * grid.width + x0
            out.replaceSubrange((yy * w)..<(yy * w + w), with: grid.samples[src..<(src + w)])
        }
        return ElevationGrid(width: w, height: h, samples: out, region: region)
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
        // The padded raster covers proportionally more ground, so the region
        // must grow with it or every derived distance is wrong.
        let latPad = grid.region.latitudeSpan * Double(margin) / Double(grid.height)
        let lonPad = grid.region.longitudeSpan * Double(margin) / Double(grid.width)
        let region = GeoRegion(
            minLatitude: grid.region.minLatitude - latPad,
            maxLatitude: grid.region.maxLatitude + latPad,
            minLongitude: grid.region.minLongitude - lonPad,
            maxLongitude: grid.region.maxLongitude + lonPad
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
            var out = [Float](repeating: .nan, count: w * h)
            for y in 0..<h {
                let src = (y + margin) * products.width + margin
                out.replaceSubrange(
                    (y * w)..<(y * w + w),
                    with: source[src..<(src + w)]
                )
            }
            return out
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

    /// Ground sample distance of the finest cached tile, for display.
    public func finestResolution() -> Double? {
        cache.values.map(\.grid.groundSampleDistance).min()
    }

    /// Drops cached imagery. Derivatives are kept — only shading changed.
    public func clear() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - Rendering

    private func render(_ tile: CachedTile) -> CGImage? {
        let products = tile.products
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
            values = tile.grid.samples
            range = ReliefRenderer.robustRange(of: values)
        }

        return ReliefRenderer.image(
            from: values,
            width: products.width,
            height: products.height,
            style: settings.style,
            range: range
        )
    }

    private nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
        // deeper than the apparent zoom — z17 for a view that looks like
        // z15 — so a tight cap silently blanked the whole layer. Depth is
        // handled in the provider instead, by source selection.
        self.minimumZ = 6
        self.maximumZ = 19
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
