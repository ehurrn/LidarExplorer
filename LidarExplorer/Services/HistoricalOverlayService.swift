//
//  HistoricalOverlayService.swift
//  LidarExplorer
//
//  Created by Claude on 1/19/26.
//

import Foundation
import MapKit
import OSLog

class HistoricalOverlayService {
    static let shared = HistoricalOverlayService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "HistoricalOverlayService")

    // Cached data
    private var territories: [HistoricalTerritory] = []
    private var trails: [HistoricalTrail] = []
    private var civilWarSites: [HistoricalSite] = []
    private var archaeologicalSites: [HistoricalSite] = []

    private init() {
        loadAllData()
    }

    // MARK: - Public API

    func getNativeAmericanTerritories() -> [HistoricalTerritory] {
        return territories
    }

    func getHistoricalTrails() -> [HistoricalTrail] {
        return trails
    }

    func getCivilWarSites() -> [HistoricalSite] {
        return civilWarSites
    }

    func getArchaeologicalSites() -> [HistoricalSite] {
        return archaeologicalSites
    }

    func getAllTerritories() -> [HistoricalTerritory] {
        return territories
    }

    func getAllTrails() -> [HistoricalTrail] {
        return trails
    }

    func getAllSites() -> [HistoricalSite] {
        return civilWarSites + archaeologicalSites
    }

    func getSites(ofType type: HistoricalOverlayType) -> [HistoricalSite] {
        return getAllSites().filter { $0.type == type }
    }

    // MARK: - Data Loading

    private func loadAllData() {
        territories = loadTerritories()
        trails = loadTrails()
        civilWarSites = loadCivilWarSites()
        archaeologicalSites = loadArchaeologicalSites()

        logger.info("Loaded historical data: \(self.territories.count) territories, \(self.trails.count) trails, \(self.civilWarSites.count) Civil War sites, \(self.archaeologicalSites.count) archaeological sites")
    }

    private func loadTerritories() -> [HistoricalTerritory] {
        guard let data = loadJSONFile(named: "native_american_territories") else {
            logger.warning("Failed to load native_american_territories.json")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jsonTerritories = try decoder.decode([TerritoryJSON].self, from: data)
            return jsonTerritories.compactMap { json in
                HistoricalTerritory(
                    name: json.name,
                    type: .nativeAmericanTerritory,
                    coordinates: json.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                    description: json.description,
                    timePeriod: json.timePeriod,
                    culturalGroup: json.culturalGroup
                )
            }
        } catch {
            logger.error("Error decoding territories: \(error.localizedDescription)")
            return []
        }
    }

    private func loadTrails() -> [HistoricalTrail] {
        guard let data = loadJSONFile(named: "historical_trails") else {
            logger.warning("Failed to load historical_trails.json")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jsonTrails = try decoder.decode([TrailJSON].self, from: data)
            return jsonTrails.compactMap { json in
                HistoricalTrail(
                    name: json.name,
                    coordinates: json.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                    description: json.description,
                    timePeriod: json.timePeriod,
                    lengthMiles: json.lengthMiles
                )
            }
        } catch {
            logger.error("Error decoding trails: \(error.localizedDescription)")
            return []
        }
    }

    private func loadCivilWarSites() -> [HistoricalSite] {
        return loadSites(filename: "civil_war_sites", type: .civilWarSite, typeName: "civil war sites")
    }

    private func loadArchaeologicalSites() -> [HistoricalSite] {
        return loadSites(filename: "archaeological_sites", type: .archaeologicalSite, typeName: "archaeological sites")
    }

    private func loadSites(filename: String, type: HistoricalOverlayType, typeName: String) -> [HistoricalSite] {
        guard let data = loadJSONFile(named: filename) else {
            logger.warning("Failed to load \(filename).json")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jsonSites = try decoder.decode([SiteJSON].self, from: data)
            return jsonSites.compactMap { json in
                HistoricalSite(
                    name: json.name,
                    type: type,
                    coordinate: CLLocationCoordinate2D(latitude: json.coordinate.latitude, longitude: json.coordinate.longitude),
                    description: json.description,
                    timePeriod: json.timePeriod,
                    significance: json.significance,
                    dateEstablished: json.dateEstablished
                )
            }
        } catch {
            logger.error("Error decoding \(typeName): \(error.localizedDescription)")
            return []
        }
    }

    private func loadJSONFile(named filename: String) -> Data? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            logger.warning("Could not find \(filename).json in bundle")
            return nil
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("Error reading \(filename).json: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - JSON Decodable Models

private struct TerritoryJSON: Decodable {
    let name: String
    let type: String
    let culturalGroup: String?
    let timePeriod: String
    let description: String
    let coordinates: [CoordinateJSON]
}

private struct TrailJSON: Decodable {
    let name: String
    let timePeriod: String
    let lengthMiles: Double?
    let description: String
    let coordinates: [CoordinateJSON]
}

private struct SiteJSON: Decodable {
    let name: String
    let type: String
    let coordinate: CoordinateJSON
    let timePeriod: String
    let significance: String
    let dateEstablished: String?
    let description: String
}

private struct CoordinateJSON: Decodable {
    let latitude: Double
    let longitude: Double
}
