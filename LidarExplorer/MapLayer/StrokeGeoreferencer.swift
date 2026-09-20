//
//  StrokeGeoreferencer.swift
//  LidarExplorer
//
//  Turns a stroke drawn on the screen into a line on the ground.
//
//  Kept free of UIKit and PencilKit: it takes the stroke's points and a function that says what coordinate is
//  under a point, which on the device is the map view's own `convert(_:toCoordinateFrom:)`. That is what lets the
//  arithmetic be tested host-side against a map whose geometry is known.
//

import CoreGraphics
import CoreLocation
import Foundation

public nonisolated enum StrokeGeoreferencer {

    /// The Douglas-Peucker simplification of `points`: the ends kept, and every dropped point within `tolerance`
    /// of the line that replaces it.
    ///
    /// Distance is to the *segment*, not its infinite line, so a stroke that doubles back on itself is not
    /// collapsed onto the line through its ends.
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let limit = max(Double(tolerance), 0)
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var pending = [(0, points.count - 1)]
        while let (low, high) = pending.popLast() {
            guard high - low > 1 else { continue }
            var farthest = -1.0
            var index = low
            for i in (low + 1)..<high {
                let d = distance(from: points[i], toSegment: points[low], points[high])
                if d > farthest { farthest = d; index = i }
            }
            if farthest > limit {
                keep[index] = true
                pending.append((low, index))
                pending.append((index, high))
            }
        }
        return zip(points, keep).filter(\.1).map(\.0)
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
        let t = min(max((Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(Double(p.x) - (Double(a.x) + t * dx), Double(p.y) - (Double(a.y) + t * dy))
    }

    /// A ground trace for a stroke, or `nil` when it does not describe a line.
    ///
    /// Points that are not numbers, and points `convert` cannot place (or places off the Earth), are dropped; the
    /// rest are simplified to `tolerance` screen points before conversion, so a long Pencil stroke costs a few
    /// dozen conversions rather than thousands. Simplification also collapses a pen held still into one vertex.
    public static func trace(
        screenPoints: [CGPoint], colorHex: String, strokeWidth: Double, tolerance: CGFloat = 1.5,
        convert: (CGPoint) -> CLLocationCoordinate2D?
    ) -> FieldAnnotationTrace? {
        let finite = screenPoints.filter { $0.x.isFinite && $0.y.isFinite }
        guard finite.count >= 2 else { return nil }

        var coordinates: [CLLocationCoordinate2D] = []
        for point in simplify(finite, tolerance: tolerance) {
            guard let coordinate = convert(point), FieldPosition(coordinate).isValid else { continue }
            coordinates.append(coordinate)
        }
        guard let first = coordinates.first, coordinates.count >= 2,
              coordinates.contains(where: { $0.latitude != first.latitude || $0.longitude != first.longitude })
        else { return nil }
        return FieldAnnotationTrace(coordinates: coordinates, strokeWidth: strokeWidth, colorHex: colorHex)
    }
}
