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
}
