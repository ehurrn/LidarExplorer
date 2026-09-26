//
//  DialGeometry.swift
//  LidarExplorer
//
//  The geometry of a circular bearing dial: which bearing a touch asks for, and which compass detent a
//  bearing sits near. Pure, so a drag around the face is testable without a screen (the pattern of
//  PencilRollAzimuth.swift).
//

import CoreGraphics
import Foundation

public nonisolated enum DialGeometry {

    /// Touches within this many points of the centre have no usable direction.
    public static let deadZoneRadius: CGFloat = 4

    /// The eight compass headings the azimuth haptics tick at (HapticDetents), in degrees.
    public static let compassDetents: [Double] = stride(from: 0.0, to: 360.0, by: 45.0).map { $0 }

    /// The bearing, in degrees [0, 360), north up and clockwise, of `point` from the centre of a dial
    /// `diameter` points across whose origin is its top-left corner; `nil` inside the dead zone.
    public static func bearing(at point: CGPoint, diameter: CGFloat) -> Double? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        guard dx * dx + dy * dy > deadZoneRadius * deadZoneRadius else { return nil }
        var degrees = Foundation.atan2(Double(dx), Double(-dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees == 360 ? 0 : degrees
    }

    /// The compass detent within `tolerance` degrees of `azimuth`, measured around the circle, or `nil`.
    public static func nearestDetent(to azimuth: Double, tolerance: Double) -> Double? {
        var best: (detent: Double, distance: Double)?
        for detent in compassDetents {
            let distance = abs((azimuth - detent).remainder(dividingBy: 360))
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (detent, distance)
            }
        }
        return best?.detent
    }
}
