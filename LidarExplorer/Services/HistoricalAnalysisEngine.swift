//
//  HistoricalAnalysisEngine.swift
//  LidarExplorer
//
//  Historical site detection and analysis engine
//

import Foundation
import CoreImage
import MapKit
import UIKit
import OSLog

// MARK: - Historical Analysis Engine

actor HistoricalAnalysisEngine {
    static let shared = HistoricalAnalysisEngine()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "HistoricalAnalysisEngine")
    private let osmService = OpenStreetMapService.shared
    private let satelliteService = SatelliteImageryService.shared
    private let validationService = MultiSourceValidationService.shared

    // MARK: - Detection Thresholds

    // Mound Detection (LOCAL peaks - small/medium mounds)
    // Large mounds are now detected by detectLargeFeatures()
    private enum MoundThresholds {
        static let minimumElevationChange: Double = 2.0 // meters above surroundings (increased from 1.5)
        static let minimumProminence: Double = 0.5 // meters relative prominence (increased from 0.3)
        static let neighborhoodSize: Int = 7 // grid cells for local maxima detection

        // Size-based filtering for historical mounds
        static let minimumHistoricalHeight: Double = 1.5 // meters (increased)
        static let maximumHistoricalHeight: Double = 30.0 // meters
        static let minimumHistoricalDiameter: Double = 15.0 // meters (increased)
        static let maximumHistoricalDiameter: Double = 150.0 // meters

        // Penalties for out-of-range features
        static let sizeOutOfRangePenalty: Double = 0.2 // 80% reduction (increased)
    }

    // Linear Feature Detection - ULTRA STRICT
    private enum LinearThresholds {
        static let minimumGradient: Double = 0.8 // gradient magnitude for ridge detection (increased from 0.6)
        static let minimumElevationDifference: Double = 1.5 // meters for linear alignment (increased from 1.0)
        static let minimumAlignmentScore: Double = 3.0 // threshold for considering linear pattern (increased from 2.0)
        static let minimumClusterPoints: Int = 35 // minimum points to form feature (increased from 25)

        // Straightness thresholds (ultra strict)
        static let veryHighStraightness: Double = 0.60 // likely modern road (reduced from 0.70)
        static let highStraightness: Double = 0.50 // possibly modern (reduced from 0.60)
        static let moderateStraightness: Double = 0.40 // minor concern (reduced from 0.50)

        // Maximum aggressive penalties
        static let straightnessPenaltyHigh: Double = 0.05 // 95% reduction (was 90%)
        static let straightnessPenaltyMedium: Double = 0.15 // 85% reduction (was 75%)
        static let straightnessPenaltyLow: Double = 0.25 // 75% reduction (was 60%)
    }

    // Circular Pattern Detection - ULTRA STRICT
    private enum CircularThresholds {
        static let minimumUniformity: Double = 0.75 // uniformity score threshold (increased back up for selectivity)
        static let minimumElevationPattern: Double = 2.5 // elevation pattern strength (increased from 2.0)

        // Ultra-tight circularity thresholds
        static let veryHighCircularity: Double = 0.85 // likely modern structure (reduced from 0.88)
        static let highCircularity: Double = 0.75 // possibly modern (reduced from 0.80)
        static let moderateCircularity: Double = 0.65 // minor concern (reduced from 0.70)

        // Extremely aggressive penalties
        static let circularityPenaltyHigh: Double = 0.05 // 95% reduction (was 85%)
        static let circularityPenaltyMedium: Double = 0.15 // 85% reduction (was 65%)
        static let circularityPenaltyLow: Double = 0.30 // 70% reduction (was 45%)

        // Size-based filtering - much more aggressive
        static let smallRadiusThreshold: Double = 15.0 // meters - likely modern utility (increased from 10.0)
        static let smallRadiusPenalty: Double = 0.10 // 90% reduction (was 75%)

        // Historical feature size ranges - narrower
        static let minimumHistoricalRadius: Double = 12.0 // meters (increased from 8.0)
        static let maximumHistoricalRadius: Double = 100.0 // meters
    }

    // Terrace Detection
    private enum TerraceThresholds {
        static let maximumVariance: Double = 0.8 // increased from 0.5 for less perfect flatness
        static let minimumVariance: Double = 0.20 // features below this are too flat (modern)

        // Tightened flatness thresholds
        static let veryLowVariance: Double = 0.20 // extremely flat - likely modern (increased from 0.15)
        static let lowVariance: Double = 0.35 // very flat - possibly modern (increased from 0.30)
        static let moderateVariance: Double = 0.55 // flat - minor concern (increased from 0.50)

        // More aggressive penalties for excessive flatness
        static let variancePenaltyHigh: Double = 0.2 // 80% reduction (was 50%)
        static let variancePenaltyMedium: Double = 0.4 // 60% reduction (was 30%)
        static let variancePenaltyLow: Double = 0.6 // 40% reduction (was 15%)

        // Edge detection thresholds
        static let minimumEdgeDifference: Double = 2.0 // meters (increased from 1.5)
        static let minimumEdgePoints: Int = 8 // out of 12 (increased proportion)
    }

    // Modern Feature Detection (Note: lower regularity score = more regular/modern)
    private enum ModernFeatureThresholds {
        // Tightened regularity thresholds
        static let veryHighRegularity: Double = 0.30 // extremely regular - likely modern (increased from 0.25)
        static let highRegularity: Double = 0.45 // quite regular - possibly modern (increased from 0.4)
        static let moderateRegularity: Double = 0.60 // somewhat regular - minor concern (increased from 0.55)

        // More aggressive penalties
        static let regularityPenaltyHigh: Double = 0.2 // 80% reduction (was 50%)
        static let regularityPenaltyMedium: Double = 0.4 // 60% reduction (was 30%)
        static let regularityPenaltyLow: Double = 0.6 // 40% reduction (was 15%)

        // OpenStreetMap proximity filtering
        static let osmProximityRadiusMeters: Double = 75.0 // check for modern infrastructure within this radius
        static let osmDirectProximityThreshold: Double = 20.0 // features within this distance get maximum penalty
    }

    private var detectedFeatures: [UUID: HistoricalFeature]
    private var knownSites: [HistoricalFeature]
    private var analysisSettings: AnalysisSettings
    private var isAnalyzing: Bool
    private var isInitialized: Bool = false

    private init() {
        // Initialize with literal values to avoid MainActor issues
        self.detectedFeatures = [:]
        self.knownSites = []
        self.analysisSettings = AnalysisSettings(
            enabled: false,
            minimumConfidence: .medium,
            featureTypesFilter: Set(FeatureType.allCases),
            analyzeInRealtime: false,
            highlightColor: "yellow",
            highlightOpacity: 0.6,
            slopeThreshold: 5.0,
            elevationChangeThreshold: 1.0,
            circularityThreshold: 0.7,
            linearityThreshold: 0.8,
            minimumFeatureSize: 5.0,
            maximumFeatureSize: 500.0
        )
        self.isAnalyzing = false
    }

    func initialize() async {
        // Prevent multiple initializations
        guard !isInitialized else {
            logger.debug("Skipping initialization - already initialized")
            return
        }

        logger.info("Initializing HistoricalAnalysisEngine")
        loadKnownSites()
        loadDetectedFeatures()
        isInitialized = true
        logger.info("HistoricalAnalysisEngine initialization complete")
    }

    // MARK: - Settings Management

    func updateSettings(_ newSettings: AnalysisSettings) {
        self.analysisSettings = newSettings
    }

    func getSettings() -> AnalysisSettings {
        return analysisSettings
    }

    // MARK: - Feature Management

    func getAllFeatures() -> [HistoricalFeature] {
        let detected = Array(detectedFeatures.values)
        let all = detected + knownSites
        return all.sorted { $0.confidence > $1.confidence }
    }

    func getFeatures(minimumConfidence: DetectionConfidence) -> [HistoricalFeature] {
        let all = getAllFeatures()
        return all.filter { $0.confidence >= minimumConfidence }
    }

    func getFeaturesInRegion(region: MKCoordinateRegion) -> [HistoricalFeature] {
        let features = getAllFeatures()
        return features.filter { feature in
            let latDelta = abs(feature.coordinate.latitude - region.center.latitude)
            let lonDelta = abs(feature.coordinate.longitude - region.center.longitude)
            return latDelta <= region.span.latitudeDelta / 2 &&
                   lonDelta <= region.span.longitudeDelta / 2
        }
    }

    func addFeature(_ feature: HistoricalFeature) {
        if feature.confidence == .confirmed {
            knownSites.append(feature)
        } else {
            detectedFeatures[feature.id] = feature
        }
        saveDetectedFeatures()
    }

    func updateFeature(_ feature: HistoricalFeature) {
        if feature.confidence == .confirmed {
            if let index = knownSites.firstIndex(where: { $0.id == feature.id }) {
                knownSites[index] = feature
            } else {
                knownSites.append(feature)
            }
            detectedFeatures.removeValue(forKey: feature.id)
        } else {
            detectedFeatures[feature.id] = feature
        }
        saveDetectedFeatures()
    }

    func deleteFeature(id: UUID) {
        detectedFeatures.removeValue(forKey: id)
        knownSites.removeAll(where: { $0.id == id })
        saveDetectedFeatures()
    }

    // MARK: - Analysis Engine

    /// Analyzes a map region for potential historical and archaeological features
    ///
    /// This function runs multiple detection algorithms to identify various types of historical features:
    /// - Mounds: Local elevation peaks that may indicate burial mounds or earthworks
    /// - Linear features: Ridge patterns that may indicate ancient roads, walls, or defensive structures
    /// - Circular patterns: Ring-shaped elevation changes that may indicate fortifications or settlements
    /// - Terraces: Flat platforms with distinct edges that may indicate agricultural or ceremonial sites
    ///
    /// Modern feature filtering is applied to reduce false positives from contemporary construction.
    ///
    /// - Parameters:
    ///   - region: The map coordinate region being analyzed
    ///   - elevationData: 2D array of elevation values in meters, obtained from USGS 3DEP
    /// - Returns: Array of detected historical features that meet the minimum confidence threshold
    func analyzeRegion(
        region: MKCoordinateRegion,
        elevationData: [[Double]]
    ) async -> [HistoricalFeature] {
        guard !isAnalyzing else { return [] }
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Debug: Analyze elevation data statistics
        var allValues: [Double] = []
        for row in elevationData {
            allValues.append(contentsOf: row)
        }
        let minElev = allValues.min() ?? 0
        let maxElev = allValues.max() ?? 0
        let meanElev = allValues.reduce(0, +) / Double(allValues.count)
        let range = maxElev - minElev

        logger.debug("Elevation data statistics: Size=\(elevationData.count)x\(elevationData.first?.count ?? 0), Min=\(String(format: "%.2f", minElev))m, Max=\(String(format: "%.2f", maxElev))m, Mean=\(String(format: "%.2f", meanElev))m, Range=\(String(format: "%.2f", range))m")

        var detectedFeatures: [HistoricalFeature] = []

        // Run different detection algorithms
        // CRITICAL: Run large feature detection FIRST to catch obvious mounds
        let largeFeatures = await detectLargeFeatures(elevationData: elevationData, region: region)
        logger.debug("Large feature detection: found \(largeFeatures.count) candidates")
        detectedFeatures += largeFeatures

        let mounds = await detectMounds(elevationData: elevationData, region: region)
        logger.debug("Mound detection: found \(mounds.count) candidates")
        detectedFeatures += mounds

        let linear = await detectLinearFeatures(elevationData: elevationData, region: region)
        logger.debug("Linear feature detection: found \(linear.count) candidates")
        detectedFeatures += linear

        let circular = await detectCircularPatterns(elevationData: elevationData, region: region)
        logger.debug("Circular pattern detection: found \(circular.count) candidates")
        detectedFeatures += circular

        let terraces = await detectTerraces(elevationData: elevationData, region: region)
        logger.debug("Terrace detection: found \(terraces.count) candidates")
        detectedFeatures += terraces

        logger.debug("Total candidates before filtering: \(detectedFeatures.count)")

        // Filter by confidence threshold
        logger.debug("Minimum confidence threshold: \(self.analysisSettings.minimumConfidence.rawValue)")
        let filtered = detectedFeatures.filter {
            $0.confidence >= analysisSettings.minimumConfidence
        }

        logger.info("Features after confidence filtering: \(filtered.count)")
        if filtered.count == 0 && detectedFeatures.count > 0 {
            logger.warning("All \(detectedFeatures.count) candidates were filtered out by confidence threshold")
        }

        // MULTI-SOURCE VALIDATION: Validate against satellite imagery, OSM, and other sources
        logger.info("Starting multi-source validation for \(filtered.count) features")
        let validationResults = await validationService.validateFeatures(
            features: filtered,
            elevationData: elevationData,
            region: region
        )

        // Apply validation results and filter invalid features
        var validatedFeatures: [HistoricalFeature] = []
        for feature in filtered {
            guard let validation = validationResults[feature.id] else {
                continue
            }

            if validation.isValid {
                // Adjust confidence based on validation score
                let adjustedConfidence = DetectionConfidence.from(
                    score: feature.confidence.threshold * validation.compositeScore
                )

                let validatedFeature = HistoricalFeature(
                    id: feature.id,
                    coordinate: feature.coordinate,
                    featureType: feature.featureType,
                    confidence: adjustedConfidence,
                    detectionDate: feature.detectionDate,
                    area: feature.area,
                    dimensions: feature.dimensions,
                    metadata: feature.metadata
                )

                validatedFeatures.append(validatedFeature)
            } else {
                logger.debug("Feature REJECTED by multi-source validation: \(validation.failureReasons.joined(separator: ", "))")
            }
        }

        logger.info("Features after multi-source validation: \(validatedFeatures.count) (rejected: \(filtered.count - validatedFeatures.count))")

        // Add to detected features collection
        for feature in validatedFeatures {
            self.detectedFeatures[feature.id] = feature
        }

        saveDetectedFeatures()
        return validatedFeatures
    }

    // MARK: - Detection Algorithms
    //
    // All detection algorithms include modern feature filtering to distinguish
    // between historical/archaeological features and modern construction:
    //
    // 1. Geometric Regularity Analysis
    //    - Modern features have perfect geometry (straight lines, perfect circles)
    //    - Historical features are more organic and irregular
    //    - Confidence is reduced for "too perfect" features
    //
    // 2. Shape-Specific Filtering
    //    - Mounds: Check shape irregularity (1.0m minimum height)
    //    - Linear: Check straightness (penalize perfectly straight features)
    //    - Circular: Check circularity perfection (penalize perfect circles)
    //    - Terraces: Check flatness (penalize excessive flatness)
    //
    // 3. Size-Based Filtering
    //    - Features outside typical historical size ranges receive lower confidence
    //    - Very small features are likely modern utilities
    //    - Typical historical mounds: 1-30m height, 10-100m diameter
    //
    // These improvements significantly reduce false positives from modern infrastructure
    // such as buildings, roads, water tanks, and agricultural terracing.

    /// Detects LARGE features (like Pinson Mounds) using regional analysis
    /// Works at broader scale than local peak detection
    private func detectLargeFeatures(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        let rows = elevationData.count
        let cols = elevationData[0].count

        guard rows >= 20 && cols >= 20 else { return [] }

        var largeFeatures: [HistoricalFeature] = []

        // Calculate regional statistics
        var allElevations: [Double] = []
        for row in elevationData {
            allElevations.append(contentsOf: row)
        }

        let meanElevation = allElevations.reduce(0, +) / Double(allElevations.count)
        let variance = allElevations.map { pow($0 - meanElevation, 2) }.reduce(0, +) / Double(allElevations.count)
        let stdDev = sqrt(variance)

        logger.debug("Regional stats: mean=\(String(format: "%.2f", meanElevation))m, stdDev=\(String(format: "%.2f", stdDev))m")

        // Look for broad elevated regions (20x20 grid cells = large areas)
        let windowSize = 20
        let stepSize = 10 // Overlap windows by 50%

        for i in stride(from: 0, to: rows - windowSize, by: stepSize) {
            for j in stride(from: 0, to: cols - windowSize, by: stepSize) {
                // Calculate average elevation in this window
                var windowElevation = 0.0
                var windowCount = 0
                var maxElevation = -Double.infinity
                var minElevation = Double.infinity

                for wi in 0..<windowSize {
                    for wj in 0..<windowSize {
                        let elev = elevationData[i + wi][j + wj]
                        windowElevation += elev
                        windowCount += 1
                        maxElevation = max(maxElevation, elev)
                        minElevation = min(minElevation, elev)
                    }
                }

                let avgElevation = windowElevation / Double(windowCount)
                let elevationRange = maxElevation - minElevation

                // Check if this region is significantly elevated above mean
                // AND has substantial relief (not just flat high ground)
                let elevationAboveMean = avgElevation - meanElevation

                if elevationAboveMean > 2.0 && elevationRange > 3.0 {
                    // This looks like a large mound or elevated feature
                    let centerI = i + windowSize / 2
                    let centerJ = j + windowSize / 2

                    let coordinate = coordinateFromGridPosition(
                        row: centerI,
                        col: centerJ,
                        rows: rows,
                        cols: cols,
                        region: region
                    )

                    // Calculate shape characteristics
                    let irregularity = calculateShapeIrregularity(
                        elevationData: elevationData,
                        centerRow: centerI,
                        centerCol: centerJ,
                        radius: windowSize / 2
                    )

                    // High confidence for large, prominent features
                    var confidenceScore = min(elevationAboveMean / 10.0, 1.0)

                    // Bonus for substantial relief
                    if elevationRange > 5.0 {
                        confidenceScore = min(confidenceScore * 1.2, 1.0)
                    }

                    // Apply modern feature filtering
                    confidenceScore = await applyModernFeaturePenalties(
                        baseConfidence: confidenceScore,
                        featureType: .mound,
                        geometricRegularity: irregularity,
                        coordinate: coordinate
                    )

                    let confidence = DetectionConfidence.from(score: confidenceScore)

                    // Only report if confidence is reasonable
                    if confidence >= .low {
                        let feature = HistoricalFeature(
                            coordinate: coordinate,
                            featureType: .mound,
                            confidence: confidence,
                            dimensions: FeatureDimensions(
                                length: nil,
                                width: nil,
                                height: elevationRange,
                                diameter: Double(windowSize) * 2.0  // Approximate
                            ),
                            metadata: FeatureMetadata(
                                notes: "Large elevated feature (\(String(format: "%.1f", elevationAboveMean))m above regional mean, \(String(format: "%.1f", elevationRange))m relief)"
                            )
                        )

                        largeFeatures.append(feature)
                        logger.info("LARGE FEATURE DETECTED: \(String(format: "%.1f", elevationAboveMean))m above mean, \(String(format: "%.1f", elevationRange))m relief")
                    }
                }
            }
        }

        return largeFeatures
    }

    private func detectMounds(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var mounds: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Need at least 9x9 for 7x7 neighborhood analysis
        guard rows >= 9 && cols >= 9 else { return [] }

        var localMaximaCount = 0
        var significantPeaks: [(elevation: Double, prominence: Double)] = []

        let halfNeighborhood = MoundThresholds.neighborhoodSize / 2

        // Simple peak detection algorithm - look for local maxima
        for i in (halfNeighborhood + 1)..<(rows - halfNeighborhood - 1) {
            for j in (halfNeighborhood + 1)..<(cols - halfNeighborhood - 1) {
                let centerElevation = elevationData[i][j]

                // Check if this is a local maximum in configured neighborhood
                var isLocalMax = true
                var elevationSum = 0.0
                var count = 0
                var maxNeighborElevation = 0.0

                // Check neighborhood
                for di in -halfNeighborhood...halfNeighborhood {
                    for dj in -halfNeighborhood...halfNeighborhood {
                        if di == 0 && dj == 0 { continue }
                        let neighborElevation = elevationData[i + di][j + dj]
                        elevationSum += neighborElevation
                        count += 1
                        maxNeighborElevation = max(maxNeighborElevation, neighborElevation)
                        if neighborElevation >= centerElevation {
                            isLocalMax = false
                        }
                    }
                }

                if isLocalMax {
                    localMaximaCount += 1
                }

                let averageNeighborElevation = elevationSum / Double(count)
                let elevationChange = centerElevation - averageNeighborElevation

                if isLocalMax && elevationChange > 0.1 {
                    significantPeaks.append((elevationChange, centerElevation - maxNeighborElevation))
                }

                // If it's a local maximum with significant elevation change
                // Use threshold to detect quality candidates, then filter by confidence
                // Modern feature penalties will reduce confidence on modern-looking features
                if isLocalMax && elevationChange >= MoundThresholds.minimumElevationChange {
                    let coordinate = coordinateFromGridPosition(
                        row: i, col: j,
                        rows: rows, cols: cols,
                        region: region
                    )

                    // Calculate shape irregularity (historical features are more organic)
                    let irregularity = calculateShapeIrregularity(
                        elevationData: elevationData,
                        centerRow: i,
                        centerCol: j,
                        radius: halfNeighborhood
                    )

                    // Calculate edge sharpness (modern features have crisp edges)
                    let edgeSharpness = calculateEdgeSharpness(
                        elevationData: elevationData,
                        centerRow: i,
                        centerCol: j,
                        radius: halfNeighborhood
                    )

                    // Calculate estimated dimensions for size-based filtering
                    let estimatedHeight = elevationChange
                    let estimatedDiameter = estimateDiameter(elevationChange: elevationChange)

                    // Calculate confidence based on prominence and sharpness
                    let prominence = elevationChange / max(0.1, centerElevation - maxNeighborElevation)
                    var confidenceScore = min(elevationChange / 5.0 * prominence, 1.0)

                    // Penalize sharp edges (modern features have crisp, unweathered edges)
                    if edgeSharpness > 0.7 {
                        confidenceScore *= 0.4 // 60% reduction for very sharp edges
                        logger.debug("Sharp edges detected (modern), confidence reduced")
                    } else if edgeSharpness > 0.5 {
                        confidenceScore *= 0.6 // 40% reduction for moderately sharp edges
                        logger.debug("Moderately sharp edges, confidence reduced")
                    }

                    // Apply size-based filtering (historical mounds have typical size ranges)
                    if estimatedHeight < MoundThresholds.minimumHistoricalHeight ||
                       estimatedHeight > MoundThresholds.maximumHistoricalHeight ||
                       estimatedDiameter < MoundThresholds.minimumHistoricalDiameter ||
                       estimatedDiameter > MoundThresholds.maximumHistoricalDiameter {
                        confidenceScore *= MoundThresholds.sizeOutOfRangePenalty
                        logger.debug("Mound size out of historical range (H:\(String(format: "%.1f", estimatedHeight))m, D:\(String(format: "%.1f", estimatedDiameter))m), confidence reduced")
                    }

                    // Apply modern feature penalties (including OSM proximity check)
                    confidenceScore = await applyModernFeaturePenalties(
                        baseConfidence: confidenceScore,
                        featureType: .mound,
                        geometricRegularity: irregularity,
                        coordinate: coordinate
                    )

                    let confidence = DetectionConfidence.from(score: confidenceScore)

                    let feature = HistoricalFeature(
                        coordinate: coordinate,
                        featureType: .mound,
                        confidence: confidence,
                        area: calculateArea(elevationChange: elevationChange),
                        dimensions: FeatureDimensions(
                            length: nil,
                            width: nil,
                            height: elevationChange,
                            diameter: estimateDiameter(elevationChange: elevationChange)
                        ),
                        metadata: FeatureMetadata(
                            notes: "Local elevation peak (\(String(format: "%.1f", elevationChange))m above surroundings)"
                        )
                    )

                    mounds.append(feature)
                }
            }
        }

        // Debug logging
        logger.debug("Mound detection: \(localMaximaCount) local maxima, \(significantPeaks.count) significant peaks, \(mounds.count) mounds meeting threshold")

        return mounds
    }

    private func detectLinearFeatures(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var linearFeatures: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        guard rows >= 3 && cols >= 3 else { return [] }

        // Calculate gradients and identify ridge lines
        var ridgePoints: [(row: Int, col: Int, strength: Double)] = []

        for i in 2..<(rows - 2) {
            for j in 2..<(cols - 2) {
                let dx = (elevationData[i][j + 1] - elevationData[i][j - 1]) / 2.0
                let dy = (elevationData[i + 1][j] - elevationData[i - 1][j]) / 2.0
                let gradientMagnitude = sqrt(dx * dx + dy * dy)

                // Look for consistent elevation along a line (ridge detection)
                if gradientMagnitude >= LinearThresholds.minimumGradient {
                    // Check if this forms part of a linear pattern
                    let angle = atan2(dy, dx)
                    var alignmentScore = 0.0

                    // Check neighboring points along the gradient direction
                    for offset in -2...2 {
                        if offset == 0 { continue }
                        let checkI = i + Int(Double(offset) * sin(angle))
                        let checkJ = j + Int(Double(offset) * cos(angle))

                        if checkI >= 0 && checkI < rows && checkJ >= 0 && checkJ < cols {
                            let elevDiff = abs(elevationData[i][j] - elevationData[checkI][checkJ])
                            if elevDiff < 1.0 {  // Similar elevation = likely part of ridge
                                alignmentScore += 1.0
                            }
                        }
                    }

                    if alignmentScore >= 2.0 {
                        ridgePoints.append((i, j, gradientMagnitude * alignmentScore))
                    }
                }
            }
        }

        // Cluster nearby ridge points into linear features
        var usedPoints = Set<Int>()

        for idx in ridgePoints.indices {
            guard !usedPoints.contains(idx) else { continue }

            let (i, j, strength) = ridgePoints[idx]
            var cluster: [(Int, Int, Double)] = [(i, j, strength)]
            usedPoints.insert(idx)

            // Find nearby points within 5 grid units
            for otherIdx in ridgePoints.indices {
                guard !usedPoints.contains(otherIdx) else { continue }
                let (oi, oj, os) = ridgePoints[otherIdx]

                let dist = sqrt(pow(Double(i - oi), 2) + pow(Double(j - oj), 2))
                if dist < 10.0 {  // Cluster radius
                    cluster.append((oi, oj, os))
                    usedPoints.insert(otherIdx)
                }
            }

            // Create feature if cluster is significant enough
            // Use updated minimum cluster points threshold
            if cluster.count >= LinearThresholds.minimumClusterPoints {
                let avgI = cluster.map { Double($0.0) }.reduce(0, +) / Double(cluster.count)
                let avgJ = cluster.map { Double($0.1) }.reduce(0, +) / Double(cluster.count)
                let avgStrength = cluster.map { $0.2 }.reduce(0, +) / Double(cluster.count)

                let coordinate = coordinateFromGridPosition(
                    row: Int(avgI),
                    col: Int(avgJ),
                    rows: rows,
                    cols: cols,
                    region: region
                )

                // Calculate straightness (modern roads are straighter than ancient paths)
                let clusterPoints = cluster.map { (row: $0.0, col: $0.1) }
                let straightness = calculateStraightness(points: clusterPoints)

                // Detect parallel features (modern roads have curbs, shoulders)
                let parallelScore = detectParallelFeatures(
                    elevationData: elevationData,
                    centerPoints: clusterPoints,
                    searchDistance: 5
                )

                var confidenceScore = min(Double(cluster.count) / 20.0 * avgStrength, 1.0)

                // Penalize features that are too straight (likely modern roads)
                // Using aggressive penalties to reduce false positives
                if straightness > LinearThresholds.veryHighStraightness {
                    confidenceScore *= LinearThresholds.straightnessPenaltyHigh
                    logger.debug("Very straight linear feature detected, confidence reduced")
                } else if straightness > LinearThresholds.highStraightness {
                    confidenceScore *= LinearThresholds.straightnessPenaltyMedium
                    logger.debug("Straight linear feature detected, confidence reduced")
                } else if straightness > LinearThresholds.moderateStraightness {
                    confidenceScore *= LinearThresholds.straightnessPenaltyLow
                    logger.debug("Moderately straight feature, minor confidence reduction")
                }

                // Penalize parallel features (modern roads have symmetric structures)
                if parallelScore > 0.6 {
                    confidenceScore *= 0.3 // 70% reduction for strong parallel pattern
                    logger.debug("Strong parallel pattern detected (modern road), confidence heavily reduced")
                } else if parallelScore > 0.4 {
                    confidenceScore *= 0.5 // 50% reduction for moderate parallel pattern
                    logger.debug("Parallel pattern detected, confidence reduced")
                }

                let confidence = DetectionConfidence.from(score: confidenceScore)

                let feature = HistoricalFeature(
                    coordinate: coordinate,
                    featureType: .linearFeature,
                    confidence: confidence,
                    dimensions: FeatureDimensions(
                        length: Double(cluster.count) * 2.0,  // Rough estimate in meters
                        width: nil,
                        height: nil,
                        diameter: nil
                    ),
                    metadata: FeatureMetadata(
                        notes: "Linear elevation pattern (\(cluster.count) aligned points) - possible road, wall, or ridge"
                    )
                )

                linearFeatures.append(feature)
            }
        }

        return linearFeatures
    }

    private func detectCircularPatterns(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var circularFeatures: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        guard rows >= 15 && cols >= 15 else { return [] }

        // Look for circular patterns (ring-shaped elevation changes)
        // Check various radii for circular patterns
        let radiiToCheck: [Double] = [5, 7, 10, 12, 15]

        for i in stride(from: 20, to: rows - 20, by: 5) {
            for j in stride(from: 20, to: cols - 20, by: 5) {
                let centerElevation = elevationData[i][j]

                for radius in radiiToCheck {
                    var circularityScore = 0.0
                    var ringElevationSum = 0.0
                    var pointsChecked = 0

                    // Sample points around the circle
                    for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8) {
                        let checkI = i + Int(radius * sin(angle))
                        let checkJ = j + Int(radius * cos(angle))

                        guard checkI >= 0 && checkI < rows && checkJ >= 0 && checkJ < cols else { continue }

                        let ringElevation = elevationData[checkI][checkJ]
                        ringElevationSum += ringElevation
                        pointsChecked += 1

                        // Check if ring has different elevation than center (moat or raised ring)
                        let elevationDifference = abs(ringElevation - centerElevation)
                        if elevationDifference > LinearThresholds.minimumElevationDifference {
                            circularityScore += 1.0
                        }
                    }

                    if pointsChecked > 0 {
                        let avgRingElevation = ringElevationSum / Double(pointsChecked)
                        let uniformityScore = circularityScore / Double(pointsChecked)

                        // Detect both raised centers (mounds) and depressed centers (moats)
                        let elevationPattern = abs(centerElevation - avgRingElevation)

                        // Require higher uniformity and elevation difference to reduce false positives
                        if uniformityScore > CircularThresholds.minimumUniformity && elevationPattern > CircularThresholds.minimumElevationPattern {
                            let coordinate = coordinateFromGridPosition(
                                row: i,
                                col: j,
                                rows: rows,
                                cols: cols,
                                region: region
                            )

                            // Calculate circularity perfection (modern features are too perfect)
                            let circularityPerfection = calculateCircularityPerfection(
                                elevationData: elevationData,
                                centerRow: i,
                                centerCol: j,
                                radius: radius
                            )

                            var confidenceScore = min(uniformityScore * elevationPattern / 3.0, 1.0)

                            // Penalize perfect circles (likely modern water tanks, silos, etc.)
                            // Using moderate penalties to balance false positive reduction with detection
                            if circularityPerfection > CircularThresholds.veryHighCircularity {
                                confidenceScore *= CircularThresholds.circularityPenaltyHigh
                                logger.debug("Nearly perfect circle detected, confidence reduced")
                            } else if circularityPerfection > CircularThresholds.highCircularity {
                                confidenceScore *= CircularThresholds.circularityPenaltyMedium
                                logger.debug("Very uniform circle detected, confidence reduced")
                            } else if circularityPerfection > CircularThresholds.moderateCircularity {
                                confidenceScore *= CircularThresholds.circularityPenaltyLow
                                logger.debug("Uniform circle, minor confidence reduction")
                            }

                            // Filter out features that are too small (likely modern utility features)
                            if radius < CircularThresholds.smallRadiusThreshold {
                                confidenceScore *= CircularThresholds.smallRadiusPenalty
                                logger.debug("Small circular feature detected, confidence reduced")
                            }

                            let confidence = DetectionConfidence.from(score: confidenceScore)

                            let patternType: FeatureType = centerElevation > avgRingElevation ? .fortification : .circularPattern

                            let feature = HistoricalFeature(
                                coordinate: coordinate,
                                featureType: patternType,
                                confidence: confidence,
                                dimensions: FeatureDimensions(
                                    length: nil,
                                    width: nil,
                                    height: elevationPattern,
                                    diameter: radius * 2.0
                                ),
                                metadata: FeatureMetadata(
                                    notes: "Circular pattern (\(String(format: "%.0f", radius * 2.0))m diameter) - possible ring fort, moat, or enclosure"
                                )
                            )

                            circularFeatures.append(feature)
                            break // Found a pattern at this location, don't check other radii
                        }
                    }
                }
            }
        }

        return circularFeatures
    }

    private func detectTerraces(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var terraces: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Need at least 16x16 grid for safe 12x12 analysis with edge checking
        guard rows >= 16 && cols >= 16 else { return [] }

        // Look for horizontal platforms (areas with low slope variation)
        // Check multiple sizes for terraces
        let terraceSize = 12  // Look for 12x12m platforms

        // Loop with stride to avoid detecting same terrace multiple times
        for i in stride(from: 2, to: rows - terraceSize - 2, by: 6) {
            for j in stride(from: 2, to: cols - terraceSize - 2, by: 6) {
                var elevationSum = 0.0

                // Check terrace area
                for di in 0..<terraceSize {
                    for dj in 0..<terraceSize {
                        elevationSum += elevationData[i + di][j + dj]
                    }
                }

                let avgElevation = elevationSum / Double(terraceSize * terraceSize)

                // Calculate variance (flatness measure)
                var variance = 0.0
                for di in 0..<terraceSize {
                    for dj in 0..<terraceSize {
                        let diff = elevationData[i + di][j + dj] - avgElevation
                        variance += diff * diff
                    }
                }
                variance /= Double(terraceSize * terraceSize)

                // Low variance indicates flatness - use more lenient threshold
                if variance < TerraceThresholds.maximumVariance {
                    let flatnessScore = 1.0 - min(variance / TerraceThresholds.maximumVariance, 1.0)

                    // Check if there's an elevation change around the flat area (indicating a terrace edge)
                    var maxEdgeDifference = 0.0
                    var edgePoints = 0

                    // Check edges of the flat area (safely within bounds)
                    for k in 0..<terraceSize {
                        // Check all four edges
                        let topEdge = abs(elevationData[i - 1][j + k] - avgElevation)
                        let bottomEdge = abs(elevationData[i + terraceSize][j + k] - avgElevation)
                        let leftEdge = abs(elevationData[i + k][j - 1] - avgElevation)
                        let rightEdge = abs(elevationData[i + k][j + terraceSize] - avgElevation)

                        maxEdgeDifference = max(maxEdgeDifference, topEdge, bottomEdge, leftEdge, rightEdge)

                        if topEdge > 1.5 || bottomEdge > 1.5 || leftEdge > 1.5 || rightEdge > 1.5 {
                            edgePoints += 1
                        }
                    }

                    // Detect terrace if it's flat AND has significant elevation changes at edges
                    // Use updated thresholds for edge detection
                    if edgePoints >= TerraceThresholds.minimumEdgePoints && maxEdgeDifference > TerraceThresholds.minimumEdgeDifference {
                        let coordinate = coordinateFromGridPosition(
                            row: i + terraceSize / 2,
                            col: j + terraceSize / 2,
                            rows: rows,
                            cols: cols,
                            region: region
                        )

                        let edgeScore = min(maxEdgeDifference / 3.0, 1.0)
                        var confidenceScore = (flatnessScore + edgeScore) / 2.0

                        // Penalize excessively flat features (modern construction is TOO perfect)
                        // Historical terraces have some natural irregularity
                        // Using moderate penalties to balance false positive reduction with detection
                        if variance < TerraceThresholds.veryLowVariance {
                            confidenceScore *= TerraceThresholds.variancePenaltyHigh
                            logger.debug("Extremely flat terrace, confidence reduced")
                        } else if variance < TerraceThresholds.lowVariance {
                            confidenceScore *= TerraceThresholds.variancePenaltyMedium
                            logger.debug("Very flat terrace, confidence reduced")
                        } else if variance < TerraceThresholds.moderateVariance {
                            confidenceScore *= TerraceThresholds.variancePenaltyLow
                            logger.debug("Flat terrace, minor confidence reduction")
                        }

                        let confidence = DetectionConfidence.from(score: confidenceScore)

                        let feature = HistoricalFeature(
                            coordinate: coordinate,
                            featureType: .terrace,
                            confidence: confidence,
                            dimensions: FeatureDimensions(
                                length: Double(terraceSize),
                                width: Double(terraceSize),
                                height: maxEdgeDifference,
                                diameter: nil
                            ),
                            metadata: FeatureMetadata(
                                notes: "Flat platform (\(terraceSize)×\(terraceSize)m) with \(String(format: "%.1f", maxEdgeDifference))m elevation change - possible agricultural or defensive terrace"
                            )
                        )

                        terraces.append(feature)
                    }
                }
            }
        }

        return terraces
    }

    // MARK: - Helper Functions

    private func coordinateFromGridPosition(
        row: Int, col: Int,
        rows: Int, cols: Int,
        region: MKCoordinateRegion
    ) -> CLLocationCoordinate2D {
        let latFraction = Double(row) / Double(rows)
        let lonFraction = Double(col) / Double(cols)

        let latitude = region.center.latitude - region.span.latitudeDelta / 2.0 +
                      latFraction * region.span.latitudeDelta
        let longitude = region.center.longitude - region.span.longitudeDelta / 2.0 +
                       lonFraction * region.span.longitudeDelta

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Modern Feature Detection

    /// Calculates shape irregularity score for a feature area
    /// Returns 0.0 (perfectly regular/geometric) to 1.0 (highly irregular/organic)
    /// Historical features tend to have higher irregularity (0.4-1.0)
    /// Modern features tend to have lower irregularity (0.0-0.3)
    private func calculateShapeIrregularity(
        elevationData: [[Double]],
        centerRow: Int,
        centerCol: Int,
        radius: Int
    ) -> Double {
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Sample points around the perimeter at different angles
        let angles: [Double] = stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 12).map { $0 }
        var distances: [Double] = []

        for angle in angles {
            // Find where the elevation significantly changes (edge of feature)
            var edgeDistance = 0.0
            let centerElevation = elevationData[centerRow][centerCol]

            for r in 1...radius {
                let checkRow = centerRow + Int(Double(r) * sin(angle))
                let checkCol = centerCol + Int(Double(r) * cos(angle))

                guard checkRow >= 0 && checkRow < rows && checkCol >= 0 && checkCol < cols else { break }

                let elevDiff = abs(elevationData[checkRow][checkCol] - centerElevation)
                if elevDiff > 0.5 {
                    edgeDistance = Double(r)
                    break
                }
            }

            if edgeDistance > 0 {
                distances.append(edgeDistance)
            }
        }

        guard distances.count >= 3 else { return 0.5 }

        // Calculate coefficient of variation (std dev / mean)
        let mean = distances.reduce(0, +) / Double(distances.count)
        let variance = distances.map { pow($0 - mean, 2) }.reduce(0, +) / Double(distances.count)
        let stdDev = sqrt(variance)

        // Coefficient of variation normalized to 0-1 range
        // Perfect circles/squares have CV near 0, irregular shapes have CV > 0.3
        let coefficientOfVariation = mean > 0 ? stdDev / mean : 0
        return min(coefficientOfVariation * 2.0, 1.0) // Scale up and cap at 1.0
    }

    /// Detects parallel features (modern roads have curbs, shoulders)
    /// Returns 0.0 (no parallel features) to 1.0 (strong parallel pattern)
    private func detectParallelFeatures(
        elevationData: [[Double]],
        centerPoints: [(row: Int, col: Int)],
        searchDistance: Int = 5
    ) -> Double {
        guard centerPoints.count >= 3 else { return 0.0 }

        let rows = elevationData.count
        let cols = elevationData[0].count
        var parallelScore = 0.0
        var checkedPoints = 0

        // Check for parallel ridges/features on both sides
        for point in centerPoints {
            guard point.row >= searchDistance && point.row < rows - searchDistance &&
                  point.col >= searchDistance && point.col < cols - searchDistance else { continue }

            let centerElevation = elevationData[point.row][point.col]

            // Check perpendicular directions for parallel features
            // Modern roads have consistent parallel structures (curbs, shoulders)
            var leftScore = 0.0
            var rightScore = 0.0

            for offset in 1...searchDistance {
                // Check both sides
                let leftElev = elevationData[point.row][point.col - offset]
                let rightElev = elevationData[point.row][point.col + offset]

                // Look for symmetric elevation patterns
                let leftDiff = abs(leftElev - centerElevation)
                let rightDiff = abs(rightElev - centerElevation)

                if abs(leftDiff - rightDiff) < 0.3 {
                    // Similar elevation changes on both sides = parallel pattern
                    parallelScore += 1.0
                }
            }

            checkedPoints += 1
        }

        return checkedPoints > 0 ? min(parallelScore / Double(checkedPoints * searchDistance), 1.0) : 0.0
    }

    /// Calculates straightness score for a linear feature
    /// Returns 0.0 (very curved/meandering) to 1.0 (perfectly straight)
    /// Historical paths tend to meander (0.3-0.7)
    /// Modern roads tend to be straight (0.8-1.0)
    private func calculateStraightness(points: [(row: Int, col: Int)]) -> Double {
        guard points.count >= 3,
              let first = points.first,
              let last = points.last else { return 0.5 }
        let idealLength = sqrt(pow(Double(last.row - first.row), 2) + pow(Double(last.col - first.col), 2))

        // Calculate actual path length
        var actualLength = 0.0
        for i in 0..<(points.count - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            actualLength += sqrt(pow(Double(p2.row - p1.row), 2) + pow(Double(p2.col - p1.col), 2))
        }

        // Straightness = ideal length / actual length
        // Perfect straight line = 1.0, curved path < 1.0
        return idealLength > 0 ? min(idealLength / actualLength, 1.0) : 0.5
    }

    /// Calculates edge sharpness score
    /// Returns 0.0 (very weathered/rounded) to 1.0 (sharp/crisp edges)
    /// Historical features have weathered edges (0.2-0.6)
    /// Modern features have sharp edges (0.7-1.0)
    private func calculateEdgeSharpness(
        elevationData: [[Double]],
        centerRow: Int,
        centerCol: Int,
        radius: Int
    ) -> Double {
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Sample edge gradients at multiple angles
        var maxGradients: [Double] = []
        let angles: [Double] = stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8).map { $0 }

        for angle in angles {
            // Check gradient at edge
            var maxGradient = 0.0

            for r in 1..<radius {
                let row = centerRow + Int(Double(r) * sin(angle))
                let col = centerCol + Int(Double(r) * cos(angle))

                guard row > 0 && row < rows - 1 && col > 0 && col < cols - 1 else { continue }

                // Calculate local gradient magnitude
                let dx = (elevationData[row][col + 1] - elevationData[row][col - 1]) / 2.0
                let dy = (elevationData[row + 1][col] - elevationData[row - 1][col]) / 2.0
                let gradient = sqrt(dx * dx + dy * dy)

                maxGradient = max(maxGradient, gradient)
            }

            if maxGradient > 0 {
                maxGradients.append(maxGradient)
            }
        }

        guard !maxGradients.isEmpty else { return 0.5 }

        // High average gradient = sharp edges (modern)
        // Low average gradient = weathered edges (historical)
        let avgGradient = maxGradients.reduce(0, +) / Double(maxGradients.count)

        // Normalize: 0.5+ gradient = sharp (1.0), 0.1- gradient = weathered (0.0)
        let sharpness = min(max((avgGradient - 0.1) / 0.4, 0.0), 1.0)
        return sharpness
    }

    /// Calculates circularity perfection score
    /// Returns 0.0 (very irregular) to 1.0 (perfect circle)
    /// Historical features tend to be irregular (0.4-0.7)
    /// Modern features tend to be perfect (0.85-1.0)
    private func calculateCircularityPerfection(
        elevationData: [[Double]],
        centerRow: Int,
        centerCol: Int,
        radius: Double
    ) -> Double {
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Sample points around the circle
        let angles: [Double] = stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 16).map { $0 }
        var deviations: [Double] = []
        let centerElevation = elevationData[centerRow][centerCol]

        for angle in angles {
            let checkRow = centerRow + Int(radius * sin(angle))
            let checkCol = centerCol + Int(radius * cos(angle))

            guard checkRow >= 0 && checkRow < rows && checkCol >= 0 && checkCol < cols else { continue }

            let ringElevation = elevationData[checkRow][checkCol]
            deviations.append(ringElevation)
        }

        guard !deviations.isEmpty else { return 0.5 }

        // Calculate uniformity of ring elevations
        let mean = deviations.reduce(0, +) / Double(deviations.count)
        let variance = deviations.map { pow($0 - mean, 2) }.reduce(0, +) / Double(deviations.count)
        let stdDev = sqrt(variance)

        // Low std dev = highly uniform = likely modern
        // High std dev = irregular = likely historical
        // Normalize: stdDev of 0.1m = 0.9 perfection, 1.0m = 0.1 perfection
        let perfection = max(0, 1.0 - (stdDev / 1.0))
        return perfection
    }

    /// Applies modern feature penalties to confidence score
    /// Reduces confidence for features with modern characteristics
    private func applyModernFeaturePenalties(
        baseConfidence: Double,
        featureType: FeatureType,
        geometricRegularity: Double,
        coordinate: CLLocationCoordinate2D? = nil
    ) async -> Double {
        var adjustedConfidence = baseConfidence

        // Penalize features with very regular geometry (likely modern)
        // Historical features are organic and irregular
        // Using moderate penalties to balance false positive reduction with feature detection
        if geometricRegularity < ModernFeatureThresholds.veryHighRegularity {
            // Extremely regular (perfect geometry) = very likely modern
            adjustedConfidence *= ModernFeatureThresholds.regularityPenaltyHigh
            logger.debug("Very regular geometry detected, confidence reduced")
        } else if geometricRegularity < ModernFeatureThresholds.highRegularity {
            // Quite regular = possibly modern
            adjustedConfidence *= ModernFeatureThresholds.regularityPenaltyMedium
            logger.debug("Regular geometry detected, confidence reduced")
        } else if geometricRegularity < ModernFeatureThresholds.moderateRegularity {
            // Somewhat regular = might be modern or well-preserved historical
            adjustedConfidence *= ModernFeatureThresholds.regularityPenaltyLow
            logger.debug("Moderately regular geometry, minor confidence reduction")
        }
        // geometricRegularity >= moderateRegularity = irregular, likely historical, no penalty

        // Check proximity to modern infrastructure using OpenStreetMap data
        if let coord = coordinate {
            let osmPenalty = await osmService.modernInfrastructurePenalty(
                coordinate: coord,
                penaltyRadiusMeters: ModernFeatureThresholds.osmProximityRadiusMeters
            )

            if osmPenalty < 1.0 {
                adjustedConfidence *= osmPenalty
                logger.debug("Feature near modern infrastructure (OSM), confidence reduced by \(String(format: "%.0f", (1.0 - osmPenalty) * 100))%")
            }

            // Check terrain classification using satellite imagery
            let terrainPenalty = await satelliteService.terrainPenalty(coordinate: coord)

            if terrainPenalty < 1.0 {
                adjustedConfidence *= terrainPenalty
                logger.debug("Artificial surface detected (Satellite), confidence reduced by \(String(format: "%.0f", (1.0 - terrainPenalty) * 100))%")
            }
        }

        return adjustedConfidence
    }

    private func calculateArea(elevationChange: Double) -> Double {
        // Simple estimation based on elevation change
        // Assumes circular mound with radius proportional to height
        let estimatedRadius = elevationChange * 5.0
        return Double.pi * estimatedRadius * estimatedRadius
    }

    private func estimateDiameter(elevationChange: Double) -> Double {
        return elevationChange * 10.0
    }

    // MARK: - Persistence

    private func saveDetectedFeatures() {
        let features = Array(detectedFeatures.values)
        if let data = try? JSONEncoder().encode(features) {
            AppSettings.detectedHistoricalFeaturesData = data
        }
    }

    private func loadDetectedFeatures() {
        guard let data = AppSettings.detectedHistoricalFeaturesData,
              let features = try? JSONDecoder().decode([HistoricalFeature].self, from: data) else {
            return
        }

        for feature in features {
            detectedFeatures[feature.id] = feature
        }
    }

    private func loadKnownSites() {
        // Skip if already loaded
        guard knownSites.isEmpty else { return }

        // Load known historical sites from bundled database
        // This would be populated from a JSON file or external database
        // For now, we'll add some example sites

        // Example: Cahokia Mounds - using fixed UUID so it's consistent across launches
        let cahokia = HistoricalFeature(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            coordinate: CLLocationCoordinate2D(latitude: 38.6551, longitude: -90.0628),
            featureType: .mound,
            confidence: .confirmed,
            metadata: FeatureMetadata(
                customName: "Cahokia Mounds",
                notes: "Largest pre-Columbian settlement north of Mexico",
                historicalPeriod: "800-1400 CE",
                culture: "Mississippian",
                verified: true
            )
        )

        // Example: Poverty Point - using fixed UUID
        let povertyPoint = HistoricalFeature(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            coordinate: CLLocationCoordinate2D(latitude: 32.6381, longitude: -91.4084),
            featureType: .earthwork,
            confidence: .confirmed,
            metadata: FeatureMetadata(
                customName: "Poverty Point",
                notes: "Massive earthwork complex",
                historicalPeriod: "1700-1100 BCE",
                culture: "Poverty Point",
                verified: true
            )
        )

        knownSites = [cahokia, povertyPoint]
        logger.info("Loaded \(self.knownSites.count) known historical sites")
    }

    // MARK: - Export Functionality

    func exportFeatures() -> String {
        let features = getAllFeatures()
        var csv = "ID,Name,Type,Latitude,Longitude,Confidence,Date Detected,Notes\n"

        for feature in features {
            let name = (feature.metadata.customName ?? feature.featureType.rawValue).replacingOccurrences(of: ",", with: ";")
            let notes = (feature.metadata.notes ?? "").replacingOccurrences(of: ",", with: ";")

            csv += "\(feature.id.uuidString),"
            csv += "\(name),"
            csv += "\(feature.featureType.rawValue),"
            csv += "\(feature.coordinate.latitude),"
            csv += "\(feature.coordinate.longitude),"
            csv += "\(feature.confidence.rawValue),"
            csv += "\(feature.detectionDate.formatted()),"
            csv += "\(notes)\n"
        }

        return csv
    }
}
