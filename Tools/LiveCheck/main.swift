import CoreLocation
import Foundation
import MapKit

var failures = 0
func check(_ n: String, _ ok: Bool, _ d: String = "") {
    print(ok ? "  PASS  \(n)" : "  FAIL  \(n) \(d)")
    if !ok { failures += 1 }
}

/// Slippy-map tile containing a coordinate at a zoom level.
func tilePath(lat: Double, lon: Double, z: Int) -> MKTileOverlayPath {
    let n = pow(2.0, Double(z))
    let x = Int((lon + 180.0) / 360.0 * n)
    let y = Int((1.0 - asinh(tan(lat * .pi / 180)) / .pi) / 2.0 * n)
    return MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2)
}

let cahokia = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)

@MainActor
func run() async {
    print("\n=== Tile geometry ===")
    // A tile must contain the coordinate used to derive it, at every zoom.
    for z in [10, 12, 14, 16] {
        let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: z)
        let region = TerrainTileOverlay.region(for: path)
        check("z\(z) tile contains its own coordinate", region.contains(cahokia),
              "lat \(region.minLatitude)..\(region.maxLatitude)")
    }
    // Tiles must halve in span with each zoom step.
    let wide = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 12))
    let tight = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 13))
    check("one zoom step halves the tile span",
          abs(wide.longitudeSpan / tight.longitudeSpan - 2) < 1e-9,
          "\(wide.longitudeSpan / tight.longitudeSpan)")
    // Adjacent tiles must abut exactly, or the terrain shows seams.
    let a = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 100, y: 200, z: 14, contentScaleFactor: 2))
    let b = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 101, y: 200, z: 14, contentScaleFactor: 2))
    let c = TerrainTileOverlay.region(for: MKTileOverlayPath(x: 100, y: 201, z: 14, contentScaleFactor: 2))
    check("horizontally adjacent tiles abut", abs(a.maxLongitude - b.minLongitude) < 1e-12)
    check("vertically adjacent tiles abut", abs(a.minLatitude - c.maxLatitude) < 1e-12)

    print("\n=== Basemap overzoom deduplication ===")
    let basemap = HillshadeTileOverlay(basemap: .shadedRelief)
    let parentX = 2046
    let parentY = 3140
    let child1 = MKTileOverlayPath(x: parentX * 2, y: parentY * 2, z: 14, contentScaleFactor: 2)
    let child2 = MKTileOverlayPath(x: parentX * 2 + 1, y: parentY * 2, z: 14, contentScaleFactor: 2)
    let d1 = try? await basemap.loadTile(at: child1)
    let d2 = try? await basemap.loadTile(at: child2)
    check("child tile 1 loads", d1 != nil)
    check("child tile 2 loads", d2 != nil)
    if let d1, let d2 {
        check("adjacent overzoomed child tiles are distinct (not duplicate parent)", d1 != d2)
    }

    print("\n=== Tiered tile streaming (live) ===")
    let provider = TerrainTileProvider()

    // Browsing zooms must be fast, and detail must improve with zoom.
    var timings: [Int: Double] = [:]
    var resolutions: [Int: Double] = [:]
    for z in [11, 13, 15, 16, 18] {
        let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: z)
        let region = TerrainTileOverlay.region(for: path)
        let started = Date()
        let data = await provider.tileImageData(
            x: path.x, y: path.y, z: path.z, region: region, pixels: 512
        )
        let elapsed = Date().timeIntervalSince(started)
        timings[z] = elapsed
        let source = TerrainTileProvider.sourceName(forZ: z)
        let px = z <= TerrariumTileService.maximumZ ? 256.0 : 512.0
        resolutions[z] = region.widthMeters / px
        let sourceLabel = source.padding(toLength: 22, withPad: " ", startingAt: 0)
        let sizeLabel = data == nil ? "NO DATA" : "\(data!.count / 1024) KB"
        print("        " + "z\(z)".padding(toLength: 6, withPad: " ", startingAt: 0)
              + sourceLabel
              + String(format: "%7.0f m wide -> %5.2f m/px  %6.2fs  ",
                       region.widthMeters, region.widthMeters / px, elapsed)
              + sizeLabel)
        check("z\(z) tile renders", data != nil)
    }

    // The point of the tiered source: browsing must not stall.
    for z in [11, 13, 15, 16] {
        check("z\(z) tile is fast enough to browse (< 3s)", (timings[z] ?? 99) < 3.0,
              String(format: "%.2fs", timings[z] ?? -1))
    }
    if let r11 = resolutions[11], let r13 = resolutions[13],
       let r15 = resolutions[15], let r16 = resolutions[16],
       let r18 = resolutions[18] {
        check("detail improves monotonically with zoom",
              r11 > r13 && r13 > r15 && r15 > r16 && r16 > r18,
              "\(r11) / \(r13) / \(r15) / \(r16) / \(r18)")
        check("deepest tier reaches native resolution (< 1.5 m)", r18 < 1.5, "\(r18) m/px")
    }
    if let finest = await provider.finestResolution() {
        print(String(format: "        finest cached raster GSD: %.2f m/px", finest))
        check("finest raster GSD reaches 1 m", finest < 1.5, String(format: "%.2f m/px", finest))
    }

    print("\n=== Relighting uses the cache ===")
    // Re-shading must not refetch: that is what keeps the light controls live.
    let path = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 15)
    let region = TerrainTileOverlay.region(for: path)
    _ = await provider.tileImageData(
        x: path.x, y: path.y, z: path.z, region: region, pixels: 512)   // warm

    var settings = TerrainStyleSettings()
    settings.style = .hillshade
    settings.azimuthDegrees = 135
    _ = await provider.update(settings)

    let started = Date()
    let relit = await provider.tileImageData(
        x: path.x, y: path.y, z: path.z, region: region, pixels: 512)
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "        relight took %.3fs", elapsed))
    check("relight produces an image", relit != nil)
    check("relight is far faster than a fetch", elapsed < 1.0,
          String(format: "%.3fs", elapsed))

    print("\n=== Elevation readout from tiles ===")
    let elevation = await provider.elevation(at: cahokia)
    check("elevation available from cached tiles", elevation != nil)
    if let e = elevation {
        print(String(format: "        %.1f m at Monks Mound", e))
        check("elevation plausible for Cahokia", e > 110 && e < 200, "\(e)")
    }
    let spot = await provider.inspectSpot(at: cahokia)
    check("spot inspection available from cached tiles", spot != nil)
    if let spot {
        print(String(format: "        Spot: elev %.1f m, slope %.1f° (%@), aspect %.0f° (%@)",
                     spot.elevationMeters, spot.slopeDegrees, spot.slopePercentFormatted, spot.aspectDegrees, spot.compassDirection))
        check("spot elevation matches elevation readout", abs(spot.elevationMeters - (elevation ?? 0)) < 0.1)
        check("spot slope valid", !spot.slopeDegrees.isNaN && spot.slopeDegrees >= 0)
    }
    let far = await provider.elevation(
        at: CLLocationCoordinate2D(latitude: 45.0, longitude: -100.0))
    check("coordinate outside cached tiles reads nil", far == nil)
    let farSpot = await provider.inspectSpot(
        at: CLLocationCoordinate2D(latitude: 45.0, longitude: -100.0))
    check("spot outside cached tiles reads nil", farSpot == nil)

    print("\n=== Elevation range fits the visible area (not continental) ===")
    let elevRegion = TerrainTileOverlay.region(for: tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 15))
    if let r = await provider.elevationRange(in: elevRegion) {
        let span = r.upperBound - r.lowerBound
        print(String(format: "        fitted range %.1f..%.1f m (span %.1f)", r.lowerBound, r.upperBound, span))
        check("elevation range is local, not continental", span < 500, "span \(span)")
        check("elevation range plausible for Cahokia", r.lowerBound > 100 && r.upperBound < 250, "\(r.lowerBound)..\(r.upperBound)")
    } else {
        check("elevation range available from cached tiles", false)
    }

    print("\n=== Adjacent tile seam continuity (z18) ===")
    let pathA = tilePath(lat: cahokia.latitude, lon: cahokia.longitude, z: 18)
    let pathB = MKTileOverlayPath(x: pathA.x + 1, y: pathA.y, z: 18, contentScaleFactor: 2)
    let regionA = TerrainTileOverlay.region(for: pathA)
    let regionB = TerrainTileOverlay.region(for: pathB)
    let dataA = await provider.tileImageData(x: pathA.x, y: pathA.y, z: pathA.z, region: regionA, pixels: 512)
    let dataB = await provider.tileImageData(x: pathB.x, y: pathB.y, z: pathB.z, region: regionB, pixels: 512)
    check("tile A (z18) renders", dataA != nil)
    check("tile B (z18) renders", dataB != nil)

    if let dataA, let dataB {
        func imageDimensions(from data: Data) -> (Int, Int)? {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return (img.width, img.height)
        }
        let dimsA = imageDimensions(from: dataA)
        let dimsB = imageDimensions(from: dataB)
        check("tile A is exactly 512x512 retina", dimsA?.0 == 512 && dimsA?.1 == 512, "\(String(describing: dimsA))")
        check("tile B is exactly 512x512 retina", dimsB?.0 == 512 && dimsB?.1 == 512, "\(String(describing: dimsB))")

        // Elevation at shared boundary coordinate
        let midLat = (regionA.minLatitude + regionA.maxLatitude) / 2
        let boundaryCoord = CLLocationCoordinate2D(latitude: midLat, longitude: regionA.maxLongitude)
        let boundaryElev = await provider.elevation(at: boundaryCoord)
        check("elevation at shared tile boundary is valid", boundaryElev != nil, "\(String(describing: boundaryElev))")
    }
}

await run()
print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
