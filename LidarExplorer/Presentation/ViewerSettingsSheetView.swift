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
    @Environment(\.dismiss) private var dismiss

    public init(
        model: TerrainViewerModel,
        store: StoreService,
        ads: AdService,
        showsDebug: Binding<Bool>
    ) {
        self.model = model
        self.store = store
        self.ads = ads
        self._showsDebug = showsDebug
    }

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                basemapSection
                unitsSection
                if let resolution = model.currentResolution {
                    detailSection(resolution)
                }
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
