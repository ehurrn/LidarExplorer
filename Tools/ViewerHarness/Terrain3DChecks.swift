//
//  Terrain3DChecks.swift
//  ViewerHarness
//
//  The 3D view's data path: stitching shaded tiles into a texture, and the viewer model preparing a scene.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit

@MainActor
func runTerrain3DChecks() async {
    print("\n=== 3D view data ===")
    checkTileComposite()
    await checkTerrain3DScene()
}

/// A solid 8 x 8 image, premultiplied as the map's tile bitmaps are.
private func solidImage(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    func premultiplied(_ v: UInt8) -> UInt8 { UInt8((Int(v) * Int(alpha) + 127) / 255) }
    for i in 0..<64 {
        pixels[i * 4] = premultiplied(r); pixels[i * 4 + 1] = premultiplied(g); pixels[i * 4 + 2] = premultiplied(b)
        pixels[i * 4 + 3] = alpha
    }
    return CGImage(
        width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// The RGBA at pixel (x, y) counted from the top left.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drawn, x >= 0, x < image.width, y >= 0, y < image.height else { return nil }
    let o = (y * image.width + x) * 4
    return [Int(data[o]), Int(data[o + 1]), Int(data[o + 2]), Int(data[o + 3])]
}

private func mercator(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GeoRegion {
    let sw = GeoRegion.fromMercatorMeters(x: x0, y: y0), ne = GeoRegion.fromMercatorMeters(x: x1, y: y1)
    return GeoRegion(minLatitude: sw.latitude, maxLatitude: ne.latitude, minLongitude: sw.longitude, maxLongitude: ne.longitude)
}

@MainActor
private func checkTileComposite() {
    print("\n--- U1. stitching tiles ---")
    let x0 = -10_000_000.0, y0 = 4_700_000.0, side = 1_000.0
    let region = mercator(x0, y0, x0 + 2 * side, y0 + side)
    let west = TileComposite.Tile(image: solidImage(255, 0, 0), region: mercator(x0, y0, x0 + side, y0 + side), zoom: 15)
    let east = TileComposite.Tile(image: solidImage(0, 0, 255), region: mercator(x0 + side, y0, x0 + 2 * side, y0 + side), zoom: 15)
    guard let image = TileComposite.render(tiles: [west, east], region: region, maxPixels: 200) else {
        check("two tiles stitch into an image", false, "nil")
        return
    }
    check("a region twice as wide as tall is 200 x 100, the longer side at the cap",
          image.width == 200 && image.height == 100, "\(image.width) x \(image.height)")
    let left = pixel(image, 50, 50), right = pixel(image, 150, 50)
    check("each tile lands on its own ground: the west tile on the left, the east tile on the right",
          left.map { $0[0] > 250 && $0[2] < 5 } == true && right.map { $0[2] > 250 && $0[0] < 5 } == true,
          "\(String(describing: left)) \(String(describing: right))")

    // North is up: a tile over the northern half of the region must be at the top.
    let tall = mercator(x0, y0, x0 + side, y0 + 2 * side)
    let south = TileComposite.Tile(image: solidImage(0, 255, 0), region: mercator(x0, y0, x0 + side, y0 + side), zoom: 15)
    let north = TileComposite.Tile(image: solidImage(255, 255, 0), region: mercator(x0, y0 + side, x0 + side, y0 + 2 * side), zoom: 15)
    let stacked = TileComposite.render(tiles: [south, north], region: tall, maxPixels: 100)
    check("north is at the top of the image",
          stacked.flatMap { pixel($0, 25, 25) }.map { $0[0] > 250 && $0[1] > 250 && $0[2] < 5 } == true
          && stacked.flatMap { pixel($0, 25, 75) }.map { $0[0] < 5 && $0[1] > 250 } == true && stacked?.height == 100)

    // A finer tile over the same ground wins whatever the order they arrive in.
    let coarse = TileComposite.Tile(image: solidImage(255, 0, 0), region: region, zoom: 14)
    let fine = TileComposite.Tile(image: solidImage(0, 255, 0), region: mercator(x0, y0, x0 + side, y0 + side), zoom: 16)
    let layered = TileComposite.render(tiles: [fine, coarse], region: region, maxPixels: 200)
    check("a finer tile is drawn over a coarser one, wherever they arrive in the list, and the coarser shows beyond it",
          layered.flatMap { pixel($0, 50, 50) }.map { $0[1] > 250 && $0[0] < 5 } == true
          && layered.flatMap { pixel($0, 150, 50) }.map { $0[0] > 250 && $0[1] < 5 } == true)

    // Where nothing has drawn it is transparent, and tiles off the region are ignored.
    let partial = TileComposite.render(tiles: [west], region: region, maxPixels: 200)
    let elsewhere = TileComposite.Tile(image: solidImage(9, 9, 9), region: mercator(x0 + 5 * side, y0, x0 + 6 * side, y0 + side), zoom: 15)
    check("ground no tile covers is transparent",
          partial.flatMap { pixel($0, 150, 50) }.map { $0[3] == 0 } == true && partial.flatMap { pixel($0, 50, 50) }.map { $0[3] == 255 } == true)
    // The map's shading tiles are translucent overlays meant to sit over a basemap. Left transparent they light as
    // near-black on an opaque 3D surface, so a background goes down first.
    let veil = TileComposite.Tile(image: solidImage(255, 0, 0, alpha: 128), region: mercator(x0, y0, x0 + side, y0 + side), zoom: 15)
    let backed = TileComposite.render(tiles: [veil], region: region, maxPixels: 200,
                                      background: CGColor(gray: 1, alpha: 1))
    let over = backed.flatMap { pixel($0, 50, 50) }, beside = backed.flatMap { pixel($0, 150, 50) }
    check("over a background, a translucent tile lands on it and ground no tile covers is the background, opaque",
          over.map { $0[3] == 255 && $0[0] > 250 && abs($0[1] - 127) <= 3 && abs($0[2] - 127) <= 3 } == true
          && beside.map { $0 == [255, 255, 255, 255] } == true
          && partial.flatMap({ pixel($0, 150, 50) })?[3] == 0,
          "\(String(describing: over)) \(String(describing: beside))")
    check("no tiles, tiles off the region, and a region with no extent give nothing",
          TileComposite.render(tiles: [], region: region, maxPixels: 200) == nil
          && TileComposite.render(tiles: [elsewhere], region: region, maxPixels: 200) == nil
          && TileComposite.render(tiles: [west], region: GeoRegion(minLatitude: 1, maxLatitude: 1, minLongitude: 1, maxLongitude: 1), maxPixels: 200) == nil
          && TileComposite.render(tiles: [west], region: region, maxPixels: 1) == nil)
}

@MainActor
private func checkTerrain3DScene() async {
    print("\n--- U2. preparing a scene ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    await scene.loadNeighbourhood()
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.visibleRegion = MKCoordinateRegion(
        center: scene.region().center, span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002))
    await model.openTerrain3D()
    let prepared = model.terrain3DScene
    check("the viewport's terrain becomes a scene: a mesh within the cap, draped with the shaded tiles",
          prepared != nil && (prepared?.mesh.positions.count ?? 0) > 400 && (prepared?.mesh.columns ?? 999) <= 192
          && prepared?.texture != nil && model.inspectorMessage == nil && !model.isPreparingTerrain3D,
          "\(String(describing: prepared?.mesh.columns)) x \(String(describing: prepared?.mesh.rows)), texture \(prepared?.texture != nil), \(String(describing: model.inspectorMessage))")
    // The texture the 3D view lights must be opaque everywhere: tile shading is translucent, and the tiles that have
    // drawn cover only part of the ground the mesh spans.
    var alphas: [Int] = []
    if let texture = prepared?.texture {
        for (fx, fy) in [(0.02, 0.02), (0.98, 0.02), (0.5, 0.5), (0.02, 0.98), (0.98, 0.98), (0.25, 0.75)] {
            if let p = pixel(texture, Int(fx * Double(texture.width)), Int(fy * Double(texture.height))) { alphas.append(p[3]) }
        }
    }
    check("the texture the 3D view lights is opaque at every point sampled, corners included",
          alphas.count == 6 && alphas.allSatisfy { $0 == 255 }, "alpha \(alphas)")
    check("the mesh stands on the real relief: the synthetic mound rises above its plain",
          (prepared?.mesh.bounds.maximum.y ?? 0) > 1.5 && (prepared?.mesh.bounds.maximum.y ?? 99) < 6,
          "\(String(describing: prepared?.mesh.bounds))")

    let bare = TerrainViewerModel(terrainProvider: TerrainTileProvider(elevation: RecordingElevationStub(answers: false), gridCache: TileDiskCache(directory: makeCacheDir())))
    await bare.openTerrain3D()
    check("with no terrain drawn there is no scene, and the model says why",
          bare.terrain3DScene == nil && bare.inspectorMessage?.contains("terrain") == true && !bare.isPreparingTerrain3D,
          "\(String(describing: bare.inspectorMessage))")
}
