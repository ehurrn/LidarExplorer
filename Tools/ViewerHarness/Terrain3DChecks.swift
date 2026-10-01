//
//  Terrain3DChecks.swift
//  ViewerHarness
//
//  The 3D view's data path: stitching shaded tiles into a texture, the viewer model preparing a scene, a view the map
//  still draws after the provider's cache has let its tiles go (U3), the grid reaching a tall view's edges (U4), and the
//  provider's budget sparing the tiles on screen (U5).
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
    await checkBudgetSparesTheTilesOnScreen()
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
/// mean latitude, so a complete tall view's grid stopped 8-18 m short of the view's north and south edges (and a wide one's
/// about 14 m short of its east and west). On the 13-inch iPad in portrait, the second row of points the coverage share reads
/// lies a quarter point inside the region's top edge, so a fully drawn tall view said "Only 98%".
///
/// The regions are MapKit's (`MKMapView.region`): centred on the Mercator middle of the map's rect, their latitude span
/// running from its south edge to its north. Mercator stretches with latitude, so the rect's north half spans fewer degrees
/// than its south, and the box centre ± span/2 the coverage share reads (`GeoRegion(center:latitudeSpan:longitudeSpan:)`)
/// lies north of the rect: 4 m on a 16 km view at Paris, TN, as the Simulator logged it, and kilometres on a continent. A
/// grid centred on that box's own Mercator middle lost the rect's south edge on views over about 30 km tall here, with no
/// notice, since the share never reads past the box. So the grid must reach past the edges of both.
///
/// The views are the 13-inch iPad's map in portrait (1032 by 1324 pt: its region leaves out the safe area's strips) at five
/// zooms, from a continent to a kilometre, and one turned landscape, over the synthetic scene's centre tile: one tile they all
/// touch, since the grid spans the view whatever of it has elevation. Each reach is measured to the grid's cells' outer
/// edges, as far as a point reads elevation (``TerrainTileProvider/elevationShare(of:in:samplesPerSide:)``), in ground metres
/// at that edge, and must be a centimetre at least: past the edge, not on it within a rounding.
@MainActor
private func checkGridReachesTheViewEdges() async {
    print("\n--- U4. the grid reaches a tall view's edges ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.image()
    let centre = scene.region().center
    let c = GeoRegion.toMercatorMeters(centre), k = cos(centre.latitude * .pi / 180)
    // Ground metres at the centre.
    let views: [(name: String, width: Double, height: Double)] = [
        ("12,642 x 16,219 m portrait", 12_642, 16_219), ("10,072 x 12,922 m portrait", 10_072, 12_922),
        ("933 x 1,198 m portrait", 933, 1_198), ("16,219 x 12,642 m landscape", 16_219, 12_642),
        ("46.8 x 60 km portrait", 46_800, 60_000), ("1,170 x 1,500 km portrait", 1_170_000, 1_500_000),
    ]
    typealias Bounds = (minX: Double, minY: Double, maxX: Double, maxY: Double)
    var offCentre: [String] = [], partShares: [String] = []
    for (name, width, height) in views {
        // The map's rect, in Mercator about its middle, and the region MapKit gives for it.
        let rect: Bounds = (c.x - width / 2 / k, c.y - height / 2 / k, c.x + width / 2 / k, c.y + height / 2 / k)
        let southWest = GeoRegion.fromMercatorMeters(x: rect.minX, y: rect.minY)
        let northEast = GeoRegion.fromMercatorMeters(x: rect.maxX, y: rect.maxY)
        let region = MKCoordinateRegion(center: centre, span: MKCoordinateSpan(
            latitudeDelta: northEast.latitude - southWest.latitude, longitudeDelta: northEast.longitude - southWest.longitude))
        let box = GeoRegion(center: centre, latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta)
        let label = "a \(name) view's grid reaches past all four edges of the map's rect and of the box the share reads, by a centimetre at least"
        guard let grid = await scene.provider.activeGrid(covering: region), grid.width > 1, grid.height > 1 else {
            check(label, false, "no grid")
            continue
        }
        // Node-registered: the region runs through the outermost samples, and each stands for the cell around it.
        let g = grid.region.mercatorBounds
        let cellX = (g.maxX - g.minX) / Double(grid.width - 1), cellY = (g.maxY - g.minY) / Double(grid.height - 1)
        func past(_ v: Bounds) -> (north: Double, south: Double, east: Double, west: Double) {
            (g.maxY + cellY / 2 - v.maxY, v.minY - (g.minY - cellY / 2), g.maxX + cellX / 2 - v.maxX, v.minX - (g.minX - cellX / 2))
        }
        // In ground metres at each edge.
        func ground(_ v: Bounds) -> (north: Double, south: Double, east: Double, west: Double) {
            let p = past(v)
            func at(_ y: Double) -> Double { cos(GeoRegion.fromMercatorMeters(x: c.x, y: y).latitude * .pi / 180) }
            return (p.north * at(v.maxY), p.south * at(v.minY), p.east * k, p.west * k)
        }
        let onRect = ground(rect), onBox = ground(box.mercatorBounds)
        check(label, min(onRect.north, onRect.south, onRect.east, onRect.west, onBox.north, onBox.south) >= 0.01,
              String(format: "past the rect's edges N %.3f S %.3f E %.3f W %.3f m, the box's N %.3f S %.3f m; %d x %d cells of %.3f m",
                     onRect.north, onRect.south, onRect.east, onRect.west, onBox.north, onBox.south,
                     grid.width, grid.height, cellY * k))
        // The builder lays the grid out evenly about the centre it is given, in Mercator: the region's, the rect's middle.
        let p = past(rect)
        let northSouth = abs(p.north - p.south) / cellY, eastWest = abs(p.east - p.west) / cellX
        if max(northSouth, eastWest) > 0.01 {
            offCentre.append("\(name): " + String(format: "north-south %.3f, east-west %.3f of a cell", northSouth, eastWest))
        }
        // The share the 3D view and the file report, on this grid's extent with elevation everywhere, read over the 13-inch
        // screen in portrait: 1376 pt tall, 32 of them above the map's rect and 20 below.
        guard width < height else { continue }
        let full = ElevationGrid(
            width: grid.width, height: grid.height,
            samples: [Float](repeating: 100, count: grid.width * grid.height), region: grid.region)
        let point = (rect.maxY - rect.minY) / 1324
        let top = rect.maxY + 32 * point, bottom = rect.minY - 20 * point
        let corners = [(rect.minX, top), (rect.maxX, top), (rect.minX, bottom), (rect.maxX, bottom)].map {
            GeoRegion.fromMercatorMeters(x: $0.0, y: $0.1)
        }
        let share = TerrainViewerModel.elevationShare(of: box, onScreen: corners, in: full)
        if let notice = TerrainViewerModel.coverageNotice(share: share, inFile: false) {
            partShares.append("\(name): \(notice)")
        }
    }
    check("each grid is centred on its region's centre, the middle of the map's rect, as the builder lays it out in Mercator: as far past the rect's north edge as its south, and its east as its west, to a hundredth of a cell",
          offCentre.isEmpty, offCentre.joined(separator: "; "))
    check("and with elevation everywhere on it, each portrait view's grid reads all of the view on the 13-inch screen, whose second row of points from the top lies a quarter point inside the map's rect: no \"Only 98%\"",
          partShares.isEmpty, partShares.joined(separator: "; "))
    let noExtent = MKCoordinateRegion(center: centre, span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0))
    let noExtentGrid = await scene.provider.activeGrid(covering: noExtent)
    check("a region with no extent has no grid, not a few cells around its centre",
          noExtentGrid == nil, noExtentGrid.map { "\($0.width) x \($0.height) cells" } ?? "")
}

/// The provider's memory budget (``TerrainTileProvider/maxMemoryCacheBytes`` and 160 tiles) spares the tiles on screen, and
/// sheds the shaded bitmaps only it holds, on screen or off, before any whole tile.
///
/// The renderer never asks again for a tile it holds an image of, so by age alone the tiles of a view the map keeps drawing
/// were the first the budget let go. Spot inspection, the viewshed and the transect read only this cache, and met holes
/// where the map drew: "Elevation unavailable" on drawn terrain. Here the tiles are registered as on screen before the loads
/// elsewhere, as the renderer registers them at its first region change. On screen means the tiles the renderer holds or
/// is loading there (``TerrainTileProvider/setVisibleKeysSource(_:)``) and the tiles where the map looks
/// (``TerrainTileProvider/setVisibleViewSource(_:)``), which MapKit may draw from its own layer with the renderer holding
/// none of them.
///
/// The host shades on the GPU wherever there is Metal, so no tile here holds the CPU fallback's derivative planes, which
/// only the fallback computes (the Simulator's path: six planes a tile beside its raster, so its byte budget held about 31
/// tiles). The byte budget is driven over by 1024 px tiles' rasters and bitmaps instead, and the planes' turn is seen only
/// in the Simulator.
@MainActor
private func checkBudgetSparesTheTilesOnScreen() async {
    print("\n--- U5. the provider's budget spares the tiles on screen ---")
    func key(_ scene: SyntheticTileScene, _ dx: Int, _ dy: Int = 0) -> String {
        TerrainTileOverlayRenderer.key(MKTileOverlayPath(x: scene.x + dx, y: scene.y + dy, z: scene.z, contentScaleFactor: 1))
    }
    /// One tile, at `pixels` a side: at 1024 px about 4 MB of raster and 4 MB of bitmap, four times what 512 px holds.
    func load(_ scene: SyntheticTileScene, _ dx: Int, pixels: Int) async {
        _ = await scene.provider.tileImage(
            x: scene.x + dx, y: scene.y, z: scene.z, region: scene.region(dx: dx), pixels: pixels)
    }
    let budget = TerrainTileProvider.maxMemoryCacheBytes
    func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    // The count cap: a view's nine tiles, then 170 elsewhere, as a long session pans and zooms, over the cap of 160. The
    // budget alone does not bind: 169 rasters and 48 bitmaps at 512 px are about 222 MB.
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let nine = Set((-1...1).flatMap { dy in (-1...1).map { dx in key(scene, dx, dy) } })
    await scene.provider.setVisibleKeysSource { nine }
    for dx in 10..<180 { await scene.image(dx: dx, dy: 0) }
    let held = await scene.provider.cachedTileKeys()
    check("with a view's nine tiles on screen, 170 tiles loaded elsewhere leave the provider holding all nine",
          nine.isSubset(of: held), "holds \(held.intersection(nine).count) of the 9; \(held.count) tiles in all")
    check("and it holds its cap of 160 tiles: tiles off the screen go, and no more of them than the cap needs",
          held.count == 160, "\(held.count) tiles")
    let tile = scene.region(), centre = scene.region().center
    let reading = await scene.provider.elevation(at: centre)
    let inspection = await scene.provider.inspectSpot(at: centre)
    let profile = await scene.provider.profile(
        from: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude - tile.longitudeSpan),
        to: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude + tile.longitudeSpan))
    check("and an elevation reading and spot inspection at the view's centre, and a profile across it, answer from the cache",
          reading != nil && inspection != nil && profile != nil,
          "reading \(reading.map { "\($0) m" } ?? "none"); inspection \(inspection != nil); profile \(profile != nil)")

    // A zoomed-out view can show more tiles than the cap: the provider still holds no more than the cap, its newest.
    let wide = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: wide.directory) }
    let row = (0..<170).map { key(wide, $0) }
    let rowOnScreen = Set(row)
    await wide.provider.setVisibleKeysSource { rowOnScreen }
    for dx in 0..<170 { await wide.image(dx: dx, dy: 0) }
    let wideHeld = await wide.provider.cachedTileKeys()
    check("a view showing 170 tiles, more than the cap: the provider holds 160 of them, the most recent",
          wideHeld == Set(row.suffix(160)),
          "\(wideHeld.count) held; \(wideHeld.subtracting(row.suffix(160)).count) of them not among the newest 160")

    // The byte budget: the nine at 512 px on screen, then 38 tiles at 1024 px elsewhere, which take the cache to about
    // 325 MB, rasters 164 and bitmaps 161 (47 bitmaps, within the provider's 48).
    let heavy = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    defer { try? FileManager.default.removeItem(at: heavy.directory) }
    await heavy.loadNeighbourhood()
    let heavyNine = Set((-1...1).flatMap { dy in (-1...1).map { dx in key(heavy, dx, dy) } })
    await heavy.provider.setVisibleKeysSource { heavyNine }
    for dx in 10..<48 { await load(heavy, dx, pixels: 1024) }
    let shedHeld = await heavy.provider.cachedTileKeys()
    let shedShaded = await heavy.provider.renderedTileKeys()
    let shedBytes = await heavy.provider.memoryCacheSize()
    check("over the byte budget, the provider sheds the bitmaps of tiles off the screen, oldest first, before any whole tile: it holds all 47 within 256 MB, the nine on screen with their bitmaps",
          shedHeld.count == 47 && shedBytes <= budget && heavyNine.isSubset(of: shedShaded)
            && !shedShaded.contains(key(heavy, 10)) && shedShaded.contains(key(heavy, 47)),
          "\(shedHeld.count) held, \(megabytes(shedBytes)); \(shedShaded.intersection(heavyNine).count) of the 9 shaded; oldest elsewhere shaded \(shedShaded.contains(key(heavy, 10))), newest \(shedShaded.contains(key(heavy, 47)))")
    // 32 more: their rasters alone, with the nine's, come to about 294 MB.
    for dx in 48..<80 { await load(heavy, dx, pixels: 1024) }
    let evictedHeld = await heavy.provider.cachedTileKeys()
    let evictedBytes = await heavy.provider.memoryCacheSize()
    let heavyReading = await heavy.provider.elevation(at: heavy.region().center)
    check("and with the rasters alone over it, whole tiles off the screen go, oldest first, and the nine on screen stay: a reading at the view's centre still answers",
          heavyNine.isSubset(of: evictedHeld) && evictedBytes <= budget && evictedHeld.count < 79
            && !evictedHeld.contains(key(heavy, 10)) && evictedHeld.contains(key(heavy, 79)) && heavyReading != nil,
          "holds \(evictedHeld.intersection(heavyNine).count) of the 9, \(evictedHeld.count) in all, \(megabytes(evictedBytes)); reading \(heavyReading.map { "\($0) m" } ?? "none")")

    // A view the renderer still draws but no longer holds the images of. In the Simulator, after a pan a screen away and
    // back, MapKit drew the view again from its own layer, asking for none of its tiles, and the renderer, which had let
    // their images go at the pan, held 7 of the 35. Where the map looks (``TerrainTileView``) still takes in all of them.
    func viewOfRow(_ scene: SyntheticTileScene, _ range: Range<Int>) -> TerrainTileView {
        let first = TerrainTileOverlay.mapRect(for: MKTileOverlayPath(x: scene.x + range.lowerBound, y: scene.y, z: scene.z, contentScaleFactor: 1))
        let last = TerrainTileOverlay.mapRect(for: MKTileOverlayPath(x: scene.x + range.upperBound - 1, y: scene.y, z: scene.z, contentScaleFactor: 1))
        // Just inside the row's edges, so that a tile beside it lies off the screen rather than touching its edge.
        return TerrainTileView(rect: first.union(last).insetBy(dx: first.width * 0.01, dy: first.height * 0.01),
                               drawnLevels: scene.z...scene.z)
    }

    // The tiles on screen alone over the byte budget, as in the Simulator, where the CPU fallback's derivative planes
    // (about 8 MB a tile with its bitmap) put the 35 tiles of a 1 km view at about 290 MB: 40 tiles at 1024 px on screen,
    // about 323 MB, the renderer holding the oldest 7. The bitmaps of the other 33 go, not their rasters, which are what
    // spot inspection reads; the 7 the renderer holds keep theirs, which are its own images too.
    let packed = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: packed.directory) }
    let forty = (0..<40).map { key(packed, $0) }
    let fortyOnScreen = Set(forty), packedRendererHolds = Set(forty.prefix(7))
    let packedView = viewOfRow(packed, 0..<40)
    await packed.provider.setVisibleKeysSource { packedRendererHolds }
    await packed.provider.setVisibleViewSource { packedView }
    for dx in 0..<40 { await load(packed, dx, pixels: 1024) }
    let packedHeld = await packed.provider.cachedTileKeys()
    let packedShaded = await packed.provider.renderedTileKeys()
    let packedBytes = await packed.provider.memoryCacheSize()
    check("with the tiles on screen alone over the byte budget, those the renderer no longer holds shed their bitmaps, oldest first, rather than go: all 40 held within 256 MB, the 7 it holds with theirs",
          packedHeld == fortyOnScreen && packedBytes <= budget && packedRendererHolds.isSubset(of: packedShaded)
            && !packedShaded.contains(forty[7]) && packedShaded.contains(forty[39]),
          "\(packedHeld.count) of 40 held, \(megabytes(packedBytes)); \(packedShaded.count) shaded, \(packedShaded.intersection(packedRendererHolds).count) of the 7 the renderer holds, the oldest of the rest \(packedShaded.contains(forty[7])), the newest \(packedShaded.contains(forty[39]))")

    // Tiles off the screen, then 30 on it the renderer holds 7 of, about 323 MB in all at 1024 px: a bitmap that only
    // the provider holds goes, on screen too, oldest first, before any whole tile, since it is shaded again from the raster
    // in memory, while a raster let go comes back from disk only when the map asks for its tile.
    let panned = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: panned.directory) }
    let thirty = (0..<30).map { key(panned, $0) }
    let pannedRendererHolds = Set(thirty.prefix(7))
    let offScreen = Set((100..<110).map { key(panned, $0) })
    let pannedView = viewOfRow(panned, 0..<30)
    await panned.provider.setVisibleKeysSource { pannedRendererHolds }
    await panned.provider.setVisibleViewSource { pannedView }
    for dx in 100..<110 { await load(panned, dx, pixels: 1024) }
    for dx in 0..<30 { await load(panned, dx, pixels: 1024) }
    let pannedHeld = await panned.provider.cachedTileKeys()
    let pannedShaded = await panned.provider.renderedTileKeys()
    let pannedBytes = await panned.provider.memoryCacheSize()
    let pannedOrder = await panned.provider.bitmapOrder()
    check("tiles off the screen keep their rasters while tiles on it hold bitmaps only the provider holds: those go, oldest first, before any whole tile, and all 40 are held within 256 MB",
          offScreen.isSubset(of: pannedHeld) && pannedHeld.count == 40 && pannedBytes <= budget
            && pannedShaded.isDisjoint(with: offScreen) && pannedRendererHolds.isSubset(of: pannedShaded)
            && !pannedShaded.contains(thirty[7]) && pannedShaded.contains(thirty[29]),
          "holds \(pannedHeld.intersection(offScreen).count) of the 10 off the screen, \(pannedHeld.count) in all, \(megabytes(pannedBytes)); \(pannedShaded.count) shaded, \(pannedShaded.intersection(offScreen).count) of them off the screen, \(pannedShaded.intersection(pannedRendererHolds).count) of the 7 the renderer holds, the oldest of the rest on it \(pannedShaded.contains(thirty[7])), the newest \(pannedShaded.contains(thirty[29]))")
    check("and its record of the tiles holding bitmaps, oldest first, stays in step with them through the shedding",
          Set(pannedOrder) == pannedShaded && pannedOrder.count == pannedShaded.count,
          "\(pannedOrder.count) recorded, \(Set(pannedOrder).count) distinct; \(pannedShaded.count) shaded")

    // The same, with the renderer holding all 30 it draws. Their bitmaps are its own images: dropping the provider's hold
    // on them frees nothing while it draws them, and counted as freed, the provider would keep that much more raster
    // besides. So they stay, counted, and the oldest tiles off the screen go whole instead.
    let shared = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: shared.directory) }
    let sharedThirty = (0..<30).map { key(shared, $0) }
    let sharedOnScreen = Set(sharedThirty)
    let sharedView = viewOfRow(shared, 0..<30)
    await shared.provider.setVisibleKeysSource { sharedOnScreen }
    await shared.provider.setVisibleViewSource { sharedView }
    for dx in 100..<110 { await load(shared, dx, pixels: 1024) }
    for dx in 0..<30 { await load(shared, dx, pixels: 1024) }
    let sharedHeld = await shared.provider.cachedTileKeys()
    let sharedShaded = await shared.provider.renderedTileKeys()
    let sharedBytes = await shared.provider.memoryCacheSize()
    check("a bitmap the renderer is drawing is not shed, since that frees nothing: the 30 keep theirs, counted within 256 MB, and the oldest tiles off the screen go whole",
          sharedOnScreen.isSubset(of: sharedHeld) && sharedOnScreen.isSubset(of: sharedShaded) && sharedBytes <= budget
            && !sharedHeld.contains(key(shared, 100)) && sharedHeld.contains(key(shared, 109)),
          "holds \(sharedHeld.intersection(sharedOnScreen).count) of the 30, \(sharedShaded.intersection(sharedOnScreen).count) of them shaded, \(megabytes(sharedBytes)); the oldest off the screen held \(sharedHeld.contains(key(shared, 100))), the newest \(sharedHeld.contains(key(shared, 109)))")

    // Through the renderer, in the count regime the iPad's GPU shading is in (its 160 tiles bind long before 256 MB): the
    // map draws 25 tiles, is panned well away and back, and MapKit draws the view again from its own layer, asking for no
    // tile. The renderer let the images go at the pan and holds none of them. Then 170 tiles load elsewhere.
    let drawn = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    defer { try? FileManager.default.removeItem(at: drawn.directory) }
    let renderer = TerrainTileOverlayRenderer(tileOverlay: TerrainTileOverlay(provider: drawn.provider))
    func path(_ dx: Int, _ dy: Int) -> MKTileOverlayPath {
        MKTileOverlayPath(x: drawn.x + dx, y: drawn.y + dy, z: drawn.z, contentScaleFactor: 1)
    }
    let block = Set((-2...2).flatMap { dy in (-2...2).map { dx in TerrainTileOverlayRenderer.key(path(dx, dy)) } })
    let blockRect = TerrainTileOverlay.mapRect(for: path(-2, -2)).union(TerrainTileOverlay.mapRect(for: path(2, 2)))
    let side = TerrainTileOverlay.mapRect(for: path(0, 0)).width
    // The screen: the middle nine, just inside their edges. The ring of 16 around them lies within the quarter of a
    // viewport past the screen the renderer keeps drawn for a pan back.
    let screen = TerrainTileOverlay.mapRect(for: path(-1, -1)).union(TerrainTileOverlay.mapRect(for: path(1, 1)))
        .insetBy(dx: side * 0.01, dy: side * 0.01)
    // The four tiles a level finer than the centre one, loaded first, as before a zoom-out: under the screen, but at a level
    // the map no longer draws, so not spared.
    let finer = (0...1).flatMap { dy in (0...1).map { dx in
        MKTileOverlayPath(x: 2 * drawn.x + dx, y: 2 * drawn.y + dy, z: drawn.z + 1, contentScaleFactor: 1) } }
    for child in finer {
        _ = await drawn.provider.tileImage(
            x: child.x, y: child.y, z: child.z, region: TerrainTileOverlay.region(for: child), pixels: 512)
    }
    let finerKeys = Set(finer.map(TerrainTileOverlayRenderer.key))
    let drawDeadline = Date().addingTimeInterval(20)
    // 0.5 screen points per map point draws z19 with 256-point tiles.
    while Date() < drawDeadline, !block.isSubset(of: Set(renderer.store.imageKeys())) {
        _ = renderer.canDraw(blockRect, zoomScale: 0.5)
        try? await Task.sleep(for: .milliseconds(10))
    }
    let drewAll = block.isSubset(of: Set(renderer.store.imageKeys()))
    renderer.cullTiles(outsideVisible: screen)
    renderer.cullTiles(outsideVisible: TerrainTileOverlay.mapRect(for: path(50, 0)))
    renderer.cullTiles(outsideVisible: screen)
    let rendererHolds = renderer.visibleTileKeys(), view = renderer.currentView()
    check("after a pan away and back the renderer holds none of the 25 tiles it drew, while where the map looks takes in all of them, and not the next tile out or a finer one under the screen",
          drewAll && rendererHolds.isEmpty && renderer.store.imageKeys().isEmpty
            && block.allSatisfy { view?.keepsDrawn($0) == true }
            && view?.keepsDrawn(TerrainTileOverlayRenderer.key(path(3, 0))) == false
            && finerKeys.allSatisfy { view?.keepsDrawn($0) == false },
          "drew all 25 \(drewAll); holds \(rendererHolds.count) on screen, \(renderer.store.imageKeys().count) in all; view takes in \(block.filter { view?.keepsDrawn($0) == true }.count) of the 25, the next tile out \(view?.keepsDrawn(TerrainTileOverlayRenderer.key(path(3, 0))) == true), \(finerKeys.filter { view?.keepsDrawn($0) == true }.count) of the 4 finer")
    for dx in 10..<180 { await drawn.image(dx: dx, dy: 0) }
    let drawnHeld = await drawn.provider.cachedTileKeys()
    let drawnInspection = await drawn.provider.inspectSpot(at: drawn.region(dx: 1, dy: 1).center)
    let drawnEdge = await drawn.provider.elevation(at: drawn.region(dx: -2, dy: 2).center)
    check("then 170 tiles loaded elsewhere leave the provider holding all 25 the map still draws, the renderer holding none, and not the finer four: spot inspection answers on the screen, and a reading just past it",
          block.isSubset(of: drawnHeld) && drawnHeld.isDisjoint(with: finerKeys) && drawnHeld.count == 160
            && drawnInspection != nil && drawnEdge != nil,
          "holds \(drawnHeld.intersection(block).count) of the 25, \(drawnHeld.intersection(finerKeys).count) of the finer 4, \(drawnHeld.count) in all; inspection \(drawnInspection != nil); reading past the screen \(drawnEdge.map { "\($0) m" } ?? "none")")
    withExtendedLifetime(renderer) {}
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
