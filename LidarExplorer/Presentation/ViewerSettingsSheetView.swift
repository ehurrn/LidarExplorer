//
//  ViewerSettingsSheetView.swift
//  LidarExplorer
//
//  Settings sheet for terrain adjustments, basemap styling, units, and diagnostics.
//

import SwiftUI
import UniformTypeIdentifiers

public struct ViewerSettingsSheetView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsDebug: Bool
    @Binding var showsHistoricalImporter: Bool
    @Binding var showsSoilImporter: Bool
    @Environment(\.dismiss) private var dismiss

    public init(
        model: TerrainViewerModel,
        showsDebug: Binding<Bool>,
        showsHistoricalImporter: Binding<Bool> = .constant(false),
        showsSoilImporter: Binding<Bool> = .constant(false)
    ) {
        self.model = model
        self._showsDebug = showsDebug
        self._showsHistoricalImporter = showsHistoricalImporter
        self._showsSoilImporter = showsSoilImporter
    }

    @State private var isExporting = false
    @State private var isExportingGeoTIFF = false
    @State private var exportItems: [Any]?
    @State private var showsShareSheet = false
    @State private var exportError: String?
    @State private var showsElevationImporter = false

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                basemapSection
                historicalSection
                soilsSection
                localElevationSection
                unitsSection
                exportSection
                if let resolution = model.currentResolution {
                    detailSection(resolution)
                }
                storageSection
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
            // On the sheet itself, which is what presents it, so the picker opens over the sheet without closing it and
            // a refusal is shown in the section beside the button.
            .fileImporter(isPresented: $showsElevationImporter, allowedContentTypes: [.tiff, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        await model.importLocalElevation(from: url)
                        // The map has flown to the file: close the sheet to show it. A refusal stays for the user to read.
                        if model.localElevationMessage == nil { dismiss() }
                    }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        model.localElevationMessage = "The file could not be opened: \(error.localizedDescription)."
                    }
                }
            }
        }
    }

    // MARK: - Terrain Section

    private var terrainSection: some View {
        Section("Terrain Layer") {
            Toggle("Show Terrain Layer", isOn: $model.showsTerrain)

            if model.showsTerrain {
                if model.style.usesSunAltitude {
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
                if model.canBlend {
                    // Bound to the layer in effect, not the one remembered: a layer that is the style itself is not
                    // among the choices, and a Picker whose selection has no tag shows nothing.
                    Picker("Blend Layer", selection: Binding(
                        get: { model.activeBlend?.product },
                        set: { model.blendLayer = $0 }
                    )) {
                        Text("None").tag(MicroTopographyProduct?.none)
                        ForEach(model.blendChoices) { product in
                            Text(product.displayName).tag(Optional(product))
                        }
                    }
                    if model.activeBlend != nil {
                        Picker("Blend Mode", selection: $model.blendMode) {
                            ForEach(RasterBlendMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Blend Strength")
                                Spacer()
                                Text(String(format: "%.0f%%", model.blendOpacity * 100))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $model.blendOpacity, in: 0...1)
                            Text("Drapes a second product over this one. Multiply darkens where the layer is dark, Soft Light is the gentlest, Overlay adds contrast, and Screen lightens.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.style.usesGrazingSunAltitude {
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
                ForEach(BasemapChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }

            // Hidden rather than disabled for Apple's basemap: opacity is
            // applied to a tile overlay renderer's alpha, and MapKit exposes no
            // equivalent for the base layer it draws itself, so the control
            // would move and change nothing at all.
            if model.basemap.supportsOpacity {
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

                if model.historicalWipeFraction != nil {
                    Picker("Wipe Orientation", selection: $model.historicalWipeOrientation) {
                        ForEach(TerrainViewerModel.WipeOrientation.allCases, id: \.self) { o in
                            Text(o.rawValue).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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

    // MARK: - Your Elevation Data Section

    private var localElevationSection: some View {
        Section {
            ForEach(model.localElevationFiles) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        Text("\(file.width) × \(file.height) samples, about \(Self.length(file.footprint.widthMeters)) × \(Self.length(file.footprint.heightMeters))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await model.removeLocalElevation(id: file.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(file.name)")
                }
            }

            Button {
                showsElevationImporter = true
            } label: {
                if model.isImportingLocalElevation {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading…")
                    }
                } else {
                    Label("Import GeoTIFF…", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(model.isImportingLocalElevation)

            if let message = model.localElevationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Your Elevation Data")
        } footer: {
            Text("A 32-bit floating-point GeoTIFF (uncompressed, up to 4096 px) in Web Mercator, UTM or latitude/longitude replaces the online elevation wherever it has data, and the map flies to it. Up to \(TerrainViewerModel.maxLocalElevationFiles) files are held in memory; they are gone when the app closes, so import them again next time.")
        }
    }

    private static func length(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
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
            Picker("Format", selection: $model.exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            if model.exportFormat == .geoTIFF {
                geoTIFFExportButton(
                    .elevation,
                    title: model.analyticalExportStyle == nil ? "Export 32-bit Float GeoTIFF" : "Export Elevation GeoTIFF",
                    systemImage: "doc.badge.gearshape.fill"
                )
                if let style = model.analyticalExportStyle {
                    geoTIFFExportButton(
                        .analytical(style), title: "Export \(style.displayName) GeoTIFF", systemImage: "chart.xyaxis.line"
                    )
                    Text("The product export writes the analysis values themselves, not the colour map.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.style == .relativeElevation {
                    Text("Relative Elevation needs a river thalweg, so only the elevation can be exported as a GeoTIFF.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
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
                .disabled(isExporting || isExportingGeoTIFF)
            }

            if let exportError {
                Text(exportError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text(model.exportFormat == .geoTIFF
                    ? "Exports a native single-band 32-bit floating point GeoTIFF carrying EPSG:3857 georeferencing for GIS analysis."
                    : "Exports a high-resolution PNG with ESRI World File (.pgw) and GeoJSON spatial boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func geoTIFFExportButton(_ content: GeoTIFFContent, title: String, systemImage: String) -> some View {
        Button {
            Task {
                await performGeoTIFFExport(content)
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                if isExportingGeoTIFF {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isExporting || isExportingGeoTIFF)
    }

    private func performGeoTIFFExport(_ content: GeoTIFFContent) async {
        isExportingGeoTIFF = true
        exportError = nil
        defer { isExportingGeoTIFF = false }
        do {
            let url = try await model.exportCurrentGeoTIFF(content)
            exportItems = [url]
            showsShareSheet = true
        } catch {
            exportError = error.localizedDescription
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

            NavigationLink {
                OfflineHarvestView(model: model, controller: model.offlineHarvest)
            } label: {
                Label("Download This Area for Offline Use", systemImage: "arrow.down.circle")
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
            Text("Elevation: USGS 3DEP & AWS Terrain Tiles · Basemaps: USGS & Apple")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
