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
    @State private var exportError: String?
    /// What the GeoTIFF this sheet just exported leaves out (``TerrainViewerModel/exportNotice``), said in the export
    /// section beside the button that made it until the next export: the viewer's pill for it sits behind this sheet, and
    /// on a phone this sheet covers it.
    @State private var exportCoverageNotice: String?
    /// The export under way, cancelled when this sheet closes: it outlives the sheet, and finishing after it had gone it
    /// raised the model's share-sheet flag with no sheet left to present or lower it, which held the viewer's coverage
    /// pill up for good and opened a blank sheet over the next Settings.
    @State private var exportTask: Task<Void, Never>?
    @State private var showsElevationImporter = false
    @State private var showsRemoveDownloadsConfirmation = false
    @State private var showsRemoveDownloadsRefusal = false

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                viewshedSection
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
            // On the model, so the viewer's pill for a part-covered file stays up beside it as it does beside the viewer's
            // own share sheet. Closed, the notice is said in the export section, and the pill goes.
            .sheet(isPresented: $model.showsSettingsShareSheet, onDismiss: {
                if let exportCoverageNotice { model.dismissExportNotice(exportCoverageNotice) }
            }) {
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
        // On the stack, not the form, which also disappears under a pushed page. Closed mid-export, the file is not
        // shared, and the model's flag goes down with the sheet that presents it. A share sheet asked for as this sheet
        // closed never shows either, so its file's notice goes too.
        .onDisappear {
            exportTask?.cancel()
            if model.showsSettingsShareSheet, let exportCoverageNotice { model.dismissExportNotice(exportCoverageNotice) }
            model.showsSettingsShareSheet = false
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

                // Each product's controls are offered while that product is drawn: as the style, as the layer draped
                // over it, or as sky-view shading (`drawnProducts`).
                if model.tunes(.localRelief) {
                    tuning("Smoothing Radius", model.formattedLength(Double(model.microTopographyOptions.lrmRadiusMeters)),
                           $model.microTopographyOptions.lrmRadiusMeters, in: 5...50, step: 1)
                }
                // The contrast scale normalises Local Relief's residual and the difference of Gaussians' alike.
                if model.tunes(.localRelief) || model.tunes(.differenceOfGaussians) {
                    tuning("Contrast Scale", "±" + model.formattedLength(Double(model.microTopographyOptions.lrmScaleMeters), decimals: 1),
                           $model.microTopographyOptions.lrmScaleMeters, in: 0.5...5.0, step: 0.5)
                }

                if model.tunes(.skyView) {
                    tuning("Sky-View Radius", model.formattedLength(Double(model.microTopographyOptions.svfRadiusMeters)),
                           $model.microTopographyOptions.svfRadiusMeters, in: 5...30, step: 1)
                }

                if model.tunes(.rakingLight) {
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

                if model.tunes(.curvature) {
                    // The kernel computes both curvatures; this picks the one drawn and exported.
                    Picker("Curvature", selection: $model.microTopographyOptions.curvatureChannel) {
                        ForEach(CurvatureChannel.allCases) { channel in Text(channel.displayName).tag(channel) }
                    }
                    .pickerStyle(.segmented)
                    Text("Profile bends along the slope (crests and toes); Planform bends across it (gullies, channel heads, enclosure rings); Mean averages the two.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if model.tunesOpennessRadius {
                    tuning("Openness Radius", model.formattedLength(Double(model.microTopographyOptions.opennessRadiusMeters)),
                           $model.microTopographyOptions.opennessRadiusMeters, in: 5...40, step: 1)
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
                if model.grazingSunAltitudeMatters {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Grazing Sun Altitude")
                            Spacer()
                            Text(String(format: "%.0f°", model.rakingAltitude)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.rakingAltitude, in: 5...15, step: 1)
                    }
                }
                if model.tunes(.relativeElevation) {
                    tuning("Band Width", model.formattedLength(Double(model.microTopographyOptions.remBandMeters), decimals: 2),
                           $model.microTopographyOptions.remBandMeters, in: 0...1, step: 0.25)
                    Button("Draw River Thalweg") {
                        model.beginThalwegDrawing()
                        dismiss()
                    }
                    Button("Clear Thalweg", role: .destructive) {
                        model.thalweg = []
                    }
                    .disabled(model.thalweg.isEmpty)
                }

                if !model.drawnProducts.isEmpty {
                    advancedTuning
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

    /// A labelled slider with its value shown in the display unit.
    private func tuning<V: BinaryFloatingPoint>(
        _ label: String, _ value: String, _ binding: Binding<V>, in range: ClosedRange<V>, step: V.Stride
    ) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    /// The engine's finer parameters for the products drawn, folded away: the robust trend of Local Relief, the
    /// macro horizon of sky view, the two scales of the difference of Gaussians, the occlusion distance, the
    /// ruggedness ceiling, the habitation mask's radius.
    private var advancedTuning: some View {
        DisclosureGroup("Advanced") {
            if model.tunes(.localRelief) {
                Toggle("Robust Trend (Tukey)", isOn: $model.microTopographyOptions.lrmRobustTukey)
                if model.microTopographyOptions.lrmRobustTukey {
                    tuning("Outlier Cutoff", model.formattedLength(Double(model.microTopographyOptions.lrmTukeyCutoffMeters), decimals: 1),
                           $model.microTopographyOptions.lrmTukeyCutoffMeters, in: 0.5...5, step: 0.5)
                }
            }
            if model.tunes(.skyView) {
                tuning("Macro Horizon Radius", model.formattedLength(Double(model.microTopographyOptions.svfMacroRadiusMeters)),
                       $model.microTopographyOptions.svfMacroRadiusMeters, in: 30...120, step: 5)
                tuning("Micro Horizon Weight", String(format: "%.0f%%", model.microTopographyOptions.svfBlendWeight * 100),
                       $model.microTopographyOptions.svfBlendWeight, in: 0...1, step: 0.05)
                Picker("Horizon Rays", selection: $model.microTopographyOptions.svfAzimuthRays) {
                    ForEach([8, 16, 32], id: \.self) { rays in Text("\(rays)").tag(rays) }
                }
                .pickerStyle(.segmented)
            }
            if model.tunes(.differenceOfGaussians) {
                tuning("Fine Scale", model.formattedLength(Double(model.microTopographyOptions.dogSigma1Meters), decimals: 1),
                       $model.microTopographyOptions.dogSigma1Meters, in: 0.5...5, step: 0.5)
                tuning("Coarse Scale", model.formattedLength(Double(model.microTopographyOptions.dogSigma2Meters)),
                       $model.microTopographyOptions.dogSigma2Meters, in: 5...30, step: 1)
            }
            if model.tunes(.directionalOcclusion) {
                tuning("Occlusion Distance", model.formattedLength(Double(model.microTopographyOptions.directionalOcclusionDistanceMeters)),
                       $model.microTopographyOptions.directionalOcclusionDistanceMeters, in: 20...120, step: 5)
            }
            if model.tunes(.vectorRuggedness) {
                tuning("Ruggedness Ceiling", String(format: "%.3f", model.microTopographyOptions.vrmMaxDisplay),
                       $model.microTopographyOptions.vrmMaxDisplay, in: 0.005...0.05, step: 0.005)
            }
            if model.tunes(.habitation) || model.showsHabitationMask {
                tuning("Habitation Radius", model.formattedLength(Double(model.microTopographyOptions.habitationRadiusMeters)),
                       $model.microTopographyOptions.habitationRadiusMeters, in: 10...60, step: 5)
            }
        }
    }

    // MARK: - Viewshed Section

    /// The viewshed's parameters, which only the engine had: a change with an observer placed recomputes it.
    private var viewshedSection: some View {
        Section("Viewshed") {
            tuning("Observer Eye Height", model.formattedLength(Double(model.viewshedObserverEyeHeight), decimals: 1),
                   $model.viewshedObserverEyeHeight, in: 0.5...30, step: 0.5)
            tuning("Target Height", model.formattedLength(Double(model.viewshedTargetHeight), decimals: 1),
                   $model.viewshedTargetHeight, in: 0...10, step: 0.5)
            tuning("Radius", model.formattedDistance(Double(model.viewshedRadiusMeters)),
                   $model.viewshedRadiusMeters, in: 250...10_000, step: 250)
            Text(model.viewshedObserverCoordinate == nil
                 ? "Applied when an observer is placed with the Viewshed tool."
                 : "The placed viewshed is computed again as these change.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                model.resetViewshedParameters()
            } label: {
                Label("Reset Viewshed Defaults", systemImage: "arrow.counterclockwise")
            }
            .disabled(!model.hasCustomViewshed)
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
                    set: { on in model.setSplitWipe(on) }
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

            if let message = model.historicalMapImportMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
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

            if let message = model.soilImportMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if model.importedSoilSurvey != nil {
                Text("Showing the imported soils wherever the map goes; switch Show Soil Hatching off to return to USDA's.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        Text("\(file.width) × \(file.height) samples, about \(model.formattedDistance(file.footprint.widthMeters)) × \(model.formattedDistance(file.footprint.heightMeters))")
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
                    exportTask = Task {
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
            } else if let exportCoverageNotice {
                Label(exportCoverageNotice, systemImage: "square.dashed")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                Text(model.exportFormat == .geoTIFF
                    ? "Exports a native single-band 32-bit floating point GeoTIFF carrying EPSG:3857 georeferencing for GIS analysis."
                    : "Exports the map with its terrain shading as a high-resolution PNG, with an ESRI World File (.pgw) in Web Mercator and a GeoJSON footprint in WGS 84.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func geoTIFFExportButton(_ content: GeoTIFFContent, title: String, systemImage: String) -> some View {
        Button {
            exportTask = Task {
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
        exportCoverageNotice = nil
        defer { isExportingGeoTIFF = false }
        do {
            let url = try await model.exportCurrentGeoTIFF(content)
            // This sheet closed while the file was made: nothing will share it, so nothing says what it leaves out.
            guard !Task.isCancelled else {
                if let notice = model.exportNotice { model.dismissExportNotice(notice) }
                return
            }
            exportCoverageNotice = model.exportNotice
            exportItems = [url]
            model.showsSettingsShareSheet = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func performExport() async {
        isExporting = true
        exportError = nil
        exportCoverageNotice = nil
        // A GeoTIFF's pill still up from the viewer's export would otherwise be held beside this map's share sheet, as
        // though it spoke of it.
        if let notice = model.exportNotice { model.dismissExportNotice(notice) }
        defer { isExporting = false }
        do {
            // The view as it stands now, and how much of it the terrain shading covers.
            let coverage = await model.noteGeoreferencedExportCoverage()
            let service = GeoreferencedExportService()
            let result = try await service.export(
                region: model.visibleRegion,
                style: model.style,
                elevationUnit: model.elevationUnit,
                resolutionMeters: model.currentResolution,
                terrain: model.terrainProvider,
                terrainOpacity: model.terrainOpacity,
                terrainCoverage: coverage.share,
                basemap: model.basemap,
                basemapOpacity: model.basemapOpacity
            )
            // This sheet closed while the files were made: nothing will share them, so nothing says what they lack.
            guard !Task.isCancelled else {
                if let notice = model.exportNotice { model.dismissExportNotice(notice) }
                return
            }
            exportCoverageNotice = coverage.notice
            exportItems = result.allURLs
            model.showsSettingsShareSheet = true
        } catch {
            if let notice = model.exportNotice { model.dismissExportNotice(notice) }
            exportError = error.localizedDescription
        }
    }

    // MARK: - Detail Section

    private func detailSection(_ resolution: Double) -> some View {
        Section("Ground Resolution") {
            HStack {
                Text("Native Detail")
                Spacer()
                Text(model.formattedResolution(resolution))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section {
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

            HStack {
                Text("Other Caches")
                Spacer()
                Text(model.otherCachesSizeFormatted)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Raw 3DEP rasters, basemap tiles and soil surveys, cleared with the tile cache.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Text("Offline Downloads")
                Spacer()
                Text(model.offlineDownloadsSizeFormatted)
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
                Label("Clear Caches", systemImage: "trash")
            }

            Button(role: .destructive) {
                showsRemoveDownloadsConfirmation = true
            } label: {
                Label("Remove Offline Downloads", systemImage: "trash")
            }
            .disabled(!model.hasOfflineDownloads || model.isDownloadingOffline || model.isRemovingOfflineDownloads)
            .confirmationDialog(
                "Remove all offline downloads?", isPresented: $showsRemoveDownloadsConfirmation, titleVisibility: .visible
            ) {
                Button("Remove Offline Downloads", role: .destructive) {
                    Task {
                        if await model.removeOfflineDownloads() == false { showsRemoveDownloadsRefusal = true }
                    }
                }
            } message: {
                Text("The terrain and basemap tiles you downloaded are deleted from this device, and the map goes back to loading them over the network.")
            }
            .alert("Stop the download first", isPresented: $showsRemoveDownloadsRefusal) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Offline downloads cannot be removed while one is running.")
            }
        } header: {
            Text("Local Storage & Offline Cache")
        } footer: {
            Text("Cached tiles are what the map has looked at lately: they are trimmed as you browse, and clearing them is safe. "
                 + "Offline downloads stay until you remove them, and clearing the tile cache leaves them.")
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
