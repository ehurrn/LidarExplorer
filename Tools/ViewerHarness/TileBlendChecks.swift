//
//  TileBlendChecks.swift
//  ViewerHarness
//
//  Compositing one micro-topography product over another on the live tile path: that a tile shaded with a blend is
//  what the CPU reference makes of the two products' own tiles, that the settings and the viewer model carry it, that
//  the tile reads far enough beyond its edge for both products, and that it stays inside a frame's budget.
//

import CoreGraphics
import CoreLocation
import Foundation
import simd

@MainActor
func runTileBlendChecks() async {
    print("\n=== Layer blending on the tile path ===")
    checkBlendVocabulary()
    await checkBlendModel()
    guard await MetalTerrainPipelineActor().isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    await checkTileBlendParity()
    await checkTileBlendControls()
    await checkTileBlendOverlays()
    await checkTileBlendRelativeElevation()
    await checkTileBlendBudget()
}

// MARK: - Helpers

private func shadingSettings(
    _ style: ReliefStyle, blend: LayerBlend? = nil, azimuth: Double = 315, grazing: Double = 10,
    contours: ContourInterval = .off
) -> TerrainStyleSettings {
    var settings = TerrainStyleSettings()
    settings.style = style
    settings.blend = blend
    settings.azimuthDegrees = azimuth
    settings.rakingAltitudeDegrees = grazing
    settings.contourInterval = contours
    return settings
}

private func shade(_ scene: SyntheticTileScene, _ settings: TerrainStyleSettings) async -> TilePixels? {
    await scene.provider.update(settings)
    guard let image = await scene.image(), let rgba = rgbaBytes(image) else { return nil }
    return TilePixels(width: image.width, height: image.height, rgba: rgba)
}

/// What blending two tiles' own pictures, pixel by pixel, gives by the CPU reference.
private func referenceBlend(base: TilePixels, layer: TilePixels, mode: RasterBlendMode, opacity: Float) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: base.rgba.count)
    for i in stride(from: 0, to: base.rgba.count, by: 4) {
        func unit(_ tile: TilePixels) -> SIMD4<Float> {
            SIMD4(Float(tile.rgba[i]), Float(tile.rgba[i + 1]), Float(tile.rgba[i + 2]), Float(tile.rgba[i + 3])) / 255
        }
        let e = MicroTopographyReference.blend(base: unit(base), modulation: unit(layer), mode: mode, opacity: opacity) * 255
        for (channel, value) in [e.x, e.y, e.z, e.w].enumerated() { out[i + channel] = UInt8(clamping: Int(value.rounded())) }
    }
    return out
}

private func worstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? Int.max
}

private func changedPixels(_ a: TilePixels, _ b: TilePixels) -> Int {
    guard a.rgba.count == b.rgba.count else { return -1 }
    var changed = 0
    for i in stride(from: 0, to: a.rgba.count, by: 4) where a.rgba[i..<i + 4] != b.rgba[i..<i + 4] { changed += 1 }
    return changed
}

// MARK: - K1. Names, options and reach

@MainActor
private func checkBlendVocabulary() {
    print("\n--- K1. names, options and reach ---")
    let products = MicroTopographyProduct.allCases.map(\.displayName)
    let modes = RasterBlendMode.allCases.map(\.displayName)
    check("every product and every blend mode has a name of its own, and a product that is a style is named as the style is",
          products.allSatisfy { !$0.isEmpty } && Set(products).count == products.count
          && modes.allSatisfy { !$0.isEmpty } && Set(modes).count == modes.count
          && ReliefStyle.allCases.allSatisfy { style in style.microTopographyProduct.map { $0.displayName == style.displayName } ?? true },
          "\(products) \(modes)")

    var settings = TerrainStyleSettings()
    settings.azimuthDegrees = 200
    settings.rakingAltitudeDegrees = 8
    let defaults = MicroTopographyOptions()
    let both = settings.analysisOptions(forAll: [.skyView, .rakingLight])
    let pair = settings.analysisOptions(forAll: [.directionalOcclusion, .rakingLight])
    let neither = settings.analysisOptions(forAll: [.skyView, .localRelief])
    check("one pass over two products runs with the options of both: the sun lands on a low-sun layer whichever place it has",
          both.sunAzimuthDegrees == 200 && both.sunAltitudeDegrees == 8
          && pair.sunAzimuthDegrees == 200 && pair.directionalOcclusionAzimuthDegrees == 200
          && pair.directionalOcclusionAltitudeDegrees == 8
          && neither.sunAzimuthDegrees == defaults.sunAzimuthDegrees && neither == settings.microTopographyOptions
          && settings.analysisOptions(for: .rakingLight) == settings.analysisOptions(forAll: [.rakingLight]),
          "\(both.sunAzimuthDegrees) \(both.sunAltitudeDegrees) \(pair.directionalOcclusionAzimuthDegrees)")

    let options = MicroTopographyOptions()
    let overlays = CompositeOverlays()
    func radius(_ product: MicroTopographyProduct) -> Float {
        TerrainTileProvider.neighbourhoodRadius(product: product, options: options, overlays: overlays)
    }
    let over = TerrainTileProvider.neighbourhoodRadius(products: [.rakingLight, .skyView], options: options, overlays: overlays)
    let wider = TerrainTileProvider.neighbourhoodRadius(products: [.localRelief, .skyView, .habitation], options: options, overlays: overlays)
    check("a pass over two products reads as far beyond a tile's edge as the farther-reaching of them",
          radius(.skyView) > 0 && over == radius(.skyView)
          && wider == max(radius(.localRelief), radius(.skyView), radius(.habitation))
          && TerrainTileProvider.neighbourhoodRadius(products: [.rakingLight], options: options, overlays: overlays) == 0,
          "\(over) vs sky-view \(radius(.skyView)); \(wider)")

    var blended = TerrainStyleSettings()
    blended.style = .rakingLight
    blended.blend = LayerBlend(product: .skyView, mode: .softLight, opacity: 0.6)
    var noWeight = blended
    noWeight.blend?.opacity = 0
    var itself = blended
    itself.blend?.product = .rakingLight
    var plainStyle = blended
    plainStyle.style = .hillshade
    var nan = blended
    nan.blend?.opacity = .nan
    check("the blend that counts is one over a micro-topography style, with some weight, of a product that is not the style's own",
          blended.activeBlend?.base == .rakingLight && blended.activeBlend?.layer == blended.blend
          && noWeight.activeBlend == nil && itself.activeBlend == nil && plainStyle.activeBlend == nil && nan.activeBlend == nil
          && TerrainStyleSettings().activeBlend == nil)
}

// MARK: - K2. A blended tile is the blend of the two tiles

@MainActor
private func checkTileBlendParity() async {
    print("\n--- K2. a blended tile against the blend of the two tiles ---")

    typealias Case = (base: ReliefStyle, layer: MicroTopographyProduct, layerStyle: ReliefStyle, mode: RasterBlendMode, opacity: Float)
    // The sun is moved off its default so a layer that takes its light from the settings shows whether it did.
    func compare(_ c: Case, on scene: SyntheticTileScene, where place: String) async {
        let base = await shade(scene, shadingSettings(c.base, azimuth: 135, grazing: 6))
        let layer = await shade(scene, shadingSettings(c.layerStyle, azimuth: 135, grazing: 6))
        let blended = await shade(scene, shadingSettings(
            c.base, blend: LayerBlend(product: c.layer, mode: c.mode, opacity: c.opacity), azimuth: 135, grazing: 6))
        let name = "\(c.layer.displayName) over \(c.base.displayName), \(c.mode.displayName) at \(Int(c.opacity * 100)) %\(place)"
        guard let base, let layer, let blended, base.rgba.count == layer.rgba.count, blended.rgba.count == base.rgba.count else {
            check("\(name) is what the CPU reference makes of the two tiles' own pictures", false, "a tile did not shade")
            return
        }
        let expected = referenceBlend(base: base, layer: layer, mode: c.mode, opacity: c.opacity)
        let worst = worstDifference(expected, blended.rgba)
        let changed = changedPixels(base, blended)
        check("\(name) is what the CPU reference makes of the two tiles' own pictures, to one level on every pixel, edges included",
              blended.width == base.width && worst <= 1 && changed > 50,
              "worst \(worst), \(changed) of \(base.width * base.height) pixels differ from the base, \(blended.width) px wide")
    }

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    let cases: [Case] = [
        (.rakingLight, .skyView, .skyView, .multiply, 0.7),
        (.skyView, .rakingLight, .rakingLight, .softLight, 0.8),
        (.localRelief, .directionalOcclusion, .directionalOcclusion, .overlay, 0.5),
        (.rrim, .negativeOpenness, .negativeOpenness, .screen, 0.9),
    ]
    for c in cases { await compare(c, on: scene, where: "") }

    // A mound across the tile's east edge: sky-view at that edge depends on ground beyond it, which the tile's skirt
    // has to reach for the layer though raking light, the base, needs none.
    let seam = makeSyntheticScene(moundOffsetFromSeamMeters: 4)
    await seam.loadNeighbourhood()
    await compare(cases[0], on: seam, where: ", with the mound across the tile's edge")
    await compare(cases[3], on: seam, where: ", with the mound across the tile's edge")
    try? FileManager.default.removeItem(at: scene.directory)
    try? FileManager.default.removeItem(at: seam.directory)
}

// MARK: - K3. Controls

@MainActor
private func checkTileBlendControls() async {
    print("\n--- K3. weight, mode and what is ignored ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    func over(_ mode: RasterBlendMode, _ opacity: Float, base: ReliefStyle = .rakingLight) -> TerrainStyleSettings {
        shadingSettings(base, blend: LayerBlend(product: .skyView, mode: mode, opacity: opacity))
    }

    let plain = await shade(scene, shadingSettings(.rakingLight))
    let zero = await shade(scene, over(.multiply, 0))
    check("a layer at no weight leaves the tile exactly as it was", plain != nil && zero == plain)

    var means: [Double] = []
    for weight: Float in [0.25, 0.5, 1] {
        if let tile = await shade(scene, over(.multiply, weight)) { means.append(tile.meanRed()) }
    }
    if let plain, means.count == 3 {
        check("more weight darkens more, under multiply with the sky-view layer: 0, 25, 50 and 100 %",
              plain.meanRed() > means[0] && means[0] > means[1] && means[1] > means[2],
              "\(plain.meanRed()) > \(means)")
    } else {
        check("more weight darkens more, under multiply", false, "a tile did not shade")
    }

    var tiles: [RasterBlendMode: TilePixels] = [:]
    for mode in RasterBlendMode.allCases { tiles[mode] = await shade(scene, over(mode, 1)) }
    let distinct = Set(tiles.values.map(\.rgba)).count
    if let plain, let multiply = tiles[.multiply], let screen = tiles[.screen] {
        check("the four blend modes give four different pictures, multiply darker than the base and screen lighter",
              tiles.count == 4 && distinct == 4 && multiply.meanRed() < plain.meanRed() && screen.meanRed() > plain.meanRed(),
              "\(distinct) distinct; base \(plain.meanRed()), multiply \(multiply.meanRed()), screen \(screen.meanRed())")
    } else {
        check("the four blend modes give four different pictures", false, "a tile did not shade")
    }

    let hillshade = await shade(scene, shadingSettings(.hillshade))
    let hillshadeBlended = await shade(scene, over(.multiply, 1, base: .hillshade))
    check("a style that is not a micro-topography product ignores a blend, and draws as it would without one",
          hillshade != nil && hillshadeBlended == hillshade)
    let itself = await shade(scene, shadingSettings(.rakingLight, blend: LayerBlend(product: .rakingLight, mode: .multiply, opacity: 1)))
    check("a layer that is the style itself is ignored, not multiplied into the style", plain != nil && itself == plain)

    // The blend is part of the shading settings: changing any part of it is a change the tiles must redraw for.
    let a = shadingSettings(.rakingLight)
    var b = a
    b.blend = LayerBlend(product: .skyView, mode: .multiply, opacity: 0.5)
    var c = b
    c.blend?.opacity = 0.6
    var d = b
    d.blend?.mode = .screen
    var e = b
    e.blend?.product = .habitation
    var changes: [Bool] = []
    for settings in [a, b, b, c, d, e, e] { changes.append(await scene.provider.update(settings)) }
    check("the provider redraws when the layer, its mode or its weight changes, and not when nothing has",
          changes == [true, true, false, true, true, true, false], "\(changes)")
    let tileB = await shade(scene, b), tileC = await shade(scene, c)
    check("and the tile it draws after such a change shows it", tileB != nil && tileC != nil && tileB != tileC)
}

// MARK: - K4. Overlays

@MainActor
private func checkTileBlendOverlays() async {
    print("\n--- K4. contours over a blended tile ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    let layer = LayerBlend(product: .skyView, mode: .softLight, opacity: 1)
    let lined = await shade(scene, shadingSettings(.rakingLight, contours: .halfMeter))
    let linedZero = await shade(scene, shadingSettings(
        .rakingLight, blend: LayerBlend(product: .skyView, mode: .softLight, opacity: 0), contours: .halfMeter))
    let linedBlended = await shade(scene, shadingSettings(.rakingLight, blend: layer, contours: .halfMeter))
    let unlinedBlended = await shade(scene, shadingSettings(.rakingLight, blend: layer))
    check("with contours on, a blended tile is drawn at display resolution like any other with overlays: 512 px at z19",
          linedBlended?.width == 512 && lined?.width == 512 && unlinedBlended?.width == 64,
          "\(String(describing: linedBlended?.width)) \(String(describing: lined?.width)) \(String(describing: unlinedBlended?.width))")
    check("a layer at no weight leaves a tile with contours exactly as it was", lined != nil && linedZero == lined)
    check("a layer at full weight changes a tile with contours, and the contours stay",
          lined != nil && linedBlended != nil && linedBlended != lined && linedBlended != unlinedBlended)
}

// MARK: - K5. Relative elevation

@MainActor
private func checkTileBlendRelativeElevation() async {
    print("\n--- K5. relative elevation as the base or the layer ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    // No thalweg is drawn, so each falls back to a flat water plane at the tile's lowest ground.
    let raking = await shade(scene, shadingSettings(.rakingLight))
    let rem = await shade(scene, shadingSettings(.relativeElevation))
    let remOver = await shade(scene, shadingSettings(
        .rakingLight, blend: LayerBlend(product: .relativeElevation, mode: .softLight, opacity: 0.7)))
    if let raking, let rem, let remOver {
        let expected = referenceBlend(base: raking, layer: rem, mode: .softLight, opacity: 0.7)
        check("relative elevation as the layer, with no river drawn, is the blend of the two tiles: the flat-plane fallback reaches the composite",
              worstDifference(expected, remOver.rgba) <= 1 && changedPixels(raking, remOver) > 50,
              "worst \(worstDifference(expected, remOver.rgba)), \(changedPixels(raking, remOver)) changed")
    } else {
        check("relative elevation as the layer is the blend of the two tiles", false, "a tile did not shade")
    }

    let sky = await shade(scene, shadingSettings(.skyView))
    let remBase = await shade(scene, shadingSettings(
        .relativeElevation, blend: LayerBlend(product: .skyView, mode: .multiply, opacity: 0.8)))
    if let sky, let rem, let remBase {
        let expected = referenceBlend(base: rem, layer: sky, mode: .multiply, opacity: 0.8)
        check("relative elevation as the base, with a layer over it, is the blend of the two tiles too",
              worstDifference(expected, remBase.rgba) <= 1, "worst \(worstDifference(expected, remBase.rgba))")
    } else {
        check("relative elevation as the base is the blend of the two tiles", false, "a tile did not shade")
    }
}

// MARK: - K6. Budget

@MainActor
private func checkTileBlendBudget() async {
    print("\n--- K6. a blended tile's budget (warm, ms) ---")
    for z in [18, 19, 20] {
        let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30, z: z)
        await scene.loadNeighbourhood()
        var settings = shadingSettings(.rakingLight, blend: LayerBlend(product: .skyView, mode: .softLight, opacity: 0.7))
        await scene.provider.update(settings)
        _ = await scene.image()
        settings.azimuthDegrees += 1
        await scene.provider.update(settings)
        let started = Date()
        let image = await scene.image()
        let milliseconds = Date().timeIntervalSince(started) * 1000
        print(String(format: "        z%d raking light + sky-view %.1f ms", z, milliseconds))
        check("z\(z) a raking-light tile with a sky-view layer renders within 30 ms warm", image != nil && milliseconds < 30,
              String(format: "%.1f ms", milliseconds))
        try? FileManager.default.removeItem(at: scene.directory)
    }
}

// MARK: - K7. The viewer model

@MainActor
private func checkBlendModel() async {
    print("\n--- K7. the viewer model ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.style = .rakingLight
    model.blendLayer = .skyView
    model.blendMode = .overlay
    model.blendOpacity = 0.4
    try? await Task.sleep(for: .milliseconds(120))
    let expected = LayerBlend(product: .skyView, mode: .overlay, opacity: 0.4)
    let shown = await scene.provider.currentSettings().blend
    check("the layer, its mode and its weight reach the provider while a micro-topography style is shown",
          shown == expected && model.activeBlend == expected && model.canBlend, "\(String(describing: shown))")

    model.style = .hillshade
    try? await Task.sleep(for: .milliseconds(120))
    let hidden = await scene.provider.currentSettings().blend
    check("on a style that cannot have one, no blend is sent, none is in effect, and none is offered",
          hidden == nil && model.activeBlend == nil && !model.canBlend && model.blendChoices.isEmpty
          && model.blendLayer == .skyView, "\(String(describing: hidden))")

    model.style = .skyView
    try? await Task.sleep(for: .milliseconds(120))
    let ownLayer = await scene.provider.currentSettings().blend
    check("a layer that is the style itself is not sent, and is not among the choices",
          ownLayer == nil && !model.blendChoices.contains(.skyView) && model.blendChoices.contains(.rakingLight))

    model.style = .rakingLight
    try? await Task.sleep(for: .milliseconds(120))
    let remembered = await scene.provider.currentSettings().blend
    check("coming back to a style that can have one restores the layer that was chosen",
          remembered == expected && model.blendChoices.count == MicroTopographyProduct.allCases.count - 1
          && model.blendChoices.contains(.habitation) && !model.blendChoices.contains(.rakingLight),
          "\(String(describing: remembered)), \(model.blendChoices.count) choices")

    check("a blend counts as custom shading", model.hasCustomShading)
    model.resetShading()
    try? await Task.sleep(for: .milliseconds(120))
    let reset = await scene.provider.currentSettings().blend
    check("resetting the shading takes the layer off and restores the mode and weight",
          model.blendLayer == nil && model.blendMode == TerrainViewerModel.Defaults.blendMode
          && model.blendOpacity == TerrainViewerModel.Defaults.blendOpacity && reset == nil && !model.hasCustomShading,
          "\(String(describing: reset))")
    try? FileManager.default.removeItem(at: scene.directory)
}
