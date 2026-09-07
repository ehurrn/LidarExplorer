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
            Log.geospatial.debug("Elevation cache hit for \(key, privacy: .public)")
            return .observed(
                cached,
                Provenance(source: .usgs3DEP, servedFromCacheAt: Date())
            )
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

            // Map the no-data sentinel onto NaN so voids stay voids rather
            // than becoming a deep pit in the terrain. The raster's own
            // GDAL_NODATA tag wins when present -- reading what the file
            // declares beats assuming the value we asked for came back.
            let sentinel = raster.noDataValue ?? Self.noDataValue
            var samples = raster.samples
            var voidCount = 0
            for i in samples.indices where samples[i].isNaN || samples[i] <= sentinel + 1 {
                samples[i] = .nan
                voidCount += 1
            }

            // Georeference from the raster itself, not from what was asked
            // for. The service is free to adjust the extent, and an overlay
            // pinned to the requested region rather than the delivered one is
            // simply drawn in the wrong place.
            let actualRegion = Self.region(of: raster) ?? region
            if let served = Self.region(of: raster), !Self.matches(served, region) {
                Log.geospatial.notice(
                    "Served extent differs from request: asked lat \(region.latitudeSpan, format: .fixed(precision: 5))/lon \(region.longitudeSpan, format: .fixed(precision: 5)), got lat \(served.latitudeSpan, format: .fixed(precision: 5))/lon \(served.longitudeSpan, format: .fixed(precision: 5)); using the served extent"
                )
            }

            let grid = ElevationGrid(
                width: raster.width, height: raster.height,
                samples: samples, region: actualRegion
            )

            // Reject an all-void or implausible raster rather than analysing it.
            let stats = grid.statistics()
            guard stats.validCount > 0 else {
                return .unavailable(.noCoverage(.usgs3DEP))
            }
            guard stats.minimum > -500, stats.maximum < 9_000 else {
                let text = String(
                    format: "elevations span %.0f..%.0f m", stats.minimum, stats.maximum
                )
                Log.geospatial.error("3DEP raster implausible: \(text, privacy: .public)")
                return .unavailable(.implausible(.usgs3DEP, description: text))
            }

            store(grid, for: key)
            Log.geospatial.info(
                "3DEP ok: \(raster.width)x\(raster.height), \(voidCount) voids, \(String(format: "%.1f", stats.range)) m relief"
            )
            return .observed(grid, Provenance(source: .usgs3DEP, acquired: nil))
        }
    }

    /// The geographic extent a raster actually covers, per its GeoTIFF tags.
    ///
    /// Handles both geographic degrees (EPSG:4326) and projected metres (EPSG:3857).
    private nonisolated static func region(of raster: FloatTIFFDecoder.Raster) -> GeoRegion? {
        guard let transform = raster.geoTransform else { return nil }
        let bounds = transform.bounds(width: raster.width, height: raster.height)
        // If coordinates exceed 180, they are projected metres (EPSG:3857).
        if abs(bounds.minX) > 180 || abs(bounds.maxX) > 180 {
            let sw = GeoRegion.fromMercatorMeters(x: bounds.minX, y: bounds.minY)
            let ne = GeoRegion.fromMercatorMeters(x: bounds.maxX, y: bounds.maxY)
            return GeoRegion(
                minLatitude: sw.latitude, maxLatitude: ne.latitude,
                minLongitude: sw.longitude, maxLongitude: ne.longitude
            )
        }
        // Guard against an invalid geographic raster: degrees only.
        guard abs(bounds.minY) <= 90, abs(bounds.maxY) <= 90,
              abs(bounds.minX) <= 180, abs(bounds.maxX) <= 180 else { return nil }
        return GeoRegion(
            minLatitude: bounds.minY, maxLatitude: bounds.maxY,
            minLongitude: bounds.minX, maxLongitude: bounds.maxX
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
