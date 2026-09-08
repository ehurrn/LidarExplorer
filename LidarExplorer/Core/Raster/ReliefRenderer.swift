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
    ///
    /// The reason this app exists: a single light direction is blind to any
    /// landform whose long axis runs parallel to it, so subtle linear
    /// micro-topography vanishes at one azimuth and is obvious at the next.
    /// Mapping the spread across directions shows all of it at once.
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

/// Renders float rasters into `CGImage`s for map display.
public nonisolated enum ReliefRenderer {

    /// Builds an image from a raster.
    ///
    /// - Parameters:
    ///   - values: Row-major samples. `NaN` renders fully transparent, so DEM
    ///     voids read as holes rather than as a shade of grey that could be
    ///     mistaken for terrain.
    ///   - range: Value range mapped across the ramp. Computed from the data
    ///     when `nil`.
    public static func image(
        from values: [Float],
        width: Int,
        height: Int,
        style: ReliefStyle,
        range: ClosedRange<Float>? = nil
    ) -> CGImage? {
        guard width > 0, height > 0, values.count == width * height else { return nil }

        let bounds = range ?? dataRange(of: values)
        let span = max(bounds.upperBound - bounds.lowerBound, .leastNormalMagnitude)
        let invSpan = 1.0 / span
        let lower = bounds.lowerBound
        let count = values.count

        // Write packed 32-bit RGBA straight into a pre-sized Data buffer.
        // Building Data from a separate [UInt8] would force a second ~1 MB copy
        // per tile; one UInt32 store per pixel also replaces four byte stores.
        // Packing is little-endian (Apple silicon): byte 0 = R … byte 3 = A,
        // matching CGImageAlphaInfo.last.
        var pixelData = Data(count: count * 4)
        let styleLUT = lut32(for: style)

        values.withUnsafeBufferPointer { valBuf in
            pixelData.withUnsafeMutableBytes { rawBuf in
                guard let vBase = valBuf.baseAddress,
                      let pBase = rawBuf.baseAddress?.assumingMemoryBound(to: UInt32.self)
                else { return }
                for i in 0..<count {
                    let value = vBase[i]
                    guard !value.isNaN else { continue }  // leaves 0x00000000 = transparent

                    let t = min(max((value - lower) * invSpan, 0), 1)
                    let idx = Int(t * 255.0)
                    pBase[i] = styleLUT[idx]
                }
            }
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Range over valid samples, ignoring voids.
    public static func dataRange(of values: [Float]) -> ClosedRange<Float> {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for v in values where !v.isNaN {
            low = min(low, v)
            high = max(high, v)
        }
        guard low <= high else { return 0...1 }
        return low...high
    }

    /// Robust range that clips the extreme tails.
    ///
    /// A single spike — a power pylon in the DEM, or a decoding artefact —
    /// otherwise compresses the entire ramp into a narrow band and makes the
    /// real terrain look flat. Clipping at the 2nd and 98th percentiles keeps
    /// the visible contrast on the terrain rather than on the outlier.
    public static func robustRange(of values: [Float]) -> ClosedRange<Float> {
        let stride = max(values.count / 2048, 1)
        var sampled = [Float]()
        sampled.reserveCapacity(2048)
        for i in Swift.stride(from: 0, to: values.count, by: stride) {
            let v = values[i]
            if !v.isNaN { sampled.append(v) }
        }
        guard sampled.count > 20 else { return dataRange(of: values) }
        sampled.sort()
        let low = sampled[Int(Double(sampled.count) * 0.02)]
        let high = sampled[Int(Double(sampled.count) * 0.98)]
        return low <= high ? low...high : dataRange(of: values)
    }

    // MARK: - Ramps

    private typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

    /// Packs a straight-alpha RGBA tuple into a little-endian UInt32 word
    /// (byte 0 = R … byte 3 = A) matching CGImageAlphaInfo.last.
    @inline(__always)
    private static func pack(_ c: RGBA) -> UInt32 {
        UInt32(c.0) | (UInt32(c.1) << 8) | (UInt32(c.2) << 16) | (UInt32(c.3) << 24)
    }

    private static let hillshadeLUT: [UInt32] = (0...255).map { i in
        let v = UInt32(i)
        return v | (v << 8) | (v << 16) | (255 << 24)
    }

    private static let multiDirectionalLUT: [UInt32] = (0...255).map { i in
        let t = Float(i) / 255.0
        // Alpha = t^0.45, capped at ~0.75. The gamma lifts gentle relief on
        // flat ground into view (median relief ~0.005 at Cahokia sits far below
        // the 0.18 range cap); dropping the earlier 1.8 gain stops rugged
        // terrain becoming a solid black wash — at max signal the dark ink
        // reads as dark grey over the basemap rather than near-black.
        let signal = pow(t, 0.45)
        let alpha = UInt32(signal * 190)
        let ink: UInt32 = 26
        return ink | (ink << 8) | (ink << 16) | (alpha << 24)
    }

    private static let slopeLUT: [UInt32] = (0...255).map { i in
        pack(ramp(Float(i) / 255.0, stops: Self.slopeStops))
    }

    private static let elevationLUT: [UInt32] = (0...255).map { i in
        pack(ramp(Float(i) / 255.0, stops: Self.elevationStops))
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

    /// Linear interpolation across an ordered colour table.
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

    /// Perceptually ordered cool-to-warm ramp for steepness.
    private static let slopeStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, (49, 54, 149)),
        (0.25, (69, 149, 196)),
        (0.50, (224, 243, 248)),
        (0.75, (253, 174, 97)),
        (1.00, (165, 0, 38)),
    ]

    /// Conventional hypsometric tint: greens low, browns mid, white high.
    private static let elevationStops: [(Float, (UInt8, UInt8, UInt8))] = [
        (0.00, (56, 122, 87)),
        (0.30, (154, 184, 108)),
        (0.55, (215, 194, 134)),
        (0.75, (168, 130, 96)),
        (0.90, (140, 110, 100)),
        (1.00, (245, 245, 245)),
    ]
}
