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
    @State private var isExpanded: Bool = true

    public init(model: TerrainViewerModel, profile: ElevationProfile) {
        self.model = model
        self.profile = profile
    }

    public var body: some View {
        VStack(spacing: 10) {
            headerRow
            if isExpanded {
                metricsRow
                if let signatures = model.activeTransectAnalysis?.signatures, !signatures.isEmpty {
                    signaturesRow(signatures)
                }
                chartSection
                if let selectedDistance, let detail = scrubDetail(at: selectedDistance) {
                    scrubRuler(detail: detail)
                }
            }
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

            Text("Micro-Topography Profile")
                .font(.headline)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse profile" : "Expand profile")

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
        .padding(.vertical, 2)
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

    // MARK: - Earthwork Signatures

    private func signaturesRow(_ signatures: [TransectSignature]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(signatures) { sig in
                    HStack(spacing: 4) {
                        Image(systemName: sig.kind == .platformMound ? "square.stack.3d.up.fill" : "water.waves")
                            .font(.caption2)
                        if sig.kind == .platformMound {
                            Text(String(format: "Mound: %.0f m top · %.1f m relief", sig.plateauWidthMeters ?? 0, sig.reliefMeters))
                                .font(.caption2.weight(.medium))
                        } else {
                            Text(String(format: "Berm/Ditch: %.1fm relief", sig.reliefMeters))
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        sig.kind == .platformMound
                            ? Color.purple.opacity(0.18)
                            : Color.blue.opacity(0.18),
                        in: Capsule()
                    )
                    .foregroundStyle(sig.kind == .platformMound ? Color.purple : Color.blue)
                }
            }
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        let isFeet = model.elevationUnit == .feet
        let scale = isFeet ? 3.28084 : 1.0

        let decimated = decimatePoints(profile.points, maxCount: 384)
        let displayPoints: [(distance: Double, elevation: Double)] = decimated.map {
            ($0.distanceMeters, Double($0.elevationMeters) * scale)
        }

        let yMin = (Double(profile.minElevationMeters) * scale).rounded(.down) - 5
        let yMax = (Double(profile.maxElevationMeters) * scale).rounded(.up) + 5
        let signatures = model.activeTransectAnalysis?.signatures ?? []

        return Chart {
            ForEach(signatures) { sig in
                RectangleMark(
                    xStart: .value("SigStart", Double(sig.startDistance)),
                    xEnd: .value("SigEnd", Double(sig.endDistance))
                )
                .foregroundStyle(
                    sig.kind == .platformMound
                        ? Color.purple.opacity(0.15)
                        : Color.blue.opacity(0.15)
                )
            }

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

            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x - geo[proxy.plotFrame!].origin.x
                                if let dist: Double = proxy.value(atX: x) {
                                    selectedDistance = max(0, min(dist, profile.totalDistanceMeters))
                                }
                            }
                            .onEnded { _ in
                                selectedDistance = nil
                            }
                    )
            }
        }
        .frame(height: 140)
    }

    // MARK: - Scrub Ruler

    private struct ScrubDetail {
        let distanceMeters: Double
        let elevationMeters: Float
        let slopeDegrees: Float?
        let curvature: Float?
    }

    private func scrubDetail(at distance: Double) -> ScrubDetail? {
        guard let closestPt = profile.points.min(by: { abs($0.distanceMeters - distance) < abs($1.distanceMeters - distance) }) else {
            return nil
        }
        var slope: Float?
        var curv: Float?
        if let samples = model.activeTransectAnalysis?.samples,
           let match = samples.min(by: { abs(Double($0.distance) - distance) < abs(Double($1.distance) - distance) }) {
            if match.slopeDegrees.isFinite { slope = match.slopeDegrees }
            if match.curvature.isFinite { curv = match.curvature }
        }
        return ScrubDetail(
            distanceMeters: closestPt.distanceMeters,
            elevationMeters: closestPt.elevationMeters,
            slopeDegrees: slope,
            curvature: curv
        )
    }

    private func scrubRuler(detail: ScrubDetail) -> some View {
        HStack(spacing: 12) {
            Text(model.formattedDistance(detail.distanceMeters))
                .font(.caption2.monospacedDigit())
            Text(model.formattedElevation(detail.elevationMeters))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.orange)
            if let slope = detail.slopeDegrees {
                Text(String(format: "Slope: %.1f°", slope))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let curv = detail.curvature {
                Text(String(format: "Curv: %.3f/m", curv))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - Decimation

    private func decimatePoints(_ points: [ElevationProfilePoint], maxCount: Int = 384) -> [ElevationProfilePoint] {
        guard points.count > maxCount, maxCount >= 2 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var result: [ElevationProfilePoint] = []
        result.reserveCapacity(maxCount)
        for i in 0..<maxCount {
            let index = min(Int((Double(i) * step).rounded()), points.count - 1)
            result.append(points[index])
        }
        return result
    }
}
