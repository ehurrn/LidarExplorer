//
//  HistoricalOverlayService.swift
//  LidarExplorer
//
//  Created by Claude on 1/19/26.
//

import Foundation
import MapKit

class HistoricalOverlayService {
    static let shared = HistoricalOverlayService()

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

        print("📚 Loaded historical data:")
        print("   - \(territories.count) Native American territories")
        print("   - \(trails.count) historical trails")
        print("   - \(civilWarSites.count) Civil War sites")
        print("   - \(archaeologicalSites.count) archaeological sites")
    }

    private func loadTerritories() -> [HistoricalTerritory] {
        guard let data = loadJSONFile(named: "native_american_territories") else {
            print("⚠️ Failed to load native_american_territories.json")
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
            print("⚠️ Error decoding territories: \(error)")
            return []
        }
    }

    private func loadTrails() -> [HistoricalTrail] {
        guard let data = loadJSONFile(named: "historical_trails") else {
            print("⚠️ Failed to load historical_trails.json")
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
            print("⚠️ Error decoding trails: \(error)")
            return []
        }
    }

    private func loadCivilWarSites() -> [HistoricalSite] {
        guard let data = loadJSONFile(named: "civil_war_sites") else {
            print("⚠️ Failed to load civil_war_sites.json")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jsonSites = try decoder.decode([SiteJSON].self, from: data)
            return jsonSites.compactMap { json in
                HistoricalSite(
                    name: json.name,
                    type: .civilWarSite,
                    coordinate: CLLocationCoordinate2D(latitude: json.coordinate.latitude, longitude: json.coordinate.longitude),
                    description: json.description,
                    timePeriod: json.timePeriod,
                    significance: json.significance,
                    dateEstablished: json.dateEstablished
                )
            }
        } catch {
            print("⚠️ Error decoding civil war sites: \(error)")
            return []
        }
    }

    private func loadArchaeologicalSites() -> [HistoricalSite] {
        guard let data = loadJSONFile(named: "archaeological_sites") else {
            print("⚠️ Failed to load archaeological_sites.json")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jsonSites = try decoder.decode([SiteJSON].self, from: data)
            return jsonSites.compactMap { json in
                HistoricalSite(
                    name: json.name,
                    type: .archaeologicalSite,
                    coordinate: CLLocationCoordinate2D(latitude: json.coordinate.latitude, longitude: json.coordinate.longitude),
                    description: json.description,
                    timePeriod: json.timePeriod,
                    significance: json.significance,
                    dateEstablished: json.dateEstablished
                )
            }
        } catch {
            print("⚠️ Error decoding archaeological sites: \(error)")
            return []
        }
    }

    private func loadJSONFile(named filename: String) -> Data? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            print("⚠️ Could not find \(filename).json in bundle")
            return nil
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            print("⚠️ Error reading \(filename).json: \(error)")
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
