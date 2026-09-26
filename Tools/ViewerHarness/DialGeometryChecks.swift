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
    // A tiny negative angle plus 360 rounds to exactly 360.0; the bearing must still read 0.
    let subUlpWest = bearing(CGFloat(38).nextDown, 0)
    check("a sub-ulp hair west of north reads 0, never 360", subUlpWest == 0,
          String(describing: subUlpWest))
    check("exactly on the dead-zone radius has no bearing", bearing(42, 38) == nil,
          String(describing: bearing(42, 38)))
    check("a point that is not a number has no bearing", bearing(.nan, 38) == nil,
          String(describing: bearing(.nan, 38)))
    let largerDialEast = DialGeometry.bearing(at: CGPoint(x: 100, y: 50), diameter: 100)
    check("a larger dial measures from its own centre", abs((largerDialEast ?? -1) - 90) < 0.001,
          String(describing: largerDialEast))

    check("44 degrees is near the NE detent", DialGeometry.nearestDetent(to: 44, tolerance: 6) == 45)
    check("357 degrees is near north around the wrap", DialGeometry.nearestDetent(to: 357, tolerance: 6) == 0)
    check("3 degrees is near north", DialGeometry.nearestDetent(to: 3, tolerance: 6) == 0)
    check("22.5 degrees sits between detents", DialGeometry.nearestDetent(to: 22.5, tolerance: 6) == nil)
    check("tolerance is inclusive", DialGeometry.nearestDetent(to: 51, tolerance: 6) == 45)
    check("of two detents in range the nearest wins",
          DialGeometry.nearestDetent(to: 30, tolerance: 30) == 45,
          String(describing: DialGeometry.nearestDetent(to: 30, tolerance: 30)))
    check("an azimuth past 360 is near north", DialGeometry.nearestDetent(to: 363, tolerance: 6) == 0)
    check("a negative azimuth is near north", DialGeometry.nearestDetent(to: -3, tolerance: 6) == 0)
    check("the dial's detents are the headings the haptics tick at",
          DialGeometry.compassDetents == AzimuthDetents.headings, "\(DialGeometry.compassDetents)")
}
