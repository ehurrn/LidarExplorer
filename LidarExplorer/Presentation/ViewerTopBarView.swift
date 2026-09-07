//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar containing compact elevation readout and action buttons.
//

import SwiftUI

public struct ViewerTopBarView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsPrimer: Bool
    @Binding var showsSettings: Bool

    public init(
        model: TerrainViewerModel,
        showsPrimer: Binding<Bool>,
        showsSettings: Binding<Bool>
    ) {
        self.model = model
        self._showsPrimer = showsPrimer
        self._showsSettings = showsSettings
    }

    public var body: some View {
        HStack(alignment: .center) {
            elevationCapsule
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Elevation Capsule

    private var elevationCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "mountain.2.fill")
                .font(.caption2)
                .foregroundStyle(.tint)

            if let elevation = model.elevationReadout {
                Text(model.formattedElevation(elevation))
                    .font(.caption.weight(.semibold))
            } else {
                Text("Tap map for elevation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showsPrimer = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Lidar Guide")

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Settings")
        }
    }
}

// MARK: - TerrainViewerModel Elevation Extension

extension TerrainViewerModel {
    public var elevationReadout: Float? {
        inspectedElevation
    }

    public func formattedElevation(_ elevation: Float) -> String {
        String(format: "%.1f m", elevation)
    }
}
