//
//  TransectExporter.swift
//  LidarExplorer
//
//  GeoJSON and CSV serialisation of a transect analysis, for GIS software and spreadsheets.
//

import CoreLocation
import Foundation
import simd

public nonisolated enum TransectExportError: Error, Sendable, Equatable {
    /// Fewer than two samples have both an elevation and a position, so there is no line to write.
    case noProfile
}

/// Writes a ``TransectAnalysis`` (the sampled profile and the earthwork signatures found on it) as
/// RFC 7946 GeoJSON or RFC 4180 CSV.
///
/// An analysis places its samples in the local metric frame of the field they were sampled from, not
/// on the globe, so each exporter takes that field to turn a position back into a coordinate.
public nonisolated enum TransectExporter {

    private static let csvHeader =
        "distance_meters,elevation_meters,along_track_slope_degrees,curvature_rad_per_meter,latitude,longitude"

    // MARK: GeoJSON

    /// A `FeatureCollection` holding the profile and its signatures.
    ///
    /// - The profile is one 3D `LineString` of `[longitude, latitude, elevationMeters]`. A void sample has no
    ///   elevation and is left out (the CSV keeps it), so a track with a void draws straight across it.
    /// - A platform mound is one `Point` at the middle of its extent, at the ground height there.
    /// - A ditch-and-berm chain is one `Point` per break (each ditch floor and berm crest), every one
    ///   carrying the whole chain of break distances.
    ///
    /// Each feature has a `type` property: `transectProfile`, `platformMound` or `ditchAndBerm`. Coordinates are
    /// rounded to 7 decimals (about 1 cm) and measurements to 3; a non-finite value is written as `null`, so
    /// the document is always valid JSON. `cut_fill_area_sq_meters` is the cut (above-baseline) area.
    ///
    /// - Throws: ``TransectExportError/noProfile`` when there is no line to draw.
    public static func exportGeoJSON(from analysis: TransectAnalysis, in field: some GeoreferencedElevationField) throws -> Data {
        var track: [[Double]] = []
        track.reserveCapacity(analysis.samples.count)
        for sample in analysis.samples where sample.elevation.isFinite {
            guard let c = coordinate(of: sample.position, in: field) else { continue }
            track.append([rounded(c.longitude, 7), rounded(c.latitude, 7), rounded(Double(sample.elevation), 3)])
        }
        guard track.count >= 2 else { throw TransectExportError.noProfile }

        let profile: [String: Any] = [
            "type": "Feature",
            "geometry": ["type": "LineString", "coordinates": track] as [String: Any],
            "properties": [
                "type": "transectProfile",
                "length_meters": number(Double(analysis.lengthMeters)),
                "step_meters": number(Double(analysis.stepDistance)),
                "valid_fraction": number(analysis.validFraction, places: 4),
            ] as [String: Any],
        ]
        var features = [profile]
        for signature in analysis.signatures {
            features += signatureFeatures(signature, in: analysis, field: field)
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func signatureFeatures(
        _ signature: TransectSignature, in analysis: TransectAnalysis, field: some GeoreferencedElevationField
    ) -> [[String: Any]] {
        var properties: [String: Any] = [
            "type": signature.kind.rawValue,
            "signature_id": signature.id,
            "relief_meters": number(Double(signature.reliefMeters)),
        ]
        let distances: [Float]
        switch signature.kind {
        case .platformMound:
            distances = [(signature.startDistance + signature.endDistance) / 2]
            properties["plateau_width_meters"] = signature.plateauWidthMeters.map { number(Double($0)) } ?? NSNull()
            properties["flank_slopes_degrees"] = signature.flankSlopesDegrees.map { number(Double($0)) }
            properties["cut_volume_cubic_meters"] = number(signature.estimatedVolumeCubicMeters)
            properties["cut_fill_area_sq_meters"] = number(signature.cutFillAreaSquareMeters.cut)
            properties["baseline_elevation_range"] = signature.baselineElevationRange
                .map { [number($0.lowerBound), number($0.upperBound)] } ?? NSNull()
        case .ditchAndBerm:
            distances = signature.breakDistances
            properties["break_distances_meters"] = signature.breakDistances.map { number(Double($0)) }
        }

        return distances.compactMap { distance -> [String: Any]? in
            guard let location = locate(distance, in: analysis),
                  let c = coordinate(of: location.position, in: field) else { return nil }
            var position = [rounded(c.longitude, 7), rounded(c.latitude, 7)]
            if location.elevation.isFinite { position.append(rounded(Double(location.elevation), 3)) }
            var own = properties
            own["distance_meters"] = number(Double(distance))
            return [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": position] as [String: Any],
                "properties": own,
            ]
        }
    }

    // MARK: CSV

    /// One row per sample, CRLF-terminated, under a header line:
    /// `distance_meters,elevation_meters,along_track_slope_degrees,curvature_rad_per_meter,latitude,longitude`.
    ///
    /// Curvature is the along-track d²z/dx² in 1/m, which is the turn in radians per metre on gentle ground.
    /// Elevation, slope and curvature are empty where they could not be measured (a void, or the
    /// neighbourhood of one); a row always keeps its distance and position. No cell is ever `NaN` text.
    public static func exportCSV(from analysis: TransectAnalysis, in field: some GeoreferencedElevationField) -> String {
        var csv = csvHeader + "\r\n"
        for sample in analysis.samples {
            let c = field.coordinate(for: sample.position)
            csv += [
                decimal(Double(sample.distance), "%.3f"),
                decimal(Double(sample.elevation), "%.3f"),
                decimal(Double(sample.slopeDegrees), "%.3f"),
                decimal(Double(sample.curvature), "%.6f"),
                decimal(c.latitude, "%.7f"),
                decimal(c.longitude, "%.7f"),
            ].joined(separator: ",")
            csv += "\r\n"
        }
        return csv
    }

    // MARK: Helpers

    /// Position and ground height `distance` metres along the transect. Samples sit at exact multiples of
    /// the step along a straight line, so linear interpolation between neighbours is exact.
    private static func locate(_ distance: Float, in analysis: TransectAnalysis) -> (position: SIMD2<Float>, elevation: Float)? {
        let samples = analysis.samples
        guard samples.count > 1, analysis.stepDistance > 0, distance.isFinite else { return nil }
        let index = min(max(distance / analysis.stepDistance, 0), Float(samples.count - 1))
        let lower = min(Int(index), samples.count - 2)
        let t = index - Float(lower)
        let a = samples[lower], b = samples[lower + 1]
        let elevation = a.elevation.isFinite && b.elevation.isFinite
            ? a.elevation + (b.elevation - a.elevation) * t
            : (t < 0.5 ? a.elevation : b.elevation)
        return (a.position + (b.position - a.position) * t, elevation)
    }

    private static func coordinate(of position: SIMD2<Float>, in field: some GeoreferencedElevationField) -> CLLocationCoordinate2D? {
        let c = field.coordinate(for: position)
        return c.latitude.isFinite && c.longitude.isFinite ? c : nil
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    /// A JSON number, or `null` when the value is not finite: `JSONSerialization` raises on NaN and infinity.
    private static func number(_ value: Double, places: Int = 3) -> Any {
        let r = rounded(value, places)
        return r.isFinite ? r : NSNull()
    }

    private static func decimal(_ value: Double, _ format: String) -> String {
        value.isFinite ? String(format: format, value) : ""
    }
}
