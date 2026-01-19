//
//  HistoricalOverlay.swift
//  LidarExplorer
//
//  Created by Claude on 1/19/26.
//

import Foundation
import MapKit

// MARK: - Historical Overlay Types

enum HistoricalOverlayType: String, Codable, CaseIterable, Identifiable {
    case nativeAmericanTerritory = "Native American Territories"
    case civilWarSite = "Civil War Sites"
    case historicalTrail = "Historical Trails"
    case archaeologicalSite = "Archaeological Sites"

    var id: String { rawValue }

    var systemIconName: String {
        switch self {
        case .nativeAmericanTerritory: return "map.fill"
        case .civilWarSite: return "flag.fill"
        case .historicalTrail: return "arrow.triangle.turn.up.right.diamond.fill"
        case .archaeologicalSite: return "building.columns.fill"
        }
    }

    var color: Color {
        switch self {
        case .nativeAmericanTerritory: return .purple.opacity(0.3)
        case .civilWarSite: return .red.opacity(0.4)
        case .historicalTrail: return .orange
        case .archaeologicalSite: return .blue.opacity(0.4)
        }
    }

    var strokeColor: Color {
        switch self {
        case .nativeAmericanTerritory: return .purple
        case .civilWarSite: return .red
        case .historicalTrail: return .orange
        case .archaeologicalSite: return .blue
        }
    }
}

// MARK: - Territory (Polygon Area)

struct HistoricalTerritory: Identifiable, Codable {
    let id: UUID
    let name: String
    let type: HistoricalOverlayType
    let coordinates: [CLLocationCoordinate2D]
    let description: String
    let timePeriod: String
    let culturalGroup: String?

    init(id: UUID = UUID(),
         name: String,
         type: HistoricalOverlayType,
         coordinates: [CLLocationCoordinate2D],
         description: String,
         timePeriod: String,
         culturalGroup: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.coordinates = coordinates
        self.description = description
        self.timePeriod = timePeriod
        self.culturalGroup = culturalGroup
    }

    // Codable conformance for CLLocationCoordinate2D
    enum CodingKeys: String, CodingKey {
        case id, name, type, coordinates, description, timePeriod, culturalGroup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(HistoricalOverlayType.self, forKey: .type)
        description = try container.decode(String.self, forKey: .description)
        timePeriod = try container.decode(String.self, forKey: .timePeriod)
        culturalGroup = try container.decodeIfPresent(String.self, forKey: .culturalGroup)

        let coordData = try container.decode([[String: Double]].self, forKey: .coordinates)
        coordinates = coordData.compactMap { dict in
            guard let lat = dict["latitude"], let lon = dict["longitude"] else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(description, forKey: .description)
        try container.encode(timePeriod, forKey: .timePeriod)
        try container.encodeIfPresent(culturalGroup, forKey: .culturalGroup)

        let coordData = coordinates.map { ["latitude": $0.latitude, "longitude": $0.longitude] }
        try container.encode(coordData, forKey: .coordinates)
    }
}

// MARK: - Trail (Polyline Path)

struct HistoricalTrail: Identifiable, Codable {
    let id: UUID
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let description: String
    let timePeriod: String
    let lengthMiles: Double?

    init(id: UUID = UUID(),
         name: String,
         coordinates: [CLLocationCoordinate2D],
         description: String,
         timePeriod: String,
         lengthMiles: Double? = nil) {
        self.id = id
        self.name = name
        self.coordinates = coordinates
        self.description = description
        self.timePeriod = timePeriod
        self.lengthMiles = lengthMiles
    }

    // Codable conformance for CLLocationCoordinate2D
    enum CodingKeys: String, CodingKey {
        case id, name, coordinates, description, timePeriod, lengthMiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        timePeriod = try container.decode(String.self, forKey: .timePeriod)
        lengthMiles = try container.decodeIfPresent(Double.self, forKey: .lengthMiles)

        let coordData = try container.decode([[String: Double]].self, forKey: .coordinates)
        coordinates = coordData.compactMap { dict in
            guard let lat = dict["latitude"], let lon = dict["longitude"] else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(timePeriod, forKey: .timePeriod)
        try container.encodeIfPresent(lengthMiles, forKey: .lengthMiles)

        let coordData = coordinates.map { ["latitude": $0.latitude, "longitude": $0.longitude] }
        try container.encode(coordData, forKey: .coordinates)
    }
}

// MARK: - Site (Point Location)

struct HistoricalSite: Identifiable, Codable {
    let id: UUID
    let name: String
    let type: HistoricalOverlayType
    let coordinate: CLLocationCoordinate2D
    let description: String
    let timePeriod: String
    let significance: String
    let dateEstablished: String?

    init(id: UUID = UUID(),
         name: String,
         type: HistoricalOverlayType,
         coordinate: CLLocationCoordinate2D,
         description: String,
         timePeriod: String,
         significance: String,
         dateEstablished: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.coordinate = coordinate
        self.description = description
        self.timePeriod = timePeriod
        self.significance = significance
        self.dateEstablished = dateEstablished
    }

    // Codable conformance for CLLocationCoordinate2D
    enum CodingKeys: String, CodingKey {
        case id, name, type, coordinate, description, timePeriod, significance, dateEstablished
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(HistoricalOverlayType.self, forKey: .type)
        description = try container.decode(String.self, forKey: .description)
        timePeriod = try container.decode(String.self, forKey: .timePeriod)
        significance = try container.decode(String.self, forKey: .significance)
        dateEstablished = try container.decodeIfPresent(String.self, forKey: .dateEstablished)

        let coordData = try container.decode([String: Double].self, forKey: .coordinate)
        guard let lat = coordData["latitude"], let lon = coordData["longitude"] else {
            throw DecodingError.dataCorruptedError(forKey: .coordinate,
                                                   in: container,
                                                   debugDescription: "Invalid coordinate data")
        }
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(description, forKey: .description)
        try container.encode(timePeriod, forKey: .timePeriod)
        try container.encode(significance, forKey: .significance)
        try container.encodeIfPresent(dateEstablished, forKey: .dateEstablished)

        let coordData = ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
        try container.encode(coordData, forKey: .coordinate)
    }
}

// MARK: - MapKit Integration

// Custom overlay for territories
class TerritoryOverlay: NSObject, MKOverlay {
    let territory: HistoricalTerritory
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(territory: HistoricalTerritory) {
        self.territory = territory

        // Calculate center and bounding rect
        var minLat = territory.coordinates.first?.latitude ?? 0
        var maxLat = minLat
        var minLon = territory.coordinates.first?.longitude ?? 0
        var maxLon = minLon

        for coord in territory.coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        self.coordinate = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))

        self.boundingMapRect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
}

// Custom overlay for trails
class TrailOverlay: NSObject, MKOverlay {
    let trail: HistoricalTrail
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(trail: HistoricalTrail) {
        self.trail = trail

        // Calculate center and bounding rect
        var minLat = trail.coordinates.first?.latitude ?? 0
        var maxLat = minLat
        var minLon = trail.coordinates.first?.longitude ?? 0
        var maxLon = minLon

        for coord in trail.coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        self.coordinate = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))

        self.boundingMapRect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
}

// Custom annotation for historical sites
class HistoricalSiteAnnotation: NSObject, MKAnnotation {
    let site: HistoricalSite
    var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(site: HistoricalSite) {
        self.site = site
        self.coordinate = site.coordinate
        self.title = site.name
        self.subtitle = site.timePeriod
    }
}

// MARK: - SwiftUI Color Extension

import SwiftUI

extension Color {
    var uiColor: UIColor {
        UIColor(self)
    }
}
