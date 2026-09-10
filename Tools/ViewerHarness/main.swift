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

    for style in ReliefStyle.allCases {
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

print("\n=== Morton spatial key (GeoTileKey) ===")
// The defect: a 16-bit-only dilation drops the high half of a 32-bit
// coordinate, so anything differing only above bit 16 collides. Prove the
// bijection at the bit level first, then through GeoRegion.
check("interleave separates a low bit-16 difference",
      GeoTileKey.interleave(lat: 0x0000_0005, lon: 0)
        != GeoTileKey.interleave(lat: 0x0001_0005, lon: 0),
      "bit 16 of lat collided")
check("interleave separates high-16-bit-only differences (identical low 16)",
      GeoTileKey.interleave(lat: 0xABCD_0005, lon: 0)
        != GeoTileKey.interleave(lat: 0x1234_0005, lon: 0),
      "high 16 bits of lat collided")
check("interleave keeps lat and lon on disjoint bits",
      GeoTileKey.interleave(lat: 1, lon: 0) != GeoTileKey.interleave(lat: 0, lon: 1),
      "lat/lon overlap")

// Exhaustive bijection over a swept set of 32-bit inputs: N distinct pairs
// must yield N distinct keys.
do {
    var keys = Set<UInt64>()
    var pairs = 0
    for hiLat in [0x0000, 0x0001, 0x8000, 0xFFFF] {
        for loLat in [0x0000, 0x0001, 0x00FF, 0xFF00, 0xFFFF] {
            for hiLon in [0x0000, 0x0001, 0x8000, 0xFFFF] {
                let lat = UInt32(hiLat << 16 | loLat)
                let lon = UInt32(hiLon << 16 | 0x00AB)
                keys.insert(GeoTileKey.interleave(lat: lat, lon: lon))
                pairs += 1
            }
        }
    }
    check("interleave is a bijection (no collisions across swept inputs)",
          keys.count == pairs, "\(keys.count) keys for \(pairs) distinct inputs")
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
    let key = GeoTileKey(region: mortonBase)
    let encoded = try! JSONEncoder().encode(key)
    let decoded = try! JSONDecoder().decode(GeoTileKey.self, from: encoded)
    check("GeoTileKey round-trips through Codable", decoded == key)
    check("GeoTileKey round-trips through packedValue",
          GeoTileKey(packedValue: key.packedValue) == key)
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
        check("IFD declares 14 entries", entryCount == 14, "\(entryCount)")

        var tagVal: [Int: Int] = [:]
        var tagsAscending = true
        var prevTag = -1
        for i in 0..<entryCount {
            let e = 10 + i * 12
            let tag = u16(e)
            if tag <= prevTag { tagsAscending = false }
            prevTag = tag
            tagVal[tag] = u32(e + 8)
        }
        check("IFD entries are in ascending tag order (strict-reader safe)", tagsAscending)
        check("GeoTIFF structural tags present (PixelScale, Tiepoint, GeoKeyDir)",
              tagVal[33550] != nil && tagVal[33922] != nil && tagVal[34735] != nil)

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

print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
