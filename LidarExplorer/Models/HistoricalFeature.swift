//
//  HistoricalFeature.swift
//  LidarExplorer
//
//  Created for historical site detection feature
//

import Foundation
import MapKit

// MARK: - Feature Type Classification

enum FeatureType: String, CaseIterable, Codable, Sendable {
    case earthwork = "Earthwork"
    case mound = "Mound"
    case linearFeature = "Linear Feature"
    case circularPattern = "Circular Pattern"
    case buildingFoundation = "Building Foundation"
    case terrace = "Terrace"
    case roadTrace = "Road Trace"
    case fortification = "Fortification"
    case settlement = "Settlement Pattern"
    case unknown = "Unknown Anomaly"

    var icon: String {
        switch self {
        case .earthwork: return "mountain.2"
        case .mound: return "triangle.fill"
        case .linearFeature: return "line.diagonal"
        case .circularPattern: return "circle"
        case .buildingFoundation: return "building.2"
        case .terrace: return "rectangle.stack"
        case .roadTrace: return "road.lanes"
        case .fortification: return "shield"
        case .settlement: return "house.and.flag"
        case .unknown: return "questionmark.diamond"
        }
    }

    var color: String {
        switch self {
        case .earthwork: return "brown"
        case .mound: return "orange"
        case .linearFeature: return "blue"
        case .circularPattern: return "purple"
        case .buildingFoundation: return "red"
        case .terrace: return "green"
        case .roadTrace: return "gray"
        case .fortification: return "yellow"
        case .settlement: return "pink"
        case .unknown: return "white"
        }
    }
}

// MARK: - Detection Confidence Level

enum DetectionConfidence: String, Codable, Sendable {
    case veryLow = "Very Low"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case veryHigh = "Very High"
    case confirmed = "Confirmed" // Manually verified or from known database

    nonisolated var threshold: Double {
        switch self {
        case .veryLow: return 0.2
        case .low: return 0.4
        case .medium: return 0.6
        case .high: return 0.8
        case .veryHigh: return 0.9
        case .confirmed: return 1.0
        }
    }

    nonisolated static func from(score: Double) -> DetectionConfidence {
        switch score {
        case 0.9...: return .veryHigh
        case 0.8..<0.9: return .high
        case 0.6..<0.8: return .medium
        case 0.4..<0.6: return .low
        default: return .veryLow
        }
    }
}

extension DetectionConfidence: Comparable {
    nonisolated static func < (lhs: DetectionConfidence, rhs: DetectionConfidence) -> Bool {
        lhs.threshold < rhs.threshold
    }
}

// MARK: - Historical Feature Model

struct HistoricalFeature: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let featureType: FeatureType
    let confidence: DetectionConfidence
    let detectionDate: Date
    let area: Double? // Square meters
    let dimensions: FeatureDimensions?
    let metadata: FeatureMetadata

    nonisolated var title: String {
        metadata.customName ?? featureType.rawValue
    }

    nonisolated var subtitle: String {
        "Confidence: \(confidence.rawValue)"
    }

    nonisolated init(
        id: UUID = UUID(),
        coordinate: CLLocationCoordinate2D,
        featureType: FeatureType,
        confidence: DetectionConfidence,
        detectionDate: Date = Date(),
        area: Double? = nil,
        dimensions: FeatureDimensions? = nil,
        metadata: FeatureMetadata = FeatureMetadata()
    ) {
        self.id = id
        self.coordinate = coordinate
        self.featureType = featureType
        self.confidence = confidence
        self.detectionDate = detectionDate
        self.area = area
        self.dimensions = dimensions
        self.metadata = metadata
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistoricalFeature, rhs: HistoricalFeature) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Feature Dimensions

struct FeatureDimensions: Codable, Sendable, Hashable {
    let length: Double? // meters
    let width: Double? // meters
    let height: Double? // meters (elevation change)
    let diameter: Double? // meters (for circular features)

    nonisolated var description: String {
        var parts: [String] = []
        if let length = length { parts.append("L: \(Int(length))m") }
        if let width = width { parts.append("W: \(Int(width))m") }
        if let height = height { parts.append("H: \(Int(height))m") }
        if let diameter = diameter { parts.append("D: \(Int(diameter))m") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Feature Metadata

struct FeatureMetadata: Codable, Sendable, Hashable {
    var customName: String?
    var notes: String?
    var historicalPeriod: String?
    var culture: String?
    var verified: Bool = false
    var verificationDate: Date?
    var verifiedBy: String?
    var photos: [String] = [] // URLs or file paths
    var references: [String] = [] // Bibliography

    nonisolated init(
        customName: String? = nil,
        notes: String? = nil,
        historicalPeriod: String? = nil,
        culture: String? = nil,
        verified: Bool = false
    ) {
        self.customName = customName
        self.notes = notes
        self.historicalPeriod = historicalPeriod
        self.culture = culture
        self.verified = verified
    }
}

// MARK: - CLLocationCoordinate2D Extensions

extension CLLocationCoordinate2D: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        self.init(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Analysis Settings

struct AnalysisSettings: Codable, Sendable {
    var enabled: Bool
    var minimumConfidence: DetectionConfidence
    var featureTypesFilter: Set<FeatureType>
    var analyzeInRealtime: Bool
    var highlightColor: String
    var highlightOpacity: Double

    // Detection algorithm parameters
    var slopeThreshold: Double // degrees
    var elevationChangeThreshold: Double // meters
    var circularityThreshold: Double // 0-1
    var linearityThreshold: Double // 0-1
    var minimumFeatureSize: Double // meters
    var maximumFeatureSize: Double // meters

    nonisolated init(
        enabled: Bool = false,
        minimumConfidence: DetectionConfidence = .high,
        featureTypesFilter: Set<FeatureType> = Set(FeatureType.allCases),
        analyzeInRealtime: Bool = false,
        highlightColor: String = "yellow",
        highlightOpacity: Double = 0.6,
        slopeThreshold: Double = 5.0,
        elevationChangeThreshold: Double = 1.0,
        circularityThreshold: Double = 0.7,
        linearityThreshold: Double = 0.8,
        minimumFeatureSize: Double = 5.0,
        maximumFeatureSize: Double = 500.0
    ) {
        self.enabled = enabled
        self.minimumConfidence = minimumConfidence
        self.featureTypesFilter = featureTypesFilter
        self.analyzeInRealtime = analyzeInRealtime
        self.highlightColor = highlightColor
        self.highlightOpacity = highlightOpacity
        self.slopeThreshold = slopeThreshold
        self.elevationChangeThreshold = elevationChangeThreshold
        self.circularityThreshold = circularityThreshold
        self.linearityThreshold = linearityThreshold
        self.minimumFeatureSize = minimumFeatureSize
        self.maximumFeatureSize = maximumFeatureSize
    }
}
