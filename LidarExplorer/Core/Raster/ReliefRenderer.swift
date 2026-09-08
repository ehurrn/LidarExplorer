//
//  ReliefRenderer.swift
//  LidarExplorer
//
//  Turns float rasters into displayable images.
//

import CoreGraphics
import Foundation
import os

/// How a terrain raster should be shaded for display.
public nonisolated enum ReliefStyle: String, Sendable, CaseIterable, Identifiable {
    /// Classic single-direction Lambertian hillshade.
    case hillshade
    /// Per-cell spread across several illumination directions.
    case multiDirectional
    /// Slope steepness, cool to warm.
    case slope
    /// Hypsometric tint by elevation.
    case elevation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hillshade: "Hillshade"
        case .multiDirectional: "Multi-directional"
        case .slope: "Slope"
        case .elevation: "Elevation"
        }
    }

    /// Whether the light controls affect this style.
    public var usesIllumination: Bool {
        self == .hillshade || self == .multiDirectional
    }
}

extension Data {
    nonisolated init(unsafeUninitializedCapacity byteCount: Int, initializingWith initializer: (inout UnsafeMutableRawBufferPointer, inout Int) throws -> Void) rethrows {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
        var rawBuf = UnsafeMutableRawBufferPointer(start: ptr, count: byteCount)
        var initializedCount = 0
        do {
            try initializer(&rawBuf, &initializedCount)
        } catch {
            ptr.deallocate()
            throw error
        }
        self = Data(bytesNoCopy: ptr, count: initializedCount, deallocator: .custom { p, _ in p.deallocate() })
    }
}

/// Renders float rasters into `CGImage`s for map display.
public nonisolated enum ReliefRenderer {
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    public static func image(
        from values: [Float],
        width: Int,
        height: Int,
        style: ReliefStyle,
        range: ClosedRange<Float>? = nil,
        elevation: [Float]? = nil,
        contourInterval: ContourInterval = .off,
        palette: HypsometricPalette = .topo
    ) -> CGImage? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let bounds = range ?? dataRange(of: values)
        let span = max(bounds.upperBound - bounds.lowerBound, 0.001)
        let invSpan255 = 255.0 / span
        let lower = bounds.lowerBound
        let count = values.count
        let styleLUT = style == .elevation ? lut32(for: palette) : lut32(for: style)

        let pixelData = Data(unsafeUninitializedCapacity: count * 4) { rawBuf, initializedCount in
            guard let pBase = rawBuf.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            values.withUnsafeBufferPointer { valBuf in
                styleLUT.withUnsafeBufferPointer { lutBuf in
                    guard let vBase = valBuf.baseAddress, let lutBase = lutBuf.baseAddress else { return }
                    for i in 0..<count {
                        let value = vBase[i]
                        if value.isNaN {
                            pBase[i] = 0x00000000
                        } else {
                            let t = (value - lower) * invSpan255
                            let idx = min(max(Int(t), 0), 255)
                            pBase[i] = lutBase[idx]
                        }
                    }
                }
            }

            let elevArray = elevation ?? (style == .elevation ? values : nil)
            if contourInterval.meters > 0, let elevArray, elevArray.count == count {
                let interval = contourInterval.meters
                elevArray.withUnsafeBufferPointer { elevBuf in
                    guard let eBase = elevBuf.baseAddress else { return }
                    for i in 0..<count {
                        let elev = eBase[i]
                        if elev.isNaN { continue }
                        let current = pBase[i]
                        let curA = Float((current >> 24) & 0xFF)
                        guard curA > 0 else { continue }

                        let mod = elev.truncatingRemainder(dividingBy: interval)
                        let posMod = mod < 0 ? mod + interval : mod
                        let distToLine = min(posMod, interval - posMod)

                        let x = i % width
                        let y = i / width
                        let left = x > 0 ? eBase[i - 1] : elev
                        let right = x + 1 < width ? eBase[i + 1] : elev
                        let up = y > 0 ? eBase[i - width] : elev
                        let down = y + 1 < height ? eBase[i + width] : elev
                        let dzdx = (!left.isNaN && !right.isNaN) ? (right - left) * 0.5 : 0.0
                        let dzdy = (!up.isNaN && !down.isNaN) ? (down - up) * 0.5 : 0.0
                        let grad = max(sqrt(dzdx * dzdx + dzdy * dzdy), 0.5)
                        let lineDist = distToLine / grad

                        if lineDist < 1.2 {
                            let factor = Float(1.0 - (lineDist / 1.2))
                            let invA = 255.0 / curA
                            let r = Float(current & 0xFF) * invA
                            let g = Float((current >> 8) & 0xFF) * invA
                            let b = Float((current >> 16) & 0xFF) * invA

                            let newR = UInt8(clamping: Int(r + (35.0 - r) * factor))
                            let newG = UInt8(clamping: Int(g + (30.0 - g) * factor))
                            let newB = UInt8(clamping: Int(b + (25.0 - b) * factor))
                            let newA = UInt8(clamping: Int(curA + (230.0 - curA) * factor))
                            pBase[i] = packPremultiplied(newR, newG, newB, newA)
                        }
                    }
                }
            }

            initializedCount = count * 4
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    public static func dataRange(of values: [Float]) -> ClosedRange<Float> {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        values.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for i in 0..<buf.count {
                let v = ptr[i]
                if !v.isNaN {
                    if v < low { low = v }
                    if v > high { high = v }
                }
            }
        }
        guard low <= high else { return 0...1 }
        return low...high
    }

    public static func robustRange(of values: [Float]) -> ClosedRange<Float> {
        let stride = max(values.count / 2048, 1)
        var sampled = [Float]()
        sampled.reserveCapacity(2048)
        values.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for i in Swift.stride(from: 0, to: buf.count, by: stride) {
                let v = ptr[i]
                if !v.isNaN { sampled.append(v) }
            }
        }
        guard sampled.count > 20 else { return dataRange(of: values) }
        sampled.sort()
        let low = sampled[Int(Double(sampled.count) * 0.02)]
        let high = sampled[Int(Double(sampled.count) * 0.98)]
        return low <= high ? low...high : dataRange(of: values)
    }

    private typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

    @inline(__always)
    private static func packPremultiplied(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
        if a == 0 { return 0 }
        let pr = UInt32((UInt16(r) * UInt16(a) + 127) / 255)
        let pg = UInt32((UInt16(g) * UInt16(a) + 127) / 255)
        let pb = UInt32((UInt16(b) * UInt16(a) + 127) / 255)
        let pa = UInt32(a)
        return pr | (pg << 8) | (pb << 16) | (pa << 24)
    }

    private static let hillshadeLUT: [UInt32] = (0...255).map { i in
        let v = UInt32(i)
        return v | (v << 8) | (v << 16) | (255 << 24)
    }

    private static let multiDirectionalLUT: [UInt32] = (0...255).map { i in
        let t = Float(i) / 255.0
        let signal = pow(t, 0.45)
        let alpha = UInt8(min(max(signal * 190.0, 0.0), 255.0))
        return packPremultiplied(26, 26, 26, alpha)
    }

    private static let slopeLUT: [UInt32] = (0...255).map { i in
        let c = ramp(Float(i) / 255.0, stops: Self.slopeStops)
        return packPremultiplied(c.0, c.1, c.2, c.3)
    }

    private static let elevationLUT: [UInt32] = (0...255).map { i in
        let c = ramp(Float(i) / 255.0, stops: Self.elevationStops)
        return packPremultiplied(c.0, c.1, c.2, c.3)
    }

    @inline(__always)
    private static func lut32(for style: ReliefStyle) -> [UInt32] {
        switch style {
        case .hillshade: return hillshadeLUT
        case .multiDirectional: return multiDirectionalLUT
        case .slope: return slopeLUT
        case .elevation: return elevationLUT
        }
    }

    private static func ramp(
        _ t: Float, stops: [(Float, (UInt8, UInt8, UInt8))]
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        if t <= first.0 { return (first.1.0, first.1.1, first.1.2, 220) }
        if t >= last.0 { return (last.1.0, last.1.1, last.1.2, 220) }
        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            guard t >= t0, t <= t1 else { continue }
            let f = (t - t0) / max(t1 - t0, .leastNormalMagnitude)
            return (
                UInt8(Float(c0.0) + f * (Float(c1.0) - Float(c0.0))),
                UInt8(Float(c0.1) + f * (Float(c1.1) - Float(c0.1))),
                UInt8(Float(c0.2) + f * (Float(c1.2) - Float(c0.2))),
                220
            )
        }
        return (last.1.0, last.1.1, last.1.2, 220)
    }

    private static let slopeStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, (49, 54, 149)),
        (0.25, (69, 149, 196)),
        (0.50, (224, 243, 248)),
        (0.75, (253, 174, 97)),
        (1.00, (165, 0, 38)),
    ]

    private static let elevationStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, (56, 122, 87)),
        (0.30, (154, 184, 108)),
        (0.55, (215, 194, 134)),
        (0.75, (168, 130, 96)),
        (0.90, (140, 110, 100)),
        (1.00, (245, 245, 245)),
    ]

    private static let turboStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, ( 48,  18,  59)),
        (0.10, ( 67,  87, 173)),
        (0.20, ( 56, 152, 222)),
        (0.30, ( 29, 206, 180)),
        (0.40, ( 74, 237, 112)),
        (0.50, (159, 249,  56)),
        (0.60, (219, 219,  42)),
        (0.70, (250, 176,  30)),
        (0.80, (246, 119,  17)),
        (0.90, (219,  55,   7)),
        (1.00, (122,   4,   3)),
    ]

    private static let slateStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, ( 30,  30,  35)),
        (0.25, ( 65,  68,  75)),
        (0.50, (120, 118, 115)),
        (0.75, (175, 170, 165)),
        (1.00, (230, 225, 220)),
    ]

    private static let magmaStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, (  0,   0,   3)),
        (0.15, ( 30,  12,  67)),
        (0.30, ( 94,  19, 108)),
        (0.45, (156,  39, 109)),
        (0.60, (213,  72,  84)),
        (0.75, (244, 133,  53)),
        (0.90, (252, 205, 105)),
        (1.00, (252, 253, 191)),
    ]

    @inline(__always)
    private static func lut32(for palette: HypsometricPalette) -> [UInt32] {
        let stops: [(Float, (UInt8, UInt8, UInt8))]
        switch palette {
        case .topo: stops = elevationStops
        case .turbo: stops = turboStops
        case .slate: stops = slateStops
        case .magma: stops = magmaStops
        }
        return (0...255).map { i in
            let c = ramp(Float(i) / 255.0, stops: stops)
            return packPremultiplied(c.0, c.1, c.2, c.3)
        }
    }
}

/// Hypsometric color palette for elevation tint rendering.
public nonisolated enum HypsometricPalette: String, Sendable, CaseIterable, Identifiable {
    case topo = "Topo"
    case turbo = "Turbo"
    case slate = "Slate"
    case magma = "Magma"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .topo: "Topo"
        case .turbo: "Turbo"
        case .slate: "Slate"
        case .magma: "Magma"
        }
    }
}
