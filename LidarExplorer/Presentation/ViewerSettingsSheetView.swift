//
//  ViewerSettingsSheetView.swift
//  LidarExplorer
//
//  Settings sheet for terrain adjustments, basemap styling, units, and diagnostics.
//

import StoreKit
import SwiftUI

public struct ViewerSettingsSheetView: View {

    @Bindable var model: TerrainViewerModel
    var store: StoreService
    var ads: AdService
    @Binding var showsDebug: Bool
    @Binding var showsHistoricalImporter: Bool
    @Binding var showsSoilImporter: Bool
    @Environment(\.dismiss) private var dismiss

    public init(
        model: TerrainViewerModel,
        store: StoreService,
        ads: AdService,
        showsDebug: Binding<Bool>,
        showsHistoricalImporter: Binding<Bool> = .constant(false),
        showsSoilImporter: Binding<Bool> = .constant(false)
    ) {
        self.model = model
        self.store = store
        self.ads = ads
        self._showsDebug = showsDebug
        self._showsHistoricalImporter = showsHistoricalImporter
        self._showsSoilImporter = showsSoilImporter
    }

    @State private var isExporting = false
    @State private var exportItems: [Any]?
    @State private var showsShareSheet = false
    @State private var exportError: String?

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                basemapSection
                historicalSection
                soilsSection
                unitsSection
                exportSection
                if let resolution = model.currentResolution {
                    detailSection(resolution)
                }
                storageSection
                upgradesSection
                diagnosticsSection
                attributionsSection
            }
            .navigationTitle("Terrain Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                await model.refreshDiskCacheStats()
            }
            .sheet(isPresented: $showsShareSheet) {
                if let exportItems {
                    ActivityView(activityItems: exportItems)
                }
            }
        }
    }

    // MARK: - Terrain Section

    private var terrainSection: some View {
        Section("Terrain Layer") {
            Toggle("Show Terrain Layer", isOn: $model.showsTerrain)

            if model.showsTerrain {
                if model.style.usesIllumination {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sun Altitude")
                            Spacer()
                            Text(String(format: "%.0f°", model.altitude))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.altitude, in: 5...85, step: 1)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Terrain Opacity")
                        Spacer()
                        Text(String(format: "%.0f%%", model.terrainOpacity * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.terrainOpacity, in: 0...1)
                }

                Picker("Contour Lines", selection: $model.contourInterval) {
                    ForEach(ContourInterval.allCases) { interval in
                        Text(interval.rawValue).tag(interval)
                    }
                }

                if model.style == .elevation {
                    Picker("Elevation Palette", selection: $model.palette) {
                        ForEach(HypsometricPalette.allCases) { pal in
                            Text(pal.displayName).tag(pal)
                        }
                    }
                }

                if model.style == .localRelief {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Smoothing Radius")
                            Spacer()
                            Text(String(format: "%.0f m", model.microTopographyOptions.lrmRadiusMeters))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.lrmRadiusMeters, in: 5...50, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Contrast Scale")
                            Spacer()
                            Text(String(format: "±%.1f m", model.microTopographyOptions.lrmScaleMeters))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.lrmScaleMeters, in: 0.5...5.0, step: 0.5)
                    }
                }

                if model.style == .skyView {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sky-View Radius")
                            Spacer()
                            Text(String(format: "%.0f m", model.microTopographyOptions.svfRadiusMeters))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.svfRadiusMeters, in: 5...30, step: 1)
                    }
                }

                if model.style == .rakingLight {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Vertical Exaggeration")
                            Spacer()
                            Text(String(format: "%.1f×", model.microTopographyOptions.zFactor))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.zFactor, in: 1...5, step: 0.5)
                    }
                }

                if model.style == .rrim {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Openness Radius")
                            Spacer()
                            Text(String(format: "%.0f m", model.microTopographyOptions.opennessRadiusMeters))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.opennessRadiusMeters, in: 5...40, step: 1)
                    }
                }

                if model.style.microTopographyProduct != nil {
                    Toggle("Habitation Potential Mask", isOn: $model.showsHabitationMask)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sky-View Shading")
                            Spacer()
                            Text(String(format: "%.0f%%", model.skyViewShading * 100)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.skyViewShading, in: 0...1)
                    }
                }
                if model.style == .rakingLight {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Grazing Sun Altitude")
                            Spacer()
                            Text(String(format: "%.0f°", model.rakingAltitude)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.rakingAltitude, in: 5...15, step: 1)
                    }
                }
                if model.style == .relativeElevation {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Band Width")
                            Spacer()
                            Text(String(format: "%.2f m", model.microTopographyOptions.remBandMeters)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.remBandMeters, in: 0...1, step: 0.25)
                    }
                    Button("Draw River Thalweg") {
                        model.interactionMode = .thalweg
                        dismiss()
                    }
                    Button("Clear Thalweg", role: .destructive) {
                        model.thalweg = []
                    }
                    .disabled(model.thalweg.isEmpty)
                }

                Button {
                    model.resetShading()
                } label: {
                    Label("Reset Shading Defaults", systemImage: "arrow.counterclockwise")
                }
                .disabled(!model.hasCustomShading)
            }
        }
    }

    // MARK: - Basemap Section

    private var basemapSection: some View {
        Section("Basemap") {
            Picker("Basemap Style", selection: $model.basemap) {
                ForEach(TerrainBasemap.allCases) { basemap in
                    Text(basemap.displayName).tag(basemap)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Basemap Opacity")
                    Spacer()
                    Text(String(format: "%.0f%%", model.basemapOpacity * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.basemapOpacity, in: 0...1)
            }
        }
    }

    // MARK: - Historical Maps Section

    private var historicalSection: some View {
        Section("Historical Maps") {
            Button("Import Map…") {
                dismiss()
                showsHistoricalImporter = true
            }

            if !model.historicalMaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(String(format: "%.0f%%", model.historicalOpacity * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.historicalOpacity, in: 0...1)
                }

                Toggle("Above terrain", isOn: $model.historicalAboveTerrain)

                Toggle("Split Wipe", isOn: Binding(
                    get: { model.historicalWipeFraction != nil },
                    set: { on in
                        model.historicalWipeFraction = on ? 0.5 : nil
                        if on {
                            model.interactionMode = .historicalWipe
                        } else if model.interactionMode == .historicalWipe {
                            model.interactionMode = .explore
                        }
                    }
                ))

                Button("Remove All", role: .destructive) {
                    model.removeHistoricalMaps()
                }
            }
        }
    }

    // MARK: - Soils (SSURGO) Section

    private var soilsSection: some View {
        Section("Soils (SSURGO)") {
            Toggle("Show Soil Hatching", isOn: $model.showsSoils)

            VStack(alignment: .leading, spacing: 6) {
                Text("Legend")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 18))
                                path.addLine(to: CGPoint(x: 18, y: 0))
                            }
                            .stroke(Color.blue, lineWidth: 1.5)
                        )
                    Text("Hydric clay (diagonal blue): backswamps, clay plugs")
                        .font(.caption)
                }
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.78, green: 0.58, blue: 0.28), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 18))
                                path.addLine(to: CGPoint(x: 18, y: 0))
                                path.move(to: CGPoint(x: 0, y: 0))
                                path.addLine(to: CGPoint(x: 18, y: 18))
                            }
                            .stroke(Color(red: 0.78, green: 0.58, blue: 0.28), lineWidth: 1.5)
                        )
                    Text("Well-drained sandy loam (cross-hatched tan): levees, point bars")
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)

            Button("Import GeoJSON…") {
                dismiss()
                showsSoilImporter = true
            }
        }
    }

    // MARK: - Units Section

    private var unitsSection: some View {
        Section("Elevation Units") {
            Picker("Display Units", selection: $model.elevationUnit) {
                ForEach(ElevationUnit.allCases, id: \.self) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        Section("GIS & Field Export") {
            Button {
                Task {
                    await performExport()
                }
            } label: {
                HStack {
                    Label("Export Georeferenced Map", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.primary)
                    Spacer()
                    if isExporting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isExporting)

            if let exportError {
                Text(exportError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text("Exports a high-resolution PNG with an ESRI World File (.pgw) and GeoJSON spatial boundary for QGIS, ArcGIS, and CAD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func performExport() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let service = GeoreferencedExportService()
            let result = try await service.export(
                region: model.visibleRegion,
                style: model.style,
                elevationUnit: model.elevationUnit,
                resolutionMeters: model.currentResolution
            )
            exportItems = result.allURLs
            showsShareSheet = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Detail Section

    private func detailSection(_ resolution: Double) -> some View {
        Section("Ground Resolution") {
            HStack {
                Text("Native Detail")
                Spacer()
                Text(String(format: "%.1f m/px", resolution))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section("Local Storage & Offline Cache") {
            HStack {
                Text("Cached Tiles")
                Spacer()
                Text(model.diskCacheSizeFormatted)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Text("Served From Cache")
                Spacer()
                Text(model.diskCacheHitRateFormatted)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(role: .destructive) {
                Task {
                    await model.clearDiskCache()
                }
            } label: {
                Label("Clear Tile Cache", systemImage: "trash")
            }
        }
    }

    // MARK: - Upgrades Section

    private var upgradesSection: some View {
        Section("Upgrades") {
            if store.hasRemoveAds {
                Label("Ads Removed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                if let product = store.removeAdsProduct {
                    Button {
                        Task {
                            await store.purchase()
                            await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remove Ads")
                                    .foregroundStyle(.primary)
                                Text("One-time purchase")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(store.isPurchasing)
                } else if store.isPurchasing {
                    HStack {
                        Text("Processing purchase…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }

                Button("Restore Purchases") {
                    Task {
                        await store.restore()
                        await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                    }
                }
                .disabled(store.isRestoring)

                if let error = store.lastErrorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                dismiss()
                showsDebug = true
            } label: {
                Label("Tile Activity Logs", systemImage: "ladybug")
            }
        }
    }

    // MARK: - Attributions Section

    private var attributionsSection: some View {
        Section {
            Text("Elevation: USGS 3DEP & AWS Terrain Tiles · Basemaps: USGS")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
