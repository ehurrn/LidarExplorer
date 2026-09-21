//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The primary terrain viewer screen: unobstructed map with floating top bar and bottom dock.
//

import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

public struct TerrainViewerView: View {

    @State private var model = TerrainViewerModel(fieldNotebookStore: .standard())
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPrimer = false
    @State private var showsStyleReference = false
    @State private var showsSettings = false
    @State private var showsDebug = false
    @State private var showsHistoricalImporter = false
    @State private var showsSoilImporter = false

    /// Persisted so the primer appears automatically on first launch only.
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPEN_STYLE_REF"] == "1" {
            _showsStyleReference = State(initialValue: true)
        }
        #endif
    }

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
                soilVersion: model.soilVersion,
                markupVersion: model.markupVersion
            )
            .ignoresSafeArea()

            #if canImport(PencilKit)
            // The drawing layer. In the hand tool it is removed, so the map takes every touch.
            if model.isMarkingUp && model.markupTool != .hand {
                PencilMarkupCanvas(model: model)
                    .ignoresSafeArea()
            }
            #endif

            if let fraction = model.historicalWipeFraction {
                GeometryReader { proxy in
                    let isVertical = model.historicalWipeOrientation == .vertical
                    let x = isVertical ? fraction * proxy.size.width : proxy.size.width / 2
                    let y = isVertical ? proxy.size.height / 2 : fraction * proxy.size.height

                    ZStack {
                        Path { path in
                            if isVertical {
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                            } else {
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }
                        }
                        .stroke(Color.white, lineWidth: 2)
                        .shadow(color: .black.opacity(0.5), radius: 3)

                        // Draggable interactive handle with tactile feedback
                        HStack(spacing: 4) {
                            Image(systemName: isVertical ? "arrow.left.and.right" : "arrow.up.and.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .position(x: x, y: y)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let oldFraction = model.historicalWipeFraction ?? 0.5
                                    let newFraction: Double
                                    if isVertical {
                                        newFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                                    } else {
                                        newFraction = min(max(value.location.y / proxy.size.height, 0), 1)
                                    }
                                    if (oldFraction < 0.5 && newFraction >= 0.5) || (oldFraction > 0.5 && newFraction <= 0.5) {
                                        #if canImport(UIKit)
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        #endif
                                    } else if abs(newFraction - oldFraction) > 0.02 {
                                        #if canImport(UIKit)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
                                        #endif
                                    }
                                    model.historicalWipeFraction = newFraction
                                }
                        )
                        .onTapGesture(count: 2) {
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            #endif
                            model.historicalWipeOrientation = isVertical ? .horizontal : .vertical
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .top) {
            ViewerTopBarView(
                model: model,
                showsStyleReference: $showsStyleReference,
                showsSettings: $showsSettings
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            VStack(spacing: 6) {
                if model.isMarkingUp {
                    FieldMarkupToolbarView(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.activeProfile != nil)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.activeSpot != nil)
        }
        // Attached outside both safe-area insets, so the top bar and dock
        // narrow with the map when the panel opens beside it.
        .inspector(isPresented: $showsStyleReference) {
            MapStylesReferenceView(model: model, isPresented: $showsStyleReference)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                .presentationDetents([.medium, .large])
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
        .sheet(isPresented: $showsPrimer) {
            VisualPrimerView()
        }
        .sheet(isPresented: $showsSettings) {
            ViewerSettingsSheetView(
                model: model,
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
        .fullScreenCover(item: $model.terrain3DScene) { scene in
            #if canImport(SceneKit)
            Terrain3DOrbitView(scene: scene)
            #endif
        }
        .alert("3D View", isPresented: Binding(
            get: { model.inspectorMessage != nil },
            set: { if !$0 { model.inspectorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.inspectorMessage ?? "")
        }
        .sheet(isPresented: $model.showsExportSheet) {
            if let url = model.exportURL {
                ActivityView(activityItems: [url])
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { model.exportErrorMessage != nil },
            set: { if !$0 { model.exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.exportErrorMessage ?? "")
        }
        .alert("Field Notes", isPresented: Binding(
            get: { model.markupNotice != nil },
            set: { if !$0 { model.markupNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.markupNotice ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A notebook that could not be read at launch (an iPad still locked since it restarted) is tried again.
                Task { await model.restoreFieldMarkup() }
            case .inactive, .background:
                // The app may be suspended within moments, and a notebook still waiting for its write would be lost
                // if it were then terminated.
                #if canImport(UIKit)
                BackgroundWork.run("Save field notes") { await model.flushFieldMarkup() }
                #else
                Task { await model.flushFieldMarkup() }
                #endif
            @unknown default:
                break
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TEST_VIEWSHED_READOUT"] == "1" {
                model.interactionMode = .viewshed
                model.viewshedObserverCoordinate = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)
            }
            if let style = ProcessInfo.processInfo.environment["TEST_INITIAL_STYLE"],
               let s = ReliefStyle.allCases.first(where: { $0.dockLabel == style || $0.displayName == style }) {
                model.style = s
            }
            if ProcessInfo.processInfo.environment["TEST_TOGGLE_PANEL"] == "1" {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showsStyleReference = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showsStyleReference = false
                }
            }
            #endif
            #if DEBUG
            // Drives the import a Simulator run cannot reach through the document picker.
            if let path = ProcessInfo.processInfo.environment["IMPORT_LOCAL_TIFF"] {
                Task { await model.importLocalElevation(from: URL(fileURLWithPath: path)) }
            }
            #endif
            model.start()
            if !hasSeenIntro {
                hasSeenIntro = true
                showsPrimer = true
            }
        }
    }
}
