//
//  SettingsView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import SwiftUI
import Combine

// This ViewModel bridges the async Actor world with the sync SwiftUI world.
@MainActor
class SettingsViewModel: ObservableObject {
    @Published var maxCacheSizeGB: Double = 2.0
    @Published var currentUsage: String = "Calculating..."
    
    private var cancellable: AnyCancellable?

    init() {
        // Asynchronously subscribe to changes from the actor's publisher.
        Task {
            let subject = await TileCacheManager.shared.settingsChangedSubject
            cancellable = subject
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    self?.fetchCacheSizeSetting()
                }
        }
        
        // Load initial state from the actor.
        fetchInitialState()
    }
    
    func fetchInitialState() {
        Task {
            self.maxCacheSizeGB = await TileCacheManager.shared.maxCacheSizeGB
            self.currentUsage = await TileCacheManager.shared.getCurrentUsage()
        }
    }
    
    private func fetchCacheSizeSetting() {
        Task {
            self.maxCacheSizeGB = await TileCacheManager.shared.maxCacheSizeGB
        }
    }
    
    func updateUsage() {
        Task {
            await TileCacheManager.shared.pruneCache() // Prune first
            self.currentUsage = await TileCacheManager.shared.getCurrentUsage()
        }
    }
    
    func clearCache() {
        Task {
            await TileCacheManager.shared.clearCache()
            // After clearing, refresh the usage display.
            self.currentUsage = await TileCacheManager.shared.getCurrentUsage()
        }
    }
    
    func setMaxCacheSize(_ newSize: Double) {
        // Update the local state immediately for a responsive UI.
        self.maxCacheSizeGB = newSize
        // Tell the actor to update its state and prune if necessary.
        TileCacheManager.shared.updateMaxCacheSize(to: newSize)
    }
}


struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // Use the new ViewModel instead of accessing the actor directly.
    @StateObject private var viewModel = SettingsViewModel()
    
    @AppStorage("startLocationName") var startLocationName: String = "Random"
    
    var body: some View {
            NavigationView {
                Form {
                    Section(header: Text("Startup Behavior")) {
                        Picker("Start Location", selection: $startLocationName) {
                            Text("Current Location").tag("Current Location")
                            Text("Random National Park").tag("Random")
                            ForEach(SeedLocations.allParks) { park in
                                Text(park.name).tag(park.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                
                Section(header: Text("Storage Management"), footer: Text("Lidar tiles are saved to your device to speed up loading. You can limit how much space the app uses.")) {
                    // This Picker uses a custom binding to call the ViewModel's method.
                    Picker("Maximum Storage Limit", selection: Binding(
                        get: { viewModel.maxCacheSizeGB },
                        set: { viewModel.setMaxCacheSize($0) }
                    )) {
                        Text("500 MB").tag(0.5)
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                    
                    HStack {
                        Text("Space Currently Used")
                        Spacer()
                        Text(viewModel.currentUsage)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        viewModel.clearCache()
                    }) {
                        Text("Delete All Cached Maps")
                            .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("About Data"), footer: Text("All elevation data is sourced directly from the USGS 3DEP program. Connectivity is required to fetch new areas.")) {
                    HStack {
                        Text("Data Source")
                        Spacer()
                        Text("USGS National Map")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                viewModel.updateUsage()
            }
        }
    }
}
