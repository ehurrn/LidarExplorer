//
//  DEMDataService.swift
//  LidarExplorer
//
//  Service to fetch real elevation data from USGS 3DEP Elevation API
//

import Foundation
import MapKit
import OSLog

/// Service for fetching Digital Elevation Model (DEM) data from USGS 3DEP
actor DEMDataService {
    static let shared = DEMDataService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "DEMDataService")

    // MARK: - Configuration Constants

    private enum APIConfiguration {
        static let maximumResolution = 50 // Maximum grid resolution for API efficiency
        static let defaultResolution = 100 // Default resolution before clamping
        static let batchSize = 100 // Number of points to fetch per batch
    }

    private init() {}

    /// Fetches elevation data for a given map region from USGS 3DEP
    /// - Parameters:
    ///   - region: The map region to fetch elevation data for
    ///   - resolution: Desired grid resolution (clamped for API efficiency)
    /// - Returns: 2D array of elevation values in meters
    func fetchElevationData(
        for region: MKCoordinateRegion,
        resolution: Int = APIConfiguration.defaultResolution
    ) async throws -> [[Double]] {

        // Use a smaller resolution for point queries to avoid too many API calls
        // We'll interpolate to the desired resolution later if needed
        let actualResolution = min(resolution, APIConfiguration.maximumResolution)

        logger.info("Fetching DEM data from USGS Elevation Point Query Service")
        logger.debug("Region: \(region.center.latitude), \(region.center.longitude), Resolution: \(actualResolution)x\(actualResolution)")

        // Calculate bounding box from region
        let bbox = calculateBoundingBox(from: region)

        // Create a grid of sample points
        let latStep = (bbox.maxLat - bbox.minLat) / Double(actualResolution - 1)
        let lonStep = (bbox.maxLon - bbox.minLon) / Double(actualResolution - 1)

        // Create all coordinate pairs
        var coordinates: [(row: Int, col: Int, lat: Double, lon: Double)] = []
        for row in 0..<actualResolution {
            let lat = bbox.minLat + (Double(row) * latStep)
            for col in 0..<actualResolution {
                let lon = bbox.minLon + (Double(col) * lonStep)
                coordinates.append((row, col, lat, lon))
            }
        }

        logger.debug("Fetching \(coordinates.count) elevation points in batches")

        // Track success/failure rates
        var successCount = 0
        var failureCount = 0

        // Fetch points in batches to avoid overwhelming the API
        let batchSize = APIConfiguration.batchSize
        var allResults: [Int: [Int: Double]] = [:]

        for batchStart in stride(from: 0, to: coordinates.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, coordinates.count)
            let batch = Array(coordinates[batchStart..<batchEnd])

            // Fetch this batch concurrently
            let batchResults = await withTaskGroup(of: (Int, Int, Double, Bool).self) { group in
                for coord in batch {
                    group.addTask {
                        do {
                            let elevation = try await self.fetchElevationForPoint(lat: coord.lat, lon: coord.lon)
                            return (coord.row, coord.col, elevation, true)
                        } catch {
                            return (coord.row, coord.col, 0.0, false)
                        }
                    }
                }

                var resultDict: [Int: [Int: Double]] = [:]
                var batchSuccesses = 0
                var batchFailures = 0

                for await result in group {
                    if resultDict[result.0] == nil {
                        resultDict[result.0] = [:]
                    }
                    resultDict[result.0]?[result.1] = result.2
                    if result.3 {
                        batchSuccesses += 1
                    } else {
                        batchFailures += 1
                    }
                }

                successCount += batchSuccesses
                failureCount += batchFailures

                return resultDict
            }

            // Merge batch results
            for (row, rowDict) in batchResults {
                if allResults[row] == nil {
                    allResults[row] = [:]
                }
                for (col, elevation) in rowDict {
                    allResults[row]?[col] = elevation
                }
            }

            logger.debug("Progress: \(batchEnd)/\(coordinates.count) points")
        }

        let results = allResults

        // Report success/failure statistics
        logger.info("API Results: \(successCount) successful, \(failureCount) failed")

        // Convert to 2D array
        var elevationData: [[Double]] = []
        for row in 0..<actualResolution {
            var rowData: [Double] = []
            for col in 0..<actualResolution {
                rowData.append(results[row]?[col] ?? 0.0)
            }
            elevationData.append(rowData)
        }

        logger.info("Fetched \(elevationData.count)x\(elevationData.first?.count ?? 0) elevation grid")

        // If we fetched at lower resolution, interpolate to desired resolution
        if actualResolution < resolution {
            logger.debug("Interpolating from \(actualResolution)x\(actualResolution) to \(resolution)x\(resolution)")
            elevationData = interpolateGrid(elevationData, targetSize: resolution)
        }

        return elevationData
    }

    /// Interpolates a grid to a target size using bilinear interpolation
    private func interpolateGrid(_ grid: [[Double]], targetSize: Int) -> [[Double]] {
        let sourceSize = grid.count
        let scale = Double(sourceSize - 1) / Double(targetSize - 1)

        var result: [[Double]] = []

        for i in 0..<targetSize {
            var row: [Double] = []
            for j in 0..<targetSize {
                let sourceI = Double(i) * scale
                let sourceJ = Double(j) * scale

                let i0 = Int(floor(sourceI))
                let i1 = min(i0 + 1, sourceSize - 1)
                let j0 = Int(floor(sourceJ))
                let j1 = min(j0 + 1, sourceSize - 1)

                let di = sourceI - Double(i0)
                let dj = sourceJ - Double(j0)

                // Bilinear interpolation
                let v00 = grid[i0][j0]
                let v01 = grid[i0][j1]
                let v10 = grid[i1][j0]
                let v11 = grid[i1][j1]

                let v0 = v00 * (1 - dj) + v01 * dj
                let v1 = v10 * (1 - dj) + v11 * dj
                let v = v0 * (1 - di) + v1 * di

                row.append(v)
            }
            result.append(row)
        }

        return result
    }

    /// Fetches elevation for a single coordinate point
    private func fetchElevationForPoint(lat: Double, lon: Double) async throws -> Double {
        // Use USGS Elevation Point Query Service
        // API format: https://epqs.nationalmap.gov/v1/json?x={longitude}&y={latitude}&units=Meters
        // includeDate=true provides temporal metadata for future analysis
        let urlString = "https://epqs.nationalmap.gov/v1/json?x=\(lon)&y=\(lat)&units=Meters&wkid=4326&includeDate=true"

        guard let url = URL(string: urlString) else {
            throw DEMError.invalidURL
        }

        // Create request with proper headers
        var request = URLRequest(url: url)
        request.setValue("LidarExplorer/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DEMError.networkError
        }

        // DEBUG: Log raw response for first request to diagnose parsing issues
        var hasLoggedResponse = false
        if !hasLoggedResponse {
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.debug("USGS API Sample Response: \(jsonString)")
            }
            hasLoggedResponse = true
        }

        // Parse the response - EPQS current format (2024+):
        // {"location": {...}, "value": "114.976028442", "rasterId": 110085, ...}
        // NOTE: "value" is returned as a STRING, not a number!
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Current USGS format - value is a STRING that needs conversion
            if let valueString = json["value"] as? String,
               let elevation = Double(valueString) {
                return elevation
            }

            // Fallback: value might be a number in some responses
            if let elevation = json["value"] as? Double {
                return elevation
            }

            // Try alternative USGS format structures
            if let service = json["USGS_Elevation_Point_Query_Service"] as? [String: Any],
               let query = service["Elevation_Query"] as? [String: Any] {
                // Try as number
                if let elevation = query["Elevation"] as? Double {
                    return elevation
                }
                // Try as string
                if let elevString = query["Elevation"] as? String,
                   let elevation = Double(elevString) {
                    return elevation
                }
            }

            // Try legacy array format
            if let valueArray = json["value"] as? [[String: Any]],
               let firstResult = valueArray.first {
                if let elevation = firstResult["value"] as? Double {
                    return elevation
                }
                if let elevString = firstResult["value"] as? String,
                   let elevation = Double(elevString) {
                    return elevation
                }
            }

            // Try "elevation" (lowercase)
            if let elevation = json["elevation"] as? Double {
                return elevation
            }
            if let elevString = json["elevation"] as? String,
               let elevation = Double(elevString) {
                return elevation
            }

            // Try "Elevation" (capitalized)
            if let elevation = json["Elevation"] as? Double {
                return elevation
            }
            if let elevString = json["Elevation"] as? String,
               let elevation = Double(elevString) {
                return elevation
            }
        }

        throw DEMError.parseError
    }

    /// Calculates bounding box from map region
    private func calculateBoundingBox(from region: MKCoordinateRegion) -> BoundingBox {
        let centerLat = region.center.latitude
        let centerLon = region.center.longitude
        let latDelta = region.span.latitudeDelta
        let lonDelta = region.span.longitudeDelta

        return BoundingBox(
            minLon: centerLon - lonDelta / 2,
            minLat: centerLat - latDelta / 2,
            maxLon: centerLon + lonDelta / 2,
            maxLat: centerLat + latDelta / 2
        )
    }

    /// Constructs the USGS 3DEP API URL with parameters
    private func constructAPIURL(bbox: BoundingBox, width: Int, height: Int) -> URL? {
        var components = URLComponents(string: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage")

        // Format bbox as: minLon,minLat,maxLon,maxLat
        let bboxString = "\(bbox.minLon),\(bbox.minLat),\(bbox.maxLon),\(bbox.maxLat)"

        components?.queryItems = [
            URLQueryItem(name: "bbox", value: bboxString),
            URLQueryItem(name: "bboxSR", value: "4326"), // WGS84 spatial reference
            URLQueryItem(name: "size", value: "\(width),\(height)"),
            URLQueryItem(name: "imageSR", value: "4326"),
            URLQueryItem(name: "format", value: "json"), // Use JSON format for easier parsing
            URLQueryItem(name: "pixelType", value: "F32"), // 32-bit float for elevation
            URLQueryItem(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
            URLQueryItem(name: "f", value: "json")
        ]

        return components?.url
    }

    /// Parses the JSON response from USGS API into elevation array
    private func parseElevationResponse(data: Data, width: Int, height: Int) throws -> [[Double]] {

        // Try to parse as JSON first to check for errors
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // DEBUG: Log the response structure
            logger.debug("API Response keys: \(json.keys.joined(separator: ", "))")
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.debug("Full response: \(jsonString)")
            }

            // Check for API errors
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                logger.error("USGS API Error: \(message)")
                throw DEMError.apiError(message)
            }

            // The USGS API returns elevation data in the "pixelData" field as a 1D array
            // We need to reshape it into a 2D array
            if let pixelData = json["pixelData"] as? [[Double]] {
                // pixelData is already in 2D format (array of rows)
                logger.debug("Found pixelData in 2D format")
                return pixelData
            }

            // Sometimes it's a flat array that needs reshaping
            if let flatData = json["pixelData"] as? [Double] {
                logger.debug("Found pixelData in flat format, reshaping")
                return reshapeData(flatData, width: width, height: height)
            }

            // Check if data is in "data" field (alternative format)
            if let flatData = json["data"] as? [Double] {
                logger.debug("Found data in flat format, reshaping")
                return reshapeData(flatData, width: width, height: height)
            }

            // Check if there's an href field (image URL)
            if let href = json["href"] as? String {
                logger.warning("API returned image URL: \(href), image-based responses not yet supported")
            }
        }

        // If JSON parsing didn't work, it might be binary data (TIFF/IMG format)
        // For now, we'll fall back to mock data and log a warning
        logger.warning("Could not parse elevation data format, using fallback")
        throw DEMError.parseError
    }

    /// Reshapes a flat array into a 2D grid
    private func reshapeData(_ flatData: [Double], width: Int, height: Int) -> [[Double]] {
        var result: [[Double]] = []

        for row in 0..<height {
            var rowData: [Double] = []
            for col in 0..<width {
                let index = row * width + col
                if index < flatData.count {
                    rowData.append(flatData[index])
                } else {
                    rowData.append(0.0) // Fill with 0 if out of bounds
                }
            }
            result.append(rowData)
        }

        return result
    }
}

// MARK: - Supporting Types

struct BoundingBox {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double
}

enum DEMError: LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct valid API URL"
        case .networkError:
            return "Network request failed"
        case .parseError:
            return "Failed to parse elevation data"
        case .apiError(let message):
            return "USGS API Error: \(message)"
        }
    }
}
