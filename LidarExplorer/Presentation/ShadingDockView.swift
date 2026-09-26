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
        HStack(alignment: .center, spacing: 14) {
            styleTray
            if model.sunDirectionMatters {
                sunDial
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.sunDirectionMatters)
        .onAppear { localAzimuth = model.azimuth }
        .onChange(of: model.azimuth) { _, new in
            // The pencil roll or a reset moved the sun; follow unless a finger owns the dial.
            if !isDraggingSun, abs(localAzimuth - new) > 0.5 { localAzimuth = new }
        }
        .onChange(of: model.style) { _, _ in selectionFeedback.selectionChanged() }
    }

    // MARK: - Style tray

    private var styleTray: some View {
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
                            .frame(minHeight: 40)
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
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
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

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.5))
            Circle()
                .strokeBorder(.separator, lineWidth: 0.75)

            detentMarks

            // The sun, riding the rim.
            Circle()
                .fill(Color.orange.gradient)
                .frame(width: 14, height: 14)
                .shadow(color: .orange.opacity(isActive ? 0.8 : 0.35), radius: isActive ? 7 : 3)
                .offset(y: -(diameter / 2 - 12))
                .rotationEffect(.degrees(azimuth))

            Text(readout)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText(value: azimuth))
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: azimuth.rounded())
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isActive ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        .contentShape(Circle())
        .gesture(dialGesture)
        .accessibilityElement()
        .accessibilityLabel("Sun direction")
        .accessibilityValue(String(format: "%.0f degrees", azimuth))
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            var next = (azimuth + step).truncatingRemainder(dividingBy: 360)
            if next < 0 { next += 360 }
            onBegan(); onChanged(next); onEnded()
        }
    }

    private var readout: String {
        let whole = azimuth.rounded() == 360 ? 0 : azimuth.rounded()
        return String(format: "%03.0f°", whole)
    }

    /// Ticks at the eight headings the haptics snap to; the one the sun sits nearest glows, so the
    /// haptic and the picture agree.
    private var detentMarks: some View {
        ForEach(DialGeometry.compassDetents, id: \.self) { heading in
            let near = DialGeometry.nearestDetent(to: azimuth, tolerance: 6) == heading
            // A concrete colour, not the hierarchical `.tertiary`: under rotationEffect that style drew
            // nothing, so only the unrotated north tick showed (iOS 27 Simulator).
            Capsule()
                .fill(near ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
                .frame(width: near ? 2.5 : 1.5,
                       height: heading.truncatingRemainder(dividingBy: 90) == 0 ? 7 : 5)
                .offset(y: -(diameter / 2 - 6))
                .rotationEffect(.degrees(heading))
                .animation(.easeOut(duration: 0.12), value: near)
        }
    }

    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isTracking {
                    isTracking = true
                    onBegan()
                }
                guard let degrees = DialGeometry.bearing(at: value.location, diameter: diameter) else { return }
                onChanged(degrees)
            }
            .onEnded { _ in
                isTracking = false
                onEnded()
            }
    }
}
