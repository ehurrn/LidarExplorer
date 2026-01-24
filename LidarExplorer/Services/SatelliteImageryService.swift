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
/// Uses Copernicus Data Space Ecosystem (free tier) for Sentinel Hub API access
actor SatelliteImageryService {
    static let shared = SatelliteImageryService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "SatelliteImageryService")

    // Copernicus Data Space Ecosystem - Sentinel Hub API
    // Free tier: 12TB/month transfer, generous request limits
    // Documentation: https://documentation.dataspace.copernicus.eu/
    private let sentinelHubBaseURL = "https://sh.dataspace.copernicus.eu"
    private let oauthTokenURL = "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token"

    // OAuth credentials - To be configured
    // Users can sign up for free at https://dataspace.copernicus.eu/
    private var clientId: String?
    private var clientSecret: String?

    // Authentication token management
    private var accessToken: String?
    private var tokenExpiration: Date?

    // Cache for imagery data
    private var cache: [String: SatelliteImageData] = [:]
    private let cacheExpirationSeconds: TimeInterval = 86400 // 24 hours

    private init() {
        // Load credentials from configuration if available
        loadCredentials()
    }

    // MARK: - Configuration

    /// Load OAuth credentials from environment or configuration
    private func loadCredentials() {
        // Try loading from environment variables (development/debug builds)
        clientId = ProcessInfo.processInfo.environment["COPERNICUS_CLIENT_ID"]
        clientSecret = ProcessInfo.processInfo.environment["COPERNICUS_CLIENT_SECRET"]

        // If not found in environment, try loading from Info.plist (release builds)
        if clientId == nil {
            clientId = Bundle.main.object(forInfoDictionaryKey: "COPERNICUS_CLIENT_ID") as? String
        }
        if clientSecret == nil {
            clientSecret = Bundle.main.object(forInfoDictionaryKey: "COPERNICUS_CLIENT_SECRET") as? String
        }

        if clientId == nil || clientSecret == nil {
            logger.warning("Copernicus credentials not configured. Using fallback mode with limited functionality.")
            logger.info("To enable full functionality, sign up at https://dataspace.copernicus.eu/ and configure credentials")
            logger.info("See SENTINEL_HUB_SETUP.md for configuration instructions")
        } else {
            logger.info("Copernicus credentials loaded successfully")
        }
    }

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

    // MARK: - Authentication

    /// Get or refresh OAuth access token
    private func getAccessToken() async -> String? {
        // Check if we have a valid token
        if let token = accessToken,
           let expiration = tokenExpiration,
           Date() < expiration {
            return token
        }

        // Need to authenticate
        guard let clientId = clientId, let clientSecret = clientSecret else {
            logger.warning("OAuth credentials not configured")
            return nil
        }

        // Build token request
        guard let url = URL(string: oauthTokenURL) else {
            logger.error("Invalid OAuth URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // OAuth2 client credentials grant
        let bodyString = "grant_type=client_credentials&client_id=\(clientId)&client_secret=\(clientSecret)"
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("OAuth authentication failed")
                return nil
            }

            // Parse token response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["access_token"] as? String,
               let expiresIn = json["expires_in"] as? Int {

                accessToken = token
                tokenExpiration = Date().addingTimeInterval(TimeInterval(expiresIn - 60)) // Refresh 1 min early

                logger.info("Successfully authenticated with Copernicus")
                return token
            }

        } catch {
            logger.error("OAuth error: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Data Fetching

    private func fetchSentinel2Data(coordinate: CLLocationCoordinate2D) async -> SatelliteImageData? {
        // Round coordinates to reduce cache granularity (10m precision ~ 0.0001 degrees)
        let roundedLat = round(coordinate.latitude * 10000) / 10000
        let roundedLon = round(coordinate.longitude * 10000) / 10000
        let cacheKey = "\(roundedLat),\(roundedLon)"

        // Check cache
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached Sentinel-2 data")
            return cached
        }

        // Try to fetch from Sentinel Hub API
        if let data = await fetchFromSentinelHub(coordinate: coordinate) {
            cache[cacheKey] = data
            logger.info("Sentinel-2 data fetched successfully via Sentinel Hub")
            return data
        }

        // Fallback to estimated values based on typical terrain
        logger.warning("Falling back to estimated values (configure API credentials for real data)")
        let fallbackData = generateFallbackData(coordinate: coordinate)
        cache[cacheKey] = fallbackData
        return fallbackData
    }

    /// Fetch pixel values from Sentinel Hub Process API
    private func fetchFromSentinelHub(coordinate: CLLocationCoordinate2D) async -> SatelliteImageData? {
        guard let token = await getAccessToken() else {
            logger.warning("No access token available")
            return nil
        }

        // Use Statistical API instead of Process API for pixel value extraction
        // Statistical API is designed for extracting values and returns JSON natively
        let statisticalURL = "\(sentinelHubBaseURL)/api/v1/statistics"

        guard let url = URL(string: statisticalURL) else {
            logger.error("Invalid Sentinel Hub URL")
            return nil
        }

        // Create a small bounding box (10m x 10m around point)
        let delta = 0.00009 // ~10 meters
        let bbox = [
            coordinate.longitude - delta,
            coordinate.latitude - delta,
            coordinate.longitude + delta,
            coordinate.latitude + delta
        ]

        // Evalscript to extract band values
        let evalscript = """
        //VERSION=3
        function setup() {
            return {
                input: [{
                    bands: ["B02", "B03", "B04", "B08"],
                    units: "REFLECTANCE"
                }],
                output: [
                    {
                        id: "bands",
                        bands: 4
                    }
                ]
            };
        }

        function evaluatePixel(samples) {
            return {
                bands: [samples.B02, samples.B03, samples.B04, samples.B08]
            };
        }
        """

        // Request body for Statistical API
        let requestBody: [String: Any] = [
            "input": [
                "bounds": [
                    "bbox": bbox,
                    "properties": [
                        "crs": "http://www.opengis.net/def/crs/EPSG/0/4326"
                    ]
                ],
                "data": [
                    [
                        "type": "sentinel-2-l2a",
                        "dataFilter": [
                            "timeRange": [
                                "from": getRecentDate(daysAgo: 30),
                                "to": getCurrentDate()
                            ]
                        ]
                    ]
                ]
            ],
            "aggregation": [
                "timeRange": [
                    "from": getRecentDate(daysAgo: 30),
                    "to": getCurrentDate()
                ],
                "aggregationInterval": [
                    "of": "P1D"
                ],
                "evalscript": evalscript
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted) else {
            logger.error("Failed to serialize request body")
            return nil
        }

        // Debug: Log the request body to verify structure
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            logger.debug("Statistical API request body: \(bodyString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response from Sentinel Hub")
                return nil
            }

            if httpResponse.statusCode == 200 {
                return parseStatisticalResponse(data: data, coordinate: coordinate)
            } else {
                logger.error("Sentinel Hub API error: HTTP \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    logger.debug("Error response: \(errorString)")
                }
                return nil
            }

        } catch {
            logger.error("Sentinel Hub API error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse Sentinel Hub Statistical API response
    private func parseStatisticalResponse(data: Data, coordinate: CLLocationCoordinate2D) -> SatelliteImageData? {
        do {
            // Statistical API returns data with statistics per interval
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArray = json["data"] as? [[String: Any]],
                  let firstInterval = dataArray.first,
                  let outputs = firstInterval["outputs"] as? [String: Any],
                  let bandsData = outputs["bands"] as? [String: Any],
                  let bands = bandsData["bands"] as? [String: Any],
                  let meanBands = bands["B0"] as? [String: Any],
                  let mean = meanBands["mean"] as? [Double],
                  mean.count >= 4 else {
                logger.error("Invalid Statistical API response format")
                // Log the actual response for debugging
                if let responseString = String(data: data, encoding: .utf8) {
                    logger.debug("Response: \(responseString)")
                }
                return nil
            }

            // Extract band values (mean reflectance from the small area)
            let blue = mean[0]
            let green = mean[1]
            let red = mean[2]
            let nir = mean[3]

            // Validate values are reasonable (reflectance should be 0-1)
            guard blue >= 0 && blue <= 1,
                  green >= 0 && green <= 1,
                  red >= 0 && red <= 1,
                  nir >= 0 && nir <= 1 else {
                logger.warning("Invalid reflectance values detected")
                return nil
            }

            var bandDict: [String: Double] = [:]
            bandDict["B02"] = blue
            bandDict["B03"] = green
            bandDict["B04"] = red
            bandDict["B08"] = nir

            logger.info("Successfully extracted real Sentinel-2 pixel values")
            logger.debug("Bands - Blue: \(String(format: "%.3f", blue)), Green: \(String(format: "%.3f", green)), Red: \(String(format: "%.3f", red)), NIR: \(String(format: "%.3f", nir))")

            return SatelliteImageData(
                coordinate: coordinate,
                bands: bandDict,
                timestamp: Date(),
                cloudCoverage: 0.0
            )

        } catch {
            logger.error("Failed to parse Statistical API response: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate fallback data when API is unavailable
    /// Uses estimated values based on typical terrain signatures
    private func generateFallbackData(coordinate: CLLocationCoordinate2D) -> SatelliteImageData {
        // Generate conservative estimates
        // These are typical values for moderately vegetated terrain
        var bands: [String: Double] = [:]
        bands["B02"] = 0.08  // Blue
        bands["B03"] = 0.10  // Green
        bands["B04"] = 0.08  // Red
        bands["B08"] = 0.30  // NIR

        return SatelliteImageData(
            coordinate: coordinate,
            bands: bands,
            timestamp: Date(),
            cloudCoverage: 0.0
        )
    }

    // MARK: - Helper Methods

    private func getCurrentDate() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private func getRecentDate(daysAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return formatter.string(from: date)
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
