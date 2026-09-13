//
//  SoilSurvey.swift
//  LidarExplorer
//
//  SSURGO map units, their geomorphic classification, and polygon geometry.
//

import CoreLocation
import Foundation
import simd

public nonisolated enum SoilClass: String, Sendable, CaseIterable {
    /// Poorly drained clays: backswamps, oxbow and clay plugs.
    case hydricClay
    /// Well-drained sands and sandy loams: natural levees, point bars.
    case wellDrainedSandyLoam
    case other
}

public nonisolated struct SoilMapUnit: Sendable, Equatable, Hashable {
    public let mukey: String
    public let name: String
    public let drainageClass: String?
    public let hydricPercent: Int?

    public init(mukey: String, name: String, drainageClass: String?, hydricPercent: Int?) {
        self.mukey = mukey
        self.name = name
        self.drainageClass = drainageClass
        self.hydricPercent = hydricPercent
    }

    public var soilClass: SoilClass {
        SoilClassifier.classify(name: name, drainageClass: drainageClass, hydricPercent: hydricPercent)
    }
}

public nonisolated enum SoilClassifier {
    static let textures = [
        "loamy very fine sand", "very fine sandy loam", "silty clay loam", "sandy clay loam", "loamy fine sand",
        "fine sandy loam", "silty clay", "sandy clay", "loamy sand", "sandy loam", "clay loam", "fine sand",
        "silt loam", "clay", "loam", "sand",
    ].sorted { $0.count > $1.count }
    static let clayey: Set<String> = ["clay", "silty clay", "sandy clay", "silty clay loam", "clay loam"]
    static let wellDrained: Set<String> = ["well drained", "moderately well drained", "somewhat excessively drained", "excessively drained"]
    static let poorlyDrained: Set<String> = ["poorly drained", "very poorly drained"]

    public static func texture(inName name: String) -> String? {
        let head = name.lowercased().split(separator: ",").first.map(String.init) ?? ""
        return textures.first { head.contains($0) }
    }

    public static func classify(name: String, drainageClass: String?, hydricPercent: Int?) -> SoilClass {
        let texture = texture(inName: name)
        let drainage = drainageClass?.lowercased()
        let hydric = (hydricPercent ?? 0) >= 66 || (drainage.map { poorlyDrained.contains($0) } ?? false)
        if hydric, let texture, clayey.contains(texture) { return .hydricClay }
        if !hydric, let texture, texture.contains("sand"), let drainage, wellDrained.contains(drainage) {
            return .wellDrainedSandyLoam
        }
        return .other
    }
}

/// One map unit's geometry: polygons as rings of (longitude, latitude), exterior first.
public nonisolated struct SoilPolygon: Sendable {
    public let unit: SoilMapUnit
    public let parts: [[[SIMD2<Double>]]]
    public let bounds: GeoRegion

    public init?(unit: SoilMapUnit, parts: [[[SIMD2<Double>]]]) {
        let points = parts.flatMap { $0.flatMap { $0 } }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        self.unit = unit
        self.parts = parts
        self.bounds = GeoRegion(minLatitude: minY, maxLatitude: maxY, minLongitude: minX, maxLongitude: maxX)
    }

    public func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard bounds.contains(coordinate) else { return false }
        let p = SIMD2(coordinate.longitude, coordinate.latitude)
        for polygon in parts {
            guard let exterior = polygon.first, Self.ringContains(exterior, p) else { continue }
            if !polygon.dropFirst().contains(where: { Self.ringContains($0, p) }) { return true }
        }
        return false
    }

    /// Even-odd ray casting.
    static func ringContains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

public nonisolated struct SoilSurvey: Sendable {
    public let polygons: [SoilPolygon]

    public init(polygons: [SoilPolygon]) {
        self.polygons = polygons
    }

    public func polygons(intersecting region: GeoRegion) -> [SoilPolygon] {
        polygons.filter {
            $0.bounds.minLatitude <= region.maxLatitude && $0.bounds.maxLatitude >= region.minLatitude
                && $0.bounds.minLongitude <= region.maxLongitude && $0.bounds.maxLongitude >= region.minLongitude
        }
    }

    public func unit(at coordinate: CLLocationCoordinate2D) -> SoilMapUnit? {
        polygons.first { $0.contains(coordinate) }?.unit
    }
}

public nonisolated enum WKTPolygonParser {
    /// `POLYGON` / `MULTIPOLYGON` text as polygons of rings of (x, y) = (longitude, latitude). Nil for other types.
    public static func polygons(_ wkt: String) -> [[[SIMD2<Double>]]]? {
        let text = wkt.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        let isMulti = upper.hasPrefix("MULTIPOLYGON")
        guard isMulti || upper.hasPrefix("POLYGON"), let open = text.firstIndex(of: "(") else { return nil }
        let ringDepth = isMulti ? 3 : 2
        var polygons: [[[SIMD2<Double>]]] = []
        var rings: [[SIMD2<Double>]] = []
        var ring: [SIMD2<Double>] = []
        var pair: [Double] = []
        var number = ""
        var depth = 0

        func flushNumber() {
            if let v = Double(number) { pair.append(v) }
            number = ""
        }
        func flushPair() {
            flushNumber()
            if pair.count >= 2 { ring.append(SIMD2(pair[0], pair[1])) }
            pair = []
        }

        for character in text[open...] {
            switch character {
            case "(":
                depth += 1
            case ")":
                if depth == ringDepth {
                    flushPair()
                    if ring.count >= 4 { rings.append(ring) }
                    ring = []
                } else if depth == ringDepth - 1 {
                    if !rings.isEmpty { polygons.append(rings) }
                    rings = []
                }
                depth -= 1
            case ",":
                if depth == ringDepth { flushPair() }
            case " ", "\t", "\n", "\r":
                if depth == ringDepth { flushNumber() }
            default:
                if depth == ringDepth { number.append(character) }
            }
        }
        return polygons.isEmpty ? nil : polygons
    }
}

public nonisolated enum SoilGeoJSON {
    public enum ParseError: Error { case notAFeatureCollection }

    /// Features carrying `mukey`, `muname`, `drclassdcd`, `hydclprs` with Polygon or MultiPolygon geometry.
    public static func polygons(from data: Data) throws -> [SoilPolygon] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else { throw ParseError.notAFeatureCollection }

        func ring(_ any: Any) -> [SIMD2<Double>]? {
            (any as? [[Double]])?.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        }
        return features.compactMap { feature -> SoilPolygon? in
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any]
            else { return nil }
            let hydric = (properties["hydclprs"] as? NSNumber)?.intValue ?? (properties["hydclprs"] as? String).flatMap { Int($0) }
            let unit = SoilMapUnit(
                mukey: (properties["mukey"] as? String) ?? (properties["mukey"] as? NSNumber)?.stringValue ?? "",
                name: properties["muname"] as? String ?? "",
                drainageClass: properties["drclassdcd"] as? String,
                hydricPercent: hydric
            )
            switch type {
            case "Polygon":
                return SoilPolygon(unit: unit, parts: [coordinates.compactMap(ring)])
            case "MultiPolygon":
                return SoilPolygon(unit: unit, parts: coordinates.map { (($0 as? [Any]) ?? []).compactMap(ring) }.filter { !$0.isEmpty })
            default:
                return nil
            }
        }
    }
}
