//
//  DEMDataService.swift
//  LidarExplorer
//
//  Service to fetch real elevation data from USGS 3DEP Elevation API
//

import Foundation
import MapKit

/// Service for fetching Digital Elevation Model (DEM) data from USGS 3DEP
actor DEMDataService {
    static let shared = DEMDataService()

    private init() {}

    /// Fetches elevation data for a given map region from USGS 3DEP
    /// - Parameters:
    ///   - region: The map region to fetch elevation data for
    ///   - resolution: Desired grid resolution (clamped to 50x50 for API efficiency)
    /// - Returns: 2D array of elevation values in meters
    func fetchElevationData(
        for region: MKCoordinateRegion,
        resolution: Int = 100
    ) async throws -> [[Double]] {

        // Use a smaller resolution for point queries to avoid too many API calls
        // We'll interpolate to the desired resolution later if needed
        let actualResolution = min(resolution, 50)

        print("📡 Fetching DEM data from USGS Elevation Point Query Service...")
        print("   Region: \(region.center.latitude), \(region.center.longitude)")
        print("   Resolution: \(actualResolution)x\(actualResolution) (\(actualResolution * actualResolution) points)")

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

        print("   Fetching \(coordinates.count) elevation points in batches...")

        // Track success/failure rates
        var successCount = 0
        var failureCount = 0

        // Fetch points in batches to avoid overwhelming the API
        // Process 100 points at a time for reasonable performance
        let batchSize = 100
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

            print("   Progress: \(batchEnd)/\(coordinates.count) points (\(Int(Double(batchEnd) / Double(coordinates.count) * 100))%)")
        }

        let results = allResults

        // Report success/failure statistics
        print("   API Results: \(successCount) successful, \(failureCount) failed (\(Int(Double(successCount) / Double(successCount + failureCount) * 100))% success rate)")

        // Convert to 2D array
        var elevationData: [[Double]] = []
        for row in 0..<actualResolution {
            var rowData: [Double] = []
            for col in 0..<actualResolution {
                rowData.append(results[row]?[col] ?? 0.0)
            }
            elevationData.append(rowData)
        }

        print("✅ Fetched \(elevationData.count)x\(elevationData.first?.count ?? 0) elevation grid")

        // If we fetched at lower resolution, interpolate to desired resolution
        if actualResolution < resolution {
            print("   Interpolating from \(actualResolution)x\(actualResolution) to \(resolution)x\(resolution)...")
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

        // Parse the response - EPQS returns structure like:
        // {"value": [{"value": 123.45, "resolution": 1, "units": "Meters"}]}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Try different response formats
            if let valueArray = json["value"] as? [[String: Any]],
               let firstResult = valueArray.first,
               let elevation = firstResult["value"] as? Double {
                return elevation
            }

            // Alternative format: elevation might be a direct number
            if let elevation = json["elevation"] as? Double {
                return elevation
            }

            // Another format possibility
            if let elevation = json["value"] as? Double {
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
            print("📋 API Response keys: \(json.keys.joined(separator: ", "))")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📋 Full response: \(jsonString)")
            }

            // Check for API errors
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                print("❌ USGS API Error: \(message)")
                throw DEMError.apiError(message)
            }

            // The USGS API returns elevation data in the "pixelData" field as a 1D array
            // We need to reshape it into a 2D array
            if let pixelData = json["pixelData"] as? [[Double]] {
                // pixelData is already in 2D format (array of rows)
                print("✅ Found pixelData in 2D format")
                return pixelData
            }

            // Sometimes it's a flat array that needs reshaping
            if let flatData = json["pixelData"] as? [Double] {
                print("✅ Found pixelData in flat format, reshaping...")
                return reshapeData(flatData, width: width, height: height)
            }

            // Check if data is in "data" field (alternative format)
            if let flatData = json["data"] as? [Double] {
                print("✅ Found data in flat format, reshaping...")
                return reshapeData(flatData, width: width, height: height)
            }

            // Check if there's an href field (image URL)
            if let href = json["href"] as? String {
                print("📷 API returned image URL: \(href)")
                print("⚠️ Image-based responses not yet supported")
            }
        }

        // If JSON parsing didn't work, it might be binary data (TIFF/IMG format)
        // For now, we'll fall back to mock data and log a warning
        print("⚠️ Could not parse elevation data format, using fallback")
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
