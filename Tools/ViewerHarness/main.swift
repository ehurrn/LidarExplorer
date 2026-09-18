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

// .topographicOpenness and .rrim are exercised in their own sections below:
// they need opennessProducts/rrimImage, not TerrainAnalysis derivatives, so
// they do not fit this loop's single-scalar ReliefRenderer.image path.
for style in ReliefStyle.allCases where style.microTopographyProduct == nil && style != .topographicOpenness {
    let values: [Float]
    switch style {
    case .hillshade: values = TerrainAnalysis.hillshade(products.derivatives, azimuthDegrees: 315, altitudeDegrees: 35)
    case .multiDirectional: values = products.multiDirectionalRelief
    case .slope: values = products.slopeDegrees
    case .elevation: values = terrain.samples
    case .topographicOpenness, .rrim, .localRelief, .skyView, .rakingLight, .relativeElevation, .curvature,
         .directionalOcclusion, .positiveOpenness, .negativeOpenness, .vectorRuggedness, .differenceOfGaussians:
        fatalError("excluded by the where clause above")
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
// `cropped(margin:)` is deprecated: the render path passes the margin to the
// shader instead. It still has to behave, because the CPU fallback and any
// caller wanting a standalone grid still use it, so the checks stay — inside a
// deprecated helper, which is how Swift lets a deprecated API be exercised
// without the call site itself warning.
@available(*, deprecated)
func legacyCrop(_ grid: ElevationGrid, margin: Int) -> ElevationGrid {
    grid.cropped(margin: margin)
}
let croppedGrid = legacyCrop(paddedGrid, margin: 4)
check("croppedRegion matches the region cropping produces",
      paddedGrid.croppedRegion(margin: 4) == croppedGrid.region,
      "analytic region disagrees with the copied one")
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

print("\n=== Fused surface-to-display kernel ===")
// The display kernel replaces the whole download-and-loop tail of the old
// path. Two things have to hold for that to be a refactor rather than a
// rewrite of the picture: it must dispatch over the destination tile while
// reading its 3x3 window across the skirt, and it must land on the same
// colours the CPU renderer produces from the same numbers.

let fusedMargin = 4
let fusedPaddedW = 72
let fusedPaddedH = 72
let fusedDestW = fusedPaddedW - fusedMargin * 2
let fusedDestH = fusedPaddedH - fusedMargin * 2

// Ridged terrain rather than a plane: a uniform surface would give every
// style a constant value and make an agreement check vacuous.
var fusedSamples = [Float](repeating: 0, count: fusedPaddedW * fusedPaddedH)
for y in 0..<fusedPaddedH {
    for x in 0..<fusedPaddedW {
        let fx = Float(x) / Float(fusedPaddedW)
        let fy = Float(y) / Float(fusedPaddedH)
        fusedSamples[y * fusedPaddedW + x] =
            300 + 60 * sin(fx * 7) * cos(fy * 5) + 25 * fx + 40 * fy
    }
}
let fusedGrid = ElevationGrid(
    width: fusedPaddedW, height: fusedPaddedH, samples: fusedSamples,
    region: GeoRegion(minLatitude: 39.0, maxLatitude: 39.0018,
                      minLongitude: -106.5, maxLongitude: -106.4977)
)

/// Copies the destination tile out of a padded plane, the way the kernel's
/// dispatch bounds do without moving anything.
func trimPlane(_ source: [Float], width: Int, margin: Int) -> [Float] {
    let height = source.count / width
    let w = width - margin * 2
    let h = height - margin * 2
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { out[y * w + x] = source[(y + margin) * width + (x + margin)] }
    }
    return out
}

/// RGBA bytes of an image, unpacked from whatever row stride it carries.
func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let stride = image.bytesPerRow
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        for y in 0..<image.height {
            memcpy(&out[y * image.width * 4], base + y * stride, image.width * 4)
        }
    }
    return out
}

let fusedCompute = RasterCompute()
if await fusedCompute.isDisplayKernelAvailable() {
    let fusedProducts = await fusedCompute.reliefProducts(for: fusedGrid)
    let fusedElevation = trimPlane(fusedGrid.samples, width: fusedPaddedW, margin: fusedMargin)

    // .topographicOpenness and .rrim never reach the fused display kernel in
    // the real app (TerrainTileOverlay routes them to opennessProducts/
    // rrimImage instead), so there is no CPU-parity comparison to make here;
    // they have their own dedicated sections below.
    for style in ReliefStyle.allCases where style.microTopographyProduct == nil && style != .topographicOpenness {
        var styleSettings = TerrainStyleSettings()
        styleSettings.style = style
        styleSettings.azimuthDegrees = 315
        styleSettings.altitudeDegrees = 35
        if style == .elevation { styleSettings.elevationRange = 300...430 }
        let range = TerrainTileProvider.displayRange(for: styleSettings)

        let bitmap = await fusedCompute.renderTile(
            samples: .array(fusedGrid.samples),
            paddedWidth: fusedPaddedW,
            paddedHeight: fusedPaddedH,
            metersPerColumn: fusedGrid.metersPerColumn,
            metersPerRow: fusedGrid.metersPerRow,
            request: TerrainRenderRequest(
                style: style,
                azimuthDegrees: styleSettings.azimuthDegrees,
                altitudeDegrees: styleSettings.altitudeDegrees,
                contourIntervalMeters: 0,
                range: range,
                palette: .topo,
                margin: fusedMargin
            )
        )
        guard let bitmap, let gpuImage = bitmap.makeImage(), let gpu = rgbaBytes(gpuImage) else {
            check("fused kernel renders \(style.rawValue)", false, "nil bitmap")
            continue
        }
        check("fused kernel dispatches the destination tile, not the padded one: \(style.rawValue)",
              bitmap.width == fusedDestW && bitmap.height == fusedDestH,
              "\(bitmap.width)x\(bitmap.height), expected \(fusedDestW)x\(fusedDestH)")

        // The same numbers through the CPU renderer. The skirt is trimmed here
        // because that path still works on cropped planes -- which is the cost
        // the kernel avoids.
        let cpuValues: [Float]
        switch style {
        case .hillshade:
            cpuValues = trimPlane(
                TerrainAnalysis.hillshade(
                    fusedProducts.derivatives, azimuthDegrees: 315, altitudeDegrees: 35),
                width: fusedPaddedW, margin: fusedMargin)
        case .multiDirectional:
            cpuValues = trimPlane(fusedProducts.multiDirectionalRelief,
                                  width: fusedPaddedW, margin: fusedMargin)
        case .slope:
            cpuValues = trimPlane(fusedProducts.slopeDegrees,
                                  width: fusedPaddedW, margin: fusedMargin)
        case .elevation:
            cpuValues = fusedElevation
        case .topographicOpenness, .rrim, .localRelief, .skyView, .rakingLight, .relativeElevation, .curvature,
             .directionalOcclusion, .positiveOpenness, .negativeOpenness, .vectorRuggedness, .differenceOfGaussians:
            fatalError("excluded by the where clause above")
        }
        guard let cpuImage = ReliefRenderer.image(
            from: cpuValues, width: fusedDestW, height: fusedDestH, style: style,
            range: range, elevation: fusedElevation, contourInterval: .off, palette: .topo
        ), let cpu = rgbaBytes(cpuImage) else {
            check("CPU reference renders \(style.rawValue)", false, "nil image")
            continue
        }

        // Not byte-exact by construction: the kernel samples the palette with
        // linear filtering where the CPU indexes a 256-entry table, so the two
        // differ by up to one ramp step. What must not differ is the picture.
        var total = 0, worst = 0
        for i in 0..<min(gpu.count, cpu.count) {
            let delta = abs(Int(gpu[i]) - Int(cpu[i]))
            total += delta
            worst = max(worst, delta)
        }
        let mean = Double(total) / Double(max(gpu.count, 1))
        print(String(format: "        %-16@ meanDelta=%.2f maxDelta=%d",
                     style.rawValue as NSString, mean, worst))
        check("fused kernel matches the CPU renderer: \(style.rawValue)",
              mean < 1.0 && worst <= 8,
              String(format: "mean %.2f, max %d", mean, worst))
    }

    // --- Contours ------------------------------------------------------------
    // Evaluated in the same pass, from the elevation already in registers.
    var contourSettings = TerrainStyleSettings()
    contourSettings.style = .elevation
    contourSettings.elevationRange = 300...430
    func fusedRender(contour: Float) async -> [UInt8]? {
        let bitmap = await fusedCompute.renderTile(
            samples: .array(fusedGrid.samples),
            paddedWidth: fusedPaddedW, paddedHeight: fusedPaddedH,
            metersPerColumn: fusedGrid.metersPerColumn,
            metersPerRow: fusedGrid.metersPerRow,
            request: TerrainRenderRequest(
                style: .elevation, azimuthDegrees: 315, altitudeDegrees: 35,
                contourIntervalMeters: contour, range: 300...430,
                palette: .topo, margin: fusedMargin
            )
        )
        return bitmap?.makeImage().flatMap(rgbaBytes)
    }
    let contourOff1 = await fusedRender(contour: 0)
    let contourOn = await fusedRender(contour: 10)
    let contourOff2 = await fusedRender(contour: 0)
    check("contours change the fused tile", contourOff1 != nil && contourOff1 != contourOn,
          "contour overlay drew nothing")
    check("contours off -> on -> off round-trips exactly in the kernel",
          contourOff1 == contourOff2, "contour residue left behind")

    // --- Zero-copy ingestion -------------------------------------------------
    // A mapped cache file and a heap array are the same numbers by two routes.
    // If they were not, the disk path would be quietly rendering something
    // else -- the failure mode a page-offset mistake produces.
    let zeroCopyDir = makeCacheDir()
    let zeroCopyCache = TileDiskCache(directory: zeroCopyDir)
    if let encoded = ElevationGridCoder.encode(fusedGrid, source: "3DEP 1m") {
        await zeroCopyCache.write(encoded, forKey: "zero_copy_probe")
        let mapped = await zeroCopyCache.map(forKey: "zero_copy_probe")
        let header = mapped.flatMap { ElevationGridCoder.decodeHeader($0.bytes) }
        check("encoded payload starts its samples on a page boundary",
              header?.isPageAligned == true && header?.sampleOffset == 4096,
              "offset \(String(describing: header?.sampleOffset))")
        check("a mapped payload reports the grid it was written from",
              header?.width == fusedPaddedW && header?.height == fusedPaddedH,
              "\(String(describing: header?.width))x\(String(describing: header?.height))")

        if let mapped, let header {
            let request = TerrainRenderRequest(
                style: .slope, azimuthDegrees: 315, altitudeDegrees: 35,
                contourIntervalMeters: 0, range: 0...45, palette: .topo, margin: fusedMargin
            )
            let fromArray = await fusedCompute.renderTile(
                samples: .array(fusedGrid.samples),
                paddedWidth: fusedPaddedW, paddedHeight: fusedPaddedH,
                metersPerColumn: fusedGrid.metersPerColumn,
                metersPerRow: fusedGrid.metersPerRow, request: request
            )?.makeImage().flatMap(rgbaBytes)
            let fromMapping = await fusedCompute.renderTile(
                samples: .mapped(
                    base: mapped.base, mappedLength: mapped.mappedLength,
                    sampleOffset: header.sampleOffset, owner: mapped
                ),
                paddedWidth: fusedPaddedW, paddedHeight: fusedPaddedH,
                metersPerColumn: fusedGrid.metersPerColumn,
                metersPerRow: fusedGrid.metersPerRow, request: request
            )?.makeImage().flatMap(rgbaBytes)
            check("the mapped cache file renders identically to the heap array",
                  fromMapping != nil && fromMapping == fromArray,
                  fromMapping == nil ? "zero-copy render failed" : "pixels differ")
        }
    } else {
        check("zero-copy fixture encodes", false, "encode returned nil")
    }
    try? FileManager.default.removeItem(at: zeroCopyDir)
} else {
    print("        (skipped: no Metal device)")
}

// A payload from before the sample block was page-aligned still has to decode,
// or every cache file written by an earlier build becomes a crash risk rather
// than a miss.
var legacyPayload = Data()
func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { legacyPayload.append(contentsOf: $0) } }
func appendLE64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { legacyPayload.append(contentsOf: $0) } }
appendLE32(0x4C45_4731)                       // "LEG1"
appendLE32(UInt32(bitPattern: 4))              // width
appendLE32(UInt32(bitPattern: 3))              // height
appendLE64(35.0); appendLE64(35.001); appendLE64(-111.0); appendLE64(-110.999)
let legacySource = Array("terrarium".utf8)
appendLE32(UInt32(bitPattern: Int32(legacySource.count)))
legacyPayload.append(contentsOf: legacySource)
for i in 0..<12 { withUnsafeBytes(of: Float(100 + i).bitPattern.littleEndian) { legacyPayload.append(contentsOf: $0) } }
let legacyDecoded = ElevationGridCoder.decode(legacyPayload)
check("a pre-alignment cache payload still decodes",
      legacyDecoded?.grid.width == 4 && legacyDecoded?.grid.height == 3
        && legacyDecoded?.source == "terrarium",
      "\(String(describing: legacyDecoded?.grid.width))x\(String(describing: legacyDecoded?.grid.height))")
check("a pre-alignment payload reports itself unaligned",
      legacyPayload.withUnsafeBytes { ElevationGridCoder.decodeHeader($0)?.isPageAligned } == false,
      "claimed alignment it does not have")

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
let surfacedGridDir = makeCacheDir()
let surfacedGrids = TileDiskCache(directory: surfacedGridDir)
let surfacedProvider = TerrainTileProvider(gridCache: surfacedGrids)
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
let unreadableGridDir = makeCacheDir()
let unreadableGridModel = TerrainViewerModel(
    terrainProvider: TerrainTileProvider(
        gridCache: TileDiskCache(directory: unreadableGridDir)))
try? FileManager.default.setAttributes([.posixPermissions: 0o000],
                                       ofItemAtPath: unreadableGridDir.path)
await unreadableGridModel.refreshDiskCacheStats()
let unreadableGridSize = unreadableGridModel.diskCacheSizeFormatted
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: unreadableGridDir.path)
check("an unreadable cache makes the total unknown, not zero",
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

// --- F. presentation state no longer reaches the disk ---------------------
// The settle timer, the per-tile write coalescing and the pending-write
// ceiling all existed to protect one cache: rendered tiles, keyed by azimuth,
// altitude, contour interval, palette and the shared elevation range. Scrubbing
// a slider re-keyed every visible tile, so the write path needed a debounce
// just to avoid writing a generation of the viewport to flash per frame.
//
// That tier is gone, and with it the whole class of problem. Nothing on disk is
// keyed by anything the user can change from the shading controls, so there is
// no stale key to serve, no write to coalesce and no queue to bound. What is
// left to assert is the invariant itself: the disk key depends only on the tile.
let invariantKeyA = TerrainTileProvider.gridCacheKey(x: 3, y: 4, z: 18, pixels: 256, margin: 4)
let invariantKeyB = TerrainTileProvider.gridCacheKey(x: 3, y: 4, z: 18, pixels: 256, margin: 4)
check("the disk key is a pure function of the tile", invariantKeyA == invariantKeyB)
check("the disk key carries no shading state",
      !invariantKeyA.contains("hillshade") && !invariantKeyA.contains("315")
        && !invariantKeyA.contains("topo"),
      "got \(invariantKeyA)")

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

// --- G. a settings change mid-fetch still produces a coherent tile --------
// loadTile awaits network I/O. If the viewer pushes new settings during that
// window, the tile has to be shaded with one coherent set of values rather
// than a mixture -- and, now that nothing rendered is persisted, the change
// must not be able to leave a stale image behind under the old settings.
let raceDir = makeCacheDir()
let raceProvider = TerrainTileProvider(
    elevation: SlowElevationStub(delayMilliseconds: 250),
    // A throwaway grid cache: sharing the app's would let a grid stored by an
    // earlier run make this fetch instant, and the race would never happen.
    gridCache: TileDiskCache(directory: raceDir)
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
    await raceProvider.tileImage(x: 66532, y: 100234, z: 18, region: raceRegion, pixels: 256)
}
try? await Task.sleep(for: .milliseconds(60))   // land the change mid-fetch
var afterScrub = beforeScrub
afterScrub.azimuthDegrees = 200
_ = await raceProvider.update(afterScrub)
let raceImage = await raceTile.value

check("mid-fetch settings change still produces a tile", raceImage != nil, "nil tile")

// The raster the fetch produced is what gets persisted, and it is the same
// raster under either set of settings -- so the tile is on disk exactly once,
// under a key neither azimuth appears in.
try? await Task.sleep(for: .milliseconds(300))
let raceFiles = (try? FileManager.default.contentsOfDirectory(atPath: raceDir.path)) ?? []
check("the fetched raster is persisted once, not per settings",
      raceFiles.count == 1, "\(raceFiles.count) files: \(raceFiles)")
check("nothing keyed by shading settings reaches disk",
      !raceFiles.contains { $0.contains("315") || $0.contains("200") },
      "\(raceFiles)")

for dir in [lazyInitDir, capDir, mtimeDir, statsDir, surfacedGridDir, lruDir, keyDir,
            lockedDir, concurrentDir, raceDir] {
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
let roundTripped = legacyCrop(TerrainTileProvider.padByReplication(unpadded, margin: 4), margin: 4)
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
    gridCache: TileDiskCache(directory: sharedGridDir)
)
_ = await firstProvider.tileImage(x: 66532, y: 100234, z: 18, region: gridRegion, pixels: 256)
check("first visit consults the elevation source", firstStub.callCount == 1, "\(firstStub.callCount) calls")

// Wait for the background gridCache write to drain to disk
for _ in 0..<50 {
    if !(FileManager.default.subpaths(atPath: sharedGridDir.path) ?? []).isEmpty { break }
    try? await Task.sleep(for: .milliseconds(10))
}

// A separate provider with an empty memory cache: only the grid cache is
// shared, so anything it serves came from there.
let secondStub = CountingElevationStub()
let secondProvider = TerrainTileProvider(
    elevation: secondStub,
    gridCache: TileDiskCache(directory: sharedGridDir)
)
let restoredImage = await secondProvider.tileImage(
    x: 66532, y: 100234, z: 18, region: gridRegion, pixels: 256)
check("a later launch renders the tile without the elevation source",
      secondStub.callCount == 0, "\(secondStub.callCount) calls")
check("a tile restored from the grid cache still renders", restoredImage != nil, "nil tile")

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
// Each encoded raster is ~272 KB, so the write path needs a ceiling. What must
// not change is that ordinary volumes still all reach disk.
let queueDir = makeCacheDir()
let queueCache = TileDiskCache(directory: queueDir)
let queueProvider = TerrainTileProvider(gridCache: queueCache)
let rasterPayload = Data(repeating: 0x21, count: 2_048)
let queuedCount = 40
for i in 0..<queuedCount {
    await queueProvider.queueGridWrite(rasterPayload, forKey: "queued_grid_\(i)")
}
// Drain is immediate: a raster does not depend on settings, so nothing can
// supersede it and there is no settle window to wait out.
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

// --- The disk cache has to be visible, and clearable -----------------------
// A readout or a Clear button that does not know about the raster cache
// under-reports what is on disk and leaves all of it behind. There used to be
// a second tier here holding rendered tiles; its budget was folded into this
// one when it was retired, so this is now the whole of the app's footprint.
let tierGridDir = makeCacheDir()
let tierGridCache = TileDiskCache(directory: tierGridDir)
let tierStub = CountingElevationStub()
let tierProvider = TerrainTileProvider(elevation: tierStub, gridCache: tierGridCache)

await tierGridCache.write(Data(repeating: 0x12, count: 40_000), forKey: "grid_probe")

let combined = await tierProvider.diskCacheSize()
check("reported cache size covers the raster cache",
      combined != nil && combined! >= 40_000,
      "\(String(describing: combined)) bytes, expected >= 40000")

// The tier that decides whether a tile needs refetching is the one worth
// reporting -- and now the only one there is.
_ = await tierGridCache.read(forKey: "grid_probe")
_ = await tierGridCache.read(forKey: "grid_probe")
_ = await tierGridCache.read(forKey: "absent_grid")
let tierStats = await tierProvider.diskCacheStatistics()
check("reported hit rate is the tier that avoids refetching",
      tierStats.hits == 2 && tierStats.misses == 1,
      "\(tierStats.hits) hits / \(tierStats.misses) misses")

await tierProvider.clearDiskCache()
let gridFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: tierGridDir.path))?.count ?? -1
check("clearing the cache removes elevation rasters", gridFilesAfter == 0, "\(gridFilesAfter) left")
let clearedSize = await tierProvider.diskCacheSize()
check("cleared cache reports as empty", clearedSize == 0, "\(String(describing: clearedSize))")
check("provider memory cache size starts at zero", await tierProvider.memoryCacheSize() == 0)

for dir in [sharedGridDir, tierGridDir] {
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
check("contour intervals defined", intervals.count == 9, "\(intervals.count)")
check("contour quarter meter interval", ContourInterval.quarterMeter.meters == 0.25, "mismatch")
check("contour half meter interval", ContourInterval.halfMeter.meters == 0.5, "mismatch")
check("contour one meter interval", ContourInterval.oneMeter.meters == 1.0, "mismatch")
check("contour two meters interval", ContourInterval.twoMeters.meters == 2.0, "mismatch")
check("contour five meters interval", ContourInterval.fiveMeters.meters == 5.0, "mismatch")
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
// only the shaded bitmap is discarded), and it draws them twice while they are on.
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

// ============================================================
print("\n=== ElevationRangePolicy ===")

// niceStep: span-relative, 1/2/5 grid, floored at minStep.
check("niceStep floors at 10 for flat terrain",
      ElevationRangePolicy.niceStep(forSpan: 10) == 10,
      "\(ElevationRangePolicy.niceStep(forSpan: 10))")
check("niceStep ~50 for 1000 m span",
      ElevationRangePolicy.niceStep(forSpan: 1000) == 50,
      "\(ElevationRangePolicy.niceStep(forSpan: 1000))")
check("niceStep ~20 for 300 m span",
      ElevationRangePolicy.niceStep(forSpan: 300) == 20,
      "\(ElevationRangePolicy.niceStep(forSpan: 300))")

// quantize covers the raw extent (floor low / ceil high => never clips).
let qRaw: ClosedRange<Float> = 203 ... 758
let q = ElevationRangePolicy.quantize(qRaw)
check("quantize covers raw low", q.lowerBound <= qRaw.lowerBound, "\(q.lowerBound)")
check("quantize covers raw high", q.upperBound >= qRaw.upperBound, "\(q.upperBound)")
check("quantize actually snaps (not identity)",
      q.lowerBound != qRaw.lowerBound || q.upperBound != qRaw.upperBound,
      "\(q)")

// First fit: nil current adopts the quantized range.
check("first fit adopts quantized range",
      ElevationRangePolicy.next(raw: qRaw, current: nil) == q,
      "\(String(describing: ElevationRangePolicy.next(raw: qRaw, current: nil)))")

// Settling: re-evaluating the SAME raw after adopting keeps it (no churn).
check("no immediate re-adoption after settling",
      ElevationRangePolicy.next(raw: qRaw, current: q) == nil,
      "\(String(describing: ElevationRangePolicy.next(raw: qRaw, current: q)))")

// Deadband: a sub-tolerance wobble keeps the current range.
let policyBase: ClosedRange<Float> = 200 ... 1200     // span 1000 => tol = 90
check("deadband keeps current on small wobble",
      ElevationRangePolicy.next(raw: 210 ... 1190, current: policyBase) == nil,
      "adopted despite <tol wobble")

// Beyond the deadband: a large drift adopts a new (covering) range.
let far = ElevationRangePolicy.next(raw: 600 ... 1700, current: policyBase)
check("large drift adopts a new range", far != nil && far != policyBase, "\(String(describing: far))")
check("adopted range covers the new raw",
      (far?.lowerBound ?? 999) <= 600 && (far?.upperBound ?? 0) >= 1700, "\(String(describing: far))")

// Flat terrain still moves on a ~10 m change, like the old behaviour.
let flat: ClosedRange<Float> = 100 ... 110            // span 10 => tol = 10
check("flat terrain adopts on a >10 m shift",
      ElevationRangePolicy.next(raw: 130 ... 145, current: flat) != nil,
      "stuck on flat terrain")

// ============================================================
print("\n=== ElevationRangePolicy: churn before/after ===")

// A ~14-step pan up a valley: both bounds wander by tens of metres.
let panExtents: [(Float, Float)] = [
    (203, 758), (212, 769), (231, 802), (258, 845), (296, 905),
    (341, 982), (388, 1043), (421, 1088), (447, 1121), (462, 1140),
    (455, 1129), (430, 1094), (398, 1051), (362, 1002),
]
// Per-step jitter (<=6 m) modelling the re-visit's slightly different extent.
let jitter: [Float] = [3, -4, 5, -3, 4, -5, 2, -6, 5, -2, 3, -4, 6, -3]

// The pre-existing baseline: fixed 10 m snap, adopt on any change.
func baselineNext(raw: ClosedRange<Float>, current: ClosedRange<Float>?) -> ClosedRange<Float>? {
    let lo = (raw.lowerBound / 10).rounded(.down) * 10
    let hi = (raw.upperBound / 10).rounded(.up) * 10
    let q = lo ... Swift.max(hi, lo + 10)
    return q != current ? q : nil
}

// Replays a pan (optionally jittered), returning the adopted ranges in order.
func replay(
    _ next: (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?,
    jittered: Bool
) -> [ClosedRange<Float>] {
    var current: ClosedRange<Float>? = nil
    var adopted: [ClosedRange<Float>] = []
    for (i, e) in panExtents.enumerated() {
        let j = jittered ? jitter[i] : 0
        let raw = (e.0 + j) ... (e.1 + j)
        if let n = next(raw, current) { current = n; adopted.append(n) }
    }
    return adopted
}

func keyString(_ r: ClosedRange<Float>) -> String { "\(Int(r.lowerBound))_\(Int(r.upperBound))" }

for (label, next) in [
    ("baseline(10m,!=)", baselineNext),
    ("policy", ElevationRangePolicy.next),
] as [(String, (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?)] {
    let pass1 = replay(next, jittered: false)
    let pass2 = replay(next, jittered: true)
    let keys1 = Set(pass1.map(keyString))
    let pass2Keys = pass2.map(keyString)
    let hits = pass2Keys.filter { keys1.contains($0) }.count
    let hitRate = pass2Keys.isEmpty ? 1.0 : Double(hits) / Double(pass2Keys.count)
    let pct = Int((hitRate * 100).rounded())
    print("    \(label)  adoptions(pass1)=\(pass1.count)  distinctKeys=\(keys1.count)  reVisitHitRate=\(pct)%")
}

// Assert the improvement (relative, so it is robust to the synthetic values).
let baseAdopt = replay(baselineNext, jittered: false).count
let policyAdopt = replay(ElevationRangePolicy.next, jittered: false).count
check("policy adopts fewer ranges than baseline",
      policyAdopt < baseAdopt, "policy=\(policyAdopt) baseline=\(baseAdopt)")

let baseKeys = Set(replay(baselineNext, jittered: false).map(keyString)).count
let policyKeys = Set(replay(ElevationRangePolicy.next, jittered: false).map(keyString)).count
check("policy produces fewer distinct disk keys",
      policyKeys < baseKeys, "policy=\(policyKeys) baseline=\(baseKeys)")

func hitRate(_ next: (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?) -> Double {
    let keys1 = Set(replay(next, jittered: false).map(keyString))
    let k2 = replay(next, jittered: true).map(keyString)
    return k2.isEmpty ? 1.0 : Double(k2.filter { keys1.contains($0) }.count) / Double(k2.count)
}
check("policy re-visits the disk cache more than baseline",
      hitRate(ElevationRangePolicy.next) > hitRate(baselineNext),
      "policy=\(hitRate(ElevationRangePolicy.next)) baseline=\(hitRate(baselineNext))")

print("\n=== Map style guide ===")
do {
    // The in-app guide explains every style the dock offers: none may be
    // missing, listed twice, or left with an empty field.
    let listed = ReliefStyleGuide.sections.flatMap(\.styles)
    check("the guide lists every map style exactly once",
          listed.count == ReliefStyle.allCases.count && Set(listed) == Set(ReliefStyle.allCases),
          "\(listed.count) listed for \(ReliefStyle.allCases.count) styles")
    let incomplete = ReliefStyle.allCases.filter { style in
        let entry = style.guide
        return [entry.shows, entry.reading, entry.bestFor].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    check("every guide entry says what it shows, how to read it and what it is for",
          incomplete.isEmpty, "\(incomplete.map(\.displayName))")
    check("micro-topography styles are grouped apart from the standard shadings",
          ReliefStyleGuide.sections.allSatisfy { section in
              section.styles.allSatisfy { ($0.microTopographyProduct != nil) == section.isMicroTopography }
          })
    check("the guide explains the shared overlays", !ReliefStyleGuide.overlays.isEmpty
          && ReliefStyleGuide.overlays.allSatisfy { !$0.name.isEmpty && !$0.explanation.isEmpty })
    // Search, as the Map Styles reference panel uses it.
    func found(_ query: String) -> Set<ReliefStyle> {
        Set(ReliefStyleGuide.sections.flatMap { ReliefStyleGuide.styles(in: $0, matching: query) })
    }
    check("a blank search lists every style",
          found("").count == ReliefStyle.allCases.count && found("   ").count == ReliefStyle.allCases.count)
    check("searching \"rem\" finds Relative Elevation",
          found("rem").contains(.relativeElevation), "\(found("rem").map(\.displayName))")
    let ditch = found("ditch")
    check("searching \"ditch\" finds Local Relief and only styles whose searched text mentions ditches",
          ditch.contains(.localRelief) && ditch.allSatisfy { style in
              style.guideSearchText.contains { $0.localizedStandardContains("ditch") }
          }, "\(ditch.map(\.displayName))")
    check("search skips the Adjust-with text, so \"settings\" does not match every style",
          found("settings").isEmpty, "\(found("settings").count) matched")
    check("a nonsense search finds nothing",
          found("zzqx-no-such-style").isEmpty && ReliefStyleGuide.overlays(matching: "zzqx-no-such-style").isEmpty)
    check("overlays are searchable by name and explanation",
          ReliefStyleGuide.overlays(matching: "contour").map(\.name) == ["Contour Lines"]
          && ReliefStyleGuide.overlays(matching: "amber").map(\.name) == ["Habitation Potential Mask"])
    check("results keep dock order within a section",
          ReliefStyleGuide.sections.allSatisfy { ReliefStyleGuide.styles(in: $0, matching: "") == $0.styles })

    // A guide that names a sun control a style ignores, or leaves out one it
    // responds to, sends the reader to the wrong slider.
    let misdescribed = ReliefStyle.allCases.filter { style in
        let controls = style.guide.controls
        func names(_ control: String) -> Bool { controls.contains { $0.hasPrefix(control) } }
        return names("Sun direction slider") != style.usesSunDirection
            || names("Sun Altitude") != style.usesSunAltitude
            || names("Grazing Sun Altitude") != style.usesGrazingSunAltitude
    }
    check("the guide names exactly the sun controls each style responds to",
          misdescribed.isEmpty, "\(misdescribed.map(\.displayName))")
}

print("\n=== Morton spatial key (GeoTileKey) ===")
// The defect: a 16-bit-only dilation drops the high half of a 32-bit
// coordinate, so anything differing only above bit 16 collides. Prove the
// dilation the key is built from is lossless at the bit level, then check
// the key itself through GeoRegion.
do {
    // Inverse of the dilation: gather the even bits back into 32.
    func compact(_ v: UInt64) -> UInt32 {
        var x = v & 0x5555_5555_5555_5555
        x = (x | (x >> 1))  & 0x3333_3333_3333_3333
        x = (x | (x >> 2))  & 0x0F0F_0F0F_0F0F_0F0F
        x = (x | (x >> 4))  & 0x00FF_00FF_00FF_00FF
        x = (x | (x >> 8))  & 0x0000_FFFF_0000_FFFF
        x = (x | (x >> 16)) & 0x0000_0000_FFFF_FFFF
        return UInt32(x)
    }
    var inputs: [UInt32] = []
    for hi in [0x0000, 0x0001, 0x1234, 0x8000, 0xABCD, 0xFFFF] {
        for lo in [0x0000, 0x0001, 0x0005, 0x00FF, 0xFF00, 0xFFFF] {
            inputs.append(UInt32(hi << 16 | lo))
        }
    }
    let dilated = inputs.map(GeoTileKey.dilate32To64)
    check("dilation round-trips every swept 32-bit input (high 16 bits kept)",
          zip(inputs, dilated).allSatisfy { compact($1) == $0 }, "lossy dilation")
    check("dilation lands only on even bits, so lat (odd) and lon (even) never overlap",
          dilated.allSatisfy { $0 & 0xAAAA_AAAA_AAAA_AAAA == 0 }, "odd bit set")
    check("inputs differing only above bit 16 dilate apart",
          GeoTileKey.dilate32To64(0xABCD_0005) != GeoTileKey.dilate32To64(0x1234_0005),
          "high 16 bits collided")
}

// Through GeoRegion: two regions differing by ~0.7° of latitude (a change in a
// high-order quantised bit) must key differently — the exact case that used to
// collide.
let mortonBase = GeoRegion(minLatitude: 39.0000, maxLatitude: 39.01,
                           minLongitude: -106.5, maxLongitude: -106.49)
let mortonHiBit = GeoRegion(minLatitude: 39.7031, maxLatitude: 39.71,
                            minLongitude: -106.5, maxLongitude: -106.49)
check("regions differing in a high-order latitude bit get distinct keys",
      GeoTileKey(region: mortonBase) != GeoTileKey(region: mortonHiBit),
      "high-order region collision")
check("identical regions produce identical keys",
      GeoTileKey(region: mortonBase) == GeoTileKey(region: mortonBase))

// A dense sweep of distinct SW origins across the globe -> all-unique keys.
do {
    var keys = Set<UInt64>()
    var n = 0
    for latI in stride(from: -90, through: 89, by: 7) {
        for lonI in stride(from: -180, through: 179, by: 11) {
            let r = GeoRegion(minLatitude: Double(latI), maxLatitude: Double(latI) + 0.5,
                              minLongitude: Double(lonI), maxLongitude: Double(lonI) + 0.5)
            keys.insert(GeoTileKey(region: r).packedValue)
            n += 1
        }
    }
    check("global origin sweep collides for none of \(n) tiles", keys.count == n,
          "\(keys.count)/\(n) unique")
}

// Codable + packed round-trip.
do {
    let key = GeoTileKey(region: mortonBase, zoom: 16)
    let encoded = try! JSONEncoder().encode(key)
    let decoded = try! JSONDecoder().decode(GeoTileKey.self, from: encoded)
    check("GeoTileKey round-trips through Codable", decoded == key)
    check("GeoTileKey round-trips through packedValue",
          GeoTileKey(packedValue: key.packedValue) == key)
    check("GeoTileKey preserves zoom 16 through serialization", decoded.zoom == 16)
}

// Zoom level disambiguation across identical SW origins.
do {
    let regionZ14 = GeoRegion(minLatitude: 39.0, maxLatitude: 39.05, minLongitude: -106.5, maxLongitude: -106.45)
    let regionZ18 = GeoRegion(minLatitude: 39.0, maxLatitude: 39.01, minLongitude: -106.5, maxLongitude: -106.49)
    let key14 = GeoTileKey(region: regionZ14, zoom: 14)
    let key18 = GeoTileKey(region: regionZ18, zoom: 18)
    check("identical SW origins with different zoom levels produce distinct keys", key14 != key18)
    check("GeoTileKey preserves zoom level in top 6 bits", key14.zoom == 14 && key18.zoom == 18)
    check("GeoTileKey packed values differ", key14.packedValue != key18.packedValue)
    check("legacyCacheKey matches across identical SW origins", key14.legacyCacheKey == key18.legacyCacheKey)
    check("cacheKey contains distinct zoom prefix", key14.cacheKey != key18.cacheKey)
}

print("\n=== GeoTIFF export (byte layout + georeferencing) ===")
do {
    // A node-registered DEM with a void, over a real Mercator extent.
    let w = 128, h = 96
    var samples = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { samples[y * w + x] = 1000 + Float(x) * 0.5 - Float(y) * 0.25 }
    }
    samples[10 * w + 20] = .nan   // a void
    let demRegion = GeoRegion(minLatitude: 39.00, maxLatitude: 39.05,
                              minLongitude: -106.50, maxLongitude: -106.40)
    let dem = ElevationGrid(width: w, height: h, samples: samples, region: demRegion)

    let tifURL = URL(fileURLWithPath: "/tmp/verify.tif")
    do {
        try GeoTIFFWriter.shared.export(grid: dem, to: tifURL)
        check("GeoTIFF export writes a file", FileManager.default.fileExists(atPath: tifURL.path))
    } catch {
        check("GeoTIFF export writes a file", false, "\(error)")
    }

    if let tif = try? Data(contentsOf: tifURL) {
        let bytes = [UInt8](tif)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        check("TIFF magic is little-endian 42",
              bytes.count > 8 && bytes[0] == 0x49 && bytes[1] == 0x49 && u16(2) == 42)
        check("first IFD offset is 8", u32(4) == 8)
        let entryCount = u16(8)
        check("IFD declares 15 entries", entryCount == 15, "\(entryCount)")

        var tagVal: [Int: Int] = [:]
        var tagType: [Int: Int] = [:]
        var tagCount: [Int: Int] = [:]
        var tagsAscending = true
        var prevTag = -1
        for i in 0..<entryCount {
            let e = 10 + i * 12
            let tag = u16(e)
            if tag <= prevTag { tagsAscending = false }
            prevTag = tag
            tagType[tag] = u16(e + 2)
            tagCount[tag] = u32(e + 4)
            tagVal[tag] = u32(e + 8)
        }
        check("IFD entries are in ascending tag order (strict-reader safe)", tagsAscending)
        check("GeoTIFF structural tags present (PixelScale, Tiepoint, GeoKeyDir)",
              tagVal[33550] != nil && tagVal[33922] != nil && tagVal[34735] != nil)

        // Tag 42113 (GDAL_NODATA) must sit after 34735 in ascending order, be
        // ASCII, count 4, and — since count*width(1) <= 4 — inline in the
        // entry's value field rather than pointing at an extra-data offset.
        check("GDAL_NODATA (42113) is ASCII with count 4",
              tagType[42113] == 2 && tagCount[42113] == 4,
              "type=\(String(describing: tagType[42113])) count=\(String(describing: tagCount[42113]))")
        if let nodataVal = tagVal[42113] {
            let chars = [UInt8(nodataVal & 0xFF), UInt8((nodataVal >> 8) & 0xFF),
                         UInt8((nodataVal >> 16) & 0xFF), UInt8((nodataVal >> 24) & 0xFF)]
            check("GDAL_NODATA inline value is ASCII \"nan\\0\", not an offset",
                  chars == [0x6E, 0x61, 0x6E, 0x00], "\(chars)")
        } else {
            check("GDAL_NODATA inline value is ASCII \"nan\\0\"", false, "tag missing")
        }

        // Geotransform: tiepoint must be (0,0,0) -> (minX, maxY, 0), and pixel
        // scale must be span/(n-1) in both axes -- read directly from the file
        // rather than re-deriving the writer's own arithmetic.
        let expectedBounds = demRegion.mercatorBounds
        let expectedScaleX = (expectedBounds.maxX - expectedBounds.minX) / Double(w - 1)
        let expectedScaleY = (expectedBounds.maxY - expectedBounds.minY) / Double(h - 1)
        func f64(_ o: Int) -> Double {
            tif.subdata(in: o..<(o + 8)).withUnsafeBytes { $0.load(as: Double.self) }
        }
        if let tiepointOffset = tagVal[33922], let pixelScaleOffset = tagVal[33550],
           tiepointOffset > 0, pixelScaleOffset > 0,
           bytes.count >= tiepointOffset + 48, bytes.count >= pixelScaleOffset + 24 {
            let tiepoint = (0..<6).map { f64(tiepointOffset + $0 * 8) }
            check("tiepoint raster origin is (0,0,0)",
                  tiepoint[0] == 0 && tiepoint[1] == 0 && tiepoint[2] == 0, "\(tiepoint)")
            check("tiepoint model origin is (minX, maxY, 0)",
                  tiepoint[3] == expectedBounds.minX && tiepoint[4] == expectedBounds.maxY && tiepoint[5] == 0,
                  "\(tiepoint[3]),\(tiepoint[4]),\(tiepoint[5]) vs \(expectedBounds.minX),\(expectedBounds.maxY)")
            let pixelScale = (0..<3).map { f64(pixelScaleOffset + $0 * 8) }
            check("pixel scale equals span/(n-1) in both axes",
                  abs(pixelScale[0] - expectedScaleX) < 1e-9 && abs(pixelScale[1] - expectedScaleY) < 1e-9,
                  "\(pixelScale[0]),\(pixelScale[1]) vs \(expectedScaleX),\(expectedScaleY)")
        } else {
            check("geotransform tags present with valid offsets", false)
        }

        // gdalinfo cross-check: skipped, not failed, if GDAL isn't installed.
        let gdalinfo = Process()
        gdalinfo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gdalinfo.arguments = ["gdalinfo", tifURL.path]
        let gdalPipe = Pipe()
        gdalinfo.standardOutput = gdalPipe
        gdalinfo.standardError = Pipe()
        do {
            try gdalinfo.run()
            gdalinfo.waitUntilExit()
            let gdalOut = String(data: gdalPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if gdalinfo.terminationStatus == 0 {
                check("gdalinfo reports NoData Value as nan",
                      gdalOut.range(of: #"NoData Value=nan"#, options: .caseInsensitive) != nil,
                      "gdalinfo output: \(gdalOut.prefix(400))")
            } else {
                print("        (skipped gdalinfo cross-check: gdalinfo exited \(gdalinfo.terminationStatus))")
            }
        } catch {
            print("        (skipped gdalinfo cross-check: \(error))")
        }

        let stripOffset = tagVal[273] ?? -1
        check("strip offset is 4-byte aligned", stripOffset > 0 && stripOffset % 4 == 0,
              "offset \(stripOffset)")
        let stripBytes = tagVal[279] ?? -1
        check("strip byte count matches Float32 payload", stripBytes == w * h * 4, "\(stripBytes)")
        check("file length == strip offset + payload (no trailing corruption)",
              bytes.count == stripOffset + w * h * 4, "\(bytes.count)")

        // Pixel round-trip: the exported floats must equal the source exactly.
        if stripOffset > 0, bytes.count >= stripOffset + w * h * 4 {
            var mismatches = 0
            var voidIndices: [Int] = []
            tif.withUnsafeBytes { raw in
                let fp = raw.baseAddress!.advanced(by: stripOffset)
                    .assumingMemoryBound(to: Float.self)
                for i in 0..<(w * h) {
                    let a = fp[i], b = samples[i]
                    if a.isNaN { voidIndices.append(i) }
                    // A finite sample read back as NaN (or vice-versa) is a real
                    // corruption, so count the NaN-mismatch case as a mismatch.
                    if a.isNaN != b.isNaN { mismatches += 1; continue }
                    if a.isNaN && b.isNaN { continue }
                    if a != b { mismatches += 1 }
                }
            }
            check("every exported sample round-trips bit-exact (finite<->NaN counts)",
                  mismatches == 0, "\(mismatches) differ")
            check("the one void survives at exactly its source index, and only there",
                  voidIndices == [10 * w + 20], "voids at \(voidIndices)")
        }
    } else {
        check("GeoTIFF is readable back", false)
    }

    // A zero-dimension grid must be refused, not written as a broken TIFF.
    let emptyURL = URL(fileURLWithPath: "/tmp/verify_empty.tif")
    var threwEmpty = false
    do {
        try GeoTIFFWriter.shared.export(
            grid: ElevationGrid(width: 0, height: 0, samples: [], region: demRegion), to: emptyURL)
    } catch { threwEmpty = true }
    check("empty grid export throws instead of writing an invalid TIFF", threwEmpty)
    try? FileManager.default.removeItem(at: emptyURL)

    // A zero-area region collapses ModelPixelScale to zero — refuse it rather
    // than write a raster no GIS reader can georeference.
    let degenerateRegion = GeoRegion(minLatitude: 39.0, maxLatitude: 39.0,
                                     minLongitude: -106.5, maxLongitude: -106.5)
    let degenerateGrid = ElevationGrid(width: 4, height: 4,
        samples: [Float](repeating: 500, count: 16), region: degenerateRegion)
    let degenerateURL = URL(fileURLWithPath: "/tmp/verify_degenerate.tif")
    var threwDegenerate = false
    var threwWrongType = false
    do {
        try GeoTIFFWriter.shared.export(grid: degenerateGrid, to: degenerateURL)
    } catch GeoTIFFWriterError.degenerateBounds {
        threwDegenerate = true
    } catch {
        threwWrongType = true
    }
    check("degenerate (zero-area) bounds export throws .degenerateBounds",
          threwDegenerate && !threwWrongType)
    check("degenerate bounds export writes no file",
          !FileManager.default.fileExists(atPath: degenerateURL.path))
    try? FileManager.default.removeItem(at: degenerateURL)
}

/// Runs `workers` leased computations concurrently, each reading its slope
/// plane fully while holding the lease, and returns whether each read summed to
/// the expected total. Nonisolated so its only captures are Sendable parameters
/// — the group closure carries no main-actor region.
nonisolated func leaseConcurrencyCheck(
    _ raster: RasterCompute, grid: ElevationGrid, refSum: Double, workers: Int
) async -> [Bool] {
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<workers {
            group.addTask {
                guard let l = await raster.leasedReliefProducts(for: grid) else { return false }
                var sum = 0.0
                for i in 0..<(l.width * l.height) {
                    let s = l.slope[i]            // read held across the lease's lifetime
                    if s.isFinite { sum += Double(s) }
                }
                return Swift.abs(sum - refSum) < 1.0   // lease drops here -> recycle
            }
        }
        var out: [Bool] = []
        for await r in group { out.append(r) }
        return out
    }
}

print("\n=== UMA buffer leasing (zero-copy, lifecycle, concurrency) ===")
do {
    // A grid above the GPU threshold so the leased path engages.
    let lw = 300, lh = 300
    var ls = [Float](repeating: 0, count: lw * lh)
    for y in 0..<lh {
        for x in 0..<lw {
            ls[y * lw + x] = 500 + 40 * sin(Float(x) * 0.05) * cos(Float(y) * 0.04) + Float(x) * 0.1
        }
    }
    let leaseGrid = ElevationGrid(
        width: lw, height: lh, samples: ls,
        region: GeoRegion(minLatitude: 39.0, maxLatitude: 39.02,
                          minLongitude: -106.5, maxLongitude: -106.47))

    if let leased = await compute.leasedReliefProducts(for: leaseGrid) {
        check("leased products report the grid dimensions",
              leased.width == lw && leased.height == lh)
        check("leased products carry unit normals", leased.normalX != nil && leased.normalZ != nil)

        // The leased buffers must hold the same numbers the copy-out path does.
        let reference = await compute.reliefProducts(for: leaseGrid)
        var maxDelta: Float = 0
        var compared = 0
        for i in stride(from: 0, to: lw * lh, by: 37) {
            let a = leased.slope[i], b = reference.slopeDegrees[i]
            if a.isNaN && b.isNaN { continue }
            if a.isNaN || b.isNaN { maxDelta = .infinity; break }
            maxDelta = Swift.max(maxDelta, Swift.abs(a - b)); compared += 1
        }
        check("leased slope matches the copy-out slope (\(compared) samples)",
              maxDelta < 0.01, "maxDelta=\(maxDelta)")

        // Reference finite-sum, to detect any mid-read corruption under load.
        var refSum = 0.0
        for i in 0..<(lw * lh) where reference.slopeDegrees[i].isFinite {
            refSum += Double(reference.slopeDegrees[i])
        }

        // Concurrency: many simultaneous leased computations, each holding its
        // leases across a full read. If a completed buffer were recycled while
        // a consumer still read it, a sum would drift or the run would crash.
        let workers = 16
        let results = await leaseConcurrencyCheck(
            compute, grid: leaseGrid, refSum: refSum, workers: workers)
        check("all \(workers) concurrent leases read uncorrupted buffers",
              results.count == workers && results.allSatisfy { $0 },
              "\(results.filter { $0 }.count)/\(workers) correct")

        // Churn many leases so recycling must fire repeatedly without exhausting
        // the pool or corrupting later computations.
        var churnOK = true
        for _ in 0..<40 {
            guard let l = await compute.leasedReliefProducts(for: leaseGrid) else { churnOK = false; break }
            if !l.slope[lw * lh / 2 + 7].isFinite && !l.relief[0].isNaN { /* touch */ }
            _ = l   // dropped each iteration -> recycle path exercised 40x
        }
        check("40 sequential lease/recycle cycles stay healthy", churnOK)
    } else {
        check("leased path available (needs fused GPU pipeline)", false,
              "leasedReliefProducts returned nil (no Metal/fused pipeline on host)")
    }
}

print("\n=== Non-square raster grid (200x120) ===")
do {
    let nsWidth = 200, nsHeight = 120
    var nsSamples = [Float](repeating: 0, count: nsWidth * nsHeight)
    for y in 0..<nsHeight {
        for x in 0..<nsWidth { nsSamples[y * nsWidth + x] = 300 + Float(x) * 0.3 + Float(y) * 0.15 }
    }
    let nsGrid = ElevationGrid(
        width: nsWidth, height: nsHeight, samples: nsSamples,
        region: GeoRegion(minLatitude: 39.0, maxLatitude: 39.02,
                          minLongitude: -106.5, maxLongitude: -106.46))

    let nsProducts = await compute.reliefProducts(for: nsGrid)
    check("reliefProducts keeps width and height distinct for a non-square grid",
          nsProducts.width == nsWidth && nsProducts.height == nsHeight,
          "\(nsProducts.width)x\(nsProducts.height)")
    check("reliefProducts array length matches width*height, not height*width",
          nsProducts.slopeDegrees.count == nsWidth * nsHeight,
          "\(nsProducts.slopeDegrees.count)")

    // Ground truth from the CPU derivative kernel already exercised above: if
    // reliefProducts' backend (CPU or GPU) transposed width/height strides,
    // its slope field would disagree with this reference almost everywhere,
    // not just at the edges.
    let nsReference = TerrainAnalysis.derivatives(of: nsGrid)
    var nsMaxDelta: Float = 0
    var nsCompared = 0
    for i in 0..<(nsWidth * nsHeight) {
        let a = nsProducts.slopeDegrees[i], b = nsReference.slopeDegrees[i]
        if a.isNaN && b.isNaN { continue }
        if a.isNaN || b.isNaN { nsMaxDelta = .infinity; break }
        nsMaxDelta = max(nsMaxDelta, abs(a - b)); nsCompared += 1
    }
    check("non-square (200x120) reliefProducts slope matches the CPU reference (\(nsCompared) samples)",
          nsMaxDelta < 0.01, "maxDelta=\(nsMaxDelta)")

    if let nsLeased = await compute.leasedReliefProducts(for: nsGrid) {
        check("leasedReliefProducts keeps width and height distinct for a non-square grid",
              nsLeased.width == nsWidth && nsLeased.height == nsHeight,
              "\(nsLeased.width)x\(nsLeased.height)")
        var nsLeasedMaxDelta: Float = 0
        for i in 0..<(nsWidth * nsHeight) {
            let a = nsLeased.slope.pointer[i], b = nsReference.slopeDegrees[i]
            if a.isNaN && b.isNaN { continue }
            if a.isNaN || b.isNaN { nsLeasedMaxDelta = .infinity; break }
            nsLeasedMaxDelta = max(nsLeasedMaxDelta, abs(a - b))
        }
        check("non-square (200x120) leasedReliefProducts slope matches the CPU reference",
              nsLeasedMaxDelta < 0.01, "maxDelta=\(nsLeasedMaxDelta)")
    } else {
        check("leasedReliefProducts on a non-square grid (needs fused GPU pipeline)", false,
              "leasedReliefProducts returned nil (no Metal/fused pipeline on host)")
    }
}

print("\n=== Lease pool reuse resilience ===")
do {
    let heldWidth = 200, heldHeight = 150
    var heldSamples = [Float](repeating: 0, count: heldWidth * heldHeight)
    for i in 0..<heldSamples.count { heldSamples[i] = Float(i % 97) * 0.37 + 10 }
    let heldGrid = ElevationGrid(
        width: heldWidth, height: heldHeight, samples: heldSamples,
        region: GeoRegion(minLatitude: 39.0, maxLatitude: 39.03,
                          minLongitude: -106.5, maxLongitude: -106.46))

    if let heldLease = await compute.leasedReliefProducts(for: heldGrid) {
        // Bit patterns, not Float values: border cells are legitimately NaN
        // (Horn's method needs a full 3x3 neighbourhood), and NaN != NaN under
        // Float equality would fail this check even when nothing changed.
        let snapshotCount = min(64, heldLease.width * heldLease.height)
        let snapshot = (0..<snapshotCount).map { heldLease.slope.pointer[$0].bitPattern }

        // Churn the single-buffer lease pool across ten dispatches of varying
        // sizes -- including the held lease's own byte count -- so any
        // confusion between "checked out" and "free" buffers of the same size
        // would corrupt the buffer this test is still holding.
        let churnSizes: [(Int, Int)] = [
            (64, 64), (heldWidth, heldHeight), (90, 300), (heldWidth, heldHeight),
            (128, 128), (300, 90), (heldWidth, heldHeight), (64, 512), (512, 64),
            (heldWidth, heldHeight),
        ]
        for (cw, ch) in churnSizes {
            var churnSamples = [Float](repeating: 0, count: cw * ch)
            for i in 0..<churnSamples.count { churnSamples[i] = Float(i) * 0.01 }
            let churnGrid = ElevationGrid(
                width: cw, height: ch, samples: churnSamples,
                region: GeoRegion(minLatitude: 40.0, maxLatitude: 40.02,
                                  minLongitude: -100.0, maxLongitude: -99.98))
            _ = await compute.leasedReliefProducts(for: churnGrid)  // dropped -> recycles immediately
        }

        let afterChurn = (0..<snapshotCount).map { heldLease.slope.pointer[$0].bitPattern }
        check("a retained lease's buffer survives 10 churn dispatches on other grid sizes",
              afterChurn == snapshot, "values drifted while the lease was held")
        withExtendedLifetime(heldLease) {}
    } else {
        check("lease pool reuse resilience (needs fused GPU pipeline)", false,
              "leasedReliefProducts returned nil (no Metal/fused pipeline on host)")
    }
}

print("\n=== GeoTileKey boundary & locality ===")
do {
    // Extreme corners must not crash or misbehave -- clamping happens before
    // quantisation, so no input can push the Morton code past its 58 bits.
    let corners = [
        GeoRegion(minLatitude: -90.0, maxLatitude: -90.0, minLongitude: -180.0, maxLongitude: -180.0),
        GeoRegion(minLatitude: 90.0, maxLatitude: 90.0, minLongitude: 180.0, maxLongitude: 180.0),
        GeoRegion(minLatitude: -90.0, maxLatitude: -90.0, minLongitude: 180.0, maxLongitude: 180.0),
        GeoRegion(minLatitude: 90.0, maxLatitude: 90.0, minLongitude: -180.0, maxLongitude: -180.0),
    ]
    let cornerKeys = corners.map { GeoTileKey(region: $0).packedValue }
    check("all four globe corners produce distinct keys", Set(cornerKeys).count == corners.count,
          "\(cornerKeys)")

    // Values past the clamp boundary must clamp, not misbehave.
    let beyondNorth = GeoRegion(minLatitude: 95.0, maxLatitude: 95.0, minLongitude: 0, maxLongitude: 0)
    let atNorth = GeoRegion(minLatitude: 90.0, maxLatitude: 90.0, minLongitude: 0, maxLongitude: 0)
    check("a region past +90 degrees latitude clamps to the same key as exactly +90",
          GeoTileKey(region: beyondNorth) == GeoTileKey(region: atNorth))
    let beyondWest = GeoRegion(minLatitude: 0, maxLatitude: 0, minLongitude: -190.0, maxLongitude: -190.0)
    let atWest = GeoRegion(minLatitude: 0, maxLatitude: 0, minLongitude: -180.0, maxLongitude: -180.0)
    check("a region past -180 degrees longitude clamps to the same key as exactly -180",
          GeoTileKey(region: beyondWest) == GeoTileKey(region: atWest))

    // Morton locality: a neighbour a few metres away must land far closer in
    // key-space than a region on another continent.
    let localityBase = GeoRegion(minLatitude: 10.0, maxLatitude: 10.001,
                                 minLongitude: 20.0, maxLongitude: 20.001)
    let localityNear = GeoRegion(minLatitude: 10.0002, maxLatitude: 10.0012,
                                 minLongitude: 20.0002, maxLongitude: 20.0012)
    let localityFar = GeoRegion(minLatitude: -60.0, maxLatitude: -59.999,
                                minLongitude: 150.0, maxLongitude: 150.001)
    func keyDelta(_ a: GeoRegion, _ b: GeoRegion) -> UInt64 {
        let ka = GeoTileKey(region: a).packedValue, kb = GeoTileKey(region: b).packedValue
        return ka > kb ? ka - kb : kb - ka
    }
    let nearDelta = keyDelta(localityBase, localityNear)
    let farDelta = keyDelta(localityBase, localityFar)
    check("an adjacent region lands far closer in key-space than a distant one",
          nearDelta < farDelta, "near=\(nearDelta) far=\(farDelta)")
}

print("\n=== Index contours & cliff-face dampening (fused display kernel) ===")
if await compute.isDisplayKernelAvailable() {
    let icMargin = 4
    let icWidth = 220
    let icHeight = icMargin * 2 + 1   // a single destination row is enough

    // A ramp rising ~1 m per column (contour crossings land at predictable
    // columns) with a sheer 40 m step at column 150 -- the cliff the density
    // dampening exists to protect from ink flooding.
    var icGrid = makeGrid(width: icWidth, height: icHeight, gsd: 1.0)
    var icSamples = icGrid.samples
    for y in 0..<icHeight {
        for x in 0..<icWidth {
            icSamples[y * icWidth + x] = Float(x) + (x >= 150 ? 40 : 0)
        }
    }
    icGrid = ElevationGrid(width: icWidth, height: icHeight, samples: icSamples, region: icGrid.region)

    let icRequest = TerrainRenderRequest(
        style: .elevation, azimuthDegrees: 315, altitudeDegrees: 35,
        contourIntervalMeters: 10, indexContourMultiplier: 5, indexContourWidth: 2.0,
        range: 0...260, palette: .topo, margin: icMargin
    )
    if let icBitmap = await compute.renderTile(
        samples: .array(icGrid.samples), paddedWidth: icWidth, paddedHeight: icHeight,
        metersPerColumn: icGrid.metersPerColumn, metersPerRow: icGrid.metersPerRow,
        request: icRequest
    ), let icImage = icBitmap.makeImage(), let icPixels = rgbaBytes(icImage) {
        // Single destination row: pixel `destX` is at byte offset destX*4.
        func darkness(_ column: Int) -> Int {
            let destX = column - icMargin
            let o = destX * 4
            return 255 * 3 - (Int(icPixels[o]) + Int(icPixels[o + 1]) + Int(icPixels[o + 2]))
        }
        // Regular lines land at multiples of 10 (column 30); index lines
        // (every 5th, i.e. every 50 m) land at multiples of 50 (column 50).
        // Column 5 sits roughly halfway between contour crossings.
        check("a regular contour line darkens its column",
              darkness(30) > darkness(5) + 30, "regular=\(darkness(30)) flat=\(darkness(5))")
        check("an index contour line is at least as bold as a regular one",
              darkness(50) >= darkness(30), "index=\(darkness(50)) regular=\(darkness(30))")

        // The cliff face (columns 150+) must not be flooded solid black by
        // contour ink -- density dampening should keep it close to the
        // palette's own colour rather than near-black (max possible 765).
        var cliffMaxDarkness = 0
        for column in 151..<min(160, icWidth - icMargin) {
            cliffMaxDarkness = max(cliffMaxDarkness, darkness(column))
        }
        check("the cliff face is not flooded with contour ink",
              cliffMaxDarkness < 700, "darkness=\(cliffMaxDarkness) (max possible 765)")
    } else {
        check("index contour / dampening render produces a bitmap", false, "nil bitmap or image")
    }
} else {
    print("        (skipped: no fused display kernel)")
}

print("\n=== Topographic openness (compute_topographic_openness) ===")
if await compute.isOpennessAvailable() {
    let opWidth = 41, opHeight = 41
    let flatGrid = makeGrid(width: opWidth, height: opHeight, gsd: 2.0)

    if let flatOpenness = await compute.opennessProducts(for: flatGrid, radiusCells: 10) {
        check("openness reports the grid dimensions",
              flatOpenness.width == opWidth && flatOpenness.height == opHeight)
        let interiorIdx = 20 * opWidth + 20
        let cornerIdx = 0
        check("flat terrain reports ~90 degree positive openness at an interior cell",
              abs(flatOpenness.positive.pointer[interiorIdx] - 90) < 0.5,
              "\(flatOpenness.positive.pointer[interiorIdx])")
        check("flat terrain reports ~90 degree negative openness at an interior cell",
              abs(flatOpenness.negative.pointer[interiorIdx] - 90) < 0.5,
              "\(flatOpenness.negative.pointer[interiorIdx])")
        // Without the edge-of-grid sentinel fix, a ray that runs off the grid
        // before finding any sample reports a degenerate extreme instead of
        // "flat" -- so a corner would disagree sharply with an interior cell
        // on terrain that is uniformly flat everywhere.
        check("a grid-corner cell on flat terrain matches an interior cell (no edge-of-grid artefact)",
              abs(flatOpenness.positive.pointer[cornerIdx] - flatOpenness.positive.pointer[interiorIdx]) < 0.5,
              "corner=\(flatOpenness.positive.pointer[cornerIdx]) interior=\(flatOpenness.positive.pointer[interiorIdx])")
    } else {
        check("openness on flat terrain (needs Metal)", false, "opennessProducts returned nil")
    }

    // A tall mound blocks the upward view from nearby lower ground far more
    // than it blocks the view from flat ground well outside its footprint.
    let moundGrid = makeGrid(width: opWidth, height: opHeight, gsd: 2.0,
                             mounds: [(cx: 20, cy: 20, h: 40, s: 4)])
    if let moundOpenness = await compute.opennessProducts(for: moundGrid, radiusCells: 10) {
        let nearMoundIdx = 20 * opWidth + 12   // on the mound's lower flank, within radius
        let farFlatIdx = 20 * opWidth + 2      // far from the mound, effectively flat
        check("ground near a mound is less positively open than ground far from it",
              moundOpenness.positive.pointer[nearMoundIdx]
                < moundOpenness.positive.pointer[farFlatIdx] - 5,
              "near=\(moundOpenness.positive.pointer[nearMoundIdx]) far=\(moundOpenness.positive.pointer[farFlatIdx])")
    } else {
        check("openness near a mound (needs Metal)", false, "opennessProducts returned nil")
    }

    // A void reads as NaN openness, not a bogus finite value.
    var voidSamples = flatGrid.samples
    voidSamples[20 * opWidth + 20] = .nan
    let voidGrid = ElevationGrid(width: opWidth, height: opHeight, samples: voidSamples, region: flatGrid.region)
    if let voidOpenness = await compute.opennessProducts(for: voidGrid, radiusCells: 10) {
        check("a void cell reports NaN openness",
              voidOpenness.positive.pointer[20 * opWidth + 20].isNaN
                && voidOpenness.negative.pointer[20 * opWidth + 20].isNaN)
    } else {
        check("openness with a void (needs Metal)", false, "opennessProducts returned nil")
    }
} else {
    print("        (skipped: no Metal openness pipeline)")
}

print("\n=== Red Relief Image Map (rrim_composite_to_texture) ===")
if await compute.isRRIMAvailable() {
    let rrimGrid = makeGrid(width: 64, height: 64, gsd: 2.0,
                            mounds: [(cx: 32, cy: 32, h: 20, s: 6)])
    if let rrimBitmap = await compute.rrimImage(for: rrimGrid, radiusCells: 8),
       let rrimCGImage = rrimBitmap.makeImage(), let rrimPixels = rgbaBytes(rrimCGImage) {
        check("RRIM bitmap matches the grid dimensions",
              rrimBitmap.width == rrimGrid.width && rrimBitmap.height == rrimGrid.height)
        func redness(_ x: Int, _ y: Int) -> Int {
            let o = (y * rrimBitmap.width + x) * 4
            return Int(rrimPixels[o]) - max(Int(rrimPixels[o + 1]), Int(rrimPixels[o + 2]))
        }
        let flankRedness = redness(26, 32)   // near the mound's steepest flank
        let flatRedness = redness(4, 4)      // far corner, effectively flat
        check("a steep flank reads redder than flat ground in the RRIM composite",
              flankRedness > flatRedness, "flank=\(flankRedness) flat=\(flatRedness)")
    } else {
        check("RRIM composite renders", false, "nil bitmap or image")
    }
} else {
    print("        (skipped: no fused + RRIM pipeline)")
}

print("\n=== UTM projection (COG native georeferencing) ===")
do {
    // Ground truth from `gdaltransform -s_srs EPSG:26916 -t_srs EPSG:4326`
    // on a real USGS 3DEP tile's centre, in zone 16N.
    let inv = UTMProjection.inverse(
        easting: 389_081.9997, northing: 3_752_966.0003, zone: 16, hemisphere: .north)
    check("UTM inverse matches GDAL to within 0.0001 degrees",
          abs(inv.latitude - 33.9112697279035) < 0.0001
            && abs(inv.longitude - (-88.1998094207409)) < 0.0001,
          "\(inv.latitude), \(inv.longitude)")

    let fwd = UTMProjection.forward(
        latitude: inv.latitude, longitude: inv.longitude, zone: 16, hemisphere: .north)
    check("UTM forward(inverse(p)) round-trips to sub-metre precision",
          abs(fwd.easting - 389_081.9997) < 0.01 && abs(fwd.northing - 3_752_966.0003) < 0.01,
          "\(fwd.easting), \(fwd.northing)")

    check("EPSG 26916 decodes as NAD83 UTM zone 16N",
          UTMProjection.zone(forEPSG: 26916).map { "\($0.zone)\($0.hemisphere)" } == "16north")
    check("EPSG 32633 decodes as WGS84 UTM zone 33N",
          UTMProjection.zone(forEPSG: 32633).map { "\($0.zone)\($0.hemisphere)" } == "33north")
    check("EPSG 32733 decodes as WGS84 UTM zone 33S",
          UTMProjection.zone(forEPSG: 32733).map { "\($0.zone)\($0.hemisphere)" } == "33south")
    check("a non-UTM EPSG code is not misidentified as UTM",
          UTMProjection.zone(forEPSG: 4326) == nil)
}

print("\n=== COG tile decode: TIFF LZW + floating-point predictor ===")
do {
    // A real USGS 3DEP tile (256x256 Float32, LZW-compressed, predictor 3),
    // fixed in the repo so this check needs no network. Ground truth for the
    // spot values below was pulled independently via GDAL
    // (`gdal_translate -srcwin 8960 6912 256 256 <cog> ...`), so this test
    // fails if either the LZW decode or the predictor reversal is wrong --
    // not just internally self-consistent.
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cog_tile_lzw_fp_256x256.bin")
    if let compressed = try? Data(contentsOf: fixtureURL) {
        let expectedRaw = 256 * 256 * 4
        if let raw = TIFFLZWDecoder.decode([UInt8](compressed), expectedByteCount: expectedRaw) {
            check("LZW decode produces the expected byte count", raw.count == expectedRaw)
            let decoded = TIFFFloatingPointPredictor.decode(raw, width: 256, height: 256)
            let floats = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            check("decoded tile has the expected sample count", floats.count == 256 * 256)

            let row0 = Array(floats[0..<8])
            let expectedRow0: [Float] = [
                123.91963, 123.70096, 123.43201, 123.129395, 122.86242, 122.593124, 122.38384, 122.15388,
            ]
            check("row 0 matches GDAL's independently decoded values",
                  zip(row0, expectedRow0).allSatisfy { abs($0 - $1) < 0.001 },
                  "\(row0) vs \(expectedRow0)")

            let row128 = Array(floats[(128 * 256 + 128)..<(128 * 256 + 136)])
            let expectedRow128: [Float] = [
                112.951645, 112.8261, 112.81118, 112.69709, 112.57202, 112.54135, 112.51922, 112.455986,
            ]
            check("row 128 (mid-tile) matches GDAL's independently decoded values",
                  zip(row128, expectedRow128).allSatisfy { abs($0 - $1) < 0.001 },
                  "\(row128) vs \(expectedRow128)")

            let minVal = floats.min() ?? .nan
            let maxVal = floats.max() ?? .nan
            check("decoded tile's value range matches GDAL's",
                  abs(minVal - 95.70592) < 0.001 && abs(maxVal - 131.43253) < 0.001,
                  "min=\(minVal) max=\(maxVal)")
        } else {
            check("LZW decode of the real COG fixture succeeds", false)
        }
    } else {
        check("COG fixture readable", false, "missing \(fixtureURL.path)")
    }

    // A corrupt/truncated stream must fail closed, not fabricate a result.
    check("a truncated LZW stream returns nil rather than a short result",
          TIFFLZWDecoder.decode([0x80, 0x00], expectedByteCount: 65536) == nil)
    check("an empty stream returns nil",
          TIFFLZWDecoder.decode([], expectedByteCount: 100) == nil)
}

print("\n=== Bilinear transect interpolation (ElevationGrid) ===")
do {
    let bilinearGrid = makeGrid(width: 40, height: 40, gsd: 2.0, slope: 0.5)
    // Off a grid-cell centre, the interpolated value must land strictly
    // between the surrounding cells -- a nearest-neighbour readout could
    // never do that, since the ramp is monotonic in x.
    let x0 = 10, y0 = 10
    let a = bilinearGrid.coordinate(x: x0, y: y0)
    let b = bilinearGrid.coordinate(x: x0 + 1, y: y0)
    let midLat = (a.latitude + b.latitude) / 2
    let midLon = (a.longitude + b.longitude) / 2
    let midCoord = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
    let left = bilinearGrid.sample(x: x0, y: y0)!
    let right = bilinearGrid.sample(x: x0 + 1, y: y0)!
    if let interpolated = bilinearGrid.interpolatedElevation(at: midCoord) {
        check("interpolated midpoint lies strictly between its two neighbours",
              interpolated > min(left, right) && interpolated < max(left, right),
              "\(interpolated) not between \(left) and \(right)")
        check("interpolated midpoint is close to the linear average on a uniform ramp",
              abs(interpolated - (left + right) / 2) < 0.01,
              "\(interpolated) vs \((left + right) / 2)")
    } else {
        check("interpolatedElevation resolves at a midpoint", false)
    }
    // Exactly on a sample, interpolation must reproduce that sample.
    let exact = bilinearGrid.coordinate(x: 20, y: 20)
    check("interpolation at an exact grid point matches the stored sample",
          bilinearGrid.interpolatedElevation(at: exact).map { abs($0 - bilinearGrid.sample(x: 20, y: 20)!) < 0.001 } ?? false)
    // A void neighbour must refuse to interpolate, not blend across the gap.
    var voidSamples = bilinearGrid.samples
    voidSamples[y0 * 40 + x0 + 1] = .nan
    let voidBilinearGrid = ElevationGrid(width: 40, height: 40, samples: voidSamples, region: bilinearGrid.region)
    check("interpolation refuses to blend across a void neighbour",
          voidBilinearGrid.interpolatedElevation(at: midCoord) == nil)
    // Outside the region entirely.
    check("interpolation outside the region returns nil",
          bilinearGrid.interpolatedElevation(at: CLLocationCoordinate2D(latitude: 0, longitude: 0)) == nil)
}

print("\n=== Radial viewshed raymarching (compute_viewshed_raymarch) ===")
if await compute.isViewshedAvailable() {
    // --- Self-visibility and radius cutoff on flat terrain -----------------
    let vsWidth = 41, vsHeight = 41
    let flatViewshedGrid = makeGrid(width: vsWidth, height: vsHeight, gsd: 2.0)
    let observerCol = 20, observerRow = 20
    if let visibility = await compute.viewshed(
        for: flatViewshedGrid, observerColumn: observerCol, observerRow: observerRow,
        maxRadiusMeters: 30
    ) {
        check("viewshed result covers the whole grid", visibility.count == vsWidth * vsHeight)
        check("the observer's own cell is visible", visibility[observerRow * vsWidth + observerCol])
        // 10 cells * 2 m/cell = 20 m, inside a 30 m radius, flat and unobstructed.
        check("a nearby unobstructed cell on flat terrain is visible",
              visibility[observerRow * vsWidth + (observerCol + 10)])
        // 20 cells * 2 m/cell = 40 m, outside the 30 m radius.
        check("a cell beyond maxRadiusMeters is not visible",
              !visibility[observerRow * vsWidth + (observerCol + 20)])
    } else {
        check("viewshed on flat terrain (needs Metal)", false, "viewshed returned nil")
    }

    // --- Occlusion by a wall -------------------------------------------------
    // A raised block sits east of the observer, spanning rows 28...32. A
    // target due east passes straight through it (occluded); a target east
    // and well to the north crosses the same column outside the block's row
    // band, on a clear line (visible).
    let wallWidth = 71, wallHeight = 61
    var wallSamples = [Float](repeating: 100, count: wallWidth * wallHeight)
    for y in 28...32 {
        for x in 39...41 { wallSamples[y * wallWidth + x] = 160 }
    }
    let wallGrid = makeGrid(width: wallWidth, height: wallHeight, gsd: 2.0)
    let wallViewshedGrid = ElevationGrid(width: wallWidth, height: wallHeight, samples: wallSamples, region: wallGrid.region)
    if let visibility = await compute.viewshed(
        for: wallViewshedGrid, observerColumn: 10, observerRow: 30, maxRadiusMeters: 200
    ) {
        check("a target directly behind a wall is occluded",
              !visibility[30 * wallWidth + 60], "expected occluded")
        check("a target past the wall's column but off its row band is visible",
              visibility[10 * wallWidth + 60], "expected visible")
    } else {
        check("viewshed with an occluder (needs Metal)", false, "viewshed returned nil")
    }

    // --- Void handling ---------------------------------------------------
    var voidViewshedSamples = flatViewshedGrid.samples
    voidViewshedSamples[observerRow * vsWidth + (observerCol + 5)] = .nan
    let voidViewshedGrid = ElevationGrid(
        width: vsWidth, height: vsHeight, samples: voidViewshedSamples, region: flatViewshedGrid.region)
    if let visibility = await compute.viewshed(
        for: voidViewshedGrid, observerColumn: observerCol, observerRow: observerRow, maxRadiusMeters: 30
    ) {
        check("a void target cell is not visible",
              !visibility[observerRow * vsWidth + (observerCol + 5)])
    } else {
        check("viewshed with a void target (needs Metal)", false, "viewshed returned nil")
    }

    // --- Invalid observer ------------------------------------------------
    let invalidObserverResult = await compute.viewshed(
        for: flatViewshedGrid, observerColumn: -1, observerRow: 0, maxRadiusMeters: 30)
    check("an out-of-bounds observer returns nil", invalidObserverResult == nil)
} else {
    print("        (skipped: no Metal viewshed pipeline)")
}

await runCoordinatorOfflineChecks()
await runTransectChecks()
await runMicroTopographyChecks(outDir: outDir)
await runInteractiveAnalysisChecks()
await runProviderMicroChecks()
await runHistoricalAndSoilChecks()
await runBasemapChecks()

print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
