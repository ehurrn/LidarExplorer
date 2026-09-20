//
//  TerrainHarvestSource.swift
//  LidarExplorer
//
//  Lets the offline harvester fill the terrain provider's disk cache, under the keys the renderer reads.
//

import Foundation
import ImageIO

public nonisolated struct TerrainElevationHarvestSource: HarvestTileSource {
    let provider: TerrainTileProvider

    /// The padded raster's size, for a 3DEP tile. A Terrarium tile below z16 is a 256 px source and weighs less,
    /// so a job's estimate is an upper bound.
    public func estimatedBytesPerTile(pixels: Int) -> Int64 {
        let side = pixels + 2 * TerrainTileProvider.marginPixels
        return Int64(ElevationGridCoder.encodedByteCount(width: side, height: side))
    }

    public func harvest(_ tile: HarvestTile, pixels: Int) async -> HarvestTileOutcome {
        await provider.harvestTile(x: tile.x, y: tile.y, z: tile.z, pixels: pixels)
    }
}

/// Stores USGS basemap tiles where ``HillshadeTileOverlay`` looks for them before it tries the network.
///
/// Only the USGS services can be harvested. Apple's imagery is drawn by MapKit, which offers no way to keep it.
public nonisolated struct BasemapHarvestSource: HarvestTileSource {
    let basemap: TerrainBasemap
    let cache: TileDiskCache
    let session: URLSession

    public init(basemap: TerrainBasemap, cache: TileDiskCache = HillshadeTileOverlay.sharedHarvestedTiles,
                session: URLSession = BasemapHarvestSource.makeSession()) {
        self.basemap = basemap
        self.cache = cache
        self.session = session
    }

    /// A session that goes to the network every time: the tile is about to be kept on disk by this app, and a
    /// second copy in the URL cache would only spend the same bytes twice.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = OfflineHarvestCoordinator.defaultConcurrency
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "LidarExplorer/1.0 (github.com/ehurrn/LidarExplorer)"]
        return URLSession(configuration: config)
    }

    /// An average: 256 px USGS tiles run from a few KB of plain relief to ~50 KB of imagery.
    public static let averageTileBytes: Int64 = 30_000

    public func estimatedBytesPerTile(pixels: Int) -> Int64 { Self.averageTileBytes }

    public func harvest(_ tile: HarvestTile, pixels: Int) async -> HarvestTileOutcome {
        // Past the service's depth the overlay slices its deepest tile, so that is the one to keep.
        let excess = max(tile.z - basemap.maximumZ, 0)
        let source = HarvestTile(x: tile.x >> excess, y: tile.y >> excess, z: tile.z - excess)
        let key = TerrainBasemap.harvestKey(basemap, source)
        if await cache.contains(forKey: key) { return .alreadyCached }
        guard let url = basemap.tileURL(x: source.x, y: source.y, z: source.z) else {
            return .failed(reason: "no URL for the tile")
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            // A captive portal answers 200 with a web page. Keeping it would put a broken tile on the map
            // that no later fetch replaces.
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else {
                return .failed(reason: "the response was not an image")
            }
            guard !Task.isCancelled else { return .failed(reason: "cancelled") }
            guard await cache.write(data, forKey: key) else {
                return .failed(reason: "the disk cache could not be written")
            }
            return .stored(bytes: data.count)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
