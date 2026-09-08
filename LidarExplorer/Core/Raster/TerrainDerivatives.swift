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

public nonisolated enum TerrainAnalysis {
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
        let degToRad: Float = .pi / 180.0

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

                                        let sRad = slopeVal * degToRad
                                        let aRad = deg * degToRad
                                        var sinS: Float = 0, cosS: Float = 0
                                        __sincosf(sRad, &sinS, &cosS)
                                        var sinA: Float = 0, cosA: Float = 0
                                        __sincosf(aRad, &sinA, &cosA)

                                        nzPtr[idx] = cosS
                                        nyPtr[idx] = sinS * cosA
                                        nxPtr[idx] = sinS * sinA
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

        // Vectorized fallback for non-cached normals
        let degToRad: Float = .pi / 180
        return [Float](unsafeUninitializedCapacity: count) { outBuf, initializedCount in
            guard let outPtr = outBuf.baseAddress else { return }
            derivatives.slopeDegrees.withUnsafeBufferPointer { sBuf in
                derivatives.aspectDegrees.withUnsafeBufferPointer { aBuf in
                    guard let sPtr = sBuf.baseAddress, let aPtr = aBuf.baseAddress else { return }
                    for i in 0..<count {
                        let sDeg = sPtr[i]
                        let aDeg = aPtr[i]
                        if sDeg.isNaN || aDeg.isNaN {
                            outPtr[i] = .nan
                            continue
                        }
                        let s = sDeg * degToRad
                        let a = aDeg * degToRad
                        var sinS: Float = 0, cosS: Float = 0
                        __sincosf(s, &sinS, &cosS)
                        var sinA: Float = 0, cosA: Float = 0
                        __sincosf(a, &sinA, &cosA)
                        let cosDiff = cosLightAzimuth * cosA + sinLightAzimuth * sinA
                        let value = cosZenith * cosS + sinZenith * sinS * cosDiff
                        outPtr[i] = max(0, min(1, value))
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
