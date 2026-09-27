//
//  ShadingDockView.swift
//  LidarExplorer
//
//  Floating dock: the relief-style tray and a circular sun-azimuth dial. The dial wraps freely through
//  north — a linear slider cannot cross 359° to 0° — and draws the eight compass detents the haptics
//  tick (HapticDetents), the near one brightening, so every snap that is felt is also seen.
//

import SwiftUI
import UIKit

public struct ShadingDockView: View {

    @Bindable var model: TerrainViewerModel

    /// The sun while a finger is on the dial; committed through the same 60 ms debounce the old slider
    /// used, so a scrub does not re-shade every visible tile per sample.
    @State private var localAzimuth: Double = 315
    @State private var debounceTask: Task<Void, Never>?
    @State private var isDraggingSun = false
    /// True while the tray scrolls under a finger (or coasts from one), so a second hand moving the map leaves it be.
    /// Not while the tray scrolls itself to a chip (``isUnderFinger(_:)``).
    @State private var isTrayScrolling = false
    /// Which ends of the tray have chips past them, each shown by a chevron.
    @State private var trayOverflow = TrayOverflow()
    /// The chips at least mostly in view, for a chevron to page the tray from.
    @State private var chipsInView: [ReliefStyle.ID] = []
    /// The dock was touched during the camera move (while it had yielded, or by a dial drag or tray scroll that ran
    /// into the move): it stays out until the camera settles.
    @State private var isHeldOpen = false
    /// Where each chip is in the window, for the style tick to play at the chip picked (``HapticFeedbackManager``).
    @State private var chipAnchors = ChipAnchors()
    @Namespace private var chipSelection
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        // The dock stays mounted and keeps its footprint while it yields. Swapped out for the pill, it shrank the
        // bottom inset, so the callout and markup toolbar stacked above it dropped on every pan and sprang back on
        // settle, and the tray lost its scroll position. Bottom-aligned, the pill rests where the dock's foot is.
        ZStack(alignment: .bottom) {
            dock
                .opacity(isEvacuated ? 0 : 1)
                .scaleEffect(isEvacuated && !reduceMotion ? 0.96 : 1, anchor: .bottom)
                .accessibilityHidden(isEvacuated)
            if isEvacuated {
                evacuatedPill
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .overlay {
            if isEvacuated {
                // The yielded dock's area is not a hole to the map: MapKit settles a flick only after it coasts
                // (and a flight only when it lands), so a tap aimed at a chip meanwhile fell through to the ground
                // as a spot inspection or a transect point. A touch here brings the dock back instead.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in isHeldOpen = true })
                    .accessibilityHidden(true)
                    // Gone the moment the dock comes back, not faded out with it: a view leaving by a transition
                    // still takes touches, so under the dock's fade-in this clear layer swallowed a chip tapped in
                    // the spring's half second (a chip tapped then did nothing; seen with the fade slowed to 4 s).
                    .transition(.identity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isEvacuated)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { localAzimuth = model.azimuth }
        .onChange(of: model.azimuth) { _, new in
            // The pencil roll or a reset moved the sun; follow unless a finger owns the dial.
            if !isDraggingSun, abs(localAzimuth - new) > 0.5 { localAzimuth = new }
        }
        // At the chip picked: where the finger or the Pencil lifted, or where the tray is scrolling to for a style
        // picked elsewhere.
        .onChange(of: model.style) { _, style in
            HapticFeedbackManager.shared.play(
                .styleChanged, at: chipAnchors.anchor(for: style.id).windowCentre, in: model.viewerWindow?())
        }
        .onChange(of: model.isCameraGestureActive) { _, moving in
            if !moving { isHeldOpen = false }
        }
    }

    /// The dock yields while the camera moves, but never from under a finger on the dial or the tray (a second
    /// hand pinching the map would take them away mid-drag), once used during the move, or while VoiceOver
    /// or Switch Control drives focus: a focused chip or dial would drop out of the tree and lose its place.
    private var isEvacuated: Bool {
        model.isCameraGestureActive && !isDraggingSun && !isTrayScrolling && !isHeldOpen
            && !voiceOverEnabled && !switchControlEnabled
    }

    /// While the map is being panned or pinched the dock yields to a single read-only pill: the
    /// current style, and the sun bearing when it matters.
    private var evacuatedPill: some View {
        HStack(spacing: 6) {
            Text(model.style.dockLabel)
                .font(.caption.weight(.semibold))
            if model.sunDirectionMatters {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                // The dial's own whole degree, so the pill and the readout it stands in for never disagree.
                Text(String(format: "%03d°", DialGeometry.wholeDegrees(model.azimuth)))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
        // One element, not a style, a dot, an unlabeled symbol and a number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pillAccessibilityLabel)
    }

    private var pillAccessibilityLabel: String {
        guard model.sunDirectionMatters else { return model.style.displayName }
        return "\(model.style.displayName), sun \(DialGeometry.wholeDegrees(model.azimuth)) degrees"
    }

    private var dock: some View {
        HStack(alignment: .center, spacing: 14) {
            styleTray
            if model.sunDirectionMatters {
                sunDial
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        // The dial's diameter scales with the text and shares the row with the tray; past accessibility 2 it
        // would leave the tray too narrow for one chip on a phone.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel()
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.sunDirectionMatters)
    }

    // MARK: - Style tray

    private var styleTray: some View {
        ScrollViewReader { tray in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ReliefStyle.allCases) { style in
                        let selected = model.style == style
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                model.style = style
                            }
                        } label: {
                            Text(style.dockLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background {
                                    if selected {
                                        Capsule()
                                            .fill(Color.accentColor.gradient)
                                            .matchedGeometryEffect(id: "chip", in: chipSelection)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .hapticAnchor(chipAnchors.anchor(for: style.id))
                        .accessibilityLabel(style.displayName)
                        // Voice Control matches the words on screen, so the chip answers to its short label too.
                        .accessibilityInputLabels([Text(style.dockLabel), Text(style.displayName)])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
                .scrollTargetLayout()
            }
            // Chips at rest start clear of the edge fades; only a chip scrolled under one fades.
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .onScrollTargetVisibilityChange(idType: ReliefStyle.ID.self, threshold: 0.9) { chipsInView = $0 }
            .onScrollPhaseChange { old, phase in
                isTrayScrolling = Self.isUnderFinger(phase)
                // A scroll that ran into a camera move holds the dock out once it comes to rest, as a touch does.
                if Self.isUnderFinger(old), !Self.isUnderFinger(phase) { holdOpenIfCameraMoving() }
            }
            .onScrollGeometryChange(for: TrayOverflow.self) { geometry in
                TrayOverflow(leading: geometry.visibleRect.minX > 1,
                             trailing: geometry.visibleRect.maxX < geometry.contentSize.width - 1)
            } action: { _, overflow in
                trayOverflow = overflow
            }
            .mask {
                // The tray fades at its edges instead of clipping chips mid-glyph.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.trayFade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.trayFade)
                    // Beside the dial, a clear strip at the end for the trailing chevron, so it is never drawn over a
                    // chip. The chip scrolled under the strip still takes touches there: the chevron takes them first.
                    if showsTrailingChevronInTray { Color.clear.frame(width: Self.trayStrip) }
                }
            }
            // The chips' 28 pt gaps (their padding and spacing) are wider than the fade, so the tray's edge can fall
            // between two chips and show nothing of the next one: with the dial beside it on a 13-inch in portrait,
            // the tray ended at PosOp and nothing said NegOp, VRM and DoG lay past it. A chevron says so, in the
            // gutter just outside the tray (the dock's padding), clear of the chips. Beside the dial it takes a clear
            // strip at the tray's own end instead: out in the gap before the dial it sat 5 pt from the rim, by the
            // west tick, and read as part of the dial. Either way it is a button that pages the tray, its target the
            // tray's full height and ``chevronTarget`` wide, over its end's fade zone and out past the tray's edge.
            .overlay(alignment: .leading) {
                if trayOverflow.leading {
                    overflowChevron(forward: false, tray: tray, glyphCentre: Self.gutterGlyphCentre)
                }
            }
            .overlay(alignment: .trailing) {
                if trayOverflow.trailing {
                    overflowChevron(forward: true, tray: tray,
                                    glyphCentre: showsTrailingChevronInTray ? -Self.trayStrip / 2 : Self.gutterGlyphCentre,
                                    inset: showsTrailingChevronInTray ? Self.trayStrip : 0)
                }
            }
            .animation(.easeOut(duration: 0.15), value: trayOverflow)
            // The selected chip stays in view: picked in the inspector, or pushed out as the dial takes its room.
            .onAppear { tray.scrollTo(model.style.id) }
            .onChange(of: model.style) { _, style in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tray.scrollTo(style.id) }
            }
            .onChange(of: model.sunDirectionMatters) { _, _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tray.scrollTo(model.style.id) }
            }
        }
    }

    /// The trailing chevron sits in the tray's own clear end, not the gutter: the gutter there is the gap before the dial.
    private var showsTrailingChevronInTray: Bool {
        trayOverflow.trailing && model.sunDirectionMatters
    }

    /// A scroll a finger drives, or a flick coasts on from: not `.animating`, the tray scrolling itself to the chip
    /// a style picked elsewhere (the Map Styles guide) selects, which would bring a yielded dock back mid-move.
    private static func isUnderFinger(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        default: false
        }
    }

    /// Each end of the tray fades over this width (its mask).
    private static let trayFade: CGFloat = 12
    /// Beside the dial, the clear strip at the tray's trailing end, past its fade, that the trailing chevron is drawn in.
    private static let trayStrip: CGFloat = 12
    /// A chevron's glyph centre in the gutter, this far outside the tray's edge: the middle of the dock's 14 pt padding.
    private static let gutterGlyphCentre: CGFloat = 7
    /// How wide a chevron's target is: from the inner edge of its end's fade zone out past the tray's edge, into the
    /// gutter (16 pt: the dock's 14 pt padding and 2 pt beyond) or, beside the dial, over the clear strip and 4 pt into
    /// the gap before the dial, where nothing else takes a touch. Covering the fade, it leaves no chip a place to take a
    /// tap under the chevron or its fade, where a chip is at most a sliver of padding; 12 pt wide, the glyph's own
    /// column, a tap just beside it picked a chip nobody could see, or missed.
    private static let chevronTarget: CGFloat = 28

    /// Says chips lie past that end of the tray, and pages the tray that way when tapped: the style never changes. It
    /// takes the tap itself, over ``chevronTarget`` by the tray's full height, laid over the fade zone and the chip
    /// scrolled under it (a mask hides only what is drawn, and a chip under the fade or the clear strip still answers a
    /// touch). `inset` is how far inside the tray's edge its end's fade zone ends (beside the dial, the clear strip's
    /// width), and `glyphCentre` where the glyph is drawn, from the tray's edge, outward positive. Hidden from VoiceOver,
    /// which steps through the chips themselves.
    private func overflowChevron(forward: Bool, tray: ScrollViewProxy, glyphCentre: CGFloat, inset: CGFloat = 0) -> some View {
        // The target runs from the fade's inner edge outward: its outer edge lies this far past the tray's edge.
        let reach = Self.chevronTarget - Self.trayFade - inset
        return Button {
            let page = Self.page(forward: forward, inView: chipsInView)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tray.scrollTo(page.id, anchor: page.anchor) }
        } label: {
            Image(systemName: forward ? "chevron.compact.right" : "chevron.compact.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                // From the target's outer edge to the glyph's.
                .padding(forward ? .trailing : .leading, reach - glyphCentre - 6)
                .frame(width: Self.chevronTarget, alignment: forward ? .trailing : .leading)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: forward ? reach : -reach)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// Where a chevron pages the tray. Forward, the last chip in view goes to the leading edge, so those past it come
    /// into view (the next chip, when the last already leads); back, the first goes to the trailing edge. Before the
    /// tray has said which chips are in view, the far end.
    private static func page(forward: Bool, inView: [ReliefStyle.ID]) -> (id: ReliefStyle.ID, anchor: UnitPoint) {
        let order = ReliefStyle.allCases.map(\.id)
        let shown = inView.compactMap { order.firstIndex(of: $0) }.sorted()
        guard let first = shown.first, let last = shown.last else {
            return forward ? (order[order.count - 1], .trailing) : (order[0], .leading)
        }
        return forward
            ? (order[min(last > first ? last : last + 1, order.count - 1)], .leading)
            : (order[max(first < last ? first : first - 1, 0)], .trailing)
    }

    // MARK: - Sun dial

    private var sunDial: some View {
        SunAzimuthDial(
            azimuth: localAzimuth,
            isActive: isDraggingSun,
            onBegan: {
                isDraggingSun = true
                HapticFeedbackManager.shared.beginAzimuthGesture(at: localAzimuth, in: model.viewerWindow?())
            },
            onChanged: { degrees, location in
                localAzimuth = degrees
                HapticFeedbackManager.shared.azimuthSnap(degrees: degrees, at: location, in: model.viewerWindow?())
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    model.azimuth = degrees
                }
            },
            onEnded: {
                isDraggingSun = false
                HapticFeedbackManager.shared.endAzimuthGesture()
                debounceTask?.cancel()
                model.azimuth = localAzimuth
                // A drag that ran into a camera move (one hand on the dial, the other pinching) leaves the dock out
                // under the hand that just used it, rather than yielding the moment the finger lifts.
                holdOpenIfCameraMoving()
            }
        )
    }

    /// The dock was in use during a camera move and stays out until the camera settles (``isHeldOpen``).
    private func holdOpenIfCameraMoving() {
        if model.isCameraGestureActive { isHeldOpen = true }
    }
}

/// Where each style chip is in the window: one ``HapticAnchor`` per chip, made as the chip is first laid out.
@MainActor
private final class ChipAnchors {
    private var anchors: [ReliefStyle.ID: HapticAnchor] = [:]

    func anchor(for id: ReliefStyle.ID) -> HapticAnchor {
        if let anchor = anchors[id] { return anchor }
        let made = HapticAnchor()
        anchors[id] = made
        return made
    }
}

/// Whether chips lie past the tray's leading or trailing edge.
private nonisolated struct TrayOverflow: Equatable, Sendable {
    var leading = false
    var trailing = false
}

// MARK: - Dial

/// A circular bearing instrument: drag anywhere on the face to swing the sun, wrapping freely through
/// north; a tap on the readout at its centre only reads it, and a drag that grabs the sun has it at once
/// (``DialGeometry/Drag``). 0° is up (north), increasing clockwise, matching the shading azimuth convention.
struct SunAzimuthDial: View {

    let azimuth: Double
    let isActive: Bool
    let onBegan: () -> Void
    /// The new bearing, and the touch that set it in the window's coordinates, for the haptics to play at.
    let onChanged: (Double, CGPoint?) -> Void
    let onEnded: () -> Void

    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 76
    @State private var isTracking = false
    /// The touch on the face: whether it is still a tap on the readout or a drag swinging the sun.
    @State private var drag = DialGeometry.Drag()
    /// True while a finger is down. Unlike the drag's `onEnded`, it also resets when the system cancels the touch.
    @GestureState private var isPressed = false
    /// Where the dial is in the window, so a detent's tick plays under the finger or the Pencil on it.
    @State private var anchor = HapticAnchor()

    /// The press's own spring, scoped to the scale and the glow: keyed to the press for the whole dial, it would
    /// also carry the sun's jump to the touch, and a rotation animates by numbers, so a touch across north would
    /// swing the sun the long way round.
    private static let pressSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.5))
            Circle()
                .strokeBorder(.separator, lineWidth: 0.75)

            detentMarks

            // The sun, on an orbit inside the ticks (it ends where they begin), so the one that glows is never
            // under it.
            Circle()
                .fill(Color.orange.gradient)
                .frame(width: DialGeometry.sunRadius * 2, height: DialGeometry.sunRadius * 2)
                .animation(Self.pressSpring) { sun in
                    sun.shadow(color: .orange.opacity(isActive ? 0.8 : 0.35), radius: isActive ? 7 : 3)
                }
                .offset(y: -(diameter / 2 - DialGeometry.sunOrbitInset))
                .rotationEffect(.degrees(azimuth))

            Text(readout)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText(value: azimuth))
                // Digits roll for a change nobody is dragging (a pencil roll, a VoiceOver step); under a finger
                // they would be mid-roll whenever they are read.
                .animation(isActive ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: azimuth.rounded())
        }
        .frame(width: diameter, height: diameter)
        .animation(Self.pressSpring) { dial in
            dial.scaleEffect(isActive ? 1.06 : 1)
        }
        .contentShape(Circle())
        .hapticAnchor(anchor)
        .gesture(dialGesture)
        // SwiftUI calls a drag's onEnded only when the finger lifts: a touch the system cancels (Control Center,
        // an app switch) or a dial taken off screen mid-drag must end the drag too, or the dock stops following
        // the model's sun.
        .onChange(of: isPressed) { _, pressed in
            if !pressed { finishTracking() }
        }
        .onDisappear { finishTracking() }
        .accessibilityElement()
        .accessibilityLabel("Sun direction")
        .accessibilityValue("\(DialGeometry.wholeDegrees(azimuth)) degrees")
        .accessibilityAdjustableAction { direction in
            let next = DialGeometry.adjustedBearing(from: azimuth, clockwise: direction == .increment)
            onBegan(); onChanged(next, anchor.windowCentre); onEnded()
        }
    }

    private var readout: String {
        String(format: "%03d°", DialGeometry.wholeDegrees(azimuth))
    }

    /// Ticks at the eight headings the haptics snap to. The one within 6° of the sun glows: wider than the
    /// haptics' 1.5° window, since a drag crosses that in less than a frame, so a snap that is felt stays lit
    /// long enough to be seen.
    private var detentMarks: some View {
        ForEach(DialGeometry.compassDetents, id: \.self) { heading in
            let near = DialGeometry.nearestDetent(to: azimuth, tolerance: 6) == heading
            // A concrete colour, not the hierarchical `.tertiary`: under rotationEffect that style drew
            // nothing, so only the unrotated north tick showed (iOS 27 Simulator).
            Capsule()
                .fill(near ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
                .frame(width: near ? 2.5 : 1.5,
                       height: heading.truncatingRemainder(dividingBy: 90) == 0 ? 6 : 4)
                .offset(y: -(diameter / 2 - 4.5))
                .rotationEffect(.degrees(heading))
                .animation(.easeOut(duration: 0.12), value: near)
        }
    }

    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, pressed, _ in pressed = true }
            .onChanged { value in
                if !isTracking {
                    isTracking = true
                    drag = DialGeometry.Drag()
                    onBegan()
                }
                guard let degrees = drag.bearing(at: value.location, diameter: diameter, sunAt: azimuth) else { return }
                onChanged(degrees, anchor.windowPoint(value.location))
            }
            .onEnded { _ in finishTracking() }
    }

    /// Ends the drag once, however it ended: a lift, a cancelled touch, or the dial leaving the screen.
    private func finishTracking() {
        guard isTracking else { return }
        isTracking = false
        onEnded()
    }
}
