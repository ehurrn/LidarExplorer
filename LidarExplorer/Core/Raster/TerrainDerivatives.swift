//
//  TerrainDerivatives.swift
//  LidarExplorer
//
//  Slope, aspect, and hillshade over an ElevationGrid.
//

import Accelerate
import Foundation
import simd

public nonisolated struct TerrainDerivatives: Sendable {
    public let slopeDegrees: [Float]
    public let aspectDegrees: [Float]
    public let width: Int
    public let height: Int

    // Precomputed unit surface normal components (Nx, Ny, Nz)
    public let normalX: [Float]?
    public let normalY: [Float]?
    public let normalZ: [Float]?

    public init(
        slopeDegrees: [Float],
        aspectDegrees: [Float],
        width: Int,
        height: Int,
        normalX: [Float]? = nil,
        normalY: [Float]? = nil,
        normalZ: [Float]? = nil
    ) {
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
        self.width = width
        self.height = height
        self.normalX = normalX
        self.normalY = normalY
        self.normalZ = normalZ
    }
}

public nonisolated struct TopographicCurvature: Sendable {
    public let profileCurvature: [Float]   // rad/m, negative = concave, positive = convex
    public let planformCurvature: [Float]  // rad/m, negative = convergent, positive = divergent
    public let width: Int
    public let height: Int

    public init(profileCurvature: [Float], planformCurvature: [Float], width: Int, height: Int) {
        self.profileCurvature = profileCurvature
        self.planformCurvature = planformCurvature
        self.width = width
        self.height = height
    }
}

public nonisolated enum TerrainAnalysis {
    public static func curvature(of grid: ElevationGrid) -> TopographicCurvature {
        let g = RasterGeometry(grid)
        let win = DestinationWindow.full(g)
        let (prof, plan) = MicroTopographyReference.topographicCurvature(grid.samples, g, window: win)
        return TopographicCurvature(profileCurvature: prof, planformCurvature: plan, width: grid.width, height: grid.height)
    }

    public static func derivatives(of grid: ElevationGrid) -> TerrainDerivatives {
        let w = grid.width
        let h = grid.height
        let count = max(w * h, 0)

        guard w >= 3, h >= 3, count > 0 else {
            return TerrainDerivatives(
                slopeDegrees: [Float](repeating: .nan, count: count),
                aspectDegrees: [Float](repeating: .nan, count: count),
                width: w, height: h
            )
        }

        let cellX = Float(grid.metersPerColumn)
        let cellY = Float(grid.metersPerRow)
        guard cellX > 0, cellY > 0 else {
            return TerrainDerivatives(
                slopeDegrees: [Float](repeating: .nan, count: count),
                aspectDegrees: [Float](repeating: .nan, count: count),
                width: w, height: h
            )
        }

        let inv8CellX: Float = 1.0 / (8.0 * cellX)
        let inv8CellY: Float = 1.0 / (8.0 * cellY)
        let radToDeg: Float = 180.0 / .pi

        var slope = [Float](repeating: .nan, count: count)
        var aspect = [Float](repeating: .nan, count: count)
        var nx = [Float](repeating: .nan, count: count)
        var ny = [Float](repeating: .nan, count: count)
        var nz = [Float](repeating: .nan, count: count)

        grid.withUnsafeSamples { src in
            slope.withUnsafeMutableBufferPointer { slopeOut in
                aspect.withUnsafeMutableBufferPointer { aspectOut in
                    nx.withUnsafeMutableBufferPointer { nxOut in
                        ny.withUnsafeMutableBufferPointer { nyOut in
                            nz.withUnsafeMutableBufferPointer { nzOut in
                                guard let sPtr = slopeOut.baseAddress,
                                      let aPtr = aspectOut.baseAddress,
                                      let nxPtr = nxOut.baseAddress,
                                      let nyPtr = nyOut.baseAddress,
                                      let nzPtr = nzOut.baseAddress,
                                      let srcPtr = src.baseAddress else { return }

                                for y in 1..<(h - 1) {
                                    let rowAbove = (y - 1) * w
                                    let row = y * w
                                    let rowBelow = (y + 1) * w

                                    for x in 1..<(w - 1) {
                                        let a = srcPtr[rowAbove + x - 1], b = srcPtr[rowAbove + x], c = srcPtr[rowAbove + x + 1]
                                        let d = srcPtr[row + x - 1], center = srcPtr[row + x], f = srcPtr[row + x + 1]
                                        let g = srcPtr[rowBelow + x - 1], hh = srcPtr[rowBelow + x], i = srcPtr[rowBelow + x + 1]

                                        if center.isNaN || a.isNaN || b.isNaN || c.isNaN || d.isNaN
                                            || f.isNaN || g.isNaN || hh.isNaN || i.isNaN {
                                            continue
                                        }

                                        let dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) * inv8CellX
                                        let dzdy = ((g + 2 * hh + i) - (a + 2 * b + c)) * inv8CellY
                                        let rise = (dzdx * dzdx + dzdy * dzdy).squareRoot()
                                        let slopeVal = atan(rise) * radToDeg

                                        var deg: Float = 0
                                        if dzdx != 0 || dzdy != 0 {
                                            deg = 90 - atan2(dzdy, -dzdx) * radToDeg
                                            if deg < 0 { deg += 360 }
                                            if deg >= 360 { deg -= 360 }
                                        }

                                        let idx = row + x
                                        sPtr[idx] = slopeVal
                                        aPtr[idx] = deg

                                        let invNorm = 1.0 / (rise * rise + 1.0).squareRoot()
                                        nzPtr[idx] = invNorm
                                        nyPtr[idx] = dzdy * invNorm
                                        nxPtr[idx] = -dzdx * invNorm
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return TerrainDerivatives(
            slopeDegrees: slope,
            aspectDegrees: aspect,
            width: w,
            height: h,
            normalX: nx,
            normalY: ny,
            normalZ: nz
        )
    }

    public static func hillshade(
        _ derivatives: TerrainDerivatives,
        azimuthDegrees: Double = 315,
        altitudeDegrees: Double = 45
    ) -> [Float] {
        let count = derivatives.slopeDegrees.count
        guard count > 0 else { return [] }

        let zenith = Float((90 - altitudeDegrees) * .pi / 180)
        let lightAzimuth = Float(azimuthDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180)

        let cosZenith = cos(zenith)
        let sinZenith = sin(zenith)
        let cosLightAzimuth = cos(lightAzimuth)
        let sinLightAzimuth = sin(lightAzimuth)

        let lx = sinZenith * sinLightAzimuth
        let ly = sinZenith * cosLightAzimuth
        let lz = cosZenith

        if let nx = derivatives.normalX,
           let ny = derivatives.normalY,
           let nz = derivatives.normalZ {
            return [Float](unsafeUninitializedCapacity: count) { outBuf, initializedCount in
                guard let outPtr = outBuf.baseAddress else { return }

                nx.withUnsafeBufferPointer { nxBuf in
                    ny.withUnsafeBufferPointer { nyBuf in
                        nz.withUnsafeBufferPointer { nzBuf in
                            guard let nxP = nxBuf.baseAddress,
                                  let nyP = nyBuf.baseAddress,
                                  let nzP = nzBuf.baseAddress else { return }

                            var i = 0
                            let simdCount = count - (count % 8)
                            while i < simdCount {
                                let xVec = UnsafeRawPointer(nxP + i).loadUnaligned(as: SIMD8<Float>.self)
                                let yVec = UnsafeRawPointer(nyP + i).loadUnaligned(as: SIMD8<Float>.self)
                                let zVec = UnsafeRawPointer(nzP + i).loadUnaligned(as: SIMD8<Float>.self)

                                let dot = zVec * lz + yVec * ly + xVec * lx
                                let clamped = simd_clamp(dot, SIMD8<Float>(repeating: 0), SIMD8<Float>(repeating: 1))

                                for lane in 0..<8 {
                                    let idx = i + lane
                                    if zVec[lane].isNaN {
                                        outPtr[idx] = .nan
                                    } else {
                                        outPtr[idx] = clamped[lane]
                                    }
                                }
                                i += 8
                            }

                            while i < count {
                                let z = nzP[i]
                                if z.isNaN {
                                    outPtr[i] = .nan
                                } else {
                                    let dot = z * lz + nyP[i] * ly + nxP[i] * lx
                                    outPtr[i] = max(0, min(1, dot))
                                }
                                i += 1
                            }
                        }
                    }
                }
                initializedCount = count
            }
        }

        // Vectorized fallback for non-cached normals using Accelerate vDSP and vForce
        let chunkSize = 1024
        var degToRad: Float = .pi / 180.0
        return [Float](unsafeUninitializedCapacity: count) { outBuf, initializedCount in
            guard let outPtr = outBuf.baseAddress else { return }
            derivatives.slopeDegrees.withUnsafeBufferPointer { sBuf in
                derivatives.aspectDegrees.withUnsafeBufferPointer { aBuf in
                    guard let sPtr = sBuf.baseAddress, let aPtr = aBuf.baseAddress else { return }

                    withUnsafeTemporaryAllocation(of: Float.self, capacity: chunkSize * 6) { temp in
                        guard let base = temp.baseAddress else { return }
                        let sRadChunk = base
                        let aRadChunk = base + chunkSize
                        let sinSChunk = base + chunkSize * 2
                        let cosSChunk = base + chunkSize * 3
                        let sinAChunk = base + chunkSize * 4
                        let cosAChunk = base + chunkSize * 5

                        var offset = 0
                        while offset < count {
                            let currentChunk = min(chunkSize, count - offset)
                            var n32 = Int32(currentChunk)

                            vDSP_vsmul(sPtr + offset, 1, &degToRad, sRadChunk, 1, vDSP_Length(currentChunk))
                            vDSP_vsmul(aPtr + offset, 1, &degToRad, aRadChunk, 1, vDSP_Length(currentChunk))

                            vvsincosf(sinSChunk, cosSChunk, sRadChunk, &n32)
                            vvsincosf(sinAChunk, cosAChunk, aRadChunk, &n32)

                            var j = 0
                            let simdLen = currentChunk - (currentChunk % 8)
                            while j < simdLen {
                                let sinSVec = UnsafeRawPointer(sinSChunk + j).loadUnaligned(as: SIMD8<Float>.self)
                                let cosSVec = UnsafeRawPointer(cosSChunk + j).loadUnaligned(as: SIMD8<Float>.self)
                                let sinAVec = UnsafeRawPointer(sinAChunk + j).loadUnaligned(as: SIMD8<Float>.self)
                                let cosAVec = UnsafeRawPointer(cosAChunk + j).loadUnaligned(as: SIMD8<Float>.self)
                                let sDegVec = UnsafeRawPointer(sPtr + offset + j).loadUnaligned(as: SIMD8<Float>.self)
                                let aDegVec = UnsafeRawPointer(aPtr + offset + j).loadUnaligned(as: SIMD8<Float>.self)

                                let cosDiff = cosLightAzimuth * cosAVec + sinLightAzimuth * sinAVec
                                let valVec = cosZenith * cosSVec + sinZenith * sinSVec * cosDiff
                                let clamped = simd_clamp(valVec, SIMD8<Float>(repeating: 0), SIMD8<Float>(repeating: 1))

                                for lane in 0..<8 {
                                    let idx = offset + j + lane
                                    if sDegVec[lane].isNaN || aDegVec[lane].isNaN {
                                        outPtr[idx] = .nan
                                    } else {
                                        outPtr[idx] = clamped[lane]
                                    }
                                }
                                j += 8
                            }

                            while j < currentChunk {
                                let idx = offset + j
                                let sDeg = sPtr[idx]
                                let aDeg = aPtr[idx]
                                if sDeg.isNaN || aDeg.isNaN {
                                    outPtr[idx] = .nan
                                } else {
                                    let cosDiff = cosLightAzimuth * cosAChunk[j] + sinLightAzimuth * sinAChunk[j]
                                    let val = cosZenith * cosSChunk[j] + sinZenith * sinSChunk[j] * cosDiff
                                    outPtr[idx] = max(0, min(1, val))
                                }
                                j += 1
                            }

                            offset += currentChunk
                        }
                    }
                }
            }
            initializedCount = count
        }
    }

    public static func multiDirectionalRelief(
        _ derivatives: TerrainDerivatives,
        azimuths: [Double] = [45, 135, 225, 315],
        altitudeDegrees: Double = 30
    ) -> [Float] {
        guard azimuths.count > 1 else {
            return [Float](repeating: .nan, count: derivatives.slopeDegrees.count)
        }
        let zenith = Float((90 - altitudeDegrees) * .pi / 180)
        let cosZenith = cos(zenith)
        let sinZenith = sin(zenith)
        let lightAzimuths = azimuths.map {
            Float($0.truncatingRemainder(dividingBy: 360) * .pi / 180)
        }
        let n = Float(lightAzimuths.count)
        let invN = 1.0 / n
        let degToRad: Float = .pi / 180
        let count = derivatives.slopeDegrees.count
        guard count > 0 else { return [] }

        return [Float](unsafeUninitializedCapacity: count) { outBuf, initializedCount in
            let outPtr = outBuf.baseAddress!
            derivatives.slopeDegrees.withUnsafeBufferPointer { sBuf in
                derivatives.aspectDegrees.withUnsafeBufferPointer { aBuf in
                    let sPtr = sBuf.baseAddress!, aPtr = aBuf.baseAddress!
                    for i in 0..<count {
                        let slopeDeg = sPtr[i]
                        let aspectDeg = aPtr[i]
                        if slopeDeg.isNaN || aspectDeg.isNaN { outPtr[i] = .nan; continue }
                        let slope = slopeDeg * degToRad
                        let aspect = aspectDeg * degToRad
                        let baseCos = cosZenith * cos(slope)
                        let baseSin = sinZenith * sin(slope)
                        var sum: Float = 0
                        var sumSquares: Float = 0
                        for lightAzimuth in lightAzimuths {
                            let value = max(0, min(1, baseCos + baseSin * cos(lightAzimuth - aspect)))
                            sum += value
                            sumSquares += value * value
                        }
                        let mean = sum * invN
                        outPtr[i] = max(0, sumSquares * invN - mean * mean).squareRoot()
                    }
                }
            }
            initializedCount = count
        }
    }
}

/// Dynamic topographic contour interval for relief overlay rendering.
public nonisolated enum ContourInterval: String, Sendable, CaseIterable, Identifiable {
    case off = "Off"
    case quarterMeter = "0.25 m"
    case halfMeter = "0.5 m"
    case oneMeter = "1 m"
    case twoMeters = "2 m"
    case fiveMeters = "5 m"
    case tenMeters = "10 m (~33 ft)"
    case twentyFiveMeters = "25 m (~82 ft)"
    case fiftyMeters = "50 m (~164 ft)"

    public var id: String { rawValue }

    public var meters: Float {
        switch self {
        case .off: return 0.0
        case .quarterMeter: return 0.25
        case .halfMeter: return 0.5
        case .oneMeter: return 1.0
        case .twoMeters: return 2.0
        case .fiveMeters: return 5.0
        case .tenMeters: return 10.0
        case .twentyFiveMeters: return 25.0
        case .fiftyMeters: return 50.0
        }
    }

    /// Every Nth line is an index contour: the 0.25 m micro interval indexes
    /// every 2.5 m, the cartographic every-fifth-line convention otherwise.
    public var indexMultiplier: Int { self == .quarterMeter ? 10 : 5 }

    public var indexIntervalMeters: Float { meters * Float(indexMultiplier) }
}
