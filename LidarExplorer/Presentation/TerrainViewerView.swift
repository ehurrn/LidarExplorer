//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The primary terrain viewer screen.
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
        TerrainMapView(model: model)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                ViewerTopBarView(
                    model: model,
                    showsPrimer: $showsPrimer,
                    showsSettings: $showsSettings
                )
            }
            .overlay(alignment: .bottom) {
                ViewerBottomDockView(model: model)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)
            }
            .sheet(isPresented: $showsPrimer, onDismiss: {
                Task {
                    await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                }
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
