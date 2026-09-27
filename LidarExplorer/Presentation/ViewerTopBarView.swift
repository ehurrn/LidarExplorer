//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar: the telemetry capsule, location and 3D buttons, a cluster for the three interaction
//  modes (one accent, a sliding selection), and one menu for everything that is not moment-to-moment.
//  Where the bar is too narrow to show the readout beside the buttons, the readout moves to a row below.
//

import CoreLocation
import SwiftUI

public struct ViewerTopBarView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

    @Namespace private var modeSelection

    /// The width the readout needs for a whole prompt: "Tap map for elevation" is about 212 pt at the default size.
    /// The longest prompt, "Observer placed (drag pin to move)", needs about 314 pt and still truncates on one row
    /// between these widths (an iPhone in landscape, a 13-inch in portrait beside a widened inspector): covering it
    /// would spend a second row of map height there to show the drag hint whole.
    @ScaledMetric(relativeTo: .callout) private var readableReadoutWidth: CGFloat = 220
    /// The bar's width inside its margins and the buttons' width, both measured, so the choice of one row or two
    /// follows the room alone. Choosing by the readout's own text would flip the bar as the readout changes.
    @State private var barWidth: CGFloat?
    @State private var controlsWidth: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        // One structure for both layouts: only the readout moves, so the buttons keep their identity (VoiceOver
        // and keyboard focus, and the mode cluster's single matched-geometry source) when the bar changes rows.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if fitsOneRow {
                    dimmedWhileMoving(elevationCapsule)
                        .layoutPriority(1)
                }
                Spacer(minLength: 8)
                dimmedWhileMoving(controls)
            }
            if !fitsOneRow {
                // Too narrow for a readable readout beside the buttons (an 11-inch iPad in portrait with the Map
                // Styles inspector open): the buttons keep their place and the readout takes the row under them.
                dimmedWhileMoving(elevationCapsule)
            }
        }
        // Telemetry first for VoiceOver in either layout, not after the buttons when it sits under them.
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isCameraGestureActive)
    }

    /// The bar dims while the camera moves, as the dock yields, but not while VoiceOver or Switch Control drives
    /// focus (the dock does not yield then either), and only lightly under Increase Contrast or Reduce Transparency,
    /// whose users most need the chrome legible over the terrain.
    private var movingOpacity: Double {
        guard model.isCameraGestureActive, !voiceOverEnabled, !switchControlEnabled else { return 1 }
        return contrast == .increased || reduceTransparency ? 0.7 : 0.35
    }

    /// Dims one piece of the bar (the readout, the row of buttons) while the camera moves, and keeps its touches.
    /// SwiftUI does not count content under a partial opacity when it decides whether a touch is its own or the map's
    /// beneath: dimmed as a whole, the bar let a tap aimed at a button during a flick's coast through to the map as a
    /// spot inspection (a transect point or an observer move in those modes), and the button, shown pressed, never
    /// fired. The clear backing sits outside the dim, so the piece keeps the touch and the button under it takes it.
    /// It also takes a touch in the gaps between the buttons, which used to reach the map.
    private func dimmedWhileMoving(_ piece: some View) -> some View {
        piece
            .opacity(movingOpacity)
            .background { Color.clear.contentShape(Rectangle()) }
    }

    /// Whether the readout keeps a readable width beside the buttons: what is left of the bar after the buttons,
    /// the spacer's 8 pt minimum and the 10 pt gap either side of it.
    private var fitsOneRow: Bool {
        guard let barWidth else { return true }
        return barWidth - controlsWidth - 28 >= readableReadoutWidth
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            circularButton("My location", icon: "location.fill",
                           disabled: model.locationAuthorization == .denied) {
                Task { await model.goToUserLocation() }
            }
            terrain3DButton
            modeCluster
            utilitiesMenu
        }
        // The glyphs grow with the text inside fixed 44 pt glass: past accessibility 1 they fill the mode segments and
        // then spill out of their circles and the cluster. The readout, outside this row, keeps growing.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
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
        // One element, read first in the bar whichever row it sits on.
        .accessibilityElement(children: .combine)
        .accessibilitySortPriority(1)
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

    /// The segment that carries the sliding selection. The model's toggles keep the three modes exclusive
    /// (entering one leaves the others, from the cluster or a Pencil double-tap or squeeze), but it can still hold
    /// markup and an analysis mode at once (a pencil stroke on the map starts a transect while markup's hand tool
    /// is up), and two views must never both be the source for one matched-geometry id. So the analysis mode, the
    /// one the readout describes, carries the slide, and a markup segment that is on at the same time gets a plain
    /// fill of the same accent. Leaving the analysis mode from that state hands the slide to markup, so the capsule
    /// glides onto a segment that was already lit: accepted for a state only a pencil stroke reaches.
    private var slidingMode: Mode? {
        switch model.interactionMode {
        case .transect: .profile
        case .viewshed: .viewshed
        case .explore, .thalweg, .historicalWipe: model.isMarkingUp ? .markup : nil
        }
    }

    /// The three mutually exclusive interaction tools, one accent, the selection sliding between them.
    private var modeCluster: some View {
        // No spacing and a thinner outer inset: each segment carries half the 2 pt gap and the cluster's 3 pt
        // top and bottom inset in its own hit area, so the whole cluster height answers a touch.
        HStack(spacing: 0) {
            modeSegment("Cross-Section Profile", mode: .profile,
                        icon: "ruler", selectedIcon: "ruler.fill",
                        selected: model.isProfileModeActive) {
                model.toggleProfileMode()
            }
            modeSegment("Viewshed Analysis", mode: .viewshed,
                        icon: "eye", selectedIcon: "eye.fill",
                        selected: model.interactionMode == .viewshed) {
                model.toggleViewshedMode()
            }
            modeSegment("Field Markup", mode: .markup,
                        icon: "pencil.tip.crop.circle", selectedIcon: "pencil.tip.crop.circle.fill",
                        selected: model.isMarkingUp) {
                model.toggleFieldMarkup()
            }
        }
        .padding(.horizontal, 2)
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
                .padding(.vertical, 3)
                .padding(.horizontal, 1)
                // The whole padded rectangle answers a touch; a pointer's hover highlight keeps a capsule
                // inside the cluster's rounded ends.
                .contentShape(.interaction, Rectangle())
                .contentShape(.hoverEffect, Capsule().inset(by: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        // A toggle: VoiceOver reads it as a switch button, on or off, so activating a lit segment reads as
        // turning the mode off rather than as re-choosing a selected segment.
        .accessibilityAddTraits(selected ? [.isToggle, .isSelected] : .isToggle)
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
                // Opens (or keeps open) the guide; it closes from its own close button.
                showsStyleReference = true
            } label: {
                Label("Map Styles Guide", systemImage: "questionmark.circle")
            }
            Section("Export") {
                Button {
                    Task { await model.shareGeoTIFF(.elevation) }
                } label: {
                    Label(
                        model.analyticalExportStyle == nil ? "Export 32-bit Float GeoTIFF" : "Export Elevation GeoTIFF",
                        systemImage: "doc.badge.gearshape"
                    )
                }
                .disabled(model.isPreparingExport)
                // A micro-topography style can also export its product: the analysis values, not the colour map.
                if let style = model.analyticalExportStyle {
                    Button {
                        Task { await model.shareGeoTIFF(.analytical(style)) }
                    } label: {
                        // A non-breaking hyphen: the menu is narrow enough to wrap "Sky-View" after its hyphen.
                        Label("Export \(style.displayName.replacingOccurrences(of: "-", with: "\u{2011}")) GeoTIFF",
                              systemImage: "chart.xyaxis.line")
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
            // An export in progress shows on the button, as the 3D button shows its preparation: the menu's
            // export items give no sign once it closes. The menu stays usable; its export items wait it out.
            Group {
                if model.isPreparingExport {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .accessibilityLabel("More")
        .accessibilityValue(model.isPreparingExport ? "Exporting" : "")
    }
}
