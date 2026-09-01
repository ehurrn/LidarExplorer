//
//  DetectedFeature.swift
//  LidarExplorer
//
//  The central domain entity: a candidate anthropogenic landform.
//

import CoreLocation
import Foundation

/// The kind of landform a detector proposes.
public nonisolated enum FeatureKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case mound
    case linearEarthwork
    case enclosure
    case terrace
    case depression

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mound: "Mound"
        case .linearEarthwork: "Linear earthwork"
        case .enclosure: "Enclosure"
        case .terrace: "Terrace"
        case .depression: "Depression"
        }
    }

    public var symbolName: String {
        switch self {
        case .mound: "mountain.2.fill"
        case .linearEarthwork: "line.diagonal"
        case .enclosure: "circle.dashed"
        case .terrace: "square.stack.3d.down.right.fill"
        case .depression: "arrow.down.to.line"
        }
    }
}

/// Calibrated confidence bands.
///
/// Backed by a continuous score so the band is derived, never assigned
/// independently of the number that justifies it.
public nonisolated enum Confidence: String, Sendable, Codable, Comparable, CaseIterable {
    case low
    case moderate
    case high
    case corroborated

    /// Inclusive lower bound of the band.
    public var lowerBound: Double {
        switch self {
        case .low: 0.0
        case .moderate: 0.55
        case .high: 0.72
        case .corroborated: 0.87
        }
    }

    public static func band(for score: Double) -> Confidence {
        switch score {
        case Confidence.corroborated.lowerBound...: .corroborated
        case Confidence.high.lowerBound...: .high
        case Confidence.moderate.lowerBound...: .moderate
        default: .low
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.lowerBound < rhs.lowerBound
    }

    public var displayName: String { rawValue.capitalized }
}

/// Physical extent of a candidate, in metres.
public nonisolated struct FeatureDimensions: Sendable, Codable, Equatable {
    /// Height above the local surrounding surface. Negative for depressions.
    public let reliefMeters: Double
    /// Longest horizontal axis.
    public let majorAxisMeters: Double
    /// Shortest horizontal axis, perpendicular to the major.
    public let minorAxisMeters: Double

    public init(reliefMeters: Double, majorAxisMeters: Double, minorAxisMeters: Double) {
        self.reliefMeters = reliefMeters
        self.majorAxisMeters = majorAxisMeters
        self.minorAxisMeters = minorAxisMeters
    }

    /// Ratio of minor to major axis, `0...1`. 1.0 is perfectly circular.
    public var elongation: Double {
        majorAxisMeters > 0 ? minorAxisMeters / majorAxisMeters : 0
    }

    /// Relief divided by mean horizontal extent.
    ///
    /// Constructed mounds cluster in a narrow band of this ratio; spoil heaps
    /// and natural knolls sit outside it.
    public var aspectRatio: Double {
        let meanWidth = (majorAxisMeters + minorAxisMeters) / 2
        return meanWidth > 0 ? abs(reliefMeters) / meanWidth : 0
    }

    /// Ellipse-approximated footprint in square metres.
    public var footprintSquareMeters: Double {
        .pi * (majorAxisMeters / 2) * (minorAxisMeters / 2)
    }
}

/// A candidate anthropogenic landform proposed by a detector and scored by
/// corroboration.
///
/// Immutable by construction. Re-scoring produces a new value rather than
/// mutating in place, so a feature and the evidence that justified it can
/// never drift apart.
public nonisolated struct DetectedFeature: Sendable, Identifiable, Equatable {

    public let id: UUID
    public let kind: FeatureKind
    public let coordinate: CLLocationCoordinate2D
    public let dimensions: FeatureDimensions

    /// Detector output before corroboration, `0...1`.
    public let detectorScore: Double

    /// Multi-source corroboration, or `nil` if not yet corroborated.
    public let corroboration: Corroboration?

    /// When this candidate was produced on device.
    public let detectedAt: Date

    /// Free-form notes accumulated during analysis.
    public let notes: [String]

    public init(
        id: UUID = UUID(),
        kind: FeatureKind,
        coordinate: CLLocationCoordinate2D,
        dimensions: FeatureDimensions,
        detectorScore: Double,
        corroboration: Corroboration? = nil,
        detectedAt: Date,
        notes: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.dimensions = dimensions
        self.detectorScore = min(max(detectorScore, 0), 1)
        self.corroboration = corroboration
        self.detectedAt = detectedAt
        self.notes = notes
    }

    /// Final score: the detector's own score tempered by corroboration.
    ///
    /// When corroboration could not be computed the detector score stands
    /// alone and is explicitly capped below the `.high` band — an uncorroborated
    /// candidate must never present as strongly as a corroborated one.
    public var score: Double {
        guard let composite = corroboration?.compositeScore else {
            return min(detectorScore, Confidence.high.lowerBound - 0.01)
        }
        return detectorScore * composite
    }

    public var confidence: Confidence { .band(for: score) }

    /// Caveat describing evidence gaps, suitable for display under the score.
    public var caveat: String? {
        corroboration?.caveat ?? "Not corroborated against external sources"
    }

    /// Returns a copy carrying the given corroboration.
    public func corroborated(by corroboration: Corroboration) -> DetectedFeature {
        DetectedFeature(
            id: id,
            kind: kind,
            coordinate: coordinate,
            dimensions: dimensions,
            detectorScore: detectorScore,
            corroboration: corroboration,
            detectedAt: detectedAt,
            notes: notes
        )
    }

    /// Returns a copy with an additional note.
    public func annotated(_ note: String) -> DetectedFeature {
        DetectedFeature(
            id: id, kind: kind, coordinate: coordinate, dimensions: dimensions,
            detectorScore: detectorScore, corroboration: corroboration,
            detectedAt: detectedAt, notes: notes + [note]
        )
    }

    public static func == (lhs: DetectedFeature, rhs: DetectedFeature) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.detectorScore == rhs.detectorScore
            && lhs.corroboration == rhs.corroboration
    }
}
