//
//  UTMProjection.swift
//  LidarExplorer
//
//  Forward/inverse UTM projection, for reading rasters whose georeferencing
//  is native UTM rather than the Web Mercator this app otherwise standardises
//  on -- which is how USGS 3DEP ships its source COGs.
//

import Foundation

/// Forward and inverse Universal Transverse Mercator projection.
///
/// Uses the GRS80 ellipsoid (NAD83's reference ellipsoid); WGS84's differs by
/// under a millimetre in the defining parameters, which is far inside the
/// noise floor of a 1 m DEM, so one implementation serves both datums.
///
/// Snyder's closed-form transverse Mercator series (USGS Professional Paper
/// 1395, "Map Projections: A Working Manual"), truncated at the same order
/// libraries typically ship for a WGS84/GRS80-class ellipsoid: sub-millimetre
/// error across a UTM zone's 6 degree width.
public nonisolated enum UTMProjection {
    public enum Hemisphere: Sendable, Equatable {
        case north
        case south
    }

    private static let semiMajorAxis = 6_378_137.0
    private static let flattening = 1.0 / 298.257222101
    private static let k0 = 0.9996
    private static let falseEasting = 500_000.0
    private static let falseNorthing = 10_000_000.0

    /// Decodes a UTM zone and hemisphere from a projected CRS's EPSG code, for
    /// the two numbering schemes USGS data actually ships under: NAD83 UTM
    /// (26901...26923, zones 1N...23N) and WGS84 UTM (326xx north, 327xx
    /// south). Returns `nil` for any other CRS -- this does not attempt to be
    /// a general EPSG registry.
    public static func zone(forEPSG epsg: Int) -> (zone: Int, hemisphere: Hemisphere)? {
        switch epsg {
        case 26901...26923:
            return (epsg - 26900, .north)
        case 32601...32660:
            return (epsg - 32600, .north)
        case 32701...32760:
            return (epsg - 32700, .south)
        default:
            return nil
        }
    }

    /// Projects a geographic coordinate to UTM easting/northing metres.
    public static func forward(
        latitude: Double, longitude: Double, zone: Int, hemisphere: Hemisphere
    ) -> (easting: Double, northing: Double) {
        let a = semiMajorAxis
        let f = flattening
        let e2 = f * (2 - f)
        let ePrime2 = e2 / (1 - e2)

        let lat = latitude * .pi / 180
        let centralMeridian = Double(-183 + 6 * zone) * .pi / 180
        let lon = longitude * .pi / 180
        let dLon = lon - centralMeridian

        let sinLat = sin(lat), cosLat = cos(lat), tanLat = tan(lat)
        let n = a / sqrt(1 - e2 * sinLat * sinLat)
        let t = tanLat * tanLat
        let c = ePrime2 * cosLat * cosLat
        let aTerm = cosLat * dLon

        // Meridional arc length from the equator to `lat`.
        let m = a * (
            (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * pow(e2, 3) / 256) * lat
            - (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * pow(e2, 3) / 1024) * sin(2 * lat)
            + (15 * e2 * e2 / 256 + 45 * pow(e2, 3) / 1024) * sin(4 * lat)
            - (35 * pow(e2, 3) / 3072) * sin(6 * lat)
        )

        let easting = falseEasting + k0 * n * (
            aTerm
            + (1 - t + c) * pow(aTerm, 3) / 6
            + (5 - 18 * t + t * t + 72 * c - 58 * ePrime2) * pow(aTerm, 5) / 120
        )

        var northing = k0 * (
            m + n * tanLat * (
                aTerm * aTerm / 2
                + (5 - t + 9 * c + 4 * c * c) * pow(aTerm, 4) / 24
                + (61 - 58 * t + t * t + 600 * c - 330 * ePrime2) * pow(aTerm, 6) / 720
            )
        )
        if hemisphere == .south { northing += falseNorthing }
        return (easting, northing)
    }

    /// Inverse-projects UTM easting/northing back to a geographic coordinate.
    public static func inverse(
        easting: Double, northing: Double, zone: Int, hemisphere: Hemisphere
    ) -> (latitude: Double, longitude: Double) {
        let a = semiMajorAxis
        let f = flattening
        let e2 = f * (2 - f)
        let ePrime2 = e2 / (1 - e2)
        let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))

        let x = easting - falseEasting
        let y = hemisphere == .south ? northing - falseNorthing : northing

        let m = y / k0
        let mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * pow(e2, 3) / 256))

        let footprintLat = mu
            + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu)
            + (1097 * pow(e1, 4) / 512) * sin(8 * mu)

        let sinPhi1 = sin(footprintLat), cosPhi1 = cos(footprintLat), tanPhi1 = tan(footprintLat)
        let n1 = a / sqrt(1 - e2 * sinPhi1 * sinPhi1)
        let t1 = tanPhi1 * tanPhi1
        let c1 = ePrime2 * cosPhi1 * cosPhi1
        let r1 = a * (1 - e2) / pow(1 - e2 * sinPhi1 * sinPhi1, 1.5)
        let d = x / (n1 * k0)

        let lat = footprintLat - (n1 * tanPhi1 / r1) * (
            d * d / 2
            - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ePrime2) * pow(d, 4) / 24
            + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ePrime2 - 3 * c1 * c1) * pow(d, 6) / 720
        )

        let lon = (
            d
            - (1 + 2 * t1 + c1) * pow(d, 3) / 6
            + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ePrime2 + 24 * t1 * t1) * pow(d, 5) / 120
        ) / cosPhi1

        let centralMeridian = Double(-183 + 6 * zone) * .pi / 180
        return (lat * 180 / .pi, (centralMeridian + lon) * 180 / .pi)
    }
}
