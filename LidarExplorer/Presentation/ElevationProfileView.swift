//
//  ElevationProfileView.swift
//  LidarExplorer
//
//  Interactive 2D cross-sectional elevation profile chart and metrics.
//

import Charts
import SwiftUI

public struct ElevationProfileView: View {

    @Bindable var model: TerrainViewerModel
    let profile: ElevationProfile

    @State private var selectedDistance: Double?

    public init(model: TerrainViewerModel, profile: ElevationProfile) {
        self.model = model
        self.profile = profile
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerRow
            metricsRow
            chartSection
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Cross-Section Profile")
                .font(.headline)

            Spacer()

            Button {
                model.clearProfile()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close profile")
        }
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metricItem(
                label: "Distance",
                value: model.formattedDistance(profile.totalDistanceMeters)
            )
            Divider().frame(height: 24)
            metricItem(
                label: "Climb",
                value: model.formattedElevation(Float(profile.elevationGainMeters)),
                icon: "arrow.up.right"
            )
            Divider().frame(height: 24)
            metricItem(
                label: "Descent",
                value: model.formattedElevation(Float(profile.elevationLossMeters)),
                icon: "arrow.down.right"
            )
            Divider().frame(height: 24)
            metricItem(
                label: "Max Slope",
                value: String(format: "%.1f°", profile.maxSlopeDegrees)
            )
        }
        .padding(.vertical, 4)
    }

    private func metricItem(label: String, value: String, icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private var chartSection: some View {
        let isFeet = model.elevationUnit == .feet
        let scale = isFeet ? 3.28084 : 1.0

        let displayPoints: [(distance: Double, elevation: Double)] = profile.points.map {
            ($0.distanceMeters, Double($0.elevationMeters) * scale)
        }

        let yMin = (Double(profile.minElevationMeters) * scale).rounded(.down) - 5
        let yMax = (Double(profile.maxElevationMeters) * scale).rounded(.up) + 5

        return Chart {
            ForEach(displayPoints, id: \.distance) { pt in
                AreaMark(
                    x: .value("Distance", pt.distance),
                    yStart: .value("Baseline", yMin),
                    yEnd: .value("Elevation", pt.elevation)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.4), Color.orange.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Distance", pt.distance),
                    y: .value("Elevation", pt.elevation)
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartYScale(domain: yMin...yMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { val in
                AxisGridLine()
                AxisTick()
                if let dist = val.as(Double.self) {
                    AxisValueLabel(model.formattedDistance(dist))
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { val in
                AxisGridLine()
                AxisTick()
                if let elev = val.as(Double.self) {
                    AxisValueLabel(isFeet ? "\(Int(elev)) ft" : "\(Int(elev)) m")
                }
            }
        }
        .frame(height: 140)
    }
}
