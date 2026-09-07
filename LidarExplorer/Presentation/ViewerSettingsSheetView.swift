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
                    Text(String(format: "%.0f°", model.sunAngle))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.sunAngle, in: 5...85, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Vertical Exaggeration")
                    Spacer()
                    Text(String(format: "%.1f×", model.verticalExaggeration))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.verticalExaggeration, in: 1...5, step: 0.5)
            }
        }
    }

    // MARK: - Basemap Section

    private var basemapSection: some View {
        Section("Basemap Layer") {
            Picker("Style", selection: $model.selectedBasemap) {
                ForEach(BasemapType.allCases, id: \.self) { basemap in
                    Text(basemap.rawValue).tag(basemap)
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
                        await store.purchaseRemoveAds()
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
                        if let price = store.removeAdsPrice {
                            Text(price)
                                .fontWeight(.semibold)
                        } else {
                            ProgressView()
                        }
                    }
                }

                Button("Restore Purchases") {
                    Task {
                        await store.restorePurchases()
                    }
                }
                .font(.footnote)
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

// MARK: - Supporting Types

public enum BasemapType: String, CaseIterable, Sendable {
    case topo = "USGS Topo"
    case imagery = "USGS Imagery"
    case imageryTopo = "USGS Imagery + Topo"
}

public enum ElevationUnit: String, CaseIterable, Sendable {
    case feet
    case meters

    public var title: String {
        switch self {
        case .feet: return "Feet (ft)"
        case .meters: return "Meters (m)"
        }
    }
}

// MARK: - Compatibility Extensions

@MainActor
private var _verticalExaggerationStore: [ObjectIdentifier: Double] = [:]

@MainActor
private var _selectedBasemapStore: [ObjectIdentifier: BasemapType] = [:]

@MainActor
private var _elevationUnitStore: [ObjectIdentifier: ElevationUnit] = [:]

extension TerrainViewerModel {
    public var sunAngle: Double {
        get { altitude }
        set { altitude = newValue }
    }

    public var verticalExaggeration: Double {
        get {
            access(keyPath: \.verticalExaggeration)
            return _verticalExaggerationStore[ObjectIdentifier(self)] ?? 1.0
        }
        set {
            withMutation(keyPath: \.verticalExaggeration) {
                _verticalExaggerationStore[ObjectIdentifier(self)] = newValue
            }
        }
    }

    public var selectedBasemap: BasemapType {
        get {
            access(keyPath: \.selectedBasemap)
            return _selectedBasemapStore[ObjectIdentifier(self)] ?? .topo
        }
        set {
            withMutation(keyPath: \.selectedBasemap) {
                _selectedBasemapStore[ObjectIdentifier(self)] = newValue
            }
        }
    }

    public var elevationUnit: ElevationUnit {
        get {
            access(keyPath: \.elevationUnit)
            return _elevationUnitStore[ObjectIdentifier(self)] ?? .feet
        }
        set {
            withMutation(keyPath: \.elevationUnit) {
                _elevationUnitStore[ObjectIdentifier(self)] = newValue
            }
        }
    }
}

extension StoreService {
    public var removeAdsPrice: String? {
        removeAdsProduct?.displayPrice
    }

    public func purchaseRemoveAds() async {
        _ = await purchase()
    }

    public func restorePurchases() async {
        await restore()
    }
}
