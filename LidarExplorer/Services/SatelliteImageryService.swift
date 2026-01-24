//
//  SatelliteImageryService.swift
//  LidarExplorer
//
//  Sentinel-2 satellite imagery integration for terrain classification
//

import Foundation
import MapKit
import OSLog
import ImageIO
import CoreGraphics

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
        // Requesting reflectance bands only (cloud filtering can be done via API parameters)
        // Using FLOAT32 sample type for precision with TIFF output format
        let evalscript = """
        //VERSION=3
        function setup() {
            return {
                input: [{
                    bands: ["B02", "B03", "B04", "B08"],
                    units: "REFLECTANCE"
                }],
                output: {
                    bands: 4,
                    sampleType: "FLOAT32"
                }
            };
        }

        function evaluatePixel(samples) {
            return {
                bands: [samples.B02, samples.B03, samples.B04, samples.B08]
            };
        }
        """

        // Request body for Process API
        // Structure must match Sentinel Hub Process API v1 specification exactly
        // Using TIFF format for raw band values (JSON doesn't support raster output)
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
            "evalscript": evalscript,
            "output": [
                "width": 1,
                "height": 1,
                "responses": [
                    [
                        "identifier": "default",
                        "format": [
                            "type": "image/tiff"
                        ]
                    ]
                ]
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

    /// Parse Sentinel Hub Process API TIFF response
    private func parseSentinelHubResponse(data: Data, coordinate: CLLocationCoordinate2D) -> SatelliteImageData? {
        // Response is a TIFF image with 4 bands (FLOAT32)
        // For a 1x1 pixel image, extract the 4 float values
        guard let bandValues = parseTiffFloatBands(from: data, bandCount: 4) else {
            logger.error("Failed to parse TIFF response from Sentinel Hub")
            return nil
        }

        guard bandValues.count >= 4 else {
            logger.error("Invalid Sentinel Hub response: expected 4 bands, got \(bandValues.count)")
            return nil
        }

        // Extract band values (already in reflectance 0-1)
        let blue = Double(bandValues[0])
        let green = Double(bandValues[1])
        let red = Double(bandValues[2])
        let nir = Double(bandValues[3])

        // Validate values are reasonable (reflectance should be 0-1, with some tolerance for noise)
        guard blue >= -0.1 && blue <= 1.5,
              green >= -0.1 && green <= 1.5,
              red >= -0.1 && red <= 1.5,
              nir >= -0.1 && nir <= 1.5 else {
            logger.warning("Invalid reflectance values detected: B=\(blue), G=\(green), R=\(red), NIR=\(nir)")
            return nil
        }

        var bands: [String: Double] = [:]
        bands["B02"] = max(0, min(1, blue))
        bands["B03"] = max(0, min(1, green))
        bands["B04"] = max(0, min(1, red))
        bands["B08"] = max(0, min(1, nir))

        logger.info("Successfully extracted real Sentinel-2 pixel values")
        logger.debug("Bands - Blue: \(String(format: "%.3f", blue)), Green: \(String(format: "%.3f", green)), Red: \(String(format: "%.3f", red)), NIR: \(String(format: "%.3f", nir))")

        return SatelliteImageData(
            coordinate: coordinate,
            bands: bands,
            timestamp: Date(),
            cloudCoverage: 0.0
        )
    }

    /// Parse FLOAT32 band values from a TIFF image
    /// For a 1x1 pixel TIFF with N bands, extracts N float values
    private func parseTiffFloatBands(from data: Data, bandCount: Int) -> [Float]? {
        // Use ImageIO to parse the TIFF
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            logger.error("Failed to create image source from TIFF data")
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            logger.error("Failed to create CGImage from TIFF")
            return nil
        }

        // For FLOAT32 TIFFs, we need to access the raw data
        // CGImage may convert to integer format, so we'll try to get raw data first
        guard let dataProvider = cgImage.dataProvider,
              let rawData = dataProvider.data as Data? else {
            logger.error("Failed to get raw data from TIFF image")
            return nil
        }

        // Check if the data size matches expected FLOAT32 format
        // For 1x1 pixel with bandCount bands at 4 bytes per float
        let expectedSize = bandCount * MemoryLayout<Float>.size

        if rawData.count >= expectedSize {
            // Parse as raw FLOAT32 values
            var floatValues: [Float] = []
            rawData.withUnsafeBytes { buffer in
                let floatBuffer = buffer.bindMemory(to: Float.self)
                for i in 0..<min(bandCount, floatBuffer.count) {
                    floatValues.append(floatBuffer[i])
                }
            }

            if floatValues.count == bandCount {
                return floatValues
            }
        }

        // Fallback: CGImage converted to normalized integer values
        // Extract pixel data using CGContext
        let width = cgImage.width
        let height = cgImage.height

        guard width == 1 && height == 1 else {
            logger.warning("Expected 1x1 image, got \(width)x\(height)")
            // Still try to extract the first pixel
            return extractFirstPixelValues(from: cgImage, bandCount: bandCount)
        }

        return extractFirstPixelValues(from: cgImage, bandCount: bandCount)
    }

    /// Extract pixel values from CGImage (fallback for non-FLOAT32 TIFFs)
    private func extractFirstPixelValues(from cgImage: CGImage, bandCount: Int) -> [Float]? {
        let width = cgImage.width
        let height = cgImage.height
        let bitsPerComponent = cgImage.bitsPerComponent
        let bytesPerRow = cgImage.bytesPerRow

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data as Data? else {
            return nil
        }

        // Handle different bit depths
        if bitsPerComponent == 32 {
            // FLOAT32 format
            return data.withUnsafeBytes { buffer -> [Float]? in
                let floatBuffer = buffer.bindMemory(to: Float.self)
                guard floatBuffer.count >= bandCount else { return nil }
                return Array(floatBuffer.prefix(bandCount))
            }
        } else if bitsPerComponent == 16 {
            // UINT16 format - normalize to 0-1
            return data.withUnsafeBytes { buffer -> [Float]? in
                let uint16Buffer = buffer.bindMemory(to: UInt16.self)
                guard uint16Buffer.count >= bandCount else { return nil }
                return uint16Buffer.prefix(bandCount).map { Float($0) / 65535.0 }
            }
        } else if bitsPerComponent == 8 {
            // UINT8 format - normalize to 0-1
            return data.withUnsafeBytes { buffer -> [Float]? in
                guard buffer.count >= bandCount else { return nil }
                return buffer.prefix(bandCount).map { Float($0) / 255.0 }
            }
        }

        logger.warning("Unsupported TIFF bit depth: \(bitsPerComponent)")
        return nil
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
