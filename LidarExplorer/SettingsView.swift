//
//  SettingsView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 12/12/25.
//


import SwiftUI

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var cacheManager = TileCacheManager.shared
    
    // We update the usage string when the view appears
    @State private var currentUsage: String = "Calculating..."
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Storage & Network")) {
                    // Cache Size Picker
                    Picker("Max Cache Size", selection: $cacheManager.maxCacheSizeGB) {
                        Text("500 MB").tag(0.5)
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                    
                    // Usage Display
                    HStack {
                        Text("Current Usage")
                        Spacer()
                        Text(currentUsage)
                            .foregroundColor(.secondary)
                    }
                    
                    // Nuke Button
                    Button(action: {
                        cacheManager.clearCache()
                        updateUsage()
                    }) {
                        Text("Clear Cache Now")
                            .foregroundColor(.red)
                    }
                }
                
                Section(footer: Text("Using USGS 3DEP ImageServer. Tiles are cached locally to reduce server load.")) {
                    // Just informational
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
        // Enforce the limit first, then calculate size
        cacheManager.enforceLimit() 
        currentUsage = cacheManager.getCurrentUsage()
    }
}