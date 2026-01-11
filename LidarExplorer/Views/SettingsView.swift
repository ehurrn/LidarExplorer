//
//  SettingsView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var cacheManager = TileCacheManager.shared
    
    // Bind to the same key used in ContentView
    @AppStorage("startLocationMode") var startLocationMode: String = "random"
    
    @State private var currentUsage: String = "Calculating..."
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Startup Location"), footer: Text("Choose where the map centers when you open the app.")) {
                    Picker("Location", selection: $startLocationMode) {
                        Text("Random National Park").tag("random")
                        Text("My Current Location").tag("device")
                    }
                }
                
                Section(header: Text("Storage Management"), footer: Text("Lidar tiles are saved to your device to speed up loading. You can limit how much space the app uses.")) {
                    // Cache Size Picker
                    Picker("Maximum Storage Limit", selection: $cacheManager.maxCacheSizeGB) {
                        Text("500 MB").tag(0.5)
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                    
                    // Usage Display
                    HStack {
                        Text("Space Currently Used")
                        Spacer()
                        Text(currentUsage)
                            .foregroundColor(.secondary)
                    }
                    
                    // Nuke Button
                    Button(action: {
                        cacheManager.clearCache()
                        updateUsage()
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
                updateUsage()
            }
        }
    }
    
    func updateUsage() {
        cacheManager.enforceLimit()
        currentUsage = cacheManager.getCurrentUsage()
    }
}
