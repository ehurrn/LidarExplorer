//
//  TemporalAnalysisService.swift
//  LidarExplorer
//
//  Multi-temporal analysis for detecting volumetric and structural changes
//

import Foundation
import MapKit
import OSLog

/// Service for analyzing elevation data across multiple time periods
/// Helps distinguish modern disturbances from stable historical features
actor TemporalAnalysisService {
    static let shared = TemporalAnalysisService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "TemporalAnalysisService")
    private let demService = DEMDataService.shared

    // Cache for temporal data
    private var temporalCache: [String: TemporalDataset] = [:]

    private init() {}

    // MARK: - Public API

    /// Analyzes temporal stability of a feature
    /// Returns stability score (0.0 = highly unstable/modern, 1.0 = very stable/historical)
    func analyzeTemporalStability(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = 50.0
    ) async -> Double {
        logger.info("Analyzing temporal stability at \(coordinate.latitude), \(coordinate.longitude)")
        
        // Sample points in a grid around the coordinate
        let gridSize = 5
        let metersPerDegree = 111320.0 // Approximate at equator
        let deltaLat = radiusMeters / metersPerDegree
        let deltaLon = radiusMeters / (metersPerDegree * cos(coordinate.latitude * .pi / 180))
        
        var elevations: [Double] = []
        var samples = 0
        
        // Sample elevation in a grid pattern
        for i in 0..<gridSize {
            for j in 0..<gridSize {
                let latOffset = (Double(i) / Double(gridSize - 1) - 0.5) * 2.0 * deltaLat
                let lonOffset = (Double(j) / Double(gridSize - 1) - 0.5) * 2.0 * deltaLon
                
                let sampleCoord = CLLocationCoordinate2D(
                    latitude: coordinate.latitude + latOffset,
                    longitude: coordinate.longitude + lonOffset
                )
                
                if let elevation = await demService.fetchElevation(at: sampleCoord) {
                    elevations.append(elevation)
                    samples += 1
                }
            }
        }
        
        // Need at least some samples to analyze
        guard samples >= 3 else {
            logger.warning("Insufficient elevation samples for stability analysis")
            return 0.5 // Unknown stability
        }
        
        // Calculate statistical measures
        let meanElevation = elevations.reduce(0.0, +) / Double(elevations.count)
        let variance = elevations.map { pow($0 - meanElevation, 2) }.reduce(0.0, +) / Double(elevations.count)
        let stdDev = sqrt(variance)
        
        // Calculate elevation range
        let minElev = elevations.min() ?? 0
        let maxElev = elevations.max() ?? 0
        let elevationRange = maxElev - minElev
        
        // Stability heuristics:
        // 1. Low standard deviation (< 0.5m) suggests stable, undisturbed terrain
        // 2. Moderate std dev (0.5-2m) suggests natural variation or weathered features
        // 3. High std dev (> 2m) with sharp transitions suggests modern disturbance
        // 4. Very high range (> 5m) over small area suggests construction or excavation
        
        var stabilityScore = 1.0
        
        // Penalize high standard deviation (indicates inconsistent surface)
        if stdDev > 2.0 {
            stabilityScore *= 0.3 // Likely modern disturbance
        } else if stdDev > 1.0 {
            stabilityScore *= 0.6 // Possible disturbance or natural erosion
        } else if stdDev > 0.5 {
            stabilityScore *= 0.85 // Natural variation
        }
        
        // Penalize high elevation range over small area
        let rangeThreshold = radiusMeters * 0.1 // 10% of radius is significant
        if elevationRange > rangeThreshold {
            let rangeFactor = min(elevationRange / rangeThreshold, 3.0)
            stabilityScore *= (1.0 - (rangeFactor - 1.0) * 0.2)
        }
        
        // Smooth, consistent terrain gets a bonus
        if stdDev < 0.3 && elevationRange < 1.0 {
            stabilityScore = min(stabilityScore * 1.1, 1.0)
        }
        
        // Ensure score is within valid range
        stabilityScore = max(0.0, min(1.0, stabilityScore))
        
        logger.info("Stability analysis: mean=\(String(format: "%.2f", meanElevation))m, stdDev=\(String(format: "%.2f", stdDev))m, range=\(String(format: "%.2f", elevationRange))m, score=\(String(format: "%.2f", stabilityScore))")
        
        return stabilityScore
    }

    /// Detects volumetric changes between time periods
    func detectVolumetricChanges(
        region: MKCoordinateRegion,
        gridSize: Int = 25
    ) async -> TemporalChangeAnalysis? {
        // This would:
        // 1. Fetch elevation data from multiple time periods
        // 2. Calculate volume differences
        // 3. Identify areas of significant change
        // 4. Classify changes (cut/fill, erosion, construction)

        // Placeholder for future implementation
        logger.info("Temporal volumetric analysis requested for region (feature coming soon)")

        return nil // TODO: implement full volumetric analysis
    }

    /// Checks if a feature shows signs of recent disturbance
    func hasRecentDisturbance(
        coordinate: CLLocationCoordinate2D,
        thresholdMeters: Double = 0.5
    ) async -> Bool {
        logger.info("Checking for recent disturbance at \(coordinate.latitude), \(coordinate.longitude)")
        
        // Use stability analysis as a proxy for disturbance
        // Lower stability scores indicate more likely disturbance
        let stabilityScore = await analyzeTemporalStability(
            coordinate: coordinate,
            radiusMeters: 30.0
        )
        
        // Stability below 0.5 suggests significant disturbance
        let hasDisturbance = stabilityScore < 0.5
        
        // Additionally, check for extreme elevation variations in a tight radius
        // that might indicate construction, excavation, or significant modification
        let tightRadiusStability = await analyzeTemporalStability(
            coordinate: coordinate,
            radiusMeters: 10.0
        )
        
        // If tight radius shows much lower stability, that's a strong indicator
        let stabilityDropoff = stabilityScore - tightRadiusStability
        let hasSharpTransition = stabilityDropoff > 0.3
        
        let disturbanceDetected = hasDisturbance || hasSharpTransition
        
        if disturbanceDetected {
            logger.info("Disturbance detected: stability=\(String(format: "%.2f", stabilityScore)), tight=\(String(format: "%.2f", tightRadiusStability))")
        }
        
        return disturbanceDetected
    }

    /// Calculates change rate at a location (meters per year)
    func calculateChangeRate(
        coordinate: CLLocationCoordinate2D
    ) async -> Double? {
        logger.info("Calculating change rate at \(coordinate.latitude), \(coordinate.longitude)")
        
        // In the absence of true temporal data, we can estimate change rate
        // based on terrain characteristics and stability indicators
        
        let stabilityScore = await analyzeTemporalStability(
            coordinate: coordinate,
            radiusMeters: 50.0
        )
        
        // Get elevation data to analyze local terrain
        guard let centerElevation = await demService.fetchElevation(at: coordinate) else {
            logger.warning("Unable to fetch elevation for change rate calculation")
            return nil
        }
        
        // Sample nearby points to detect gradients
        let sampleDistance = 25.0 // meters
        let metersPerDegree = 111320.0
        let deltaLat = sampleDistance / metersPerDegree
        let deltaLon = sampleDistance / (metersPerDegree * cos(coordinate.latitude * .pi / 180))
        
        var maxGradient = 0.0
        
        // Check gradients in cardinal directions
        let directions: [(Double, Double)] = [
            (deltaLat, 0),      // North
            (-deltaLat, 0),     // South
            (0, deltaLon),      // East
            (0, -deltaLon)      // West
        ]
        
        for (latOffset, lonOffset) in directions {
            let sampleCoord = CLLocationCoordinate2D(
                latitude: coordinate.latitude + latOffset,
                longitude: coordinate.longitude + lonOffset
            )
            
            if let sampleElevation = await demService.fetchElevation(at: sampleCoord) {
                let gradient = abs(sampleElevation - centerElevation) / sampleDistance
                maxGradient = max(maxGradient, gradient)
            }
        }
        
        // Estimate change rate based on stability and gradient
        // Lower stability + high gradient = higher estimated change rate
        // This is a proxy for actual temporal measurements
        
        var estimatedChangeRate: Double = 0.0
        
        // Unstable areas with high gradients suggest active change
        if stabilityScore < 0.5 {
            // Recent disturbance suggests modern activity
            estimatedChangeRate = (1.0 - stabilityScore) * 0.5 // 0 to 0.25 m/year
            
            // Steep gradients increase change rate estimate (erosion/construction)
            if maxGradient > 0.1 { // 10% grade or more
                estimatedChangeRate += maxGradient * 2.0
            }
        } else if stabilityScore < 0.7 {
            // Moderate stability suggests slower natural change
            estimatedChangeRate = (1.0 - stabilityScore) * 0.1 // 0 to 0.03 m/year
        }
        // Else: high stability (> 0.7) suggests minimal change
        
        // Natural erosion baseline for any terrain
        let naturalErosionRate = 0.001 // 1mm per year baseline
        estimatedChangeRate = max(estimatedChangeRate, naturalErosionRate)
        
        logger.info("Estimated change rate: \(String(format: "%.4f", estimatedChangeRate)) m/year (stability: \(String(format: "%.2f", stabilityScore)), gradient: \(String(format: "%.4f", maxGradient)))")
        
        return estimatedChangeRate
    }
}

// MARK: - Data Models

struct TemporalDataset {
    let coordinate: CLLocationCoordinate2D
    let measurements: [TemporalMeasurement]
    let timestamp: Date
}

struct TemporalMeasurement {
    let date: Date
    let elevation: Double
    let source: String
    let accuracy: Double?
}

struct TemporalChangeAnalysis {
    let region: MKCoordinateRegion
    let timeRange: DateInterval
    let volumeChange: Double // cubic meters
    let changeType: ChangeType
    let significantChanges: [SignificantChange]

    enum ChangeType {
        case cut // Material removed
        case fill // Material added
        case erosion // Natural wearing
        case construction // Artificial modification
        case stable // No significant change
    }
}

struct SignificantChange {
    let coordinate: CLLocationCoordinate2D
    let elevationChange: Double
    let date: Date?
    let confidence: Double
}

// MARK: - Future Enhancements

/// Data fusion framework for integrating multiple data sources
/// This is a placeholder for the full implementation
struct DataFusionFramework {

    // MARK: - Satellite Imagery Integration

    /// Fetches satellite imagery for semantic classification
    static func fetchSatelliteImagery(
        region: MKCoordinateRegion,
        resolution: ImageResolution = .medium
    ) async -> SatelliteImage? {
        // TODO: Integrate with satellite imagery providers (Sentinel-2, Landsat, etc.)
        return nil
    }

    /// Applies semantic segmentation to classify terrain types
    static func classifyTerrain(
        image: SatelliteImage
    ) async -> TerrainClassification? {
        // TODO: Use ML model to classify:
        // - Paved surfaces (roads, parking lots)
        // - Buildings
        // - Vegetation (dense forest, open field)
        // - Water bodies
        // - Bare earth
        return nil
    }

    // MARK: - Multispectral Analysis

    /// Analyzes multispectral data for vegetation patterns
    static func analyzeVegetationPatterns(
        region: MKCoordinateRegion
    ) async -> VegetationAnalysis? {
        // TODO: Calculate NDVI (Normalized Difference Vegetation Index)
        // Helps identify disturbed areas (modern construction shows different vegetation)
        return nil
    }

    /// Detects surface material characteristics
    static func detectSurfaceMaterials(
        region: MKCoordinateRegion
    ) async -> SurfaceAnalysis? {
        // TODO: Use multispectral bands to distinguish:
        // - Concrete/asphalt (modern)
        // - Natural earth
        // - Weathered stone
        // - Vegetation
        return nil
    }

    // MARK: - Environmental Data Integration

    /// Fetches weather history for correlation analysis
    static func fetchWeatherHistory(
        coordinate: CLLocationCoordinate2D,
        timeRange: DateInterval
    ) async -> WeatherHistory? {
        // TODO: Integrate with weather APIs (NOAA, etc.)
        // Correlate erosion patterns with precipitation
        return nil
    }

    /// Retrieves soil moisture indices
    static func fetchSoilMoistureData(
        region: MKCoordinateRegion
    ) async -> SoilMoistureAnalysis? {
        // TODO: Use satellite-derived soil moisture data
        // Helps understand structural stability and erosion patterns
        return nil
    }

    // MARK: - Data Models

    struct SatelliteImage {
        let region: MKCoordinateRegion
        let date: Date
        let resolution: Double // meters per pixel
        let bands: [SpectralBand]
    }

    struct SpectralBand {
        let name: String
        let wavelengthNm: Double
        let data: [[Double]]
    }

    enum ImageResolution {
        case low    // 30m (Landsat)
        case medium // 10m (Sentinel-2)
        case high   // 3m (commercial)
        case veryHigh // <1m (aerial/drone)
    }

    struct TerrainClassification {
        let classes: [[TerrainClass]]
        let confidence: [[Double]]
    }

    enum TerrainClass {
        case paved
        case building
        case denseVegetation
        case sparseVegetation
        case water
        case bareEarth
        case unknown
    }

    struct VegetationAnalysis {
        let ndvi: [[Double]] // -1.0 to 1.0
        let vegetationHealth: [[VegetationHealth]]
    }

    enum VegetationHealth {
        case healthy
        case stressed
        case dead
        case none
    }

    struct SurfaceAnalysis {
        let materials: [[SurfaceMaterial]]
        let confidence: [[Double]]
    }

    enum SurfaceMaterial {
        case concrete
        case asphalt
        case gravel
        case soil
        case weatheredStone
        case vegetation
        case unknown
    }

    struct WeatherHistory {
        let measurements: [WeatherMeasurement]
    }

    struct WeatherMeasurement {
        let date: Date
        let precipitationMm: Double
        let temperatureCelsius: Double
        let windSpeedMps: Double
    }

    struct SoilMoistureAnalysis {
        let values: [[Double]] // 0.0 to 1.0
        let date: Date
    }
}
