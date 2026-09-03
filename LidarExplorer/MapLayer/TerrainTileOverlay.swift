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

    private let elevation: any ElevationProviding
    private let terrarium: TerrariumTileService
    private let raster: RasterCompute

    private var settings = TerrainStyleSettings()
    /// Cached derivatives per tile, so relighting costs no network.
    private var cache: [String: CachedTile] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 160

    private struct CachedTile {
        let grid: ElevationGrid
        let products: ReliefProducts
    }

    public init(
        elevation: (any ElevationProviding)? = nil,
        terrarium: TerrariumTileService? = nil,
        raster: RasterCompute? = nil
    ) {
        self.elevation = elevation ?? USGS3DEPService()
        self.terrarium = terrarium ?? TerrariumTileService()
        self.raster = raster ?? RasterCompute()
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
    ///  - to z15, pre-rendered Terrarium tiles, ~0.2s each
    ///  - beyond, the 3DEP ImageServer at native 1 m, 10-18s for a novel
    ///    extent but covering a small area by then, with MapKit showing the
    ///    upsampled z15 tile until it lands
    public func tileImageData(
        x: Int, y: Int, z: Int,
        region: GeoRegion,
        pixels: Int
    ) async -> Data? {
        let key = "\(z)/\(x)/\(y)"

        let cached: CachedTile
        if let hit = cache[key] {
            cached = hit
        } else {
            guard let entry = await loadTile(x: x, y: y, z: z, region: region, pixels: pixels)
            else { return nil }
            store(entry, for: key)
            cached = entry
        }

        guard let image = render(cached) else { return nil }
        return Self.pngData(from: image)
    }

    /// Fetches elevation for a tile and computes its derivatives.
    private func loadTile(
        x: Int, y: Int, z: Int, region: GeoRegion, pixels: Int
    ) async -> CachedTile? {
        let margin = Self.marginPixels

        if z <= TerrariumTileService.maximumZ {
            guard let grid = await terrarium
                .elevation(x: x, y: y, z: z, region: region).value else { return nil }
            // Terrarium tiles arrive with no overlap, so the outermost ring
            // has no neighbourhood for Horn's kernel. Replicating the edge
            // before shading and cropping after costs nothing and avoids a
            // dead border on every tile, which would read as a grid of seams.
            let padded = Self.padByReplication(grid, margin: margin)
            let products = await raster.reliefProducts(for: padded)
            return CachedTile(
                grid: grid,
                products: Self.crop(products, margin: margin)
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

        guard let grid = await elevation
            .elevation(for: expanded, targetSamples: samples).value else { return nil }
        let products = await raster.reliefProducts(for: grid)
        return CachedTile(
            grid: grid,
            products: Self.crop(products, margin: margin)
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

    private func store(_ tile: CachedTile, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
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
        // Below this a single tile spans hundreds of kilometres, where a
        // bare-earth relief model says little and each fetch is slow.
        self.minimumZ = 9
        // 3DEP is 1 m, and a z16 tile at 512px already lands at ~0.93 m/px.
        // Going deeper only resamples the same data while doubling the number
        // of slow dynamic requests, so MapKit upsamples past here instead.
        self.maximumZ = 16
        self.canReplaceMapContent = false
    }

    public override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let region = Self.region(for: path)
        // MapKit asks for @2x tiles on retina, which lands at 512px — the
        // size the service serves fastest.
        let pixels = Int(tileSize.width * max(path.contentScaleFactor, 1))

        Task { [provider] in
            let data = await provider.tileImageData(
                x: path.x, y: path.y, z: path.z, region: region, pixels: pixels
            )
            // A tile with no data is not an error: it is ocean, or outside
            // 3DEP coverage. Reporting an error makes MapKit retry forever.
            result(data, nil)
        }
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
