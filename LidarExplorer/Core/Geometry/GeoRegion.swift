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
    public var cacheKey: String {
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

// MARK: - Morton spatial key

/// A 64-bit spatial key for a region's south-west origin at one zoom level.
///
/// ## Why a Morton key
///
/// Spatial indexes want nearby regions to land near each other in the key
/// space so a sort clusters neighbours. Interleaving the bits of the two
/// quantised coordinates — a Morton / Z-order code — does exactly that while
/// staying a pure `UInt64` that hashes and compares in one instruction.
///
/// ## Layout
///
/// Each coordinate of the south-west origin is quantised to 29 bits (about
/// 3.7 cm of latitude, 7.5 cm of longitude at the equator).
/// ``dilate32To64(_:)`` spreads all 32 input bits onto the even positions of a
/// `UInt64` — its first stage moves the high 16 bits up to bit 32 rather than
/// discarding them, which is what a 16-bit-only dilation got wrong and why it
/// collided above bit 16. Latitude takes the odd positions, longitude the even,
/// so the 58 low bits hold every quantised bit exactly once and the zoom fills
/// the top 6: two origins at the same zoom share a key only if they quantise to
/// the same cell.
///
/// The whole construction is arithmetic on stack `UInt64`s: no heap
/// allocation, no string formatting, `@inlinable` end to end.
///
/// ## Identity: origin and zoom, not span
///
/// The region's north and east bounds are not part of the key, so regions with
/// the same origin and zoom share one whatever their span. For a tile's own
/// extent that is exact at every zoom the app serves (up to 21), because origin
/// and zoom fix the extent. Any other region, such as the 3DEP elevation
/// cache's, must key on ``GeoRegion/cacheKey``, whose four bounds do tell spans
/// apart (to 1e-6 degrees). All 64 bits are in use, so folding span in would
/// mean a wider key or coarser origin quantisation.
public nonisolated struct GeoTileKey: Hashable, Sendable, Codable {
    /// The 64-bit packed value:
    /// - Bits 58..63 (6 bits): Zoom level (0..63)
    /// - Bits 0..57 (58 bits): Interleaved 29-bit latitude and 29-bit longitude Morton code.
    public let packedValue: UInt64

    /// The zoom level encoded in the top 6 bits of `packedValue`.
    public var zoom: Int {
        Int((packedValue >> 58) & 0x3F)
    }

    /// Hex cache key for disk persistence.
    public var cacheKey: String {
        String(format: "%016llx", packedValue)
    }

    /// Quantises a region's south-west origin and zoom level into a 64-bit key.
    ///
    /// The top 6 bits store the zoom level (`zoom & 0x3F`). The lower 58 bits
    /// store a Morton-interleaved code of 29-bit latitude and 29-bit longitude.
    @inlinable
    public init(region: GeoRegion, zoom: Int) {
        let latClamped = min(max(region.minLatitude, -90.0), 90.0)
        let lonClamped = min(max(region.minLongitude, -180.0), 180.0)

        let max29: Double = 536_870_911.0
        let lat = UInt32(clamping: Int(((latClamped + 90.0) / 180.0 * max29).rounded()))
        let lon = UInt32(clamping: Int(((lonClamped + 180.0) / 360.0 * max29).rounded()))
        let interleaved58 = (Self.dilate32To64(lat) << 1) | Self.dilate32To64(lon)
        let zoomBits = UInt64(zoom & 0x3F) << 58
        self.packedValue = zoomBits | (interleaved58 & 0x03FF_FFFF_FFFF_FFFF)
    }

    /// Constructs a key directly from a packed value (e.g. when decoding).
    @inlinable
    public init(packedValue: UInt64) {
        self.packedValue = packedValue
    }

    /// Dilation of a 32-bit integer across 64 bits with 1-bit gaps.
    @inlinable
    public static func dilate32To64(_ val: UInt32) -> UInt64 {
        var x = UInt64(val) & 0x0000_0000_FFFF_FFFF
        x = (x | (x << 16)) & 0x0000_FFFF_0000_FFFF
        x = (x | (x << 8))  & 0x00FF_00FF_00FF_00FF
        x = (x | (x << 4))  & 0x0F0F_0F0F_0F0F_0F0F
        x = (x | (x << 2))  & 0x3333_3333_3333_3333
        x = (x | (x << 1))  & 0x5555_5555_5555_5555
        return x
    }
}
