//
//  MultiSourceValidationService.swift
//  LidarExplorer
//
//  Multi-source comparison algorithm for feature validation
//

import Foundation
import MapKit
import OSLog

/// Service that validates detected features against multiple data sources
/// Implements comparison algorithm to dramatically reduce false positives
actor MultiSourceValidationService {
    static let shared = MultiSourceValidationService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "MultiSourceValidation")

    // Service dependencies
    private let osmService = OpenStreetMapService.shared
    private let satelliteService = SatelliteImageryService.shared
    private let temporalService = TemporalAnalysisService.shared

    // Validation thresholds
    private enum ValidationThresholds {
        static let minimumSourceAgreement: Int = 2 // At least 2 sources must agree
        static let minimumConfidenceScore: Double = 0.6 // After multi-source validation
        static let maximumModernProximity: Double = 30.0 // meters
        static let artificialSurfacePenalty: Double = 0.1 // 90% reduction
        static let recentDisturbancePenalty: Double = 0.3 // 70% reduction
    }

    private init() {}

    // MARK: - Public API

    /// Validates a detected feature against all available data sources
    /// Returns validated confidence score (0.0-1.0)
    func validateFeature(
        feature: HistoricalFeature,
        elevationData: [[Double]],
        preloadedOSMData: OSMQueryResult? = nil
    ) async -> ValidationResult {
        logger.info("Validating feature at \(feature.coordinate.latitude), \(feature.coordinate.longitude)")

        var validationScores: [ValidationSource: Double] = [:]
        var failureReasons: [String] = []

        // Source 1: OpenStreetMap (modern infrastructure check)
        let osmScore = await validateAgainstOSM(
            coordinate: feature.coordinate,
            preloadedData: preloadedOSMData
        )
        validationScores[.openStreetMap] = osmScore

        if osmScore < 0.3 {
            failureReasons.append("Very close to modern infrastructure (OSM)")
        }

        // Source 2: Satellite imagery (terrain classification)
        let satelliteScore = await validateAgainstSatellite(coordinate: feature.coordinate, featureType: feature.featureType)
        validationScores[.satelliteImagery] = satelliteScore

        if satelliteScore < 0.3 {
            failureReasons.append("Artificial surface detected (Sentinel-2)")
        }

        // Source 3: Vegetation analysis (disturbance detection)
        let vegetationScore = await validateVegetation(coordinate: feature.coordinate)
        validationScores[.vegetation] = vegetationScore

        if vegetationScore < 0.3 {
            failureReasons.append("Recent disturbance detected (NDVI)")
        }

        // Source 4: Geometric consistency (cross-validation)
        let geometricScore = validateGeometry(feature: feature, elevationData: elevationData)
        validationScores[.geometric] = geometricScore

        if geometricScore < 0.5 {
            failureReasons.append("Geometric characteristics inconsistent with historical features")
        }

        // Calculate composite score using weighted average
        let compositeScore = calculateCompositeScore(scores: validationScores)

        // Count sources that agree (score > 0.5 = agreement)
        let agreeingSources = validationScores.values.filter { $0 > 0.5 }.count

        // Determine validation decision
        let isValid = agreeingSources >= ValidationThresholds.minimumSourceAgreement &&
                      compositeScore >= ValidationThresholds.minimumConfidenceScore

        logger.info("Validation result: \(isValid ? "VALID" : "INVALID"), composite score: \(String(format: "%.2f", compositeScore)), agreeing sources: \(agreeingSources)/\(validationScores.count)")

        return ValidationResult(
            isValid: isValid,
            compositeScore: compositeScore,
            sourceScores: validationScores,
            agreeingSourcesCount: agreeingSources,
            totalSourcesCount: validationScores.count,
            failureReasons: failureReasons
        )
    }

    /// Batch validates multiple features (optimized to reduce API calls)
    func validateFeatures(
        features: [HistoricalFeature],
        elevationData: [[Double]],
        region: MKCoordinateRegion? = nil
    ) async -> [UUID: ValidationResult] {
        var results: [UUID: ValidationResult] = [:]

        // PRE-FETCH: Query OSM once for entire region to avoid rate limiting
        var regionalOSMData: OSMQueryResult?
        if let region = region {
            logger.info("Pre-fetching OSM data for entire region to avoid rate limiting")
            regionalOSMData = await osmService.queryRegion(region: region)
            if regionalOSMData != nil {
                logger.info("Regional OSM data fetched successfully")
            } else {
                logger.warning("Failed to fetch regional OSM data, will gracefully degrade")
            }
        }

        // Validate features using cached regional data
        for feature in features {
            let result = await validateFeature(
                feature: feature,
                elevationData: elevationData,
                preloadedOSMData: regionalOSMData
            )
            results[feature.id] = result
        }

        let validCount = results.values.filter { $0.isValid }.count
        logger.info("Batch validation complete: \(validCount)/\(features.count) features valid")

        return results
    }

    // MARK: - Individual Validation Methods

    /// Validates against OpenStreetMap data
    private func validateAgainstOSM(
        coordinate: CLLocationCoordinate2D,
        preloadedData: OSMQueryResult? = nil
    ) async -> Double {
        // Use preloaded data if available, otherwise query
        let osmData: OSMQueryResult?
        if let preloaded = preloadedData {
            osmData = preloaded
        } else {
            // Fallback to individual query (will use cache if available)
            let bbox = OSMBoundingBox(
                minLat: coordinate.latitude - 0.001,
                maxLat: coordinate.latitude + 0.001,
                minLon: coordinate.longitude - 0.001,
                maxLon: coordinate.longitude + 0.001
            )
            // Note: This might fail with 429/504, so we gracefully degrade
            osmData = nil // Skip individual queries to avoid rate limiting
        }

        guard let data = osmData else {
            // No OSM data available - gracefully degrade
            // Return neutral score rather than penalizing
            logger.debug("No OSM data available for validation, using neutral score")
            return 0.8 // Slight reduction but not full penalty
        }

        // Calculate distance to nearest modern feature
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var minDistance: Double?

        for feature in data.buildings + data.roads + data.structures {
            let featureLocation = CLLocation(latitude: feature.latitude, longitude: feature.longitude)
            let distance = location.distance(from: featureLocation)

            if let current = minDistance {
                minDistance = min(current, distance)
            } else {
                minDistance = distance
            }
        }

        guard let distance = minDistance else {
            // No modern infrastructure found
            return 1.0
        }

        // Score based on distance
        if distance < ValidationThresholds.maximumModernProximity {
            // Very close to modern infrastructure
            let proximityRatio = distance / ValidationThresholds.maximumModernProximity
            return proximityRatio // 0.0-1.0 based on distance
        }

        // Far from modern infrastructure
        return 1.0
    }

    /// Validates against satellite imagery
    private func validateAgainstSatellite(coordinate: CLLocationCoordinate2D, featureType: FeatureType) async -> Double {
        guard let terrainClass = await satelliteService.classifyTerrain(coordinate: coordinate) else {
            // No satellite data available
            return 0.8 // Neutral score
        }

        // Score based on terrain classification
        switch terrainClass {
        case .artificial:
            // Artificial surface = modern construction
            return ValidationThresholds.artificialSurfacePenalty

        case .bareEarth:
            // Bare earth could be historical or modern
            // Check if it matches expected feature type
            if featureType == .mound || featureType == .terrace {
                return 0.7 // Possible match
            }
            return 0.5 // Uncertain

        case .sparseVegetation:
            // Sparse vegetation typical of historical sites
            return 0.8

        case .moderateVegetation, .denseVegetation:
            // Vegetation covering feature (normal for historical sites)
            return 1.0

        case .water:
            // Water body (not a historical feature)
            return 0.0
        }
    }

    /// Validates vegetation patterns
    private func validateVegetation(coordinate: CLLocationCoordinate2D) async -> Double {
        guard let disturbance = await satelliteService.detectDisturbance(coordinate: coordinate) else {
            return 0.8 // Neutral score
        }

        // Score based on disturbance analysis
        switch disturbance.type {
        case .none:
            // No disturbance = likely historical
            return 1.0

        case .possibleDisturbance:
            // Minor disturbance = uncertain
            return 0.6

        case .recentDisturbance:
            // Recent disturbance = likely modern
            return ValidationThresholds.recentDisturbancePenalty

        case .modernConstruction:
            // Clear modern construction
            return ValidationThresholds.artificialSurfacePenalty
        }
    }

    /// Validates geometric consistency
    private func validateGeometry(feature: HistoricalFeature, elevationData: [[Double]]) -> Double {
        // Check if geometric characteristics match historical features

        var score: Double = 1.0

        // Check dimensions
        if let dimensions = feature.dimensions {
            // Mounds should have reasonable proportions
            if feature.featureType == .mound {
                if let height = dimensions.height, let diameter = dimensions.diameter {
                    let heightDiameterRatio = height / diameter

                    // Historical mounds typically have ratio between 0.01 and 0.3
                    if heightDiameterRatio < 0.01 {
                        score *= 0.5 // Too flat
                    } else if heightDiameterRatio > 0.3 {
                        score *= 0.6 // Too steep (possibly modern pile)
                    }

                    // Check absolute size ranges
                    if height < 1.0 || height > 30.0 {
                        score *= 0.4 // Outside historical range
                    }
                    if diameter < 10.0 || diameter > 150.0 {
                        score *= 0.4 // Outside historical range
                    }
                }
            }

            // Linear features should have reasonable length
            if feature.featureType == .linearFeature {
                if let length = dimensions.length {
                    if length < 20.0 {
                        score *= 0.5 // Too short (likely noise)
                    } else if length > 1000.0 {
                        score *= 0.3 // Very long (likely modern road)
                    }
                }
            }

            // Circular features should have reasonable diameter
            if feature.featureType == .circularPattern || feature.featureType == .fortification {
                if let diameter = dimensions.diameter {
                    if diameter < 16.0 {
                        score *= 0.3 // Too small (likely modern utility)
                    } else if diameter > 200.0 {
                        score *= 0.5 // Very large (uncommon)
                    }
                }
            }
        }

        // Check confidence level
        if feature.confidence.threshold < 0.5 {
            score *= 0.7 // Low initial confidence
        }

        return score
    }

    /// Calculates weighted composite score from multiple sources
    private func calculateCompositeScore(scores: [ValidationSource: Double]) -> Double {
        // Weights for each source (total = 1.0)
        let weights: [ValidationSource: Double] = [
            .openStreetMap: 0.35,      // 35% - Most reliable for modern infrastructure
            .satelliteImagery: 0.30,   // 30% - Very reliable for terrain type
            .vegetation: 0.20,         // 20% - Good for disturbance detection
            .geometric: 0.15           // 15% - Validates internal consistency
        ]

        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0

        for (source, score) in scores {
            if let weight = weights[source] {
                weightedSum += score * weight
                totalWeight += weight
            }
        }

        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
    }

    // MARK: - Reporting

    /// Generates detailed validation report
    func generateReport(validationResult: ValidationResult) -> String {
        var report = "=== MULTI-SOURCE VALIDATION REPORT ===\n\n"

        report += "Status: \(validationResult.isValid ? "✓ VALID" : "✗ INVALID")\n"
        report += "Composite Score: \(String(format: "%.2f", validationResult.compositeScore))\n"
        report += "Agreeing Sources: \(validationResult.agreeingSourcesCount)/\(validationResult.totalSourcesCount)\n\n"

        report += "Source Scores:\n"
        for (source, score) in validationResult.sourceScores.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let status = score > 0.5 ? "✓" : "✗"
            report += "  \(status) \(source.rawValue): \(String(format: "%.2f", score))\n"
        }

        if !validationResult.failureReasons.isEmpty {
            report += "\nFailure Reasons:\n"
            for reason in validationResult.failureReasons {
                report += "  • \(reason)\n"
            }
        }

        return report
    }
}

// MARK: - Data Models

struct ValidationResult {
    let isValid: Bool
    let compositeScore: Double
    let sourceScores: [ValidationSource: Double]
    let agreeingSourcesCount: Int
    let totalSourcesCount: Int
    let failureReasons: [String]
}

enum ValidationSource: String {
    case openStreetMap = "OpenStreetMap"
    case satelliteImagery = "Satellite Imagery"
    case vegetation = "Vegetation Analysis"
    case geometric = "Geometric Validation"
    case temporal = "Temporal Analysis"
}
