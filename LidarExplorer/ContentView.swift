//
//  ContentView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 12/12/25.
//


import SwiftUI
import MapKit

struct ContentView: View {
    // 1. App Lifecycle Watcher (Fixes the "blank tiles on wake" bug)
    @Environment(\.scenePhase) var scenePhase
    
    // 2. Managers & State
    @StateObject private var locationManager = LocationManager()
    
    // Map Configuration
    @State private var overlayOpacity: Double = 0.7
    @State private var mapType: MKMapType = .standard
    @State private var searchCoordinate: CLLocationCoordinate2D?
    @State private var zoomLevel: Double = 0.5 // 0.0 (High) to 1.0 (Deep Zoom)
    
    // Map Refresh Token (Changes to force a reload)
    @State private var refreshID = UUID()
    
    // UI State
    @State private var searchText = ""
    @State private var showLayerMenu = false
    @State private var showSettings = false
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // --- LAYER 1: THE MAP ENGINE ---
            USGSMapView(
                opacity: $overlayOpacity,
                mapType: $mapType,
                searchCoordinate: $searchCoordinate,
                zoomLevel: $zoomLevel
            )
            .id(refreshID) // Rebuilds map when this ID changes
            .edgesIgnoringSafeArea(.all)
            
            // --- LAYER 2: THE UI OVERLAY ---
            VStack {
                
                // TOP BAR: Settings + Search
                HStack(spacing: 12) {
                    
                    // Settings Button
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    
                    // Search Field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search USA (City, Zip)...", text: $searchText)
                            .submitLabel(.search)
                            .onSubmit {
                                performSearch()
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal)
                    .background(.ultraThinMaterial)
                    .cornerRadius(25)
                    .shadow(radius: 4)
                }
                .padding(.horizontal)
                .padding(.top, 60) // Push down from Dynamic Island / Notch
                
                Spacer()
                
                // BOTTOM CONTROLS
                HStack(alignment: .bottom) {
                    
                    // LEFT: Layer & Opacity Menu
                    VStack(alignment: .leading) {
                        
                        // The Pop-up Menu
                        if showLayerMenu {
                            VStack(alignment: .leading, spacing: 15) {
                                Text("Lidar Intensity")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                                
                                Slider(value: $overlayOpacity, in: 0...1)
                                    .tint(.blue)
                                
                                Divider()
                                
                                Text("Base Map")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                                
                                Picker("Base Map", selection: $mapType) {
                                    Text("Standard").tag(MKMapType.standard)
                                    Text("Hybrid").tag(MKMapType.hybrid)
                                    Text("Satellite").tag(MKMapType.satellite)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding()
                            .frame(width: 260)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                            .transition(.scale.combined(with: .opacity).animation(.spring()))
                        }
                        
                        // The Toggle Button
                        Button(action: {
                            withAnimation { showLayerMenu.toggle() }
                        }) {
                            Image(systemName: "square.2.layers.3d")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 50, height: 50)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.leading, 20)
                    
                    Spacer()
                    
                    // RIGHT: Zoom & Location
                    VStack(spacing: 20) {
                        
                        // Custom Glass Slider
                        GlassZoomSlider(value: $zoomLevel)
                            .frame(height: 200)
                        
                        // Location Button
                        Button(action: {
                            locationManager.requestLocation()
                            if let loc = locationManager.location {
                                // Update map target to user location
                                searchCoordinate = loc.coordinate
                            }
                        }) {
                            Image(systemName: "location.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .frame(width: 50, height: 50)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.trailing, 20)
                }
                .padding(.bottom, 30)
            }
        }
        // Sheet for Settings
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Wake Up Handler
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                print("App woke up. Refreshing map connection...")
                // Slight delay to ensure network stack is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.refreshID = UUID()
                }
            }
        }
    }

    // --- Helper Logic ---
    
    func performSearch() {
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = searchText
        
        let search = MKLocalSearch(request: searchRequest)
        search.start { response, error in
            // We access .location?.coordinate instead of .placemark.coordinate
            guard let coordinate = response?.mapItems.first?.location.coordinate else { return }
            
            // Fly to location
            self.searchCoordinate = coordinate
            
            // Dismiss keyboard
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
