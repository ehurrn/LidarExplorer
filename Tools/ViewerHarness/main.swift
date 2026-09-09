import CoreLocation
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(name)" : "  FAIL  \(name) \(detail)")
    if !ok { failures += 1 }
}

func makeGrid(width: Int, height: Int, gsd: Double, base: Float = 200,
              slope: Float = 0,
              mounds: [(cx: Int, cy: Int, h: Float, s: Float)] = [],
              voids: [(x: Int, y: Int)] = []) -> ElevationGrid {
    var samples = [Float](repeating: base, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = base + slope * Float(x)
            for m in mounds {
                let dx = Float(x - m.cx), dy = Float(y - m.cy)
                v += m.h * exp(-(dx*dx + dy*dy) / (2 * m.s * m.s))
            }
            samples[y * width + x] = v
        }
    }
    for v in voids { samples[v.y * width + v.x] = .nan }
    let centerLat = 38.6553
    let latSpan = Double(height - 1) * gsd / GeoRegion.metersPerDegreeLatitude
    let lonSpan = Double(width - 1) * gsd
        / (GeoRegion.metersPerDegreeLatitude * cos(centerLat * .pi / 180))
    return ElevationGrid(width: width, height: height, samples: samples,
        region: GeoRegion(center: CLLocationCoordinate2D(latitude: centerLat, longitude: -90.0621),
                          latitudeSpan: latSpan, longitudeSpan: lonSpan))
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// ============================================================
print("\n=== Geometry ===")
let g = makeGrid(width: 200, height: 200, gsd: 2.0)
check("gsd x ~2m", abs(g.metersPerColumn - 2.0) < 0.05, "\(g.metersPerColumn)")
check("flat stddev == 0", g.statistics().standardDeviation == 0)
let high = makeGrid(width: 200, height: 200, gsd: 2.0, base: 8000)
check("no Float cancellation at 8000 m", high.statistics().standardDeviation == 0,
      "\(high.statistics().standardDeviation)")
check("mean exact at 8000 m", high.statistics().mean == 8000)
let gv = makeGrid(width: 50, height: 50, gsd: 2.0, voids: [(10,10),(11,11)])
check("voids counted", gv.statistics().voidCount == 2)
check("voids excluded from mean", !gv.statistics().mean.isNaN)
if let idx = g.index(for: g.coordinate(x: 100, y: 100)) {
    check("coordinate<->index round trip", idx.x == 100 && idx.y == 100, "\(idx)")
} else { check("coordinate<->index round trip", false) }
check("row 0 is north", g.coordinate(x: 0, y: 0).latitude > g.coordinate(x: 0, y: 199).latitude)

let testCoord = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)
let meters = GeoRegion.toMercatorMeters(testCoord)
let roundTrip = GeoRegion.fromMercatorMeters(x: meters.x, y: meters.y)
check("Mercator round trip latitude exact", abs(roundTrip.latitude - testCoord.latitude) < 1e-6, "\(roundTrip.latitude)")
check("Mercator round trip longitude exact", abs(roundTrip.longitude - testCoord.longitude) < 1e-6, "\(roundTrip.longitude)")
let mercBounds = g.region.mercatorBounds
check("Mercator bounds are valid", mercBounds.maxX > mercBounds.minX && mercBounds.maxY > mercBounds.minY)

print("\n=== Terrain derivatives ===")
let ramp = makeGrid(width: 60, height: 60, gsd: 1.0, slope: 0.1)
let d = TerrainAnalysis.derivatives(of: ramp)
let mid = 30 * 60 + 30
check("slope on 10% grade ~5.71°",
      abs(Double(d.slopeDegrees[mid]) - atan(0.1) * 180 / .pi) < 0.1, "\(d.slopeDegrees[mid])")
check("aspect points downhill (west ~270°)", abs(Double(d.aspectDegrees[mid]) - 270) < 1.0,
      "\(d.aspectDegrees[mid])")
check("borders are NaN", d.slopeDegrees[0].isNaN)

// #2 regression: an isolated interior void must invalidate its own cell,
// even though Horn's 3x3 formula never reads the centre sample.
var vg = makeGrid(width: 40, height: 40, gsd: 1.0, slope: 0.1)
do {
    var samples = vg.samples
    let cx = 20, cy = 20
    samples[cy * 40 + cx] = .nan
    vg = ElevationGrid(width: 40, height: 40, samples: samples, region: vg.region)
}
let vd = TerrainAnalysis.derivatives(of: vg)
check("isolated centre void -> NaN slope", vd.slopeDegrees[20 * 40 + 20].isNaN)
check("isolated centre void -> NaN aspect", vd.aspectDegrees[20 * 40 + 20].isNaN)
// A neighbour one cell away (whose 3x3 does NOT include the void) stays valid.
check("cell clear of the void stays valid", !vd.slopeDegrees[20 * 40 + 24].isNaN)
let shade = TerrainAnalysis.hillshade(d, azimuthDegrees: 315, altitudeDegrees: 45)
check("hillshade within 0...1", shade[mid] >= 0 && shade[mid] <= 1, "\(shade[mid])")
// Pin the illumination convention absolutely, not just relatively.
// The ramp rises toward the east, so its surface faces west (aspect 270).
let litFromWest = TerrainAnalysis.hillshade(d, azimuthDegrees: 270, altitudeDegrees: 45)[mid]
let litFromEast = TerrainAnalysis.hillshade(d, azimuthDegrees: 90, altitudeDegrees: 45)[mid]
let litFromNorth = TerrainAnalysis.hillshade(d, azimuthDegrees: 0, altitudeDegrees: 45)[mid]
check("west-facing slope is brightest lit from the west",
      litFromWest > litFromNorth && litFromNorth > litFromEast,
      "W=\(litFromWest) N=\(litFromNorth) E=\(litFromEast)")
// Closed form: with light exactly opposite the aspect, cos(az - aspect) is
// -1, so the value collapses to cos(zenith)cos(slope) - sin(zenith)sin(slope)
// = cos(zenith + slope). A 5.71 degree ramp is gently shaded, not black.
let zenithRad = 45.0 * Double.pi / 180
let slopeRad = atan(0.1)
let expectedAway = Float(cos(zenithRad + slopeRad))
check("slope lit from directly opposite matches cos(zenith + slope)",
      abs(litFromEast - expectedAway) < 1e-3,
      "got \(litFromEast) expected \(expectedAway)")
// And lit from directly along the aspect, cos(az - aspect) is +1.
let expectedToward = Float(cos(zenithRad - slopeRad))
check("slope lit from directly along matches cos(zenith - slope)",
      abs(litFromWest - expectedToward) < 1e-3,
      "got \(litFromWest) expected \(expectedToward)")

// A ridge lit along its axis is nearly invisible; lit across it, it is not.
// The ridge runs north-south, so its faces point east and west.
let ridge = makeGrid(width: 120, height: 120, gsd: 1.0,
                     mounds: (0..<120).map { (cx: 60, cy: $0, h: 2.0, s: 3) })
let ridgeD = TerrainAnalysis.derivatives(of: ridge)
func spread(_ v: [Float]) -> Float {
    let ok = v.filter { !$0.isNaN }
    let m = ok.reduce(0, +) / Float(ok.count)
    return (ok.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(ok.count)).squareRoot()
}
let along = spread(TerrainAnalysis.hillshade(ridgeD, azimuthDegrees: 0, altitudeDegrees: 30))
let across = spread(TerrainAnalysis.hillshade(ridgeD, azimuthDegrees: 90, altitudeDegrees: 30))
check("a N-S ridge shows more when lit from the east than from the north",
      across > along * 1.5, "along=\(along) across=\(across)")
// This is the whole argument for the multi-directional style: the feature
// that vanishes at one azimuth must still register in the combined product.
let ridgeMDR = TerrainAnalysis.multiDirectionalRelief(ridgeD)
check("multi-directional relief catches what one azimuth misses",
      (ridgeMDR.filter { !$0.isNaN }.max() ?? 0) > along,
      "mdr=\(ridgeMDR.filter { !$0.isNaN }.max() ?? 0) along=\(along)")

print("\n=== TIFF decoding ===")
func makeTIFF(width: Int, height: Int, values: [Float], littleEndian: Bool = true) -> Data {
    var out = Data()
    func put16(_ v: UInt16) {
        out.append(littleEndian ? Data([UInt8(v & 0xFF), UInt8(v >> 8)])
                                : Data([UInt8(v >> 8), UInt8(v & 0xFF)]))
    }
    func put32(_ v: UInt32) {
        let b = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        out.append(Data(littleEndian ? b : b.reversed()))
    }
    out.append(contentsOf: littleEndian ? [0x49,0x49] : [0x4D,0x4D]); put16(42); put32(8)
    var all: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256,3,1,UInt32(width)), (257,3,1,UInt32(height)), (258,3,1,32), (259,3,1,1),
        (277,3,1,1), (278,3,1,UInt32(height)), (339,3,1,3),
    ]
    let ifdSize = 2 + (all.count + 2) * 12 + 4
    all.append((273,4,1,UInt32(8 + ifdSize)))
    all.append((279,4,1,UInt32(width * height * 4)))
    all.sort { $0.0 < $1.0 }
    put16(UInt16(all.count))
    for (t, ty, c, v) in all {
        put16(t); put16(ty); put32(c)
        if ty == 3 { put16(UInt16(v)); put16(0) } else { put32(v) }
    }
    put32(0)
    for v in values { put32(v.bitPattern) }
    return out
}
let known: [Float] = [201.5, 202.25, 203.0, 204.75, 205.5, 206.0]
do {
    let r = try FloatTIFFDecoder.decode(makeTIFF(width: 3, height: 2, values: known))
    check("little-endian float32 exact", r.samples == known && r.width == 3 && r.height == 2)
} catch { check("little-endian float32 exact", false, "\(error)") }
do {
    let r = try FloatTIFFDecoder.decode(makeTIFF(width: 3, height: 2, values: known, littleEndian: false))
    check("big-endian float32 exact", r.samples == known)
} catch { check("big-endian float32 exact", false, "\(error)") }
func mustThrow(_ n: String, _ data: Data) {
    do { _ = try FloatTIFFDecoder.decode(data); check(n, false, "decoded instead of throwing") }
    catch { check(n, true) }
}
mustThrow("empty throws", Data())
mustThrow("bad magic throws", Data([0,1,2,3,0,0,0,0,0,0]))
mustThrow("truncated throws", makeTIFF(width: 3, height: 2, values: known).dropLast(12))
mustThrow("random bytes throw", Data(repeating: 0xAB, count: 4096))

// Test empty stripByteCounts handling
func makeEmptyByteCountsTIFF() -> Data {
    var out = Data()
    out.append(contentsOf: [0x49, 0x49, 42, 0, 8, 0, 0, 0])
    var entries: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256, 3, 1, 4), (257, 3, 1, 4), (258, 3, 1, 32), (259, 3, 1, 1),
        (273, 4, 1, 120), (277, 3, 1, 1), (278, 3, 1, 4), (279, 4, 0, 0),
        (339, 3, 1, 3)
    ]
    entries.sort { $0.0 < $1.0 }
    out.append(UInt8(entries.count & 0xFF)); out.append(UInt8(entries.count >> 8))
    for (t, ty, c, v) in entries {
        out.append(UInt8(t & 0xFF)); out.append(UInt8(t >> 8))
        out.append(UInt8(ty & 0xFF)); out.append(UInt8(ty >> 8))
        out.append(UInt8(c & 0xFF)); out.append(UInt8((c >> 8) & 0xFF)); out.append(UInt8((c >> 16) & 0xFF)); out.append(UInt8(c >> 24))
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
    }
    out.append(contentsOf: [0, 0, 0, 0])
    while out.count < 120 + 64 { out.append(0) }
    return out
}
mustThrow("empty stripByteCounts throws safely without trapping", makeEmptyByteCountsTIFF())

// Test oversized dimensions cap (4096)
func makeOversizedTIFF() -> Data {
    var out = Data()
    out.append(contentsOf: [0x49, 0x49, 42, 0, 8, 0, 0, 0])
    let entries: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256, 4, 1, 65536), (257, 4, 1, 65536), (258, 3, 1, 32), (259, 3, 1, 1),
        (273, 4, 1, 200), (277, 3, 1, 1), (278, 4, 1, 65536), (279, 4, 1, 100),
        (339, 3, 1, 3)
    ]
    out.append(UInt8(entries.count & 0xFF)); out.append(UInt8(entries.count >> 8))
    for (t, ty, c, v) in entries.sorted(by: { $0.0 < $1.0 }) {
        out.append(UInt8(t & 0xFF)); out.append(UInt8(t >> 8))
        out.append(UInt8(ty & 0xFF)); out.append(UInt8(ty >> 8))
        out.append(UInt8(c & 0xFF)); out.append(UInt8((c >> 8) & 0xFF)); out.append(UInt8((c >> 16) & 0xFF)); out.append(UInt8(c >> 24))
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
    }
    out.append(contentsOf: [0, 0, 0, 0])
    return out
}
mustThrow("oversized dimensions throw unsupported", makeOversizedTIFF())
// Tiled layout: what the USGS 3DEP ImageServer actually returns (128x128
// tiles). A strip-only reader rejects every real elevation raster, which is
// exactly how this was found.
func makeTiledTIFF(width: Int, height: Int, tile: Int, values: [Float]) -> Data {
    var out = Data()
    func put16(_ v: UInt16) { out.append(Data([UInt8(v & 0xFF), UInt8(v >> 8)])) }
    func put32(_ v: UInt32) {
        out.append(Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                         UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]))
    }
    let across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
    let tileCount = across * down
    let tileBytes = tile * tile * 4
    out.append(contentsOf: [0x49, 0x49]); put16(42); put32(8)
    var entries: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256,3,1,UInt32(width)), (257,3,1,UInt32(height)), (258,3,1,32), (259,3,1,1),
        (277,3,1,1), (322,3,1,UInt32(tile)), (323,3,1,UInt32(tile)), (339,3,1,3),
    ]
    let ifdSize = 2 + (entries.count + 2) * 12 + 4
    let offsetsAt = 8 + ifdSize
    let countsAt = offsetsAt + tileCount * 4
    let pixelsAt = countsAt + tileCount * 4
    entries.append((324,4,UInt32(tileCount),UInt32(offsetsAt)))
    entries.append((325,4,UInt32(tileCount),UInt32(countsAt)))
    entries.sort { $0.0 < $1.0 }
    put16(UInt16(entries.count))
    for (t, ty, c, v) in entries {
        put16(t); put16(ty); put32(c)
        if ty == 3 && c == 1 { put16(UInt16(v)); put16(0) } else { put32(v) }
    }
    put32(0)
    for i in 0..<tileCount { put32(UInt32(pixelsAt + i * tileBytes)) }
    for _ in 0..<tileCount { put32(UInt32(tileBytes)) }
    // Tiles are padded to full size at the right and bottom edges.
    for ty in 0..<down {
        for tx in 0..<across {
            for row in 0..<tile {
                for col in 0..<tile {
                    let y = ty * tile + row, x = tx * tile + col
                    let v: Float = (x < width && y < height) ? values[y * width + x] : -9999
                    put32(v.bitPattern)
                }
            }
        }
    }
    return out
}
// 100x70 over 32px tiles exercises padding on both edges at once.
let tiledValues = (0..<(100 * 70)).map { Float($0) * 0.25 + 50 }
do {
    let r = try FloatTIFFDecoder.decode(
        makeTiledTIFF(width: 100, height: 70, tile: 32, values: tiledValues))
    check("tiled TIFF dimensions", r.width == 100 && r.height == 70, "\(r.width)x\(r.height)")
    check("tiled TIFF de-tiles without shearing", r.samples == tiledValues,
          r.samples.count == tiledValues.count
            ? "first mismatch at \(r.samples.indices.first { r.samples[$0] != tiledValues[$0] } ?? -1)"
            : "count \(r.samples.count)")
} catch { check("tiled TIFF decodes", false, "\(error)") }

let big = (0..<(64*64)).map { Float($0) * 0.5 + 100 }
do {
    check("64x64 round trip", try FloatTIFFDecoder.decode(makeTIFF(width: 64, height: 64, values: big)).samples == big)
} catch { check("64x64 round trip", false, "\(error)") }

print("\n=== Relief rendering ===")
let terrain = makeGrid(width: 256, height: 256, gsd: 2.0, slope: 0.05,
                       mounds: [(cx: 90, cy: 110, h: 4, s: 10), (cx: 170, cy: 150, h: 2.5, s: 7)])
let compute = RasterCompute()
let gpuAvailable = await compute.isGPUAvailable()
print("        GPU available: \(gpuAvailable)")
let products = await compute.reliefProducts(for: terrain)
check("relief products sized to grid",
      products.slopeDegrees.count == 256 * 256 && products.width == 256)
check("multi-directional relief produced",
      products.multiDirectionalRelief.contains { !$0.isNaN })

for style in ReliefStyle.allCases {
    let values: [Float]
    switch style {
    case .hillshade: values = TerrainAnalysis.hillshade(products.derivatives, azimuthDegrees: 315, altitudeDegrees: 35)
    case .multiDirectional: values = products.multiDirectionalRelief
    case .slope: values = products.slopeDegrees
    case .elevation: values = terrain.samples
    }
    let image = ReliefRenderer.image(from: values, width: 256, height: 256, style: style,
                                     range: ReliefRenderer.robustRange(of: values))
    check("\(style.displayName) renders", image != nil)
    if let image {
        check("\(style.displayName) is 256x256", image.width == 256 && image.height == 256)
        _ = writePNG(image, to: "\(outDir)/relief-\(style.rawValue).png")
    }
}

// Voids must render transparent, not as a grey that reads as terrain.
let voidTerrain = makeGrid(width: 64, height: 64, gsd: 2.0, voids: [(32,32)])
if let img = ReliefRenderer.image(from: voidTerrain.samples, width: 64, height: 64, style: .elevation) {
    let bytes = img.dataProvider!.data! as Data
    let alphaAtVoid = bytes[(32 * 64 + 32) * 4 + 3]
    check("voids render fully transparent", alphaAtVoid == 0, "alpha=\(alphaAtVoid)")
} else { check("voids render fully transparent", false, "no image") }

// An outlier must not flatten the ramp.
var spiky = terrain.samples
spiky[100 * 256 + 100] = 9000
let full = ReliefRenderer.dataRange(of: spiky)
let robust = ReliefRenderer.robustRange(of: spiky)
check("robust range rejects a single spike",
      robust.upperBound < full.upperBound / 2,
      "robust=\(robust.upperBound) full=\(full.upperBound)")

let paddedGrid = makeGrid(width: 520, height: 406, gsd: 1.0)
let croppedGrid = paddedGrid.cropped(margin: 4)
check("cropped grid width reduced by 2*margin", croppedGrid.width == 512, "width=\(croppedGrid.width)")
check("cropped grid height reduced by 2*margin", croppedGrid.height == 398, "height=\(croppedGrid.height)")
check("cropped grid sample count matches w*h", croppedGrid.samples.count == 512 * 398)

let elevationImage = ReliefRenderer.image(
    from: croppedGrid.samples,
    width: croppedGrid.width,
    height: croppedGrid.height,
    style: .elevation
)
check("elevation style renders successfully with cropped grid", elevationImage != nil)

print("\n=== GPU / CPU agreement ===")
if gpuAvailable {
    // The GPU path only engages above the threshold; compare it to the CPU
    // path on the same data to prove the two implement one estimator.
    let cpu = TerrainAnalysis.derivatives(of: terrain)
    var maxDelta: Float = 0
    var compared = 0
    for i in 0..<products.slopeDegrees.count {
        let a = products.slopeDegrees[i], b = cpu.slopeDegrees[i]
        if a.isNaN && b.isNaN { continue }
        if a.isNaN || b.isNaN { maxDelta = .infinity; break }
        maxDelta = max(maxDelta, abs(a - b)); compared += 1
    }
    print("        backend=\(products.backend.rawValue) compared=\(compared) maxDelta=\(maxDelta)")
    check("GPU and CPU slope agree to 0.01°", maxDelta < 0.01, "\(maxDelta)")
} else {
    print("        (skipped: no Metal device)")
}

print("\n=== Landmarks & Bookmarks ===")
let sites = Landmark.curatedSites
check("curated sites not empty", !sites.isEmpty, "\(sites.count)")
check("cahokia present", sites.contains { $0.name.contains("Cahokia") }, "missing Cahokia")

let custom = Landmark(
    id: UUID(),
    name: "Test Butte",
    subtitle: "Custom test",
    category: .custom,
    latitude: 35.0,
    longitude: -110.0,
    altitudeMeters: 5000,
    recommendedAzimuth: 315
)
let data = try JSONEncoder().encode(custom)
let decoded = try JSONDecoder().decode(Landmark.self, from: data)
check("landmark serialization roundtrip", decoded.name == custom.name, "mismatch")

// Test TerrainViewerModel bookmark saving, deletion, and flyTo logic
let model = TerrainViewerModel()
let initialCount = model.bookmarks.count

// Save bookmark
model.visibleRegion.center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
model.azimuth = 270
model.saveBookmark(named: "Grand Canyon Test")

check("bookmark count incremented", model.bookmarks.count == initialCount + 1)
if let saved = model.bookmarks.first {
    check("bookmark name matches", saved.name == "Grand Canyon Test")
    check("bookmark category is custom", saved.category == .custom)
    check("bookmark recommendedAzimuth matches model azimuth", saved.recommendedAzimuth == 270)
    check("bookmark coordinate latitude matches", abs(saved.latitude - 36.1069) < 1e-4)
    check("bookmark coordinate longitude matches", abs(saved.longitude - (-112.1129)) < 1e-4)
    check("bookmark subtitle contains N and W hemispheres", saved.subtitle.contains("N") && saved.subtitle.contains("W"))

    // Persistence check in UserDefaults
    if let data = UserDefaults.standard.data(forKey: "saved_bookmarks"),
       let decodedBookmarks = try? JSONDecoder().decode([Landmark].self, from: data) {
        check("bookmark persisted to UserDefaults", decodedBookmarks.contains { $0.id == saved.id })
    } else {
        check("bookmark persisted to UserDefaults", false, "no data in UserDefaults")
    }

    // Delete bookmark
    model.deleteBookmark(id: saved.id)
    check("bookmark deleted", !model.bookmarks.contains { $0.id == saved.id })
    check("bookmark count restored", model.bookmarks.count == initialCount)
} else {
    check("saved bookmark exists", false)
}

// FlyTo test
if let meteorCrater = Landmark.curatedSites.first(where: { $0.name.contains("Meteor Crater") }) {
    model.showsLandmarks = true
    model.flyTo(landmark: meteorCrater)

    check("flyTo updates visibleRegion center", abs(model.visibleRegion.center.latitude - meteorCrater.latitude) < 1e-4)
    check("flyTo updates pendingRegion", model.pendingRegion != nil)
    if let pending = model.pendingRegion {
        check("pendingRegion center matches landmark", abs(pending.center.latitude - meteorCrater.latitude) < 1e-4)
    }
    check("flyTo updates azimuth to recommendedAzimuth", model.azimuth == meteorCrater.recommendedAzimuth)
    check("flyTo closes landmarks sheet", !model.showsLandmarks)
} else {
    check("meteor crater site exists", false)
}

print("\n=== Persistent Disk Tile Cache ===")
let tempTestCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestTerrainTiles_\(UUID().uuidString)")
let diskCache = TileDiskCache(directory: tempTestCacheDir)
let sampleKey = "test_18_66532_100234"
let sampleData = Data([0xDE, 0xAD, 0xBE, 0xEF])
await diskCache.write(sampleData, forKey: sampleKey)
let readBack = await diskCache.read(forKey: sampleKey)
check("disk cache roundtrip", readBack == sampleData, "data mismatch")

let usage = await diskCache.measureDiskUsage() ?? -1
check("disk cache reports positive usage", usage >= 4, "\(usage) bytes")

await diskCache.clear()
let clearedRead = await diskCache.read(forKey: sampleKey)
check("disk cache cleared successfully", clearedRead == nil, "not nil")
try? FileManager.default.removeItem(at: tempTestCacheDir)

await model.refreshDiskCacheStats()
check("model diskCacheSizeFormatted populated", !model.diskCacheSizeFormatted.isEmpty)

print("\n=== Tile Disk Cache Performance Hygiene ===")

/// Elevation source that answers after a controllable delay, so a settings
/// change can be landed while a tile fetch is still in flight.
nonisolated struct SlowElevationStub: ElevationProviding {
    let delayMilliseconds: Int
    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        let n = max(targetSamples, 16)
        var samples = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                samples[y * n + x] = 300 + Float(x) * 0.5 + Float(y) * 0.25
            }
        }
        return .observed(
            ElevationGrid(width: n, height: n, samples: samples, region: region),
            Provenance(source: .usgs3DEP)
        )
    }
}

func makeCacheDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TileCacheHygiene_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func populate(_ dir: URL, files: Int, bytesEach: Int) {
    let blob = Data(repeating: 0xAB, count: bytesEach)
    for i in 0..<files {
        try? blob.write(to: dir.appendingPathComponent("seed_\(i).cache"))
    }
}

func directoryBytes(_ dir: URL) -> Int64 {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return files.reduce(Int64(0)) { total, f in
        total + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

func modificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

// --- A. init() must not stat-walk the cache directory ---------------------
// TerrainViewerModel builds TerrainTileProvider (and thus TileDiskCache) from
// its @MainActor init, so any directory enumeration here lands on the main
// thread during app launch and grows with the cache.
let lazyInitDir = makeCacheDir()
populate(lazyInitDir, files: 4000, bytesEach: 256)
_ = TileDiskCache(directory: lazyInitDir)  // warm the FS cache
let initStart = DispatchTime.now().uptimeNanoseconds
_ = TileDiskCache(directory: lazyInitDir)
let initMillis = Double(DispatchTime.now().uptimeNanoseconds - initStart) / 1_000_000
check("init does not enumerate the cache directory",
      initMillis < 2.0, String(format: "took %.3f ms on 4000 files", initMillis))

// --- B. the disk cap is still enforced without an eager init scan ---------
// Deferring the measurement must not defeat eviction: a cache that is already
// over its cap on launch has to prune on the next write.
let capDir = makeCacheDir()
populate(capDir, files: 40, bytesEach: 1024)  // 40 KB, over the 8 KB cap below
let capCache = TileDiskCache(directory: capDir, maxDiskBytes: 8 * 1024, targetDiskBytes: 4 * 1024)
await capCache.write(Data(repeating: 0x01, count: 1024), forKey: "cap_probe")
// The measurement that discovers the overrun runs off-actor, so give it a
// bounded window to land rather than assuming it is synchronous.
var capUsage = directoryBytes(capDir)
for _ in 0..<100 where capUsage > 4 * 1024 {
    try? await Task.sleep(for: .milliseconds(20))
    capUsage = directoryBytes(capDir)
}
check("over-cap directory prunes after lazy measurement",
      capUsage <= 4 * 1024, "\(capUsage) bytes remain, expected <= 4096")

// --- C. metadata writes are once per file per session, not per read -------
// Stamping setAttributes(.modificationDate:) on every hit is a synchronous
// metadata write per tile, serialized through the actor behind every other
// tile fetch. Dropping it entirely would be worse in the other direction:
// modification date is the only recency signal that survives a launch, so
// eviction would decay into "least recently written". Stamping once, on the
// first read of a file in a session, keeps both properties.
let mtimeDir = makeCacheDir()
let mtimeCache = TileDiskCache(directory: mtimeDir)
await mtimeCache.write(Data(repeating: 0x02, count: 512), forKey: "mtime_probe")
let probeURL = mtimeDir.appendingPathComponent("mtime_probe.cache")

try? await Task.sleep(for: .milliseconds(30))
_ = await mtimeCache.read(forKey: "mtime_probe")     // first touch: stamps
let afterFirstRead = modificationDate(probeURL)
try? await Task.sleep(for: .milliseconds(30))
_ = await mtimeCache.read(forKey: "mtime_probe")     // repeat: memory only
_ = await mtimeCache.read(forKey: "mtime_probe")
let afterRepeatReads = modificationDate(probeURL)
check("repeat reads in a session write no file metadata",
      afterFirstRead == afterRepeatReads,
      "\(String(describing: afterFirstRead)) -> \(String(describing: afterRepeatReads))")

// A new instance is a new session: it has no in-memory recency, so the first
// read has to refresh the on-disk signal that a future launch will prune by.
let nextSession = TileDiskCache(directory: mtimeDir)
try? await Task.sleep(for: .milliseconds(30))
_ = await nextSession.read(forKey: "mtime_probe")
let afterNewSession = modificationDate(probeURL)
check("first read of a file in a new session refreshes its modification date",
      afterNewSession != nil && afterFirstRead != nil && afterNewSession! > afterFirstRead!,
      "\(String(describing: afterFirstRead)) -> \(String(describing: afterNewSession))")

// --- C2. hit and miss counts are observable -------------------------------
// Every claim about this cache being worth its complexity is a claim about
// hit rate, which nothing measured until now.
let statsDir = makeCacheDir()
let statsCache = TileDiskCache(directory: statsDir)
await statsCache.write(Data(repeating: 0x0A, count: 32), forKey: "present")
_ = await statsCache.read(forKey: "present")
_ = await statsCache.read(forKey: "present")
_ = await statsCache.read(forKey: "absent")
let stats = await statsCache.statistics()
check("cache counts hits", stats.hits == 2, "\(stats.hits) hits, expected 2")
check("cache counts misses", stats.misses == 1, "\(stats.misses) misses, expected 1")
check("cache reports hit rate", abs(stats.hitRate - 2.0 / 3.0) < 0.001, "\(stats.hitRate)")
let emptyStats = await TileDiskCache(directory: makeCacheDir()).statistics()
check("hit rate is zero with no reads", emptyStats.hitRate == 0, "\(emptyStats.hitRate)")

// --- C4. hit rate reaches the surface -------------------------------------
// Counters nothing reads are not measurement. The settings sheet already
// reports what the cache costs in bytes; what it returns for that cost has to
// be visible in the same place, or the cache's value stays an assertion.
let surfacedDir = makeCacheDir()
let surfacedGridDir = makeCacheDir()
let surfacedCache = TileDiskCache(directory: surfacedDir)
let surfacedGrids = TileDiskCache(directory: surfacedGridDir)
let surfacedProvider = TerrainTileProvider(
    diskCache: surfacedCache, gridCache: surfacedGrids)
let surfacedModel = TerrainViewerModel(terrainProvider: surfacedProvider)

await surfacedModel.refreshDiskCacheStats()
check("hit rate reads as unavailable before any lookup",
      surfacedModel.diskCacheHitRateFormatted == "—",
      "got \(surfacedModel.diskCacheHitRateFormatted)")

// Driven through the raster tier, because that is the one the readout
// reports: it is what decides whether a tile has to be fetched again.
await surfacedGrids.write(Data(repeating: 0x0D, count: 32), forKey: "surfaced")
_ = await surfacedGrids.read(forKey: "surfaced")
_ = await surfacedGrids.read(forKey: "surfaced")
_ = await surfacedGrids.read(forKey: "surfaced")
_ = await surfacedGrids.read(forKey: "nothing_here")
await surfacedModel.refreshDiskCacheStats()
check("model reports disk cache hit rate",
      surfacedModel.diskCacheHitRateFormatted == "75% of 4",
      "got \(surfacedModel.diskCacheHitRateFormatted)")

// An unreadable cache directory must not be reported as an empty one.
let unreadableDir = makeCacheDir()
let unreadableCache = TileDiskCache(directory: unreadableDir)
let unreadableModel = TerrainViewerModel(
    terrainProvider: TerrainTileProvider(
        diskCache: unreadableCache, gridCache: TileDiskCache(directory: makeCacheDir())))
try? FileManager.default.setAttributes([.posixPermissions: 0o000],
                                       ofItemAtPath: unreadableDir.path)
await unreadableModel.refreshDiskCacheStats()
let unreadableSize = unreadableModel.diskCacheSizeFormatted
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: unreadableDir.path)
check("an unreadable tier makes the total unknown, not zero",
      unreadableSize == "—", "got \(unreadableSize)")

// Symmetrically for the raster tier, which is the larger of the two.
let unreadableGridDir = makeCacheDir()
let unreadableGridModel = TerrainViewerModel(
    terrainProvider: TerrainTileProvider(
        diskCache: TileDiskCache(directory: makeCacheDir()),
        gridCache: TileDiskCache(directory: unreadableGridDir)))
try? FileManager.default.setAttributes([.posixPermissions: 0o000],
                                       ofItemAtPath: unreadableGridDir.path)
await unreadableGridModel.refreshDiskCacheStats()
let unreadableGridSize = unreadableGridModel.diskCacheSizeFormatted
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: unreadableGridDir.path)
check("an unreadable raster tier also makes the total unknown",
      unreadableGridSize == "—", "got \(unreadableGridSize)")
try? FileManager.default.removeItem(at: unreadableGridDir)

// --- C3. an unreadable directory must not read as "empty" -----------------
// computeUsage returning 0 for a directory it could not enumerate would pin
// the usage figure at zero and silently disable the size cap for the session.
let lockedDir = makeCacheDir()
try? Data(repeating: 0x0B, count: 4096).write(to: lockedDir.appendingPathComponent("locked.cache"))
let lockedCache = TileDiskCache(directory: lockedDir)
try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
let lockedMeasured = await lockedCache.measureDiskUsage()
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
check("unenumerable directory reports no usage figure",
      lockedMeasured == nil, "recorded \(String(describing: lockedMeasured))")

// --- D. eviction still honours read recency -------------------------------
// Dropping the mtime write must not silently downgrade LRU to "least recently
// written": a tile read just before the prune has to survive it.
let lruDir = makeCacheDir()
let lruCache = TileDiskCache(directory: lruDir, maxDiskBytes: 4096, targetDiskBytes: 2048)
let kb = Data(repeating: 0x03, count: 1024)
for name in ["a", "b", "c", "d"] {
    await lruCache.write(kb, forKey: name)
    try? await Task.sleep(for: .milliseconds(5))
}
_ = await lruCache.read(forKey: "a")           // "a" is now the most recent
try? await Task.sleep(for: .milliseconds(5))
await lruCache.write(kb, forKey: "e")          // 5 KB > 4 KB cap, prunes to 2 KB
let survivedA = await lruCache.read(forKey: "a") != nil
let survivedB = await lruCache.read(forKey: "b") != nil
check("recently read entry survives eviction", survivedA, "\"a\" was evicted")
check("least recently used entry is evicted", !survivedB, "\"b\" survived")

// --- E. key sanitization behaviour is unchanged ---------------------------
// The read path rebuilds the filename character by character on every hit, so
// it is worth a fast path -- but only if the mapping stays identical.
let keyDir = makeCacheDir()
let keyCache = TileDiskCache(directory: keyDir)
let unsafeKey = "tile/18:66532 100234?x=1"
let unsafePayload = Data(repeating: 0x04, count: 64)
await keyCache.write(unsafePayload, forKey: unsafeKey)
check("unsafe characters round-trip", await keyCache.read(forKey: unsafeKey) == unsafePayload)
check("unsafe characters map to underscores",
      FileManager.default.fileExists(atPath:
        keyDir.appendingPathComponent("tile_18_66532_100234_x_1.cache").path),
      "sanitized filename not found")
let longKey = String(repeating: "k", count: 260)
let longPayload = Data(repeating: 0x05, count: 32)
await keyCache.write(longPayload, forKey: longKey)
check("over-long key truncates to 200 characters",
      FileManager.default.fileExists(atPath:
        keyDir.appendingPathComponent(String(repeating: "k", count: 200) + ".cache").path),
      "truncated filename not found")
check("over-long key round-trips", await keyCache.read(forKey: longKey) == longPayload)
let safeKey = "tile_18_66532_100234_hillshade_315_45_contour_off_pal_topo"
let safePayload = Data(repeating: 0x06, count: 16)
await keyCache.write(safePayload, forKey: safeKey)
check("already-safe key is left alone",
      FileManager.default.fileExists(atPath: keyDir.appendingPathComponent(safeKey + ".cache").path),
      "safe filename not found")

// --- F. transient renders are not persisted -------------------------------
// Scrubbing the azimuth slider re-renders every visible tile continuously.
// Only the settings the user actually settles on deserve a disk write.
let coalesceDir = makeCacheDir()
let coalesceCache = TileDiskCache(directory: coalesceDir)
let coalesceProvider = TerrainTileProvider(
    diskCache: coalesceCache, gridCache: TileDiskCache(directory: makeCacheDir()))
var settledSettings = TerrainStyleSettings()
settledSettings.style = .hillshade
settledSettings.azimuthDegrees = 315
_ = await coalesceProvider.update(settledSettings)

let settledKey = TerrainTileProvider.diskCacheKey(x: 1, y: 1, z: 18, settings: settledSettings)
await coalesceProvider.schedulePersist(
    Data(repeating: 0x07, count: 8), tile: "18/1/1",
    diskKey: settledKey, renderedWith: settledSettings)

var scrubbedSettings = TerrainStyleSettings()
scrubbedSettings.style = .hillshade
scrubbedSettings.azimuthDegrees = 200
let scrubbedKey = TerrainTileProvider.diskCacheKey(x: 2, y: 2, z: 18, settings: scrubbedSettings)
await coalesceProvider.schedulePersist(
    Data(repeating: 0x08, count: 8), tile: "18/2/2",
    diskKey: scrubbedKey, renderedWith: scrubbedSettings)

try? await Task.sleep(for: .milliseconds(900))
check("render matching current settings is persisted",
      await coalesceCache.read(forKey: settledKey) != nil, "not written")
check("render from superseded settings is skipped",
      await coalesceCache.read(forKey: scrubbedKey) == nil, "stale render was written")

// --- F2. pending writes are coalesced per tile ----------------------------
// A settings change re-renders every visible tile, so during a drag the same
// tile is produced many times inside one settle window. Holding each of those
// renders until its own timer fires piles ~41 KB per tile per generation into
// memory -- in an app that already halves its tile cache on memory warnings.
// Only the newest render of a given tile can ever be written, so only it
// should be retained.
let coalesceDir2 = makeCacheDir()
let coalesceCache2 = TileDiskCache(directory: coalesceDir2)
let provider2 = TerrainTileProvider(
    diskCache: coalesceCache2, gridCache: TileDiskCache(directory: makeCacheDir()))
// .hillshade specifically, because the .multiDirectional key ignores azimuth
// and all three renders would collapse onto one filename.
var scrubA = TerrainStyleSettings()
scrubA.style = .hillshade
scrubA.azimuthDegrees = 100
var scrubB = scrubA
scrubB.azimuthDegrees = 101
var scrubC = scrubA
scrubC.azimuthDegrees = 102
_ = await provider2.update(scrubC)   // the value the user comes to rest on

let keyA = TerrainTileProvider.diskCacheKey(x: 5, y: 5, z: 18, settings: scrubA)
let keyB = TerrainTileProvider.diskCacheKey(x: 5, y: 5, z: 18, settings: scrubB)
let keyC = TerrainTileProvider.diskCacheKey(x: 5, y: 5, z: 18, settings: scrubC)
let payload = Data(repeating: 0x09, count: 64)
for (k, sset) in [(keyA, scrubA), (keyB, scrubB), (keyC, scrubC)] {
    await provider2.schedulePersist(payload, tile: "18/5/5", diskKey: k, renderedWith: sset)
}
try? await Task.sleep(for: .milliseconds(900))
check("only the settled render of a tile reaches disk",
      await coalesceCache2.read(forKey: keyC) != nil, "settled render missing")
let intermediateA = await coalesceCache2.read(forKey: keyA)
let intermediateB = await coalesceCache2.read(forKey: keyB)
check("intermediate renders of a tile never reach disk",
      intermediateA == nil && intermediateB == nil, "an intermediate render was written")

// --- F3. the pending queue is bounded -------------------------------------
// Distinct tiles do not coalesce with each other, so a fast zoom across many
// tiles still needs a hard ceiling rather than an unbounded queue.
let floodDir = makeCacheDir()
let floodCache = TileDiskCache(directory: floodDir)
let floodProvider = TerrainTileProvider(
    diskCache: floodCache, gridCache: TileDiskCache(directory: makeCacheDir()))
var floodSettings = TerrainStyleSettings()
floodSettings.style = .hillshade
floodSettings.azimuthDegrees = 42
_ = await floodProvider.update(floodSettings)
for i in 0..<(TerrainTileProvider.pendingWriteLimit + 200) {
    let k = TerrainTileProvider.diskCacheKey(x: i, y: 0, z: 18, settings: floodSettings)
    await floodProvider.schedulePersist(payload, tile: "18/\(i)/0", diskKey: k,
                                        renderedWith: floodSettings)
}
// Assert through what lands on disk rather than the queue's internals: if
// the ceiling were missing, every one of these renders would be written.
try? await Task.sleep(for: .milliseconds(900))
let floodFiles = (try? FileManager.default.contentsOfDirectory(atPath: floodDir.path))?.count ?? 0
check("pending write queue is capped",
      floodFiles <= TerrainTileProvider.pendingWriteLimit,
      "\(floodFiles) written, limit \(TerrainTileProvider.pendingWriteLimit)")

// When the queue is full the render just produced is the one the user is
// most likely looking at; the stale head of the queue is what should go.
let firstFlooded = TerrainTileProvider.diskCacheKey(x: 0, y: 0, z: 18, settings: floodSettings)
let lastIndex = TerrainTileProvider.pendingWriteLimit + 199
let lastFlooded = TerrainTileProvider.diskCacheKey(x: lastIndex, y: 0, z: 18, settings: floodSettings)
let keptNewest = await floodCache.read(forKey: lastFlooded)
let keptOldest = await floodCache.read(forKey: firstFlooded)
check("a full queue drops its oldest render, not the newest",
      keptNewest != nil && keptOldest == nil,
      "newest \(keptNewest == nil ? "dropped" : "kept"), oldest \(keptOldest == nil ? "dropped" : "kept")")

// --- F4. the launch-path measurement never blocks a tile read -------------
// Deferring the directory walk is only a win if it runs off the actor: an
// inline walk would simply move a ~25 ms stall from launch into the opening
// burst of tile fetches, with every concurrent read queued behind it.
let concurrentDir = makeCacheDir()
populate(concurrentDir, files: 12000, bytesEach: 256)
let concurrentCache = TileDiskCache(directory: concurrentDir)
// Timed from before the write, because the write is what triggers the walk:
// an inline walk would finish inside this call and never overlap the reads.
let readStart = DispatchTime.now().uptimeNanoseconds
await concurrentCache.write(Data(repeating: 0x0C, count: 128), forKey: "seed_0")
for i in 0..<50 { _ = await concurrentCache.read(forKey: "seed_\(i)") }
let readMillis = Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
check("the directory walk does not block writes or reads",
      readMillis < 15.0, String(format: "took %.2f ms", readMillis))

// --- G. a tile is keyed by the settings it was rendered with --------------
// loadTile awaits network I/O. If the viewer pushes new settings during that
// window the tile renders with the new ones, so the key must move with them --
// otherwise the image lands under the old key and is later served as if it
// had been rendered for those settings.
let raceDir = makeCacheDir()
let raceCache = TileDiskCache(directory: raceDir)
let raceProvider = TerrainTileProvider(
    elevation: SlowElevationStub(delayMilliseconds: 250),
    diskCache: raceCache,
    // A throwaway grid cache: sharing the app's would let a grid stored by an
    // earlier run make this fetch instant, and the race would never happen.
    gridCache: TileDiskCache(directory: makeCacheDir())
)
var beforeScrub = TerrainStyleSettings()
beforeScrub.style = .hillshade
beforeScrub.azimuthDegrees = 315
_ = await raceProvider.update(beforeScrub)

let raceRegion = GeoRegion(
    center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621),
    latitudeSpan: 0.002, longitudeSpan: 0.002
)
let raceTile = Task {
    await raceProvider.tileImageData(x: 66532, y: 100234, z: 18, region: raceRegion, pixels: 256)
}
try? await Task.sleep(for: .milliseconds(60))   // land the change mid-fetch
var afterScrub = beforeScrub
afterScrub.azimuthDegrees = 200
_ = await raceProvider.update(afterScrub)
let racePNG = await raceTile.value
try? await Task.sleep(for: .milliseconds(900))  // let the coalesced write settle

check("mid-fetch settings change still produces a tile", racePNG != nil, "nil tile")

let staleKey = TerrainTileProvider.diskCacheKey(x: 66532, y: 100234, z: 18, settings: beforeScrub)
let freshKey = TerrainTileProvider.diskCacheKey(x: 66532, y: 100234, z: 18, settings: afterScrub)
check("tile is not stored under superseded settings",
      await raceCache.read(forKey: staleKey) == nil, "written under \(staleKey)")
check("tile is stored under the settings it rendered with",
      await raceCache.read(forKey: freshKey) != nil, "missing \(freshKey)")

for dir in [lazyInitDir, capDir, mtimeDir, statsDir, surfacedGridDir, lruDir, keyDir, coalesceDir,
            coalesceDir2, floodDir, lockedDir, concurrentDir,
            surfacedDir, unreadableDir, raceDir] {
    try? FileManager.default.removeItem(at: dir)
}


print("\n=== Elevation Grid Disk Cache ===")

func gridFixture(width: Int, height: Int, voids: [(Int, Int)] = []) -> ElevationGrid {
    var samples = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            samples[y * width + x] = Float(300) + Float(x) * 0.75 - Float(y) * 0.25
        }
    }
    for v in voids { samples[v.1 * width + v.0] = .nan }
    return ElevationGrid(
        width: width, height: height, samples: samples,
        region: GeoRegion(minLatitude: 35.0, maxLatitude: 35.0023,
                          minLongitude: -111.02, maxLongitude: -111.0172)
    )
}

// --- Encoding round-trips exactly -----------------------------------------
// Elevation is measured data, so the on-disk form has to be lossless: a
// quantised grid would put fabricated centimetres behind a readout that
// presents itself as an observation.
let originalGrid = gridFixture(width: 40, height: 24, voids: [(3, 4), (39, 23)])
guard let encodedGrid = ElevationGridCoder.encode(originalGrid, source: "3DEP 1m") else {
    fatalError("encode returned nil")
}
if let decoded = ElevationGridCoder.decode(encodedGrid) {
    check("grid round-trips its dimensions",
          decoded.grid.width == 40 && decoded.grid.height == 24,
          "\(decoded.grid.width)x\(decoded.grid.height)")
    check("grid round-trips its region exactly",
          decoded.grid.region == originalGrid.region, "region drifted")
    check("grid round-trips its source", decoded.source == "3DEP 1m", decoded.source)
    let sameFinite = zip(decoded.grid.samples, originalGrid.samples)
        .allSatisfy { $0.isNaN ? $1.isNaN : $0 == $1 }
    check("grid round-trips every sample bit-exactly", sameFinite, "samples differ")
    check("grid round-trips voids as NaN",
          decoded.grid.samples[4 * 40 + 3].isNaN && decoded.grid.samples[23 * 40 + 39].isNaN,
          "voids lost")
} else {
    check("grid decodes", false, "decode returned nil")
}

// --- Malformed payloads are rejected, never trapped -----------------------
// ElevationGrid.init has a precondition on buffer length, so a corrupt or
// truncated cache file would crash the app rather than miss. The decoder has
// to validate before it constructs.
check("truncated payload is rejected",
      ElevationGridCoder.decode(encodedGrid.prefix(encodedGrid.count / 2)) == nil, "accepted")
check("empty payload is rejected", ElevationGridCoder.decode(Data()) == nil, "accepted")
var wrongMagic = encodedGrid
wrongMagic.replaceSubrange(0..<4, with: [0x00, 0x00, 0x00, 0x00])
check("payload with an unknown header is rejected",
      ElevationGridCoder.decode(wrongMagic) == nil, "accepted")
var lyingHeader = encodedGrid
// Claim a far larger grid than the payload carries samples for.
lyingHeader.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(9999).littleEndian) { Array($0) })
check("payload whose header disagrees with its length is rejected",
      ElevationGridCoder.decode(lyingHeader) == nil, "accepted")
var negativeDims = encodedGrid
negativeDims.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(-40).littleEndian) { Array($0) })
check("payload with negative dimensions is rejected",
      ElevationGridCoder.decode(negativeDims) == nil, "accepted")

// --- Padding and cropping are inverses ------------------------------------
// The cache stores the padded grid and reconstructs the tile grid by
// cropping it, so a fresh load and a cache hit must agree.
let unpadded = gridFixture(width: 32, height: 32)
let roundTripped = TerrainTileProvider.padByReplication(unpadded, margin: 4).cropped(margin: 4)
check("pad then crop restores the sample buffer",
      roundTripped.samples == unpadded.samples, "samples differ")
check("pad then crop restores the region",
      abs(roundTripped.region.minLatitude - unpadded.region.minLatitude) < 1e-9
      && abs(roundTripped.region.maxLongitude - unpadded.region.maxLongitude) < 1e-9,
      "region drifted")

// --- The grid cache spares the elevation source on a later launch ---------
// The rendered-PNG cache is consulted only after loadTile has already run, so
// it saves the render but never the fetch. Caching the range-independent grid
// is what lets a cold launch skip the source entirely -- and it keeps the
// grids in memory, which spot inspection and the .elevation refit both read.
nonisolated final class CountingElevationStub: ElevationProviding, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        lock.withLock { calls += 1 }
        let n = max(targetSamples, 16)
        var samples = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n { samples[y * n + x] = 250 + Float(x) * 0.5 + Float(y) * 0.25 }
        }
        return .observed(
            ElevationGrid(width: n, height: n, samples: samples, region: region),
            Provenance(source: .usgs3DEP)
        )
    }
}

let sharedGridDir = makeCacheDir()
let gridRegion = GeoRegion(
    center: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621),
    latitudeSpan: 0.002, longitudeSpan: 0.002
)

let firstStub = CountingElevationStub()
let firstProvider = TerrainTileProvider(
    elevation: firstStub,
    diskCache: TileDiskCache(directory: makeCacheDir()),
    gridCache: TileDiskCache(directory: sharedGridDir)
)
_ = await firstProvider.tileImageData(x: 66532, y: 100234, z: 18, region: gridRegion, pixels: 256)
check("first visit consults the elevation source", firstStub.callCount == 1, "\(firstStub.callCount) calls")

// A separate provider with an empty memory cache and a fresh PNG cache: only
// the grid cache is shared, so anything it serves came from there.
let secondStub = CountingElevationStub()
let secondProvider = TerrainTileProvider(
    elevation: secondStub,
    diskCache: TileDiskCache(directory: makeCacheDir()),
    gridCache: TileDiskCache(directory: sharedGridDir)
)
let restoredPNG = await secondProvider.tileImageData(
    x: 66532, y: 100234, z: 18, region: gridRegion, pixels: 256)
check("a later launch renders the tile without the elevation source",
      secondStub.callCount == 0, "\(secondStub.callCount) calls")
check("a tile restored from the grid cache still renders", restoredPNG != nil, "nil tile")

// The point of caching the grid rather than the pixels: everything that reads
// elevation has to keep working from a cache hit.
let restoredElevation = await secondProvider.elevation(at: gridRegion.center)
check("a restored tile still answers elevation queries",
      restoredElevation != nil && restoredElevation!.isFinite,
      "\(String(describing: restoredElevation))")
check("a restored tile still contributes to the .elevation range",
      await secondProvider.elevationRange(in: gridRegion) != nil, "no range")
check("a restored tile still reports its resolution",
      await secondProvider.finestResolution() != nil, "no resolution")

// --- Degraded tiles must not become permanent ------------------------------
// When 3DEP fails, the tile is upsampled from a terrarium ancestor. Caching
// that would pin the low-detail fallback in place for every later launch,
// long after the outage that caused it.
check("authoritative sources are cached",
      TerrainTileProvider.isCacheableSource("3DEP 1m")
      && TerrainTileProvider.isCacheableSource("terrarium"),
      "an authoritative source was refused")
check("the terrarium fallback for a failed 3DEP fetch is not cached",
      !TerrainTileProvider.isCacheableSource("3DEP 1m (fallback to terrarium)"),
      "a degraded tile would be cached")

// --- Queued rasters are written, and the queue is bounded ------------------
// Each encoded raster is ~272 KB, 6.6x a rendered tile, so the write path
// needs the ceiling the rendered-tile path already has. What must not change
// is that ordinary volumes still all reach disk.
let queueDir = makeCacheDir()
let queueCache = TileDiskCache(directory: queueDir)
let queueProvider = TerrainTileProvider(
    diskCache: TileDiskCache(directory: makeCacheDir()), gridCache: queueCache)
let rasterPayload = Data(repeating: 0x21, count: 2_048)
let queuedCount = 40
for i in 0..<queuedCount {
    await queueProvider.queueGridWrite(rasterPayload, forKey: "queued_grid_\(i)")
}
// Drain is immediate — a raster does not depend on settings, so unlike a
// rendered tile there is nothing that could supersede it and no settle window.
for _ in 0..<200 where (try? FileManager.default.contentsOfDirectory(atPath: queueDir.path))?.count ?? 0 < queuedCount {
    try? await Task.sleep(for: .milliseconds(10))
}
let queuedWritten = (try? FileManager.default.contentsOfDirectory(atPath: queueDir.path))?.count ?? 0
check("every queued raster below the ceiling reaches disk",
      queuedWritten == queuedCount, "\(queuedWritten) of \(queuedCount)")
check("a queued raster round-trips",
      await queueCache.read(forKey: "queued_grid_7") == rasterPayload, "payload differs")
// A second burst, after the first drain has certainly finished: the drain has
// to re-arm, or the queue works once per launch and then silently stops.
try? await Task.sleep(for: .milliseconds(200))
for i in 0..<5 {
    await queueProvider.queueGridWrite(rasterPayload, forKey: "second_burst_\(i)")
}
for _ in 0..<200 where await queueCache.read(forKey: "second_burst_4") == nil {
    try? await Task.sleep(for: .milliseconds(10))
}
check("rasters queued after a drain finishes are still written",
      await queueCache.read(forKey: "second_burst_4") != nil, "second burst lost")

check("the raster write queue declares a ceiling",
      TerrainTileProvider.pendingGridWriteLimit > 0
      && TerrainTileProvider.pendingGridWriteLimit <= 256,
      "\(TerrainTileProvider.pendingGridWriteLimit)")
try? FileManager.default.removeItem(at: queueDir)

// --- Both tiers have to be visible, and clearable --------------------------
// The grid cache is the larger of the two (350 MB against 150 MB). A readout
// or a Clear button that only knows about rendered tiles under-reports what is
// on disk and leaves most of it behind.
let tierTileDir = makeCacheDir()
let tierGridDir = makeCacheDir()
let tierTileCache = TileDiskCache(directory: tierTileDir)
let tierGridCache = TileDiskCache(directory: tierGridDir)
let tierStub = CountingElevationStub()
let tierProvider = TerrainTileProvider(
    elevation: tierStub, diskCache: tierTileCache, gridCache: tierGridCache)

await tierTileCache.write(Data(repeating: 0x11, count: 3_000), forKey: "rendered_probe")
await tierGridCache.write(Data(repeating: 0x12, count: 40_000), forKey: "grid_probe")

let combined = await tierProvider.diskCacheSize()
check("reported cache size covers both tiers",
      combined != nil && combined! >= 43_000,
      "\(String(describing: combined)) bytes, expected >= 43000")

// The tier that decides whether a tile needs refetching is the one worth
// reporting: a rendered-tile hit still arrives after loadTile has run.
_ = await tierGridCache.read(forKey: "grid_probe")
_ = await tierGridCache.read(forKey: "grid_probe")
_ = await tierGridCache.read(forKey: "absent_grid")
_ = await tierTileCache.read(forKey: "rendered_probe")
let tierStats = await tierProvider.diskCacheStatistics()
check("reported hit rate is the tier that avoids refetching",
      tierStats.hits == 2 && tierStats.misses == 1,
      "\(tierStats.hits) hits / \(tierStats.misses) misses")

await tierProvider.clearDiskCache()
let tileFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: tierTileDir.path))?.count ?? -1
let gridFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: tierGridDir.path))?.count ?? -1
check("clearing the cache removes rendered tiles", tileFilesAfter == 0, "\(tileFilesAfter) left")
check("clearing the cache removes elevation rasters", gridFilesAfter == 0, "\(gridFilesAfter) left")
let clearedSize = await tierProvider.diskCacheSize()
check("cleared cache reports as empty", clearedSize == 0, "\(String(describing: clearedSize))")

for dir in [sharedGridDir, tierTileDir, tierGridDir] {
    try? FileManager.default.removeItem(at: dir)
}

print("\n=== Spot Inspection ===")
let spot = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: 150.0,
    slopeDegrees: 12.5,
    aspectDegrees: 270.0
)
check("spot inspection compass direction", spot.compassDirection == "W", "expected W, got \(spot.compassDirection)")
check("spot slope percentage", spot.slopePercentFormatted == "22%", "got \(spot.slopePercentFormatted)")
check("spot formatted elevation meters", spot.formattedElevation(unit: .meters) == "150.0 m", "got \(spot.formattedElevation(unit: .meters))")
check("spot formatted elevation feet", spot.formattedElevation(unit: .feet) == "492.1 ft", "got \(spot.formattedElevation(unit: .feet))")
check("spot equatable self", spot == spot)

let spotNaN = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: .nan,
    slopeDegrees: .nan,
    aspectDegrees: .nan
)
check("spot NaN compass direction", spotNaN.compassDirection == "Flat", "got \(spotNaN.compassDirection)")
check("spot NaN slope percentage", spotNaN.slopePercentFormatted == "0%", "got \(spotNaN.slopePercentFormatted)")
check("spot NaN equatable", spotNaN == spotNaN)

let spotSteep = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: 500.0,
    slopeDegrees: 90.0,
    aspectDegrees: 45.0
)
check("spot steep slope percentage", spotSteep.slopePercentFormatted == ">1000%", "got \(spotSteep.slopePercentFormatted)")
check("spot NE compass direction", spotSteep.compassDirection == "NE", "got \(spotSteep.compassDirection)")

let spotInf = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: 500.0,
    slopeDegrees: 15.0,
    aspectDegrees: .infinity
)
check("spot infinity compass direction is Flat", spotInf.compassDirection == "Flat", "got \(spotInf.compassDirection)")
check("spot infinity aspectFormatted is Flat", spotInf.aspectFormatted == "Flat", "got \(spotInf.aspectFormatted)")

let spotFlat = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: 100.0,
    slopeDegrees: 0.2,
    aspectDegrees: 180.0
)
check("spot flat slope compass direction is Flat", spotFlat.compassDirection == "Flat", "got \(spotFlat.compassDirection)")
check("spot flat slope aspectFormatted is Flat", spotFlat.aspectFormatted == "Flat", "got \(spotFlat.aspectFormatted)")

model.clearInspection()
check("model activeSpot nil after clearInspection", model.activeSpot == nil)
check("model inspectionState idle after clearInspection", model.inspectionState == .idle)

print("\n=== Topographic Contour Lines ===")
let intervals = ContourInterval.allCases
check("contour intervals defined", intervals.count == 4, "\(intervals.count)")
check("contour ten meters interval", ContourInterval.tenMeters.meters == 10.0, "mismatch")
check("contour twenty five meters interval", ContourInterval.twentyFiveMeters.meters == 25.0, "mismatch")
check("contour fifty meters interval", ContourInterval.fiftyMeters.meters == 50.0, "mismatch")
check("contour off interval is 0", ContourInterval.off.meters == 0.0, "mismatch")

let testSlopeGrid = makeGrid(width: 64, height: 64, gsd: 1.0, base: 100, slope: 1.0)
let imgNoContour = ReliefRenderer.image(
    from: testSlopeGrid.samples,
    width: 64,
    height: 64,
    style: .elevation,
    contourInterval: .off
)
check("renders without contours", imgNoContour != nil)

let imgWithContour = ReliefRenderer.image(
    from: testSlopeGrid.samples,
    width: 64,
    height: 64,
    style: .elevation,
    contourInterval: .tenMeters
)
check("renders with contours", imgWithContour != nil)

if let imgNoContour, let imgWithContour {
    let bytesNo = imgNoContour.dataProvider!.data! as Data
    let bytesWith = imgWithContour.dataProvider!.data! as Data
    check("contour image produces different pixel output", bytesNo != bytesWith, "pixel buffers identical")
} else {
    check("contour image produces different pixel output", false, "nil image")
}

model.contourInterval = .tenMeters
check("model contourInterval set", model.contourInterval == .tenMeters)
check("model hasCustomShading with contour", model.hasCustomShading)
check("contourInterval persisted in UserDefaults", UserDefaults.standard.string(forKey: "contourInterval") == ContourInterval.tenMeters.rawValue)

// Contours are a render-time overlay only: they must never be baked into the
// cached ReliefProducts. If they are, a tile fetched while contours were on keeps
// them after the user turns contours off (the products survive a settings change,
// only renderedPNG is discarded), and it draws them twice while they are on.
// Assert the round-trip: rendering the same products off -> on -> off is exact.
let contourProducts = await compute.reliefProducts(for: testSlopeGrid)
check(
    "relief products carry no contour imprint",
    contourProducts.width == 64 && contourProducts.height == 64
)

// .elevation rather than .multiDirectional: a uniform-slope grid has constant
// relief spread, so multiDirectional renders it fully transparent and the contour
// pass correctly skips every pixel, which would make this assertion vacuous.
func contourRender(_ interval: ContourInterval) -> Data? {
    ReliefRenderer.image(
        from: testSlopeGrid.samples,
        width: contourProducts.width,
        height: contourProducts.height,
        style: .elevation,
        elevation: testSlopeGrid.samples,
        contourInterval: interval
    ).flatMap { $0.dataProvider?.data as Data? }
}

if let off1 = contourRender(.off),
   let on1 = contourRender(.tenMeters),
   let off2 = contourRender(.off) {
    check("contours change the rendered tile", off1 != on1, "contour overlay drew nothing")
    check("contours off -> on -> off round-trips exactly", off1 == off2, "contour residue left behind")
} else {
    check("contour round-trip renders", false, "nil image")
}

model.resetShading()
check("model contourInterval reset to off", model.contourInterval == .off)
check("contourInterval reset in UserDefaults", UserDefaults.standard.string(forKey: "contourInterval") == ContourInterval.off.rawValue)

print("\n=== Hypsometric Palettes ===")
let palettes = HypsometricPalette.allCases
check("all palettes available", palettes.count == 4, "\(palettes.count)")
for p in palettes {
    let img = ReliefRenderer.image(
        from: [100.0, 200.0, 300.0, 400.0],
        width: 2,
        height: 2,
        style: .elevation,
        palette: p
    )
    check("palette renders image: \(p.displayName)", img != nil, "nil image")
}

// Verify different palettes produce different pixels
let turboImg = ReliefRenderer.image(from: [100.0, 200.0, 300.0, 400.0], width: 2, height: 2, style: .elevation, palette: .turbo)
let slateImg = ReliefRenderer.image(from: [100.0, 200.0, 300.0, 400.0], width: 2, height: 2, style: .elevation, palette: .slate)
if let turboImg, let slateImg {
    let tBytes = turboImg.dataProvider!.data! as Data
    let sBytes = slateImg.dataProvider!.data! as Data
    check("turbo vs slate produce different output", tBytes != sBytes, "pixel buffers identical")
} else {
    check("turbo vs slate produce different output", false, "nil image")
}

model.palette = .magma
check("model palette set", model.palette == .magma)
check("model hasCustomShading with palette", model.hasCustomShading)
check("palette persisted in UserDefaults", UserDefaults.standard.string(forKey: "hypsometricPalette") == HypsometricPalette.magma.rawValue)

model.resetShading()
check("model palette reset to topo", model.palette == .topo)

print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
