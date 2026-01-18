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

        var detectedFeatures: [HistoricalFeature] = []

        // Run different detection algorithms
        detectedFeatures += await detectMounds(elevationData: elevationData, region: region)
        detectedFeatures += await detectLinearFeatures(elevationData: elevationData, region: region)
        detectedFeatures += await detectCircularPatterns(elevationData: elevationData, region: region)
        detectedFeatures += await detectTerraces(elevationData: elevationData, region: region)

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

        // Simple peak detection algorithm
        for i in 2..<(rows - 2) {
            for j in 2..<(cols - 2) {
                let centerElevation = elevationData[i][j]

                // Check if this is a local maximum
                var isLocalMax = true
                var elevationSum = 0.0
                var count = 0

                // Check 5x5 neighborhood
                for di in -2...2 {
                    for dj in -2...2 {
                        if di == 0 && dj == 0 { continue }
                        let neighborElevation = elevationData[i + di][j + dj]
                        elevationSum += neighborElevation
                        count += 1
                        if neighborElevation >= centerElevation {
                            isLocalMax = false
                        }
                    }
                }

                let averageNeighborElevation = elevationSum / Double(count)
                let elevationChange = centerElevation - averageNeighborElevation

                // If it's a local maximum with significant elevation change
                if isLocalMax && elevationChange >= analysisSettings.elevationChangeThreshold {
                    let coordinate = coordinateFromGridPosition(
                        row: i, col: j,
                        rows: rows, cols: cols,
                        region: region
                    )

                    let confidence = DetectionConfidence.from(
                        score: min(elevationChange / 10.0, 1.0)
                    )

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
                            notes: "Detected local elevation maximum"
                        )
                    )

                    mounds.append(feature)
                }
            }
        }

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

        // Calculate gradients
        var gradients: [(row: Int, col: Int, gradient: Double)] = []

        for i in 1..<(rows - 1) {
            for j in 1..<(cols - 1) {
                let dx = (elevationData[i][j + 1] - elevationData[i][j - 1]) / 2.0
                let dy = (elevationData[i + 1][j] - elevationData[i - 1][j]) / 2.0
                let gradientMagnitude = sqrt(dx * dx + dy * dy)

                if gradientMagnitude >= analysisSettings.slopeThreshold / 10.0 {
                    gradients.append((i, j, gradientMagnitude))
                }
            }
        }

        // Group gradients into linear features using simple clustering
        // This is a simplified version - a real implementation would use more sophisticated algorithms
        if !gradients.isEmpty {
            let centerGradient = gradients[gradients.count / 2]
            let coordinate = coordinateFromGridPosition(
                row: centerGradient.row,
                col: centerGradient.col,
                rows: rows,
                cols: cols,
                region: region
            )

            let confidence = DetectionConfidence.from(
                score: min(Double(gradients.count) / 100.0, 1.0)
            )

            let feature = HistoricalFeature(
                coordinate: coordinate,
                featureType: .linearFeature,
                confidence: confidence,
                metadata: FeatureMetadata(
                    notes: "Detected linear elevation pattern - possible road, wall, or earthwork"
                )
            )

            linearFeatures.append(feature)
        }

        return linearFeatures
    }

    private func detectCircularPatterns(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        // Simplified circular pattern detection
        // A real implementation would use Hough Circle Transform or similar
        return []
    }

    private func detectTerraces(
        elevationData: [[Double]],
        region: MKCoordinateRegion
    ) async -> [HistoricalFeature] {
        guard !elevationData.isEmpty else { return [] }

        var terraces: [HistoricalFeature] = []
        let rows = elevationData.count
        let cols = elevationData[0].count

        // Need at least 12x12 grid for safe 10x10 analysis with edge checking
        guard rows >= 12 && cols >= 12 else { return [] }

        // Look for horizontal platforms (areas with low slope variation)
        // Loop from 1 to (rows-11) so we can safely check i-1 and i+10
        for i in 1..<(rows - 11) {
            for j in 1..<(cols - 11) {
                var flatnessScore = 0.0
                var elevationSum = 0.0

                // Check 10x10 area starting at (i, j)
                for di in 0..<10 {
                    for dj in 0..<10 {
                        elevationSum += elevationData[i + di][j + dj]
                    }
                }

                let avgElevation = elevationSum / 100.0

                // Calculate variance
                var variance = 0.0
                for di in 0..<10 {
                    for dj in 0..<10 {
                        let diff = elevationData[i + di][j + dj] - avgElevation
                        variance += diff * diff
                    }
                }
                variance /= 100.0

                // Low variance indicates flatness
                if variance < 0.5 {
                    flatnessScore = 1.0 - min(variance / 0.5, 1.0)

                    // Check if there's an elevation change around the flat area (indicating a terrace edge)
                    var hasEdge = false
                    let edgeThreshold = 2.0

                    // Check edges of the flat area (safely within bounds)
                    for k in 0..<10 {
                        // Check top, bottom, left, right edges
                        if abs(elevationData[i - 1][j + k] - avgElevation) > edgeThreshold ||
                           abs(elevationData[i + 10][j + k] - avgElevation) > edgeThreshold ||
                           abs(elevationData[i + k][j - 1] - avgElevation) > edgeThreshold ||
                           abs(elevationData[i + k][j + 10] - avgElevation) > edgeThreshold {
                            hasEdge = true
                            break
                        }
                    }

                    if hasEdge && flatnessScore > 0.7 {
                        let coordinate = coordinateFromGridPosition(
                            row: i + 5,
                            col: j + 5,
                            rows: rows,
                            cols: cols,
                            region: region
                        )

                        let confidence = DetectionConfidence.from(score: flatnessScore)

                        let feature = HistoricalFeature(
                            coordinate: coordinate,
                            featureType: .terrace,
                            confidence: confidence,
                            dimensions: FeatureDimensions(
                                length: 10.0,
                                width: 10.0,
                                height: nil,
                                diameter: nil
                            ),
                            metadata: FeatureMetadata(
                                notes: "Detected flat platform with elevation change at edges"
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
