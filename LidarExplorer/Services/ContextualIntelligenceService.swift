//
//  ContextualIntelligenceService.swift
//  LidarExplorer
//
//  Aggregates contextual intelligence from multiple online sources
//  to inform and improve archaeological feature detection
//

import Foundation
import MapKit
import OSLog

/// Unified site representation from any source
struct ContextualSite: Identifiable, Sendable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let source: DataSource
    let siteType: SiteType
    let description: String?
    let wikipediaURL: String?
    let timePeriod: String?
    let culture: String?
    let distanceMeters: Double

    enum DataSource: String, Sendable {
        case wikidata = "Wikidata"
        case openStreetMap = "OpenStreetMap"
        case bundledDatabase = "Local Database"
    }

    enum SiteType: String, Sendable {
        case mound = "Mound"
        case earthwork = "Earthwork"
        case archaeologicalSite = "Archaeological Site"
        case ruins = "Ruins"
        case monument = "Monument"
        case historicSite = "Historic Site"
        case other = "Other"

        var isArchaeological: Bool {
            switch self {
            case .mound, .earthwork, .archaeologicalSite, .ruins:
                return true
            default:
                return false
            }
        }
    }
}

/// Aggregated intelligence report for a region
struct RegionalIntelligenceReport: Sendable {
    let queryCenter: CLLocationCoordinate2D
    let queryRadiusKm: Double
    let timestamp: Date

    // Combined sites from all sources (deduplicated)
    let sites: [ContextualSite]

    // Source-specific results
    let wikidataResult: WikidataQueryResult?
    let osmHistoricResult: OSMHistoricResult?

    // Analysis recommendations
    let recommendations: AnalysisRecommendations

    // Summary statistics
    var totalSiteCount: Int { sites.count }
    var archaeologicalSiteCount: Int { sites.filter { $0.siteType.isArchaeological }.count }
    var moundCount: Int { sites.filter { $0.siteType == .mound || $0.siteType == .earthwork }.count }

    var hasKnownSites: Bool { !sites.isEmpty }
    var isArchaeologicallyRich: Bool { archaeologicalSiteCount >= 3 }

    /// Get sites within a specific distance
    func sites(withinMeters distance: Double) -> [ContextualSite] {
        sites.filter { $0.distanceMeters <= distance }
    }

    /// Find nearest site to a coordinate
    func nearestSite(to coordinate: CLLocationCoordinate2D) -> ContextualSite? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return sites.min { site1, site2 in
            let loc1 = CLLocation(latitude: site1.coordinate.latitude, longitude: site1.coordinate.longitude)
            let loc2 = CLLocation(latitude: site2.coordinate.latitude, longitude: site2.coordinate.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        }
    }
}

/// Recommendations for analysis based on regional context
struct AnalysisRecommendations: Sendable {
    let sensitivityMultiplier: Double      // 1.0 = normal, >1.0 = more sensitive
    let suggestedFeatureTypes: [String]    // e.g., ["mound", "earthwork"]
    let dominantCultures: [String]         // e.g., ["Mississippian", "Hopewell"]
    let dominantTimePeriods: [String]      // e.g., ["1000-1450 CE"]
    let contextSummary: String             // Human-readable summary
    let confidenceBoostForMatches: Double  // Boost for features near known sites

    static let `default` = AnalysisRecommendations(
        sensitivityMultiplier: 1.0,
        suggestedFeatureTypes: ["mound", "earthwork", "archaeological_feature"],
        dominantCultures: [],
        dominantTimePeriods: [],
        contextSummary: "No prior archaeological data found for this region.",
        confidenceBoostForMatches: 1.0
    )
}

/// Service that aggregates contextual intelligence from multiple sources
actor ContextualIntelligenceService {
    static let shared = ContextualIntelligenceService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "ContextualIntelligence")

    private let wikidataService = WikidataService.shared
    private let osmService = OpenStreetMapService.shared

    // Cache for intelligence reports
    private var reportCache: [String: RegionalIntelligenceReport] = [:]
    private let cacheExpirationSeconds: TimeInterval = 3600 // 1 hour

    private init() {}

    // MARK: - Public API

    /// Gather comprehensive intelligence about a region before analysis
    /// This queries multiple online sources in parallel
    func gatherIntelligence(
        center: CLLocationCoordinate2D,
        radiusKm: Double = 50.0
    ) async -> RegionalIntelligenceReport {
        let cacheKey = "\(Int(center.latitude * 10)),\(Int(center.longitude * 10)),\(Int(radiusKm))"

        // Check cache
        if let cached = reportCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationSeconds {
            logger.debug("Using cached intelligence report: \(cached.sites.count) sites")
            return cached
        }

        logger.info("Gathering regional intelligence for (\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))) within \(radiusKm)km")

        // Query all sources in parallel
        async let wikidataTask = wikidataService.querySites(center: center, radiusKm: radiusKm)
        async let osmTask = osmService.queryHistoricFeatures(center: center, radiusMeters: radiusKm * 1000)

        let wikidataResult = await wikidataTask
        let osmResult = await osmTask

        logger.info("Wikidata: \(wikidataResult.sites.count) sites, OSM: \(osmResult.features.count) historic features")

        // Combine and deduplicate sites
        let combinedSites = combineSites(
            wikidata: wikidataResult,
            osm: osmResult,
            queryCenter: center
        )

        // Build recommendations based on gathered data
        let recommendations = buildRecommendations(
            sites: combinedSites,
            wikidataResult: wikidataResult,
            osmResult: osmResult
        )

        let report = RegionalIntelligenceReport(
            queryCenter: center,
            queryRadiusKm: radiusKm,
            timestamp: Date(),
            sites: combinedSites,
            wikidataResult: wikidataResult,
            osmHistoricResult: osmResult,
            recommendations: recommendations
        )

        // Cache the report
        reportCache[cacheKey] = report

        // Log summary
        logger.info("Intelligence report: \(report.totalSiteCount) total sites, \(report.archaeologicalSiteCount) archaeological")
        logger.info("Recommendations: sensitivity=\(String(format: "%.2f", recommendations.sensitivityMultiplier)), types=\(recommendations.suggestedFeatureTypes.joined(separator: ", "))")

        return report
    }

    /// Quick check if there are known sites near a specific coordinate
    func hasKnownSitesNear(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = 1000
    ) async -> Bool {
        let report = await gatherIntelligence(center: coordinate, radiusKm: max(radiusMeters / 1000, 5))
        return !report.sites(withinMeters: radiusMeters).isEmpty
    }

    /// Find the nearest known site to a detected feature
    func findNearestKnownSite(
        to coordinate: CLLocationCoordinate2D,
        maxDistanceMeters: Double = 5000
    ) async -> ContextualSite? {
        let report = await gatherIntelligence(center: coordinate, radiusKm: max(maxDistanceMeters / 1000 * 2, 10))
        let nearest = report.nearestSite(to: coordinate)

        if let site = nearest, site.distanceMeters <= maxDistanceMeters {
            return site
        }
        return nil
    }

    // MARK: - Site Combination & Deduplication

    private func combineSites(
        wikidata: WikidataQueryResult,
        osm: OSMHistoricResult,
        queryCenter: CLLocationCoordinate2D
    ) -> [ContextualSite] {
        var sites: [ContextualSite] = []
        var seenLocations: Set<String> = []  // For deduplication

        let centerLocation = CLLocation(latitude: queryCenter.latitude, longitude: queryCenter.longitude)

        // Add Wikidata sites
        for site in wikidata.sites {
            let locationKey = "\(Int(site.coordinate.latitude * 1000)),\(Int(site.coordinate.longitude * 1000))"

            if !seenLocations.contains(locationKey) {
                seenLocations.insert(locationKey)

                sites.append(ContextualSite(
                    id: "wd:\(site.id)",
                    name: site.name,
                    coordinate: site.coordinate,
                    source: .wikidata,
                    siteType: mapWikidataType(site.siteType),
                    description: site.description,
                    wikipediaURL: site.wikipediaURL,
                    timePeriod: site.timePeriod,
                    culture: site.culture,
                    distanceMeters: site.distanceMeters ?? 0
                ))
            }
        }

        // Add OSM sites (avoiding duplicates)
        for feature in osm.features {
            let locationKey = "\(Int(feature.latitude * 1000)),\(Int(feature.longitude * 1000))"

            // Skip if we already have a site at this location (prefer Wikidata)
            if seenLocations.contains(locationKey) {
                continue
            }
            seenLocations.insert(locationKey)

            sites.append(ContextualSite(
                id: "osm:\(feature.id)",
                name: feature.name,
                coordinate: feature.coordinate,
                source: .openStreetMap,
                siteType: mapOSMType(feature.category),
                description: feature.tags["description"],
                wikipediaURL: feature.tags["wikipedia"],
                timePeriod: feature.tags["start_date"],
                culture: nil,
                distanceMeters: feature.distanceMeters
            ))
        }

        // Sort by distance
        return sites.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func mapWikidataType(_ type: WikidataSite.WikidataSiteType) -> ContextualSite.SiteType {
        switch type {
        case .mound: return .mound
        case .earthwork: return .earthwork
        case .archaeologicalSite: return .archaeologicalSite
        case .ruins: return .ruins
        case .monument: return .monument
        case .historicSite, .nativeAmericanSite: return .historicSite
        case .other: return .other
        }
    }

    private func mapOSMType(_ category: OSMHistoricCategory) -> ContextualSite.SiteType {
        switch category {
        case .mound: return .mound
        case .archaeologicalSite: return .archaeologicalSite
        case .ruins: return .ruins
        case .megalith: return .archaeologicalSite
        case .monument: return .monument
        case .battlefield, .fortification: return .historicSite
        case .other: return .other
        }
    }

    // MARK: - Recommendations Building

    private func buildRecommendations(
        sites: [ContextualSite],
        wikidataResult: WikidataQueryResult,
        osmResult: OSMHistoricResult
    ) -> AnalysisRecommendations {
        guard !sites.isEmpty else {
            return .default
        }

        // Calculate sensitivity multiplier based on site density
        let sensitivityMultiplier: Double
        switch sites.count {
        case 0: sensitivityMultiplier = 1.0
        case 1...2: sensitivityMultiplier = 1.1
        case 3...5: sensitivityMultiplier = 1.15
        case 6...10: sensitivityMultiplier = 1.2
        default: sensitivityMultiplier = 1.25
        }

        // Determine suggested feature types based on what's in the region
        var suggestedTypes: Set<String> = []
        for site in sites {
            switch site.siteType {
            case .mound:
                suggestedTypes.insert("mound")
                suggestedTypes.insert("platform_mound")
            case .earthwork:
                suggestedTypes.insert("earthwork")
                suggestedTypes.insert("mound")
            case .archaeologicalSite:
                suggestedTypes.insert("archaeological_feature")
            case .ruins:
                suggestedTypes.insert("structure")
                suggestedTypes.insert("ruins")
            default:
                break
            }
        }
        if suggestedTypes.isEmpty {
            suggestedTypes = ["mound", "earthwork", "archaeological_feature"]
        }

        // Extract cultures and time periods
        let cultures = sites.compactMap { $0.culture }.unique()
        let periods = sites.compactMap { $0.timePeriod }.unique()

        // Build context summary
        let summary = buildContextSummary(sites: sites, cultures: cultures, periods: periods)

        // Confidence boost for features matching known sites
        let confidenceBoost = sites.count > 0 ? 1.15 : 1.0

        return AnalysisRecommendations(
            sensitivityMultiplier: sensitivityMultiplier,
            suggestedFeatureTypes: Array(suggestedTypes),
            dominantCultures: cultures,
            dominantTimePeriods: periods,
            contextSummary: summary,
            confidenceBoostForMatches: confidenceBoost
        )
    }

    private func buildContextSummary(
        sites: [ContextualSite],
        cultures: [String],
        periods: [String]
    ) -> String {
        var parts: [String] = []

        // Site count
        let archaeologicalCount = sites.filter { $0.siteType.isArchaeological }.count
        if archaeologicalCount > 0 {
            parts.append("\(archaeologicalCount) known archaeological site\(archaeologicalCount == 1 ? "" : "s") in region")
        }

        // Mound specific
        let moundCount = sites.filter { $0.siteType == .mound || $0.siteType == .earthwork }.count
        if moundCount > 0 {
            parts.append("including \(moundCount) mound/earthwork site\(moundCount == 1 ? "" : "s")")
        }

        // Cultures
        if !cultures.isEmpty {
            let cultureStr = cultures.prefix(3).joined(separator: ", ")
            parts.append("Associated cultures: \(cultureStr)")
        }

        // Time periods
        if !periods.isEmpty {
            let periodStr = periods.prefix(2).joined(separator: ", ")
            parts.append("Time periods: \(periodStr)")
        }

        // Nearest site
        if let nearest = sites.first {
            let distanceKm = nearest.distanceMeters / 1000
            parts.append("Nearest: \(nearest.name) (\(String(format: "%.1f", distanceKm))km)")
        }

        if parts.isEmpty {
            return "Limited archaeological data available for this region."
        }

        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Array Extension

private extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
