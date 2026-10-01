//
//  Terrain3DChecks.swift
//  ViewerHarness
//
//  The 3D view's data path: stitching shaded tiles into a texture, the viewer model preparing a scene, a view the map
//  still draws after the provider's cache has let its tiles go (U3), and the grid reaching a tall view's edges (U4).
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import os

@MainActor
func runTerrain3DChecks() async {
    print("\n=== 3D view data ===")
    checkTileComposite()
    await checkTerrain3DScene()
    await checkDrawnViewOutlivesTheBudget()
    await checkGridReachesTheViewEdges()
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

    // On a rotated map the model is given the map's corners with its region, which is the north-up box around them. Five
    // tiles have drawn in a plus, the centre one and its four side neighbours, and the screen is a square turned 45 degrees
    // that reaches the centres of the four: every point of it has elevation, while the box reaches into the four corner
    // tiles, which never load, and a fully drawn rotated view said "Only 75%". With the east tile missing, the gap is real.
    let plus = await makePartialScene([(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)])
    let plusLessEast = await makePartialScene([(0, 0), (-1, 0), (0, -1), (0, 1)])
    defer { for partial in [plus, plusLessEast] { try? FileManager.default.removeItem(at: partial.directory) } }
    let turned = turnedView(plus)
    let turnedDrawn = TerrainViewerModel(terrainProvider: plus.provider)
    let turnedGap = TerrainViewerModel(terrainProvider: plusLessEast.provider)
    for turnedModel in [turnedDrawn, turnedGap] {
        turnedModel.liveVisibleRegion = { turned.region }
        turnedModel.liveVisibleCorners = { turned.corners }
        await turnedModel.openTerrain3D()
    }
    check("on a rotated map, a view drawn wherever the screen reaches says nothing about coverage, though the box around it reaches ground that never loads; one tile the screen reaches missing, it says about 87%, not the box's 62%",
          turnedDrawn.terrain3DScene != nil && turnedDrawn.terrain3DScene?.coverageNotice == nil
            && (84...90).contains(percent(in: turnedGap.terrain3DScene?.coverageNotice) ?? -1),
          "\(String(describing: turnedDrawn.terrain3DScene?.coverageNotice)), \(String(describing: turnedGap.terrain3DScene?.coverageNotice)), \(String(describing: turnedDrawn.inspectorMessage))")

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

    // A rotated view, measured over the map's own corners. The screen is the diamond through the midpoints of the box's
    // edges (a square turned 45 degrees), and the grid over the box has elevation over the diamond and a little past it,
    // none in the box's corners, which were never on screen: read over the box, as the region is, it said 60%. A void
    // strip down the middle of the screen still counts, and corners that are not four places give nothing.
    let box = GeoRegion(minLatitude: 10, maxLatitude: 11, minLongitude: 20, maxLongitude: 21)
    func overBox(valid: (_ x: Double, _ y: Double) -> Bool) -> ElevationGrid {
        ElevationGrid(width: 65, height: 65, samples: (0..<(65 * 65)).map { i in
            valid(Double(i % 65) / 32 - 1, Double(i / 65) / 32 - 1) ? 100 : .nan
        }, region: box)
    }
    let diamond = [
        CLLocationCoordinate2D(latitude: 10.5, longitude: 20), CLLocationCoordinate2D(latitude: 11, longitude: 20.5),
        CLLocationCoordinate2D(latitude: 10, longitude: 20.5), CLLocationCoordinate2D(latitude: 10.5, longitude: 21),
    ]
    let drawnDiamond = overBox { abs($0) + abs($1) <= 1.1 }
    let rotatedShares = [
        TerrainTileProvider.elevationShare(ofScreenCorners: diamond, within: box, in: drawnDiamond),
        TerrainTileProvider.elevationShare(of: box, in: drawnDiamond),
        TerrainTileProvider.elevationShare(
            ofScreenCorners: diamond, within: box, in: overBox { abs($0) + abs($1) <= 1.1 && abs($0) > 0.1 }),
        TerrainTileProvider.elevationShare(ofScreenCorners: Array(diamond.prefix(3)), within: box, in: drawnDiamond),
        TerrainTileProvider.elevationShare(
            ofScreenCorners: [CLLocationCoordinate2D(latitude: .nan, longitude: 20)] + diamond.dropFirst(), within: box,
            in: drawnDiamond),
    ]
    check("a rotated view over its own corners: all of a screen drawn where it reaches, not the 60% of the box around it; a void strip down its middle, a fifth of it, still counts; nothing for three corners or one that is not a number",
          rotatedShares[0] == 1 && rotatedShares[1] < 0.7 && (0.76...0.86).contains(rotatedShares[2])
            && rotatedShares[3] == 0 && rotatedShares[4] == 0, "\(rotatedShares)")

    // MapKit's region leaves out the safe area's strips at the top and bottom of the screen (on the 13-inch in portrait,
    // 32 and 20 pt of the 1376: the screen's corners lay 4% of its height past the region), and no grid, file or mesh holds
    // them. Counted as gaps, every fully drawn north-up view read about 96%; only the points in the region count. A gap
    // inside the region still does.
    let tallScreen = [
        CLLocationCoordinate2D(latitude: 11.03, longitude: 20), CLLocationCoordinate2D(latitude: 11.03, longitude: 21),
        CLLocationCoordinate2D(latitude: 9.98, longitude: 20), CLLocationCoordinate2D(latitude: 9.98, longitude: 21),
    ]
    let pastTheRegion = [
        TerrainTileProvider.elevationShare(ofScreenCorners: tallScreen, within: box, in: overBox { _, _ in true }),
        TerrainTileProvider.elevationShare(ofScreenCorners: tallScreen, within: box, in: overBox { x, _ in x < 0 }),
    ]
    check("the screen's strips past the region, under the status bar and the home indicator, are not gaps: a drawn view reads all of it, and one void over its east half about half",
          pastTheRegion[0] == 1 && abs(pastTheRegion[1] - 0.5) < 0.03, "\(pastTheRegion)")

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

/// View in 3D and the GeoTIFF exports over a view the map still draws, after the provider's cache has let its tiles go.
///
/// The cache evicts by age (160 tiles, 256 MB), and the renderer never asks again for a tile it holds an image of, so the
/// tiles of a view the map has fully drawn age out while they stay on screen. On the owner's iPad, View in 3D over a
/// clearly drawn view near Paris, TN said "No terrain has drawn for this view yet". The renderer's on-screen tiles are
/// registered only after the turnover, so the check still tests the read-back once the budget spares on-screen tiles.
@MainActor
private func checkDrawnViewOutlivesTheBudget() async {
    print("\n--- U3. a drawn view after the provider's cache has turned over ---")
    var counted: ReadBackTerrainStub?
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0) { synthetic in
        let stub = ReadBackTerrainStub(synthetic)
        counted = stub
        return stub
    }
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    // Two tiles across, centred on the centre tile: the view touches all nine tiles and lies half a tile inside them, so
    // the LRM's 27 m skirt stays on them too.
    let tile = scene.region()
    let view = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: 2 * tile.latitudeSpan, longitudeDelta: 2 * tile.longitudeSpan))
    let viewGeo = GeoRegion(center: view.center, latitudeSpan: view.span.latitudeDelta, longitudeSpan: view.span.longitudeDelta)
    // The nine, drawn: what the renderer holds and reports (``TerrainTileOverlayRenderer/drawnTiles()``), each with the image
    // the provider shaded for it.
    let fineTiles = await drawnTiles(of: scene, at: (-1...1).flatMap { dy in (-1...1).map { dx in (dx, dy) } })
    let viewTiles = Set(fineTiles.keys)
    // And their parent, a level coarser, still held from when it stood in for them while they loaded. They cover all of it,
    // so the map draws it nowhere. Solid red, so a drape that lays it under their translucent shading shows it.
    let parent = MKTileOverlayPath(x: scene.x / 2, y: scene.y / 2, z: scene.z - 1, contentScaleFactor: 1)
    let parentKey = TerrainTileOverlayRenderer.key(parent)
    var drawn = fineTiles
    drawn[parentKey] = TileComposite.Tile(
        image: solidImage(255, 0, 0), region: TerrainTileOverlay.region(for: parent), zoom: parent.z)
    let drawnNow = drawn
    // A row of 170 tiles well east of the view, as a long session pans and zooms elsewhere: more than the cache's 160,
    // so the view's nine, loaded first, are the first to go.
    for dx in 10..<180 { await scene.image(dx: dx, dy: 0) }
    await scene.provider.setVisibleKeysSource { viewTiles.union([parentKey]) }
    await scene.provider.setDrawnTilesSource { drawnNow }
    let hasPipeline = await MetalTerrainPipelineActor.shared.isAvailable()

    /// A fresh model's View in 3D, elevation GeoTIFF and (with the pipeline) LRM GeoTIFF of the view: the scene, the
    /// alert, and each export's coverage notice or error.
    func openAndExport() async -> (scene: Terrain3DScene?, alert: String?, elevation: Result<String?, any Error>,
                                   relief: Result<String?, any Error>?) {
        let model = TerrainViewerModel(terrainProvider: scene.provider)
        model.liveVisibleRegion = { view }
        await model.openTerrain3D()
        func export(_ content: GeoTIFFContent) async -> Result<String?, any Error> {
            do {
                let url = try await model.exportCurrentRegionAsGeoTIFF(content)
                try? FileManager.default.removeItem(at: url)
                return .success(model.exportNotice)
            } catch {
                return .failure(error)
            }
        }
        let elevation = await export(.elevation)
        let relief = hasPipeline ? await export(.analytical(.localRelief)) : nil
        return (model.terrain3DScene, model.inspectorMessage, elevation, relief)
    }
    func writesAll(_ result: Result<String?, any Error>?) -> Bool {
        if case .success(nil)? = result { return true }
        return false
    }
    func describe(_ result: Result<String?, any Error>?) -> String {
        switch result {
        case .success(let notice)?: "notice \(notice ?? "none")"
        case .failure(let error)?: "\(error)"
        case nil: "not run"
        }
    }

    // The model exports to the system's temporary directory, named to the second: one run at a time.
    await withSystemTemporaryDirectoryLock {
        let before = await scene.provider.cachedTileKeys()
        let held = before.intersection(viewTiles).count
        let requestsBefore = counted?.callCount ?? -1
        let turnedOver = await openAndExport()
        let requested = (counted?.callCount ?? -1) - requestsBefore
        let after = await scene.provider.cachedTileKeys()
        check("View in 3D over a view the map still draws meshes all of it after 170 tiles have loaded elsewhere",
              turnedOver.scene != nil && turnedOver.scene?.coverageNotice == nil && turnedOver.alert == nil,
              "provider holds \(held) of the view's 9 tiles; alert \(turnedOver.alert ?? "none"); notice \(turnedOver.scene?.coverageNotice ?? "none")")
        check("and a GeoTIFF export of that view writes all of it", writesAll(turnedOver.elevation),
              describe(turnedOver.elevation))
        if hasPipeline {
            check("and an analytical GeoTIFF (LRM) of that view writes all of it", writesAll(turnedOver.relief),
                  describe(turnedOver.relief))
        } else {
            print("        (LRM export skipped: no Metal micro-topography pipeline)")
        }
        // Stored, a tile read back would evict another the map is drawing. At the cache's cap the count alone would not
        // move (each store evicts one), so the tiles themselves are compared.
        check("what View in 3D and the exports read back is not kept: the provider holds the same tiles before and after",
              before.count == 160 && after == before,
              "\(before.count) before, \(after.count) after, \(after.subtracting(before).count) new")

        // The drape. The provider's own bitmaps (48 at most) went with the tiles it let go; the map still draws every one.
        let background = CGColor(gray: 0.92, alpha: 1)
        let composite = await scene.provider.shadedComposite(over: viewGeo, maxPixels: 256)
        let expected = TileComposite.render(tiles: Array(fineTiles.values), region: viewGeo, maxPixels: 256, background: background)
        let differing = differingPixelShare(composite, expected)
        check("and the 3D view drapes the shading the map draws there, though the provider holds none of those tiles' bitmaps",
              turnedOver.scene?.texture != nil && composite != nil && differing.map { $0 < 0.005 } == true,
              "texture \(turnedOver.scene?.texture != nil), composite \(composite != nil), share of pixels off the map's composite \(differing.map { String($0) } ?? "n/a")")
        // The parent: the map draws it nowhere, so it is not read back (it is on no disk, and its fetch would reach the
        // terrain), and laid under the finer tiles' translucent shading it would tint the whole drape.
        let reddish = reddishPixelShare(composite)
        check("a coarser tile the map holds under finer ones that cover the view is neither read back nor laid under their shading",
              requested == 0 && composite != nil && reddish == 0,
              "\(requested) terrain request(s) during View in 3D and the exports; share of red pixels in the drape \(reddish)")

        // One of the nine loaded again after the turnover: the cache now holds part of the view, and the read-back must
        // still bring back the other eight rather than stop at what the cache has.
        await scene.image()
        let heldAgain = await scene.provider.cachedTileKeys().intersection(viewTiles).count
        let partlyHeld = await openAndExport()
        check("with one of the view's nine loaded again after the turnover, View in 3D still meshes all of it",
              heldAgain == 1 && partlyHeld.scene != nil && partlyHeld.scene?.coverageNotice == nil && partlyHeld.alert == nil,
              "provider holds \(heldAgain) of the view's 9 tiles; alert \(partlyHeld.alert ?? "none"); notice \(partlyHeld.scene?.coverageNotice ?? "none")")
        check("and its GeoTIFF exports, elevation and LRM, still write all of it",
              writesAll(partlyHeld.elevation) && (!hasPipeline || writesAll(partlyHeld.relief)),
              "elevation \(describe(partlyHeld.elevation)); LRM \(describe(partlyHeld.relief))")
    }

    await checkReadBackWaitsOnNothingLoading(scene)
}

/// View in 3D and the exports never wait on a load: a tile the map is still loading has drawn nothing, and one it drew that
/// must be fetched again (a fallback or a mounted file's, never written to disk) is waited for only up to
/// ``TerrainTileProvider/readBackFetchDeadline``.
@MainActor
private func checkReadBackWaitsOnNothingLoading(_ layout: SyntheticTileScene) async {
    // The renderer reports what it has drawn, not what it is loading, which ``TerrainTileOverlayRenderer/visibleTileKeys()``
    // names too, for the memory warning to spare.
    let gate = GatedTerrainStub(SyntheticTerrainStub(moundCenterMercator: nil, groundMetersPerMercatorMeter: 1))
    let gatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("u3-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: gatedDirectory) }
    let renderer = TerrainTileOverlayRenderer(
        tileOverlay: TerrainTileOverlay(provider: TerrainTileProvider(elevation: gate, gridCache: TileDiskCache(directory: gatedDirectory))))
    let path = MKTileOverlayPath(x: layout.x, y: layout.y, z: layout.z, contentScaleFactor: 1)
    let rect = TerrainTileOverlay.mapRect(for: path), key = TerrainTileOverlayRenderer.key(path)
    _ = renderer.canDraw(rect, zoomScale: 0.5)
    renderer.cullTiles(outsideVisible: rect)
    let loading = renderer.drawnTiles(), onScreen = renderer.visibleTileKeys()
    gate.open()
    // Then its east neighbour draws, and the screen moves just inside the first tile: the neighbour is kept, within the
    // margin a pan reversal brings back, but is off the screen.
    let neighbour = MKTileOverlayPath(x: layout.x + 1, y: layout.y, z: layout.z, contentScaleFactor: 1)
    let neighbourKey = TerrainTileOverlayRenderer.key(neighbour)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, renderer.store.image(for: key) == nil || renderer.store.image(for: neighbourKey) == nil {
        _ = renderer.canDraw(TerrainTileOverlay.mapRect(for: neighbour), zoomScale: 0.5)
        try? await Task.sleep(for: .milliseconds(10))
    }
    renderer.cullTiles(outsideVisible: rect.insetBy(dx: rect.width * 0.01, dy: rect.height * 0.01))
    let landed = renderer.drawnTiles()
    check("the map reports the tiles it has drawn on screen, each with its image: not a load still in flight, nor a tile it keeps off the screen",
          onScreen.contains(key) && loading.isEmpty && renderer.store.image(for: neighbourKey) != nil && landed.count == 1
            && landed[key].map { $0.image === renderer.store.image(for: key) && $0.zoom == layout.z } == true,
          "on screen \(onScreen.sorted()); drawn while loading \(loading.keys.sorted()); drawn once landed \(landed.keys.sorted()); neighbour held \(renderer.store.image(for: neighbourKey) != nil)")

    // A tile the map drew that is on no disk and whose fetch now hangs, as a fallback's does on a poor connection. Here the
    // view's east tile: never loaded, so neither cached nor on disk, and its request held 8 s whatever happens meanwhile.
    var holding: ReadBackTerrainStub?
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0) { synthetic in
        let stub = ReadBackTerrainStub(synthetic)
        holding = stub
        return stub
    }
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    holding?.hold(scene.region(dx: 1), seconds: 8)
    let others = (-1...1).flatMap { dy in (-1...1).map { dx in (dx, dy) } }.filter { $0 != (1, 0) }
    var drawn = await drawnTiles(of: scene, at: others)
    let east = MKTileOverlayPath(x: scene.x + 1, y: scene.y, z: scene.z, contentScaleFactor: 1)
    drawn[TerrainTileOverlayRenderer.key(east)] = TileComposite.Tile(
        image: solidImage(200, 200, 200, alpha: 30), region: TerrainTileOverlay.region(for: east), zoom: east.z)
    let drawnNow = drawn
    await scene.provider.setVisibleKeysSource { Set(drawnNow.keys) }
    await scene.provider.setDrawnTilesSource { drawnNow }
    let tile = scene.region()
    let view = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: 2 * tile.latitudeSpan, longitudeDelta: 2 * tile.longitudeSpan))
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.liveVisibleRegion = { view }
    let clock = ContinuousClock()
    let bound = TerrainTileProvider.readBackFetchDeadline + .milliseconds(1500)
    let opening = clock.now
    await model.openTerrain3D()
    let opened = clock.now - opening
    // The east tile lies on an eighth of the view: a quarter of its width, half its height.
    let notice = model.terrain3DScene?.coverageNotice
    check("a drawn tile whose fetch hangs holds View in 3D no longer than the read-back's deadline: the view opens without it and says how much it holds",
          opened < bound && model.terrain3DScene != nil && (84...90).contains(percent(in: notice) ?? -1),
          "took \(opened) (bound \(bound)); notice \(notice ?? "none"); alert \(model.inspectorMessage ?? "none")")
    var exported: Duration = .zero
    var fileNotice: String?
    var failure: (any Error)?
    await withSystemTemporaryDirectoryLock {
        let exporting = clock.now
        do {
            let url = try await model.exportCurrentRegionAsGeoTIFF(.elevation)
            try? FileManager.default.removeItem(at: url)
            fileNotice = model.exportNotice
        } catch {
            failure = error
        }
        exported = clock.now - exporting
    }
    check("and a GeoTIFF export of that view: written without it within the deadline, saying how much it covers",
          exported < bound && failure == nil && (84...90).contains(percent(in: fileNotice) ?? -1),
          "took \(exported) (bound \(bound)); notice \(fileNotice ?? "none"); error \(failure.map { "\($0)" } ?? "none")")
}

/// The grid View in 3D meshes and the elevation GeoTIFF writes (``TerrainTileProvider/activeGrid(covering:)``) reaches every
/// edge of the view.
///
/// The mosaic builder lays the grid out in sphere Mercator, where a degree of latitude is 111,319.5 m at the grid's centre.
/// The grid was sized from the view's ground metres (``GeoRegion/heightMeters``, 111,132 m to the degree) and centred on its
/// mean latitude, south of its Mercator middle, so a complete tall view's grid stopped 8-18 m short of the view's north and
/// south edges (and a wide one's about 14 m short of its east and west). On the 13-inch iPad in portrait, the second row of
/// points the coverage share reads lies a quarter point inside the region's top edge, so a fully drawn tall view said
/// "Only 98%".
///
/// The views are the 13-inch iPad's map in portrait (1032 by 1324 pt: its region leaves out the safe area's strips) at three
/// zooms, and the largest turned landscape, over the synthetic scene's centre tile: one tile they all touch, since the grid
/// spans the view whatever of it has elevation. Each reach is measured to the grid's cells' outer edges, as far as a point
/// reads elevation (``TerrainTileProvider/elevationShare(of:in:samplesPerSide:)``), in ground metres at that edge, and must
/// be a centimetre at least: past the edge, not on it within a rounding.
@MainActor
private func checkGridReachesTheViewEdges() async {
    print("\n--- U4. the grid reaches a tall view's edges ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.image()
    let centre = scene.region().center
    let views: [(name: String, width: Double, height: Double)] = [
        ("12,642 x 16,219 m portrait", 12_642, 16_219), ("10,072 x 12,922 m portrait", 10_072, 12_922),
        ("933 x 1,198 m portrait", 933, 1_198), ("16,219 x 12,642 m landscape", 16_219, 12_642),
    ]
    var offCentre: [String] = [], partShares: [String] = []
    for (name, width, height) in views {
        let view = GeoRegion(
            center: centre, latitudeSpan: height / GeoRegion.metersPerDegreeLatitude,
            longitudeSpan: width / (GeoRegion.metersPerDegreeLatitude * cos(centre.latitude * .pi / 180)))
        let region = MKCoordinateRegion(
            center: view.center, span: MKCoordinateSpan(latitudeDelta: view.latitudeSpan, longitudeDelta: view.longitudeSpan))
        let label = "a \(name) view's grid reaches past all four of its edges, by a centimetre at least"
        guard let grid = await scene.provider.activeGrid(covering: region), grid.width > 1, grid.height > 1 else {
            check(label, false, "no grid")
            continue
        }
        // Node-registered: the region runs through the outermost samples, and each stands for the cell around it.
        let g = grid.region.mercatorBounds, v = view.mercatorBounds
        let cellX = (g.maxX - g.minX) / Double(grid.width - 1), cellY = (g.maxY - g.minY) / Double(grid.height - 1)
        let past = (north: g.maxY + cellY / 2 - v.maxY, south: v.minY - (g.minY - cellY / 2),
                    east: g.maxX + cellX / 2 - v.maxX, west: v.minX - (g.minX - cellX / 2))
        func ground(_ mercator: Double, at latitude: Double) -> Double { mercator * cos(latitude * .pi / 180) }
        let north = ground(past.north, at: view.maxLatitude), south = ground(past.south, at: view.minLatitude)
        let east = ground(past.east, at: view.centerLatitude), west = ground(past.west, at: view.centerLatitude)
        check(label, min(north, south, east, west) >= 0.01,
              String(format: "past its edges N %.3f S %.3f E %.3f W %.3f m; %d x %d cells of %.3f m",
                     north, south, east, west, grid.width, grid.height, ground(cellY, at: view.centerLatitude)))
        // The builder lays the grid out evenly about its centre, in Mercator.
        let northSouth = abs(past.north - past.south) / cellY, eastWest = abs(past.east - past.west) / cellX
        if max(northSouth, eastWest) > 0.01 {
            offCentre.append("\(name): " + String(format: "north-south %.3f, east-west %.3f of a cell", northSouth, eastWest))
        }
        // The share the 3D view and the file report, on this grid's extent with elevation everywhere, read over the 13-inch
        // screen in portrait: 1376 pt tall, 32 of them above the region and 20 below.
        guard width < height else { continue }
        let full = ElevationGrid(
            width: grid.width, height: grid.height,
            samples: [Float](repeating: 100, count: grid.width * grid.height), region: grid.region)
        let point = (v.maxY - v.minY) / 1324
        let top = v.maxY + 32 * point, bottom = v.minY - 20 * point
        let corners = [(v.minX, top), (v.maxX, top), (v.minX, bottom), (v.maxX, bottom)].map {
            GeoRegion.fromMercatorMeters(x: $0.0, y: $0.1)
        }
        let share = TerrainViewerModel.elevationShare(of: view, onScreen: corners, in: full)
        if let notice = TerrainViewerModel.coverageNotice(share: share, inFile: false) {
            partShares.append("\(name): \(notice)")
        }
    }
    check("each grid is centred on its view as the builder lays it out, in Mercator: as far past the north edge as the south, and the east as the west, to a hundredth of a cell",
          offCentre.isEmpty, offCentre.joined(separator: "; "))
    check("and with elevation everywhere on it, each portrait view's grid reads all of the view on the 13-inch screen, whose second row of points from the top lies a quarter point inside the region: no \"Only 98%\"",
          partShares.isEmpty, partShares.joined(separator: "; "))
}

/// The scene's tiles at `offsets` (dx, dy from its centre tile), loaded, as the renderer reports them drawn: keyed by tile,
/// each with the image the provider shaded for it.
@MainActor
private func drawnTiles(of scene: SyntheticTileScene, at offsets: [(Int, Int)]) async -> [String: TileComposite.Tile] {
    var tiles: [String: TileComposite.Tile] = [:]
    for (dx, dy) in offsets {
        guard let image = await scene.image(dx: dx, dy: dy) else { continue }
        let path = MKTileOverlayPath(x: scene.x + dx, y: scene.y + dy, z: scene.z, contentScaleFactor: 1)
        tiles[TerrainTileOverlayRenderer.key(path)] = TileComposite.Tile(
            image: image, region: TerrainTileOverlay.region(for: path), zoom: path.z)
    }
    return tiles
}

/// An image's RGBA bytes, premultiplied, row 0 at the top.
private func rgba(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? data : nil
}

/// The share of pixels where `a` and `b` differ by more than 8 in any channel; nil unless both are images of one size.
private func differingPixelShare(_ a: CGImage?, _ b: CGImage?) -> Double? {
    guard let a, let b, a.width == b.width, a.height == b.height, let x = rgba(a), let y = rgba(b) else { return nil }
    var differing = 0
    for i in stride(from: 0, to: x.count, by: 4) where (0..<4).contains(where: { abs(Int(x[i + $0]) - Int(y[i + $0])) > 8 }) {
        differing += 1
    }
    return Double(differing) / Double(x.count / 4)
}

/// The share of an image's pixels that are plainly red; 0 for none.
private func reddishPixelShare(_ image: CGImage?) -> Double {
    guard let image, let bytes = rgba(image) else { return 0 }
    var red = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[i]) > Int(bytes[i + 1]) + 40 && Int(bytes[i]) > Int(bytes[i + 2]) + 40 {
        red += 1
    }
    return Double(red) / Double(bytes.count / 4)
}

/// The synthetic terrain, counting the requests that reach it, and holding those for one tile's ground for a set time
/// whatever happens meanwhile, cancellation included: a fetch that hangs, as one does on a poor connection.
nonisolated final class ReadBackTerrainStub: ElevationProviding {
    private let inner: SyntheticTerrainStub
    private let state = OSAllocatedUnfairLock(initialState: (calls: 0, held: GeoRegion?.none, seconds: 0.0))
    init(_ inner: SyntheticTerrainStub) { self.inner = inner }
    var callCount: Int { state.withLock { $0.calls } }
    /// Holds each request centred on `region` for `seconds`.
    func hold(_ region: GeoRegion, seconds: Double) { state.withLock { $0.held = region; $0.seconds = seconds } }
    func elevation(for region: GeoRegion, targetSamples count: Int) async -> Evidence<ElevationGrid> {
        let (held, seconds) = state.withLock { s -> (GeoRegion?, Double) in
            s.calls += 1
            return (s.held, s.seconds)
        }
        if let held, held.contains(region.center) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
            }
        }
        return await inner.elevation(for: region, targetSamples: count)
    }
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

/// The synthetic scene with only `tiles` loaded, each (dx, dy) from its centre tile.
@MainActor
func makePartialScene(_ tiles: [(Int, Int)]) async -> SyntheticTileScene {
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    for (dx, dy) in tiles { await scene.image(dx: dx, dy: dy) }
    return scene
}

/// A square screen turned 45 degrees over the scene's centre tile, its corners at the centres of the four side neighbours:
/// the region the map view gives for it (the north-up box around it) and its corners.
@MainActor
func turnedView(_ scene: SyntheticTileScene) -> (region: MKCoordinateRegion, corners: [CLLocationCoordinate2D]) {
    let tile = scene.region()
    let centre = tile.center, across = tile.longitudeSpan, up = tile.latitudeSpan
    let corners = [
        CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude - across),
        CLLocationCoordinate2D(latitude: centre.latitude + up, longitude: centre.longitude),
        CLLocationCoordinate2D(latitude: centre.latitude - up, longitude: centre.longitude),
        CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude + across),
    ]
    return (MKCoordinateRegion(center: centre, span: MKCoordinateSpan(latitudeDelta: 2 * up, longitudeDelta: 2 * across)), corners)
}
