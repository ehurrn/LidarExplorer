//
//  LayerBlendChecks.swift
//  ViewerHarness
//
//  Compositing one micro-topography product over another: the blend formulas against hand-worked values, the
//  GPU kernel against the CPU reference, the archaeological case the feature exists for, and the pool.
//

import CoreGraphics
import Foundation
import simd

@MainActor
func runLayerBlendChecks() async {
    print("\n=== Layer blending ===")
    checkBlendFormulas()
    let pipeline = MetalTerrainPipelineActor()
    guard await pipeline.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    await checkBlendParity(pipeline)
    await checkBlendOnEarthwork(pipeline)
    await checkBlendOpacityAndGuards(pipeline)
    await checkBlendPooling(pipeline)
    await checkTranslucentLayers(pipeline)
}

/// A rolling surface with noise, so both layers take a wide range of values everywhere.
private func roughScene() -> ElevationGrid {
    sceneGrid(width: 96, height: 96, gsd: 1.0) { x, y in
        100 + 1.2 * sin(Float(x) * 0.25) * cos(Float(y) * 0.19) + 0.3 * hashNoise(x, y)
    }
}

/// A flat plain with a straight ditch, 3 m wide and 3 m deep, down the middle.
private func ditchScene() -> ElevationGrid {
    sceneGrid(width: 120, height: 120, gsd: 1.0) { x, y in
        (x >= 59 && x <= 61 && y >= 10 && y <= 110) ? 97 : 100
    }
}

private func channels(_ p: SIMD4<UInt8>) -> [Int] { [Int(p.x), Int(p.y), Int(p.z), Int(p.w)] }

// MARK: - Formulas

@MainActor
private func checkBlendFormulas() {
    print("\n--- L1. blend formulas ---")
    func blend(_ base: Float, _ modulation: Float, _ mode: RasterBlendMode, _ opacity: Float = 1) -> Float {
        MicroTopographyReference.blend(base: base, modulation: modulation, mode: mode, opacity: opacity)
    }
    func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-5 }

    check("multiply is the product: white leaves the base, black takes it to black",
          near(blend(0.5, 0.5, .multiply), 0.25) && near(blend(0.8, 1, .multiply), 0.8) && near(blend(0.8, 0, .multiply), 0),
          "\(blend(0.5, 0.5, .multiply)) \(blend(0.8, 1, .multiply)) \(blend(0.8, 0, .multiply))")
    check("screen lightens: black leaves the base, white takes it to white",
          near(blend(0.5, 0.5, .screen), 0.75) && near(blend(0.6, 0, .screen), 0.6) && near(blend(0.6, 1, .screen), 1),
          "\(blend(0.5, 0.5, .screen)) \(blend(0.6, 0, .screen)) \(blend(0.6, 1, .screen))")
    check("overlay multiplies the shadows and screens the highlights, pivoting on the base's mid-grey",
          near(blend(0.25, 0.5, .overlay), 0.25) && near(blend(0.75, 0.5, .overlay), 0.75)
          && near(blend(0.25, 1, .overlay), 0.5) && near(blend(0.75, 0, .overlay), 0.5),
          "\(blend(0.25, 0.5, .overlay)) \(blend(0.75, 0.5, .overlay)) \(blend(0.25, 1, .overlay)) \(blend(0.75, 0, .overlay))")
    check("soft light follows the W3C curve: mid-grey changes nothing, white and black push the base up and down",
          near(blend(0.5, 0.5, .softLight), 0.5) && near(blend(0.5, 1, .softLight), 0.707107)
          && near(blend(0.5, 0, .softLight), 0.25) && near(blend(0.1, 1, .softLight), 0.296)
          && near(blend(0.9, 0, .softLight), 0.81),
          "\(blend(0.5, 0.5, .softLight)) \(blend(0.5, 1, .softLight)) \(blend(0.5, 0, .softLight)) \(blend(0.1, 1, .softLight)) \(blend(0.9, 0, .softLight))")
    check("opacity mixes linearly from the base (0) to the full blend (1)",
          near(blend(0.8, 0.5, .multiply, 0), 0.8) && near(blend(0.8, 0.5, .multiply, 1), 0.4)
          && near(blend(0.8, 0.5, .multiply, 0.5), 0.6),
          "\(blend(0.8, 0.5, .multiply, 0)) \(blend(0.8, 0.5, .multiply, 1)) \(blend(0.8, 0.5, .multiply, 0.5))")
    check("an out-of-range opacity is clamped and a NaN one counts as none",
          near(blend(0.8, 0.5, .multiply, 2), 0.4) && near(blend(0.8, 0.5, .multiply, -1), 0.8)
          && near(blend(0.8, 0.5, .multiply, .nan), 0.8),
          "\(blend(0.8, 0.5, .multiply, 2)) \(blend(0.8, 0.5, .multiply, -1)) \(blend(0.8, 0.5, .multiply, .nan))")
}

// MARK: - GPU against the CPU reference

@MainActor
private func checkBlendParity(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- L2. GPU kernel against the CPU reference ---")
    let raster = ElevationRaster(grid: roughScene())
    let options = MicroTopographyOptions()
    guard let base = await pipeline.render(.rakingLight, raster: raster, options: options),
          let modulation = await pipeline.render(.skyView, raster: raster, options: options)
    else {
        check("the base and modulation layers render", false, "nil result")
        return
    }
    let width = base.display.width, height = base.display.height

    for mode in RasterBlendMode.allCases {
        for opacity: Float in [1, 0.5] {
            guard let composite = await pipeline.renderComposite(
                base: .rakingLight, modulation: .skyView, blendMode: mode, opacity: opacity,
                raster: raster, options: options)
            else {
                check("\(mode) at \(Int(opacity * 100)) % composites", false, "nil result")
                continue
            }
            var worst = 0, compared = 0, changed = 0
            var alphaKept = true
            for y in 0..<height {
                for x in 0..<width {
                    let b = base.display.pixel(x: x, y: y), m = modulation.display.pixel(x: x, y: y)
                    let got = composite.display.pixel(x: x, y: y)
                    // The whole pixel, alpha included: the outer ring of a derivative product is transparent, and a
                    // transparent base must stay so however opaque the layer above it is.
                    func unit(_ p: SIMD4<UInt8>) -> SIMD4<Float> { SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w)) / 255 }
                    let e = MicroTopographyReference.blend(base: unit(b), modulation: unit(m), mode: mode, opacity: opacity) * 255
                    let expected = [e.x, e.y, e.z, e.w].map { Int($0.rounded()) }
                    for c in 0..<4 { worst = max(worst, abs(expected[c] - channels(got)[c])) }
                    if got.w != b.w { alphaKept = false }
                    if channels(got)[0..<3] != channels(b)[0..<3] { changed += 1 }
                    compared += 1
                }
            }
            check("\(mode) at \(Int(opacity * 100)) % matches the CPU reference to one level on all \(compared) pixels",
                  compared == width * height && compared > 9_000 && worst <= 1 && alphaKept && changed > 3_000,
                  "worst \(worst), alpha kept \(alphaKept), \(changed) pixels differ from the base")
        }
    }

    // The blit path (the Simulator's) runs the same kernel through private textures.
    let blit = MetalTerrainPipelineActor(surfaceMode: .blit)
    if let linear = await pipeline.renderComposite(
        base: .rakingLight, modulation: .skyView, blendMode: .softLight, opacity: 0.8, raster: raster, options: options),
       let viaBlit = await blit.renderComposite(
        base: .rakingLight, modulation: .skyView, blendMode: .softLight, opacity: 0.8, raster: raster, options: options) {
        var worst = 0
        for y in 0..<linear.display.height {
            for x in 0..<linear.display.width {
                let a = channels(linear.display.pixel(x: x, y: y)), b = channels(viaBlit.display.pixel(x: x, y: y))
                for c in 0..<4 { worst = max(worst, abs(a[c] - b[c])) }
            }
        }
        check("the blit path composites the same pixels as the linear path", worst <= 1 && linear.display.width == 96,
              "worst \(worst)")
    } else {
        check("the blit path composites the same pixels as the linear path", false, "nil result")
    }
}

// MARK: - The archaeological case

@MainActor
private func checkBlendOnEarthwork(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- L3. sky-view over raking light on a ditch ---")
    let raster = ElevationRaster(grid: ditchScene())
    var options = MicroTopographyOptions()
    options.sunAzimuthDegrees = 45
    options.sunAltitudeDegrees = 30
    guard let raking = await pipeline.render(.rakingLight, raster: raster, options: options),
          let sky = await pipeline.render(.skyView, raster: raster, options: options),
          let composite = await pipeline.renderComposite(
            base: .rakingLight, modulation: .skyView, blendMode: .multiply, opacity: 1,
            raster: raster, options: options)
    else {
        check("the ditch scene composites", false, "nil result")
        return
    }
    let floorBase = Int(raking.display.pixel(x: 60, y: 60).x)
    let floorBlend = Int(composite.display.pixel(x: 60, y: 60).x)
    let plateauBase = Int(raking.display.pixel(x: 20, y: 60).x)
    let plateauBlend = Int(composite.display.pixel(x: 20, y: 60).x)
    let skyFloor = Int(sky.display.pixel(x: 60, y: 60).x), skyPlateau = Int(sky.display.pixel(x: 20, y: 60).x)
    print("        raking floor \(floorBase) plateau \(plateauBase); sky floor \(skyFloor) plateau \(skyPlateau); blended floor \(floorBlend) plateau \(plateauBlend)")
    check("multiplying by sky-view darkens the ditch bottom by more than 30 % against raking light alone",
          floorBase > 0 && Double(floorBase - floorBlend) / Double(floorBase) > 0.30,
          "floor \(floorBase) -> \(floorBlend)")
    check("the flat plateau keeps the base illumination",
          plateauBase > 0 && abs(plateauBlend - plateauBase) <= 2, "plateau \(plateauBase) -> \(plateauBlend)")
}

// MARK: - Opacity and guards

@MainActor
private func checkBlendOpacityAndGuards(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- L4. opacity and guards ---")
    let raster = ElevationRaster(grid: roughScene())
    let options = MicroTopographyOptions()
    func composite(_ opacity: Float, mode: RasterBlendMode = .multiply) async -> MicroTopographyResult? {
        await pipeline.renderComposite(
            base: .rakingLight, modulation: .skyView, blendMode: mode, opacity: opacity, raster: raster, options: options)
    }
    func identical(_ a: MicroTopographyResult, _ b: MicroTopographyResult) -> Bool {
        guard a.display.width == b.display.width, a.display.height == b.display.height else { return false }
        for y in 0..<a.display.height {
            for x in 0..<a.display.width where a.display.pixel(x: x, y: y) != b.display.pixel(x: x, y: y) { return false }
        }
        return true
    }

    guard let base = await pipeline.render(.rakingLight, raster: raster, options: options),
          let none = await composite(0), let full = await composite(1)
    else {
        check("opacity composites render", false, "nil result")
        return
    }
    check("zero opacity reproduces the base layer bit for bit, for every blend mode", await {
        for mode in RasterBlendMode.allCases {
            guard let zero = await composite(0, mode: mode), identical(zero, base) else { return false }
        }
        return true
    }())
    check("full opacity really changes the picture, so that check is not vacuous", !identical(full, base) && !identical(full, none))
    if let over = await composite(2), let under = await composite(-1), let unknown = await composite(.nan) {
        check("opacity above 1 acts as 1, below 0 as 0, and NaN as 0",
              identical(over, full) && identical(under, base) && identical(unknown, base))
    } else {
        check("opacity above 1 acts as 1, below 0 as 0, and NaN as 0", false, "nil result")
    }
    check("a layer blended over itself is the layer squared", await {
        guard let same = await pipeline.renderComposite(
            base: .skyView, modulation: .skyView, blendMode: .multiply, opacity: 1, raster: raster, options: options),
              let single = await pipeline.render(.skyView, raster: raster, options: options) else { return false }
        var worst = 0
        for y in 0..<same.display.height {
            for x in 0..<same.display.width {
                let v = Float(single.display.pixel(x: x, y: y).x) / 255
                worst = max(worst, abs(Int((v * v * 255).rounded()) - Int(same.display.pixel(x: x, y: y).x)))
            }
        }
        return worst <= 1
    }())

    let window = DestinationWindow.inset(RasterGeometry(roughScene()), margin: 8)
    if let windowed = await pipeline.renderComposite(
        base: .rakingLight, modulation: .skyView, blendMode: .multiply, opacity: 1,
        raster: raster, window: window, options: options),
       let windowedBase = await pipeline.render(.rakingLight, raster: raster, window: window, options: options),
       let windowedSky = await pipeline.render(.skyView, raster: raster, window: window, options: options) {
        check("a window composites at the window's size",
              windowed.display.width == window.width && windowed.display.height == window.height
              && windowed.scalar.width == window.width && window.width < 96)
        // Both layers must be read from the same window, or the blend pairs the wrong cells.
        var worst = 0, changed = 0
        for y in 0..<window.height {
            for x in 0..<window.width {
                let b = windowedBase.display.pixel(x: x, y: y), m = windowedSky.display.pixel(x: x, y: y)
                let got = windowed.display.pixel(x: x, y: y)
                for c in 0..<3 {
                    let cb = Float([b.x, b.y, b.z][c]) / 255, cs = Float([m.x, m.y, m.z][c]) / 255
                    let v = MicroTopographyReference.blend(base: cb, modulation: cs, mode: .multiply, opacity: 1)
                    worst = max(worst, abs(Int((v * 255).rounded()) - channels(got)[c]))
                }
                if channels(got)[0..<3] != channels(b)[0..<3] { changed += 1 }
            }
        }
        check("a windowed composite blends the same cells of both layers, to one level",
              worst <= 1 && changed > 1_000, "worst \(worst), \(changed) pixels differ from the base")
    } else {
        check("a window composites at the window's size", false, "nil result")
        check("a windowed composite blends the same cells of both layers, to one level", false, "nil result")
    }
    let outside = DestinationWindow(originX: 90, originY: 0, width: 20, height: 20)
    let misfit = await pipeline.renderComposite(
        base: .rakingLight, modulation: .skyView, blendMode: .multiply, opacity: 1,
        raster: raster, window: outside, options: options)
    let noThalweg = await pipeline.renderComposite(
        base: .rakingLight, modulation: .relativeElevation, blendMode: .multiply, opacity: 1,
        raster: raster, options: options)
    check("a window that does not fit the raster, or REM without a thalweg, yields nothing",
          misfit == nil && noThalweg == nil)
}

// MARK: - Pool

@MainActor
private func checkBlendPooling(_ shared: MetalTerrainPipelineActor) async {
    print("\n--- L5. surface pool ---")
    // A pipeline of its own, so nothing but these composites has touched the pool.
    let pipeline = MetalTerrainPipelineActor()
    let raster = ElevationRaster(grid: roughScene())
    func run(_ count: Int) async -> Int {
        var produced = 0
        for _ in 0..<count {
            if await pipeline.renderComposite(
                base: .rakingLight, modulation: .skyView, blendMode: .multiply, opacity: 0.7, raster: raster) != nil {
                produced += 1
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        return produced
    }
    let firstBatch = await run(12)
    let afterTwelve = await pipeline.poolStatistics()
    // Two of a composite's surfaces are its results. The base's display, the modulation's display and scalar
    // are intermediates: unless they come back too, the idle pool holds fewer than five buffers.
    check("dropped composites return every lease, and the intermediates go back to the pool at once",
          firstBatch == 12 && afterTwelve.liveLeases == 0 && afterTwelve.idleBuffers >= 5, "\(firstBatch) made, \(afterTwelve)")
    let secondBatch = await run(12)
    let afterTwentyFour = await pipeline.poolStatistics()
    check("surfaces are reused: twelve more composites grow the idle pool by nothing",
          secondBatch == 12 && afterTwelve.idleBuffers > 0
          && afterTwentyFour.idleBuffers == afterTwelve.idleBuffers && afterTwentyFour.idleTextures == afterTwelve.idleTextures
          && afterTwentyFour.idleBytes <= MetalTerrainPipelineActor.idleByteLimit,
          "\(afterTwelve) -> \(afterTwentyFour)")

    var held: [MicroTopographyResult] = []
    for _ in 0..<3 {
        if let r = await pipeline.renderComposite(
            base: .rakingLight, modulation: .skyView, blendMode: .softLight, opacity: 1, raster: raster) { held.append(r) }
    }
    let busy = await pipeline.poolStatistics()
    check("a held composite keeps two leases, its display and its scalar, and nothing else",
          held.count == 3 && busy.liveLeases == 6, "\(held.count) held, \(busy)")
    held.removeAll()
    try? await Task.sleep(for: .milliseconds(150))
    let released = await pipeline.poolStatistics()
    check("releasing them returns the leases", busy.liveLeases == 6 && released.liveLeases == 0, "\(released)")
}

// MARK: - Translucent layers

@MainActor
private func checkTranslucentLayers(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- L6. layers with transparent parts ---")
    func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { simd_length(a - b) < 1e-5 }
    let gray = SIMD4<Float>(0.3, 0.3, 0.3, 1)
    let clear = SIMD4<Float>(0, 0, 0, 0)
    // The habitation tint: straight (1, 0.72, 0) at 0.8 alpha, held premultiplied as the displays are.
    let tint = SIMD4<Float>(0.8, 0.576, 0, 0.8)
    let tinted = MicroTopographyReference.blend(base: gray, modulation: tint, mode: .multiply, opacity: 1)
    check("a transparent modulation leaves the base exactly as it is, in every mode",
          RasterBlendMode.allCases.allSatisfy { MicroTopographyReference.blend(base: gray, modulation: clear, mode: $0, opacity: 1) == gray }
          && !near(tinted, gray),
          "\(tinted)")
    check("a translucent modulation counts at its alpha, from its straight colour: 0.3 x (1, 0.72, 0) at 80 %",
          near(tinted, SIMD4<Float>(0.3, 0.2328, 0.06, 1)), "\(tinted)")
    check("a base that is itself translucent keeps its alpha and is blended from its straight colour",
          near(MicroTopographyReference.blend(base: SIMD4<Float>(0.15, 0.15, 0.15, 0.5), modulation: SIMD4<Float>(0.5, 0.5, 0.5, 1),
                                              mode: .multiply, opacity: 1), SIMD4<Float>(0.075, 0.075, 0.075, 0.5)))

    // The real product: habitation marks a few benches and is transparent everywhere else.
    let mesa = mesaScene()
    let raster = ElevationRaster(grid: mesa)
    let window = DestinationWindow.inset(RasterGeometry(mesa), margin: 1)
    guard let raking = await pipeline.render(.rakingLight, raster: raster, window: window),
          let habitation = await pipeline.render(.habitation, raster: raster, window: window),
          let composite = await pipeline.renderComposite(
            base: .rakingLight, modulation: .habitation, blendMode: .multiply, opacity: 1, raster: raster, window: window)
    else {
        check("habitation over raking light composites", false, "nil result")
        return
    }
    var untouched = 0, transparent = 0, tintedCells = 0, worst = 0
    for y in 0..<window.height {
        for x in 0..<window.width {
            let b = raking.display.pixel(x: x, y: y), m = habitation.display.pixel(x: x, y: y), got = composite.display.pixel(x: x, y: y)
            func unit(_ p: SIMD4<UInt8>) -> SIMD4<Float> { SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w)) / 255 }
            let expected = MicroTopographyReference.blend(base: unit(b), modulation: unit(m), mode: .multiply, opacity: 1) * 255
            for (e, g) in zip([expected.x, expected.y, expected.z, expected.w], [got.x, got.y, got.z, got.w]) {
                worst = max(worst, abs(Int(e.rounded()) - Int(g)))
            }
            if m.w == 0 { transparent += 1; if got == b { untouched += 1 } } else if got != b { tintedCells += 1 }
        }
    }
    check("where habitation is transparent the raking light shows through untouched, where it is not the tint applies",
          transparent > 1_000 && untouched == transparent && tintedCells > 20,
          "\(untouched)/\(transparent) transparent cells untouched, \(tintedCells) tinted")
    check("the whole composite matches the CPU reference for translucent layers to one level",
          worst <= 1, "worst \(worst)")

    // And the other way round: a base that is itself translucent, its premultiplied colour divided back first.
    if let translucentComposite = await pipeline.renderComposite(
        base: .habitation, modulation: .rakingLight, blendMode: .multiply, opacity: 1, raster: raster, window: window) {
        var baseWorst = 0, translucentBase = 0
        for y in 0..<window.height {
            for x in 0..<window.width {
                let b = habitation.display.pixel(x: x, y: y), m = raking.display.pixel(x: x, y: y)
                let got = translucentComposite.display.pixel(x: x, y: y)
                func unit(_ p: SIMD4<UInt8>) -> SIMD4<Float> { SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w)) / 255 }
                let e = MicroTopographyReference.blend(base: unit(b), modulation: unit(m), mode: .multiply, opacity: 1) * 255
                for (want, have) in zip([e.x, e.y, e.z, e.w], [got.x, got.y, got.z, got.w]) {
                    baseWorst = max(baseWorst, abs(Int(want.rounded()) - Int(have)))
                }
                if b.w > 0 && b.w < 255 { translucentBase += 1 }
            }
        }
        check("a translucent base (habitation) blended under raking light matches the CPU reference to one level",
              translucentBase > 20 && baseWorst <= 1, "\(translucentBase) translucent cells, worst \(baseWorst)")
    } else {
        check("a translucent base (habitation) blended under raking light matches the CPU reference to one level", false, "nil result")
    }
}
