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
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

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
        HStack(alignment: .center, spacing: 10) {
            elevationCapsule
            Spacer(minLength: 0)
            // With the Map Styles panel open the bar can be narrower than its
            // content (iPad Pro 11" portrait); the readout truncates first.
            actionButtons
                .layoutPriority(1)
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
                .lineLimit(1)
                .truncationMode(.tail)
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
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.toggleFieldMarkup()
                }
            } label: {
                Image(systemName: model.isMarkingUp ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.isMarkingUp ? .green : .primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(model.isMarkingUp ? Color.green.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel(model.isMarkingUp ? "Exit Field Markup" : "Field Markup")

            Button {
                showsStyleReference.toggle()
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
            .accessibilityLabel("Map Styles")

            Menu {
                Button {
                    Task { await model.shareGeoTIFF(.elevation) }
                } label: {
                    Label(
                        model.analyticalExportStyle == nil ? "Export 32-bit Float GeoTIFF" : "Export Elevation GeoTIFF",
                        systemImage: "doc.badge.gearshape.fill"
                    )
                }
                // A micro-topography style can also export its product: the analysis values, not the colour map.
                if let style = model.analyticalExportStyle {
                    Button {
                        Task { await model.shareGeoTIFF(.analytical(style)) }
                    } label: {
                        Label("Export \(style.displayName) GeoTIFF", systemImage: "chart.xyaxis.line")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .disabled(model.isPreparingExport)
            .accessibilityLabel("Export Menu")

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
