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
    // A flick still coasting when the 3D view opens: the full-screen view takes the map out of the window, and the
    // coast it cuts short may never report its end.
    model.isCameraGestureActive = true
    await model.openTerrain3D()
    let prepared = model.terrain3DScene
    check("opening the 3D view ends a camera move the map had under way, so the chrome is not left yielded",
          prepared != nil && !model.isCameraGestureActive)
    model.isCameraGestureActive = true
    model.terrain3DScene = nil
    check("closing the 3D view ends one too", !model.isCameraGestureActive)
    model.terrain3DScene = prepared
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
    // That view is 0.002 degrees square, about 3.7 tiles north to south over the 3 loaded, so 81% of it has elevation and
    // its scene says so; the centre tile alone lies wholly on loaded ground.
    let centreTile = scene.region()
    let covered = TerrainViewerModel(terrainProvider: scene.provider)
    covered.visibleRegion = MKCoordinateRegion(
        center: centreTile.center,
        span: MKCoordinateSpan(latitudeDelta: centreTile.latitudeSpan, longitudeDelta: centreTile.longitudeSpan))
    await covered.openTerrain3D()
    check("a view the elevation covers says nothing about coverage; one it covers 81% of says so",
          covered.terrain3DScene != nil && covered.terrain3DScene?.coverageNotice == nil
            && (76...86).contains(percent(in: prepared?.coverageNotice) ?? -1),
          "\(String(describing: covered.terrain3DScene?.coverageNotice)), \(String(describing: prepared?.coverageNotice))")

    // Overzoomed: a view a third of the centre tile across is about 20 of the mesh grid's 1 m cells, fewer than the 64
    // points a side its share is read at. Counted only inside the grid's region, which runs through its outermost samples
    // half a cell in from the ground they stand for, the rim of points read as empty and the whole view said "Only 93%".
    let close = TerrainViewerModel(terrainProvider: scene.provider)
    close.visibleRegion = MKCoordinateRegion(
        center: centreTile.center,
        span: MKCoordinateSpan(latitudeDelta: centreTile.latitudeSpan / 3, longitudeDelta: centreTile.longitudeSpan / 3))
    await close.openTerrain3D()
    check("an overzoomed view the elevation covers, a few dozen of its grid's cells across, says nothing about coverage",
          close.terrain3DScene != nil && close.terrain3DScene?.coverageNotice == nil && close.inspectorMessage == nil,
          "\(String(describing: close.terrain3DScene?.coverageNotice)), \(String(describing: close.inspectorMessage))")

    let bare = TerrainViewerModel(terrainProvider: TerrainTileProvider(elevation: RecordingElevationStub(answers: false), gridCache: TileDiskCache(directory: makeCacheDir())))
    await bare.openTerrain3D()
    check("with no terrain drawn there is no scene, and the model says why",
          bare.terrain3DScene == nil && bare.inspectorMessage?.contains("terrain") == true && !bare.isPreparingTerrain3D,
          "\(String(describing: bare.inspectorMessage))")

    // Loaded but void (open water, a lidar void): the tiles have drawn, and waiting or panning will not change them.
    let voidScene = await makeVoidScene()
    defer { try? FileManager.default.removeItem(at: voidScene.directory) }
    let overVoid = TerrainViewerModel(terrainProvider: voidScene.provider)
    overVoid.visibleRegion = MKCoordinateRegion(
        center: centreTile.center,
        span: MKCoordinateSpan(latitudeDelta: centreTile.latitudeSpan, longitudeDelta: centreTile.longitudeSpan))
    await overVoid.openTerrain3D()
    check("a view whose loaded tiles are all void has no scene and says it has no valid elevation, not that no terrain has drawn",
          overVoid.terrain3DScene == nil && overVoid.inspectorMessage?.contains("no valid elevation") == true
            && overVoid.inspectorMessage?.contains("No terrain has drawn") == false,
          "\(String(describing: overVoid.inspectorMessage))")

    // Wholly past the ground that has elevation (offline beyond the downloaded area): nothing usable, refused as before
    // the pass, without advice to wait for ground that will never come.
    let beyond = TerrainViewerModel(terrainProvider: scene.provider)
    let pastTheEdge = scene.region(dx: 4)
    beyond.liveVisibleRegion = {
        MKCoordinateRegion(center: pastTheEdge.center,
                           span: MKCoordinateSpan(latitudeDelta: pastTheEdge.latitudeSpan, longitudeDelta: pastTheEdge.longitudeSpan))
    }
    await beyond.openTerrain3D()
    check("a view wholly past the ground with elevation has no scene and says no terrain has drawn, not to wait",
          beyond.terrain3DScene == nil && beyond.inspectorMessage?.contains("No terrain has drawn") == true
            && beyond.inspectorMessage?.localizedCaseInsensitiveContains("wait") == false,
          "\(String(describing: beyond.inspectorMessage))")

    // View in 3D tapped while the map still coasts: the model's region is where the map was before the move (here a
    // degree north, where no terrain has drawn), the map view's live region is the ground on screen.
    let onScreen = MKCoordinateRegion(
        center: scene.region().center, span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002))
    let coasting = TerrainViewerModel(terrainProvider: scene.provider)
    coasting.visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: onScreen.center.latitude + 1, longitude: onScreen.center.longitude),
        span: onScreen.span)
    coasting.isCameraGestureActive = true
    coasting.liveVisibleRegion = { onScreen }
    await coasting.openTerrain3D()
    check("View in 3D tapped mid-coast meshes the region on screen, not the one the map had before the move",
          coasting.terrain3DScene != nil && coasting.inspectorMessage == nil
            && coasting.visibleRegion.center.latitude == onScreen.center.latitude,
          "\(String(describing: coasting.inspectorMessage)), model region \(coasting.visibleRegion.center.latitude)")

    // Tapped as a flick brings fresh ground on screen: two thirds of the live region lie east of the tiles with elevation.
    // Meshed with nothing said, it was a strip of terrain along one edge of a black canvas; refused, as 1e86161 did, it
    // told a user offline past the downloaded area to wait for ground that would never come. It is meshed, and says so.
    let fresh = TerrainViewerModel(terrainProvider: scene.provider)
    fresh.isCameraGestureActive = true
    fresh.liveVisibleRegion = { mostlyUndrawnRegion(scene) }
    await fresh.openTerrain3D()
    let freshNotice = fresh.terrain3DScene?.coverageNotice
    let freshPercent = percent(in: freshNotice)
    check("View in 3D over a view two thirds without elevation meshes the third that has it, and says the 3D view shows only about a third of the view, not to wait",
          fresh.terrain3DScene != nil && fresh.inspectorMessage == nil && !fresh.isPreparingTerrain3D
            && freshNotice?.contains("3D view") == true && (28...38).contains(freshPercent ?? -1)
            && freshNotice?.localizedCaseInsensitiveContains("wait") == false,
          "\(String(describing: freshNotice)), \(String(describing: fresh.inspectorMessage))")

    // The share with elevation, read on the grid a mesh or a file is made from at a grid of points across the view: a
    // node-registered grid over lat 10-11, lon 20-22, its samples every 1/64 degree of longitude.
    let view = GeoRegion(minLatitude: 10, maxLatitude: 11, minLongitude: 20, maxLongitude: 22)
    func grid(_ region: GeoRegion = view, valid: (Int) -> Bool) -> ElevationGrid {
        ElevationGrid(width: 129, height: 65, samples: (0..<(129 * 65)).map { valid($0 % 129) ? 100 : .nan }, region: region)
    }
    let westHalf = grid { $0 < 64 }, whole = grid { _ in true }, void = grid { _ in false }
    let shares = [
        TerrainTileProvider.elevationShare(of: view, in: westHalf),
        TerrainTileProvider.elevationShare(of: view, in: whole),
        TerrainTileProvider.elevationShare(of: view, in: void),
        TerrainTileProvider.elevationShare(of: GeoRegion(minLatitude: 40, maxLatitude: 41, minLongitude: 20, maxLongitude: 22), in: whole),
        TerrainTileProvider.elevationShare(of: GeoRegion(minLatitude: 10, maxLatitude: 11, minLongitude: 21, maxLongitude: 23), in: whole),
        TerrainTileProvider.elevationShare(of: GeoRegion(minLatitude: .nan, maxLatitude: 1, minLongitude: 0, maxLongitude: 1), in: whole),
    ]
    check("the share with elevation, on the grid: half for a grid void over its east half, all, nothing for a grid of voids, nothing for a view off the grid, half for a view half off it, nothing for a region that is not a number",
          shares == [0.5, 1, 0, 0, 0.5, 0], "\(shares)")

    // A grid coarser than the points, as an overzoomed view has (Terrarium past z15, 1 m lidar on a view under 64 m): 10 x 5
    // cells whose outer edges are the view's, so its region, through the cells' centres, lies half a cell inside the view.
    // Each sample stands for its cell, so the grid covers the view; counted only inside its region, a complete view read
    // 74%. Real gaps still count: a void column, and ground past the cells' outer edge.
    let cellCentres = GeoRegion(minLatitude: 10.1, maxLatitude: 10.9, minLongitude: 20.1, maxLongitude: 21.9)
    func coarse(valid: (Int) -> Bool) -> ElevationGrid {
        ElevationGrid(width: 10, height: 5, samples: (0..<50).map { valid($0 % 10) ? 100 : .nan }, region: cellCentres)
    }
    let overzoomed = [
        TerrainTileProvider.elevationShare(of: view, in: coarse { _ in true }),
        TerrainTileProvider.elevationShare(of: view, in: coarse { $0 < 9 }),
        TerrainTileProvider.elevationShare(
            of: GeoRegion(minLatitude: 10, maxLatitude: 11, minLongitude: 20, maxLongitude: 22.4), in: coarse { _ in true }),
    ]
    check("an overzoomed grid, its cells' outer edges on the view's, covers all of it; void in its east column it covers 58 of 64 points across, and a view a sixth of which lies past its cells 53 of 64",
          overzoomed == [1, 58.0 / 64, 53.0 / 64], "\(overzoomed)")

    // What the 3D view and a file say: nothing when the elevation covers the view, the share otherwise (never 0%), and
    // never to wait.
    let notices = [1, 0.995, 0.62, 0.004].map { TerrainViewerModel.coverageNotice(share: $0, inFile: false) }
    let fileNotice = TerrainViewerModel.coverageNotice(share: 0.62, inFile: true)
    check("the coverage notice: none at or above 99%, then the share it covers, 1% at least, the 3D view's and the file's own words, never to wait",
          notices[0] == nil && notices[1] == nil && percent(in: notices[2]) == 62 && notices[2]?.contains("3D view") == true
            && percent(in: notices[3]) == 1 && percent(in: fileNotice) == 62 && fileNotice?.contains("file") == true
            && (notices + [fileNotice]).allSatisfy { $0?.localizedCaseInsensitiveContains("wait") != true },
          "\(notices), \(String(describing: fileNotice))")
}

/// The whole number before the first "%" in `text`: the share a coverage notice reports.
func percent(in text: String?) -> Int? {
    guard let text, let sign = text.firstIndex(of: "%") else { return nil }
    let digits = text[..<sign].reversed().prefix { $0.isNumber }
    return Int(String(digits.reversed()))
}

/// Elevation that loads but holds none, as open water or a lidar void comes back: every sample a void.
nonisolated struct VoidTerrainStub: ElevationProviding {
    func elevation(for region: GeoRegion, targetSamples count: Int) async -> Evidence<ElevationGrid> {
        .observed(ElevationGrid(width: count, height: count, samples: [Float](repeating: .nan, count: count * count), region: region),
                  Provenance(source: .usgs3DEP))
    }
}

/// The synthetic scene's tiles, the centre one and its eight neighbours, loaded from ``VoidTerrainStub``.
@MainActor
func makeVoidScene() async -> SyntheticTileScene {
    let layout = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    let provider = TerrainTileProvider(elevation: VoidTerrainStub(), gridCache: TileDiskCache(directory: layout.directory))
    let scene = SyntheticTileScene(provider: provider, x: layout.x, y: layout.y, z: layout.z, directory: layout.directory)
    await scene.loadNeighbourhood()
    return scene
}

/// A view as wide as three of the scene's tiles and one tall, centred one tile east of its drawn 3x3 neighbourhood: its
/// west third lies on drawn tiles, the rest on ground nothing has drawn.
@MainActor
func mostlyUndrawnRegion(_ scene: SyntheticTileScene) -> MKCoordinateRegion {
    let tile = scene.region(dx: 2)
    return MKCoordinateRegion(center: tile.center,
                              span: MKCoordinateSpan(latitudeDelta: tile.latitudeSpan, longitudeDelta: tile.longitudeSpan * 3))
}
