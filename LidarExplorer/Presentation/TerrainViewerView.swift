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
import UniformTypeIdentifiers

public struct TerrainViewerView: View {

    @State private var model = TerrainViewerModel()
    @State private var store = StoreService()
    @State private var ads = AdService()
    @State private var showsPrimer = false
    @State private var showsSettings = false
    @State private var showsDebug = false
    @State private var showsHistoricalImporter = false
    @State private var showsSoilImporter = false

    /// Persisted so the primer appears automatically on first launch only.
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {}

    public var body: some View {
        // Reading each reactive model value here makes SwiftUI re-invoke
        // TerrainMapView.updateUIView when it changes.
        ZStack {
            TerrainMapView(
                model: model,
                basemap: model.basemap,
                showsTerrain: model.showsTerrain,
                basemapOpacity: model.basemapOpacity,
                terrainOpacity: model.terrainOpacity,
                reloadToken: model.terrainVersion,
                locationAuthorization: model.locationAuthorization,
                pendingRecenter: model.pendingRecenter,
                pendingRegion: model.pendingRegion,
                activeSpot: model.activeSpot,
                viewshedVersion: model.viewshedVersion,
                historicalCount: model.historicalMaps.count,
                historicalOpacity: model.historicalOpacity,
                historicalWipeFraction: model.historicalWipeFraction,
                historicalAboveTerrain: model.historicalAboveTerrain,
                soilVersion: model.soilVersion
            )
            .ignoresSafeArea()

            if let fraction = model.historicalWipeFraction {
                GeometryReader { proxy in
                    let x = fraction * proxy.size.width
                    ZStack {
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                        .stroke(Color.white, lineWidth: 2)
                        .shadow(color: .black.opacity(0.4), radius: 2)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.black)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                            .position(x: x, y: proxy.size.height / 2)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                                        model.historicalWipeFraction = newFraction
                                    }
                            )
                    }
                }
                .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .top) {
            ViewerTopBarView(
                model: model,
                showsPrimer: $showsPrimer,
                showsSettings: $showsSettings
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            VStack(spacing: 6) {
                if let spot = model.activeSpot {
                    SpotInspectionCalloutView(spot: spot, model: model)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.activeSpot != nil)
        }
        .fileImporter(
            isPresented: $showsHistoricalImporter,
            allowedContentTypes: [.image, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importHistoricalMaps(from: urls)
            }
        }
        .fileImporter(
            isPresented: $showsSoilImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importSoilGeoJSON(from: url)
            }
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
                showsDebug: $showsDebug,
                showsHistoricalImporter: $showsHistoricalImporter,
                showsSoilImporter: $showsSoilImporter
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
