//
//  SpotInspectionCalloutView.swift
//  LidarExplorer
//
//  Floating HUD callout showing elevation, slope angle/percentage, and aspect
//  for a tapped point on the terrain map.
//

import CoreLocation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct SpotInspectionCalloutView: View {

    public let spot: SpotInspection
    @Bindable var model: TerrainViewerModel
    @State private var copied = false

    public init(spot: SpotInspection, model: TerrainViewerModel) {
        self.spot = spot
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerRow
            metricsRow
            if let unit = model.soilUnit(at: spot.coordinate) {
                Text("\(unit.name) · \(unit.drainageClass ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footerRow
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(maxWidth: 480)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.teal)

            Text("Spot Inspection")
                .font(.headline)

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    model.clearInspection()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close spot inspection")
        }
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack(spacing: 8) {
            metricBox(
                icon: "mountain.2.fill",
                label: "Elevation",
                value: spot.elevationMeters.isNaN ? "—" : spot.formattedElevation(unit: model.elevationUnit),
                tint: .blue
            )

            metricBox(
                icon: "angle",
                label: "Slope",
                value: spot.slopeDegrees.isNaN ? "—" : String(format: "%.1f° · %@", spot.slopeDegrees, spot.slopePercentFormatted),
                tint: .orange
            )

            metricBox(
                icon: "safari",
                label: "Aspect",
                value: spot.aspectFormatted,
                tint: .green
            )
        }
    }

    private func metricBox(icon: String, label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var coordinatesString: String {
        String(
            format: "%.4f°%@, %.4f°%@",
            abs(spot.coordinate.latitude),
            spot.coordinate.latitude >= 0 ? "N" : "S",
            abs(spot.coordinate.longitude),
            spot.coordinate.longitude >= 0 ? "E" : "W"
        )
    }

    private var footerRow: some View {
        HStack {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = coordinatesString
                #endif
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                    Text(copied ? "Coordinates Copied" : coordinatesString)
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(copied ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy coordinates")

            Spacer()
        }
    }
}
