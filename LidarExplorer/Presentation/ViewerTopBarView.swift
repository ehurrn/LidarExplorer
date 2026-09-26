//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar: the telemetry capsule, location and 3D buttons, a cluster for the three interaction
//  modes (one accent, a sliding selection), and one menu for everything that is not moment-to-moment.
//

import CoreLocation
import SwiftUI

public struct ViewerTopBarView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

    @Namespace private var modeSelection

    public init(
        model: TerrainViewerModel,
        showsStyleReference: Binding<Bool>,
        showsSettings: Binding<Bool>
    ) {
        self.model = model
        self._showsStyleReference = showsStyleReference
        self._showsSettings = showsSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            elevationCapsule
            Spacer(minLength: 8)
            circularButton("My location", icon: "location.fill",
                           disabled: model.locationAuthorization == .denied) {
                Task { await model.goToUserLocation() }
            }
            terrain3DButton
            modeCluster
            utilitiesMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .opacity(model.isCameraGestureActive ? 0.35 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isCameraGestureActive)
    }

    // MARK: - Elevation Capsule

    private var elevationCapsule: some View {
        HStack(spacing: 8) {
            if model.isProfileModeActive {
                if model.isGeneratingProfile {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ruler.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            } else if model.interactionMode == .thalweg {
                Image(systemName: "water.waves")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            } else if model.interactionMode == .historicalWipe {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            } else if case .loading = model.inspectionState {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "mountain.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            Text(readoutText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .glassSurface(in: Capsule())
    }

    private var isPlaceholder: Bool {
        if model.interactionMode != .explore { return false }
        if case .idle = model.inspectionState { return true }
        return false
    }

    private var readoutText: String {
        switch model.interactionMode {
        case .thalweg:
            if model.thalwegDraft.isEmpty {
                return "Drag along channel"
            } else {
                return "Tracing thalweg…"
            }
        case .historicalWipe:
            return "Drag split wipe to compare"
        case .transect:
            if model.isGeneratingProfile {
                return "Calculating profile…"
            } else if model.profileStart == nil {
                return "Drag or tap Point A"
            } else if model.profileEnd == nil {
                return "Tap Point B on map"
            } else {
                return "Transect sampled"
            }
        case .viewshed:
            if model.isComputingViewshed {
                return "Computing viewshed…"
            } else if model.viewshedObserverCoordinate == nil {
                return "Tap map for observer"
            } else {
                return "Observer placed (drag pin to move)"
            }
        case .explore:
            switch model.inspectionState {
            case .idle:
                return "Tap map for elevation"
            case .loading:
                return "Reading ground…"
            case .elevation(let e, _):
                return model.formattedElevation(e)
            case .noCoverage:
                return "No coverage here"
            case .failed:
                return "Elevation unavailable"
            }
        }
    }

    // MARK: - Circular buttons

    private func circularButton(
        _ label: String, icon: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var terrain3DButton: some View {
        Button {
            Task { await model.openTerrain3D() }
        } label: {
            Group {
                if model.isPreparingTerrain3D {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .disabled(model.isPreparingTerrain3D)
        .accessibilityLabel("View in 3D")
    }

    // MARK: - Mode cluster

    private enum Mode { case profile, viewshed, markup }

    /// The segment that carries the sliding selection. The cluster's own buttons keep the three modes exclusive,
    /// but the model can still hold markup and an analysis mode at once (a pencil stroke on the map starts a
    /// transect while markup's hand tool is up), and two views must never both be the source for one
    /// matched-geometry id. So the analysis mode, the one the readout describes, carries the slide, and a markup
    /// segment that is on at the same time gets a plain fill of the same accent.
    private var slidingMode: Mode? {
        switch model.interactionMode {
        case .transect: .profile
        case .viewshed: .viewshed
        case .explore, .thalweg, .historicalWipe: model.isMarkingUp ? .markup : nil
        }
    }

    /// The three mutually exclusive interaction tools, one accent, the selection sliding between them.
    private var modeCluster: some View {
        HStack(spacing: 2) {
            modeSegment("Cross-Section Profile", mode: .profile,
                        icon: "ruler", selectedIcon: "ruler.fill",
                        selected: model.isProfileModeActive) {
                // Entering an analysis mode leaves markup, as entering markup leaves the analysis modes.
                if !model.isProfileModeActive { model.isMarkingUp = false }
                model.toggleProfileMode()
            }
            modeSegment("Viewshed Analysis", mode: .viewshed,
                        icon: "eye", selectedIcon: "eye.fill",
                        selected: model.interactionMode == .viewshed) {
                if model.interactionMode != .viewshed { model.isMarkingUp = false }
                model.toggleViewshedMode()
            }
            modeSegment("Field Markup", mode: .markup,
                        icon: "pencil.tip.crop.circle", selectedIcon: "pencil.tip.crop.circle.fill",
                        selected: model.isMarkingUp) {
                model.toggleFieldMarkup()
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
    }

    private func modeSegment(
        _ label: String, mode: Mode, icon: String, selectedIcon: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                action()
            }
        } label: {
            Image(systemName: selected ? selectedIcon : icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 44, height: 38)
                .background {
                    if selected {
                        if slidingMode == mode {
                            Capsule()
                                .fill(Color.accentColor.gradient)
                                .matchedGeometryEffect(id: "mode", in: modeSelection)
                        } else {
                            Capsule()
                                .fill(Color.accentColor.gradient)
                        }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Utilities menu

    private var utilitiesMenu: some View {
        Menu {
            Button {
                model.showsLandmarks = true
            } label: {
                Label("Explore LiDAR Sites", systemImage: "safari")
            }
            Button {
                showsStyleReference.toggle()
            } label: {
                Label("Map Styles Guide", systemImage: "questionmark.circle")
            }
            Section("Export") {
                Button {
                    Task { await model.shareGeoTIFF(.elevation) }
                } label: {
                    Label(
                        model.analyticalExportStyle == nil ? "Export 32-bit Float GeoTIFF" : "Export Elevation GeoTIFF",
                        systemImage: "doc.badge.gearshape.fill"
                    )
                }
                .disabled(model.isPreparingExport)
                // A micro-topography style can also export its product: the analysis values, not the colour map.
                if let style = model.analyticalExportStyle {
                    Button {
                        Task { await model.shareGeoTIFF(.analytical(style)) }
                    } label: {
                        Label("Export \(style.displayName) GeoTIFF", systemImage: "chart.xyaxis.line")
                    }
                    .disabled(model.isPreparingExport)
                }
            }
            Divider()
            Button {
                showsSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .accessibilityLabel("More")
    }
}
