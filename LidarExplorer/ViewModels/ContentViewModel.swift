//
//  ContentViewModel.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//


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
    
    // Map Configuration
    @Published var overlayOpacity: Double = 0.7
    @Published var mapType: MKMapType = .standard
    @Published var zoomLevel: Double = 0.5
    @Published var searchCoordinate: CLLocationCoordinate2D?
    @Published var resetHeading = false
    @Published var refreshID = UUID()
    
    // UI State
    @Published var searchText = ""
    @Published var showLayerMenu = false
    @Published var showSettings = false
    
    // Tutorial State
    @Published var tutorialStep = 0
    // We use AppStorage in the view, but we can track steps here if needed
    
    // Services
    let locationManager = LocationManager()
    
    // Startup Logic
    let startingLocation: CLLocationCoordinate2D
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 1. Pick a random park on launch
        self.startingLocation = SeedLocations.randomPark
        
        // 2. Hook up LocationManager updates if you need to react to them in the VM logic
        // (Optional: currently the View binds directly to the manager, which is fine,
        // but this setup allows future logic here)
        locationManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    // --- INTENTS (Actions) ---
    
    func onAppear() {
        locationManager.startLocationServices()
    }
    
    func onWake() {
        // Reconnect to map server on wake
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
}