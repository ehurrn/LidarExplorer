//
//  ThalwegBuilder.swift
//  LidarExplorer
//
//  Turns a hand-drawn river line into a water-surface profile.
//

import CoreLocation
import Foundation

public nonisolated enum ThalwegBuilder {
    /// Densifies `drawn` to `spacingMeters`, takes each vertex's water surface as
    /// the lowest ground within `snapRadiusMeters` (hydro-flattened 3DEP water reads
    /// as the channel floor), then forces the surface to fall monotonically toward
    /// the lower end, which strips bank, bridge and levee hits.
    public static func build(
        drawn: [CLLocationCoordinate2D],
        spacingMeters: Double = 15,
        snapRadiusMeters: Double = 6,
        maximumPoints: Int = 256,
        elevation: (CLLocationCoordinate2D) -> Float?
    ) -> [ThalwegPoint] {
        guard drawn.count >= 2, maximumPoints >= 2 else { return [] }
        var lengths: [Double] = [0]
        for i in 1..<drawn.count { lengths.append(lengths[i - 1] + Geodesy.distance(from: drawn[i - 1], to: drawn[i])) }
        guard let total = lengths.last, total > 0 else { return [] }
        let spacing = max(spacingMeters, total / Double(maximumPoints - 1))

        var vertices: [CLLocationCoordinate2D] = []
        var segment = 0
        for s in stride(from: 0.0, through: total, by: spacing) {
            while segment < drawn.count - 2, lengths[segment + 1] < s { segment += 1 }
            let span = lengths[segment + 1] - lengths[segment]
            let t = span > 0 ? (s - lengths[segment]) / span : 0
            let a = drawn[segment], b = drawn[segment + 1]
            vertices.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * t))
        }
        if let lastDrawn = drawn.last, let lastVertex = vertices.last {
            if Geodesy.distance(from: lastVertex, to: lastDrawn) > 1e-3 {
                vertices.append(lastDrawn)
            }
        }

        var surfaces: [(CLLocationCoordinate2D, Float)] = []
        for v in vertices {
            let dLat = snapRadiusMeters / GeoRegion.metersPerDegreeLatitude
            let dLon = snapRadiusMeters / (GeoRegion.metersPerDegreeLatitude * cos(v.latitude * .pi / 180))
            var lowest: Float?
            for j in -2...2 {
                for i in -2...2 {
                    let probe = CLLocationCoordinate2D(latitude: v.latitude + dLat * Double(j) / 2,
                                                       longitude: v.longitude + dLon * Double(i) / 2)
                    if let z = elevation(probe) { lowest = min(lowest ?? z, z) }
                }
            }
            if let lowest { surfaces.append((v, lowest)) }
        }
        guard surfaces.count >= 2, let first = surfaces.first?.1, let last = surfaces.last?.1 else { return [] }

        var values = surfaces.map(\.1)
        if first >= last {
            for i in 1..<values.count { values[i] = min(values[i], values[i - 1]) }
        } else {
            for i in stride(from: values.count - 2, through: 0, by: -1) { values[i] = min(values[i], values[i + 1]) }
        }
        return zip(surfaces, values).map { entry, surface in
            ThalwegPoint(latitude: entry.0.latitude, longitude: entry.0.longitude, waterSurface: surface)
        }
    }
}
