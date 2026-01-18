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
    }
    
    func onWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshID = UUID()
        }
    }
    
    func performSearch() {
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
            // Initialize the engine first (loads known sites)
            HistoricalAnalysisEngine.shared.initialize()

            let features = await HistoricalAnalysisEngine.shared.getAllFeatures()
            await MainActor.run {
                self.detectedFeatures = features
            }
        }
    }

    func runAnalysis(region: MKCoordinateRegion) {
        Task {
            isAnalyzing = true

            // For now, we'll use mock elevation data
            // In a real implementation, this would fetch actual DEM data
            let mockElevationData = generateMockElevationData(size: 100)

            let features = await HistoricalAnalysisEngine.shared.analyzeRegion(
                region: region,
                elevationData: mockElevationData
            )

            await MainActor.run {
                self.detectedFeatures = features
                self.isAnalyzing = false
            }
        }
    }

    func exportFeatures() -> String {
        var csv = ""
        Task {
            csv = await HistoricalAnalysisEngine.shared.exportFeatures()
        }
        return csv
    }

    // Helper to generate mock elevation data
    // In production, this would fetch real DEM data from USGS
    private func generateMockElevationData(size: Int) -> [[Double]] {
        var data: [[Double]] = []
        for i in 0..<size {
            var row: [Double] = []
            for j in 0..<size {
                // Generate some variation to simulate terrain
                let value = sin(Double(i) / 10.0) * cos(Double(j) / 10.0) * 10.0 + 100.0
                row.append(value)
            }
            data.append(row)
        }
        return data
    }
}
