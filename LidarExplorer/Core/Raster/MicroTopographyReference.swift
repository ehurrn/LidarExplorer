//
//  MicroTopographyReference.swift
//  LidarExplorer
//
//  Shared parameter types and CPU reference implementations for the
//  micro-topography kernels.
//

import Foundation
import simd

// MARK: - Parameters

/// Tunables for the micro-topography products, with the brief's defaults.
public nonisolated struct MicroTopographyOptions: Sendable, Equatable, Hashable {
    // A. Local Relief Model
    /// Low-pass truncation radius in metres (Gaussian sigma is half of it).
    public var lrmRadiusMeters: Float = 25
    /// |dh| at which the LRM display saturates to white or black.
    public var lrmScaleMeters: Float = 2.0
    public var lrmDiverging: Bool = false

    // B. Red Relief Image Map
    public var opennessRadiusMeters: Float = 20
    public var rrimAzimuthRays: Int = 16
    public var slopeMultiplier: Float = 1.0
    public var rrimSlopeSaturationDegrees: Float = 45
    public var rrimOpennessRangeDegrees: Float = 20

    // C. Sky-view factor
    public var svfRadiusMeters: Float = 15
    public var svfAzimuthRays: Int = 16
    public var svfDisplayMinimum: Float = 0.65

    // D. Raking light
    public var sunAzimuthDegrees: Float = 315
    public var sunAltitudeDegrees: Float = 10
    public var zFactor: Float = 2.0
    public var ambient: Float = 0.15

    // F. Relative elevation
    public var remIDWPower: Float = 2
    public var remRange: ClosedRange<Float> = -3...10
    public var remBandMeters: Float = 0.5

    // G. Habitation potential
    public var flatSlopeMaximumDegrees: Float = 4
    public var steepSlopeMinimumDegrees: Float = 25
    public var habitationRadiusMeters: Float = 30

    /// Ray samples are never spaced closer than this, in metres. An oversampled
    /// raster (0.23 m pixels resampled from 1 m lidar) gains nothing from
    /// stepping every pixel but pays for it per ray.
    public var minimumRayStepMeters: Float = 0

    /// Macro-scale radius for dual-scale SVF (default 60 m).
    public var svfMacroRadiusMeters: Float = 60

    /// Blend weight between micro (15 m) and macro (60 m) SVF: alpha * micro + (1 - alpha) * macro.
    public var svfBlendWeight: Float = 0.65

    // H. Directional grazing occlusion
    public var directionalOcclusionAzimuthDegrees: Float = 315.0
    public var directionalOcclusionAltitudeDegrees: Float = 15.0
    public var directionalOcclusionDistanceMeters: Float = 60.0

    // I. Difference of Gaussians (DoG)
    public var dogSigma1Meters: Float = 2.0
    public var dogSigma2Meters: Float = 10.0

    // J. Vector Ruggedness Measure (VRM)
    public var vrmMaxDisplay: Float = 0.015

    // K. Robust Tukey LRM
    public var lrmRobustTukey: Bool = false
    public var lrmTukeyCutoffMeters: Float = 1.5

    public init() {}

    /// The largest neighbourhood any product reads, in metres.
    public var maximumRadiusMeters: Float {
        max(lrmRadiusMeters, opennessRadiusMeters, svfRadiusMeters, svfMacroRadiusMeters,
            habitationRadiusMeters, dogSigma2Meters * 3, directionalOcclusionDistanceMeters)
    }
}

/// A raster's cell geometry, enough for every kernel's uniforms.
public nonisolated struct RasterGeometry: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Metres between columns.
    public let cellSizeX: Float
    /// Metres between rows.
    public let cellSizeY: Float

    public init(width: Int, height: Int, cellSizeX: Float, cellSizeY: Float) {
        self.width = width
        self.height = height
        self.cellSizeX = cellSizeX
        self.cellSizeY = cellSizeY
    }

    public init(_ grid: ElevationGrid) {
        self.init(
            width: grid.width, height: grid.height,
            cellSizeX: Float(grid.metersPerColumn), cellSizeY: Float(grid.metersPerRow)
        )
    }

    public var count: Int { width * height }
}

/// The part of a padded raster a display product covers.
public nonisolated struct DestinationWindow: Sendable, Equatable {
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int

    public init(originX: Int, originY: Int, width: Int, height: Int) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// The whole raster.
    public static func full(_ geometry: RasterGeometry) -> DestinationWindow {
        DestinationWindow(originX: 0, originY: 0, width: geometry.width, height: geometry.height)
    }

    /// The raster minus a uniform skirt.
    public static func inset(_ geometry: RasterGeometry, margin: Int) -> DestinationWindow {
        DestinationWindow(
            originX: margin, originY: margin,
            width: max(geometry.width - margin * 2, 0), height: max(geometry.height - margin * 2, 0)
        )
    }

    public var count: Int { width * height }
}

/// A river centreline vertex in a raster's metric frame (x east from column 0,
/// y south from row 0), carrying the water-surface elevation there.
public nonisolated struct ThalwegVertex: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var waterSurface: Float
    public var padding: Float = 0

    public init(x: Float, y: Float, waterSurface: Float) {
        self.x = x
        self.y = y
        self.waterSurface = waterSurface
    }
}

/// A river centreline segment in a raster's metric frame, carrying start and end
/// water-surface elevations. Exactly 32 bytes, aligned to 8.
public nonisolated struct ThalwegSegment: Sendable, Equatable {
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var startWaterSurface: Float
    public var endWaterSurface: Float
    public var segmentLength: Float
    public var padding: Float = 0

    public init(start: SIMD2<Float>, end: SIMD2<Float>, startWaterSurface: Float, endWaterSurface: Float) {
        self.start = start
        self.end = end
        self.startWaterSurface = startWaterSurface
        self.endWaterSurface = endWaterSurface
        self.segmentLength = simd_distance(start, end)
    }

    /// Constructs piecewise segments from an ordered thalweg vertex chain.
    public static func makeSegments(from vertices: [ThalwegVertex]) -> [ThalwegSegment] {
        guard vertices.count >= 2 else {
            if let first = vertices.first {
                let p = SIMD2(first.x, first.y)
                return [ThalwegSegment(start: p, end: p, startWaterSurface: first.waterSurface, endWaterSurface: first.waterSurface)]
            }
            return []
        }
        var segments: [ThalwegSegment] = []
        segments.reserveCapacity(vertices.count - 1)
        for k in 0..<(vertices.count - 1) {
            let a = SIMD2(vertices[k].x, vertices[k].y)
            let b = SIMD2(vertices[k + 1].x, vertices[k + 1].y)
            segments.append(ThalwegSegment(
                start: a, end: b,
                startWaterSurface: vertices[k].waterSurface,
                endWaterSurface: vertices[k + 1].waterSurface
            ))
        }
        return segments
    }
}

/// Mirror of `RayStep` in `TerrainKernels.metal`: 12 bytes, 4-byte aligned.
public nonisolated struct RayStep: Sendable, Equatable {
    public var dx: Int32
    public var dy: Int32
    public var invDistance: Float
}

/// Precomputed radial rays for openness and sky-view.
///
/// Built once per (rays, radius, cell size) and consumed identically by the
/// GPU kernel and the CPU reference, which is what makes an exact parity check
/// between them possible. Consecutive samples that round to the same cell are
/// dropped; shorter rays are padded by repeating their last sample, which
/// cannot change a maximum.
public nonisolated struct RayTable: Sendable, Equatable {
    public let rayCount: Int
    public let stepsPerRay: Int
    public let steps: [RayStep]
    /// Largest |dx| or |dy| of any sample: cells at least this far from every
    /// edge can skip bounds tests.
    public let maxReach: Int

    public init(rayCount: Int, radiusMeters: Float, cellSizeX: Float, cellSizeY: Float, minimumStepMeters: Float = 0) {
        let n = max(rayCount, 1)
        let cellX = max(cellSizeX, 1e-6)
        let cellY = max(cellSizeY, 1e-6)
        let stepMeters = max(min(cellX, cellY), minimumStepMeters)
        let sampleCount = max(Int((radiusMeters / stepMeters).rounded(.down)), 1)

        var rays: [[RayStep]] = []
        rays.reserveCapacity(n)
        var reach = 0
        for r in 0..<n {
            let theta = Float(r) * 2 * .pi / Float(n)
            let east = sin(theta)
            let south = -cos(theta)
            var ray: [RayStep] = []
            var last: (Int32, Int32)?
            for k in 1...sampleCount {
                let meters = Float(k) * stepMeters
                let dx = Int32((east * meters / cellX).rounded())
                let dy = Int32((south * meters / cellY).rounded())
                if dx == 0 && dy == 0 { continue }
                if let last, last == (dx, dy) { continue }
                let groundX = Float(dx) * cellX
                let groundY = Float(dy) * cellY
                let distance = (groundX * groundX + groundY * groundY).squareRoot()
                guard distance <= radiusMeters + stepMeters * 0.5 else { continue }
                ray.append(RayStep(dx: dx, dy: dy, invDistance: 1 / distance))
                last = (dx, dy)
                reach = max(reach, Int(abs(dx)), Int(abs(dy)))
            }
            rays.append(ray)
        }
        let longest = max(rays.map(\.count).max() ?? 0, 1)
        var flat: [RayStep] = []
        flat.reserveCapacity(longest * n)
        for ray in rays {
            if ray.isEmpty {
                // Radius shorter than one cell: a ray that samples nothing
                // reads as flat in both kernels.
                flat.append(contentsOf: repeatElement(RayStep(dx: 0, dy: 0, invDistance: 0), count: longest))
            } else {
                flat.append(contentsOf: ray)
                flat.append(contentsOf: repeatElement(ray[ray.count - 1], count: longest - ray.count))
            }
        }
        self.rayCount = n
        self.stepsPerRay = longest
        self.steps = flat
        self.maxReach = reach
    }
}

/// Precomputed radial rays for dual-radius sky-view factor.
/// Evaluates micro scale and macro scale in a single pass.
public nonisolated struct DualRadiusRayTable: Sendable, Equatable {
    public let rayCount: Int
    public let microStepsPerRay: Int
    public let macroStepsPerRay: Int
    public let steps: [RayStep]
    public let maxReach: Int

    public init(
        rayCount: Int,
        microRadiusMeters: Float,
        macroRadiusMeters: Float,
        cellSizeX: Float,
        cellSizeY: Float,
        minimumStepMeters: Float = 0
    ) {
        let n = max(rayCount, 1)
        let cellX = max(cellSizeX, 1e-6)
        let cellY = max(cellSizeY, 1e-6)
        let microStep = max(min(cellX, cellY), minimumStepMeters)

        let microSampleCount = max(Int((microRadiusMeters / microStep).rounded(.down)), 1)

        var microRays: [[RayStep]] = []
        var macroRays: [[RayStep]] = []
        microRays.reserveCapacity(n)
        macroRays.reserveCapacity(n)
        var reach = 0

        for r in 0..<n {
            let theta = Float(r) * 2 * .pi / Float(n)
            let east = sin(theta)
            let south = -cos(theta)

            // Micro ray
            var mRay: [RayStep] = []
            var lastM: (Int32, Int32)?
            for k in 1...microSampleCount {
                let meters = Float(k) * microStep
                let dx = Int32((east * meters / cellX).rounded())
                let dy = Int32((south * meters / cellY).rounded())
                if dx == 0 && dy == 0 { continue }
                if let lastM, lastM == (dx, dy) { continue }
                let gx = Float(dx) * cellX
                let gy = Float(dy) * cellY
                let dist = (gx * gx + gy * gy).squareRoot()
                guard dist <= microRadiusMeters + microStep * 0.5 else { continue }
                mRay.append(RayStep(dx: dx, dy: dy, invDistance: 1 / dist))
                lastM = (dx, dy)
                reach = max(reach, Int(abs(dx)), Int(abs(dy)))
            }
            microRays.append(mRay)

            // Macro ray: Variant C (geometric far steps beyond micro radius)
            var M_ray: [RayStep] = []
            var lastMacro: (Int32, Int32)?
            if macroRadiusMeters > microRadiusMeters {
                let macroSteps = 12
                let q = pow(macroRadiusMeters / microRadiusMeters, 1.0 / Float(macroSteps))
                for k in 1...macroSteps {
                    let meters = microRadiusMeters * pow(q, Float(k))
                    let dx = Int32((east * meters / cellX).rounded())
                    let dy = Int32((south * meters / cellY).rounded())
                    if dx == 0 && dy == 0 { continue }
                    if let lastMacro, lastMacro == (dx, dy) { continue }
                    let gx = Float(dx) * cellX
                    let gy = Float(dy) * cellY
                    let dist = (gx * gx + gy * gy).squareRoot()
                    guard dist <= macroRadiusMeters + 1.0 else { continue }
                    M_ray.append(RayStep(dx: dx, dy: dy, invDistance: 1 / dist))
                    lastMacro = (dx, dy)
                    reach = max(reach, Int(abs(dx)), Int(abs(dy)))
                }
            }
            macroRays.append(M_ray)
        }

        let microLongest = max(microRays.map(\.count).max() ?? 0, 1)
        let macroLongest = max(macroRays.map(\.count).max() ?? 0, 1)

        var flat: [RayStep] = []
        flat.reserveCapacity(n * (microLongest + macroLongest))

        for r in 0..<n {
            let mRay = microRays[r]
            if mRay.isEmpty {
                flat.append(contentsOf: repeatElement(RayStep(dx: 0, dy: 0, invDistance: 0), count: microLongest))
            } else {
                flat.append(contentsOf: mRay)
                flat.append(contentsOf: repeatElement(mRay[mRay.count - 1], count: microLongest - mRay.count))
            }

            let M_ray = macroRays[r]
            if M_ray.isEmpty {
                flat.append(contentsOf: repeatElement(RayStep(dx: 0, dy: 0, invDistance: 0), count: macroLongest))
            } else {
                flat.append(contentsOf: M_ray)
                flat.append(contentsOf: repeatElement(M_ray[M_ray.count - 1], count: macroLongest - M_ray.count))
            }
        }

        self.rayCount = n
        self.microStepsPerRay = microLongest
        self.macroStepsPerRay = macroLongest
        self.steps = flat
        self.maxReach = reach
    }
}

/// Gaussian taps for the separable LRM low-pass along one axis.
public nonisolated struct GaussianTaps: Sendable, Equatable {
    public let radius: Int
    /// `weights[|offset|]`, radius + 1 entries.
    public let weights: [Float]

    /// Radius `radiusMeters` along an axis with `cellSize`-metre cells, sigma
    /// half the radius.
    public init(radiusMeters: Float, cellSize: Float) {
        let radius = max(Int((radiusMeters / max(cellSize, 1e-6)).rounded()), 1)
        let sigma = Float(radius) / 2
        let inverseTwoSigmaSq = 1 / (2 * sigma * sigma)
        self.radius = radius
        self.weights = (0...radius).map { exp(-Float($0 * $0) * inverseTwoSigmaSq) }
    }
}

// MARK: - CPU reference

/// CPU implementations mirroring each micro-topography kernel.
///
/// Two jobs: they are the ground truth the harness compares the GPU against,
/// and they are the fallback for a device without a usable Metal pipeline.
/// They follow the kernels' arithmetic step for step (same taps, same ray
/// tables, same void rules) rather than a textbook formulation, so a mismatch
/// always means a GPU bug rather than a difference of method.
public nonisolated enum MicroTopographyReference {

    public static let validElevationRange: ClosedRange<Float> = -11_000...9_000

    // MARK: Nodata

    public static func normalizeNoData(_ samples: inout [Float], noDataValue: Float?) {
        for i in samples.indices {
            let z = samples[i]
            if !z.isFinite || !validElevationRange.contains(z) || (noDataValue != nil && z == noDataValue) {
                samples[i] = .nan
            }
        }
    }

    // MARK: Helpers

    @inline(__always)
    static func hornGradient(
        _ z: [Float], _ g: RasterGeometry, x: Int, y: Int
    ) -> (dzdx: Float, dzdn: Float)? {
        guard x >= 1, y >= 1, x + 1 < g.width, y + 1 < g.height else { return nil }
        let w = g.width
        let a = z[(y - 1) * w + x - 1], b = z[(y - 1) * w + x], c = z[(y - 1) * w + x + 1]
        let d = z[y * w + x - 1], e = z[y * w + x], f = z[y * w + x + 1]
        let gg = z[(y + 1) * w + x - 1], h = z[(y + 1) * w + x], i = z[(y + 1) * w + x + 1]
        if a.isNaN || b.isNaN || c.isNaN || d.isNaN || e.isNaN || f.isNaN || gg.isNaN || h.isNaN || i.isNaN {
            return nil
        }
        let inv8X = 1 / (8 * g.cellSizeX)
        let inv8Y = 1 / (8 * g.cellSizeY)
        return (((c + 2 * f + i) - (a + 2 * d + gg)) * inv8X, ((a + 2 * b + c) - (gg + 2 * h + i)) * inv8Y)
    }

    public static func slopeDegrees(_ z: [Float], _ g: RasterGeometry) -> [Float] {
        var out = [Float](repeating: .nan, count: g.count)
        for y in 0..<g.height {
            for x in 0..<g.width {
                if let grad = hornGradient(z, g, x: x, y: y) {
                    out[y * g.width + x] = atan((grad.dzdx * grad.dzdx + grad.dzdn * grad.dzdn).squareRoot()) * 180 / .pi
                }
            }
        }
        return out
    }

    /// A reference elevation for the LRM sums: the mean of up to 4,096 evenly
    /// strided samples that hold real terrain.
    ///
    /// Sentinels are excluded by range, not just NaN, because on the zero-copy
    /// path this runs on the CPU *before* the GPU has normalised them.
    public static func referenceElevation(_ z: [Float]) -> Float {
        z.withUnsafeBytes { referenceElevation(UnsafeRawBufferPointer($0)) }
    }

    public static func referenceElevation(_ bytes: UnsafeRawBufferPointer) -> Float {
        let count = bytes.count / MemoryLayout<Float>.stride
        guard count > 0 else { return 0 }
        var sum = 0.0
        var valid = 0
        let stride = max(count / 4096, 1)
        for i in Swift.stride(from: 0, to: count, by: stride) {
            let v = bytes.load(fromByteOffset: i * MemoryLayout<Float>.stride, as: Float.self)
            guard v.isFinite, validElevationRange.contains(v) else { continue }
            sum += Double(v)
            valid += 1
        }
        return valid > 0 ? Float(sum / Double(valid)) : 0
    }

    /// Radial step of the viewshed sweep: one cell, but never more than 4,096
    /// steps per ray, which bounds the horizon table at 5 km on fine rasters.
    public static func viewshedStepMeters(_ g: RasterGeometry, maxRadiusMeters: Float) -> Float {
        max(min(g.cellSizeX, g.cellSizeY), maxRadiusMeters / 4096)
    }

    // MARK: A. Local Relief Model

    /// `dh = z - lowpass` over the destination window, metres (NaN at voids).
    public static func localRelief(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, radiusMeters: Float
    ) -> [Float] {
        let tapsX = GaussianTaps(radiusMeters: radiusMeters, cellSize: g.cellSizeX)
        let tapsY = GaussianTaps(radiusMeters: radiusMeters, cellSize: g.cellSizeY)
        let reference = referenceElevation(z)
        var sums = [SIMD2<Float>](repeating: .zero, count: g.count)
        for y in 0..<g.height {
            for x in 0..<g.width {
                var s: Float = 0, w: Float = 0
                for xx in max(x - tapsX.radius, 0)...min(x + tapsX.radius, g.width - 1) {
                    let v = z[y * g.width + xx]
                    if v.isNaN { continue }
                    let weight = tapsX.weights[abs(xx - x)]
                    s += weight * (v - reference)
                    w += weight
                }
                sums[y * g.width + x] = SIMD2(s, w)
            }
        }
        var out = [Float](repeating: .nan, count: window.count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let x = wx + window.originX, y = wy + window.originY
                var num: Float = 0, den: Float = 0
                for yy in max(y - tapsY.radius, 0)...min(y + tapsY.radius, g.height - 1) {
                    let s = sums[yy * g.width + x]
                    let weight = tapsY.weights[abs(yy - y)]
                    num += weight * s.x
                    den += weight * s.y
                }
                let v = z[y * g.width + x]
                guard den > 0, !v.isNaN else { continue }
                out[wy * window.width + wx] = (v - reference) - num / den
            }
        }
        return out
    }

    // MARK: B. RRIM / C. SVF

    /// Differential openness `(Phi - Psi) / 2` in degrees, and slope in degrees,
    /// over the window. NaN where the Horn window is incomplete or the cell is void.
    public static func differentialOpenness(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, rays: RayTable
    ) -> (differential: [Float], slope: [Float]) {
        var differential = [Float](repeating: .nan, count: window.count)
        var slope = [Float](repeating: .nan, count: window.count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let cx = wx + window.originX, cy = wy + window.originY
                let z0 = z[cy * g.width + cx]
                guard !z0.isNaN, let grad = hornGradient(z, g, x: cx, y: cy) else { continue }
                var sumPhi: Float = 0, sumPsi: Float = 0
                for r in 0..<rays.rayCount {
                    var maxUp = -Float.greatestFiniteMagnitude
                    var maxDown = -Float.greatestFiniteMagnitude
                    for s in 0..<rays.stepsPerRay {
                        let step = rays.steps[r * rays.stepsPerRay + s]
                        let sx = cx + Int(step.dx), sy = cy + Int(step.dy)
                        if sx < 0 || sy < 0 || sx >= g.width || sy >= g.height { break }
                        let v = z[sy * g.width + sx]
                        if v.isNaN { continue }
                        let t = (v - z0) * step.invDistance
                        maxUp = max(maxUp, t)
                        maxDown = max(maxDown, -t)
                    }
                    let beta = maxUp > -Float.greatestFiniteMagnitude ? atan(maxUp) : 0
                    let delta = maxDown > -Float.greatestFiniteMagnitude ? atan(maxDown) : 0
                    sumPhi += .pi / 2 - beta
                    sumPsi += .pi / 2 - delta
                }
                let n = Float(rays.rayCount)
                let i = wy * window.width + wx
                differential[i] = (sumPhi / n - sumPsi / n) * 180 / .pi * 0.5
                slope[i] = atan((grad.dzdx * grad.dzdx + grad.dzdn * grad.dzdn).squareRoot()) * 180 / .pi
            }
        }
        return (differential, slope)
    }

    /// The RRIM colour for one cell, as the kernel computes it (straight RGB, 0...1).
    public static func rrimColor(
        slopeDegrees: Float, differential: Float, options: MicroTopographyOptions
    ) -> SIMD3<Float> {
        let saturation = min(max(slopeDegrees / max(options.rrimSlopeSaturationDegrees, 0.001) * options.slopeMultiplier, 0), 1)
        let value = min(max(0.5 + 0.5 * differential / max(options.rrimOpennessRangeDegrees, 0.001), 0), 1)
        return SIMD3(value, value * (1 - saturation), value * (1 - saturation))
    }

    public static func skyViewFactor(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, rays: RayTable
    ) -> [Float] {
        var out = [Float](repeating: .nan, count: window.count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let cx = wx + window.originX, cy = wy + window.originY
                let z0 = z[cy * g.width + cx]
                guard !z0.isNaN else { continue }
                var sumSin: Float = 0
                for r in 0..<rays.rayCount {
                    var maxTangent: Float = 0
                    for s in 0..<rays.stepsPerRay {
                        let step = rays.steps[r * rays.stepsPerRay + s]
                        let sx = cx + Int(step.dx), sy = cy + Int(step.dy)
                        if sx < 0 || sy < 0 || sx >= g.width || sy >= g.height { break }
                        let v = z[sy * g.width + sx]
                        if v.isNaN { continue }
                        maxTangent = max(maxTangent, (v - z0) * step.invDistance)
                    }
                    sumSin += maxTangent / (1 + maxTangent * maxTangent).squareRoot()
                }
                out[wy * window.width + wx] = 1 - sumSin / Float(rays.rayCount)
            }
        }
        return out
    }

    /// Dual-radius multi-scale sky-view factor combining micro and macro radii.
    public static func skyViewFactor(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, rays: DualRadiusRayTable, blendWeight: Float = 0.65
    ) -> [Float] {
        var out = [Float](repeating: .nan, count: window.count)
        let stride = rays.microStepsPerRay + rays.macroStepsPerRay
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let cx = wx + window.originX, cy = wy + window.originY
                let z0 = z[cy * g.width + cx]
                guard !z0.isNaN else { continue }
                var sumSinMicro: Float = 0
                var sumSinMacro: Float = 0
                for r in 0..<rays.rayCount {
                    var maxTangentMicro: Float = 0
                    let base = r * stride
                    for s in 0..<rays.microStepsPerRay {
                        let step = rays.steps[base + s]
                        if step.invDistance <= 0 { continue }
                        let sx = cx + Int(step.dx), sy = cy + Int(step.dy)
                        if sx < 0 || sy < 0 || sx >= g.width || sy >= g.height { break }
                        let v = z[sy * g.width + sx]
                        if v.isNaN { continue }
                        maxTangentMicro = max(maxTangentMicro, (v - z0) * step.invDistance)
                    }
                    var maxTangentMacro = maxTangentMicro
                    if rays.macroStepsPerRay > 0 && blendWeight < 1.0 {
                        for s in 0..<rays.macroStepsPerRay {
                            let step = rays.steps[base + rays.microStepsPerRay + s]
                            if step.invDistance <= 0 { continue }
                            let sx = cx + Int(step.dx), sy = cy + Int(step.dy)
                            if sx < 0 || sy < 0 || sx >= g.width || sy >= g.height { break }
                            let v = z[sy * g.width + sx]
                            if v.isNaN { continue }
                            maxTangentMacro = max(maxTangentMacro, (v - z0) * step.invDistance)
                        }
                    }
                    sumSinMicro += maxTangentMicro / (1 + maxTangentMicro * maxTangentMicro).squareRoot()
                    sumSinMacro += maxTangentMacro / (1 + maxTangentMacro * maxTangentMacro).squareRoot()
                }
                let svfMicro = 1 - sumSinMicro / Float(rays.rayCount)
                let svfMacro = 1 - sumSinMacro / Float(rays.rayCount)
                out[wy * window.width + wx] = blendWeight * svfMicro + (1 - blendWeight) * svfMacro
            }
        }
        return out
    }

    // MARK: D. Raking light

    public static func rakingHillshade(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, options: MicroTopographyOptions
    ) -> [Float] {
        let az = options.sunAzimuthDegrees * .pi / 180
        let alt = options.sunAltitudeDegrees * .pi / 180
        let light = SIMD3<Float>(cos(alt) * sin(az), cos(alt) * cos(az), sin(alt))
        var out = [Float](repeating: .nan, count: window.count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                guard let grad = hornGradient(z, g, x: wx + window.originX, y: wy + window.originY) else { continue }
                let normal = simd_normalize(SIMD3(-grad.dzdx * options.zFactor, -grad.dzdn * options.zFactor, 1))
                out[wy * window.width + wx] = options.ambient + (1 - options.ambient) * max(0, simd_dot(normal, light))
            }
        }
        return out
    }

    // MARK: F. Relative elevation

    public static func thalwegSurface(at p: SIMD2<Float>, thalweg: [ThalwegVertex], power: Float, minimumDistance: Float) -> Float {
        let segments = ThalwegSegment.makeSegments(from: thalweg)
        return thalwegSurface(at: p, segments: segments, power: power, minimumDistance: minimumDistance, fallbackWaterSurface: thalweg.first?.waterSurface ?? .nan)
    }

    public static func thalwegSurface(
        at p: SIMD2<Float>,
        segments: [ThalwegSegment],
        power: Float,
        minimumDistance: Float,
        fallbackWaterSurface: Float
    ) -> Float {
        guard !segments.isEmpty else { return fallbackWaterSurface }

        var minDistance: Float = 1e30
        var bestWaterSurface = segments[0].startWaterSurface

        for k in 0..<segments.count {
            let a = segments[k].start
            let b = segments[k].end
            let v = b - a
            let u = p - a
            let lenSq = simd_dot(v, v)
            var t: Float = 0
            var proj = a
            var ws = segments[k].startWaterSurface
            if lenSq >= 1e-8 {
                t = min(max(simd_dot(u, v) / lenSq, 0), 1)
                proj = a + t * v
                ws = segments[k].startWaterSurface + t * (segments[k].endWaterSurface - segments[k].startWaterSurface)
            }
            let d = simd_distance(p, proj)
            if d < minDistance {
                minDistance = d
                bestWaterSurface = ws
            }
        }

        if segments.count == 1 {
            return bestWaterSurface
        }

        // Banded distance blending (B = 25 m): blends segments within minDistance + B
        let bandMeters: Float = 25.0
        var sumWeights: Float = 0.0
        var blendedWS: Float = 0.0

        for k in 0..<segments.count {
            let a = segments[k].start
            let b = segments[k].end
            let v = b - a
            let u = p - a
            let lenSq = simd_dot(v, v)
            let t = lenSq >= 1e-8 ? min(max(simd_dot(u, v) / lenSq, 0), 1) : 0
            let proj = a + t * v
            let d = simd_distance(p, proj)
            if d <= minDistance + bandMeters {
                let diff = d - minDistance
                let factor = max(1.0 - diff / bandMeters, 0.0)
                let w = factor * factor
                let ws = segments[k].startWaterSurface + t * (segments[k].endWaterSurface - segments[k].startWaterSurface)
                blendedWS += w * ws
                sumWeights += w
            }
        }

        return sumWeights > 0.0 ? (blendedWS / sumWeights) : bestWaterSurface
    }

    public static func relativeElevation(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, thalweg: [ThalwegVertex], power: Float
    ) -> [Float] {
        var out = [Float](repeating: .nan, count: window.count)
        let minimumDistance = max(min(g.cellSizeX, g.cellSizeY), 0.001)
        let segments = ThalwegSegment.makeSegments(from: thalweg)
        let fallback = thalweg.first?.waterSurface ?? .nan
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let x = wx + window.originX, y = wy + window.originY
                let v = z[y * g.width + x]
                guard !v.isNaN else { continue }
                let p = SIMD2(Float(x) * g.cellSizeX, Float(y) * g.cellSizeY)
                let stream = thalwegSurface(at: p, segments: segments, power: power, minimumDistance: minimumDistance, fallbackWaterSurface: fallback)
                guard !stream.isNaN else { continue }
                out[wy * window.width + wx] = v - stream
            }
        }
        return out
    }

    // MARK: G. Habitation potential

    /// Brute-force disk search: the ground truth the jump-flood kernel must match.
    public static func habitationMask(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow, options: MicroTopographyOptions
    ) -> [Bool] {
        let slope = slopeDegrees(z, g)
        let reachX = Int((options.habitationRadiusMeters / g.cellSizeX).rounded(.down))
        let reachY = Int((options.habitationRadiusMeters / g.cellSizeY).rounded(.down))
        let radiusSq = options.habitationRadiusMeters * options.habitationRadiusMeters
        var out = [Bool](repeating: false, count: window.count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let x = wx + window.originX, y = wy + window.originY
                let s = slope[y * g.width + x]
                guard !s.isNaN, s <= options.flatSlopeMaximumDegrees else { continue }
                var found = false
                search: for yy in max(y - reachY, 0)...min(y + reachY, g.height - 1) {
                    for xx in max(x - reachX, 0)...min(x + reachX, g.width - 1) {
                        let dx = Float(xx - x) * g.cellSizeX, dy = Float(yy - y) * g.cellSizeY
                        guard dx * dx + dy * dy <= radiusSq else { continue }
                        let neighbour = slope[yy * g.width + xx]
                        if !neighbour.isNaN, neighbour >= options.steepSlopeMinimumDegrees {
                            found = true
                            break search
                        }
                    }
                }
                out[wy * window.width + wx] = found
            }
        }
        return out
    }

    // MARK: Viewshed

    /// The radial-sweep viewshed, on the CPU, with the kernel's exact sampling.
    public static func viewshed(
        _ z: [Float], _ g: RasterGeometry, observerX: Float, observerY: Float,
        eyeHeight: Float, targetHeight: Float, maxRadiusMeters: Float, angularSteps: Int
    ) -> [Bool]? {
        guard let ground = bilinear(z, g, x: observerX, y: observerY) else { return nil }
        let eye = ground + eyeHeight
        let stepMeters = viewshedStepMeters(g, maxRadiusMeters: maxRadiusMeters)
        let radialSteps = max(Int((maxRadiusMeters / stepMeters).rounded(.up)), 1)
        var horizon = [Float](repeating: 0, count: angularSteps * radialSteps)
        for ray in 0..<angularSteps {
            let theta = Float(ray) * 2 * .pi / Float(angularSteps)
            let perX = sin(theta) * stepMeters / g.cellSizeX
            let perY = -cos(theta) * stepMeters / g.cellSizeY
            var maxTangent = -Float.greatestFiniteMagnitude
            var offGrid = false
            for k in 0..<radialSteps {
                horizon[ray * radialSteps + k] = maxTangent
                if offGrid { continue }
                let index = Float(k + 1)
                let x = observerX + perX * index, y = observerY + perY * index
                if x < 0 || y < 0 || x > Float(g.width - 1) || y > Float(g.height - 1) {
                    offGrid = true
                    continue
                }
                guard let v = bilinear(z, g, x: x, y: y) else { continue }
                maxTangent = max(maxTangent, (v - eye) / (index * stepMeters))
            }
        }
        var out = [Bool](repeating: false, count: g.count)
        for y in 0..<g.height {
            for x in 0..<g.width {
                let dx = (Float(x) - observerX) * g.cellSizeX
                let dy = (Float(y) - observerY) * g.cellSizeY
                let d = (dx * dx + dy * dy).squareRoot()
                guard d <= maxRadiusMeters else { continue }
                if d < 0.5 * stepMeters { out[y * g.width + x] = true; continue }
                let v = z[y * g.width + x]
                guard !v.isNaN else { continue }
                let north = (observerY - Float(y)) * g.cellSizeY
                var azimuth = abs(north) < 1e-6 ? (dx > 0 ? .pi / 2 : 1.5 * .pi) : atan2(dx, north)
                if azimuth < 0 { azimuth += 2 * .pi }
                let ray = Int((azimuth / (2 * .pi) * Float(angularSteps)).rounded()) % angularSteps
                let k = Int((d / stepMeters - 0.5).rounded(.down))
                let horizonTangent = k >= 0 ? horizon[ray * radialSteps + min(k, radialSteps - 1)] : -Float.greatestFiniteMagnitude
                out[y * g.width + x] = (v + targetHeight - eye) / d > horizonTangent
            }
        }
        return out
    }

    public static func bilinear(_ z: [Float], _ g: RasterGeometry, x: Float, y: Float) -> Float? {
        guard x >= 0, y >= 0, x <= Float(g.width - 1), y <= Float(g.height - 1) else { return nil }
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, g.width - 1), y1 = min(y0 + 1, g.height - 1)
        let v00 = z[y0 * g.width + x0], v10 = z[y0 * g.width + x1]
        let v01 = z[y1 * g.width + x0], v11 = z[y1 * g.width + x1]
        if v00.isNaN || v10.isNaN || v01.isNaN || v11.isNaN { return nil }
        let fx = x - Float(x0), fy = y - Float(y0)
        let top = v00 + (v10 - v00) * fx
        let bottom = v01 + (v11 - v01) * fx
        return top + (bottom - top) * fy
    }

    // MARK: - Zevenbergen & Thorne Curvature Reference

    /// Profile curvature (k_prof) and planform curvature (k_plan) in radians/meter
    /// using a 3x3 second-order polynomial surface fit (Zevenbergen & Thorne 1987).
    public static func topographicCurvature(
        _ z: [Float], _ g: RasterGeometry, window: DestinationWindow
    ) -> (profile: [Float], planform: [Float]) {
        var prof = [Float](repeating: .nan, count: window.count)
        var plan = [Float](repeating: .nan, count: window.count)
        let Lx = g.cellSizeX
        let Ly = g.cellSizeY
        let Lx2 = Lx * Lx
        let Ly2 = Ly * Ly

        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let cx = wx + window.originX
                let cy = wy + window.originY
                if cx < 1 || cy < 1 || cx + 1 >= g.width || cy + 1 >= g.height { continue }

                let z1 = z[(cy - 1) * g.width + (cx - 1)]
                let z2 = z[(cy - 1) * g.width + cx]
                let z3 = z[(cy - 1) * g.width + (cx + 1)]
                let z4 = z[cy * g.width + (cx - 1)]
                let z5 = z[cy * g.width + cx]
                let z6 = z[cy * g.width + (cx + 1)]
                let z7 = z[(cy + 1) * g.width + (cx - 1)]
                let z8 = z[(cy + 1) * g.width + cx]
                let z9 = z[(cy + 1) * g.width + (cx + 1)]

                if z1.isNaN || z2.isNaN || z3.isNaN || z4.isNaN || z5.isNaN ||
                    z6.isNaN || z7.isNaN || z8.isNaN || z9.isNaN {
                    continue
                }

                let D = (z4 + z6 - 2.0 * z5) / (2.0 * Lx2)
                let E = (z2 + z8 - 2.0 * z5) / (2.0 * Ly2)
                let F = (z3 + z7 - z1 - z9) / (4.0 * Lx * Ly)
                let G = (z6 - z4) / (2.0 * Lx)
                let H = (z2 - z8) / (2.0 * Ly)

                let slopeSq = G * G + H * H
                var kProf: Float = 0
                var kTan: Float = 0

                if slopeSq >= 1e-6 {
                    let term = 1.0 + slopeSq
                    let sqrtTerm = term.squareRoot()
                    let denomProf = slopeSq * term * sqrtTerm
                    let denomTan = slopeSq * sqrtTerm
                    kProf = -2.0 * (D * G * G + E * H * H + F * G * H) / denomProf
                    kTan = -2.0 * (E * G * G + D * H * H - F * G * H) / denomTan
                }

                let idx = wy * window.width + wx
                prof[idx] = kProf
                plan[idx] = kTan
            }
        }
        return (prof, plan)
    }

    /// One colour channel of a layer blend, on 0...1 values: `cs` composited over `cb` by `mode`, then mixed back
    /// toward `cb` by `opacity` (clamped to 0...1; NaN counts as none), so opacity 0 returns `cb` exactly. The
    /// formulas are the W3C compositing ones, and what `blend_relief_layers` computes.
    public static func blend(base cb: Float, modulation cs: Float, mode: RasterBlendMode, opacity: Float) -> Float {
        let weight = opacity.isNaN ? 0 : min(max(opacity, 0), 1)
        let blended: Float
        switch mode {
        case .multiply:
            blended = cb * cs
        case .screen:
            blended = cb + cs - cb * cs
        case .overlay:
            blended = cb <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
        case .softLight:
            if cs <= 0.5 {
                blended = cb - (1 - 2 * cs) * cb * (1 - cb)
            } else {
                let curve = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : cb.squareRoot()
                blended = cb + (2 * cs - 1) * (curve - cb)
            }
        }
        return cb + (blended - cb) * weight
    }
}

// MARK: - Palettes

/// Colour ramps for the micro-topography products that use a palette texture.
public nonisolated enum MicroTopographyPalettes {

    /// Banded REM tint over `range`, as 256 straight-alpha RGBA texels.
    ///
    /// Stops are placed in metres rather than in palette fractions, so levees
    /// (+2..+5 m) keep their saturated band whatever range the user picks, and
    /// everything at or below the water surface reads as water-blue.
    public static func relativeElevationTexels(range: ClosedRange<Float>) -> [UInt8] {
        let stops: [(Float, SIMD3<Float>)] = [
            (-6, SIMD3(8, 29, 88)),
            (-1.5, SIMD3(34, 94, 168)),
            (0, SIMD3(65, 182, 196)),
            (0.01, SIMD3(199, 233, 180)),
            (2, SIMD3(237, 248, 177)),
            (2.01, SIMD3(254, 217, 118)),
            (5, SIMD3(240, 59, 32)),
            (5.01, SIMD3(189, 170, 150)),
            (12, SIMD3(240, 236, 230)),
        ]
        var texels = [UInt8](repeating: 255, count: 256 * 4)
        let span = max(range.upperBound - range.lowerBound, 0.001)
        for i in 0...255 {
            let meters = range.lowerBound + span * Float(i) / 255
            var color = stops[stops.count - 1].1
            if meters <= stops[0].0 {
                color = stops[0].1
            } else {
                for k in 0..<(stops.count - 1) where meters >= stops[k].0 && meters <= stops[k + 1].0 {
                    let t = (meters - stops[k].0) / max(stops[k + 1].0 - stops[k].0, 0.0001)
                    color = stops[k].1 + (stops[k + 1].1 - stops[k].1) * t
                    break
                }
            }
            texels[i * 4] = UInt8(min(max(color.x, 0), 255))
            texels[i * 4 + 1] = UInt8(min(max(color.y, 0), 255))
            texels[i * 4 + 2] = UInt8(min(max(color.z, 0), 255))
            texels[i * 4 + 3] = 235
        }
        return texels
    }
}
