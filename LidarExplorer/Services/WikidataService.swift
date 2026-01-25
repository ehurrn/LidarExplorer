//
//  WikidataService.swift
//  LidarExplorer
//
//  Wikidata SPARQL integration for archaeological and historical site discovery
//

import Foundation
import MapKit
import OSLog

/// Represents a historical/archaeological site from Wikidata
struct WikidataSite: Identifiable, Sendable {
    let id: String  // Wikidata Q-number (e.g., "Q12345")
    let name: String
    let coordinate: CLLocationCoordinate2D
    let siteType: WikidataSiteType
    let description: String?
    let wikipediaURL: String?
    let timePeriod: String?
    let culture: String?
    let distanceMeters: Double?  // Distance from query center

    enum WikidataSiteType: String, Sendable {
        case mound = "mound"
        case earthwork = "earthwork"
        case archaeologicalSite = "archaeological_site"
        case historicSite = "historic_site"
        case ruins = "ruins"
        case monument = "monument"
        case nativeAmericanSite = "native_american_site"
        case other = "other"
    }
}

/// Result of a Wikidata query for a region
struct WikidataQueryResult: Sendable {
    let sites: [WikidataSite]
    let queryCenter: CLLocationCoordinate2D
    let radiusKm: Double
    let timestamp: Date

    var hasSites: Bool { !sites.isEmpty }
    var moundCount: Int { sites.filter { $0.siteType == .mound || $0.siteType == .earthwork }.count }
    var archaeologicalCount: Int { sites.filter { $0.siteType == .archaeologicalSite }.count }
}

/// Regional context derived from Wikidata results
struct RegionalContext: Sendable {
    let knownSiteCount: Int
    let dominantCultures: [String]
    let timePeriods: [String]
    let nearestSite: WikidataSite?
    let hasMoundSites: Bool
    let hasEarthworks: Bool
    let suggestedDetectionFocus: [String]

    /// Confidence multiplier based on regional archaeological density
    var densityMultiplier: Double {
        switch knownSiteCount {
        case 0: return 1.0       // No known sites, neutral
        case 1...3: return 1.1   // Some sites, slight boost
        case 4...10: return 1.2  // Archaeological area, good boost
        default: return 1.3     // Dense archaeological region
        }
    }
}

/// Service for querying Wikidata's SPARQL endpoint for historical/archaeological data
actor WikidataService {
    static let shared = WikidataService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "WikidataService")

    // Wikidata SPARQL endpoint
    private let sparqlEndpoint = "https://query.wikidata.org/sparql"

    // Cache for queries (keyed by rounded coordinates)
    private var cache: [String: WikidataQueryResult] = [:]
    private let cacheExpirationSeconds: TimeInterval = 86400 // 24 hours (Wikidata data is stable)

    private init() {}

    // MARK: - Public API

    /// Query Wikidata for archaeological/historical sites within radius of coordinate
    func querySites(
        center: CLLocationCoordinate2D,
        radiusKm: Double = 50.0
    ) async -> WikidataQueryResult {
        let cacheKey = "\(Int(center.latitude * 10)),\(Int(center.longitude * 10)),\(Int(radiusKm))"

        // Check cache
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached Wikidata results: \(cached.sites.count) sites")
            return cached
        }

        logger.info("Querying Wikidata for sites within \(radiusKm)km of (\(center.latitude), \(center.longitude))")

        // Build SPARQL query
        let query = buildSPARQLQuery(center: center, radiusKm: radiusKm)

        guard let url = buildQueryURL(query: query) else {
            logger.error("Failed to build Wikidata query URL")
            return WikidataQueryResult(sites: [], queryCenter: center, radiusKm: radiusKm, timestamp: Date())
        }

        // Execute query
        var request = URLRequest(url: url)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("LidarExplorer/1.0 (Archaeological Research App)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.error("Wikidata query failed with status: \(status)")
                return WikidataQueryResult(sites: [], queryCenter: center, radiusKm: radiusKm, timestamp: Date())
            }

            // Parse response
            let sites = parseSPARQLResponse(data: data, queryCenter: center)
            let result = WikidataQueryResult(
                sites: sites,
                queryCenter: center,
                radiusKm: radiusKm,
                timestamp: Date()
            )

            // Cache result
            cache[cacheKey] = result

            logger.info("Wikidata query successful: \(sites.count) sites found")
            if !sites.isEmpty {
                let types = Dictionary(grouping: sites, by: { $0.siteType }).mapValues { $0.count }
                logger.debug("Site types: \(types)")
            }

            return result

        } catch {
            logger.error("Wikidata query error: \(error.localizedDescription)")
            return WikidataQueryResult(sites: [], queryCenter: center, radiusKm: radiusKm, timestamp: Date())
        }
    }

    /// Build regional context from Wikidata results
    func buildRegionalContext(from result: WikidataQueryResult) -> RegionalContext {
        let cultures = result.sites.compactMap { $0.culture }.unique()
        let periods = result.sites.compactMap { $0.timePeriod }.unique()
        let hasMounds = result.sites.contains { $0.siteType == .mound || $0.siteType == .earthwork }
        let hasEarthworks = result.sites.contains { $0.siteType == .earthwork }

        // Determine detection focus based on regional sites
        var focus: [String] = []
        if hasMounds { focus.append("platform_mounds") }
        if hasEarthworks { focus.append("earthworks") }
        if result.sites.contains(where: { $0.siteType == .nativeAmericanSite }) {
            focus.append("native_american_features")
        }
        if focus.isEmpty { focus.append("general_archaeological") }

        return RegionalContext(
            knownSiteCount: result.sites.count,
            dominantCultures: cultures,
            timePeriods: periods,
            nearestSite: result.sites.min(by: { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }),
            hasMoundSites: hasMounds,
            hasEarthworks: hasEarthworks,
            suggestedDetectionFocus: focus
        )
    }

    /// Find the nearest known site to a coordinate
    func findNearestSite(to coordinate: CLLocationCoordinate2D, in result: WikidataQueryResult) -> WikidataSite? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return result.sites.min(by: { site1, site2 in
            let loc1 = CLLocation(latitude: site1.coordinate.latitude, longitude: site1.coordinate.longitude)
            let loc2 = CLLocation(latitude: site2.coordinate.latitude, longitude: site2.coordinate.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        })
    }

    // MARK: - SPARQL Query Building

    private func buildSPARQLQuery(center: CLLocationCoordinate2D, radiusKm: Double) -> String {
        // SPARQL query to find archaeological/historical sites
        // Uses Wikidata's geo:wktLiteral for coordinate search
        return """
        SELECT DISTINCT ?item ?itemLabel ?itemDescription ?coord ?siteType ?siteTypeLabel ?cultureLabel ?periodLabel ?article WHERE {
          # Geographic search within radius
          SERVICE wikibase:around {
            ?item wdt:P625 ?coord.
            bd:serviceParam wikibase:center "Point(\(center.longitude) \(center.latitude))"^^geo:wktLiteral.
            bd:serviceParam wikibase:radius "\(radiusKm)".
          }

          # Must be one of these types
          VALUES ?siteType {
            wd:Q839954      # archaeological site
            wd:Q7302866     # mound
            wd:Q2319498     # earthwork
            wd:Q4989906     # monument
            wd:Q5773747     # historic site
            wd:Q109607      # ruins
            wd:Q570116      # tumulus/burial mound
            wd:Q1081138     # platform mound
            wd:Q863944      # effigy mound
            wd:Q1497375     # shell mound
            wd:Q12323522    # ancient monument
          }
          ?item wdt:P31 ?siteType.

          # Optional: culture/civilization
          OPTIONAL { ?item wdt:P2596 ?culture. }

          # Optional: time period
          OPTIONAL { ?item wdt:P2348 ?period. }

          # Optional: Wikipedia article
          OPTIONAL {
            ?article schema:about ?item;
                     schema:isPartOf <https://en.wikipedia.org/>.
          }

          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        LIMIT 200
        """
    }

    private func buildQueryURL(query: String) -> URL? {
        var components = URLComponents(string: sparqlEndpoint)
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        return components?.url
    }

    // MARK: - Response Parsing

    private func parseSPARQLResponse(data: Data, queryCenter: CLLocationCoordinate2D) -> [WikidataSite] {
        var sites: [WikidataSite] = []

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [String: Any],
                  let bindings = results["bindings"] as? [[String: Any]] else {
                logger.warning("Invalid SPARQL response format")
                return []
            }

            let centerLocation = CLLocation(latitude: queryCenter.latitude, longitude: queryCenter.longitude)

            for binding in bindings {
                guard let itemValue = (binding["item"] as? [String: Any])?["value"] as? String,
                      let coordValue = (binding["coord"] as? [String: Any])?["value"] as? String else {
                    continue
                }

                // Extract Q-number from URI
                let qNumber = itemValue.components(separatedBy: "/").last ?? itemValue

                // Parse coordinate from "Point(lon lat)" format
                guard let coordinate = parseWKTPoint(coordValue) else { continue }

                // Calculate distance
                let siteLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let distance = centerLocation.distance(from: siteLocation)

                // Extract labels
                let name = (binding["itemLabel"] as? [String: Any])?["value"] as? String ?? "Unknown Site"
                let description = (binding["itemDescription"] as? [String: Any])?["value"] as? String
                let siteTypeLabel = (binding["siteTypeLabel"] as? [String: Any])?["value"] as? String ?? ""
                let culture = (binding["cultureLabel"] as? [String: Any])?["value"] as? String
                let period = (binding["periodLabel"] as? [String: Any])?["value"] as? String
                let wikipediaURL = (binding["article"] as? [String: Any])?["value"] as? String

                let site = WikidataSite(
                    id: qNumber,
                    name: name,
                    coordinate: coordinate,
                    siteType: mapSiteType(siteTypeLabel),
                    description: description,
                    wikipediaURL: wikipediaURL,
                    timePeriod: period,
                    culture: culture,
                    distanceMeters: distance
                )

                sites.append(site)
            }

        } catch {
            logger.error("Failed to parse SPARQL response: \(error.localizedDescription)")
        }

        // Sort by distance
        return sites.sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
    }

    private func parseWKTPoint(_ wkt: String) -> CLLocationCoordinate2D? {
        // Parse "Point(longitude latitude)" format
        let cleaned = wkt
            .replacingOccurrences(of: "Point(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)

        let parts = cleaned.split(separator: " ")
        guard parts.count == 2,
              let lon = Double(parts[0]),
              let lat = Double(parts[1]) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func mapSiteType(_ label: String) -> WikidataSite.WikidataSiteType {
        let lower = label.lowercased()
        if lower.contains("mound") {
            if lower.contains("platform") || lower.contains("effigy") || lower.contains("burial") || lower.contains("shell") {
                return .mound
            }
            return .mound
        }
        if lower.contains("earthwork") { return .earthwork }
        if lower.contains("archaeological") { return .archaeologicalSite }
        if lower.contains("historic") { return .historicSite }
        if lower.contains("ruins") { return .ruins }
        if lower.contains("monument") { return .monument }
        if lower.contains("native") || lower.contains("indian") { return .nativeAmericanSite }
        return .other
    }
}

// MARK: - Array Extension for Unique Elements

private extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
