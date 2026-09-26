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
    /// The style picker's own tick; the dial's ticks belong to ``HapticFeedbackManager``.
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @Namespace private var chipSelection

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        // A stack, not a Group: a Group hands its modifiers to each branch, so the animation below sat inside the
        // view being swapped and the swap ran unanimated. Bottom-aligned, the pill rests where the dock's foot was.
        ZStack(alignment: .bottom) {
            if isEvacuated {
                evacuatedPill
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                dock
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
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
        .onChange(of: model.style) { _, _ in selectionFeedback.selectionChanged() }
    }

    /// The dock yields while the camera moves, but never from under a finger on the dial: a second hand
    /// pinching the map would take the dial away mid-drag.
    private var isEvacuated: Bool {
        model.isCameraGestureActive && !isDraggingSun
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
                        .accessibilityLabel(style.displayName)
                        // Voice Control matches the words on screen, so the chip answers to its short label too.
                        .accessibilityInputLabels([Text(style.dockLabel), Text(style.displayName)])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            // Chips at rest start clear of the edge fades; only a chip scrolled under one fades.
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .mask {
                // The tray fades at its edges instead of clipping chips mid-glyph.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            }
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

    // MARK: - Sun dial

    private var sunDial: some View {
        SunAzimuthDial(
            azimuth: localAzimuth,
            isActive: isDraggingSun,
            onBegan: {
                isDraggingSun = true
                HapticFeedbackManager.shared.beginAzimuthGesture(at: localAzimuth)
            },
            onChanged: { degrees in
                localAzimuth = degrees
                HapticFeedbackManager.shared.azimuthSnap(degrees: degrees)
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
            }
        )
    }
}

// MARK: - Dial

/// A circular bearing instrument: drag anywhere on the face to swing the sun, wrapping freely through
/// north. 0° is up (north), increasing clockwise, matching the shading azimuth convention.
struct SunAzimuthDial: View {

    let azimuth: Double
    let isActive: Bool
    let onBegan: () -> Void
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 76
    @State private var isTracking = false
    /// True while a finger is down. Unlike the drag's `onEnded`, it also resets when the system cancels the touch.
    @GestureState private var isPressed = false

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
                .frame(width: 14, height: 14)
                .animation(Self.pressSpring) { sun in
                    sun.shadow(color: .orange.opacity(isActive ? 0.8 : 0.35), radius: isActive ? 7 : 3)
                }
                .offset(y: -(diameter / 2 - 15))
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
            onBegan(); onChanged(next); onEnded()
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
                    onBegan()
                }
                guard let degrees = DialGeometry.bearing(at: value.location, diameter: diameter) else { return }
                onChanged(degrees)
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
