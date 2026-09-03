//
//  ElevationService.swift
//  LidarExplorer
//
//  USGS 3DEP elevation retrieval.
//

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

    /// Largest raster the ImageServer will return in one call.
    private nonisolated static let maxSamplesPerAxis = 2048

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

        // Preserve ground aspect ratio so cells stay close to square.
        let samples = min(max(targetSamples, 16), Self.maxSamplesPerAxis)
        let aspect = region.widthMeters > 0 && region.heightMeters > 0
            ? region.widthMeters / region.heightMeters : 1
        let width = aspect >= 1 ? samples : max(Int(Double(samples) * aspect), 16)
        let height = aspect >= 1 ? max(Int(Double(samples) / aspect), 16) : samples

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "bbox", value: "\(region.minLongitude),\(region.minLatitude),\(region.maxLongitude),\(region.maxLatitude)"),
            .init(name: "bboxSR", value: "4326"),
            .init(name: "imageSR", value: "4326"),
            .init(name: "size", value: "\(width),\(height)"),
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

        Log.geospatial.info("Fetching 3DEP \(width)x\(height) for \(region.cacheKey, privacy: .public)")

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

            let grid = ElevationGrid(
                width: raster.width, height: raster.height,
                samples: samples, region: region
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
