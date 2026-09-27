//
//  ElevationProfileView.swift
//  LidarExplorer
//
//  Interactive 2D cross-sectional elevation profile chart and metrics.
//

import Charts
import SwiftUI

public struct ElevationProfileView: View {

    public typealias Metric = TerrainViewerModel.ProfileMetric

    @Bindable var model: TerrainViewerModel
    let profile: ElevationProfile

    @State private var selectedDistance: Double?
    @State private var isExpanded: Bool = true
    @State private var chartHeight: CGFloat = 140
    @State private var dragStartHeight: CGFloat?

    public init(model: TerrainViewerModel, profile: ElevationProfile) {
        self.model = model
        self.profile = profile
    }

    public var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 44, height: 5)
                .padding(.bottom, 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartHeight ?? chartHeight
                            dragStartHeight = start
                            chartHeight = min(max(start - value.translation.height, 90), 420)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .accessibilityLabel("Resize profile")

            headerRow
            if isExpanded {
                metricsRow
                Picker("Metric", selection: $model.activeProfileMetric) {
                    ForEach(Metric.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if model.showsTransectSignatures, let signatures = model.activeTransectAnalysis?.signatures, !signatures.isEmpty {
                    // Kept in place while the analysis catches up (dropped, the bottom-anchored panel would shrink under
                    // the finger), dimmed: they describe the line the finger last paused on (``analysisDim``).
                    signaturesRow(signatures)
                        .opacity(analysisDim)
                }
                chartSection
                // The ruler's row is always there, a hint holding its place until a finger is on the chart: added
                // only while scrubbing, it grew the bottom-anchored panel upward and moved the chart under the finger.
                if let selectedDistance, let detail = scrubDetail(at: selectedDistance) {
                    scrubRuler(detail: detail)
                } else if !model.isAnalysisOfProfile {
                    updatingNote
                } else {
                    scrubHint
                }
            }
        }
        .padding(16)
        .glassPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Where the detected earthworks change: plateau edges of a mound, every ditch floor and berm crest. Only
    /// the signatures the panel is showing count.
    private var scrubBreaks: [Double] {
        guard model.showsTransectSignatures, model.isAnalysisOfProfile else { return [] }
        return (model.activeTransectAnalysis?.signatures ?? []).flatMap { $0.breakDistances.map(Double.init) }
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

            // Offered once a transect has been analysed; disabled while it is still being drawn or another
            // export is being made. The files are formatted and written off the main actor, so scrubbing the
            // profile stays responsive while one is prepared.
            if model.activeTransectAnalysis != nil {
                Menu {
                    ForEach(TransectExportFormat.allCases) { format in
                        Button {
                            Task { await model.shareTransect(as: format) }
                        } label: {
                            Label(format.menuTitle, systemImage: format.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuIndicator(.hidden)
                .disabled(!model.canExportTransect)
                .accessibilityLabel("Export transect")
            }

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
                value: String(format: "%.1f°", model.profileMaxSlopeDegrees)
            )
            if let vol = model.activeTransectAnalysis?.estimatedVolumeCubicMeters, vol > 0 {
                Divider().frame(height: 24)
                metricItem(
                    label: "Earthwork",
                    value: String(format: "%.0f m³", vol),
                    icon: "cube.fill"
                )
                .opacity(analysisDim)
            }
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
                        if sig.estimatedVolumeCubicMeters > 0 {
                            Text(String(format: "· %.0f m³", sig.estimatedVolumeCubicMeters))
                                .font(.caption2.weight(.bold).monospacedDigit())
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

    @ViewBuilder
    private var chartSection: some View {
        switch model.activeProfileMetric {
        case .elevation:
            elevationChart
        case .slope:
            slopeChart
        case .curvature:
            curvatureChart
        }
    }

    private var elevationChart: some View {
        let isFeet = model.elevationUnit == .feet
        let scale = isFeet ? 3.28084 : 1.0

        // Only the ground there is: a transect dragged past the tiles drawn so far has samples with none, and each
        // unbroken run of ground is its own line and fill, so the chart shows a gap there instead of bridging it.
        let runs = profile.groundRuns
        let decimated = ProfileDecimation.minMax(profile.points.filter { $0.elevationMeters.isFinite }, maxCount: 384)
        let displayPoints: [(distance: Double, elevation: Double, run: Int)] = decimated.map {
            ($0.distanceMeters, Double($0.elevationMeters) * scale, runs[$0.id] ?? 0)
        }

        // The analysis's baseline only when it measured this line: mid-drag, and after a release until the released line's
        // analysis lands, it is the line the finger last paused on, and its baseline against this ground shaded a block of
        // cut or fill that meant nothing. The line's own chord stands in meanwhile.
        let baselineStart: Double
        let baselineSlope: Double
        if model.isAnalysisOfProfile,
           let first = model.activeTransectAnalysis?.samples.first(where: { !$0.baselineElevation.isNaN }),
           let last = model.activeTransectAnalysis?.samples.last(where: { !$0.baselineElevation.isNaN }),
           last.distance > first.distance {
            let d0 = Double(first.distance)
            let z0 = Double(first.baselineElevation) * scale
            let d1 = Double(last.distance)
            let z1 = Double(last.baselineElevation) * scale
            baselineSlope = (z1 - z0) / (d1 - d0)
            baselineStart = z0 - baselineSlope * d0
        } else if let first = displayPoints.first, let last = displayPoints.last, last.distance > first.distance {
            baselineSlope = (last.elevation - first.elevation) / (last.distance - first.distance)
            baselineStart = first.elevation - baselineSlope * first.distance
        } else {
            baselineStart = displayPoints.first?.elevation ?? 0
            baselineSlope = 0
        }

        let displayPointsWithBaseline: [(distance: Double, elevation: Double, baseline: Double, run: Int)] = displayPoints.map { pt in
            let base = baselineStart + baselineSlope * pt.distance
            return (pt.distance, pt.elevation, base, pt.run)
        }

        // Red above the baseline, blue below, each stretch its own series: split only at gaps, a run took its first
        // sample's colour throughout (``ProfileCutFill``).
        let shading = ProfileCutFill.stretches(displayPointsWithBaseline)

        let yMin = (Double(profile.minElevationMeters) * scale).rounded(.down) - 5
        let yMax = (Double(profile.maxElevationMeters) * scale).rounded(.up) + 5
        // The earthwork bands only when the analysis measured this line: they lie at the paused line's distances, over
        // ground on screen they do not describe.
        let signatures = model.showsTransectSignatures && model.isAnalysisOfProfile
            ? (model.activeTransectAnalysis?.signatures ?? []) : []

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

            ForEach(Array(shading.enumerated()), id: \.offset) { _, pt in
                AreaMark(
                    x: .value("Distance", pt.distance),
                    yStart: .value("Lower", min(pt.elevation, pt.baseline)),
                    yEnd: .value("Upper", max(pt.elevation, pt.baseline)),
                    series: .value("Series", "Fill \(pt.stretch)")
                )
                .foregroundStyle(pt.isAbove ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
            }

            ForEach(Array(displayPointsWithBaseline.enumerated()), id: \.offset) { _, pt in
                // Each line its own series: unnamed, the two were one polyline zigzagging between baseline and
                // ground at every sample, drawn dashed, and the orange ground line never showed.
                LineMark(
                    x: .value("Distance", pt.distance),
                    y: .value("Baseline", pt.baseline),
                    series: .value("Series", "Baseline")
                )
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                LineMark(
                    x: .value("Distance", pt.distance),
                    y: .value("Elevation", pt.elevation),
                    series: .value("Series", "Elevation \(pt.run)")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }

            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .chartYScale(domain: yMin...yMax)
        .chartXScale(domain: distanceDomain)
        .chartPlotStyle { $0.clipped() }
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
            overlayReader(proxy: proxy)
        }
        .frame(height: chartHeight)
    }

    private var slopeChart: some View {
        // Steepness, whichever way the ground falls: the slope is signed (a descent is negative), and plotted signed
        // on this 0-up axis every descent ran below the plot, through the scrub hint and off the panel onto the map.
        // The 20 degree flank line then reads for both flanks of a mound, as the detector applies it. Each stretch's
        // steepest sample, worked out by the model once per change (``TerrainViewerModel/profileSlopeLine``): its peak
        // is Max Slope whenever the analysis is of the line on screen.
        let samplePoints = model.profileSlopeLine
        let maxSlope = max(samplePoints.map(\.slope).max() ?? 30, 25)
        // A little room past both ends of the scale: the plot is clipped to it, and a line lying on an edge (flat ground
        // at 0, the steepest peak at the top) lost the outer half of its stroke.
        let slopePad = maxSlope * 0.04

        return Chart {
            ForEach(Array(samplePoints.enumerated()), id: \.offset) { _, pt in
                LineMark(
                    x: .value("Distance", pt.distance),
                    y: .value("Slope", pt.slope)
                )
                .foregroundStyle(Color.teal.opacity(analysisDim))
                .lineStyle(StrokeStyle(lineWidth: 2.0))
            }

            RuleMark(y: .value("Flank threshold", 20))
                .foregroundStyle(Color.red.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("20° Flank")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.red)
                }

            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .chartYScale(domain: -slopePad...(maxSlope + slopePad))
        .chartXScale(domain: distanceDomain)
        .chartPlotStyle { $0.clipped() }
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
                if let y = val.as(Double.self) {
                    AxisValueLabel(String(format: "%.0f°", y))
                }
            }
        }
        .chartOverlay { proxy in
            overlayReader(proxy: proxy)
        }
        .frame(height: chartHeight)
    }


    private var curvatureChart: some View {
        let samples = model.activeTransectAnalysis?.samples ?? []
        let strideStep = max(samples.count / 384, 1)
        let samplePoints: [(distance: Double, curvature: Double)] = stride(from: 0, to: samples.count, by: strideStep).compactMap { i in
            let s = samples[i]
            guard s.curvature.isFinite else { return nil }
            return (Double(s.distance), Double(s.curvature))
        }
        let curvs = samplePoints.map(\.curvature)
        let minC = min(curvs.min() ?? -0.05, -0.02)
        let maxC = max(curvs.max() ?? 0.05, 0.02)
        // Room past the extremes, so the clipped plot keeps the whole stroke of the highest and lowest peaks.
        let curvaturePad = (maxC - minC) * 0.04

        return Chart {
            ForEach(Array(samplePoints.enumerated()), id: \.offset) { _, pt in
                LineMark(
                    x: .value("Distance", pt.distance),
                    y: .value("Curvature", pt.curvature)
                )
                .foregroundStyle(Color.indigo.opacity(analysisDim))
                .lineStyle(StrokeStyle(lineWidth: 2.0))
            }

            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .chartYScale(domain: (minC - curvaturePad)...(maxC + curvaturePad))
        .chartXScale(domain: distanceDomain)
        .chartPlotStyle { $0.clipped() }
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
                if let y = val.as(Double.self) {
                    AxisValueLabel(String(format: "%.2f", y))
                }
            }
        }
        .chartOverlay { proxy in
            overlayReader(proxy: proxy)
        }
        .frame(height: chartHeight)
    }

    /// The transect's own length: left to itself the axis rounds up (a 1.11 km transect ran to about 1.5 km), leaving
    /// the right of the plot empty. Each chart clips its plot to it: mid-drag the slope and curvature lines, drawn faint
    /// while the analysis catches up (``analysisDim``), can still be the longer line's while the profile is already the
    /// shorter one's, and marks past the domain would draw over the axis labels and off the panel.
    private var distanceDomain: ClosedRange<Double> {
        0...max(profile.totalDistanceMeters, 1)
    }

    private func overlayReader(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = value.location.x - geo[plotFrame].origin.x
                            if let dist: Double = proxy.value(atX: x) {
                                let distance = max(0, min(dist, profile.totalDistanceMeters))
                                selectedDistance = distance
                                // A thump as the ruler crosses an earthwork's break, played under the finger or the
                                // Pencil scrubbing (the overlay's own coordinates, in the window's).
                                #if canImport(UIKit)
                                HapticFeedbackManager.shared.scrub(
                                    distance: distance, breaks: scrubBreaks,
                                    at: HapticRouting.windowPoint(value.location, inViewAt: geo.frame(in: .global)))
                                #endif
                            }
                        }
                        .onEnded { _ in
                            selectedDistance = nil
                            // The finger lifting: the next touch on the same break thumps again.
                            #if canImport(UIKit)
                            HapticFeedbackManager.shared.scrub(distance: nil, breaks: [], at: nil)
                            #endif
                        }
                )
        }
    }

    // MARK: - Scrub Ruler

    private struct ScrubDetail {
        let distanceMeters: Double
        /// Nil over a gap in the ground (a transect dragged past the tiles drawn so far).
        let elevationMeters: Float?
        let slopeDegrees: Float?
        let curvature: Float?
    }

    private func scrubDetail(at distance: Double) -> ScrubDetail? {
        guard let closestPt = profile.points.min(by: { abs($0.distanceMeters - distance) < abs($1.distanceMeters - distance) }) else {
            return nil
        }
        var slope: Float?
        var curv: Float?
        // The analysis's slope and curvature only when it measured this line; meanwhile they are another line's.
        if model.isAnalysisOfProfile, let samples = model.activeTransectAnalysis?.samples,
           let match = samples.min(by: { abs(Double($0.distance) - distance) < abs(Double($1.distance) - distance) }) {
            if match.slopeDegrees.isFinite { slope = match.slopeDegrees }
            if match.curvature.isFinite { curv = match.curvature }
        }
        return ScrubDetail(
            distanceMeters: closestPt.distanceMeters,
            elevationMeters: closestPt.elevationMeters.isFinite ? closestPt.elevationMeters : nil,
            slopeDegrees: slope,
            curvature: curv
        )
    }

    /// The slope under the cursor as the chart draws it, its steepness, with an arrow for which way the ground runs
    /// toward the transect's end, as Climb and Descent show it. Printed signed, a descent read "-28.0°" on a line drawn
    /// at 28.
    private func slopeReading(_ slope: Float) -> Text {
        let steepness = Text(String(format: "Slope: %.1f°", abs(slope)))
        guard abs(slope) >= 0.05 else { return steepness }
        return Text("\(steepness) \(Image(systemName: slope > 0 ? "arrow.up.right" : "arrow.down.right"))")
    }

    /// Holds the ruler's row while no finger is on the chart, at the ruler's height (the same caption2 line).
    private var scrubHint: some View {
        HStack {
            Text("Drag along the chart to read the ground")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .padding(.top, 2)
        // A touch hint: the chart's scrub is a drag, not an element VoiceOver can reach.
        .accessibilityHidden(true)
    }

    /// How strongly what the analysis found is drawn: in full when it measured the line on screen, faint while it is still
    /// the line the finger last paused on (mid-drag, and after a release until the released line's analysis lands,
    /// ``TerrainViewerModel/isAnalysisOfProfile``), so nothing it shows at full strength contradicts the elevation line,
    /// Climb, Descent or Max Slope, which follow the finger. ``updatingNote`` says why.
    private var analysisDim: Double { model.isAnalysisOfProfile ? 1 : 0.3 }

    /// Holds the hint's row while the analysis catches up with the line on screen, saying the faint slope and curvature
    /// lines, earthwork chips and volume are being measured again. One line in the same place, so the panel keeps its height.
    private var updatingNote: some View {
        HStack {
            Label("Updating analysis\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func scrubRuler(detail: ScrubDetail) -> some View {
        HStack(spacing: 12) {
            Text(model.formattedDistance(detail.distanceMeters))
                .font(.caption2.monospacedDigit())
            Text(detail.elevationMeters.map { model.formattedElevation($0) } ?? "No data")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.orange)
            if let slope = detail.slopeDegrees {
                slopeReading(slope)
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
        // One line, as the hint it replaces: wrapped to two on a narrow screen at a large text size, the row grew the
        // bottom-anchored panel under the finger. The readings shrink to fit instead.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
