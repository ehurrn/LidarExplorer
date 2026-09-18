//
//  ElevationTileCoordinator.swift
//  LidarExplorer
//
//  Streams USGS 3DEP 1 m Cloud-Optimized GeoTIFFs into GPU-adoptable memory.
//

import CoreLocation
import Foundation
import os
import simd

/// A 1 m DEM product The National Map lists for an area.
public nonisolated struct DEMProduct: Sendable, Equatable, Hashable {
    public let title: String
    public let url: URL
    public let bounds: GeoRegion
    /// ISO `yyyy-MM-dd`, so a newer product sorts later.
    public let publicationDate: String

    public init(title: String, url: URL, bounds: GeoRegion, publicationDate: String) {
        self.title = title
        self.url = url
        self.bounds = bounds
        self.publicationDate = publicationDate
    }
}

/// Where a COG's pixels sit on the ground: its UTM zone and affine placement.
public nonisolated struct COGGeoreference: Sendable, Equatable {
    public let zone: Int
    public let hemisphere: UTMProjection.Hemisphere
    /// Easting / northing of pixel (0, 0)'s outer corner (PixelIsArea).
    public let tiepointX: Double
    public let tiepointY: Double
    public let pixelSizeX: Double
    public let pixelSizeY: Double
    public let width: Int
    public let height: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let noDataValue: Float?

    public init(
        zone: Int, hemisphere: UTMProjection.Hemisphere,
        tiepointX: Double, tiepointY: Double, pixelSizeX: Double, pixelSizeY: Double,
        width: Int, height: Int, tileWidth: Int, tileHeight: Int, noDataValue: Float?
    ) {
        self.zone = zone
        self.hemisphere = hemisphere
        self.tiepointX = tiepointX
        self.tiepointY = tiepointY
        self.pixelSizeX = pixelSizeX
        self.pixelSizeY = pixelSizeY
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.noDataValue = noDataValue
    }

    public init?(header h: COGByteReader.Header) {
        guard let epsg = h.epsgCode, let (zone, hemisphere) = UTMProjection.zone(forEPSG: epsg),
              h.modelPixelScale.x > 0, h.modelPixelScale.y > 0, h.tileWidth > 0, h.tileLength > 0
        else { return nil }
        self.init(
            zone: zone, hemisphere: hemisphere,
            tiepointX: h.modelTiepoint.x, tiepointY: h.modelTiepoint.y,
            pixelSizeX: h.modelPixelScale.x, pixelSizeY: h.modelPixelScale.y,
            width: h.width, height: h.height, tileWidth: h.tileWidth, tileHeight: h.tileLength,
            noDataValue: h.noDataValue
        )
    }

    public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
    public var tilesDown: Int { (height + tileHeight - 1) / tileHeight }

    /// Fractional pixel coordinates of a coordinate, pixel centres at integers.
    public func pixel(for coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        let utm = UTMProjection.forward(
            latitude: coordinate.latitude, longitude: coordinate.longitude, zone: zone, hemisphere: hemisphere
        )
        return SIMD2((utm.easting - tiepointX) / pixelSizeX - 0.5, (tiepointY - utm.northing) / pixelSizeY - 0.5)
    }

    /// The geographic coordinate of a fractional pixel position.
    public func coordinate(forPixel p: SIMD2<Double>) -> CLLocationCoordinate2D {
        let easting = tiepointX + (p.x + 0.5) * pixelSizeX
        let northing = tiepointY - (p.y + 0.5) * pixelSizeY
        let geo = UTMProjection.inverse(easting: easting, northing: northing, zone: zone, hemisphere: hemisphere)
        return CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
    }

    /// Tiles whose pixels a region's bilinear resample reads.
    public func tiles(covering region: GeoRegion) -> [(column: Int, row: Int)] {
        let corners = [
            CLLocationCoordinate2D(latitude: region.minLatitude, longitude: region.minLongitude),
            CLLocationCoordinate2D(latitude: region.minLatitude, longitude: region.maxLongitude),
            CLLocationCoordinate2D(latitude: region.maxLatitude, longitude: region.minLongitude),
            CLLocationCoordinate2D(latitude: region.maxLatitude, longitude: region.maxLongitude),
        ].map(pixel(for:))
        let xs = corners.map(\.x).filter { $0.isFinite }
        let ys = corners.map(\.y).filter { $0.isFinite }
        guard let minCornerX = xs.min(), let maxCornerX = xs.max(),
              let minCornerY = ys.min(), let maxCornerY = ys.max()
        else { return [] }
        let minX = max(Int((minCornerX - 1).rounded(.down)), 0)
        let maxX = min(Int((maxCornerX + 1).rounded(.up)), width - 1)
        let minY = max(Int((minCornerY - 1).rounded(.down)), 0)
        let maxY = min(Int((maxCornerY + 1).rounded(.up)), height - 1)
        guard minX <= maxX, minY <= maxY else { return [] }
        var out: [(Int, Int)] = []
        for row in (minY / tileHeight)...(maxY / tileHeight) {
            for column in (minX / tileWidth)...(maxX / tileWidth) { out.append((column, row)) }
        }
        return out
    }
}

/// A decoded COG tile in page-aligned storage, sentinels already NaN.
public nonisolated struct StreamedTile: Sendable {
    public let product: URL
    public let column: Int
    public let row: Int
    public let overviewLevel: Int
    public let storage: COGMappedStorage
    public let width: Int
    public let height: Int
    public let cellSizeX: Float
    public let cellSizeY: Float
    /// True when the GPU's nodata pass rewrote the sentinels in this very
    /// memory; false when the CPU fallback did.
    public let normalizedOnGPU: Bool

    public init(
        product: URL,
        column: Int,
        row: Int,
        overviewLevel: Int = 0,
        storage: COGMappedStorage,
        width: Int,
        height: Int,
        cellSizeX: Float,
        cellSizeY: Float,
        normalizedOnGPU: Bool
    ) {
        self.product = product
        self.column = column
        self.row = row
        self.overviewLevel = overviewLevel
        self.storage = storage
        self.width = width
        self.height = height
        self.cellSizeX = cellSizeX
        self.cellSizeY = cellSizeY
        self.normalizedOnGPU = normalizedOnGPU
    }

    /// The tile as the micro-topography pipeline reads it: the same pages,
    /// adopted with `bytesNoCopy`.
    public var raster: ElevationRaster {
        ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: RasterGeometry(width: width, height: height, cellSizeX: cellSizeX, cellSizeY: cellSizeY)
        )
    }
}

/// A COG-derived raster resampled onto a Web Mercator footprint.
public nonisolated struct StreamedRaster: Sendable {
    /// Page-aligned, NaN-voided samples the GPU adopts without a copy.
    public let storage: COGMappedStorage
    public let width: Int
    public let height: Int
    public let region: GeoRegion
    /// The newest product that contributed samples.
    public let product: DEMProduct
    public let validFraction: Double

    public var raster: ElevationRaster {
        let grid = RasterGeometry(width: width, height: height,
                                  cellSizeX: Float(region.widthMeters / Double(max(width - 1, 1))),
                                  cellSizeY: Float(region.heightMeters / Double(max(height - 1, 1))))
        return ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: grid
        )
    }

    /// The samples as an ``ElevationGrid``, for consumers that need the heap
    /// array (the one copy on this path, and only for those consumers).
    public var grid: ElevationGrid {
        let samples = [Float](UnsafeBufferPointer(
            start: storage.pointer.assumingMemoryBound(to: Float.self), count: width * height))
        return withExtendedLifetime(storage) {
            ElevationGrid(width: width, height: height, samples: samples, region: region)
        }
    }
}

/// Resamples COG pixels onto a Web Mercator footprint.
public nonisolated enum COGResampler {

    /// Fills `destination` (`width x height`, row 0 north) with void-aware
    /// bilinear samples of the COG, placing output pixel centres exactly where
    /// the 3DEP ImageServer's `exportImage` places them (pixel-is-area over the
    /// region's Mercator bounds), so a tile renders identically from either
    /// source.
    ///
    /// The Mercator-to-UTM mapping is evaluated exactly at the corners of
    /// 16-pixel blocks and interpolated inside them. UTM and Mercator are both
    /// conformal, so within 16 pixels the mapping is affine to far better than
    /// a millimetre -- and 256x fewer projection evaluations.
    ///
    /// - Parameters:
    ///   - fillOnlyVoids: leave already-valid output alone (a second product
    ///     filling the first one's gaps).
    ///   - tile: the samples of COG tile (column, row), or `nil` if unavailable.
    /// - Returns: the number of output samples written.
    @discardableResult
    public static func resample(
        region: GeoRegion,
        width: Int,
        height: Int,
        georeference geo: COGGeoreference,
        into destination: UnsafeMutablePointer<Float>,
        fillOnlyVoids: Bool = false,
        tile: (Int, Int) -> UnsafePointer<Float>?
    ) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let m = region.mercatorBounds
        let stepX = (m.maxX - m.minX) / Double(width)
        let stepY = (m.maxY - m.minY) / Double(height)

        func sourcePixel(edgeX: Int, edgeY: Int) -> SIMD2<Double> {
            geo.pixel(for: GeoRegion.fromMercatorMeters(x: m.minX + Double(edgeX) * stepX, y: m.maxY - Double(edgeY) * stepY))
        }

        var cachedColumn = -1, cachedRow = -1
        var cachedPointer: UnsafePointer<Float>?
        func value(_ sx: Int, _ sy: Int) -> Float {
            let column = sx / geo.tileWidth, row = sy / geo.tileHeight
            if column != cachedColumn || row != cachedRow {
                cachedColumn = column
                cachedRow = row
                cachedPointer = tile(column, row)
            }
            guard let p = cachedPointer else { return .nan }
            return p[(sy - row * geo.tileHeight) * geo.tileWidth + (sx - column * geo.tileWidth)]
        }

        let block = 16
        var written = 0
        let maxX = Double(geo.width - 1), maxY = Double(geo.height - 1)
        for by in stride(from: 0, to: height, by: block) {
            let by1 = min(by + block, height)
            for bx in stride(from: 0, to: width, by: block) {
                let bx1 = min(bx + block, width)
                let p00 = sourcePixel(edgeX: bx, edgeY: by), p10 = sourcePixel(edgeX: bx1, edgeY: by)
                let p01 = sourcePixel(edgeX: bx, edgeY: by1), p11 = sourcePixel(edgeX: bx1, edgeY: by1)
                for oy in by..<by1 {
                    let ty = (Double(oy) + 0.5 - Double(by)) / Double(by1 - by)
                    let left = p00 + (p01 - p00) * ty
                    let right = p10 + (p11 - p10) * ty
                    for ox in bx..<bx1 {
                        let i = oy * width + ox
                        if fillOnlyVoids && !destination[i].isNaN { continue }
                        let tx = (Double(ox) + 0.5 - Double(bx)) / Double(bx1 - bx)
                        let s = left + (right - left) * tx
                        guard s.x >= 0, s.y >= 0, s.x <= maxX, s.y <= maxY else { continue }
                        let x0 = Int(s.x), y0 = Int(s.y)
                        let x1 = min(x0 + 1, geo.width - 1), y1 = min(y0 + 1, geo.height - 1)
                        let v00 = value(x0, y0), v10 = value(x1, y0)
                        let v01 = value(x0, y1), v11 = value(x1, y1)
                        guard !v00.isNaN, !v10.isNaN, !v01.isNaN, !v11.isNaN else { continue }
                        let fx = Float(s.x - Double(x0)), fy = Float(s.y - Double(y0))
                        let top = v00 + (v10 - v00) * fx
                        let bottom = v01 + (v11 - v01) * fx
                        destination[i] = top + (bottom - top) * fy
                        written += 1
                    }
                }
            }
        }
        return written
    }
}

/// Response shape of The National Map's product API, as far as it is used.
private nonisolated struct TNMProductResponse: Decodable {
    struct Item: Decodable {
        let title: String
        let downloadURL: String
        let publicationDate: String?
        let boundingBox: Box?
    }

    struct Box: Decodable {
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
    }

    let items: [Item]
}

/// Streams USGS 3DEP 1 m Cloud-Optimized GeoTIFFs for a region.
///
/// ## Pipeline
///
/// 1. **Discovery** — The National Map's product API lists the 1 m COGs over
///    a 0.05 degree query cell (cached; projects overlap, newest wins).
/// 2. **Range ingestion** — each COG is a ``COGByteReader``: one ranged GET for
///    the header, one per 256x256 tile touched. Concurrent requests for the
///    same tile collapse onto one fetch.
/// 3. **Decode into UMA** — LZW decompresses straight into page-aligned
///    storage and the predictor is reversed in place.
/// 4. **Nodata** — ``MetalTerrainPipelineActor/normalizeNoDataInPlace(_:)``
///    rewrites sentinels to NaN in that same memory on the GPU, before the
///    tile is published (so no reader ever races the write).
/// 5. **Preprocessing** — native tiles go to analysis as-is
///    (``StreamedTile/raster``); map tiles are resampled onto their Mercator
///    footprint (``elevationRaster(for:width:height:)``).
///
/// Tiles are held in a byte-budgeted LRU (``tileCacheBytes``).
public actor ElevationTileCoordinator: ElevationProviding {

    public static let shared = ElevationTileCoordinator()

    public nonisolated static let tileCacheBytes = 128 * 1024 * 1024
    private nonisolated static let productsEndpoint = URL(string: "https://tnmaccess.nationalmap.gov/api/v1/products")!
    private nonisolated static let dataset = "Digital Elevation Model (DEM) 1 meter"
    private nonisolated static let queryCellDegrees = 0.05
    private nonisolated static let maxSamplesPerAxis = 2048
    private nonisolated static let coverage = GeoRegion(
        minLatitude: 15.0, maxLatitude: 72.0, minLongitude: -179.5, maxLongitude: -64.0
    )

    private nonisolated static let maxReaders = 16
    private nonisolated static let maxGeoreferences = 64
    private nonisolated static let negativeProductCacheSeconds: Double = 300

    public struct TileKey: Hashable, Sendable {
        public let product: URL
        public let column: Int
        public let row: Int
        public let overviewLevel: Int

        public init(product: URL, column: Int, row: Int, overviewLevel: Int = 0) {
            self.product = product
            self.column = column
            self.row = row
            self.overviewLevel = overviewLevel
        }
    }

    public struct Statistics: Sendable, Equatable {
        public let cachedTiles: Int
        public let cachedBytes: Int
        public let tileFetches: Int
        public let gpuNormalizedTiles: Int
    }

    private struct CachedProducts {
        let products: [DEMProduct]
        let cachedAt: ContinuousClock.Instant
    }

    private struct GeoKey: Hashable, Sendable {
        let product: URL
        let overviewLevel: Int
    }

    private let transport: HTTPTransport
    private let pipeline: MetalTerrainPipelineActor

    private var readers: [URL: COGByteReader] = [:]
    private var readerOrder: [URL] = []
    private var georeferences: [GeoKey: COGGeoreference] = [:]
    private var georeferenceOrder: [GeoKey] = []
    private var unusableProducts: Set<URL> = []
    private var productCache: [String: CachedProducts] = [:]
    private var inFlightProducts: [String: Task<[DEMProduct], Never>] = [:]

    private var tileCache: [TileKey: StreamedTile] = [:]
    private var tileOrder: [TileKey] = []
    private var cachedBytes = 0
    private var inFlightTiles: [TileKey: Task<StreamedTile?, Never>] = [:]
    private var tileFetches = 0
    private var gpuNormalizedTiles = 0

    public init(transport: HTTPTransport = .shared, pipeline: MetalTerrainPipelineActor = .shared) {
        self.transport = transport
        self.pipeline = pipeline
    }

    public func statistics() -> Statistics {
        Statistics(cachedTiles: tileCache.count, cachedBytes: cachedBytes,
                   tileFetches: tileFetches, gpuNormalizedTiles: gpuNormalizedTiles)
    }

    // MARK: - Discovery

    /// 1 m DEM products intersecting `region`, those fully containing it first,
    /// newest first within each group.
    public func products(covering region: GeoRegion) async -> [DEMProduct] {
        guard Self.coverage.contains(region.center) else { return [] }
        let cell = Self.queryCell(for: region)
        let key = "\(cell.minLongitude),\(cell.minLatitude),\(cell.maxLongitude),\(cell.maxLatitude)"
        let now = ContinuousClock.now
        let listed: [DEMProduct]
        if let cached = productCache[key] {
            if !cached.products.isEmpty || (now - cached.cachedAt) < .seconds(Self.negativeProductCacheSeconds) {
                listed = cached.products
            } else {
                productCache.removeValue(forKey: key)
                listed = await fetchProducts(cell: cell, key: key)
            }
        } else {
            listed = await fetchProducts(cell: cell, key: key)
        }
        return Self.rank(listed.filter { !unusableProducts.contains($0.url) }, for: region)
    }

    private func fetchProducts(cell: GeoRegion, key: String) async -> [DEMProduct] {
        if let running = inFlightProducts[key] {
            return await running.value
        }
        let task = Task { [transport] in await Self.fetchProducts(in: cell, transport: transport) }
        inFlightProducts[key] = task
        let fetched = await task.value
        inFlightProducts[key] = nil
        productCache[key] = CachedProducts(products: fetched, cachedAt: .now)
        return fetched
    }

    nonisolated static func queryCell(for region: GeoRegion) -> GeoRegion {
        let s = queryCellDegrees
        return GeoRegion(
            minLatitude: (region.minLatitude / s).rounded(.down) * s,
            maxLatitude: (region.maxLatitude / s).rounded(.up) * s,
            minLongitude: (region.minLongitude / s).rounded(.down) * s,
            maxLongitude: (region.maxLongitude / s).rounded(.up) * s
        )
    }

    nonisolated static func rank(_ products: [DEMProduct], for region: GeoRegion) -> [DEMProduct] {
        func contains(_ p: DEMProduct) -> Bool {
            p.bounds.minLatitude <= region.minLatitude && p.bounds.maxLatitude >= region.maxLatitude
                && p.bounds.minLongitude <= region.minLongitude && p.bounds.maxLongitude >= region.maxLongitude
        }
        func intersects(_ p: DEMProduct) -> Bool {
            p.bounds.minLatitude <= region.maxLatitude && p.bounds.maxLatitude >= region.minLatitude
                && p.bounds.minLongitude <= region.maxLongitude && p.bounds.maxLongitude >= region.minLongitude
        }
        return products.filter(intersects).sorted { a, b in
            let ca = contains(a), cb = contains(b)
            if ca != cb { return ca }
            return a.publicationDate > b.publicationDate
        }
    }

    private nonisolated static func fetchProducts(in cell: GeoRegion, transport: HTTPTransport) async -> [DEMProduct] {
        var components = URLComponents(url: productsEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "datasets", value: dataset),
            .init(name: "bbox", value: "\(cell.minLongitude),\(cell.minLatitude),\(cell.maxLongitude),\(cell.maxLatitude)"),
            .init(name: "prodFormats", value: "GeoTIFF"),
            .init(name: "max", value: "100"),
            .init(name: "outputFormat", value: "JSON"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        switch await transport.data(for: request, maxAttempts: 2) {
        case .failure(let error):
            Log.network.error("TNM product query failed: \(error.description, privacy: .public)")
            return []
        case .success(let data):
            guard let response = try? JSONDecoder().decode(TNMProductResponse.self, from: data) else {
                Log.network.error("TNM product response undecodable")
                return []
            }
            return response.items.compactMap { item in
                guard let box = item.boundingBox, let url = URL(string: item.downloadURL),
                      url.pathExtension.lowercased() == "tif" else { return nil }
                return DEMProduct(
                    title: item.title, url: url,
                    bounds: GeoRegion(minLatitude: box.minY, maxLatitude: box.maxY,
                                      minLongitude: box.minX, maxLongitude: box.maxX),
                    publicationDate: item.publicationDate ?? ""
                )
            }
        }
    }

    private func reader(for product: URL) -> COGByteReader {
        if let existing = readers[product] {
            if let idx = readerOrder.firstIndex(of: product) {
                readerOrder.remove(at: idx)
                readerOrder.append(product)
            }
            return existing
        }
        while readers.count >= Self.maxReaders, !readerOrder.isEmpty {
            let victim = readerOrder.removeFirst()
            readers.removeValue(forKey: victim)
        }
        let reader = COGByteReader(url: product, transport: transport)
        readers[product] = reader
        readerOrder.append(product)
        return reader
    }

    /// The product's georeference, or `nil` (remembered) when its COG is not
    /// one this reader supports -- older 3DEP projects are striped or not UTM.
    public func georeference(for product: URL, overviewLevel: Int = 0) async -> COGGeoreference? {
        let key = GeoKey(product: product, overviewLevel: overviewLevel)
        if let known = georeferences[key] {
            if let idx = georeferenceOrder.firstIndex(of: key) {
                georeferenceOrder.remove(at: idx)
                georeferenceOrder.append(key)
            }
            return known
        }
        guard !unusableProducts.contains(product) else { return nil }
        do {
            let header = try await reader(for: product).header(forOverview: overviewLevel)
            guard let geo = COGGeoreference(header: header), header.sampleFormat == 3, header.bitsPerSample == 32 else {
                if overviewLevel == 0 {
                    unusableProducts.insert(product)
                }
                return nil
            }
            while georeferences.count >= Self.maxGeoreferences, !georeferenceOrder.isEmpty {
                let victim = georeferenceOrder.removeFirst()
                georeferences.removeValue(forKey: victim)
            }
            georeferences[key] = geo
            georeferenceOrder.append(key)
            return geo
        } catch COGError.transportFailure(let text) {
            Log.network.error("COG header fetch failed: \(text, privacy: .public)")
            return nil
        } catch {
            if overviewLevel == 0 {
                unusableProducts.insert(product)
            }
            Log.geospatial.notice("COG unusable (\(String(describing: error), privacy: .public)): \(product.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    // MARK: - Tiles

    /// One native or overview tile, decoded into page-aligned memory and nodata-normalised
    /// in place (on the GPU where the binding is zero-copy).
    public func tile(product: URL, column: Int, row: Int, overviewLevel: Int = 0) async -> StreamedTile? {
        let key = TileKey(product: product, column: column, row: row, overviewLevel: overviewLevel)
        if let hit = tileCache[key] {
            promote(key)
            return hit
        }
        if let running = inFlightTiles[key] { return await running.value }
        guard let geo = await georeference(for: product, overviewLevel: overviewLevel),
              column >= 0, row >= 0, column < geo.tilesAcross, row < geo.tilesDown
        else { return nil }

        let reader = reader(for: product)
        let index = row * geo.tilesAcross + column
        tileFetches += 1
        let task = Task<StreamedTile?, Never> { [pipeline] in
            guard let decoded = try? await reader.fetchTileStorage(index, overviewLevel: overviewLevel) else { return nil }
            let count = decoded.width * decoded.height
            _ = decoded.storage.pointer.bindMemory(to: Float.self, capacity: count)
            let raster = ElevationRaster(
                samples: .mapped(base: decoded.storage.pointer, mappedLength: decoded.storage.length,
                                 sampleOffset: 0, owner: decoded.storage),
                geometry: RasterGeometry(width: decoded.width, height: decoded.height,
                                         cellSizeX: Float(geo.pixelSizeX), cellSizeY: Float(geo.pixelSizeY)),
                needsNoDataNormalization: true, noDataValue: geo.noDataValue
            )
            let onGPU = await pipeline.normalizeNoDataInPlace(raster)
            if !onGPU { Self.normalizeOnCPU(decoded.storage, count: count, noDataValue: geo.noDataValue) }
            return StreamedTile(
                product: product, column: column, row: row, overviewLevel: overviewLevel, storage: decoded.storage,
                width: decoded.width, height: decoded.height,
                cellSizeX: Float(geo.pixelSizeX), cellSizeY: Float(geo.pixelSizeY), normalizedOnGPU: onGPU
            )
        }
        inFlightTiles[key] = task
        let result = await task.value
        inFlightTiles[key] = nil
        if let result {
            if result.normalizedOnGPU { gpuNormalizedTiles += 1 }
            store(result, for: key)
        }
        return result
    }

    nonisolated static func normalizeOnCPU(_ storage: COGMappedStorage, count: Int, noDataValue: Float?) {
        let floats = storage.pointer.assumingMemoryBound(to: Float.self)
        for i in 0..<count {
            let z = floats[i]
            if !z.isFinite || !MicroTopographyReference.validElevationRange.contains(z) || (noDataValue != nil && z == noDataValue) {
                floats[i] = .nan
            }
        }
    }

    private func promote(_ key: TileKey) {
        if let i = tileOrder.firstIndex(of: key) {
            tileOrder.remove(at: i)
            tileOrder.append(key)
        }
    }

    private func store(_ tile: StreamedTile, for key: TileKey) {
        if let existing = tileCache[key] { cachedBytes -= existing.storage.length }
        tileCache[key] = tile
        tileOrder.removeAll { $0 == key }
        tileOrder.append(key)
        cachedBytes += tile.storage.length
        while cachedBytes > Self.tileCacheBytes, let oldest = tileOrder.first {
            tileOrder.removeFirst()
            if let evicted = tileCache.removeValue(forKey: oldest) { cachedBytes -= evicted.storage.length }
        }
    }

    // MARK: - Resampled rasters

    /// A `width x height` raster over `region`'s Mercator footprint, from the
    /// newest product covering it, with up to two older products filling its
    /// voids. Samples land in page-aligned storage the GPU can adopt.
    public func elevationRaster(for region: GeoRegion, width: Int, height: Int, overviewLevel: Int = 0) async -> StreamedRaster? {
        guard width > 1, height > 1, let storage = COGMappedStorage(length: width * height * 4) else { return nil }
        let output = storage.pointer.bindMemory(to: Float.self, capacity: width * height)
        output.initialize(repeating: .nan, count: width * height)

        var contributor: DEMProduct?
        var written = 0
        for product in await products(covering: region).prefix(3) {
            guard !Task.isCancelled else { return nil }
            guard let geo = await georeference(for: product.url, overviewLevel: overviewLevel) else { continue }
            let needed = geo.tiles(covering: region)
            guard !needed.isEmpty else { continue }

            var fetched: [TileKey: StreamedTile] = [:]
            await withTaskGroup(of: StreamedTile?.self) { group in
                for (column, row) in needed {
                    group.addTask { await self.tile(product: product.url, column: column, row: row, overviewLevel: overviewLevel) }
                }
                for await tile in group {
                    if let tile { fetched[TileKey(product: tile.product, column: tile.column, row: tile.row, overviewLevel: overviewLevel)] = tile }
                }
            }
            guard !fetched.isEmpty else { continue }

            let url = product.url
            let added = withExtendedLifetime(fetched) {
                COGResampler.resample(
                    region: region, width: width, height: height, georeference: geo,
                    into: output, fillOnlyVoids: contributor != nil
                ) { column, row in
                    fetched[TileKey(product: url, column: column, row: row, overviewLevel: overviewLevel)]
                        .map { UnsafePointer($0.storage.pointer.assumingMemoryBound(to: Float.self)) }
                }
            }
            if added > 0 {
                contributor = contributor ?? product
                written += added
            }
            if written == width * height { break }
        }
        guard let contributor, written > 0 else { return nil }
        return StreamedRaster(
            storage: storage, width: width, height: height, region: region, product: contributor,
            validFraction: Double(written) / Double(width * height)
        )
    }

    // MARK: - ElevationProviding

    public static func overviewLevel(forMetersPerPixel mpp: Double) -> Int {
        if mpp < 1.7 {
            return 0 // Level 0: native ~1 m (z18+)
        } else if mpp < 3.2 {
            return 1 // Level 1: overview ~2 m (z17)
        } else {
            return 2 // Level 2: overview ~4 m (z16)
        }
    }

    /// Serves a map tile's raster from the COGs, declining (so a fallback can
    /// answer) when less than half the footprint has 1 m coverage.
    public func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        let m = region.mercatorBounds
        let mpp = (m.maxX - m.minX) / Double(max(targetSamples, 1))
        let level = Self.overviewLevel(forMetersPerPixel: mpp)
        return await elevation(for: region, targetSamples: targetSamples, overviewLevel: level)
    }

    public func elevation(for region: GeoRegion, targetSamples: Int, overviewLevel: Int) async -> Evidence<ElevationGrid> {
        guard Self.coverage.contains(region.center) else { return .unavailable(.noCoverage(.usgs3DEP)) }
        let samples = min(max(targetSamples, 16), Self.maxSamplesPerAxis)
        guard let streamed = await elevationRaster(for: region, width: samples, height: samples, overviewLevel: overviewLevel),
              streamed.validFraction >= 0.5
        else { return .unavailable(.noCoverage(.usgs3DEP)) }
        return .observed(streamed.grid, Provenance(source: .usgs3DEP))
    }
}

/// Tries one elevation source, then another.
///
/// Used to put the COG stream in front of the 3DEP ImageServer: the COG path
/// serves native 1 m samples in a few ranged GETs, and the ImageServer's
/// seamless mosaic still answers wherever no single COG does.
public nonisolated struct FallbackElevationProvider: ElevationProviding {
    public let primary: any ElevationProviding
    public let fallback: any ElevationProviding

    public init(primary: any ElevationProviding, fallback: any ElevationProviding) {
        self.primary = primary
        self.fallback = fallback
    }

    public func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        let first = await primary.elevation(for: region, targetSamples: targetSamples)
        if first.value != nil || Task.isCancelled { return first }
        return await fallback.elevation(for: region, targetSamples: targetSamples)
    }
}
