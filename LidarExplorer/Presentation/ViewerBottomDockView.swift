//
//  ViewerBottomDockView.swift
//  LidarExplorer
//
//  Floating dock hosting direct shading mode switcher and sun azimuth scrubber.
//

import SwiftUI

public struct ViewerBottomDockView: View {

    @Bindable var model: TerrainViewerModel

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 10) {
            modeRow
            azimuthRow
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
    }

    // MARK: - Mode Row

    private var modeRow: some View {
        Picker("Shading Mode", selection: $model.style) {
            ForEach(ReliefStyle.allCases, id: \.self) { style in
                Text(style.dockLabel).tag(style)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Azimuth Scrubber Row

    private var azimuthRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Slider(value: $model.azimuth, in: 0...360, step: 1) {
                Text("Sun Direction")
            }
            .tint(.orange)

            Text(String(format: "%03.0f°", model.azimuth))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private extension ReliefStyle {
    var dockLabel: String {
        switch self {
        case .multiDirectional: return "Multi-Dir"
        case .hillshade: return "Hillshade"
        case .slope: return "Slope"
        case .elevation: return "Elevation"
        }
    }
}
