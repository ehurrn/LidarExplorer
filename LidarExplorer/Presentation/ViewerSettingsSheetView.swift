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
    let store: StoreService
    let ads: AdService
    @Environment(\.dismiss) private var dismiss

    public init(
        model: TerrainViewerModel,
        store: StoreService,
        ads: AdService
    ) {
        self.model = model
        self.store = store
        self.ads = ads
    }

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                basemapSection
                unitsSection
                monetizationSection
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
        Section("Terrain Fine-Tuning") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sun Altitude")
                    Spacer()
                    Text(String(format: "%.0f°", model.altitude))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.altitude, in: 5...85, step: 1)
            }
        }
    }

    // MARK: - Basemap Section

    private var basemapSection: some View {
        Section("Basemap Layer") {
            Picker("Style", selection: $model.basemap) {
                ForEach(TerrainBasemap.allCases) { basemap in
                    Text(basemap.displayName).tag(basemap)
                }
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

    // MARK: - Monetization Section

    private var monetizationSection: some View {
        Section("Upgrades") {
            if store.hasRemoveAds {
                Label("Ads Removed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task {
                        if await store.purchase() {
                            await ads.prepare(hasRemoveAds: true)
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Remove Ads")
                                .font(.body.weight(.medium))
                            Text("One-time purchase")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.isPurchasing {
                            ProgressView().controlSize(.mini)
                        } else if let price = store.removeAdsProduct?.displayPrice {
                            Text(price)
                                .fontWeight(.semibold)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .disabled(store.isPurchasing || !store.isProductAvailable)

                Button("Restore Purchases") {
                    Task {
                        await store.restore()
                        await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                    }
                }
                .font(.footnote)
                .disabled(store.isRestoring)

                if let error = store.lastErrorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                TileDebugView(log: model.tileLog)
            } label: {
                Label("Tile Activity Logs", systemImage: "ladybug")
            }
        }
    }

    // MARK: - Attributions Section

    private var attributionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elevation Data: USGS 3DEP & AWS Terrain Tiles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Basemaps: The National Map, USGS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
