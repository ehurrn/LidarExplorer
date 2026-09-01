import Foundation
import CoreLocation

// Build a synthetic DEM: flat plain at 200 m, with planted Gaussian mounds.
func makeGrid(
    width: Int, height: Int, gsd: Double,
    base: Float = 200,
    regionalSlope: Float = 0,
    mounds: [(cx: Int, cy: Int, height: Float, sigma: Float)] = [],
    voids: [(x: Int, y: Int)] = []
) -> ElevationGrid {
    var samples = [Float](repeating: base, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = base + regionalSlope * Float(x)
            for m in mounds {
                let dx = Float(x - m.cx), dy = Float(y - m.cy)
                v += m.height * exp(-(dx*dx + dy*dy) / (2 * m.sigma * m.sigma))
            }
            samples[y * width + x] = v
        }
    }
    for v in voids { samples[v.y * width + v.x] = .nan }

    // gsd metres per cell -> derive the angular span.
    let latSpan = Double(height - 1) * gsd / GeoRegion.metersPerDegreeLatitude
    let centerLat = 38.65
    let lonSpan = Double(width - 1) * gsd
        / (GeoRegion.metersPerDegreeLatitude * cos(centerLat * .pi / 180))
    let region = GeoRegion(
        center: CLLocationCoordinate2D(latitude: centerLat, longitude: -90.06),
        latitudeSpan: latSpan, longitudeSpan: lonSpan
    )
    return ElevationGrid(width: width, height: height, samples: samples, region: region)
}

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print(condition ? "  PASS  \(name)" : "  FAIL  \(name) \(detail)")
    if !condition { failures += 1 }
}

let opts = DetectionOptions.default
let detector = MoundDetector()
let now = Date(timeIntervalSince1970: 1_756_700_000)

print("\n=== ElevationGrid ===")
let g = makeGrid(width: 200, height: 200, gsd: 2.0)
check("gsd x ~2m", abs(g.metersPerColumn - 2.0) < 0.05, "got \(g.metersPerColumn)")
check("gsd y ~2m", abs(g.metersPerRow - 2.0) < 0.05, "got \(g.metersPerRow)")
let stats = g.statistics()
check("flat grid stddev == 0", stats.standardDeviation == 0, "got \(stats.standardDeviation)")
check("flat grid coverage 1.0", stats.coverage == 1.0)

let gv = makeGrid(width: 50, height: 50, gsd: 2.0, voids: [(10,10),(11,11)])
check("voids counted", gv.statistics().voidCount == 2, "got \(gv.statistics().voidCount)")
check("voids excluded from mean", !gv.statistics().mean.isNaN)

// Precision regression: Float sum-of-squares cancels badly at real elevation
// magnitudes. A flat grid must report exactly zero spread at any altitude.
let highFlat = makeGrid(width: 200, height: 200, gsd: 2.0, base: 8000)
check("flat grid at 8000 m has zero stddev",
      highFlat.statistics().standardDeviation == 0,
      "got \(highFlat.statistics().standardDeviation)")
check("mean exact at 8000 m", highFlat.statistics().mean == 8000,
      "got \(highFlat.statistics().mean)")
// Known-answer: two values +/- 5 m about 8000 -> sigma exactly 5.
var pair = [Float](repeating: 8005, count: 20000) + [Float](repeating: 7995, count: 20000)
let pairGrid = ElevationGrid(width: 200, height: 200, samples: pair, region: highFlat.region)
check("sigma exact for +/-5 m about 8000 m",
      abs(pairGrid.statistics().standardDeviation - 5) < 1e-3,
      "got \(pairGrid.statistics().standardDeviation)")

print("\n=== Round-trip georeferencing ===")
let c = g.coordinate(x: 100, y: 100)
if let idx = g.index(for: c) {
    check("coordinate->index round trip", idx.x == 100 && idx.y == 100, "got \(idx)")
} else { check("coordinate->index round trip", false, "nil") }
check("row 0 is north", g.coordinate(x: 0, y: 0).latitude > g.coordinate(x: 0, y: 199).latitude)

print("\n=== Flat terrain -> zero detections ===")
let flat = makeGrid(width: 200, height: 200, gsd: 2.0)
let flatRelief = RasterOps.localRelief(of: flat, backgroundRadiusMeters: opts.backgroundRadiusMeters)
check("no detections on flat", detector.detect(in: flat, relief: flatRelief, options: opts, now: now).isEmpty)

print("\n=== Single planted mound ===")
// 3 m tall, sigma 8 cells = 16 m -> ~40 m across. Well inside plausible range.
let one = makeGrid(width: 200, height: 200, gsd: 2.0,
                   mounds: [(cx: 100, cy: 100, height: 3.0, sigma: 8)])
let oneRelief = RasterOps.localRelief(of: one, backgroundRadiusMeters: opts.backgroundRadiusMeters)
let found = detector.detect(in: one, relief: oneRelief, options: opts, now: now)
check("exactly 1 mound detected", found.count == 1, "got \(found.count)")
if let f = found.first {
    let truth = one.coordinate(x: 100, y: 100)
    let err = Geodesy.distance(from: f.coordinate, to: truth)
    check("located within 6 m", err < 6, String(format: "%.1f m off", err))
    check("relief ~3 m", abs(f.dimensions.reliefMeters - 3.0) < 0.7,
          String(format: "%.2f", f.dimensions.reliefMeters))
    check("detector score > 0.5", f.detectorScore > 0.5, String(format: "%.3f", f.detectorScore))
    check("uncorroborated capped below .high", f.confidence < .high, "\(f.confidence)")
    check("caveat present when uncorroborated", f.caveat != nil)
    print("        -> \(f.notes.first ?? "")  score=\(String(format: "%.3f", f.detectorScore))")
}

print("\n=== Mound on a regional slope (local relief model) ===")
// 5% regional slope dwarfs a 3 m mound in raw elevation terms.
let sloped = makeGrid(width: 200, height: 200, gsd: 2.0, regionalSlope: 0.10,
                      mounds: [(cx: 100, cy: 100, height: 3.0, sigma: 8)])
let slopedRelief = RasterOps.localRelief(of: sloped, backgroundRadiusMeters: opts.backgroundRadiusMeters)
let onSlope = detector.detect(in: sloped, relief: slopedRelief, options: opts, now: now)
check("mound found despite 20 m of regional rise", onSlope.count == 1, "got \(onSlope.count)")

print("\n=== Non-maximum suppression ===")
// Two peaks 10 m apart: closer than minimumSeparation (25 m) -> collapse to 1.
let close = makeGrid(width: 200, height: 200, gsd: 2.0,
                     mounds: [(cx: 100, cy: 100, height: 3.0, sigma: 8),
                              (cx: 105, cy: 100, height: 2.8, sigma: 8)])
let closeRelief = RasterOps.localRelief(of: close, backgroundRadiusMeters: opts.backgroundRadiusMeters)
let nms = detector.detect(in: close, relief: closeRelief, options: opts, now: now)
check("two peaks 10 m apart -> 1", nms.count == 1, "got \(nms.count)")

// Two peaks 80 m apart -> both kept.
let far = makeGrid(width: 240, height: 200, gsd: 2.0,
                   mounds: [(cx: 80, cy: 100, height: 3.0, sigma: 8),
                            (cx: 120, cy: 100, height: 3.0, sigma: 8)])
let farRelief = RasterOps.localRelief(of: far, backgroundRadiusMeters: opts.backgroundRadiusMeters)
let two = detector.detect(in: far, relief: farRelief, options: opts, now: now)
check("two peaks 80 m apart -> 2", two.count == 2, "got \(two.count)")

print("\n=== Sub-threshold relief rejected ===")
let tiny = makeGrid(width: 200, height: 200, gsd: 2.0,
                    mounds: [(cx: 100, cy: 100, height: 0.3, sigma: 8)])
let tinyRelief = RasterOps.localRelief(of: tiny, backgroundRadiusMeters: opts.backgroundRadiusMeters)
check("0.3 m bump rejected (min 0.8 m)",
      detector.detect(in: tiny, relief: tinyRelief, options: opts, now: now).isEmpty)

print("\n=== Terrain derivatives ===")
let ramp = makeGrid(width: 60, height: 60, gsd: 1.0, regionalSlope: 0.1) // 10% grade
let d = TerrainAnalysis.derivatives(of: ramp)
let mid = 30 * 60 + 30
let expected = atan(0.1) * 180 / .pi
check("slope on 10% ramp ~5.71 deg", abs(Double(d.slopeDegrees[mid]) - expected) < 0.1,
      String(format: "%.3f vs %.3f", d.slopeDegrees[mid], expected))
check("aspect points downhill (west, ~270)", abs(Double(d.aspectDegrees[mid]) - 270) < 1.0,
      String(format: "%.2f", d.aspectDegrees[mid]))
check("borders are NaN", d.slopeDegrees[0].isNaN)

let shade = TerrainAnalysis.hillshade(d, azimuthDegrees: 315, altitudeDegrees: 45)
check("hillshade in 0...1", shade[mid] >= 0 && shade[mid] <= 1, "\(shade[mid])")

print("\n=== Corroboration: honest re-weighting ===")
let full = Corroboration(evidence: [
    .modernInfrastructure: .observed(0.9, Provenance(source: .openStreetMap)),
    .spectralTerrain: .observed(0.8, Provenance(source: .sentinel2)),
    .vegetation: .observed(0.7, Provenance(source: .sentinel2)),
    .morphology: .observed(0.8, Provenance(source: .onDeviceAnalysis)),
    .knownRecord: .observed(0.5, Provenance(source: .wikidata)),
])
check("full coverage == 1.0", abs(full.evidenceCoverage - 1.0) < 1e-9, "\(full.evidenceCoverage)")
check("full composite computed", full.compositeScore != nil)
check("no caveat at full coverage", full.caveat == nil)

// The exact scenario that broke the old system: satellite unavailable.
let degraded = Corroboration(evidence: [
    .modernInfrastructure: .observed(0.9, Provenance(source: .openStreetMap)),
    .spectralTerrain: .unavailable(.notConfigured(.sentinel2)),
    .vegetation: .unavailable(.notConfigured(.sentinel2)),
    .morphology: .observed(0.8, Provenance(source: .onDeviceAnalysis)),
    .knownRecord: .unavailable(.noCoverage(.wikidata)),
])
check("degraded coverage == 0.55", abs(degraded.evidenceCoverage - 0.55) < 1e-9, "\(degraded.evidenceCoverage)")
let expectedComposite = (0.9 * 0.30 + 0.8 * 0.25) / 0.55
check("renormalised over present weight only",
      abs((degraded.compositeScore ?? -1) - expectedComposite) < 1e-9,
      "\(degraded.compositeScore ?? -1) vs \(expectedComposite)")
check("caveat names the gaps", degraded.caveat?.contains("not configured") == true, degraded.caveat ?? "nil")

// Below the evidence floor -> refuse to score at all.
let thin = Corroboration(evidence: [
    .modernInfrastructure: .unavailable(.offline),
    .spectralTerrain: .unavailable(.offline),
    .vegetation: .unavailable(.offline),
    .morphology: .observed(0.95, Provenance(source: .onDeviceAnalysis)),
    .knownRecord: .unavailable(.offline),
])
check("0.25 coverage refuses a composite", thin.compositeScore == nil)
check("thin evidence is not supported", !thin.isSupported())
// A single strong dimension must not be enough, even at a perfect score.
let lone = Corroboration(evidence: [
    .modernInfrastructure: .observed(1.0, Provenance(source: .openStreetMap)),
    .spectralTerrain: .observed(0.0, Provenance(source: .sentinel2)),
    .vegetation: .observed(0.0, Provenance(source: .sentinel2)),
    .morphology: .observed(0.0, Provenance(source: .onDeviceAnalysis)),
    .knownRecord: .unavailable(.noCoverage(.wikidata)),
])
check("one strong source is not corroboration", !lone.isSupported(),
      "dims=\(lone.corroboratingDimensions().count) composite=\(lone.compositeScore ?? -1)")

print("\n=== Confidence banding ===")
check(".band monotonic", Confidence.band(for: 0.9) == .corroborated
      && Confidence.band(for: 0.75) == .high
      && Confidence.band(for: 0.6) == .moderate
      && Confidence.band(for: 0.2) == .low)

print("\n" + String(repeating: "=", count: 46))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 46))
exit(failures == 0 ? 0 : 1)
