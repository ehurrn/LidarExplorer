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
    ///   - resolution: Desired grid resolution (default 100x100)
    /// - Returns: 2D array of elevation values in meters
    func fetchElevationData(
        for region: MKCoordinateRegion,
        resolution: Int = 100
    ) async throws -> [[Double]] {

        // Calculate bounding box from region
        let bbox = calculateBoundingBox(from: region)

        // Construct USGS 3DEP API URL
        guard let url = constructAPIURL(bbox: bbox, width: resolution, height: resolution) else {
            throw DEMError.invalidURL
        }

        print("📡 Fetching DEM data from USGS 3DEP API...")
        print("   Region: \(region.center.latitude), \(region.center.longitude)")
        print("   BBox: \(bbox)")
        print("   URL: \(url.absoluteString)")

        // Fetch data from API
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DEMError.networkError
        }

        print("✅ Received \(data.count) bytes from USGS API")

        // Parse the response
        let elevationData = try parseElevationResponse(data: data, width: resolution, height: resolution)

        print("✅ Parsed \(elevationData.count)x\(elevationData.first?.count ?? 0) elevation grid")

        return elevationData
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
