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

// MARK: - Historical Analysis Engine

actor HistoricalAnalysisEngine {
    static let shared = HistoricalAnalysisEngine()

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
            print("⏭️ Skipping initialization - already initialized")
            return
        }

        print("🚀 Initializing HistoricalAnalysisEngine...")
        loadKnownSites()
        loadDetectedFeatures()
        isInitialized = true
        print("✅ HistoricalAnalysisEngine initialization complete")
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

        print("📊 Elevation data statistics:")
        print("   Size: \(elevationData.count)x\(elevationData.first?.count ?? 0)")
        print("   Min: \(String(format: "%.2f", minElev))m")
        print("   Max: \(String(format: "%.2f", maxElev))m")
        print("   Mean: \(String(format: "%.2f", meanElev))m")
        print("   Range: \(String(format: "%.2f", range))m")

        // Sample a few values to see what the data looks like
        if elevationData.count >= 5 && elevationData[0].count >= 5 {
            print("   Sample values (top-left corner):")
            for i in 0..<min(5, elevationData.count) {
                let row = elevationData[i].prefix(5).map { String(format: "%.1f", $0) }.joined(separator: ", ")
                print("     [\(row)]")
            }
        }

        var detectedFeatures: [HistoricalFeature] = []

        // Run different detection algorithms
        let mounds = await detectMounds(elevationData: elevationData, region: region)
        print("   🔍 Mound detection: found \(mounds.count) candidates")
        detectedFeatures += mounds

        let linear = await detectLinearFeatures(elevationData: elevationData, region: region)
        print("   🔍 Linear feature detection: found \(linear.count) candidates")
        detectedFeatures += linear

        let circular = await detectCircularPatterns(elevationData: elevationData, region: region)
        print("   🔍 Circular pattern detection: found \(circular.count) candidates")
        detectedFeatures += circular

        let terraces = await detectTerraces(elevationData: elevationData, region: region)
        print("   🔍 Terrace detection: found \(terraces.count) candidates")
        detectedFeatures += terraces

        // Filter by confidence threshold
        let filtered = detectedFeatures.filter {
            $0.confidence >= analysisSettings.minimumConfidence
        }

        // Add to detected features collection
        for feature in filtered {
            self.detectedFeatures[feature.id] = feature
        }

        saveDetectedFeatures()
        return filtered
    }

    // MARK: - Detection Algorithms

    private func detectMounds(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var mounds: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Need at least 7x7 for 5x5 neighborhood analysis
        guard rows >= 7 && cols >= 7 else { return [] }

        var localMaximaCount = 0
        var significantPeaks: [(elevation: Double, prominence: Double)] = []

        // Simple peak detection algorithm - look for local maxima
        for i in 3..<(rows - 3) {
            for j in 3..<(cols - 3) {
                let centerElevation = elevationData[i][j]

                // Check if this is a local maximum in a 5x5 neighborhood
                var isLocalMax = true
                var elevationSum = 0.0
                var count = 0
                var maxNeighborElevation = 0.0

                // Check 5x5 neighborhood
                for di in -2...2 {
                    for dj in -2...2 {
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

                // If it's a local maximum with significant elevation change (lowered threshold)
                if isLocalMax && elevationChange >= 0.5 {  // More sensitive: 0.5m instead of 1.0m
                    let coordinate = coordinateFromGridPosition(
                        row: i, col: j,
                        rows: rows, cols: cols,
                        region: region
                    )

                    // Calculate confidence based on prominence and sharpness
                    let prominence = elevationChange / max(0.1, centerElevation - maxNeighborElevation)
                    let confidenceScore = min(elevationChange / 5.0 * prominence, 1.0)
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
        print("     Mound detection debug:")
        print("       Total local maxima found: \(localMaximaCount)")
        print("       Peaks > 0.1m prominence: \(significantPeaks.count)")
        if !significantPeaks.isEmpty {
            let top5 = significantPeaks.sorted { $0.elevation > $1.elevation }.prefix(5)
            print("       Top 5 peaks:")
            for (i, peak) in top5.enumerated() {
                print("         #\(i+1): \(String(format: "%.2f", peak.elevation))m elevation change, \(String(format: "%.2f", peak.prominence))m prominence")
            }
        }
        print("       Mounds meeting threshold (≥0.5m): \(mounds.count)")

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
                if gradientMagnitude >= 0.3 {  // Lower threshold for more sensitivity
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

            // Create feature if cluster is significant enough (at least 3 points)
            if cluster.count >= 3 {
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

                let confidenceScore = min(Double(cluster.count) / 20.0 * avgStrength, 1.0)
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
                        if elevationDifference > 0.5 {
                            circularityScore += 1.0
                        }
                    }

                    if pointsChecked > 0 {
                        let avgRingElevation = ringElevationSum / Double(pointsChecked)
                        let uniformityScore = circularityScore / Double(pointsChecked)

                        // Detect both raised centers (mounds) and depressed centers (moats)
                        let elevationPattern = abs(centerElevation - avgRingElevation)

                        if uniformityScore > 0.6 && elevationPattern > 1.0 {
                            let coordinate = coordinateFromGridPosition(
                                row: i,
                                col: j,
                                rows: rows,
                                cols: cols,
                                region: region
                            )

                            let confidenceScore = min(uniformityScore * elevationPattern / 3.0, 1.0)
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
                if variance < 0.8 {  // Increased from 0.5 to allow slightly less perfect flatness
                    let flatnessScore = 1.0 - min(variance / 0.8, 1.0)

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

                        if topEdge > 0.8 || bottomEdge > 0.8 || leftEdge > 0.8 || rightEdge > 0.8 {
                            edgePoints += 1
                        }
                    }

                    // Detect terrace if it's flat AND has elevation changes at edges
                    if edgePoints >= terraceSize / 3 && maxEdgeDifference > 1.0 {
                        let coordinate = coordinateFromGridPosition(
                            row: i + terraceSize / 2,
                            col: j + terraceSize / 2,
                            rows: rows,
                            cols: cols,
                            region: region
                        )

                        let edgeScore = min(maxEdgeDifference / 3.0, 1.0)
                        let confidenceScore = (flatnessScore + edgeScore) / 2.0
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
            UserDefaults.standard.set(data, forKey: "detectedHistoricalFeatures")
        }
    }

    private func loadDetectedFeatures() {
        guard let data = UserDefaults.standard.data(forKey: "detectedHistoricalFeatures"),
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
        print("✅ Loaded \(knownSites.count) known historical sites")
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
