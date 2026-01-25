//
//  OpenStreetMapService.swift
//  LidarExplorer
//
//  OpenStreetMap integration for modern infrastructure filtering
//

import Foundation
import MapKit
import OSLog

/// Service for querying OpenStreetMap data to identify modern infrastructure
/// Used to filter out false positives in historical feature detection
actor OpenStreetMapService {
    static let shared = OpenStreetMapService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "OpenStreetMapService")

    // Overpass API endpoint (public OpenStreetMap query service)
    private let overpassAPIURL = "https://overpass-api.de/api/interpreter"

    // Cache for recent queries (keyed by bounding box string)
    private var cache: [String: OSMQueryResult] = [:]
    private let cacheExpirationSeconds: TimeInterval = 3600 // 1 hour

    private init() {}

    // MARK: - Public API

    /// Batch queries for a region and caches results for multiple features
    func queryRegion(region: MKCoordinateRegion) async -> OSMQueryResult? {
        // Create bounding box for entire region
        let center = region.center
        let latRadius = region.span.latitudeDelta / 2.0 * 111000.0 // degrees to meters
        let lonRadius = region.span.longitudeDelta / 2.0 * 111000.0

        let radiusMeters = max(latRadius, lonRadius)

        let bbox = createOSMBoundingBox(center: center, radiusMeters: radiusMeters)

        return await queryModernFeatures(bbox: bbox)
    }

    /// Checks if a coordinate is near modern infrastructure
    /// Returns distance to nearest modern feature (in meters), or nil if none nearby
    func distanceToModernInfrastructure(
        coordinate: CLLocationCoordinate2D,
        searchRadiusMeters: Double = 50.0
    ) async -> Double? {
        // Query OSM for modern features around this coordinate
        let bbox = createOSMBoundingBox(center: coordinate, radiusMeters: searchRadiusMeters)

        guard let result = await queryModernFeatures(bbox: bbox) else {
            return nil
        }

        // Calculate distance to nearest modern feature
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var minDistance: Double?

        for feature in result.buildings + result.roads + result.structures {
            let featureLocation = CLLocation(latitude: feature.latitude, longitude: feature.longitude)
            let distance = location.distance(from: featureLocation)

            if let current = minDistance {
                minDistance = min(current, distance)
            } else {
                minDistance = distance
            }
        }

        return minDistance
    }

    /// Checks if a coordinate is within modern infrastructure
    func isWithinModernInfrastructure(
        coordinate: CLLocationCoordinate2D,
        thresholdMeters: Double = 25.0
    ) async -> Bool {
        guard let distance = await distanceToModernInfrastructure(
            coordinate: coordinate,
            searchRadiusMeters: thresholdMeters * 2
        ) else {
            return false
        }

        return distance < thresholdMeters
    }

    /// Returns a penalty multiplier (0.0-1.0) based on proximity to modern infrastructure
    /// 0.0 = directly on modern feature (full penalty)
    /// 1.0 = far from modern features (no penalty)
    func modernInfrastructurePenalty(
        coordinate: CLLocationCoordinate2D,
        penaltyRadiusMeters: Double = 100.0
    ) async -> Double {
        guard let distance = await distanceToModernInfrastructure(
            coordinate: coordinate,
            searchRadiusMeters: penaltyRadiusMeters * 1.5
        ) else {
            return 1.0 // No nearby features, no penalty
        }

        // Linear penalty function
        // 0m = 0.0 (full penalty)
        // penaltyRadius = 1.0 (no penalty)
        let penalty = min(distance / penaltyRadiusMeters, 1.0)
        return penalty
    }

    // MARK: - OSM Query

    private func queryModernFeatures(bbox: OSMBoundingBox) async -> OSMQueryResult? {
        let cacheKey = "\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon)"

        // Check cache
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached OSM data for bbox")
            return cached
        }

        // Build Overpass QL query
        let query = buildOverpassQuery(bbox: bbox)

        guard let url = URL(string: overpassAPIURL),
              let queryData = query.data(using: String.Encoding.utf8) else {
            logger.error("Failed to create OSM query")
            return nil
        }

        // Execute query
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = queryData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("OSM query failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            // Parse response
            let result = parseOverpassResponse(data: data)

            // Cache result
            cache[cacheKey] = result

            logger.info("OSM query successful: \(result.buildings.count) buildings, \(result.roads.count) roads, \(result.structures.count) structures")

            return result

        } catch {
            logger.error("OSM query error: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildOverpassQuery(bbox: OSMBoundingBox) -> String {
        // Query for buildings, major roads, and modern structures
        // Format: [bbox:minLat,minLon,maxLat,maxLon]
        let bboxStr = "\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon)"

        return """
        [bbox:\(bboxStr)][out:json];
        (
          way["building"];
          way["highway"~"motorway|trunk|primary|secondary"];
          way["man_made"];
          node["man_made"];
        );
        out center;
        """
    }

    private func parseOverpassResponse(data: Data) -> OSMQueryResult {
        var buildings: [OSMFeature] = []
        var roads: [OSMFeature] = []
        var structures: [OSMFeature] = []

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let elements = json?["elements"] as? [[String: Any]] else {
                logger.warning("No elements in OSM response")
                return OSMQueryResult(buildings: [], roads: [], structures: [], timestamp: Date())
            }

            for element in elements {
                guard let type = element["type"] as? String,
                      let id = element["id"] as? Int else { continue }

                // Get coordinate
                var lat: Double?
                var lon: Double?

                if type == "node" {
                    lat = element["lat"] as? Double
                    lon = element["lon"] as? Double
                } else if type == "way" {
                    // Use center coordinate if available
                    if let center = element["center"] as? [String: Any] {
                        lat = center["lat"] as? Double
                        lon = center["lon"] as? Double
                    }
                }

                guard let latitude = lat, let longitude = lon else { continue }

                let tags = element["tags"] as? [String: String] ?? [:]

                // Categorize feature
                if tags["building"] != nil {
                    buildings.append(OSMFeature(
                        id: id,
                        type: .building,
                        latitude: latitude,
                        longitude: longitude,
                        tags: tags
                    ))
                } else if tags["highway"] != nil {
                    roads.append(OSMFeature(
                        id: id,
                        type: .road,
                        latitude: latitude,
                        longitude: longitude,
                        tags: tags
                    ))
                } else if tags["man_made"] != nil {
                    structures.append(OSMFeature(
                        id: id,
                        type: .structure,
                        latitude: latitude,
                        longitude: longitude,
                        tags: tags
                    ))
                }
            }

        } catch {
            logger.error("Failed to parse OSM response: \(error.localizedDescription)")
        }

        return OSMQueryResult(
            buildings: buildings,
            roads: roads,
            structures: structures,
            timestamp: Date()
        )
    }

    private func createOSMBoundingBox(center: CLLocationCoordinate2D, radiusMeters: Double) -> OSMBoundingBox {
        // Approximate degrees per meter (varies by latitude)
        let latDegreesPerMeter = 1.0 / 111000.0
        let lonDegreesPerMeter = 1.0 / (111000.0 * cos(center.latitude * .pi / 180.0))

        let latDelta = radiusMeters * latDegreesPerMeter
        let lonDelta = radiusMeters * lonDegreesPerMeter

        return OSMBoundingBox(
            minLat: center.latitude - latDelta,
            maxLat: center.latitude + latDelta,
            minLon: center.longitude - lonDelta,
            maxLon: center.longitude + lonDelta
        )
    }

    // MARK: - Historic Features Query

    /// Query OSM for historic features (archaeological sites, ruins, monuments, etc.)
    func queryHistoricFeatures(
        center: CLLocationCoordinate2D,
        radiusMeters: Double = 25000  // 25km default for historic features
    ) async -> OSMHistoricResult {
        let bbox = createOSMBoundingBox(center: center, radiusMeters: radiusMeters)
        let cacheKey = "historic:\(Int(bbox.minLat * 100)),\(Int(bbox.minLon * 100)),\(Int(bbox.maxLat * 100)),\(Int(bbox.maxLon * 100))"

        // Check cache
        if let cached = historicCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached OSM historic data: \(cached.features.count) features")
            return cached
        }

        // Build Overpass QL query for historic features
        let query = buildHistoricOverpassQuery(bbox: bbox)

        guard let url = URL(string: overpassAPIURL),
              let queryData = query.data(using: String.Encoding.utf8) else {
            logger.error("Failed to create OSM historic query")
            return OSMHistoricResult(features: [], timestamp: Date())
        }

        // Execute query
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = queryData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("OSM historic query failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return OSMHistoricResult(features: [], timestamp: Date())
            }

            // Parse response
            let result = parseHistoricOverpassResponse(data: data, queryCenter: center)

            // Cache result
            historicCache[cacheKey] = result

            logger.info("OSM historic query successful: \(result.features.count) features")
            if !result.features.isEmpty {
                let types = Dictionary(grouping: result.features, by: { $0.historicType }).mapValues { $0.count }
                logger.debug("Historic types: \(types)")
            }

            return result

        } catch {
            logger.error("OSM historic query error: \(error.localizedDescription)")
            return OSMHistoricResult(features: [], timestamp: Date())
        }
    }

    private func buildHistoricOverpassQuery(bbox: OSMBoundingBox) -> String {
        let bboxStr = "\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon)"

        // Query for all historic features
        return """
        [bbox:\(bboxStr)][out:json][timeout:25];
        (
          node["historic"];
          way["historic"];
          relation["historic"];
          node["site_type"="megalith"];
          node["site_type"="tumulus"];
          node["site_type"="mound"];
          way["site_type"="megalith"];
          way["site_type"="tumulus"];
          way["site_type"="mound"];
          node["archaeological_site"];
          way["archaeological_site"];
        );
        out center tags;
        """
    }

    private func parseHistoricOverpassResponse(data: Data, queryCenter: CLLocationCoordinate2D) -> OSMHistoricResult {
        var features: [OSMHistoricFeature] = []
        let centerLocation = CLLocation(latitude: queryCenter.latitude, longitude: queryCenter.longitude)

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let elements = json?["elements"] as? [[String: Any]] else {
                return OSMHistoricResult(features: [], timestamp: Date())
            }

            for element in elements {
                guard let id = element["id"] as? Int else { continue }

                // Get coordinate
                var lat: Double?
                var lon: Double?

                if let nodeLat = element["lat"] as? Double,
                   let nodeLon = element["lon"] as? Double {
                    lat = nodeLat
                    lon = nodeLon
                } else if let center = element["center"] as? [String: Any] {
                    lat = center["lat"] as? Double
                    lon = center["lon"] as? Double
                }

                guard let latitude = lat, let longitude = lon else { continue }

                let tags = element["tags"] as? [String: String] ?? [:]

                // Determine historic type
                let historicType = tags["historic"] ?? tags["site_type"] ?? tags["archaeological_site"] ?? "unknown"

                // Get name
                let name = tags["name"] ?? tags["name:en"] ?? "Unnamed \(historicType)"

                // Calculate distance
                let featureLocation = CLLocation(latitude: latitude, longitude: longitude)
                let distance = centerLocation.distance(from: featureLocation)

                let feature = OSMHistoricFeature(
                    id: id,
                    name: name,
                    latitude: latitude,
                    longitude: longitude,
                    historicType: historicType,
                    tags: tags,
                    distanceMeters: distance
                )

                features.append(feature)
            }

        } catch {
            logger.error("Failed to parse OSM historic response: \(error.localizedDescription)")
        }

        // Sort by distance
        features.sort { $0.distanceMeters < $1.distanceMeters }

        return OSMHistoricResult(features: features, timestamp: Date())
    }

    // Cache for historic queries (separate from modern infrastructure cache)
    private var historicCache: [String: OSMHistoricResult] = [:]
}

// MARK: - Data Models

struct OSMBoundingBox {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}

struct OSMFeature {
    let id: Int
    let type: OSMFeatureType
    let latitude: Double
    let longitude: Double
    let tags: [String: String]
}

enum OSMFeatureType {
    case building
    case road
    case structure
}

struct OSMQueryResult {
    let buildings: [OSMFeature]
    let roads: [OSMFeature]
    let structures: [OSMFeature]
    let timestamp: Date
}

// MARK: - Historic Feature Models

struct OSMHistoricFeature: Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let historicType: String  // "archaeological_site", "ruins", "monument", "mound", etc.
    let tags: [String: String]
    let distanceMeters: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Categorize the historic type for analysis purposes
    var category: OSMHistoricCategory {
        let lower = historicType.lowercased()
        if lower.contains("mound") || lower.contains("tumulus") || lower.contains("barrow") {
            return .mound
        }
        if lower.contains("archaeological") {
            return .archaeologicalSite
        }
        if lower.contains("ruins") {
            return .ruins
        }
        if lower.contains("megalith") || lower.contains("standing_stone") || lower.contains("stone_circle") {
            return .megalith
        }
        if lower.contains("monument") || lower.contains("memorial") {
            return .monument
        }
        if lower.contains("battlefield") {
            return .battlefield
        }
        if lower.contains("fort") || lower.contains("castle") {
            return .fortification
        }
        return .other
    }
}

enum OSMHistoricCategory {
    case mound
    case archaeologicalSite
    case ruins
    case megalith
    case monument
    case battlefield
    case fortification
    case other

    var isArchaeologicallyRelevant: Bool {
        switch self {
        case .mound, .archaeologicalSite, .ruins, .megalith:
            return true
        default:
            return false
        }
    }
}

struct OSMHistoricResult {
    let features: [OSMHistoricFeature]
    let timestamp: Date

    var hasSites: Bool { !features.isEmpty }

    var archaeologicalSites: [OSMHistoricFeature] {
        features.filter { $0.category.isArchaeologicallyRelevant }
    }

    var mounds: [OSMHistoricFeature] {
        features.filter { $0.category == .mound }
    }
}
