//
//  MarkupChecks.swift
//  ViewerHarness
//
//  The field notebook: waypoints and drawn traces as data, their RFC 7946 export read back by an independent
//  parser, strokes turned into ground lines, and the viewer model's markup API.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit

@MainActor
func runMarkupChecks() async {
    print("\n=== Field markup ===")
    checkMarkupData()
    checkMarkupGeoJSON()
    checkStrokeGeoreferencing()
    // The model exports the notebook to the system's temporary directory, named to the second: one run at a time.
    await withSystemTemporaryDirectoryLock {
        await checkMarkupModel()
    }
}

// MARK: - Fixtures

private let markupTime = Date(timeIntervalSince1970: 1_800_000_000)      // 2027-01-15T08:00:00Z

private func waypointA() -> FieldWaypoint {
    FieldWaypoint(
        coordinate: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621), elevationMeters: 123.4567,
        title: "He said \"mound\" \\ 🏺", notes: "Line 1\nLine 2\ttab", timestamp: markupTime, photoFilename: "IMG_0042.jpg")
}

private func waypointB() -> FieldWaypoint {
    FieldWaypoint(coordinate: CLLocationCoordinate2D(latitude: 38.6, longitude: -90.1), title: "Bare", timestamp: markupTime)
}

private func penTrace() -> FieldAnnotationTrace {
    FieldAnnotationTrace(
        coordinates: [CLLocationCoordinate2D(latitude: 38.6550, longitude: -90.0620),
                      CLLocationCoordinate2D(latitude: 38.6551, longitude: -90.0618),
                      CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0617)],
        strokeWidth: 4.5, colorHex: "#FF3B30")
}

private func highlighterTrace() -> FieldAnnotationTrace {
    FieldAnnotationTrace(
        coordinates: [CLLocationCoordinate2D(latitude: 38.66, longitude: -90.07), CLLocationCoordinate2D(latitude: 38.661, longitude: -90.069)],
        strokeWidth: 18, colorHex: "#ffd60a80")
}

private func parse(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func features(_ data: Data) -> [[String: Any]] {
    (parse(data)?["features"] as? [[String: Any]]) ?? []
}

private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

private func fails(_ traces: [FieldAnnotationTrace] = [], _ waypoints: [FieldWaypoint] = []) -> FieldMarkupError? {
    do {
        _ = try FieldMarkup.exportGeoJSON(waypoints: waypoints, traces: traces)
        return nil
    } catch let error as FieldMarkupError {
        return error
    } catch {
        return nil
    }
}

// MARK: - M1. Data

@MainActor
private func checkMarkupData() {
    print("\n--- M1. the data ---")
    let waypoint = waypointA(), trace = penTrace()
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let waypointBack = (try? encoder.encode(waypoint)).flatMap { try? decoder.decode(FieldWaypoint.self, from: $0) }
    let traceBack = (try? encoder.encode(trace)).flatMap { try? decoder.decode(FieldAnnotationTrace.self, from: $0) }
    check("a waypoint and a trace survive being stored and read back, ids and every field",
          waypointBack == waypoint && traceBack == trace && waypointBack?.id == waypoint.id && traceBack?.coordinates.count == 3,
          "\(String(describing: waypointBack)) \(String(describing: traceBack))")
    check("a trace's coordinates are the ones it was made from",
          zip(trace.coordinates, penTrace().coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
          && trace.coordinates.count == 3 && waypoint.coordinate.latitude == 38.6553)
    let valid = [FieldPosition(latitude: 38, longitude: -90), FieldPosition(latitude: 90, longitude: 180), FieldPosition(latitude: -90, longitude: -180)]
    let invalid = [FieldPosition(latitude: .nan, longitude: 0), FieldPosition(latitude: 91, longitude: 0), FieldPosition(latitude: 0, longitude: -181),
                   FieldPosition(latitude: 0, longitude: .infinity)]
    check("only places on Earth are valid positions, the poles and the antimeridian included",
          valid.allSatisfy(\.isValid) && !invalid.contains { $0.isValid })
}

// MARK: - M2. GeoJSON

@MainActor
private func checkMarkupGeoJSON() {
    print("\n--- M2. GeoJSON export ---")
    let wpA = waypointA(), wpB = waypointB(), tracePen = penTrace(), traceHighlighter = highlighterTrace()
    guard let data = try? FieldMarkup.exportGeoJSON(
        waypoints: [wpA, wpB], traces: [tracePen, traceHighlighter]) else {
        check("markup exports", false, "threw")
        return
    }
    let root = parse(data)
    let all = features(data)
    check("the export is a FeatureCollection with one feature per item, waypoints first, and no crs member",
          root?["type"] as? String == "FeatureCollection" && all.count == 4 && root?["crs"] == nil
          && all.map({ ($0["geometry"] as? [String: Any])?["type"] as? String }) == ["Point", "Point", "LineString", "LineString"],
          "\(all.count) features")

    let a = all.first, b = all.dropFirst().first
    let aCoordinates = (a?["geometry"] as? [String: Any])?["coordinates"] as? [Double]
    check("a waypoint is [longitude, latitude, elevation], in that order, and without an elevation only two",
          aCoordinates == [-90.0621, 38.6553, 123.457]
          && ((b?["geometry"] as? [String: Any])?["coordinates"] as? [Double]) == [-90.1, 38.6],
          "\(String(describing: aCoordinates))")

    let properties = a?["properties"] as? [String: Any]
    check("a waypoint's properties carry its title, notes, ISO 8601 UTC time, elevation and photo, strings exactly",
          properties?["title"] as? String == "He said \"mound\" \\ 🏺" && properties?["notes"] as? String == "Line 1\nLine 2\ttab"
          && properties?["description"] as? String == "Line 1\nLine 2\ttab"
          && properties?["timestamp"] as? String == "2027-01-15T08:00:00Z"
          && number(properties?["elevation_meters"]) == 123.457 && properties?["photo"] as? String == "IMG_0042.jpg"
          && a?["id"] as? String == wpA.id.uuidString,
          "\(String(describing: properties))")
    let bareProperties = b?["properties"] as? [String: Any]
    check("absent values are absent, not null: no photo and no elevation on a bare waypoint",
          bareProperties?["photo"] == nil && bareProperties?["elevation_meters"] == nil && bareProperties?["title"] as? String == "Bare",
          "\(String(describing: bareProperties))")

    let line = all.dropFirst(2).first
    let lineCoordinates = (line?["geometry"] as? [String: Any])?["coordinates"] as? [[Double]]
    let lineProperties = line?["properties"] as? [String: Any]
    check("a trace is a LineString of [longitude, latitude] with simplestyle stroke, width and no opacity when opaque",
          lineCoordinates == [[-90.0620, 38.6550], [-90.0618, 38.6551], [-90.0617, 38.6553]]
          && lineProperties?["stroke"] as? String == "#FF3B30" && number(lineProperties?["stroke-width"]) == 4.5
          && lineProperties?["stroke-opacity"] == nil,
          "\(String(describing: lineCoordinates)) \(String(describing: lineProperties))")
    let highlighter = (all.last?["properties"] as? [String: Any])
    check("a translucent colour splits into stroke and stroke-opacity",
          highlighter?["stroke"] as? String == "#FFD60A" && abs((number(highlighter?["stroke-opacity"]) ?? 0) - 0.502) < 0.001,
          "\(String(describing: highlighter))")

    // An independent reader: MapKit's own GeoJSON decoder, which knows the standard's coordinate order.
    if let decoded = try? MKGeoJSONDecoder().decode(data), decoded.count == 4 {
        let shapes = decoded.compactMap { ($0 as? MKGeoJSONFeature)?.geometry.first }
        let point = shapes.first as? MKPointAnnotation
        var vertices = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: 3)
        if let polyline = shapes.dropFirst(2).first as? MKPolyline, polyline.pointCount == 3 {
            polyline.getCoordinates(&vertices, range: NSRange(location: 0, length: 3))
        }
        check("MapKit's GeoJSON decoder reads it: latitude and longitude land where they were drawn",
              shapes.count == 4 && abs((point?.coordinate.latitude ?? 0) - 38.6553) < 1e-9
              && abs((point?.coordinate.longitude ?? 0) + 90.0621) < 1e-9
              && abs(vertices[2].latitude - 38.6553) < 1e-9 && abs(vertices[2].longitude + 90.0617) < 1e-9,
              "\(shapes.count) shapes, point \(String(describing: point?.coordinate)), last vertex \(vertices[2])")
    } else {
        check("MapKit's GeoJSON decoder reads it: latitude and longitude land where they were drawn", false, "did not decode")
    }

    let empty = try? FieldMarkup.exportGeoJSON(waypoints: [], traces: [])
    check("nothing to export is still a valid, empty FeatureCollection",
          empty.flatMap(parse)?["type"] as? String == "FeatureCollection" && features(empty ?? Data()).isEmpty && (empty?.count ?? 0) > 20)
    check("the export is deterministic, byte for byte",
          (try? FieldMarkup.exportGeoJSON(waypoints: [wpA, wpB], traces: [tracePen]))
            == (try? FieldMarkup.exportGeoJSON(waypoints: [wpA, wpB], traces: [tracePen])) && !data.isEmpty)

    var badWaypoint = waypointA(); badWaypoint.position.latitude = .nan
    var farTrace = penTrace(); farTrace.positions[1].latitude = 91
    let oneVertex = FieldAnnotationTrace(coordinates: [CLLocationCoordinate2D(latitude: 1, longitude: 1)], strokeWidth: 3, colorHex: "#000000")
    let named = FieldAnnotationTrace(coordinates: penTrace().coordinates, strokeWidth: 3, colorHex: "red")
    check("a bad coordinate, a one-point line and a colour that is not hex are refused, naming the item",
          fails([], [badWaypoint]) == .invalidCoordinate(badWaypoint.id) && fails([farTrace]) == .invalidCoordinate(farTrace.id)
          && fails([oneVertex]) == .traceTooShort(oneVertex.id) && fails([named]) == .invalidColor(named.id, "red")
          && fails([penTrace()], [waypointA()]) == nil,
          "\(String(describing: fails([], [badWaypoint])))")
    // A width no pen has. It is finite, so it passes validation, but rounding it to two places multiplies by 100 and
    // overflows to infinity, which JSONSerialization answers with an Objective-C exception no Swift code can catch.
    func widthExported(_ width: Double) -> Double? {
        let trace = FieldAnnotationTrace(coordinates: penTrace().coordinates, strokeWidth: width, colorHex: "#FF3B30")
        return (try? FieldMarkup.exportGeoJSON(waypoints: [], traces: [trace])).map(features)?.first
            .flatMap { ($0["properties"] as? [String: Any])?["stroke-width"] as? Double }
    }
    let widths = [Double.greatestFiniteMagnitude, 1e308, 1e306, -1e308, .nan, .infinity, 0, -5, 1e-300, 4.5].map(widthExported)
    check("a stroke width outside any pen's range is clamped to 0.1...1000 and never reaches the JSON writer as infinity",
          widths.compactMap { $0 }.count == 10 && widths.compactMap({ $0 }).allSatisfy { $0 >= 0.1 && $0 <= 1000 }
          && widths[0] == 1000 && widths[9] == 4.5 && widths[8] == 0.1 && widths[4] == 1,
          "\(widths)")
    var nanElevation = waypointA(); nanElevation.elevationMeters = .nan
    let dropped = (try? FieldMarkup.exportGeoJSON(waypoints: [nanElevation], traces: [])).map(features)?.first
    check("a NaN elevation is left out rather than written, so the file stays valid JSON",
          ((dropped?["geometry"] as? [String: Any])?["coordinates"] as? [Double])?.count == 2
          && (dropped?["properties"] as? [String: Any])?["elevation_meters"] == nil)
}

// MARK: - M3. Strokes onto the ground

/// A pretend map: 0.5 m to the point, pixel (0, 0) at a fixed Web Mercator position.
private enum SyntheticMap {
    static let x0 = -10_014_000.0, y0 = 4_680_000.0, metersPerPoint = 0.5

    static func coordinate(_ p: CGPoint) -> CLLocationCoordinate2D {
        GeoRegion.fromMercatorMeters(x: x0 + Double(p.x) * metersPerPoint, y: y0 - Double(p.y) * metersPerPoint)
    }

    static func point(_ c: CLLocationCoordinate2D) -> CGPoint {
        let m = GeoRegion.toMercatorMeters(c)
        return CGPoint(x: (m.x - x0) / metersPerPoint, y: (y0 - m.y) / metersPerPoint)
    }
}

/// Distance from `p` to the segment `a`-`b`.
private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
    let length2 = dx * dx + dy * dy
    guard length2 > 0 else { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
    let t = min(max((Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / length2, 0), 1)
    return hypot(Double(p.x) - (Double(a.x) + t * dx), Double(p.y) - (Double(a.y) + t * dy))
}

@MainActor
private func checkStrokeGeoreferencing() {
    print("\n--- M3. strokes onto the ground ---")
    let wave = (0..<40).map { CGPoint(x: 100 + Double($0) * 6, y: 300 + 40 * sin(Double($0) * 0.4)) }
    if let full = StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#FF3B30", strokeWidth: 4, tolerance: 0, convert: SyntheticMap.coordinate) {
        let back = full.coordinates.map(SyntheticMap.point)
        let worst = zip(back, wave).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max() ?? .infinity
        check("every point of a stroke lands on the ground and maps back to its pixel within a micro-pixel",
              full.coordinates.count == 40 && worst < 1e-5 && full.colorHex == "#FF3B30" && full.strokeWidth == 4,
              "\(full.coordinates.count) points, worst \(worst) px")
    } else {
        check("every point of a stroke lands on the ground and maps back to its pixel within a micro-pixel", false, "nil trace")
    }

    let straight = (0..<200).map { CGPoint(x: 10 + Double($0), y: 50 + Double($0) * 0.5) }
    let reduced = StrokeGeoreferencer.simplify(straight, tolerance: 1.5)
    check("a straight stroke of 200 points reduces to its two ends",
          reduced.count == 2 && reduced.first == straight.first && reduced.last == straight.last, "\(reduced.count)")

    let arc = (0..<300).map { CGPoint(x: 200 + 100 * cos(Double($0) / 299 * .pi), y: 200 + 100 * sin(Double($0) / 299 * .pi)) }
    let simplified = StrokeGeoreferencer.simplify(arc, tolerance: 2)
    var withinTolerance = true
    for p in arc {
        let nearest = (0..<(simplified.count - 1)).map { distance(p, toSegment: simplified[$0], simplified[$0 + 1]) }.min() ?? .infinity
        if nearest > 2 + 1e-9 { withinTolerance = false }
    }
    var cursor = 0
    let subsequence = simplified.allSatisfy { kept in
        while cursor < arc.count, arc[cursor] != kept { cursor += 1 }
        defer { cursor += 1 }
        return cursor < arc.count
    }
    check("a semicircle keeps its shape to the tolerance with far fewer points, ends kept, in order",
          simplified.count > 4 && simplified.count < 60 && withinTolerance && subsequence
          && simplified.first == arc.first && simplified.last == arc.last,
          "\(simplified.count) of 300 points, within tolerance \(withinTolerance)")

    let single = StrokeGeoreferencer.trace(screenPoints: [CGPoint(x: 5, y: 5)], colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate)
    let still = StrokeGeoreferencer.trace(screenPoints: Array(repeating: CGPoint(x: 9, y: 9), count: 20), colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate)
    let none = StrokeGeoreferencer.trace(screenPoints: [], colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate)
    check("a dot, a stroke that never moved and an empty stroke are not lines, where a real stroke is",
          single == nil && still == nil && none == nil
          && StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate) != nil)

    var dirty = wave
    dirty[10] = CGPoint(x: CGFloat.nan, y: 5)
    dirty[11] = CGPoint(x: 3, y: CGFloat.infinity)
    let cleaned = StrokeGeoreferencer.trace(screenPoints: dirty, colorHex: "#00FF00", strokeWidth: 2, tolerance: 0, convert: SyntheticMap.coordinate)
    check("points that are not numbers are dropped and the rest of the stroke is kept",
          cleaned?.coordinates.count == 38 && cleaned?.coordinates.allSatisfy { FieldPosition($0).isValid } == true,
          "\(String(describing: cleaned?.coordinates.count))")

    // A map that cannot say what is under some points (off the world, or not yet laid out).
    let partial = StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#00FF00", strokeWidth: 2, tolerance: 0) { $0.x < 220 ? nil : SyntheticMap.coordinate($0) }
    let unmappable = StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#00FF00", strokeWidth: 2) { _ in nil }
    check("points the map cannot place are dropped, and a stroke it cannot place at all yields nothing",
          (partial?.coordinates.count ?? 0) >= 15 && (partial?.coordinates.count ?? 40) < 40 && unmappable == nil,
          "\(String(describing: partial?.coordinates.count))")
    // A pen held still while the stroke is sampled repeats points; none of them is a vertex.
    let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 30, y: 25), c = CGPoint(x: 60, y: 10)
    let repeated = StrokeGeoreferencer.trace(
        screenPoints: [a, a, a, b, b, c, c], colorHex: "#000000", strokeWidth: 1, tolerance: 0, convert: SyntheticMap.coordinate)
    check("points repeated while the pen is held still collapse to one vertex each",
          repeated?.coordinates.count == 3, "\(String(describing: repeated?.coordinates.count))")
    let first = StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate)
    let second = StrokeGeoreferencer.trace(screenPoints: wave, colorHex: "#000000", strokeWidth: 1, convert: SyntheticMap.coordinate)
    check("each stroke gets an identity of its own", first != nil && first?.id != second?.id)
}

// MARK: - M4. The model

@MainActor
private func checkMarkupModel() async {
    print("\n--- M4. the viewer model ---")
    let model = TerrainViewerModel()
    let wave = (0..<30).map { CGPoint(x: 100 + Double($0) * 5, y: 300 + 30 * sin(Double($0) * 0.5)) }

    let withoutMap = model.addFieldTrace(screenPoints: wave, colorHex: "#FF3B30", strokeWidth: 4)
    let unchanged = model.fieldTraces.isEmpty && model.markupVersion == 0 && !model.hasFieldMarkup

    model.markupCoordinateConverter = SyntheticMap.coordinate
    let added = model.addFieldTrace(screenPoints: wave, colorHex: "#FF3B30", strokeWidth: 4)
    check("with no map to place it on a stroke is refused and nothing changes, where with one it is taken",
          !withoutMap && unchanged && added)
    check("a stroke drawn on the map becomes a georeferenced trace, and the map is told once",
          added && model.fieldTraces.count == 1 && model.markupVersion == 1 && model.hasFieldMarkup
          && model.fieldTraces[0].positions.allSatisfy(\.isValid) && model.fieldTraces[0].colorHex == "#FF3B30",
          "\(added), \(model.fieldTraces.count) traces, version \(model.markupVersion)")
    let dot = model.addFieldTrace(screenPoints: [CGPoint(x: 1, y: 1)], colorHex: "#FF3B30", strokeWidth: 4)
    check("a dot is not kept", !dot && model.fieldTraces.count == 1 && model.markupVersion == 1)

    // A waypoint takes the ground's height from the terrain already drawn there.
    let region = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 65490, y: 100500, z: 18, contentScaleFactor: 1))
    let provider = TerrainTileProvider(elevation: CountingElevationStub(), gridCache: TileDiskCache(directory: makeCacheDir()))
    _ = await provider.tileImage(x: 65490, y: 100500, z: 18, region: region, pixels: 256)
    let terrainModel = TerrainViewerModel(terrainProvider: provider)
    let expected = await provider.elevation(at: region.center)
    await terrainModel.addFieldWaypoint(at: region.center, title: "Mound?", notes: "east flank")
    await model.addFieldWaypoint(at: CLLocationCoordinate2D(latitude: 10, longitude: 10), title: "Nowhere", notes: "")
    check("a waypoint records the elevation under it where terrain is loaded, and none where it is not",
          terrainModel.fieldWaypoints.count == 1 && expected != nil && terrainModel.fieldWaypoints[0].elevationMeters == expected
          && terrainModel.fieldWaypoints[0].title == "Mound?" && model.fieldWaypoints.count == 1
          && model.fieldWaypoints[0].elevationMeters == nil && model.markupVersion == 2,
          "\(String(describing: terrainModel.fieldWaypoints.first?.elevationMeters)) vs \(String(describing: expected))")

    model.undoFieldMarkup()
    let afterFirstUndo = (model.fieldWaypoints.count, model.fieldTraces.count)
    model.undoFieldMarkup()
    let afterSecondUndo = (model.fieldWaypoints.count, model.fieldTraces.count)
    let versionBeforeEmptyUndo = model.markupVersion
    model.undoFieldMarkup()
    check("undo removes the newest item first, and on nothing does nothing",
          afterFirstUndo == (0, 1) && afterSecondUndo == (0, 0) && model.markupVersion == versionBeforeEmptyUndo && versionBeforeEmptyUndo == 4,
          "\(afterFirstUndo) \(afterSecondUndo), version \(model.markupVersion)")

    // Files.
    let emptyExport = try? await model.exportFieldMarkup()
    model.addFieldTrace(screenPoints: wave, colorHex: "#FF3B30", strokeWidth: 4)
    await model.addFieldWaypoint(at: CLLocationCoordinate2D(latitude: 38.66, longitude: -90.06), title: "Pit", notes: "looter?")
    if let url = try? await model.exportFieldMarkup() {
        let contents = (try? Data(contentsOf: url)).map(features) ?? []
        let pattern = #"^LidarExplorer_Markup_\d{8}-\d{6}\.geojson$"#
        check("an empty notebook cannot be exported; a full one is a .geojson file named for its content and the time, holding every item",
              emptyExport == nil && url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil && contents.count == 2
              && contents.map({ ($0["geometry"] as? [String: Any])?["type"] as? String }) == ["Point", "LineString"],
              "\(url.lastPathComponent), \(contents.count) features")
    } else {
        check("the export is a .geojson file, named for its content and the time, holding every item", false, "threw")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 15, second: 30))!
    check("the file name pattern is LidarExplorer_Markup_<stamp>.geojson",
          ExportFileName.markup(date: date, timeZone: TimeZone(identifier: "UTC")!) == "LidarExplorer_Markup_20260920-141530.geojson",
          ExportFileName.markup(date: date, timeZone: TimeZone(identifier: "UTC")!))

    model.showsExportSheet = false
    model.exportURL = nil
    await model.shareFieldMarkup()
    let shared = (model.showsExportSheet, model.exportURL != nil, model.exportErrorMessage == nil)
    let versionBeforeClear = model.markupVersion
    model.clearFieldMarkup()
    let versionAfterClear = model.markupVersion
    model.clearFieldMarkup()
    model.showsExportSheet = false
    await model.shareFieldMarkup()
    check("sharing presents the file; clearing empties the notebook once; sharing nothing explains why",
          shared == (true, true, true) && !model.hasFieldMarkup && versionAfterClear == versionBeforeClear + 1
          && model.markupVersion == versionAfterClear
          && model.exportErrorMessage?.contains("no markup") == true && !model.showsExportSheet,
          "\(shared), \(String(describing: model.exportErrorMessage))")
}
