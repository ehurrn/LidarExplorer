//
//  MicroTopographyChecks.swift
//  ViewerHarness
//
//  GPU-vs-reference, synthetic-scene, zero-copy, pool and budget checks for
//  the micro-topography engine.
//

import CoreGraphics
import CoreLocation
import Foundation
import simd

/// A grid with `makeGrid`'s georeferencing and samples from `f(x, y)`.
func sceneGrid(width: Int, height: Int, gsd: Double, _ f: (Int, Int) -> Float) -> ElevationGrid {
    let template = makeGrid(width: width, height: height, gsd: gsd)
    var samples = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width { samples[y * width + x] = f(x, y) }
    }
    return ElevationGrid(width: width, height: height, samples: samples, region: template.region)
}

/// Largest absolute difference where both hold data, and the count of cells
/// where exactly one of them is a void.
func planeMismatch(_ a: [Float], _ b: [Float]) -> (maxDiff: Float, voidMismatch: Int) {
    var maxDiff: Float = 0
    var voids = 0
    for i in 0..<min(a.count, b.count) {
        if a[i].isNaN != b[i].isNaN { voids += 1; continue }
        if !a[i].isNaN { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
    }
    return (maxDiff, voids)
}

/// A deterministic hash in [-1, 1] for synthetic noise.
func hashNoise(_ x: Int, _ y: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Float(h & 0xFFFF) / 32_767.5 - 1
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
}

/// Flat plain with a truncated-cone platform mound and a conical pit.
func platformScene() -> ElevationGrid {
    sceneGrid(width: 120, height: 120, gsd: 1.0) { x, y in
        let r = Float(hypot(Double(x - 60), Double(y - 60)))
        let flank = Float(tan(30.0 * Double.pi / 180))
        var z: Float = 100
        if r <= 8 { z += 3 } else if r <= 8 + 3 / flank { z += 3 - (r - 8) * flank }
        let rp = Float(hypot(Double(x - 25), Double(y - 95)))
        if rp < 6 { z -= 2 * (1 - rp / 6) }
        return z
    }
}

/// Flat plain, a 12 m cliff over x = 70...75, and a flat mesa top.
func mesaScene(width: Int = 140, height: Int = 140) -> ElevationGrid {
    sceneGrid(width: width, height: height, gsd: 1.0) { x, _ in
        if x < 70 { return 100 }
        if x <= 75 { return 100 + Float(x - 70) * 2.4 }
        return 112
    }
}

@MainActor
func runMicroTopographyChecks(outDir: String) async {
    print("\n=== Micro-topography engine (MetalTerrainPipelineActor) ===")
    let pipeline = MetalTerrainPipelineActor()
    guard await pipeline.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    await checkNoDataAndZeroCopy(pipeline)
    await checkLocalRelief(pipeline)
    await checkRedRelief(pipeline)
    await checkSkyView(pipeline)
    await checkRakingLight(pipeline)
    await checkRelativeElevation(pipeline)
    await checkCurvature(pipeline)
    await checkHabitation(pipeline)
    await checkViewshedSweep(pipeline)
    await checkComposite(pipeline)
    await checkBlitParity(pipeline)
    await checkPool(pipeline)
    await checkBudget(pipeline)
    await renderMicroTopographySamples(pipeline, outDir: outDir)
}

// MARK: - Nodata and zero-copy

@MainActor
func checkNoDataAndZeroCopy(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- nodata normalisation + zero-copy binding ---")
    let w = 64, h = 64
    guard let storage = COGMappedStorage(length: w * h * 4) else {
        check("page-aligned storage allocates", false)
        return
    }
    let floats = storage.pointer.bindMemory(to: Float.self, capacity: w * h)
    for y in 0..<h { for x in 0..<w { floats[y * w + x] = 100 + Float(x) / 10 } }
    let sentinels = [10 * w + 10, 20 * w + 20, 30 * w + 30, 40 * w + 40]
    floats[sentinels[0]] = -999_999
    floats[sentinels[1]] = .infinity
    floats[sentinels[2]] = 4242
    floats[sentinels[3]] = -3.4e38
    let untouched = floats[50 * w + 50]

    let geometry = RasterGeometry(width: w, height: h, cellSizeX: 1, cellSizeY: 1)
    let raster = ElevationRaster(
        samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
        geometry: geometry, needsNoDataNormalization: true, noDataValue: 4242
    )
    if let result = await pipeline.render(.rakingLight, raster: raster) {
        check("page-aligned COG storage binds as a zero-copy linear texture",
              result.elevationBinding == .zeroCopy, "\(result.elevationBinding)")
        check("the GPU nodata pass rewrote every sentinel to NaN in the CPU's own memory",
              sentinels.allSatisfy { floats[$0].isNaN },
              sentinels.map { "\(floats[$0])" }.joined(separator: ","))
        check("the nodata pass leaves real terrain bit-identical", floats[50 * w + 50] == untouched)
        check("a normalised void renders transparent", result.display.pixel(x: 10, y: 10).w == 0)
        check("a normalised void poisons its Horn neighbours (NaN intensity)", result.scalar.value(x: 11, y: 10).isNaN)
        check("cells clear of any void still shade", !result.scalar.value(x: 32, y: 50).isNaN)
    } else {
        check("raking light over mapped storage renders", false, "nil result")
    }

    // Odd row stride: Metal needs width*4 aligned for a linear texture.
    let oddWidth = 63
    if let oddStorage = COGMappedStorage(length: oddWidth * h * 4) {
        let odd = oddStorage.pointer.bindMemory(to: Float.self, capacity: oddWidth * h)
        for i in 0..<(oddWidth * h) { odd[i] = 100 }
        let oddRaster = ElevationRaster(
            samples: .mapped(base: oddStorage.pointer, mappedLength: oddStorage.length, sampleOffset: 0, owner: oddStorage),
            geometry: RasterGeometry(width: oddWidth, height: h, cellSizeX: 1, cellSizeY: 1)
        )
        let oddResult = await pipeline.render(.rakingLight, raster: oddRaster)
        check("a misaligned row stride falls back to a copied binding, not a failure",
              oddResult?.elevationBinding == .copied, "\(String(describing: oddResult?.elevationBinding))")
    }
    let arrayResult = await pipeline.render(.rakingLight, raster: ElevationRaster(grid: makeGrid(width: 64, height: 64, gsd: 1)))
    check("a heap array binds by copy", arrayResult?.elevationBinding == .copied)
}

// MARK: - A. LRM

@MainActor
func checkLocalRelief(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- A. local relief model ---")
    let grid = sceneGrid(width: 160, height: 160, gsd: 1.0) { x, y in
        var z = 100 + 0.05 * Float(x)
        let dx = Float(x - 50), dy = Float(y - 50)
        z += 1.5 * exp(-(dx * dx + dy * dy) / (2 * 16))
        if x >= 20 && x <= 140 {
            let d = Float(y - 120)
            z -= 0.8 * exp(-(d * d) / (2 * 2.25))
        }
        return z
    }
    var samples = grid.samples
    samples[100 * 160 + 100] = .nan
    let voided = ElevationGrid(width: 160, height: 160, samples: samples, region: grid.region)
    let g = RasterGeometry(voided)
    let window = DestinationWindow.inset(g, margin: 30)
    var options = MicroTopographyOptions()
    options.lrmScaleMeters = 2

    guard let result = await pipeline.render(.localRelief, raster: ElevationRaster(grid: voided), window: window, options: options) else {
        check("LRM renders", false, "nil result")
        return
    }
    check("LRM products cover the destination window",
          result.scalar.width == window.width && result.display.width == window.width && result.display.height == window.height)
    let reference = MicroTopographyReference.localRelief(samples, g, window: window, radiusMeters: options.lrmRadiusMeters)
    let mismatch = planeMismatch(result.scalar.values(), reference)
    check("LRM residual matches the CPU normalised convolution (< 2 mm)",
          mismatch.maxDiff < 0.002 && mismatch.voidMismatch == 0, "\(mismatch)")

    func at(_ x: Int, _ y: Int) -> (dh: Float, px: SIMD4<UInt8>) {
        (result.scalar.value(x: x - window.originX, y: y - window.originY),
         result.display.pixel(x: x - window.originX, y: y - window.originY))
    }
    let plane = at(120, 70)
    check("a tilted plane far from features has ~zero local relief", abs(plane.dh) < 0.01, "\(plane.dh)")
    check("flat relief renders neutral grey (128,128,128)",
          abs(Int(plane.px.x) - 128) <= 1 && plane.px.x == plane.px.y && plane.px.y == plane.px.z, "\(plane.px)")
    let mound = at(50, 50)
    check("a mound stands out as positive relief (> +1 m)", mound.dh > 1.0, "\(mound.dh)")
    check("positive relief renders bright", mound.px.x > 180, "\(mound.px)")
    let ditch = at(80, 120)
    check("a ditch reads as negative relief (< -0.5 m)", ditch.dh < -0.5, "\(ditch.dh)")
    check("negative relief renders dark", ditch.px.x < 100, "\(ditch.px)")
    check("a void has NaN relief and a transparent pixel", at(100, 100).dh.isNaN && at(100, 100).px.w == 0)
    check("the void does not bias its neighbours (normalised convolution)",
          abs(at(101, 100).dh - reference[(100 - 30) * window.width + (101 - 30)]) < 0.002)

    options.lrmDiverging = true
    if let diverging = await pipeline.render(.localRelief, raster: ElevationRaster(grid: voided), window: window, options: options) {
        let flat = diverging.display.pixel(x: 90, y: 40)
        let bump = diverging.display.pixel(x: 20, y: 20)
        check("diverging LRM keeps flat ground mid-grey", abs(Int(flat.x) - 128) <= 1 && abs(Int(flat.z) - 128) <= 1, "\(flat)")
        check("diverging LRM tints positive relief red", bump.x > bump.z + 40, "\(bump)")
    }
}

// MARK: - B. RRIM

@MainActor
func checkRedRelief(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- B. red relief image map ---")
    let grid = platformScene()
    let g = RasterGeometry(grid)
    let window = DestinationWindow.inset(g, margin: 1)
    let options = MicroTopographyOptions()
    guard let result = await pipeline.render(.redRelief, raster: ElevationRaster(grid: grid), window: window, options: options) else {
        check("RRIM renders", false, "nil result")
        return
    }
    let table = RayTable(rayCount: options.rrimAzimuthRays, radiusMeters: options.opennessRadiusMeters,
                         cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY)
    let reference = MicroTopographyReference.differentialOpenness(grid.samples, g, window: window, rays: table)
    let mismatch = planeMismatch(result.scalar.values(), reference.differential)
    check("differential openness matches the CPU reference (< 0.02 deg)",
          mismatch.maxDiff < 0.02 && mismatch.voidMismatch == 0, "\(mismatch)")

    var colorError = 0
    for (x, y) in [(94, 19), (59, 59), (70, 59), (24, 94), (40, 40)] {
        let i = y * window.width + x
        let expected = MicroTopographyReference.rrimColor(
            slopeDegrees: reference.slope[i], differential: reference.differential[i], options: options) * 255
        let p = result.display.pixel(x: x, y: y)
        colorError = max(colorError, abs(Int(p.x) - Int(expected.x.rounded())),
                         abs(Int(p.y) - Int(expected.y.rounded())), abs(Int(p.z) - Int(expected.z.rounded())))
    }
    check("RRIM colours match the reference mapping (<= 1/255)", colorError <= 1, "max channel error \(colorError)")

    func at(_ x: Int, _ y: Int) -> (i: Float, px: SIMD4<UInt8>) {
        (result.scalar.value(x: x - 1, y: y - 1), result.display.pixel(x: x - 1, y: y - 1))
    }
    let flat = at(95, 20)
    check("open flat ground has ~zero differential openness", abs(flat.i) < 0.05, "\(flat.i)")
    check("flat ground renders unsaturated mid-grey",
          abs(Int(flat.px.x) - 128) <= 1 && Int(flat.px.x) - Int(flat.px.y) <= 1, "\(flat.px)")
    let top = at(60, 60)
    check("a platform top is convex (I > 3 deg) and bright", top.i > 3 && top.px.x > 150, "I=\(top.i) px=\(top.px)")
    let flank = at(71, 60)
    check("a 30 degree flank reads strongly red", Int(flank.px.x) - Int(flank.px.y) > 60, "\(flank.px)")
    let pit = at(25, 95)
    check("a pit is concave (I < -5 deg) and dark", pit.i < -5 && pit.px.x < 100, "I=\(pit.i) px=\(pit.px)")
}

// MARK: - C. SVF

@MainActor
func checkSkyView(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- C. sky-view factor ---")
    let grid = sceneGrid(width: 120, height: 120, gsd: 1.0) { x, y in
        (x >= 59 && x <= 61 && y >= 10 && y <= 110) ? 98.5 : 100
    }
    let g = RasterGeometry(grid)
    let options = MicroTopographyOptions()
    guard let result = await pipeline.render(.skyView, raster: ElevationRaster(grid: grid), options: options) else {
        check("SVF renders", false, "nil result")
        return
    }
    let table = DualRadiusRayTable(
        rayCount: options.svfAzimuthRays,
        microRadiusMeters: options.svfRadiusMeters,
        macroRadiusMeters: options.svfMacroRadiusMeters,
        cellSizeX: g.cellSizeX,
        cellSizeY: g.cellSizeY,
        minimumStepMeters: options.minimumRayStepMeters
    )
    let reference = MicroTopographyReference.skyViewFactor(grid.samples, g, window: .full(g), rays: table, blendWeight: options.svfBlendWeight)
    let mismatch = planeMismatch(result.scalar.values(), reference)
    check("SVF matches the CPU reference (< 1e-4)", mismatch.maxDiff < 1e-4 && mismatch.voidMismatch == 0, "\(mismatch)")
    check("open flat ground sees the whole sky (SVF ~ 1)", result.scalar.value(x: 20, y: 60) > 0.999,
          "\(result.scalar.value(x: 20, y: 60))")
    let trench = result.scalar.value(x: 60, y: 60)
    check("a sunken trail's floor sees much less sky (SVF < 0.8)", trench < 0.8, "\(trench)")
    check("the trench floor renders darker than the plain",
          result.display.pixel(x: 60, y: 60).x < result.display.pixel(x: 20, y: 60).x)
}

// MARK: - D. Raking light

@MainActor
func checkRakingLight(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- D. dynamic raking light ---")
    let eastFacing = sceneGrid(width: 64, height: 64, gsd: 1.0) { x, _ in 100 - 0.3 * Float(x) }
    let flat = makeGrid(width: 64, height: 64, gsd: 1.0)
    var options = MicroTopographyOptions()
    options.sunAltitudeDegrees = 10
    options.zFactor = 1

    func intensity(_ grid: ElevationGrid, azimuth: Float, zFactor: Float = 1) async -> Float? {
        var o = options
        o.sunAzimuthDegrees = azimuth
        o.zFactor = zFactor
        return await pipeline.render(.rakingLight, raster: ElevationRaster(grid: grid), options: o)?.scalar.value(x: 32, y: 32)
    }
    let litEast = await intensity(eastFacing, azimuth: 90)
    let litWest = await intensity(eastFacing, azimuth: 270)
    let flatLit = await intensity(flat, azimuth: 45)
    let exaggerated = await intensity(eastFacing, azimuth: 90, zFactor: 3)
    if let litEast, let litWest, let flatLit, let exaggerated {
        check("an east-facing slope is lit by an eastern sun (I ~ 0.531)", abs(litEast - 0.531) < 0.002, "\(litEast)")
        check("the same slope in shadow sits exactly on the 0.15 ambient floor", abs(litWest - 0.15) < 1e-5, "\(litWest)")
        check("flat ground under a 10 degree sun reads 0.15 + 0.85 sin(10)",
              abs(flatLit - (0.15 + 0.85 * sin(10 * Float.pi / 180))) < 1e-4, "\(flatLit)")
        check("zFactor exaggerates relief (brighter sun-facing slope)", exaggerated > litEast + 0.2, "\(exaggerated)")
    } else {
        check("raking light renders", false)
    }

    let bumpy = makeGrid(width: 96, height: 96, gsd: 1.0, mounds: [(40, 40, 2, 5), (70, 60, -1.5, 4)])
    let g = RasterGeometry(bumpy)
    options.sunAzimuthDegrees = 123
    options.zFactor = 2.5
    if let result = await pipeline.render(.rakingLight, raster: ElevationRaster(grid: bumpy), options: options) {
        let reference = MicroTopographyReference.rakingHillshade(bumpy.samples, g, window: .full(g), options: options)
        let mismatch = planeMismatch(result.scalar.values(), reference)
        check("raking light matches the CPU reference (< 1e-4)", mismatch.maxDiff < 1e-4 && mismatch.voidMismatch == 0, "\(mismatch)")
    }
}

// MARK: - F. REM

@MainActor
func checkRelativeElevation(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- F. relative elevation model ---")
    let grid = sceneGrid(width: 128, height: 128, gsd: 1.0) { x, y in
        let levee = Float(x - 70)
        let swale = Float(x - 40)
        return 50 - 0.01 * Float(y) + 0.2 * Float(abs(x - 64)) + 3 * exp(-(levee * levee) / (2 * 2.25))
            - 5.8 * exp(-(swale * swale) / (2 * 4))
    }
    let g = RasterGeometry(grid)
    let thalweg = [0, 32, 64, 96, 127].map { row in
        ThalwegVertex(x: 64 * g.cellSizeX, y: Float(row) * g.cellSizeY, waterSurface: 50 - 0.01 * Float(row))
    }
    let options = MicroTopographyOptions()
    guard let result = await pipeline.render(.relativeElevation, raster: ElevationRaster(grid: grid),
                                             options: options, thalweg: thalweg) else {
        check("REM renders", false, "nil result")
        return
    }
    let reference = MicroTopographyReference.relativeElevation(grid.samples, g, window: .full(g), thalweg: thalweg, power: options.remIDWPower)
    let mismatch = planeMismatch(result.scalar.values(), reference)
    check("REM matches the CPU reference (< 1 mm)", mismatch.maxDiff < 0.001 && mismatch.voidMismatch == 0, "\(mismatch)")
    let channel = result.scalar.value(x: 64, y: 60)
    check("the channel sits at the water surface (h_rel ~ 0)", abs(channel) < 0.02, "\(channel)")
    let levee = result.scalar.value(x: 70, y: 60)
    check("the levee crest stands +4.2 m above the river", abs(levee - 4.2) < 0.2, "\(levee)")
    let swale = result.scalar.value(x: 40, y: 60)
    check("a paleochannel swale sits below the river (h_rel < -0.5 m)", swale < -0.5, "\(swale)")
    let swalePixel = result.display.pixel(x: 40, y: 60)
    let leveePixel = result.display.pixel(x: 70, y: 60)
    check("sub-water-surface ground tints blue", swalePixel.z > swalePixel.x + 60, "\(swalePixel)")
    check("levee-band ground tints warm", leveePixel.x > leveePixel.z + 60, "\(leveePixel)")

    let plane = await pipeline.render(.relativeElevation, raster: ElevationRaster(grid: grid),
                                      thalweg: [ThalwegVertex(x: 0, y: 0, waterSurface: 48)])
    let planeValue = plane?.scalar.value(x: 70, y: 60) ?? .nan
    let expected = grid.samples[60 * 128 + 70] - 48
    check("a single-vertex thalweg detrends against a flat water plane", abs(planeValue - expected) < 1e-3, "\(planeValue) vs \(expected)")
    let none = await pipeline.render(.relativeElevation, raster: ElevationRaster(grid: grid))
    check("REM without a thalweg declines rather than guessing", none == nil)
}

// MARK: - J. Topographic Curvature

@MainActor
func checkCurvature(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- J. topographic curvature (Zevenbergen & Thorne 1987) ---")
    let grid = platformScene()
    let g = RasterGeometry(grid)
    let window = DestinationWindow.inset(g, margin: 2)
    guard let result = await pipeline.render(.curvature, raster: ElevationRaster(grid: grid), window: window) else {
        check("Curvature renders", false, "nil result")
        return
    }
    let (refProf, refPlan) = MicroTopographyReference.topographicCurvature(grid.samples, g, window: window)
    check("curvature reference computed successfully", refProf.count == window.count && refPlan.count == window.count)
    let top = result.display.pixel(x: 60 - 2, y: 60 - 2)
    check("platform top curvature renders non-zero pixel", top.w == 255)
}

// MARK: - G. Habitation

@MainActor
func checkHabitation(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- G. habitation potential (jump flood) ---")
    let mesa = mesaScene()
    let g = RasterGeometry(mesa)
    let window = DestinationWindow.inset(g, margin: 1)
    let options = MicroTopographyOptions()
    if let result = await pipeline.render(.habitation, raster: ElevationRaster(grid: mesa), window: window, options: options) {
        let reference = MicroTopographyReference.habitationMask(mesa.samples, g, window: window, options: options)
        let gpu = result.scalar.values()
        let mismatches = zip(gpu, reference).filter { ($0.0 > 0.5) != $0.1 }.count
        check("jump-flood mask matches the brute-force 30 m disk search exactly", mismatches == 0, "\(mismatches) cells differ")
        func qualifies(_ x: Int) -> Bool { result.scalar.value(x: x - 1, y: 69) > 0.5 }
        check("open plain far from any bluff does not qualify", !qualifies(20))
        check("the plain at the foot of the bluff qualifies", qualifies(45))
        check("the mesa top along the bluff edge qualifies", qualifies(90))
        check("the mesa interior > 30 m from the edge does not qualify", !qualifies(120))
        check("the steep face itself never qualifies", !qualifies(72))
        let lit = result.display.pixel(x: 44, y: 69)
        check("qualifying cells carry the amber highlight", lit.x > lit.z + 100 && lit.w > 150, "\(lit)")
    } else {
        check("habitation renders", false, "nil result")
    }

    // Scattered cones on an anisotropic raster: exercises the metric JFA.
    var z = [Float](repeating: 200, count: 200 * 200)
    var state: UInt32 = 12345
    func next() -> Int {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Int(state >> 8)
    }
    for _ in 0..<40 {
        let cx = next() % 200, cy = next() % 200, r = 3 + next() % 9, hgt = Float(4 + next() % 14)
        for y in max(cy - r, 0)..<min(cy + r, 200) {
            for x in max(cx - r, 0)..<min(cx + r, 200) {
                let d = Float(hypot(Double(x - cx), Double(y - cy) * 0.7))
                if d < Float(r) { z[y * 200 + x] += hgt * (1 - d / Float(r)) }
            }
        }
    }
    let aniso = RasterGeometry(width: 200, height: 200, cellSizeX: 1.0, cellSizeY: 0.7)
    let anisoWindow = DestinationWindow.inset(aniso, margin: 1)
    if let result = await pipeline.render(.habitation, raster: ElevationRaster(samples: .array(z), geometry: aniso),
                                          window: anisoWindow, options: options) {
        let reference = MicroTopographyReference.habitationMask(z, aniso, window: anisoWindow, options: options)
        let gpu = result.scalar.values()
        let mismatches = zip(gpu, reference).filter { ($0.0 > 0.5) != $0.1 }.count
        let positives = reference.filter { $0 }.count
        check("anisotropic scattered-relief mask agrees with brute force (<= 0.1% cells)",
              Double(mismatches) <= Double(anisoWindow.count) * 0.001 && positives > 100,
              "\(mismatches) of \(anisoWindow.count) differ, \(positives) positives")
    }
}

// MARK: - Viewshed

@MainActor
func checkViewshedSweep(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- B(3). radial-sweep viewshed ---")
    let terrain = makeGrid(width: 201, height: 201, gsd: 2.0, base: 150,
                           mounds: [(60, 60, 12, 10), (150, 90, 20, 14), (110, 160, 8, 6), (90, 120, -6, 12)])
    let g = RasterGeometry(terrain)
    guard let result = await pipeline.viewshed(raster: ElevationRaster(grid: terrain), observerColumn: 100,
                                               observerRow: 100, maxRadiusMeters: 180) else {
        check("radial viewshed renders", false, "nil result")
        return
    }
    let reference = MicroTopographyReference.viewshed(
        terrain.samples, g, observerX: 100, observerY: 100, eyeHeight: 2, targetHeight: 0.5,
        maxRadiusMeters: 180, angularSteps: 720) ?? []
    let gpu = result.mask.values()
    let differ = zip(gpu, reference).filter { ($0.0 > 0.5) != $0.1 }.count
    check("GPU sweep matches the CPU sweep (<= 0.1% cells)", !reference.isEmpty && differ <= g.count / 1000, "\(differ) differ")
    check("the observer's own cell is visible", result.mask.value(x: 100, y: 100) > 0.5)
    check("cells beyond the radius are not visible", result.mask.value(x: 200, y: 100) < 0.5)
    let hidden = gpu.enumerated().filter { i, v in
        let dx = Float(i % 201 - 100) * g.cellSizeX, dy = Float(i / 201 - 100) * g.cellSizeY
        return (dx * dx + dy * dy).squareRoot() < 170 && v < 0.5
    }.count
    check("mounds cast real shadows inside the radius", hidden > 500, "\(hidden) hidden cells")

    // Wall: due east is occluded, north-east past the wall's rows is not.
    var wall = [Float](repeating: 100, count: 71 * 61)
    for y in 28...32 { for x in 39...41 { wall[y * 71 + x] = 160 } }
    let wallGeometry = RasterGeometry(width: 71, height: 61, cellSizeX: 2, cellSizeY: 2)
    if let wallResult = await pipeline.viewshed(raster: ElevationRaster(samples: .array(wall), geometry: wallGeometry),
                                                observerColumn: 10, observerRow: 30, maxRadiusMeters: 200) {
        check("a target directly behind a wall is hidden", wallResult.mask.value(x: 60, y: 30) < 0.5)
        check("a target off the wall's row band is visible", wallResult.mask.value(x: 60, y: 10) > 0.5)
    }

    // Agreement with the legacy per-target raymarch on the same terrain.
    let legacy = RasterCompute()
    if await legacy.isViewshedAvailable(),
       let old = await legacy.viewshed(for: terrain, observerColumn: 100, observerRow: 100,
                                       eyeHeightMeters: 1.7, maxRadiusMeters: 180),
       let sweep = await pipeline.viewshed(raster: ElevationRaster(grid: terrain), observerColumn: 100, observerRow: 100,
                                           eyeHeight: 1.7, targetHeight: 0, maxRadiusMeters: 180) {
        var inside = 0, agree = 0
        let sweepMask = sweep.mask.values()
        for i in 0..<g.count {
            let dx = Float(i % 201 - 100) * g.cellSizeX, dy = Float(i / 201 - 100) * g.cellSizeY
            guard (dx * dx + dy * dy).squareRoot() < 175 else { continue }
            inside += 1
            if old[i] == (sweepMask[i] > 0.5) { agree += 1 }
        }
        let fraction = Double(agree) / Double(max(inside, 1))
        check("radial sweep agrees with the legacy raymarch on >= 93% of cells",
              fraction >= 0.93, String(format: "%.2f%%", fraction * 100))
    }

    var voided = terrain.samples
    voided[100 * 201 + 100] = .nan
    let voidObserver = await pipeline.viewshed(
        raster: ElevationRaster(samples: .array(voided), geometry: g), observerColumn: 100, observerRow: 100, maxRadiusMeters: 50)
    check("an observer over a void returns nil", voidObserver == nil)

    // Brief scale: 5 km radius on a 2048^2 raster.
    let big = sceneGrid(width: 2048, height: 2048, gsd: 5.0) { x, y in
        200 + 30 * sin(Float(x) / 60) * cos(Float(y) / 45) + 0.5 * hashNoise(x, y)
    }
    if let wide = await pipeline.viewshed(raster: ElevationRaster(grid: big), observerColumn: 1024, observerRow: 1024,
                                          maxRadiusMeters: 5000) {
        print(String(format: "        5 km / 720-ray sweep over 2048x2048: %.2f ms GPU", wide.gpuMilliseconds))
        check("a 5 km sweep completes", wide.mask.value(x: 1024, y: 1024) > 0.5)
    }
}

// MARK: - Composite

@MainActor
func checkComposite(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- E/4. composite render pass ---")
    var samples = sceneGrid(width: 128, height: 128, gsd: 1.0) { x, y in
        let dx = Float(x - 64), dy = Float(y - 64)
        return 100 + 0.08 * Float(x) + 3 * exp(-(dx * dx + dy * dy) / 200)
    }.samples
    for y in 100..<116 { for x in 10..<26 { samples[y * 128 + x] = .nan } }
    let grid = ElevationGrid(width: 128, height: 128, samples: samples, region: makeGrid(width: 128, height: 128, gsd: 1).region)
    let g = RasterGeometry(grid)
    let window = DestinationWindow.inset(g, margin: 4)
    let raster = ElevationRaster(grid: grid)
    let contours = CompositeOverlays(contourIntervalMeters: 0.25, indexIntervalMeters: 2.5)

    guard let plain = await pipeline.render(.rakingLight, raster: raster, window: window),
          let lined = await pipeline.render(.rakingLight, raster: raster, window: window, overlays: contours),
          let doubled = await pipeline.render(.rakingLight, raster: raster, window: window, overlays: contours, outputScale: 2)
    else {
        check("composite renders", false, "nil result")
        return
    }
    var changed = 0
    for y in 0..<window.height { for x in 0..<window.width where plain.display.pixel(x: x, y: y) != lined.display.pixel(x: x, y: y) { changed += 1 } }
    check("procedural contours ink the composite", changed > 500, "\(changed) pixels changed")
    check("contours never draw into voids", lined.display.pixel(x: 17 - 4, y: 107 - 4).w == 0)
    check("output scale 2 renders at twice the window resolution",
          doubled.display.width == window.width * 2 && doubled.display.height == window.height * 2)
    check("the composite keeps the product's own scalar", doubled.scalar.width == window.width)

    // fwidth keeps lines ~1 px wide at 2x: ink coverage per row roughly equal, not doubled per pixel.
    var inked1 = 0, inked2 = 0
    for x in 0..<window.width where lined.display.pixel(x: x, y: 20) != plain.display.pixel(x: x, y: 20) { inked1 += 1 }
    for x in 0..<(window.width * 2) {
        let p = doubled.display.pixel(x: x, y: 41)
        if p.x < plain.display.pixel(x: x / 2, y: 20).x - 8 { inked2 += 1 }
    }
    check("screen-space line width stays constant across output scale (2x ink per row <= 2.6x of 1x)",
          inked1 > 0 && Double(inked2) <= Double(inked1) * 2.6, "1x=\(inked1) 2x=\(inked2)")

    let mesa = mesaScene()
    let mesaRaster = ElevationRaster(grid: mesa)
    let mesaWindow = DestinationWindow.inset(RasterGeometry(mesa), margin: 1)
    if let masked = await pipeline.render(.rakingLight, raster: mesaRaster, window: mesaWindow,
                                          overlays: CompositeOverlays(habitationOpacity: 1)) {
        let bench = masked.display.pixel(x: 44, y: 69)
        let plain = masked.display.pixel(x: 19, y: 69)
        check("the habitation overlay tints qualifying ground", Int(bench.x) - Int(bench.z) > 60, "\(bench)")
        check("the habitation overlay leaves other ground untinted", abs(Int(plain.x) - Int(plain.z)) < 6, "\(plain)")
    }

    let trench = sceneGrid(width: 120, height: 120, gsd: 1.0) { x, y in
        (x >= 59 && x <= 61 && y >= 10 && y <= 110) ? 98.5 : 100
    }
    if let base = await pipeline.render(.rakingLight, raster: ElevationRaster(grid: trench)),
       let occluded = await pipeline.render(.rakingLight, raster: ElevationRaster(grid: trench),
                                            overlays: CompositeOverlays(skyViewStrength: 1)) {
        check("sky-view modulation darkens the trench floor",
              occluded.display.pixel(x: 60, y: 60).x + 10 < base.display.pixel(x: 60, y: 60).x,
              "\(occluded.display.pixel(x: 60, y: 60)) vs \(base.display.pixel(x: 60, y: 60))")
        check("sky-view modulation leaves open ground alone",
              abs(Int(occluded.display.pixel(x: 20, y: 60).x) - Int(base.display.pixel(x: 20, y: 60).x)) <= 1)
    }
}

// MARK: - Blit parity

@MainActor
func checkBlitParity(_ linear: MetalTerrainPipelineActor) async {
    print("\n--- simulator surface path (private textures + blits) ---")
    let blit = MetalTerrainPipelineActor(surfaceMode: .blit)
    guard await blit.isAvailable() else {
        check("blit-mode pipeline available", false)
        return
    }
    let grid = platformScene()
    let raster = ElevationRaster(grid: grid)
    let window = DestinationWindow.inset(RasterGeometry(grid), margin: 2)
    let overlays = CompositeOverlays(contourIntervalMeters: 0.5, indexIntervalMeters: 2.5, habitationOpacity: 0.8, skyViewStrength: 0.6)
    for product in [MicroTopographyProduct.localRelief, .redRelief, .habitation] {
        guard let a = await linear.render(product, raster: raster, window: window, overlays: overlays),
              let b = await blit.render(product, raster: raster, window: window, overlays: overlays)
        else {
            check("\(product.rawValue) renders on both surface paths", false)
            continue
        }
        let scalars = planeMismatch(a.scalar.values(), b.scalar.values())
        var pixelsDiffer = 0
        for y in 0..<a.display.height { for x in 0..<a.display.width where a.display.pixel(x: x, y: y) != b.display.pixel(x: x, y: y) { pixelsDiffer += 1 } }
        check("\(product.rawValue): blit path is bit-identical to the linear path",
              b.elevationBinding == .blitted && scalars.maxDiff == 0 && scalars.voidMismatch == 0 && pixelsDiffer == 0,
              "binding=\(b.elevationBinding) scalar=\(scalars) pixels=\(pixelsDiffer)")
    }
}

// MARK: - Pool

@MainActor
func checkPool(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- surface pool ---")
    let raster = ElevationRaster(grid: platformScene())
    for _ in 0..<12 {
        _ = await pipeline.render(.localRelief, raster: raster, overlays: CompositeOverlays(contourIntervalMeters: 0.5))
    }
    try? await Task.sleep(for: .milliseconds(150))
    let idle = await pipeline.poolStatistics()
    check("dropped results return every lease", idle.liveLeases == 0, "\(idle)")
    check("the idle pool stays inside its byte cap", idle.idleBytes <= MetalTerrainPipelineActor.idleByteLimit, "\(idle)")
    check("surfaces are recycled rather than reallocated", idle.idleBuffers > 0, "\(idle)")

    var held: [MicroTopographyResult] = []
    for _ in 0..<3 {
        if let r = await pipeline.render(.skyView, raster: raster) { held.append(r) }
    }
    let busy = await pipeline.poolStatistics()
    check("held results keep their leases (display + scalar each)", busy.liveLeases == 6, "\(busy)")
    held.removeAll()
    try? await Task.sleep(for: .milliseconds(150))
    check("releasing held results returns their leases", await pipeline.poolStatistics().liveLeases == 0)
}

// MARK: - Budget

@MainActor
func checkBudget(_ pipeline: MetalTerrainPipelineActor) async {
    print("\n--- compute dispatch budget (1024 x 1024, 1 m) ---")
    let size = 1024
    guard let storage = COGMappedStorage(length: size * size * 4) else { return }
    let floats = storage.pointer.bindMemory(to: Float.self, capacity: size * size)
    for y in 0..<size {
        for x in 0..<size {
            var z = 150 + 8 * sin(Float(x) / 90) * cos(Float(y) / 70) + 0.03 * Float(x) + 0.05 * hashNoise(x, y)
            let mx = Float(x % 128 - 64), my = Float(y % 128 - 64)
            z += 2 * exp(-(mx * mx + my * my) / 180)
            floats[y * size + x] = z
        }
    }
    let raster = ElevationRaster(
        samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
        geometry: RasterGeometry(width: size, height: size, cellSizeX: 1, cellSizeY: 1)
    )
    func time(_ product: MicroTopographyProduct, overlays: CompositeOverlays = CompositeOverlays()) async -> Double {
        _ = await pipeline.render(product, raster: raster, overlays: overlays)
        var samples: [Double] = []
        for _ in 0..<7 {
            if let r = await pipeline.render(product, raster: raster, overlays: overlays) { samples.append(r.gpuMilliseconds) }
        }
        return median(samples)
    }
    let lrm = await time(.localRelief)
    let rrim = await time(.redRelief)
    let svf = await time(.skyView)
    let raking = await time(.rakingLight)
    let rakingWallStart = Date()
    _ = await pipeline.render(.rakingLight, raster: raster)
    let rakingWallMs = Date().timeIntervalSince(rakingWallStart) * 1000.0
    let habitation = await time(.habitation)
    let composite = await time(.rakingLight, overlays: CompositeOverlays(contourIntervalMeters: 0.25, indexIntervalMeters: 2.5,
                                                                         habitationOpacity: 0.8, skyViewStrength: 0.5))
    print(String(format: "        GPU median ms — LRM %.2f · RRIM %.2f · SVF %.2f · raking %.2f (wall-clock %.2f ms) · habitation %.2f · full composite %.2f",
                 lrm, rrim, svf, raking, rakingWallMs, habitation, composite))
    check("LRM over 1024x1024 completes in under 8 ms of GPU time", lrm < 8, String(format: "%.2f ms", lrm))
    check("RRIM over 1024x1024 completes in under 8 ms of GPU time", rrim < 8, String(format: "%.2f ms", rrim))
}

// MARK: - Sample renders

@MainActor
func renderMicroTopographySamples(_ pipeline: MetalTerrainPipelineActor, outDir: String) async {
    let size = 512
    let grid = sceneGrid(width: size, height: size, gsd: 1.0) { x, y in
        var z = 60 + 0.004 * Float(y) + 0.3 * hashNoise(x / 3, y / 3) * 0.1
        // River valley along x = 110 with a levee to its east.
        z += 0.15 * Float(abs(x - 110)).squareRoot()
        let levee = Float(x - 124)
        z += 2.5 * exp(-(levee * levee) / 18)
        // Platform mound.
        let r = Float(hypot(Double(x - 300), Double(y - 150)))
        if r <= 14 { z += 4 } else if r <= 22 { z += 4 - (r - 14) * 0.5 }
        // Ditch and berm enclosure.
        let e = Float(hypot(Double(x - 330), Double(y - 360)))
        z -= 1.1 * exp(-((e - 60) * (e - 60)) / 6)
        z += 0.8 * exp(-((e - 66) * (e - 66)) / 6)
        // Bluff with a bench.
        if x > 440 { z += min(Float(x - 440) * 1.2, 18) }
        return z
    }
    let raster = ElevationRaster(grid: grid)
    let g = RasterGeometry(grid)
    let thalweg = stride(from: 0, through: size - 1, by: 64).map {
        ThalwegVertex(x: 110 * g.cellSizeX, y: Float($0) * g.cellSizeY, waterSurface: 60 + 0.004 * Float($0))
    }
    let renders: [(String, MicroTopographyProduct, CompositeOverlays)] = [
        ("micro_lrm", .localRelief, CompositeOverlays()),
        ("micro_rrim", .redRelief, CompositeOverlays()),
        ("micro_svf", .skyView, CompositeOverlays()),
        ("micro_raking", .rakingLight, CompositeOverlays()),
        ("micro_rem", .relativeElevation, CompositeOverlays()),
        ("micro_curvature", .curvature, CompositeOverlays()),
        ("micro_habitation", .habitation, CompositeOverlays()),
        ("micro_composite", .rakingLight, CompositeOverlays(contourIntervalMeters: 0.5, indexIntervalMeters: 2.5,
                                                            habitationOpacity: 0.7, skyViewStrength: 0.6)),
    ]
    var written = 0
    for (name, product, overlays) in renders {
        guard let result = await pipeline.render(product, raster: raster, thalweg: thalweg, overlays: overlays),
              let image = result.display.makeImage() else { continue }
        if writePNG(image, to: "\(outDir)/\(name).png") { written += 1 }
    }
    if let vs = await pipeline.viewshed(raster: raster, observerColumn: 300, observerRow: 150, maxRadiusMeters: 400),
       let image = vs.display.makeImage(), writePNG(image, to: "\(outDir)/micro_viewshed.png") {
        written += 1
    }
    check("micro-topography sample renders written", written == renders.count + 1, "\(written) written to \(outDir)")
}
