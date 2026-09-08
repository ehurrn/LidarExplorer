//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar containing compact elevation readout and action buttons.
//

import CoreLocation
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
        HStack(alignment: .center, spacing: 10) {
            elevationCapsule
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Elevation Capsule

    private var elevationCapsule: some View {
        HStack(spacing: 8) {
            if case .loading = model.inspectionState {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "mountain.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            Text(readoutText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var isPlaceholder: Bool {
        if case .idle = model.inspectionState { return true }
        return false
    }

    private var readoutText: String {
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

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.goToUserLocation() }
            } label: {
                Image(systemName: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("My location")
            .disabled(model.locationAuthorization == .denied)

            Button {
                showsPrimer = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
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
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Settings")
        }
    }
}
