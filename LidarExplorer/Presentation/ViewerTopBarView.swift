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
            if model.isProfileModeActive {
                if model.isGeneratingProfile {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ruler.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(model.isProfileModeActive ? Color.orange.opacity(0.3) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
                model.showsLandmarks = true
            } label: {
                Image(systemName: "safari")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Explore LiDAR Sites")

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.toggleProfileMode()
                }
            } label: {
                Image(systemName: model.isProfileModeActive ? "ruler.fill" : "ruler")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.isProfileModeActive ? .orange : .primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(model.isProfileModeActive ? Color.orange.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel(model.isProfileModeActive ? "Exit Profile Mode" : "Cross-Section Profile")

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.toggleViewshedMode()
                }
            } label: {
                Image(systemName: model.interactionMode == .viewshed ? "eye.fill" : "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.interactionMode == .viewshed ? .indigo : .primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(model.interactionMode == .viewshed ? Color.indigo.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel(model.interactionMode == .viewshed ? "Exit Viewshed Mode" : "Viewshed Analysis")

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
