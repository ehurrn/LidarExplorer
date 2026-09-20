//
//  TransectChecks.swift
//  ViewerHarness
//
//  1D transect sampling, derivatives and earthwork signature detection.
//

import CoreLocation
import Foundation
import simd

/// A 200 m x 6 m strip at 0.5 m cells whose elevation is `profile(x metres)`.
func profileStrip(_ profile: (Float) -> Float) -> ElevationGrid {
    sceneGrid(width: 400, height: 12, gsd: 0.5) { x, _ in profile(Float(x) * 0.5) }
}

/// Plain, a 25 degree flank, a flat top `plateau` metres wide `height` metres
/// up, and a matching falling flank.
func moundProfile(plateau: Float, height: Float = 2.8, flankDegrees: Float = 25) -> (Float) -> Float {
    let run = height / tan(flankDegrees * .pi / 180)
    let rise0: Float = 60, top0 = rise0 + run, top1 = top0 + plateau, fall1 = top1 + run
    return { x in
        if x < rise0 || x > fall1 { return 100 }
        if x < top0 { return 100 + (x - rise0) / run * height }
        if x <= top1 { return 100 + height }
        return 100 + (fall1 - x) / run * height
    }
}

@MainActor
func runTransectChecks() async {
    print("\n=== Elevation transect engine (sampling, derivatives, signatures) ===")

    // --- Uniform bilinear sampling on a known plane.
    let plane = profileStrip { 100 + 0.1 * $0 }
    let planeField = GridElevationField(grid: plane)
    let engine = ElevationTransectEngine(field: planeField)
    let y = Float(plane.height - 1 - 6) * Float(plane.metersPerRow)
    let samples = engine.sampleProfile(from: SIMD2(10, y), to: SIMD2(60, y), stepDistance: 0.5)
    check("a 50 m transect at 0.5 m yields 101 uniform samples",
          samples.count == 101 && abs(samples[1].distance - 0.5) < 1e-5 && abs(samples[100].distance - 50) < 1e-3,
          "\(samples.count)")
    let planeError = samples.map { abs($0.elevation - (100 + 0.1 * $0.position.x)) }.max() ?? .infinity
    check("bilinear samples reproduce a plane exactly (< 1 mm)", planeError < 0.001, "\(planeError)")
    let interiorSlope = samples[10...90].map(\.slopeDegrees)
    check("along-track slope of a 10% grade reads 5.71 degrees",
          interiorSlope.allSatisfy { abs($0 - 5.7106) < 0.02 }, "\(interiorSlope.first ?? .nan)")
    check("a plane has zero curvature", samples[10...90].allSatisfy { abs($0.curvature) < 1e-3 })

    let diagonal = engine.sampleProfile(from: SIMD2(5, 0.5), to: SIMD2(35, 4.5), stepDistance: 0.5)
    let diagonalLength = simd_length(SIMD2<Float>(30, 4))
    check("sample spacing is Euclidean along a diagonal",
          abs((diagonal.last?.distance ?? 0) - (diagonalLength / 0.5).rounded(.down) * 0.5) < 1e-3, "\(diagonal.count)")

    let a = plane.coordinate(x: 40, y: 6), b = plane.coordinate(x: 300, y: 6)
    let byCoordinate = engine.sampleProfile(from: a, to: b, stepDistance: 0.5)
    check("coordinate endpoints sample the same ground as their grid cells",
          abs((byCoordinate.first?.elevation ?? 0) - plane[40, 6]) < 0.001
            && abs((byCoordinate.last?.elevation ?? 0) - (100 + 0.1 * Float(299.9) * 0.5)) < 0.1,
          "\(byCoordinate.first?.elevation ?? .nan)")

    var voided = plane.samples
    for row in 0..<plane.height { voided[row * plane.width + 200] = .nan }
    let voidField = GridElevationField(grid: ElevationGrid(width: plane.width, height: plane.height, samples: voided, region: plane.region))
    let acrossVoid = ElevationTransectEngine(field: voidField).sampleProfile(from: SIMD2(90, y), to: SIMD2(110, y), stepDistance: 0.5)
    check("a void column yields NaN elevation, never a blended value",
          acrossVoid.contains { $0.elevation.isNaN } && acrossVoid.filter { !$0.elevation.isNaN }.allSatisfy { abs($0.elevation - (100 + 0.1 * $0.position.x)) < 0.001 })
    check("derivatives stop at the void instead of spanning it",
          acrossVoid.filter { abs($0.position.x - 100) < 0.4 }.allSatisfy { $0.slopeDegrees.isNaN })

    // --- Platform mound signatures.
    func signatures(_ profile: @escaping (Float) -> Float) -> [TransectSignature] {
        let strip = profileStrip(profile)
        let row = Float(strip.height - 1 - 6) * Float(strip.metersPerRow)
        return ElevationTransectEngine(field: GridElevationField(grid: strip))
            .analyze(from: SIMD2(1, row), to: SIMD2(199, row), stepDistance: 0.5).signatures
    }
    let mound = signatures(moundProfile(plateau: 20))
    let platforms = mound.filter { $0.kind == .platformMound }
    check("a 20 m platform with 25 degree flanks is flagged exactly once", platforms.count == 1, "\(mound)")
    if let platform = platforms.first {
        check("its plateau measures 16-21 m", (16...21).contains(platform.plateauWidthMeters ?? 0), "\(platform.plateauWidthMeters ?? -1)")
        check("both flanks exceed 20 degrees", platform.flankSlopesDegrees.allSatisfy { $0 > 20 }, "\(platform.flankSlopesDegrees)")
        // Transect starts at x = 1 m; plateau edges at 66.0 and 86.0 m.
        let edges = platform.breakDistances.map { $0 + 1 }
        check("slope breaks sit on the plateau edges (+/- 1.5 m)",
              edges.count == 2 && abs(edges[0] - 66.0) < 1.5 && abs(edges[1] - 86.0) < 1.5, "\(edges)")
        check("relief is the platform height (2.8 m +/- 0.3)", abs(platform.reliefMeters - 2.8) < 0.3, "\(platform.reliefMeters)")
        check("platform cut area exceeds 10 m²", platform.cutFillAreaSquareMeters.cut > 10.0, "\(platform.cutFillAreaSquareMeters)")
        check("platform estimated volume exceeds 100 m³", platform.estimatedVolumeCubicMeters > 100.0, "\(platform.estimatedVolumeCubicMeters)")
        check("platform baseline range surrounds 100 m", platform.baselineElevationRange.map { abs($0.lowerBound - 100) < 1.0 } ?? false)
    }
    check("the mound's own flanks are not mistaken for a ditch and berm", mound.allSatisfy { $0.kind == .platformMound })
    check("a 60 m wide rise is not a platform mound", signatures(moundProfile(plateau: 60)).isEmpty)
    check("a plateau between 10 degree flanks is not a platform mound", signatures(moundProfile(plateau: 20, flankDegrees: 10)).isEmpty)

    // --- Ditch and berm.
    let ditchBerm = signatures { x in
        let ditch = x - 80, berm = x - 85
        return 100 - 0.8 * exp(-(ditch * ditch) / 2.88) + 0.6 * exp(-(berm * berm) / 2.88)
    }
    let pairs = ditchBerm.filter { $0.kind == .ditchAndBerm }
    check("an adjacent ditch and berm are flagged once", pairs.count == 1 && ditchBerm.count == 1, "\(ditchBerm)")
    if let pair = pairs.first {
        let marks = pair.breakDistances.map { $0 + 1 }
        check("the pair's extrema sit on the ditch floor and berm crest (+/- 1.2 m)",
              marks.count == 2 && abs(marks[0] - 80) < 1.2 && abs(marks[1] - 85) < 1.2, "\(marks)")
        check("the pair's relief spans ditch floor to berm crest (> 0.8 m)", pair.reliefMeters > 0.8, "\(pair.reliefMeters)")
    }
    let enclosure = signatures { x in
        let b1 = x - 70, d = x - 76, b2 = x - 82
        return 100 + 0.6 * exp(-(b1 * b1) / 2.88) - 0.9 * exp(-(d * d) / 2.88) + 0.6 * exp(-(b2 * b2) / 2.88)
    }
    check("berm-ditch-berm merges into one chained signature with three extrema",
          enclosure.count == 1 && enclosure.first?.breakDistances.count == 3, "\(enclosure)")
    check("lidar-scale noise on flat ground raises no signatures",
          signatures { x in 100 + 0.03 * hashNoise(Int(x * 2), 7) }.isEmpty)
    check("a single 2 m valley wall is not an earthwork", signatures { x in x < 100 ? 100 : 100 + min((x - 100) * 0.2, 6) }.isEmpty)

    // --- Tile mosaic field.
    let coarse = makeGrid(width: 100, height: 100, gsd: 2.0, base: 50)
    let fineTemplate = makeGrid(width: 41, height: 41, gsd: 0.5, base: 60)
    let origin = coarse.region.center
    let mosaic = TileMosaicField(origin: origin, layers: [
        .init(grid: coarse, bounds: coarse.region),
        .init(grid: fineTemplate, bounds: fineTemplate.region),
    ])
    check("the mosaic prefers the finest layer where it answers", mosaic.elevation(at: mosaic.point(for: fineTemplate.region.center)) == 60)
    let offFine = CLLocationCoordinate2D(latitude: coarse.region.maxLatitude - 0.0001, longitude: coarse.region.minLongitude + 0.0001)
    check("the mosaic falls back to coarser layers elsewhere", mosaic.elevation(at: mosaic.point(for: offFine)) == 50)
    let roundTrip = mosaic.coordinate(for: mosaic.point(for: offFine))
    check("mosaic frame round-trips coordinates", abs(roundTrip.latitude - offFine.latitude) < 1e-9 && abs(roundTrip.longitude - offFine.longitude) < 1e-9)
    let east = mosaic.point(for: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude + 0.001))
    check("mosaic frame x is metres east (0.001 deg lon ~ 86.8 m at 38.66 N)", abs(east.x - 86.8) < 0.3 && abs(east.y) < 1e-3, "\(east)")

    // --- Real-time budget.
    let wide = makeGrid(width: 1100, height: 1100, gsd: 5.0, mounds: [(500, 500, 40, 80)])
    let wideEngine = ElevationTransectEngine(field: GridElevationField(grid: wide))
    let started = Date()
    let long = wideEngine.analyze(from: SIMD2(100, 100), to: SIMD2(4100, 3100), stepDistance: 0.5)
    let elapsed = Date().timeIntervalSince(started) * 1000
    print(String(format: "        5 km transect, %d samples at 0.5 m, analysed in %.1f ms", long.samples.count, elapsed))
    check("a 5 km transect at 0.5 m analyses in real time (< 60 ms)", long.samples.count == 10_001 && elapsed < 60,
          String(format: "%d samples, %.1f ms", long.samples.count, elapsed))

    checkTransectExport()
}

/// A transect along the centre row of a 200 m strip whose elevation is `profile(x metres)`, from x = 1 m.
private func exportScene(_ profile: @escaping (Float) -> Float)
    -> (analysis: TransectAnalysis, field: GridElevationField, row: Float) {
    let strip = profileStrip(profile)
    let row = Float(strip.height - 1 - 6) * Float(strip.metersPerRow)
    let field = GridElevationField(grid: strip)
    let analysis = ElevationTransectEngine(field: field).analyze(from: SIMD2(1, row), to: SIMD2(199, row), stepDistance: 0.5)
    return (analysis, field, row)
}

@MainActor
func checkTransectExport() {
    print("\n--- Transect export (GeoJSON + CSV) ---")
    let header = "distance_meters,elevation_meters,along_track_slope_degrees,curvature_rad_per_meter,latitude,longitude"

    // Everything below reads the export back through JSONSerialization / string splitting, never
    // through the exporter's own types, so a malformed document fails instead of round-tripping.
    func decode(_ data: Data?) -> [String: Any]? {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
    }
    func features(_ root: [String: Any]?) -> [[String: Any]] { root?["features"] as? [[String: Any]] ?? [] }
    func properties(_ feature: [String: Any]?) -> [String: Any] { feature?["properties"] as? [String: Any] ?? [:] }
    func geometry(_ feature: [String: Any]?) -> [String: Any] { feature?["geometry"] as? [String: Any] ?? [:] }
    func kind(_ feature: [String: Any]) -> String? { properties(feature)["type"] as? String }
    func number(_ value: Any?) -> Double { value as? Double ?? .nan }
    func near(_ value: Any?, _ expected: Float, tolerance: Double = 0.001) -> Bool {
        abs(number(value) - Double(expected)) <= tolerance
    }
    func cell(_ text: String, _ value: Double, places: Int) -> Bool {
        value.isNaN ? text.isEmpty : abs((Double(text) ?? .nan) - value) <= 0.5 * pow(10, -Double(places)) + 1e-9
    }

    // --- A 20 m platform mound: plain at 100 m, 25 degree flanks, a top 2.8 m up.
    let (mound, moundField, row) = exportScene(moundProfile(plateau: 20))
    let moundRoot = decode(try? TransectExporter.exportGeoJSON(from: mound, in: moundField))
    let all = features(moundRoot)
    check("the GeoJSON export parses as a FeatureCollection",
          moundRoot?["type"] as? String == "FeatureCollection" && !all.isEmpty, "\(all.count) features")

    let profileFeature = all.first { kind($0) == "transectProfile" }
    let track = geometry(profileFeature)["coordinates"] as? [[Double]] ?? []
    let start = moundField.coordinate(for: mound.samples[0].position)
    let first = track.first ?? []
    let startsRight = first.count == 3 && abs(first[0] - start.longitude) < 1e-6
        && abs(first[1] - start.latitude) < 1e-6 && abs(first[2] - Double(mound.samples[0].elevation)) < 1e-3
    check("the profile is a 3D LineString with one [lon, lat, elevation] per sample",
          geometry(profileFeature)["type"] as? String == "LineString" && track.count == mound.samples.count
            && track.allSatisfy { $0.count == 3 } && startsRight,
          "\(track.count) positions for \(mound.samples.count) samples")
    let profileProps = properties(profileFeature)
    check("the profile feature records its length, step and valid fraction",
          near(profileProps["length_meters"], mound.lengthMeters) && near(profileProps["step_meters"], mound.stepDistance)
            && near(profileProps["valid_fraction"], Float(mound.validFraction)), "\(profileProps)")

    guard let signature = mound.signatures.first(where: { $0.kind == .platformMound }) else {
        check("the synthetic mound is detected before it is exported", false, "\(mound.signatures)")
        return
    }
    let moundPoints = all.filter { kind($0) == "platformMound" }
    let center = (signature.startDistance + signature.endDistance) / 2
    let expectedCenter = moundField.coordinate(for: SIMD2(1 + center, row))
    let pointPosition = geometry(moundPoints.first)["coordinates"] as? [Double] ?? []
    let onCenter = pointPosition.count == 3 && abs(pointPosition[0] - expectedCenter.longitude) < 1e-6
        && abs(pointPosition[1] - expectedCenter.latitude) < 1e-6 && abs(pointPosition[2] - 102.8) < 0.3
    check("a platform mound exports as one Point at its center, at plateau height",
          moundPoints.count == 1 && geometry(moundPoints.first)["type"] as? String == "Point" && onCenter,
          "\(moundPoints.count) points, position \(pointPosition)")

    let m = properties(moundPoints.first)
    let flanks = m["flank_slopes_degrees"] as? [Double] ?? []
    let baseline = m["baseline_elevation_range"] as? [Double] ?? []
    let scalarsMatch = near(m["relief_meters"], signature.reliefMeters)
        && near(m["plateau_width_meters"], signature.plateauWidthMeters ?? .nan)
        && abs(number(m["cut_volume_cubic_meters"]) - signature.estimatedVolumeCubicMeters) <= 0.001
        && abs(number(m["cut_fill_area_sq_meters"]) - signature.cutFillAreaSquareMeters.cut) <= 0.001
    let flanksMatch = flanks.count == signature.flankSlopesDegrees.count
        && zip(flanks, signature.flankSlopesDegrees).allSatisfy { abs($0 - Double($1)) <= 0.001 }
    let baselineMatches = baseline.count == 2 && abs(baseline[0] - (signature.baselineElevationRange?.lowerBound ?? .nan)) <= 0.001
        && abs(baseline[1] - (signature.baselineElevationRange?.upperBound ?? .nan)) <= 0.001
    check("a mound's properties carry the detected signature's measurements, tagged with its type",
          m["type"] as? String == "platformMound" && scalarsMatch && flanksMatch && baselineMatches, "\(m)")
    check("a mound's exported measurements match the synthetic 20 m platform",
          (16.0...21.0).contains(number(m["plateau_width_meters"])) && abs(number(m["relief_meters"]) - 2.8) < 0.3
            && flanks.count == 2 && flanks.allSatisfy { $0 > 20 } && number(m["cut_volume_cubic_meters"]) > 100
            && number(m["cut_fill_area_sq_meters"]) > 10 && baseline.count == 2 && baseline.allSatisfy { abs($0 - 100) < 1 },
          "\(m)")

    // --- An adjacent ditch (floor at 80 m) and berm (crest at 85 m).
    let (ditchBerm, dbField, dbRow) = exportScene { x in
        let ditch = x - 80, berm = x - 85
        return 100 - 0.8 * exp(-(ditch * ditch) / 2.88) + 0.6 * exp(-(berm * berm) / 2.88)
    }
    let dbFeatures = features(decode(try? TransectExporter.exportGeoJSON(from: ditchBerm, in: dbField)))
    guard let pair = ditchBerm.signatures.first(where: { $0.kind == .ditchAndBerm }) else {
        check("the synthetic ditch and berm is detected before it is exported", false, "\(ditchBerm.signatures)")
        return
    }
    let pairPoints = dbFeatures.filter { kind($0) == "ditchAndBerm" }
    let atBreaks = zip(pairPoints, pair.breakDistances).allSatisfy { feature, distance in
        let position = geometry(feature)["coordinates"] as? [Double] ?? []
        let expected = dbField.coordinate(for: SIMD2(1 + distance, dbRow))
        return position.count >= 2 && abs(position[0] - expected.longitude) < 1e-6 && abs(position[1] - expected.latitude) < 1e-6
    }
    let carriesChain = pairPoints.allSatisfy { feature in
        let p = properties(feature)
        let chain = p["break_distances_meters"] as? [Double] ?? []
        return chain.count == pair.breakDistances.count && zip(chain, pair.breakDistances).allSatisfy { abs($0 - Double($1)) <= 0.001 }
            && near(p["relief_meters"], pair.reliefMeters)
    }
    check("a ditch and berm exports one Point per break, each carrying the chain and its relief",
          pairPoints.count == pair.breakDistances.count && pairPoints.count >= 2 && atBreaks && carriesChain,
          "\(pairPoints.count) points for breaks \(pair.breakDistances)")

    // --- A transect across a void column: NaN elevations must never reach the document.
    let flat = profileStrip { 100 + 0.1 * $0 }
    var voided = flat.samples
    for r in 0..<flat.height { voided[r * flat.width + 200] = .nan }
    let voidField = GridElevationField(grid: ElevationGrid(width: flat.width, height: flat.height, samples: voided, region: flat.region))
    let flatRow = Float(flat.height - 1 - 6) * Float(flat.metersPerRow)
    let acrossVoid = ElevationTransectEngine(field: voidField).analyze(from: SIMD2(90, flatRow), to: SIMD2(110, flatRow), stepDistance: 0.5)
    let voidCount = acrossVoid.samples.filter { $0.elevation.isNaN }.count
    let voidProfile = features(decode(try? TransectExporter.exportGeoJSON(from: acrossVoid, in: voidField))).first { kind($0) == "transectProfile" }
    let voidTrack = geometry(voidProfile)["coordinates"] as? [[Double]] ?? []
    check("void samples are left out of the LineString instead of being written as NaN",
          voidCount > 0 && voidTrack.count == acrossVoid.samples.count - voidCount
            && voidTrack.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) },
          "\(voidTrack.count) positions, \(voidCount) void of \(acrossVoid.samples.count)")

    let empty = TransectAnalysis(samples: [], stepDistance: 0.5, parameters: TransectSignatureParameters())
    let lone = TransectAnalysis(
        samples: [ProfileSample(index: 0, distance: 0, position: .zero, elevation: 100, smoothedElevation: 100, slopeDegrees: 0, curvature: 0)],
        stepDistance: 0.5, parameters: TransectSignatureParameters())
    func refuses(_ analysis: TransectAnalysis) -> Bool {
        do { _ = try TransectExporter.exportGeoJSON(from: analysis, in: moundField); return false }
        catch let error as TransectExportError { return error == .noProfile }
        catch { return false }
    }
    check("fewer than two located samples cannot make a LineString, so the GeoJSON export throws",
          refuses(empty) && refuses(lone))

    // --- CSV.
    let csv = TransectExporter.exportCSV(from: mound, in: moundField)
    let records = csv.components(separatedBy: "\r\n")
    let rows = records.dropFirst().dropLast().map { $0.components(separatedBy: ",") }
    check("the CSV starts with the documented header", records.first == header, "\(records.first ?? "")")
    check("the CSV has one CRLF-terminated row of six fields per sample",
          records.count == mound.samples.count + 2 && records.last == "" && rows.count == mound.samples.count
            && rows.allSatisfy { $0.count == 6 } && !csv.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
          "\(records.count) records for \(mound.samples.count) samples")
    let distances = rows.compactMap { Double($0.first ?? "") }
    check("CSV distances step by exactly the sampling interval",
          distances.count == mound.samples.count
            && distances.indices.allSatisfy { abs(distances[$0] - Double($0) * Double(mound.stepDistance)) < 1e-9 })
    let valuesMatch = zip(mound.samples, rows).allSatisfy { sample, fields in
        guard fields.count == 6 else { return false }
        let c = moundField.coordinate(for: sample.position)
        return cell(fields[1], Double(sample.elevation), places: 3) && cell(fields[2], Double(sample.slopeDegrees), places: 3)
            && cell(fields[3], Double(sample.curvature), places: 6) && cell(fields[4], c.latitude, places: 7)
            && cell(fields[5], c.longitude, places: 7)
    }
    check("every CSV row carries its sample's elevation, slope, curvature and position",
          rows.count == mound.samples.count && valuesMatch, "\(rows.count) rows for \(mound.samples.count) samples")
    let voidCSV = TransectExporter.exportCSV(from: acrossVoid, in: voidField)
    let voidRows = voidCSV.components(separatedBy: "\r\n").dropFirst().dropLast().map { $0.components(separatedBy: ",") }
    let voidRowsKeepPosition = zip(acrossVoid.samples, voidRows).allSatisfy { sample, fields in
        !sample.elevation.isNaN || (fields.count == 6 && fields[1].isEmpty && !fields[4].isEmpty && !fields[5].isEmpty)
    }
    let voidText = voidRows.map { $0.joined(separator: ",") }.joined(separator: "\n").lowercased()
    check("void samples keep their position and leave the measured cells empty, never NaN text",
          voidCount > 0 && voidRows.count == acrossVoid.samples.count && voidRowsKeepPosition
            && !voidText.contains("nan") && !voidText.contains("inf"))
    check("an empty analysis exports a header-only CSV", TransectExporter.exportCSV(from: empty, in: moundField) == header + "\r\n")
}
