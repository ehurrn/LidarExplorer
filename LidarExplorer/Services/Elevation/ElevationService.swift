//
//  ElevationService.swift
//  LidarExplorer
//
//  USGS 3DEP elevation retrieval.
//

import CoreLocation
import Foundation
import os

/// Supplies terrain elevation for a region.
///
/// A protocol so the analysis engine can be exercised against a synthetic
/// provider. The previous design reached a concrete `static let shared`
/// singleton directly from the engine, which is why none of the detection
/// logic could be tested without a live network.
public nonisolated protocol ElevationProviding: Sendable {
    /// Fetches a grid covering `region` at approximately `targetSamples`
    /// across its longest axis.
    func elevation(
        for region: GeoRegion,
        targetSamples: Int
    ) async -> Evidence<ElevationGrid>
}

/// Fetches elevation rasters from the USGS 3DEP ImageServer.
public actor USGS3DEPService: ElevationProviding {

    /// ArcGIS ImageServer export endpoint for the seamless 3DEP mosaic.
    private nonisolated static let endpoint = URL(
        string: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage"
    )!

    /// 3DEP covers the United States and its territories. Outside that the
    /// service answers with an empty raster rather than an error, so the
    /// bounds check has to happen here — otherwise a European region silently
    /// yields a flat grid that the detectors would happily analyse.
    private nonisolated static let coverage = GeoRegion(
        minLatitude: 15.0, maxLatitude: 72.0,
        minLongitude: -179.5, maxLongitude: -64.0
    )

    /// Sentinel the service substitutes for voids, per the request below.
    private nonisolated static let noDataValue: Float = -999_999

    /// Native ground sample distance of the 3DEP mosaic, in metres.
    ///
    /// The service reports `pixelSizeX`/`pixelSizeY` of 1.0. Requesting
    /// coarser than this discards real detail; requesting finer only
    /// resamples and costs memory for nothing.
    public nonisolated static let nativeResolutionMeters = 1.0

    /// Largest raster we will request along either axis.
    ///
    /// The service itself allows 8000x8000, but that is 64M cells: at four
    /// bytes each it is 256 MB for the elevation alone, and the pipeline
    /// holds slope, aspect, multi-directional relief and an RGBA image
    /// besides — well over a gigabyte. 2048 keeps the whole working set near
    /// 100 MB while still reaching native 1 m resolution for any region up
    /// to about 2 km across, which is the range this app is used at.
    private nonisolated static let maxSamplesPerAxis = 2048

    /// Samples needed along the longest axis to reach native resolution.
    ///
    /// Capped, so a large region degrades in resolution rather than
    /// exhausting memory.
    public nonisolated static func samplesForNativeResolution(
        of region: GeoRegion
    ) -> Int {
        let longest = max(region.widthMeters, region.heightMeters)
        guard longest > 0 else { return 256 }
        let ideal = Int((longest / nativeResolutionMeters).rounded())
        return min(max(ideal, 64), maxSamplesPerAxis)
    }

    private let transport: HTTPTransport
    private var cache: [String: ElevationGrid] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 24

    private static let diskCacheDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("usgs-3dep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskFilename(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
           .replacingOccurrences(of: ",", with: "_")
           .replacingOccurrences(of: "@", with: "_") + ".tif"
    }

    public init(transport: HTTPTransport = .shared) {
        self.transport = transport
    }

    public func elevation(
        for region: GeoRegion,
        targetSamples: Int = 256
    ) async -> Evidence<ElevationGrid> {

        guard Self.coverage.contains(region.center) else {
            Log.geospatial.info("Region outside 3DEP coverage; declining to fetch.")
            return .unavailable(.noCoverage(.usgs3DEP))
        }

        let key = "\(region.cacheKey)@\(targetSamples)"
        if let cached = cache[key] {
            Log.geospatial.debug("Elevation memory cache hit for \(key, privacy: .public)")
            return .observed(
                cached,
                Provenance(source: .usgs3DEP, servedFromCacheAt: Date())
            )
        }

        // Check persistent disk cache before network fetch
        if let diskDir = Self.diskCacheDirectory {
            let fileURL = diskDir.appendingPathComponent(Self.diskFilename(for: key))
            if let diskData = try? Data(contentsOf: fileURL),
               let raster = try? FloatTIFFDecoder.decode(diskData) {
                switch Self.makeGrid(from: raster, requestedRegion: region) {
                case .success(let grid):
                    store(grid, for: key)
                    Log.geospatial.debug("Elevation disk cache hit for \(key, privacy: .public)")
                    return .observed(
                        grid,
                        Provenance(source: .usgs3DEP, servedFromCacheAt: Date())
                    )
                case .failure:
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }

        // Size the request in Web Mercator (EPSG:3857) projected metres.
        // In EPSG:3857, tile bounds are inherently square, matching MKTileOverlay
        // and basemaps precisely and eliminating non-uniform vertical stretching.
        let samples = min(max(targetSamples, 16), Self.maxSamplesPerAxis)
        let m = region.mercatorBounds

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "bbox", value: "\(m.minX),\(m.minY),\(m.maxX),\(m.maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "\(samples),\(samples)"),
            .init(name: "format", value: "tiff"),
            .init(name: "pixelType", value: "F32"),
            .init(name: "noData", value: "\(Int(Self.noDataValue))"),
            .init(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            .init(name: "interpolation", value: "RSP_BilinearInterpolation"),
            .init(name: "f", value: "image"),
        ]

        guard let url = components.url else {
            return .unavailable(.transportFailure(.usgs3DEP, description: "could not build request URL"))
        }

        Log.geospatial.info("Fetching 3DEP \(samples)x\(samples) for \(region.cacheKey, privacy: .public)")

        let result = await transport.data(for: URLRequest(url: url))

        switch result {
        case .failure(let error):
            Log.geospatial.error("3DEP fetch failed: \(error.description, privacy: .public)")
            return .unavailable(.transportFailure(.usgs3DEP, description: error.description))

        case .success(let data):
            let raster: FloatTIFFDecoder.Raster
            do {
                raster = try FloatTIFFDecoder.decode(data)
            } catch {
                let text = (error as? FloatTIFFDecoder.DecodeError)?.description
                    ?? error.localizedDescription
                Log.geospatial.error("3DEP raster undecodable: \(text, privacy: .public)")
                return .unavailable(.undecodable(.usgs3DEP, description: text))
            }

            switch Self.makeGrid(from: raster, requestedRegion: region) {
            case .success(let grid):
                store(grid, for: key)
                if let diskDir = Self.diskCacheDirectory {
                    let fileURL = diskDir.appendingPathComponent(Self.diskFilename(for: key))
                    Task.detached(priority: .utility) {
                        try? data.write(to: fileURL, options: .atomic)
                    }
                }
                return .observed(grid, Provenance(source: .usgs3DEP, acquired: nil))
            case .failure(let reason):
                return .unavailable(reason)
            }
        }
    }

    private enum GridOutcome {
        case success(ElevationGrid)
        case failure(UnavailableReason)
    }

    private static func makeGrid(
        from raster: FloatTIFFDecoder.Raster,
        requestedRegion: GeoRegion
    ) -> GridOutcome {
        let sentinel = raster.noDataValue ?? Self.noDataValue
        var samples = raster.samples
        var voidCount = 0
        for i in samples.indices where samples[i].isNaN || samples[i] <= sentinel + 1 {
            samples[i] = .nan
            voidCount += 1
        }

        let actualRegion = Self.region(of: raster) ?? requestedRegion
        if let served = Self.region(of: raster), !Self.matches(served, requestedRegion) {
            Log.geospatial.notice(
                "Served extent differs from request: asked lat \(requestedRegion.latitudeSpan, format: .fixed(precision: 5))/lon \(requestedRegion.longitudeSpan, format: .fixed(precision: 5)), got lat \(served.latitudeSpan, format: .fixed(precision: 5))/lon \(served.longitudeSpan, format: .fixed(precision: 5)); using the served extent"
            )
        }

        let grid = ElevationGrid(
            width: raster.width, height: raster.height,
            samples: samples, region: actualRegion
        )

        let stats = grid.statistics()
        guard stats.validCount > 0 else {
            return .failure(.noCoverage(.usgs3DEP))
        }
        guard stats.minimum > -500, stats.maximum < 9_000 else {
            let text = String(
                format: "elevations span %.0f..%.0f m", stats.minimum, stats.maximum
            )
            Log.geospatial.error("3DEP raster implausible: \(text, privacy: .public)")
            return .failure(.implausible(.usgs3DEP, description: text))
        }
        Log.geospatial.info(
            "3DEP ok: \(raster.width)x\(raster.height), \(voidCount) voids, \(String(format: "%.1f", stats.range)) m relief"
        )
        return .success(grid)
    }

    /// The geographic extent a raster actually covers, per its GeoTIFF tags.
    ///
    /// Since we always request `imageSR=3857`, the returned GeoTIFF
    /// coordinates are Web Mercator projected metres. We convert them back
    /// to WGS-84 degrees for internal use.
    private nonisolated static func region(of raster: FloatTIFFDecoder.Raster) -> GeoRegion? {
        guard let transform = raster.geoTransform else { return nil }
        let bounds = transform.bounds(width: raster.width, height: raster.height)
        // Convert projected metres (EPSG:3857) back to geographic degrees.
        let sw = GeoRegion.fromMercatorMeters(x: bounds.minX, y: bounds.minY)
        let ne = GeoRegion.fromMercatorMeters(x: bounds.maxX, y: bounds.maxY)
        return GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
    }

    /// Whether two extents agree to well under one pixel at these scales.
    private nonisolated static func matches(_ a: GeoRegion, _ b: GeoRegion) -> Bool {
        let tolerance = 1e-6
        return abs(a.minLatitude - b.minLatitude) < tolerance
            && abs(a.maxLatitude - b.maxLatitude) < tolerance
            && abs(a.minLongitude - b.minLongitude) < tolerance
            && abs(a.maxLongitude - b.maxLongitude) < tolerance
    }

    /// Inserts into a small LRU so panning back to a region is instant.
    private func store(_ grid: ElevationGrid, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = grid
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
