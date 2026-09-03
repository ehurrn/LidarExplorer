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

        // Straight (non-premultiplied) RGBA, so the alpha we write for voids
        // is not baked into the colour channels.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<values.count {
            let value = values[i]
            let out = i * 4
            guard !value.isNaN else { continue }  // leaves RGBA = 0,0,0,0

            let t = min(max((value - bounds.lowerBound) / span, 0), 1)
            let (r, g, b, a) = colour(for: t, style: style)
            pixels[out] = r
            pixels[out + 1] = g
            pixels[out + 2] = b
            pixels[out + 3] = a
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
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
        let valid = values.filter { !$0.isNaN }.sorted()
        guard valid.count > 20 else { return dataRange(of: values) }
        let low = valid[Int(Double(valid.count) * 0.02)]
        let high = valid[Int(Double(valid.count) * 0.98)]
        return low <= high ? low...high : dataRange(of: values)
    }

    // MARK: - Ramps

    private static func colour(
        for t: Float, style: ReliefStyle
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        switch style {
        case .hillshade:
            // Neutral grey, fully opaque; the map beneath is dimmed by the
            // overlay's own alpha rather than per-pixel here.
            let v = UInt8(t * 255)
            return (v, v, v, 255)

        case .multiDirectional:
            // Dark where terrain is directionally uniform, bright where it is
            // structured. Alpha tracks the signal so flat ground stays
            // transparent and the basemap shows through.
            let v = UInt8(min(t * 1.6, 1) * 255)
            return (v, v, v, UInt8(min(t * 2.2, 1) * 255))

        case .slope:
            return ramp(t, stops: Self.slopeStops)

        case .elevation:
            return ramp(t, stops: Self.elevationStops)
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
