//
//  ViewerBottomDockView.swift
//  LidarExplorer
//
//  Floating dock hosting direct shading mode switcher and sun azimuth scrubber.
//

import SwiftUI

public typealias ShadingMode = ReliefStyle

extension TerrainViewerModel {
    public var shadingMode: ReliefStyle {
        get { style }
        set { style = newValue }
    }

    public var sunAzimuth: Double {
        get { azimuth }
        set { azimuth = newValue }
    }

    public var isDownloading: Bool { false }
    public var isRendering: Bool { false }
}

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
        HStack(spacing: 8) {
            Picker("Shading Mode", selection: $model.shadingMode) {
                ForEach(ShadingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.isDownloading || model.isRendering {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    // MARK: - Azimuth Scrubber Row

    private var azimuthRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Slider(value: $model.sunAzimuth, in: 0...360, step: 1) {
                Text("Sun Direction")
            }
            .tint(.orange)

            Text(String(format: "%03.0f°", model.sunAzimuth))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private extension ShadingMode {
    var label: String {
        switch self {
        case .multiDirectional: return "Multi-Dir"
        case .hillshade: return "Hillshade"
        case .slope: return "Slope"
        case .elevation: return "Elevation"
        }
    }
}
