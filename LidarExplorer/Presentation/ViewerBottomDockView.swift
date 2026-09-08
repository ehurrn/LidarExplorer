//
//  ViewerBottomDockView.swift
//  LidarExplorer
//
//  Floating dock hosting direct shading mode switcher and sun azimuth scrubber.
//

import SwiftUI
import UIKit

public struct ViewerBottomDockView: View {

    @Bindable var model: TerrainViewerModel

    @State private var localAzimuth: Double = 315
    @State private var debounceTask: Task<Void, Never>?
    @State private var impactFeedback = UIImpactFeedbackGenerator(style: .rigid)
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @State private var lastCardinal: Int? = nil

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 10) {
            modeRow
            if model.style.usesIllumination {
                azimuthRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear {
            localAzimuth = model.azimuth
        }
        .onChange(of: model.azimuth) { _, newAzimuth in
            if abs(localAzimuth - newAzimuth) > 0.5 {
                localAzimuth = newAzimuth
            }
        }
        .animation(.snappy, value: model.style.usesIllumination)
    }

    // MARK: - Mode Row

    private var modeRow: some View {
        Picker("Shading Mode", selection: $model.style) {
            ForEach(ReliefStyle.allCases) { style in
                Text(style.dockLabel).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: model.style) { _, _ in
            selectionFeedback.selectionChanged()
        }
    }

    // MARK: - Azimuth Row

    private var azimuthRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)

            Slider(value: $localAzimuth, in: 0...359) { isEditing in
                if !isEditing {
                    // Touch released: commit immediately
                    debounceTask?.cancel()
                    model.azimuth = localAzimuth
                }
            }
            .onChange(of: localAzimuth) { _, newValue in
                // Cardinal haptic detent
                let cardinal = nearestCardinal(newValue)
                if cardinal != lastCardinal {
                    lastCardinal = cardinal
                    if cardinal != nil {
                        impactFeedback.impactOccurred()
                    }
                }
                // While scrubbing, debounce by 60ms to prevent CPU saturation from rapid tile re-renders
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    model.azimuth = newValue
                }
            }

            Text(String(format: "%03.0f°", localAzimuth))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private func nearestCardinal(_ degrees: Double) -> Int? {
        for c in [0, 90, 180, 270] {
            let diff = abs(degrees - Double(c))
            let wrapped = min(diff, 360 - diff)
            if wrapped <= 1.0 {
                return c
            }
        }
        return nil
    }
}

private extension ReliefStyle {
    var dockLabel: String {
        switch self {
        case .multiDirectional: "Multi-Dir"
        case .hillshade: "Hillshade"
        case .slope: "Slope"
        case .elevation: "Elevation"
        }
    }
}
