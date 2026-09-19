//
//  GeoRegion.swift
//  LidarExplorer
//
//  MapKit-independent geographic primitives.
//

import CoreLocation

/// A geographic bounding box in WGS-84 degrees.
///
/// Deliberately independent of `MKCoordinateRegion` so the analysis and
/// geospatial layers can be exercised without MapKit — and without the
/// `@MainActor` isolation MapKit types carry. Bridging lives in the map layer.
public nonisolated struct GeoRegion: Sendable, Equatable, Hashable, Codable {

    /// Southern edge, degrees latitude. Always <= `maxLatitude`.
    public let minLatitude: Double
    /// Northern edge, degrees latitude.
    public let maxLatitude: Double
    /// Western edge, degrees longitude. Always <= `maxLongitude`.
    public let minLongitude: Double
    /// Eastern edge, degrees longitude.
    public let maxLongitude: Double

    /// Creates a region, normalising inverted bounds rather than trapping.
    public init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double
    ) {
        self.minLatitude = min(minLatitude, maxLatitude)
        self.maxLatitude = max(minLatitude, maxLatitude)
        self.minLongitude = min(minLongitude, maxLongitude)
        self.maxLongitude = max(minLongitude, maxLongitude)
    }

    /// Creates a region centred on a coordinate with the given angular spans.
    public init(
        center: CLLocationCoordinate2D,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) {
        self.init(
            minLatitude: center.latitude - latitudeSpan / 2,
            maxLatitude: center.latitude + latitudeSpan / 2,
            minLongitude: center.longitude - longitudeSpan / 2,
            maxLongitude: center.longitude + longitudeSpan / 2
        )
    }

    // MARK: - Derived geometry

    public var centerLatitude: Double { (minLatitude + maxLatitude) / 2 }
    public var centerLongitude: Double { (minLongitude + maxLongitude) / 2 }

    public var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }

    /// Metres per degree of latitude. Constant to within 1% across the globe.
    public static let metersPerDegreeLatitude: Double = 111_132.0

    /// Metres per degree of longitude at this region's centre latitude.
    ///
    /// Longitude convergence matters: at 45°N a degree of longitude is ~78 km,
    /// not 111 km. Ignoring this skews every distance and area computed from
    /// grid indices — the single most common source of geospatial error.
    public var metersPerDegreeLongitude: Double {
        Self.metersPerDegreeLatitude * cos(centerLatitude * .pi / 180)
    }

    /// North–south extent in metres.
    public var heightMeters: Double {
        latitudeSpan * Self.metersPerDegreeLatitude
    }

    /// East–west extent in metres at the centre latitude.
    public var widthMeters: Double {
        longitudeSpan * metersPerDegreeLongitude
    }

    /// Radius in metres of a circle enclosing the region.
    public var enclosingRadiusMeters: Double {
        (heightMeters * heightMeters + widthMeters * widthMeters).squareRoot() / 2
    }

    public func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLatitude && coordinate.latitude <= maxLatitude
            && coordinate.longitude >= minLongitude && coordinate.longitude <= maxLongitude
    }

    /// Expands the region by a metric buffer on all sides.
    public func expanded(byMeters meters: Double) -> GeoRegion {
        let dLat = meters / Self.metersPerDegreeLatitude
        let perDegLon = metersPerDegreeLongitude
        // Guard polar singularity and bound angular expansion
        let dLon = perDegLon > 1 ? min(meters / perDegLon, 180.0) : 0
        return GeoRegion(
            minLatitude: max(minLatitude - dLat, -90.0),
            maxLatitude: min(maxLatitude + dLat, 90.0),
            minLongitude: max(minLongitude - dLon, -180.0),
            maxLongitude: min(maxLongitude + dLon, 180.0)
        )
    }

    /// A stable key for caching, quantised to ~0.11 m at the equator.
    ///
    /// A region with a NaN or infinite bound cannot be quantised (`Int(_:)` traps on
    /// both), so it gets the constant `"invalid_region"` instead.
    public var cacheKey: String {
        guard minLatitude.isFinite, maxLatitude.isFinite,
              minLongitude.isFinite, maxLongitude.isFinite else {
            return "invalid_region"
        }
        let lat0 = Int((minLatitude * 1_000_000).rounded())
        let lon0 = Int((minLongitude * 1_000_000).rounded())
        let lat1 = Int((maxLatitude * 1_000_000).rounded())
        let lon1 = Int((maxLongitude * 1_000_000).rounded())

        // Stack-allocated buffer avoids dynamic Swift String interpolation heap allocs
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buf in
            guard let base = buf.baseAddress else {
                return "\(lat0),\(lon0),\(lat1),\(lon1)"
            }
            var idx = 0
            func appendInt(_ value: Int) {
                var v = value
                if v < 0 {
                    base[idx] = 45 // '-'
                    idx += 1
                    v = -v
                }
                if v == 0 {
                    base[idx] = 48 // '0'
                    idx += 1
                    return
                }
                let start = idx
                while v > 0 {
                    base[idx] = UInt8(48 + (v % 10))
                    idx += 1
                    v /= 10
                }
                var left = start
                var right = idx - 1
                while left < right {
                    let tmp = base[left]
                    base[left] = base[right]
                    base[right] = tmp
                    left += 1
                    right -= 1
                }
            }
            appendInt(lat0)
            base[idx] = 44 // ','
            idx += 1
            appendInt(lon0)
            base[idx] = 44
            idx += 1
            appendInt(lat1)
            base[idx] = 44
            idx += 1
            appendInt(lon1)
            return String(decoding: UnsafeBufferPointer(start: base, count: idx), as: UTF8.self)
        }
    }

    // MARK: - Web Mercator (EPSG:3857) Projection

    public static let maxMercatorLatitude: Double = 85.05112878

    /// Converts WGS-84 coordinate to Web Mercator projected metres (EPSG:3857).
    public static func toMercatorMeters(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let clampedLat = min(max(coordinate.latitude, -maxMercatorLatitude), maxMercatorLatitude)
        let r = 6378137.0
        let x = coordinate.longitude * .pi / 180.0 * r
        let latRad = clampedLat * .pi / 180.0
        let y = log(tan(.pi / 4.0 + latRad / 2.0)) * r
        return (x, y)
    }

    /// Converts Web Mercator projected metres (EPSG:3857) to WGS-84 coordinate.
    public static func fromMercatorMeters(x: Double, y: Double) -> CLLocationCoordinate2D {
        let r = 6378137.0
        let lon = (x / r) * 180.0 / .pi
        let lat = (2.0 * atan(exp(y / r)) - .pi / 2.0) * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Extents in Web Mercator metres (EPSG:3857).
    public var mercatorBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let sw = Self.toMercatorMeters(CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude))
        let ne = Self.toMercatorMeters(CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude))
        return (minX: min(sw.x, ne.x), minY: min(sw.y, ne.y), maxX: max(sw.x, ne.x), maxY: max(sw.y, ne.y))
    }
}

// MARK: - Distance

public nonisolated enum Geodesy {

    /// Great-circle distance in metres between two coordinates.
    ///
    /// Haversine on a spherical Earth: sub-0.5% error, which is far below the
    /// resolution of any DEM this app consumes, and it avoids constructing
    /// `CLLocation` objects in tight detection loops.
    public static func distance(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180

        let sinDPhi = sin(dPhi / 2)
        let sinDLambda = sin(dLambda / 2)
        let h = sinDPhi * sinDPhi + cos(phi1) * cos(phi2) * sinDLambda * sinDLambda
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing in degrees (0 = north, clockwise) from `a` to `b`.
    public static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
