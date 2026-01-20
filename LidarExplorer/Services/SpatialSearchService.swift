//
//  SpatialSearchService.swift
//  LidarExplorer
//
//  Provides spatial search capabilities including coordinate parsing,
//  radius-based search, and region-based filtering
//

import Foundation
import MapKit

actor SpatialSearchService {
    static let shared = SpatialSearchService()

    private init() {}

    // MARK: - Coordinate Parsing

    /// Attempts to parse various coordinate formats from a string
    /// Supported formats:
    /// - "38.6551, -90.0628" (decimal degrees)
    /// - "38.6551 N, 90.0628 W" (decimal with directions)
    /// - "38° 39' 18.36\" N, 90° 03' 46.08\" W" (DMS format)
    func parseCoordinates(from searchText: String) -> CLLocationCoordinate2D? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)

        // Try decimal degrees first (most common)
        if let coord = parseDecimalDegrees(trimmed) {
            return coord
        }

        // Try DMS format
        if let coord = parseDMS(trimmed) {
            return coord
        }

        return nil
    }

    private func parseDecimalDegrees(_ text: String) -> CLLocationCoordinate2D? {
        // Remove common separators and directions
        var cleaned = text.replacingOccurrences(of: "°", with: "")
        cleaned = cleaned.replacingOccurrences(of: "'", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\"", with: "")

        // Split by comma or space
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ",;"))
        guard parts.count == 2 else { return nil }

        let latString = parts[0].trimmingCharacters(in: .whitespaces)
        let lonString = parts[1].trimmingCharacters(in: .whitespaces)

        // Extract numbers and directions
        var latitude: Double?
        var longitude: Double?
        var latMultiplier = 1.0
        var lonMultiplier = 1.0

        // Check for N/S/E/W directions
        if latString.uppercased().contains("S") {
            latMultiplier = -1.0
        }
        if lonString.uppercased().contains("W") {
            lonMultiplier = -1.0
        }

        // Extract numeric values
        let latNumeric = latString.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".-")).inverted).joined()
        let lonNumeric = lonString.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".-")).inverted).joined()

        latitude = Double(latNumeric)
        longitude = Double(lonNumeric)

        guard let lat = latitude, let lon = longitude else { return nil }

        let finalLat = lat * latMultiplier
        let finalLon = lon * lonMultiplier

        // Validate coordinate ranges
        guard finalLat >= -90 && finalLat <= 90 &&
              finalLon >= -180 && finalLon <= 180 else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon)
    }

    private func parseDMS(_ text: String) -> CLLocationCoordinate2D? {
        // DMS format: 38° 39' 18.36" N, 90° 03' 46.08" W
        let parts = text.components(separatedBy: ",")
        guard parts.count == 2 else { return nil }

        let lat = parseDMSComponent(parts[0].trimmingCharacters(in: .whitespaces))
        let lon = parseDMSComponent(parts[1].trimmingCharacters(in: .whitespaces))

        guard let latitude = lat, let longitude = lon else { return nil }

        // Validate coordinate ranges
        guard latitude >= -90 && latitude <= 90 &&
              longitude >= -180 && longitude <= 180 else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func parseDMSComponent(_ component: String) -> Double? {
        // Extract degrees, minutes, seconds
        let pattern = #"(\d+)[°\s]+(\d+)['\s]+([0-9.]+)["'\s]*([NSEW])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

        let nsString = component as NSString
        let matches = regex.matches(in: component, options: [], range: NSRange(location: 0, length: nsString.length))

        guard let match = matches.first,
              match.numberOfRanges >= 4 else { return nil }

        let degreesString = nsString.substring(with: match.range(at: 1))
        let minutesString = nsString.substring(with: match.range(at: 2))
        let secondsString = nsString.substring(with: match.range(at: 3))

        guard let degrees = Double(degreesString),
              let minutes = Double(minutesString),
              let seconds = Double(secondsString) else { return nil }

        var decimal = degrees + (minutes / 60.0) + (seconds / 3600.0)

        // Check for direction
        if match.numberOfRanges >= 5 {
            let directionRange = match.range(at: 4)
            if directionRange.location != NSNotFound {
                let direction = nsString.substring(with: directionRange).uppercased()
                if direction == "S" || direction == "W" {
                    decimal = -decimal
                }
            }
        }

        return decimal
    }

    // MARK: - Distance Calculations

    /// Calculate distance in meters between two coordinates
    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let location2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return location1.distance(from: location2)
    }

    /// Convert miles to meters
    nonisolated func milesToMeters(_ miles: Double) -> Double {
        return miles * 1609.344
    }

    /// Convert meters to miles
    nonisolated func metersToMiles(_ meters: Double) -> Double {
        return meters / 1609.344
    }

    // MARK: - Radius-Based Search

    /// Filter features within a given radius (in meters) of a center point
    func filterFeaturesWithinRadius(
        features: [HistoricalFeature],
        center: CLLocationCoordinate2D,
        radiusMeters: Double
    ) -> [HistoricalFeature] {
        return features.filter { feature in
            let dist = distance(from: center, to: feature.coordinate)
            return dist <= radiusMeters
        }
    }

    /// Filter features within a given radius (in miles) of a center point
    func filterFeaturesWithinRadius(
        features: [HistoricalFeature],
        center: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> [HistoricalFeature] {
        return filterFeaturesWithinRadius(
            features: features,
            center: center,
            radiusMeters: milesToMeters(radiusMiles)
        )
    }

    // MARK: - Region-Based Search

    /// Check if a coordinate is inside a polygon defined by a list of coordinates
    func isCoordinate(_ point: CLLocationCoordinate2D, insidePolygon polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        // Ray casting algorithm
        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]

            if ((pi.longitude > point.longitude) != (pj.longitude > point.longitude)) &&
               (point.latitude < (pj.latitude - pi.latitude) * (point.longitude - pi.longitude) / (pj.longitude - pi.longitude) + pi.latitude) {
                inside = !inside
            }
            j = i
        }

        return inside
    }

    /// Filter features that fall within a territory boundary
    func filterFeaturesInTerritory(
        features: [HistoricalFeature],
        territory: HistoricalTerritory
    ) -> [HistoricalFeature] {
        return features.filter { feature in
            isCoordinate(feature.coordinate, insidePolygon: territory.coordinates)
        }
    }

    /// Filter features within a map region (bounding box)
    func filterFeaturesInRegion(
        features: [HistoricalFeature],
        region: MKCoordinateRegion
    ) -> [HistoricalFeature] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        return features.filter { feature in
            let lat = feature.coordinate.latitude
            let lon = feature.coordinate.longitude
            return lat >= minLat && lat <= maxLat &&
                   lon >= minLon && lon <= maxLon
        }
    }

    // MARK: - Named Region Search

    /// Search for territories by name (case-insensitive, partial match)
    func searchTerritories(
        _ territories: [HistoricalTerritory],
        query: String
    ) -> [HistoricalTerritory] {
        guard !query.isEmpty else { return territories }

        let lowercaseQuery = query.lowercased()
        return territories.filter { territory in
            territory.name.lowercased().contains(lowercaseQuery) ||
            territory.culturalGroup?.lowercased().contains(lowercaseQuery) == true ||
            territory.timePeriod.lowercased().contains(lowercaseQuery)
        }
    }

    // MARK: - Coordinate Formatting

    /// Format a coordinate as a readable string
    nonisolated func formatCoordinate(_ coordinate: CLLocationCoordinate2D, format: CoordinateFormat = .decimalDegrees) -> String {
        switch format {
        case .decimalDegrees:
            return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        case .decimalDegreesWithDirections:
            let latDir = coordinate.latitude >= 0 ? "N" : "S"
            let lonDir = coordinate.longitude >= 0 ? "E" : "W"
            return String(format: "%.4f° %@, %.4f° %@",
                        abs(coordinate.latitude), latDir,
                        abs(coordinate.longitude), lonDir)
        case .dms:
            return formatDMS(coordinate)
        }
    }

    private nonisolated func formatDMS(_ coordinate: CLLocationCoordinate2D) -> String {
        let lat = abs(coordinate.latitude)
        let lon = abs(coordinate.longitude)

        let latDeg = Int(lat)
        let latMin = Int((lat - Double(latDeg)) * 60)
        let latSec = ((lat - Double(latDeg)) * 60 - Double(latMin)) * 60

        let lonDeg = Int(lon)
        let lonMin = Int((lon - Double(lonDeg)) * 60)
        let lonSec = ((lon - Double(lonDeg)) * 60 - Double(lonMin)) * 60

        let latDir = coordinate.latitude >= 0 ? "N" : "S"
        let lonDir = coordinate.longitude >= 0 ? "E" : "W"

        return String(format: "%d° %d' %.2f\" %@, %d° %d' %.2f\" %@",
                     latDeg, latMin, latSec, latDir,
                     lonDeg, lonMin, lonSec, lonDir)
    }
}

// MARK: - Supporting Types

enum CoordinateFormat {
    case decimalDegrees
    case decimalDegreesWithDirections
    case dms
}

// MARK: - Search Result Types

struct SpatialSearchResult {
    let features: [HistoricalFeature]
    let searchType: SearchType
    let metadata: SearchMetadata

    enum SearchType {
        case radius(center: CLLocationCoordinate2D, radiusMiles: Double)
        case territory(name: String)
        case region(MKCoordinateRegion)
        case coordinate(CLLocationCoordinate2D)
    }

    struct SearchMetadata {
        let featureCount: Int
        let averageConfidence: Double?
        let searchTime: TimeInterval
    }
}
