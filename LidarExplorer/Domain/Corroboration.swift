//
//  Corroboration.swift
//  LidarExplorer
//
//  Weighted multi-source scoring that re-normalises over available evidence.
//

import Foundation

/// An independent line of evidence about whether a candidate is anthropogenic.
public nonisolated enum EvidenceDimension: String, Sendable, Codable, CaseIterable {
    /// Proximity to mapped modern infrastructure (roads, buildings, utilities).
    case modernInfrastructure = "Modern infrastructure"
    /// Spectral terrain classification from satellite reflectance.
    case spectralTerrain = "Spectral terrain"
    /// Vegetation vigour and disturbance signature.
    case vegetation = "Vegetation"
    /// Shape plausibility measured against the elevation model.
    case morphology = "Morphology"
    /// Corroboration by a catalogued archaeological record.
    case knownRecord = "Known record"

    /// Nominal weight when every dimension has data. Sums to 1.0.
    public var nominalWeight: Double {
        switch self {
        case .modernInfrastructure: 0.30
        case .spectralTerrain: 0.20
        case .vegetation: 0.15
        case .morphology: 0.25
        case .knownRecord: 0.10
        }
    }
}

/// The outcome of corroborating a candidate across several dimensions.
public nonisolated struct Corroboration: Sendable, Equatable {

    /// Per-dimension scores in `0...1`, or the reason each is missing.
    public let evidence: [EvidenceDimension: Observation<Double>]

    /// Weighted mean over the dimensions that actually produced data,
    /// renormalised so present weights sum to 1. `nil` when evidence is
    /// too thin to score at all.
    public let compositeScore: Double?

    /// Fraction of the nominal weight backed by real observations, `0...1`.
    ///
    /// This is the number that was missing from the previous design. A
    /// composite of 0.82 means something very different at `evidenceCoverage`
    /// 1.0 than at 0.25, and the UI must be able to say so.
    public let evidenceCoverage: Double

    /// Dimensions that returned no data, with the reason for each.
    public let gaps: [EvidenceDimension: UnavailableReason]

    /// Minimum share of nominal weight required before a composite is emitted.
    ///
    /// Below this, the honest answer is "not enough evidence", not a number
    /// derived from one surviving source and presented with the same
    /// authority as a fully corroborated one.
    public static let minimumEvidenceCoverage = 0.40

    /// Builds a corroboration from per-dimension observations.
    ///
    /// Weights are renormalised across present dimensions only. A dimension
    /// that could not be measured contributes nothing — it does not silently
    /// become a neutral 0.5, and it does not get replaced by a constant.
    public init(evidence: [EvidenceDimension: Observation<Double>]) {
        self.evidence = evidence

        var weighted = 0.0
        var presentWeight = 0.0
        var gaps: [EvidenceDimension: UnavailableReason] = [:]

        for dimension in EvidenceDimension.allCases {
            guard let observation = evidence[dimension] else {
                gaps[dimension] = .noCoverage(.onDeviceAnalysis)
                continue
            }
            switch observation {
            case .observed(let score, _):
                let clamped = min(max(score, 0), 1)
                weighted += clamped * dimension.nominalWeight
                presentWeight += dimension.nominalWeight
            case .unavailable(let reason):
                gaps[dimension] = reason
            }
        }

        self.gaps = gaps
        self.evidenceCoverage = presentWeight
        self.compositeScore =
            presentWeight >= Self.minimumEvidenceCoverage
            ? weighted / presentWeight
            : nil
    }

    /// Dimensions that produced a score above `threshold`.
    public func corroboratingDimensions(above threshold: Double = 0.5) -> [EvidenceDimension] {
        evidence.compactMap { dimension, observation in
            guard let score = observation.value, score > threshold else { return nil }
            return dimension
        }
    }

    /// Whether the candidate survives corroboration.
    ///
    /// Requires both a composite above `minimumComposite` and at least two
    /// independent dimensions agreeing. One strong source is not
    /// corroboration — that is the definition the previous implementation
    /// claimed and did not enforce, because two of its four "independent"
    /// sources were derived from the same fabricated constants.
    public func isSupported(minimumComposite: Double = 0.6) -> Bool {
        guard let composite = compositeScore, composite >= minimumComposite else { return false }
        return corroboratingDimensions().count >= 2
    }

    /// A caveat to show alongside the score, or `nil` when fully corroborated.
    public var caveat: String? {
        guard compositeScore != nil else {
            return "Not enough evidence to score (\(Int(evidenceCoverage * 100))% of sources available)"
        }
        guard evidenceCoverage < 0.999 else { return nil }
        let missing = gaps.values.map(\.displayText).sorted().joined(separator: "; ")
        return "Scored on \(Int(evidenceCoverage * 100))% of intended evidence — \(missing)"
    }
}
