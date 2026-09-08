//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The primary terrain viewer screen: map plus a floating control box.
//

import CoreLocation
import MapKit
import StoreKit
import SwiftUI

public struct TerrainViewerView: View {

    @State private var model = TerrainViewerModel()
    @State private var store = StoreService()
    @State private var ads = AdService()
    @State private var showsPrimer = false
    @State private var showsDebug = false
    @State private var showsPanel = true

    /// Persisted so the primer appears automatically on first launch only.
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {}

    public var body: some View {
        // Reading each reactive model value here is what makes SwiftUI
        // re-invoke TerrainMapView.updateUIView when it changes.
        TerrainMapView(
            model: model,
            basemap: model.basemap,
            showsTerrain: model.showsTerrain,
            basemapOpacity: model.basemapOpacity,
            terrainOpacity: model.terrainOpacity,
            reloadToken: model.terrainVersion,
            locationAuthorization: model.locationAuthorization,
            pendingRecenter: model.pendingRecenter
        )
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { panelToggle }
        .overlay(alignment: .topTrailing) {
            if showsPanel {
                TerrainControlPanelView(
                    model: model,
                    store: store,
                    ads: ads,
                    showsPrimer: $showsPrimer,
                    showsDebug: $showsDebug
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            ElevationReadoutCapsule(model: model)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)
        }
        .animation(.snappy, value: showsPanel)
        .sheet(isPresented: $showsPrimer, onDismiss: {
            Task { await ads.prepare(hasRemoveAds: store.hasRemoveAds) }
        }) {
            VisualPrimerView()
        }
        .sheet(isPresented: $showsDebug) {
            TileDebugView(log: model.tileLog)
        }
        .onChange(of: store.hasRemoveAds) { _, hasRemove in
            Task { await ads.prepare(hasRemoveAds: hasRemove) }
        }
        .task {
            model.start()
            await store.refresh()
            if !hasSeenIntro {
                hasSeenIntro = true
                showsPrimer = true
            } else {
                await ads.prepare(hasRemoveAds: store.hasRemoveAds)
            }
        }
    }

    // MARK: - Panel toggle

    private var panelToggle: some View {
        Button {
            showsPanel.toggle()
        } label: {
            Image(systemName: showsPanel ? "sidebar.trailing" : "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .padding()
    }
}

// MARK: - Control Panel

private struct TerrainControlPanelView: View {
    @Bindable var model: TerrainViewerModel
    var store: StoreService
    var ads: AdService
    @Binding var showsPrimer: Bool
    @Binding var showsDebug: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                basemapSection
                Divider()
                terrainSection
                Divider()
                unitsSection
                actionsSection
                if let resolution = model.currentResolution {
                    detailRow(resolution)
                }
                Divider()
                supportSection
                attribution
            }
            .padding(16)
        }
        .frame(width: 300)
        .frame(maxHeight: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding()
    }

    private var header: some View {
        HStack {
            Text("Terrain")
                .font(.headline)
            Spacer()
            Button {
                showsPrimer = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .accessibilityLabel("How to read the terrain")

            Button {
                showsDebug = true
            } label: {
                Image(systemName: "ladybug")
            }
            .accessibilityLabel("Tile activity")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Basemap

    private var basemapSection: some View {
        section("Basemap") {
            Picker("Basemap", selection: $model.basemap) {
                ForEach(TerrainBasemap.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            labelledSlider("Opacity", value: $model.basemapOpacity, in: 0...1)
        }
    }

    // MARK: - Terrain

    private var terrainSection: some View {
        section("Terrain layer") {
            Toggle("Show terrain", isOn: $model.showsTerrain)
                .font(.subheadline)

            if model.showsTerrain {
                Picker("Style", selection: $model.style) {
                    ForEach(ReliefStyle.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)

                if model.style.usesIllumination {
                    labelledSlider("Azimuth", value: $model.azimuth, in: 0...359, format: "%.0f°")
                    labelledSlider("Sun angle", value: $model.altitude, in: 5...85, format: "%.0f°")
                }

                labelledSlider("Opacity", value: $model.terrainOpacity, in: 0...1)

                Button {
                    model.resetShading()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.hasCustomShading)
            }
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        section("Elevation units") {
            Picker("Units", selection: $model.elevationUnit) {
                ForEach(ElevationUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Button {
            Task { await model.goToUserLocation() }
        } label: {
            Label("My location", systemImage: "location.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(model.locationAuthorization == .denied)
    }

    private func detailRow(_ resolution: Double) -> some View {
        HStack {
            Text("Detail").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f m/px", resolution))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Support

    @ViewBuilder
    private var supportSection: some View {
        if store.hasRemoveAds {
            Label("Ads removed — thank you", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            section("Support") {
                Button {
                    Task {
                        if await store.purchase() {
                            await ads.prepare(hasRemoveAds: true)
                        }
                    }
                } label: {
                    HStack {
                        Label("Remove ads", systemImage: "nosign")
                        Spacer()
                        if store.isPurchasing {
                            ProgressView().controlSize(.mini)
                        } else if let price = store.removeAdsProduct?.displayPrice {
                            Text(price).font(.caption.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isPurchasing || !store.isProductAvailable)

                Button("Restore purchases") {
                    Task {
                        await store.restore()
                        await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                    }
                }
                .font(.caption)
                .disabled(store.isRestoring)

                if let error = store.lastErrorMessage {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var attribution: some View {
        Text("Elevation: USGS 3DEP & AWS Terrain Tiles · Basemaps: USGS")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String = "%.0f%%"
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format,
                            format.hasSuffix("%%") ? value.wrappedValue * 100 : value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Elevation Readout

private struct ElevationReadoutCapsule: View {
    var model: TerrainViewerModel

    var body: some View {
        if let text = readoutText {
            HStack(spacing: 8) {
                if case .loading = model.inspectionState {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "mountain.2.fill").font(.caption2).foregroundStyle(.tint)
                }
                Text(text).font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding()
        }
    }

    private var readoutText: String? {
        switch model.inspectionState {
        case .idle: nil
        case .loading: "Reading ground…"
        case .elevation(let e, _): model.formattedElevation(e)
        case .noCoverage: "No coverage here"
        case .failed: "Elevation unavailable"
        }
    }
}

private extension ReliefStyle {
    /// Short label that fits a 4-way segmented control at panel width.
    var shortLabel: String {
        switch self {
        case .hillshade: "Hill"
        case .multiDirectional: "Multi"
        case .slope: "Slope"
        case .elevation: "Elev"
        }
    }
}
