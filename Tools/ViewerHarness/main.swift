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

let usage = await diskCache.totalDiskUsage()
check("disk cache reports positive usage", usage >= 4, "\(usage) bytes")

await diskCache.clear()
let clearedRead = await diskCache.read(forKey: sampleKey)
check("disk cache cleared successfully", clearedRead == nil, "not nil")
try? FileManager.default.removeItem(at: tempTestCacheDir)

await model.refreshDiskCacheSize()
check("model diskCacheSizeFormatted populated", !model.diskCacheSizeFormatted.isEmpty)

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
model.resetShading()
check("model contourInterval reset to off", model.contourInterval == .off)

print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
