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

    @State private var model = TerrainViewerModel(fieldNotebookStore: FieldNotebookStore.standard())
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPrimer = false
    @State private var showsStyleReference = false
    @State private var showsSettings = false
    @State private var showsDebug = false
    @State private var showsHistoricalImporter = false
    @State private var showsSoilImporter = false
    /// The top bar's height below the safe area's top, one row or two, measured so the map's compass sits under it.
    @State private var topBarHeight: CGFloat = 52
    /// The height of the notice pills stacked under the top bar, 0 with none up, measured so the Pencil ring keeps below.
    @State private var noticeStackHeight: CGFloat = 0

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
                dataReloadToken: model.terrainDataVersion,
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
                markupVersion: model.markupVersion,
                // 10 pt under the bar, as the compass sat under the old one-row bar.
                compassTopInset: topBarHeight + 10
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
                                    // Crossing the middle, or a jump of more than 2 %, under the finger or the
                                    // Pencil dragging (this layer fills the window, so its coordinates are nearly
                                    // the window's; converted all the same).
                                    #if canImport(UIKit)
                                    if let cue = HapticRouting.wipeCue(from: oldFraction, to: newFraction) {
                                        HapticFeedbackManager.shared.play(
                                            cue, at: HapticRouting.windowPoint(value.location, inViewAt: proxy.frame(in: .global)))
                                    }
                                    #endif
                                    model.historicalWipeFraction = newFraction
                                }
                        )
                        .onTapGesture(count: 2) {
                            #if canImport(UIKit)
                            HapticFeedbackManager.shared.play(
                                .wipeTurned, at: HapticRouting.windowPoint(CGPoint(x: x, y: y), inViewAt: proxy.frame(in: .global)))
                            #endif
                            model.historicalWipeOrientation = isVertical ? .horizontal : .vertical
                        }
                    }
                }
                .ignoresSafeArea()
            }

            // Pencil Pro barrel roll: a ring above the hover point echoes the sun it is steering. Placed inside the
            // safe area, which it reads to keep the ring clear of the top bar; it places the ring in a space that
            // ignores the safe area, as the map does, so the hover point lands under the pencil.
            PencilRollRingLayer(model: model, noticeStackHeight: noticeStackHeight)
        }
        // Attached before the safe-area insets, so the pill drops in just below the top bar.
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                ToolNoticeOverlay(model: model)
                ExportNoticeOverlay(model: model)
            }
            // A tool notice arriving or leaving moves an export pill below it with it, not in a jump.
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.toolNotice)
            // Changes only when a pill arrives or leaves, or its text wraps differently.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeStackHeight = $0 }
        }
        .safeAreaInset(edge: .top) {
            ViewerTopBarView(
                model: model,
                showsStyleReference: $showsStyleReference,
                showsSettings: $showsSettings
            )
            // Changes only when the bar takes or gives up its second row, or the text size changes.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
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
                    ShadingDockView(model: model)
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
            #if canImport(UIKit)
            // The Simulator has no Pencil: feed the model the hover samples the handler would, rolling the sun at the
            // map's centre across the NW detent (the sun trails each roll by a degree), then at the top-left corner,
            // then just under the top bar (the ring swings beside the tip), then post a notice. TEST_PENCIL_FEEDBACK_DELAY
            // sets the seconds before the first roll (6 by default), time to put an export's pill up first.
            if ProcessInfo.processInfo.environment["TEST_PENCIL_FEEDBACK"] == "1" {
                Task {
                    let delay = Double(ProcessInfo.processInfo.environment["TEST_PENCIL_FEEDBACK_DELAY"] ?? "") ?? 6
                    try? await Task.sleep(for: .seconds(delay))
                    let bounds = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.effectiveGeometry.coordinateSpace.bounds ?? .zero
                    for (roll, point) in [299.0, 310, 316, 323, 331].map({ ($0, CGPoint(x: bounds.midX, y: bounds.midY)) })
                        + [(339.0, CGPoint(x: 8, y: 20)), (347.0, CGPoint(x: bounds.midX + 100, y: 120))] {
                        model.handlePencilHover(rollRadians: roll * .pi / 180, at: point)
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    model.postToolNotice("Cross-Section Profile")
                }
            }
            #endif
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

/// What a GeoTIFF just shared leaves out (``TerrainViewerModel/exportNotice``): a file of part of the view is still
/// written, and this says so in a pill under the top bar, beside the share sheet rather than in it (on an iPad the sheet
/// draws its own card, and a header laid above it landed over the status bar). It stays while the share sheet is up, the
/// viewer's or the Settings sheet's own, and a few seconds after, takes no touches, and VoiceOver hears it once.
private struct ExportNoticeOverlay: View {

    let model: TerrainViewerModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The notice VoiceOver was told while its share sheet was up, so closing the sheet does not tell it again.
    @State private var announcedBesideSheet: String?

    /// Restarts the pill's clock when the notice changes or the share sheet opens or closes.
    private struct Clock: Equatable {
        let notice: String
        let isSheetUp: Bool
    }

    var body: some View {
        Group {
            if let notice = model.exportNotice {
                let isSheetUp = model.showsExportSheet || model.showsSettingsShareSheet
                Label(notice, systemImage: "square.dashed")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 560)
                    .glassPanel()
                    // Clear of the map's compass (44 pt, 16 pt in from the trailing edge, level with the pill), which a
                    // pill 16 pt in covered on a map under 592 pt wide: the 11-inch in portrait with the guide open, a phone.
                    .padding(.horizontal, 68)
                    .padding(.top, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: Clock(notice: notice, isSheetUp: isSheetUp)) {
                        if isSheetUp {
                            // The share sheet presents in the same update as the pill, and VoiceOver moving into it cuts
                            // off an announcement made then: this one waits until the sheet is up.
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return }
                            announce(notice)
                            announcedBesideSheet = notice
                            return
                        }
                        if announcedBesideSheet != notice { announce(notice) }
                        announcedBesideSheet = nil
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        model.dismissExportNotice(notice)
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.exportNotice)
    }

    /// Said over whatever VoiceOver is reading: behind the share sheet's modal, the pill is out of its reach.
    private func announce(_ notice: String) {
        var text = AttributedString(notice)
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}
