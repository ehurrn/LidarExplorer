//
//  HistoricalFeaturesView.swift
//  LidarExplorer
//
//  View for displaying detected historical features
//

import SwiftUI
import MapKit

enum SearchMode: String, CaseIterable, Identifiable {
    case text = "Name"
    case radius = "Radius"
    case territory = "Territory"
    case currentView = "Current View"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .text: return "magnifyingglass"
        case .radius: return "location.circle"
        case .territory: return "map"
        case .currentView: return "viewfinder"
        }
    }
}

struct HistoricalFeaturesView: View {
    @Binding var features: [HistoricalFeature]
    @Binding var selectedFeature: HistoricalFeature?
    let currentMapRegion: MKCoordinateRegion?
    let territories: [HistoricalTerritory]
    @Environment(\.dismiss) var dismiss

    @State private var searchText = ""
    @State private var searchMode: SearchMode = .text
    @State private var filterConfidence: DetectionConfidence = .veryLow
    @State private var showExportSheet = false
    @State private var exportData = ""

    // Radius search state
    @State private var radiusMiles: Double = 10.0
    @State private var radiusCenter: CLLocationCoordinate2D?
    @State private var useMapCenter = true

    // Territory search state
    @State private var selectedTerritory: String = "All"

    // Filtered results cache
    @State private var filteredFeatures: [HistoricalFeature] = []

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search and filter controls
                VStack(spacing: 12) {
                    // Search mode picker
                    Picker("Search Mode", selection: $searchMode) {
                        ForEach(SearchMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Search controls based on mode
                    switch searchMode {
                    case .text:
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search features...", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                    case .radius:
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "location.circle")
                                    .foregroundColor(.secondary)
                                Text("Search within \(String(format: "%.1f", radiusMiles)) miles")
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(.horizontal, 10)

                            Slider(value: $radiusMiles, in: 1...50, step: 0.5)
                                .padding(.horizontal, 10)

                            Toggle("Use map center", isOn: $useMapCenter)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .onChange(of: useMapCenter) { _, newValue in
                                    if newValue {
                                        radiusCenter = currentMapRegion?.center
                                    }
                                }

                            if !useMapCenter {
                                HStack {
                                    Image(systemName: "mappin.circle")
                                        .foregroundColor(.secondary)
                                    TextField("Enter coordinates...", text: $searchText)
                                        .textFieldStyle(.plain)
                                        .font(.caption)
                                        .onSubmit {
                                            Task {
                                                if let coord = await SpatialSearchService.shared.parseCoordinates(from: searchText) {
                                                    radiusCenter = coord
                                                }
                                            }
                                        }
                                }
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                                .padding(.horizontal, 10)
                            }
                        }
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                    case .territory:
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "map")
                                    .foregroundColor(.secondary)
                                Text("Search within territory")
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(.horizontal, 10)

                            Picker("Territory", selection: $selectedTerritory) {
                                Text("All Territories").tag("All")
                                ForEach(territories, id: \.id) { territory in
                                    Text(territory.name).tag(territory.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 10)
                        }
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                    case .currentView:
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "viewfinder")
                                    .foregroundColor(.secondary)
                                Text("Showing features in current map view")
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(10)
                        }
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }

                    // Confidence filter
                    HStack {
                        Text("Min Confidence:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Confidence", selection: $filterConfidence) {
                            Text("All").tag(DetectionConfidence.veryLow)
                            Text("Low+").tag(DetectionConfidence.low)
                            Text("Medium+").tag(DetectionConfidence.medium)
                            Text("High+").tag(DetectionConfidence.high)
                            Text("Very High+").tag(DetectionConfidence.veryHigh)
                            Text("Confirmed").tag(DetectionConfidence.confirmed)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding()
                .background(Color(.systemBackground))

                Divider()

                // Features list
                if filteredFeatures.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text(features.isEmpty ? "No features detected yet" : "No features match your filters")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if features.isEmpty {
                            Text("Enable analysis mode and explore the map to discover historical sites")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        Section(header: Text("\(filteredFeatures.count) Features Found")) {
                            ForEach(filteredFeatures) { feature in
                                FeatureRow(feature: feature)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedFeature = feature
                                        dismiss()
                                    }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Historical Features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        exportFeatures()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(features.isEmpty)
                }
            }
            .sheet(isPresented: $showExportSheet) {
                ExportView(csvData: exportData)
            }
        }
        .onAppear {
            if let center = currentMapRegion?.center {
                radiusCenter = center
            }
            updateFilteredFeatures()
        }
        .onChange(of: searchText) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: searchMode) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: filterConfidence) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: radiusMiles) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: radiusCenter) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: selectedTerritory) { _, _ in
            updateFilteredFeatures()
        }
        .onChange(of: features) { _, _ in
            updateFilteredFeatures()
        }
    }

    private func updateFilteredFeatures() {
        Task {
            var filtered = features

            // Apply search mode filtering
            switch searchMode {
            case .text:
                filtered = filtered.filter { feature in
                    searchText.isEmpty || feature.title.localizedCaseInsensitiveContains(searchText)
                }

            case .radius:
                if let center = radiusCenter {
                    filtered = await SpatialSearchService.shared.filterFeaturesWithinRadius(
                        features: filtered,
                        center: center,
                        radiusMiles: radiusMiles
                    )
                }

            case .territory:
                if selectedTerritory != "All",
                   let territory = territories.first(where: { $0.name == selectedTerritory }) {
                    filtered = await SpatialSearchService.shared.filterFeaturesInTerritory(
                        features: filtered,
                        territory: territory
                    )
                }

            case .currentView:
                if let region = currentMapRegion {
                    filtered = await SpatialSearchService.shared.filterFeaturesInRegion(
                        features: filtered,
                        region: region
                    )
                }
            }

            // Apply confidence filter
            filtered = filtered.filter { feature in
                feature.confidence >= filterConfidence
            }

            // Update state on main actor
            await MainActor.run {
                self.filteredFeatures = filtered.sorted { $0.confidence.threshold > $1.confidence.threshold }
            }
        }
    }

    private func exportFeatures() {
        Task {
            exportData = await HistoricalAnalysisEngine.shared.exportFeatures()
            showExportSheet = true
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let feature: HistoricalFeature

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: feature.featureType.icon)
                .font(.title2)
                .foregroundColor(confidenceColor(feature.confidence))
                .frame(width: 40, height: 40)
                .background(confidenceColor(feature.confidence).opacity(0.2))
                .clipShape(Circle())

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label(feature.confidence.rawValue, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundColor(confidenceColor(feature.confidence))

                    if let dimensions = feature.dimensions {
                        Text(dimensions.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("\(feature.coordinate.latitude, specifier: "%.4f"), \(feature.coordinate.longitude, specifier: "%.4f")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospaced()
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func confidenceColor(_ confidence: DetectionConfidence) -> Color {
        switch confidence {
        case .confirmed: return .green
        case .veryHigh: return .blue
        case .high: return .teal
        case .medium: return .yellow
        case .low: return .orange
        case .veryLow: return .red
        }
    }
}

// MARK: - Export View

struct ExportView: View {
    let csvData: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Export Historical Features")
                    .font(.headline)
                    .padding(.top)

                Text("CSV data is ready to export")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ScrollView {
                    Text(csvData)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                }
                .padding()

                ShareLink(
                    item: csvData,
                    preview: SharePreview(
                        "Historical Features",
                        icon: Image(systemName: "doc.text")
                    )
                ) {
                    Label("Share CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    HistoricalFeaturesView(
        features: .constant([
            HistoricalFeature(
                coordinate: CLLocationCoordinate2D(latitude: 38.6551, longitude: -90.0628),
                featureType: .mound,
                confidence: .confirmed,
                metadata: FeatureMetadata(customName: "Cahokia Mounds")
            ),
            HistoricalFeature(
                coordinate: CLLocationCoordinate2D(latitude: 32.6381, longitude: -91.4084),
                featureType: .earthwork,
                confidence: .high,
                metadata: FeatureMetadata(customName: "Test Feature")
            )
        ]),
        selectedFeature: .constant(nil),
        currentMapRegion: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 38.6551, longitude: -90.0628),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ),
        territories: []
    )
}
