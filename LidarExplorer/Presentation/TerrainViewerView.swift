//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The primary terrain viewer screen: unobstructed map with floating top bar and bottom dock.
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
    @State private var showsSettings = false
    @State private var showsDebug = false

    /// Persisted so the primer appears automatically on first launch only.
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {}

    public var body: some View {
        // Reading each reactive model value here makes SwiftUI re-invoke
        // TerrainMapView.updateUIView when it changes.
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
        .safeAreaInset(edge: .top) {
            ViewerTopBarView(
                model: model,
                showsPrimer: $showsPrimer,
                showsSettings: $showsSettings
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            VStack(spacing: 6) {
                if let profile = model.activeProfile {
                    ElevationProfileView(model: model, profile: profile)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ViewerBottomDockView(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.activeProfile != nil)
        }
        .sheet(isPresented: $showsPrimer, onDismiss: {
            Task { await ads.prepare(hasRemoveAds: store.hasRemoveAds) }
        }) {
            VisualPrimerView()
        }
        .sheet(isPresented: $showsSettings) {
            ViewerSettingsSheetView(
                model: model,
                store: store,
                ads: ads,
                showsDebug: $showsDebug
            )
        }
        .sheet(isPresented: $showsDebug) {
            TileDebugView(log: model.tileLog)
        }
        .sheet(isPresented: $model.showsLandmarks) {
            LandmarkCatalogView(model: model)
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
}
