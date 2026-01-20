//
//  ContentViewModel.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import Foundation
import MapKit
import SwiftUI
import Combine

@MainActor
class ContentViewModel: ObservableObject {
    // --- STATE ---
    // Set default opacity level
    @Published var overlayOpacity: Double = 0.7
    // Set Base Map type
    @Published var mapType: MKMapType = .standard
    // Set zoom level on open
    @Published var zoomLevel: Double = 0.5
    // Start location
    @Published var searchCoordinate: CLLocationCoordinate2D?
    // Compass orientation?
    @Published var resetHeading = false
    @Published var refreshID = UUID()
    // Set default source to hillshade
    @Published var selectedSource: LidarSource = .usgsHillshade

    @Published var searchText = ""
    @Published var showLayerMenu = true
    @Published var showSettings = false
    @Published var tutorialStep = 0

    // Historical analysis features
    @Published var analysisEnabled = false
    @Published var showAnalysisSettings = false
    @Published var detectedFeatures: [HistoricalFeature] = []
    @Published var showFeatureDetails: HistoricalFeature?
    @Published var isAnalyzing = false
    @Published var currentMapRegion: MKCoordinateRegion?
    @Published var showAnalysisAlert = false
    @Published var analysisAlertTitle = ""
    @Published var analysisAlertMessage = ""

    // Historical context overlays
    @Published var showNativeAmericanTerritories = false
    @Published var showCivilWarSites = false
    @Published var showHistoricalTrails = false
    @Published var showArchaeologicalSites = false

    // Overlay data
    @Published var nativeAmericanTerritories: [HistoricalTerritory] = []
    @Published var civilWarSites: [HistoricalSite] = []
    @Published var historicalTrails: [HistoricalTrail] = []
    @Published var archaeologicalSites: [HistoricalSite] = []
    
    // The exact location to initialize the map
    let startingLocation: CLLocationCoordinate2D
    
    // Services
    let locationManager = LocationManager()
    private var cancellables = Set<AnyCancellable>()
    
    // Flag to track if we are waiting for the initial user location
    private var shouldAutoZoomToUser = false
    
    init() {
        // 1. DETERMINE START LOCATION
        let savedMode = UserDefaults.standard.string(forKey: "startLocationName") ?? "Random"
        
        if savedMode == "Current Location" {
            // Mode: Current Location
            // We use a random park as a placeholder so the map has something to render immediately.
            // We then set a flag to zoom to the user's location as soon as it becomes available.
            self.startingLocation = SeedLocations.randomParkCoordinate
            self.shouldAutoZoomToUser = true
            locationManager.startLocationServices()
            
        } else if savedMode == "Random" {
            // Mode: Random
            self.startingLocation = SeedLocations.randomParkCoordinate
            
        } else {
            // Mode: Specific Park
            if let park = SeedLocations.allParks.first(where: { $0.name == savedMode }) {
                self.startingLocation = park.coordinate
            } else {
                self.startingLocation = SeedLocations.randomParkCoordinate
            }
        }
        
        // 2. Propagate permission changes
        locationManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        // 3. Handle Auto-Zoom for "Current Location" mode
        // We listen for the first valid location update, then zoom and cancel the subscription.
        locationManager.$location
            .compactMap { $0 } // Ignore nil locations
            .first()           // Take only the first one
            .sink { [weak self] loc in
                guard let self = self else { return }
                if self.shouldAutoZoomToUser {
                    self.searchCoordinate = loc.coordinate
                    self.shouldAutoZoomToUser = false
                }
            }
            .store(in: &cancellables)
    }
    
    // --- INTENTS ---
    
    func onAppear() {
        // No explicit action needed; init handled the startup logic.
        loadHistoricalOverlays()
    }
    
    func onWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshID = UUID()
        }
    }
    
    func performSearch() {
        Task {
            // First, try to parse as coordinates
            if let coordinate = await SpatialSearchService.shared.parseCoordinates(from: searchText) {
                await MainActor.run {
                    self.searchCoordinate = coordinate
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                return
            }

            // If not coordinates, fall back to location search
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = searchText
            let search = MKLocalSearch(request: searchRequest)
            search.start { [weak self] response, error in
                guard let self = self,
                      let coordinate = response?.mapItems.first?.location.coordinate else { return }

                self.searchCoordinate = coordinate
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
    
    func useCurrentLocation() {
        locationManager.startLocationServices()
        if let loc = locationManager.location {
            searchCoordinate = loc.coordinate
        }
    }

    // --- HISTORICAL ANALYSIS INTENTS ---

    func toggleAnalysisMode() {
        analysisEnabled.toggle()
        if analysisEnabled {
            loadDetectedFeatures()
        }
    }

    func loadDetectedFeatures() {
        Task {
            do {
                // Initialize the engine first (loads known sites)
                // This is safe to call multiple times due to the guard in initialize()
                await HistoricalAnalysisEngine.shared.initialize()

                let features = await HistoricalAnalysisEngine.shared.getAllFeatures()
                print("📍 Loaded \(features.count) total features:")
                for feature in features {
                    print("  - \(feature.title) at (\(feature.coordinate.latitude), \(feature.coordinate.longitude))")
                }

                await MainActor.run {
                    self.detectedFeatures = features
                    print("✅ Updated UI with \(features.count) features")
                }
            } catch {
                print("❌ Error loading features: \(error)")
                await MainActor.run {
                    self.detectedFeatures = []
                }
            }
        }
    }

    func runAnalysis(region: MKCoordinateRegion) {
        Task {
            isAnalyzing = true
            let initialFeatureCount = detectedFeatures.count

            do {
                // Fetch real elevation data from USGS 3DEP API
                print("🔍 Starting analysis for region at (\(region.center.latitude), \(region.center.longitude))")
                let elevationData = try await DEMDataService.shared.fetchElevationData(
                    for: region,
                    resolution: 100
                )

                print("✅ Fetched elevation data, analyzing...")

                let newFeatures = await HistoricalAnalysisEngine.shared.analyzeRegion(
                    region: region,
                    elevationData: elevationData
                )

                // Get all features (including known sites)
                let allFeatures = await HistoricalAnalysisEngine.shared.getAllFeatures()

                // Update UI on main actor
                await MainActor.run {
                    self.detectedFeatures = allFeatures
                    self.isAnalyzing = false
                    print("✅ Analysis complete: \(allFeatures.count) features detected")

                    // Show success alert
                    let newCount = newFeatures.count
                    self.analysisAlertTitle = "Analysis Complete"
                    if newCount > 0 {
                        self.analysisAlertMessage = "Found \(newCount) new potential historical \(newCount == 1 ? "feature" : "features") in this area.\n\nTotal features: \(allFeatures.count)"
                    } else {
                        self.analysisAlertMessage = "No new features detected in this area.\n\nTotal features: \(allFeatures.count)"
                    }
                    self.showAnalysisAlert = true
                }

            } catch {
                print("❌ Error fetching elevation data: \(error.localizedDescription)")
                print("   Falling back to mock data for testing...")

                // Fallback to mock data if API fails
                let mockElevationData = generateMockElevationData(size: 100)

                let newFeatures = await HistoricalAnalysisEngine.shared.analyzeRegion(
                    region: region,
                    elevationData: mockElevationData
                )

                let allFeatures = await HistoricalAnalysisEngine.shared.getAllFeatures()

                await MainActor.run {
                    self.detectedFeatures = allFeatures
                    self.isAnalyzing = false

                    // Show success alert
                    let newCount = newFeatures.count
                    self.analysisAlertTitle = "Analysis Complete"
                    if newCount > 0 {
                        self.analysisAlertMessage = "Found \(newCount) new potential historical \(newCount == 1 ? "feature" : "features") in this area (using mock data).\n\nTotal features: \(allFeatures.count)"
                    } else {
                        self.analysisAlertMessage = "No new features detected in this area (using mock data).\n\nTotal features: \(allFeatures.count)"
                    }
                    self.showAnalysisAlert = true
                }
            }
        }
    }

    func runAnalysisForCurrentRegion() {
        guard let region = currentMapRegion else {
            print("No current map region available")
            analysisAlertTitle = "Unable to Analyze"
            analysisAlertMessage = "Please move or zoom the map first, then try analyzing again."
            showAnalysisAlert = true
            return
        }
        runAnalysis(region: region)
    }

    func exportFeatures() -> String {
        var csv = ""
        Task {
            csv = await HistoricalAnalysisEngine.shared.exportFeatures()
        }
        return csv
    }

    // Helper to generate mock elevation data with varied terrain features
    // In production, this would fetch real DEM data from USGS
    private func generateMockElevationData(size: Int) -> [[Double]] {
        var data: [[Double]] = []

        for i in 0..<size {
            var row: [Double] = []
            for j in 0..<size {
                // Base terrain with multiple patterns
                var elevation = 100.0

                // Large-scale rolling hills
                elevation += sin(Double(i) / 15.0) * cos(Double(j) / 15.0) * 8.0

                // Add some mounds (Gaussian peaks at specific locations)
                let moundLocations = [(25, 25), (60, 40), (75, 75)]
                for (mi, mj) in moundLocations {
                    let distSq = pow(Double(i - mi), 2) + pow(Double(j - mj), 2)
                    let moundHeight = 5.0 * exp(-distSq / 50.0) // Gaussian peak
                    elevation += moundHeight
                }

                // Add terraces (flat platforms at specific elevations)
                let terraceLocations = [(35, 60), (80, 30)]
                for (ti, tj) in terraceLocations {
                    if abs(i - ti) < 8 && abs(j - tj) < 8 {
                        // Create flat platform
                        elevation = 108.0
                    }
                }

                // Add linear features (ridges)
                // Diagonal ridge
                if abs((Double(i) - Double(j))) < 3 && i > 40 && i < 60 {
                    elevation += 3.0
                }

                // Add some noise for realism
                let noise = Double.random(in: -0.5...0.5)
                elevation += noise

                row.append(elevation)
            }
            data.append(row)
        }
        return data
    }

    // --- HISTORICAL OVERLAY MANAGEMENT ---

    func loadHistoricalOverlays() {
        let service = HistoricalOverlayService.shared
        nativeAmericanTerritories = service.getNativeAmericanTerritories()
        civilWarSites = service.getCivilWarSites()
        historicalTrails = service.getHistoricalTrails()
        archaeologicalSites = service.getArchaeologicalSites()
    }
}
