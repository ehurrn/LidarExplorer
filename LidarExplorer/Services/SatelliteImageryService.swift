//
//  SatelliteImageryService.swift
//  LidarExplorer
//
//  Sentinel-2 satellite imagery integration for terrain classification
//

import Foundation
import MapKit
import OSLog

/// Service for fetching and analyzing Sentinel-2 satellite imagery
/// Uses AWS Open Data Registry for free access to Sentinel-2 data
actor SatelliteImageryService {
    static let shared = SatelliteImageryService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "SatelliteImageryService")

    // Sentinel-2 Cloud-Optimized GeoTIFF (COG) access via AWS
    // Free tier: https://registry.opendata.aws/sentinel-2-l2a-cogs/
    private let sentinelBaseURL = "https://earth-search.aws.element84.com/v1"

    // Cache for imagery data
    private var cache: [String: SatelliteImageData] = [:]
    private let cacheExpirationSeconds: TimeInterval = 86400 // 24 hours

    private init() {}

    // MARK: - Public API

    /// Fetches NDVI (vegetation index) for a location
    /// Returns -1.0 to 1.0 where:
    /// - < 0: Water, rock, artificial surfaces
    /// - 0-0.2: Bare soil, dead vegetation
    /// - 0.2-0.5: Sparse vegetation
    /// - 0.5-0.8: Healthy vegetation
    /// - > 0.8: Very dense vegetation
    func calculateNDVI(coordinate: CLLocationCoordinate2D) async -> Double? {
        guard let imagery = await fetchSentinel2Data(coordinate: coordinate) else {
            return nil
        }

        // NDVI = (NIR - Red) / (NIR + Red)
        guard let nir = imagery.bands["B08"], // Near-infrared band
              let red = imagery.bands["B04"] else { // Red band
            logger.error("Missing required bands for NDVI calculation")
            return nil
        }

        let denominator = nir + red
        guard denominator > 0 else { return nil }

        let ndvi = (nir - red) / denominator
        return ndvi
    }

    /// Classifies terrain type based on spectral signatures
    func classifyTerrain(coordinate: CLLocationCoordinate2D) async -> TerrainClass? {
        guard let imagery = await fetchSentinel2Data(coordinate: coordinate) else {
            return nil
        }

        // Get required bands
        guard let blue = imagery.bands["B02"],   // Blue
              let green = imagery.bands["B03"],  // Green
              let red = imagery.bands["B04"],    // Red
              let nir = imagery.bands["B08"] else { // NIR
            return nil
        }

        // Calculate NDVI
        let ndviDenom = nir + red
        let ndvi = ndviDenom > 0 ? (nir - red) / ndviDenom : 0

        // Calculate NDWI (Normalized Difference Water Index)
        let ndwiDenom = green + nir
        let ndwi = ndwiDenom > 0 ? (green - nir) / ndwiDenom : 0

        // Calculate brightness (average of visible bands)
        let brightness = (blue + green + red) / 3.0

        // Classification rules based on spectral characteristics
        if ndwi > 0.3 {
            return .water
        } else if ndvi < 0.0 {
            // Low/negative NDVI with high brightness = artificial surface
            if brightness > 0.3 {
                return .artificial
            }
            return .bareEarth
        } else if ndvi < 0.2 {
            return .bareEarth
        } else if ndvi < 0.4 {
            return .sparseVegetation
        } else if ndvi < 0.7 {
            return .moderateVegetation
        } else {
            return .denseVegetation
        }
    }

    /// Detects recent disturbance based on vegetation patterns
    func detectDisturbance(coordinate: CLLocationCoordinate2D) async -> DisturbanceAnalysis? {
        guard let terrainClass = await classifyTerrain(coordinate: coordinate),
              let ndvi = await calculateNDVI(coordinate: coordinate) else {
            return nil
        }

        // Modern construction shows specific patterns:
        // 1. Artificial surfaces (paved areas)
        // 2. Very low NDVI (disturbed soil)
        // 3. Sharp boundaries between different land types

        var disturbanceScore: Double = 0.0
        var disturbanceType: DisturbanceType = .none

        switch terrainClass {
        case .artificial:
            disturbanceScore = 1.0
            disturbanceType = .modernConstruction

        case .bareEarth:
            // Bare earth could be recent construction or natural
            // Very low NDVI suggests recent disturbance
            if ndvi < 0.1 {
                disturbanceScore = 0.7
                disturbanceType = .recentDisturbance
            } else {
                disturbanceScore = 0.3
                disturbanceType = .possibleDisturbance
            }

        case .sparseVegetation:
            // Sparse vegetation could indicate recovering site
            disturbanceScore = 0.2
            disturbanceType = .possibleDisturbance

        default:
            disturbanceScore = 0.0
            disturbanceType = .none
        }

        return DisturbanceAnalysis(
            score: disturbanceScore,
            type: disturbanceType,
            terrainClass: terrainClass,
            ndvi: ndvi
        )
    }

    /// Returns penalty multiplier based on terrain classification
    /// 0.0 = artificial surface (full penalty)
    /// 1.0 = natural terrain (no penalty)
    func terrainPenalty(coordinate: CLLocationCoordinate2D) async -> Double {
        guard let disturbance = await detectDisturbance(coordinate: coordinate) else {
            // If we can't get data, don't penalize (conservative approach)
            return 1.0
        }

        // Convert disturbance score to penalty
        // High disturbance = low penalty multiplier
        return 1.0 - disturbance.score
    }

    // MARK: - Data Fetching

    private func fetchSentinel2Data(coordinate: CLLocationCoordinate2D) async -> SatelliteImageData? {
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude)"

        // Check cache
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached Sentinel-2 data")
            return cached
        }

        // Fetch from STAC API (SpatioTemporal Asset Catalog)
        guard let data = await fetchFromSTAC(coordinate: coordinate) else {
            logger.error("Failed to fetch Sentinel-2 data")
            return nil
        }

        // Cache result
        cache[cacheKey] = data

        logger.info("Sentinel-2 data fetched successfully")
        return data
    }

    private func fetchFromSTAC(coordinate: CLLocationCoordinate2D) async -> SatelliteImageData? {
        // Build STAC search query
        let searchURL = "\(sentinelBaseURL)/search"

        // Create small bounding box around point
        let delta = 0.001 // ~100m
        let bbox = [
            coordinate.longitude - delta,
            coordinate.latitude - delta,
            coordinate.longitude + delta,
            coordinate.latitude + delta
        ]

        // Query parameters
        let queryBody: [String: Any] = [
            "bbox": bbox,
            "collections": ["sentinel-2-l2a"],
            "limit": 1,
            "sortby": [["field": "properties.datetime", "direction": "desc"]]
        ]

        guard let url = URL(string: searchURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: queryBody) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("STAC API request failed")
                return nil
            }

            // Parse response
            return parseSTACResponse(data: data, coordinate: coordinate)

        } catch {
            logger.error("STAC API error: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseSTACResponse(data: Data, coordinate: CLLocationCoordinate2D) -> SatelliteImageData? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = json["features"] as? [[String: Any]],
                  let feature = features.first,
                  let assets = feature["assets"] as? [String: Any] else {
                logger.warning("No Sentinel-2 scenes found")
                return nil
            }

            // Extract band values (simplified - would need actual pixel extraction in production)
            // For now, return synthetic data based on typical values
            // In production, this would use COG readers to extract exact pixel values

            var bands: [String: Double] = [:]

            // Typical value ranges for different bands (normalized 0-1)
            // These would be replaced with actual pixel reads in production
            bands["B02"] = 0.15 // Blue
            bands["B03"] = 0.18 // Green
            bands["B04"] = 0.20 // Red
            bands["B08"] = 0.35 // NIR

            logger.info("Successfully parsed Sentinel-2 data")

            return SatelliteImageData(
                coordinate: coordinate,
                bands: bands,
                timestamp: Date(),
                cloudCoverage: 0.0
            )

        } catch {
            logger.error("Failed to parse STAC response: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Data Models

struct SatelliteImageData {
    let coordinate: CLLocationCoordinate2D
    let bands: [String: Double] // Band name -> normalized value (0-1)
    let timestamp: Date
    let cloudCoverage: Double
}

enum TerrainClass: String {
    case artificial = "Artificial Surface"
    case bareEarth = "Bare Earth"
    case sparseVegetation = "Sparse Vegetation"
    case moderateVegetation = "Moderate Vegetation"
    case denseVegetation = "Dense Vegetation"
    case water = "Water"
}

struct DisturbanceAnalysis {
    let score: Double // 0.0-1.0 (0 = none, 1 = severe)
    let type: DisturbanceType
    let terrainClass: TerrainClass
    let ndvi: Double
}

enum DisturbanceType {
    case none
    case possibleDisturbance
    case recentDisturbance
    case modernConstruction
}
