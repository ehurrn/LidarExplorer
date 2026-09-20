//
//  FieldMarkup.swift
//  LidarExplorer
//
//  A field notebook's data: waypoints and hand-drawn traces on the ground, and their GeoJSON export.
//  Pure Foundation and CoreLocation, so it compiles and is tested host-side; the Pencil capture that produces
//  traces lives in the map layer.
//

import CoreLocation
import Foundation

/// A latitude and longitude that can be stored: `CLLocationCoordinate2D` is not `Codable`.
public nonisolated struct FieldPosition: Sendable, Codable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether this is a place on Earth: both finite, latitude within ±90 and longitude within ±180.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// A point of interest the user marked: a possible feature, a photo position, a note to come back to.
public nonisolated struct FieldWaypoint: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var position: FieldPosition
    /// Ground elevation at the point when it was marked, if terrain was loaded there.
    public var elevationMeters: Float?
    public var title: String
    public var notes: String
    public var timestamp: Date
    /// A photo kept alongside, by file name.
    public var photoFilename: String?

    public var coordinate: CLLocationCoordinate2D { position.coordinate }

    public init(
        id: UUID = UUID(), coordinate: CLLocationCoordinate2D, elevationMeters: Float? = nil,
        title: String, notes: String = "", timestamp: Date = Date(), photoFilename: String? = nil
    ) {
        self.id = id
        self.position = FieldPosition(coordinate)
        self.elevationMeters = elevationMeters
        self.title = title
        self.notes = notes
        self.timestamp = timestamp
        self.photoFilename = photoFilename
    }
}

/// A line drawn over the map, held as ground coordinates so it stays put as the map moves.
public nonisolated struct FieldAnnotationTrace: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var positions: [FieldPosition]
    /// Stroke width in points, as drawn.
    public var strokeWidth: Double
    /// `#RRGGBB`, or `#RRGGBBAA` where the ink is translucent (a highlighter).
    public var colorHex: String

    public var coordinates: [CLLocationCoordinate2D] { positions.map(\.coordinate) }

    public init(id: UUID = UUID(), coordinates: [CLLocationCoordinate2D], strokeWidth: Double, colorHex: String) {
        self.id = id
        self.positions = coordinates.map(FieldPosition.init)
        self.strokeWidth = strokeWidth
        self.colorHex = colorHex
    }
}

public nonisolated enum FieldMarkupError: Error, Equatable, Sendable {
    /// A waypoint or trace vertex that is not a place on Earth.
    case invalidCoordinate(UUID)
    /// A trace with fewer than two positions is not a line.
    case traceTooShort(UUID)
    /// A colour that is not `#RRGGBB` or `#RRGGBBAA`.
    case invalidColor(UUID, String)
}

public nonisolated enum FieldMarkup {

    /// An RFC 7946 FeatureCollection: a `Point` per waypoint, then a `LineString` per trace, positions as
    /// `[longitude, latitude]` (and elevation in metres where it is known), styled with the simplestyle
    /// properties GIS tools read (`stroke`, `stroke-width`, `stroke-opacity`, `title`, `description`).
    ///
    /// Coordinates are rounded to seven places, a centimetre, and elevations to a millimetre. A value that is not
    /// a number is left out rather than written: `JSONSerialization` raises on NaN, so nothing here reaches it.
    public static func exportGeoJSON(waypoints: [FieldWaypoint], traces: [FieldAnnotationTrace]) throws -> Data {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime]
        time.timeZone = TimeZone(identifier: "UTC")

        var features: [[String: Any]] = []
        for waypoint in waypoints {
            guard waypoint.position.isValid else { throw FieldMarkupError.invalidCoordinate(waypoint.id) }
            var position = [rounded(waypoint.position.longitude, 7), rounded(waypoint.position.latitude, 7)]
            var properties: [String: Any] = [
                "title": waypoint.title, "description": waypoint.notes, "notes": waypoint.notes,
                "timestamp": time.string(from: waypoint.timestamp),
            ]
            if let elevation = waypoint.elevationMeters, elevation.isFinite {
                position.append(rounded(Double(elevation), 3))
                properties["elevation_meters"] = rounded(Double(elevation), 3)
            }
            if let photo = waypoint.photoFilename { properties["photo"] = photo }
            features.append([
                "type": "Feature", "id": waypoint.id.uuidString,
                "geometry": ["type": "Point", "coordinates": position] as [String: Any],
                "properties": properties,
            ])
        }
        for trace in traces {
            guard trace.positions.count >= 2 else { throw FieldMarkupError.traceTooShort(trace.id) }
            guard trace.positions.allSatisfy(\.isValid) else { throw FieldMarkupError.invalidCoordinate(trace.id) }
            guard let style = stroke(from: trace.colorHex) else { throw FieldMarkupError.invalidColor(trace.id, trace.colorHex) }
            var properties: [String: Any] = [
                "stroke": style.color,
                "stroke-width": rounded(trace.strokeWidth.isFinite && trace.strokeWidth > 0 ? trace.strokeWidth : 1, 2),
            ]
            if let opacity = style.opacity { properties["stroke-opacity"] = rounded(opacity, 3) }
            features.append([
                "type": "Feature", "id": trace.id.uuidString,
                "geometry": [
                    "type": "LineString",
                    "coordinates": trace.positions.map { [rounded($0.longitude, 7), rounded($0.latitude, 7)] },
                ] as [String: Any],
                "properties": properties,
            ])
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    /// `#RRGGBB` or `#RRGGBBAA` as the colour and, when translucent, its opacity; `nil` for anything else.
    private static func stroke(from hex: String) -> (color: String, opacity: Double?)? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        let color = "#" + digits.prefix(6).uppercased()
        guard digits.count == 8, let alpha = UInt8(digits.suffix(2), radix: 16), alpha < 255 else { return (color, nil) }
        return (color, Double(alpha) / 255)
    }
}
