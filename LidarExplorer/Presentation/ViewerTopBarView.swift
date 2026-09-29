//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar: the telemetry capsule, location and 3D buttons, a cluster for the four interaction
//  tools (one accent, a sliding selection), and one menu for everything that is not moment-to-moment.
//  Where the bar is too narrow to show the readout beside the buttons, the readout moves to a row below. In a
//  window, the bar keeps clear of iPadOS's window controls. The arithmetic is TopBarLayout's (harness Y1).
//

import CoreLocation
import SwiftUI

public struct ViewerTopBarView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

    @Namespace private var modeSelection

    /// The width the readout needs for a whole prompt: "Tap map for elevation" is about 212 pt at the default size, and
    /// the longest of the words with no tool, with markup and with the ruler, "Pick a tool to measure", about 5 pt more.
    /// The longest prompt, "Observer placed (drag pin to move)", needs about 314 pt and still truncates on one row
    /// between these widths (an iPhone in landscape, a 13-inch in portrait beside a widened inspector): covering it
    /// would spend a second row of map height there to show the drag hint whole.
    @ScaledMetric(relativeTo: .callout) private var readableReadoutWidth: CGFloat = 220
    /// The bar's width inside its margins and the buttons' width without their gaps, both measured, so the choice of
    /// the gap and of one row or two follows the room alone. Choosing by the readout's own text would flip the bar as
    /// the readout changes.
    @State private var barWidth: CGFloat?
    @State private var buttonsWidth: CGFloat = 0
    /// The window controls' corner as the system reports it for the whole bar, margins included: how far it reaches
    /// from the bar's top-leading corner. Zero in full screen.
    @State private var windowControlsCorner: CGSize = .zero
    /// The margins round the bar's content.
    private let horizontalMargin: CGFloat = 16
    private let topMargin: CGFloat = 8
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
        let layout = layout
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: TopBarLayout.rowSpacing) {
                if layout.fitsOneRow {
                    dimmedWhileMoving(elevationCapsule)
                        // Past the window controls, in a window wide enough for one row.
                        .padding(.leading, layout.readoutLeadingInset)
                        .layoutPriority(1)
                    Spacer(minLength: TopBarLayout.readoutToButtonsMinimum)
                }
                // Last in the row whichever layout, so it keeps its identity when the readout moves.
                dimmedWhileMoving(controls)
            }
            // With the readout on its own row, the buttons alone hold this one, at its trailing edge and with no
            // spacer or gap beside them: a phone in portrait has 343 pt inside the margins, and the buttons need 338.
            // The row reports the width it is offered even where the buttons are wider (minWidth: 0), so the bar's
            // measured width is its room, not the buttons' overflow read back as room. Wider than even a 6 pt row
            // allows, the buttons overflow evenly at both ends, into the margins first.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: layout.controlsOverflow ? .center : .trailing)
            if !layout.fitsOneRow {
                // Too narrow for a readable readout beside the buttons (a phone in portrait, an 11-inch iPad in
                // portrait with the Map Styles inspector open): the buttons keep their place and the readout takes
                // the row under them.
                dimmedWhileMoving(elevationCapsule)
            }
        }
        // Telemetry first for VoiceOver in either layout, not after the buttons when it sits under them.
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        // Below the window controls, in a window too narrow for the buttons beside them.
        .padding(.top, layout.topInset)
        .padding(.horizontal, horizontalMargin)
        .padding(.top, topMargin)
        // Read on the whole bar, whose top-leading corner neither the drop nor the margins move. Read on the content,
        // the corner would stop reaching it once the drop put it below the controls, and the bar would come back up.
        // The system reports the corner from here even past the bar's own height (75 pt against a 52 pt bar).
        .onGeometryChange(for: CGSize.self) { $0.containerCornerInsets.topLeading } action: { windowControlsCorner = $0 }
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

    /// The gap between the buttons, one row or two, and the room the window controls take: TopBarLayout's arithmetic
    /// over what the bar measured.
    private var layout: TopBarLayout {
        TopBarLayout(
            barWidth: barWidth, buttonsWidth: buttonsWidth, readableReadoutWidth: readableReadoutWidth,
            // From the content's top-leading corner, inside the margins.
            windowControls: CGSize(width: windowControlsCorner.width - horizontalMargin,
                                   height: windowControlsCorner.height - topMargin))
    }

    private var controls: some View {
        // 10 pt where the bar has room for the row at 10, else 6 (TopBarLayout.controlsSpacing).
        let spacing = layout.controlsSpacing
        return HStack(alignment: .center, spacing: spacing) {
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
        // Without the gaps, measured with the gap this row was laid out at, so the gap chosen from the room does not
        // feed back into the width it is chosen from.
        .onGeometryChange(for: CGFloat.self) { $0.size.width - TopBarLayout.buttonGaps * spacing } action: { buttonsWidth = $0 }
    }

    // MARK: - Elevation Capsule

    /// The readout: an icon for the tool lit and the model's words for it (`TerrainViewerModel.readout`, checked by the
    /// harness), drawn secondary where the model marks them an idle prompt.
    private var elevationCapsule: some View {
        HStack(spacing: 8) {
            switch model.mapTool {
            case .spot:
                if case .loading = model.inspectionState {
                    ProgressView().controlSize(.mini)
                } else {
                    // Teal, as the reading's pin and callout are.
                    Image(systemName: "scope")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                }
            case .profile:
                if model.isGeneratingProfile {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ruler.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            case .thalweg:
                Image(systemName: "water.waves")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            case .splitWipe:
                Image(systemName: "slider.horizontal.2.square")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            case .markupInk, .markupHand:
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            case .navigate, .viewshed:
                Image(systemName: "mountain.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            let readout = model.readout
            Text(readout.text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(readout.isPlaceholder ? .secondary : .primary)
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

    private enum Mode { case spot, profile, viewshed, markup }

    /// The segment that carries the sliding selection. The model's toggles keep the four tools exclusive (entering
    /// one leaves the others), and no gesture lights one any more: a pencil stroke under markup's hand tool used to
    /// start a transect, a route the map bridge no longer has. But the model holds markup (`isMarkingUp`) apart from
    /// the analysis mode, so nothing in its shape forbids both at once, and two views must never both be the source
    /// for one matched-geometry id. So the analysis mode, the one the readout describes, carries the slide, and a
    /// markup segment that is on at the same time gets a plain fill of the same accent.
    private var slidingMode: Mode? {
        switch model.interactionMode {
        case .spotInspection: .spot
        case .transect: .profile
        case .viewshed: .viewshed
        case .explore, .thalweg, .historicalWipe: model.isMarkingUp ? .markup : nil
        }
    }

    /// The four mutually exclusive interaction tools, one accent, the selection sliding between them.
    private var modeCluster: some View {
        // No spacing and a thinner outer inset: each segment carries half the 2 pt gap and the cluster's 3 pt
        // top and bottom inset in its own hit area, so the whole cluster height answers a touch.
        HStack(spacing: 0) {
            // There is no filled `scope` symbol: lit, it is the white glyph on the accent capsule.
            modeSegment("Spot Inspection", mode: .spot,
                        icon: "scope", selectedIcon: "scope",
                        selected: model.isSpotInspectionActive) {
                model.toggleSpotInspection()
            }
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
                    // Spoken and matched with the plain hyphen: only the visible text needs the non-breaking one.
                    .accessibilityLabel("Export \(style.displayName) GeoTIFF")
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
