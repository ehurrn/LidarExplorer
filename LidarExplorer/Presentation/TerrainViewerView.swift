//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The viewer screen.
//

import CoreLocation
import MapKit
import SwiftUI

public struct TerrainViewerView: View {

    @State private var model = TerrainViewerModel()
    @State private var showsControls = true

    public init() {}

    public var body: some View {
        TerrainMapView(model: model)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                if showsControls { controlPanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
            }
            .overlay(alignment: .topLeading) { toggleButton }
            .overlay(alignment: .bottomLeading) { readout }
            .overlay(alignment: .bottom) { statusBar }
            .animation(.snappy, value: showsControls)
            .task { model.start() }
    }

    // MARK: - Controls

    private var toggleButton: some View {
        Button {
            showsControls.toggle()
        } label: {
            Image(systemName: showsControls ? "sidebar.trailing" : "slider.horizontal.3")
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .padding()
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                group("Basemap") {
                    Picker("Basemap", selection: $model.basemap) {
                        ForEach(TerrainBasemap.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    labelledSlider("Opacity", value: $model.basemapOpacity, in: 0...1)
                }

                Divider()

                group("Terrain layer") {
                    Picker("Style", selection: $model.style) {
                        ForEach(ReliefStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if model.style.usesIllumination {
                        labelledSlider("Azimuth", value: $model.azimuth, in: 0...359,
                                       format: "%.0f°")
                        labelledSlider("Sun angle", value: $model.altitude, in: 5...80,
                                       format: "%.0f°")
                    }

                    labelledSlider("Opacity", value: $model.terrainOpacity, in: 0...1)
                }

                Divider()

                VStack(spacing: 8) {
                    Button {
                        model.isLoading ? model.cancelLoad() : model.loadVisibleRegion()
                    } label: {
                        Label(
                            model.isLoading ? "Cancel" : "Load terrain here",
                            systemImage: model.isLoading ? "stop.circle" : "square.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isLoading && !model.canLoadVisibleRegion)

                    HStack(spacing: 8) {
                        Button {
                            Task { await model.goToUserLocation() }
                        } label: {
                            Image(systemName: "location.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.locationAuthorization == .denied)

                        Button(role: .destructive) {
                            model.clearTerrain()
                        } label: {
                            Image(systemName: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.reliefImage == nil)
                    }
                }

                if let statistics = model.statistics {
                    Divider()
                    terrainSummary(statistics)
                }
            }
            .padding(14)
        }
        .frame(width: 268)
        .frame(maxHeight: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String = "%.0f%%"
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format,
                            format.hasSuffix("%%") ? value.wrappedValue * 100 : value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func terrainSummary(_ statistics: ElevationGrid.Statistics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Loaded terrain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            summaryRow("Range", String(format: "%.0f – %.0f m",
                                       statistics.minimum, statistics.maximum))
            summaryRow("Relief", String(format: "%.1f m", statistics.range))
            summaryRow("Mean", String(format: "%.1f m", statistics.mean))
            summaryRow("Std dev", String(format: "%.2f m", statistics.standardDeviation))
            if let gsd = model.groundSampleDistance {
                summaryRow("Resolution", String(format: "%.1f m/px", gsd))
            }
            if statistics.voidCount > 0 {
                summaryRow("Coverage", String(format: "%.1f%%", statistics.coverage * 100))
            }
            if let backend = model.backend {
                summaryRow("Computed on", backend.rawValue.uppercased())
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    // MARK: - Readout

    @ViewBuilder
    private var readout: some View {
        if let coordinate = model.inspectedCoordinate {
            VStack(alignment: .leading, spacing: 2) {
                if let elevation = model.inspectedElevation {
                    Text(String(format: "%.1f m", elevation))
                        .font(.title3.monospacedDigit().weight(.semibold))
                } else {
                    Text(model.reliefImage == nil ? "No terrain loaded" : "Outside loaded area")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let message = model.statusMessage {
            HStack(spacing: 10) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Text(message).font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
    }
}
