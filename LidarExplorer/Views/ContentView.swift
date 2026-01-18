//
//  ContentView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import SwiftUI
import MapKit

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var viewModel = ContentViewModel()
    @AppStorage("hasSeenTutorial") var hasSeenTutorial: Bool = false
    @State private var showFeaturesList = false

    private let panelWidth: CGFloat = 260
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // --- LAYER 1: MAP ENGINE ---
            USGSMapView(
                opacity: $viewModel.overlayOpacity,
                mapType: $viewModel.mapType,
                searchCoordinate: $viewModel.searchCoordinate,
                zoomLevel: $viewModel.zoomLevel,
                resetHeading: $viewModel.resetHeading,
                lidarSource: $viewModel.selectedSource,
                detectedFeatures: $viewModel.detectedFeatures,
                analysisEnabled: $viewModel.analysisEnabled,
                initialCoordinate: viewModel.startingLocation
                // REMOVED: startOnUserLocation
            )
            .id(viewModel.refreshID)
            .edgesIgnoringSafeArea(.all)
            
            // --- LAYER 2: UI OVERLAY ---
            VStack {
                Spacer() // Push everything to the bottom
                
                HStack(alignment: .bottom) {
                    
                    // --- LEFT STACK (Search & Layers) ---
                    VStack(alignment: .leading, spacing: 12) {
                        
                        // 1. Search Bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search...", text: $viewModel.searchText)
                                .font(.system(size: 14))
                                .submitLabel(.search)
                                .onSubmit { viewModel.performSearch() }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .frame(width: panelWidth, height: 44)
                        .background(.thinMaterial)
                        .cornerRadius(22)
                        .shadow(radius: 4)
                        
                        // 2. Layer Menu
                        if viewModel.showLayerMenu {
                            VStack(alignment: .leading, spacing: 15) {
                                Text("Lidar Source")
                                    .font(.caption).bold().foregroundColor(.secondary)
                                Picker("Source", selection: $viewModel.selectedSource) {
                                    ForEach(LidarSource.allCases) { source in
                                        Text(source.displayName).tag(source)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity)

                                Divider()
                                Text("Lidar Intensity")
                                    .font(.caption).bold().foregroundColor(.secondary)
                                Slider(value: $viewModel.overlayOpacity, in: 0...1).tint(.blue)
                                Divider()
                                Text("Base Map")
                                    .font(.caption).bold().foregroundColor(.secondary)
                                Picker("Base Map", selection: $viewModel.mapType) {
                                    Text("Standard").tag(MKMapType.standard)
                                    Text("Hybrid").tag(MKMapType.hybrid)
                                    Text("Satellite").tag(MKMapType.satellite)
                                }
                                .pickerStyle(.segmented)

                                Divider()

                                // Historical Analysis Toggle
                                HStack {
                                    Text("Historical Analysis")
                                        .font(.caption).bold().foregroundColor(.secondary)
                                    Spacer()
                                    Toggle("", isOn: $viewModel.analysisEnabled)
                                        .labelsHidden()
                                        .onChange(of: viewModel.analysisEnabled) { _, newValue in
                                            if newValue {
                                                viewModel.loadDetectedFeatures()
                                            }
                                        }
                                }

                                if viewModel.analysisEnabled {
                                    Text("\(viewModel.detectedFeatures.count) features detected")
                                        .font(.caption)
                                        .foregroundColor(.blue)

                                    if viewModel.isAnalyzing {
                                        HStack {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                            Text("Analyzing...")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding()
                            .frame(width: panelWidth)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                            .transition(.scale.combined(with: .opacity).animation(.spring()))
                        }
                        
                        // 3. Layer Toggle Button
                        Button(action: { withAnimation { viewModel.showLayerMenu.toggle() } }) {
                            Image(systemName: "square.2.layers.3d")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 50, height: 50)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        
                        // 4. Location Button
                        Button(action: { viewModel.useCurrentLocation() }) {
                            Image(systemName: "location.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .frame(width: 50, height: 50)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 30)
                    
                    Spacer()
                    
                    // --- RIGHT STACK (Zoom & Settings) ---
                    VStack(spacing: 20) {

                        // 1. Zoom
                        GlassZoomSlider(value: $viewModel.zoomLevel)
                            .frame(height: 240)

                        // 2. Historical Features Button (only show when analysis enabled)
                        if viewModel.analysisEnabled {
                            Button(action: { showFeaturesList = true }) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .frame(width: 50, height: 50)
                                        .background(.thinMaterial)
                                        .clipShape(Circle())
                                        .shadow(radius: 4)

                                    if !viewModel.detectedFeatures.isEmpty {
                                        Text("\(viewModel.detectedFeatures.count)")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                            .padding(4)
                                            .background(Color.red)
                                            .clipShape(Circle())
                                            .offset(x: 8, y: -8)
                                    }
                                }
                            }
                        }

                        // 3. Settings Button
                        Button(action: { viewModel.showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 50, height: 50)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 30)
                }
            }
            
            // --- LAYER 3: TUTORIAL OVERLAY ---
            if !hasSeenTutorial {
                TutorialOverlay(step: $viewModel.tutorialStep, onFinish: {
                    hasSeenTutorial = true
                }, onOpenLayers: {
                    viewModel.showLayerMenu = true
                })
            }
        }
        .sheet(isPresented: $viewModel.showSettings) { SettingsView() }
        .sheet(isPresented: $showFeaturesList) {
            HistoricalFeaturesView(
                features: $viewModel.detectedFeatures,
                selectedFeature: $viewModel.showFeatureDetails
            )
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                viewModel.onWake()
            }
        }
        .onChange(of: viewModel.showFeatureDetails) { _, feature in
            if let feature = feature {
                // Navigate to feature on map
                viewModel.searchCoordinate = feature.coordinate
                viewModel.showFeatureDetails = nil
            }
        }
    }
}
