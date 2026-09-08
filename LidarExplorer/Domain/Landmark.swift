//
//  Landmark.swift
//  LidarExplorer
//
//  Curated archaeological/geological sites and user bookmarks.
//

import CoreLocation
import Foundation

public nonisolated struct Landmark: Identifiable, Hashable, Sendable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case earthworks = "Earthworks"
        case volcanic = "Volcanic"
        case tectonic = "Tectonic"
        case craters = "Craters"
        case fluvial = "Rivers & Canyons"
        case custom = "My Bookmarks"

        public var iconName: String {
            switch self {
            case .earthworks: return "pyramid.fill"
            case .volcanic: return "mountain.2.fill"
            case .tectonic: return "waveform.path.ecg"
            case .craters: return "circle.dotted"
            case .fluvial: return "water.waves"
            case .custom: return "bookmark.fill"
            }
        }
    }

    public let id: UUID
    public let name: String
    public let subtitle: String
    public let category: Category
    public let latitude: Double
    public let longitude: Double
    public let altitudeMeters: Double
    public let recommendedAzimuth: Double

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String,
        category: Category,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double = 3500,
        recommendedAzimuth: Double = 315
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.recommendedAzimuth = recommendedAzimuth
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public static let curatedSites: [Landmark] = [
        Landmark(
            name: "Cahokia Monks Mound",
            subtitle: "Largest pre-Columbian earthwork in the Americas (Collinsville, IL)",
            category: .earthworks,
            latitude: 38.6605,
            longitude: -90.0621,
            altitudeMeters: 2200,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Serpent Mound",
            subtitle: "1,348-foot prehistoric effigy mound on a meteorite crater rim (Peebles, OH)",
            category: .earthworks,
            latitude: 39.0254,
            longitude: -83.4300,
            altitudeMeters: 1800,
            recommendedAzimuth: 330
        ),
        Landmark(
            name: "Newark Octagon Earthworks",
            subtitle: "Ancient geometric Hopewell astronomical lunar observatory (Newark, OH)",
            category: .earthworks,
            latitude: 40.0520,
            longitude: -82.4430,
            altitudeMeters: 2600,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Poverty Point Ridges",
            subtitle: "3,500-year-old concentric semicircular geometric earth ridges (Epps, LA)",
            category: .earthworks,
            latitude: 32.6358,
            longitude: -91.4105,
            altitudeMeters: 3000,
            recommendedAzimuth: 300
        ),
        Landmark(
            name: "Mount St. Helens Crater",
            subtitle: "1980 blast caldera and resurgent lava dome (Skamania County, WA)",
            category: .volcanic,
            latitude: 46.1914,
            longitude: -122.1956,
            altitudeMeters: 7500,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Meteor Crater (Barringer)",
            subtitle: "Supersonic nickel-iron meteorite impact bowl (Winslow, AZ)",
            category: .craters,
            latitude: 35.0276,
            longitude: -111.0223,
            altitudeMeters: 4000,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "San Andreas Fault Scarps",
            subtitle: "Clear tectonic displacement scarps across the Carrizo Plain (San Luis Obispo, CA)",
            category: .tectonic,
            latitude: 35.1205,
            longitude: -119.6450,
            altitudeMeters: 3800,
            recommendedAzimuth: 45
        ),
        Landmark(
            name: "Goosenecks of the San Juan",
            subtitle: "Deeply entrenched meanders cut 1,000 ft into Colorado Plateau limestone (Mexican Hat, UT)",
            category: .fluvial,
            latitude: 37.1747,
            longitude: -109.9270,
            altitudeMeters: 5500,
            recommendedAzimuth: 315
        )
    ]
}
