//
//  DialGeometryChecks.swift
//  ViewerHarness
//
//  The sun dial's touch geometry: a drag around the face, the dead centre, the wrap through north,
//  and which compass detent a bearing sits near.
//

import CoreGraphics
import Foundation

@MainActor
func runDialGeometryChecks() {
    print("\n=== Dial geometry ===")
    let d: CGFloat = 76

    func bearing(_ x: CGFloat, _ y: CGFloat) -> Double? {
        DialGeometry.bearing(at: CGPoint(x: x, y: y), diameter: d)
    }

    check("top of the face is north", abs((bearing(38, 0) ?? -1) - 0) < 0.001)
    check("right is east", abs((bearing(76, 38) ?? -1) - 90) < 0.001)
    check("bottom is south", abs((bearing(38, 76) ?? -1) - 180) < 0.001)
    check("left is west", abs((bearing(0, 38) ?? -1) - 270) < 0.001)
    check("top-right corner is north-east", abs((bearing(76, 0) ?? -1) - 45) < 0.001)
    check("dead centre has no bearing", bearing(38, 38) == nil)
    check("just inside the dead zone has no bearing", bearing(41.9, 38) == nil)
    check("just outside the dead zone reads east", abs((bearing(42.1, 38) ?? -1) - 90) < 0.001)
    if let wrapped = bearing(37, 0) {
        check("a hair west of north wraps below 360", wrapped > 358 && wrapped < 360, "\(wrapped)")
    } else {
        check("a hair west of north wraps below 360", false, "nil")
    }

    check("44 degrees is near the NE detent", DialGeometry.nearestDetent(to: 44, tolerance: 6) == 45)
    check("357 degrees is near north around the wrap", DialGeometry.nearestDetent(to: 357, tolerance: 6) == 0)
    check("3 degrees is near north", DialGeometry.nearestDetent(to: 3, tolerance: 6) == 0)
    check("22.5 degrees sits between detents", DialGeometry.nearestDetent(to: 22.5, tolerance: 6) == nil)
    check("tolerance is inclusive", DialGeometry.nearestDetent(to: 51, tolerance: 6) == 45)
}
