//
//  ElevationRangePolicy.swift
//  LidarExplorer
//
//  Decides when the shared .elevation colour range should change.
//

import Foundation

/// Chooses the shared hypsometric range for the `.elevation` style, resisting
/// small changes so the rendered-tile cache is not fragmented and the screen is
/// not re-tinted on every pan.
///
/// The range is a view-adaptive aesthetic, not a measurement: it fits the tint
/// to the visible extent, and a little terrain clamping at the palette ends is
/// acceptable. Adopting a new range clears every tile's cached render
/// (`TerrainTileProvider.update`), so adopting *less often* both raises the
/// disk-cache hit rate — the key embeds the range — and removes the full-screen
/// re-render hitch a bare `!=` produced on 10 m pan wobble.
public nonisolated enum ElevationRangePolicy {

    /// Deadband half-width as a fraction of the current span. 9% keeps the tint
    /// tracking the terrain while sitting out ordinary pan wobble.
    public static let hysteresisFraction: Float = 0.09

    /// Absolute floor (metres) for both the quantization step and the deadband,
    /// so flat terrain still behaves like the previous fixed 10 m snapping.
    public static let minStep: Float = 10

    /// Adopted ranges snap to roughly span / this.
    public static let stepDivisor: Float = 12

    /// The range to adopt, or `nil` to keep `current` (no re-render).
    public static func next(
        raw: ClosedRange<Float>, current: ClosedRange<Float>?
    ) -> ClosedRange<Float>? {
        guard let current else { return quantize(raw) }
        let span = max(current.upperBound - current.lowerBound, minStep)
        let tol = max(minStep, hysteresisFraction * span)
        if abs(raw.lowerBound - current.lowerBound) <= tol,
           abs(raw.upperBound - current.upperBound) <= tol {
            return nil
        }
        let candidate = quantize(raw)
        return candidate == current ? nil : candidate
    }

    /// Snaps a raw extent onto a span-relative grid. Uses floor/ceil, so the
    /// result always covers `raw` and the tint never clips the visible extent.
    public static func quantize(_ r: ClosedRange<Float>) -> ClosedRange<Float> {
        let span = max(r.upperBound - r.lowerBound, minStep)
        let step = niceStep(forSpan: span)
        let lo = (r.lowerBound / step).rounded(.down) * step
        let hi = (r.upperBound / step).rounded(.up) * step
        return lo ... max(hi, lo + step)
    }

    /// A 1/2/5·10ᵏ "nice" step near `span / stepDivisor`, floored at `minStep`.
    /// Computed in `Double` so `pow`/`log10` resolve without a Float overload.
    public static func niceStep(forSpan span: Float) -> Float {
        let target = max(Double(span) / Double(stepDivisor), Double(minStep))
        let magnitude = pow(10.0, floor(log10(target)))
        for c in [5.0, 2.0, 1.0] where c * magnitude <= target {
            return max(Float(c * magnitude), minStep)
        }
        return max(Float(magnitude), minStep)
    }
}
