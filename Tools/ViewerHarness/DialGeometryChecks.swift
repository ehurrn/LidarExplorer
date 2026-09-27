//
//  DialGeometryChecks.swift
//  ViewerHarness
//
//  The sun dial's touch geometry: a drag around the face, the dead centre under the readout, the wrap through north,
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
    // The dead zone is the inner half of the face, where the readout sits: a quarter of the diameter, 19 pt here.
    check("a tap on the readout, 8 pt left of centre, has no bearing (it swung the sun to the west)",
          bearing(30, 38) == nil, String(describing: bearing(30, 38)))
    check("a tap at the readout's end, 15 pt right of centre and 6 pt down, has no bearing",
          bearing(53, 44) == nil, String(describing: bearing(53, 44)))
    check("just inside the dead zone has no bearing", bearing(56.9, 38) == nil)
    check("just outside the dead zone reads east", abs((bearing(57.1, 38) ?? -1) - 90) < 0.001)
    if let wrapped = bearing(37, 0) {
        check("a hair west of north wraps below 360", wrapped > 358 && wrapped < 360, "\(wrapped)")
    } else {
        check("a hair west of north wraps below 360", false, "nil")
    }
    // A tiny negative angle plus 360 rounds to exactly 360.0; the bearing must still read 0.
    let subUlpWest = bearing(CGFloat(38).nextDown, 0)
    check("a sub-ulp hair west of north reads 0, never 360", subUlpWest == 0,
          String(describing: subUlpWest))
    check("exactly on the dead-zone radius has no bearing", bearing(57, 38) == nil,
          String(describing: bearing(57, 38)))
    check("a point that is not a number has no bearing", bearing(.nan, 38) == nil,
          String(describing: bearing(.nan, 38)))
    let largerDialEast = DialGeometry.bearing(at: CGPoint(x: 100, y: 50), diameter: 100)
    check("a larger dial measures from its own centre", abs((largerDialEast ?? -1) - 90) < 0.001,
          String(describing: largerDialEast))
    // The dial and its readout grow with the text, so the dead zone does too.
    let largerDialReadout = DialGeometry.bearing(at: CGPoint(x: 74, y: 50), diameter: 100)
    let largerDialRing = DialGeometry.bearing(at: CGPoint(x: 76, y: 50), diameter: 100)
    check("a larger dial's dead zone grows with it: 24 pt out of 100 has no bearing, 26 pt reads east",
          largerDialReadout == nil && abs((largerDialRing ?? -1) - 90) < 0.001,
          "\(String(describing: largerDialReadout)), \(String(describing: largerDialRing))")

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

    // The whole degree the readout shows and VoiceOver speaks: one value, so the two never disagree.
    check("a bearing that rounds up to 360 reads 0, never 360", DialGeometry.wholeDegrees(359.7) == 0,
          "\(DialGeometry.wholeDegrees(359.7))")
    check("359.4 reads 359", DialGeometry.wholeDegrees(359.4) == 359)
    check("44.5 rounds to 45", DialGeometry.wholeDegrees(44.5) == 45)
    check("a negative bearing wraps to its compass reading", DialGeometry.wholeDegrees(-3) == 357,
          "\(DialGeometry.wholeDegrees(-3))")
    check("a bearing past a full turn wraps", DialGeometry.wholeDegrees(725) == 5)
    check("a bearing that is not a number reads 0 instead of trapping", DialGeometry.wholeDegrees(.nan) == 0)

    // The VoiceOver step: onto the 5 degree grid a drag may have left, always far enough that the readout moves.
    func step(_ azimuth: Double, _ clockwise: Bool) -> Double {
        DialGeometry.adjustedBearing(from: azimuth, clockwise: clockwise)
    }
    check("a step up from a dragged 43.27 lands on NE", step(43.27, true) == 45, "\(step(43.27, true))")
    check("a step down from a dragged 43.27 lands on 40", step(43.27, false) == 40, "\(step(43.27, false))")
    check("a step up from NE is 50", step(45, true) == 50, "\(step(45, true))")
    check("a step down from NE is 40", step(45, false) == 40, "\(step(45, false))")
    check("a step up from 44.8, already reading 045, moves on to 50", step(44.8, true) == 50,
          "\(step(44.8, true))")
    check("a step up from 357 wraps through north to 0", step(357, true) == 0, "\(step(357, true))")
    check("a step down from north wraps to 355", step(0, false) == 355, "\(step(0, false))")
    check("a step up from 359.7, reading 000, is 5", step(359.7, true) == 5, "\(step(359.7, true))")
    check("a step down from 359.7, reading 000, is 355", step(359.7, false) == 355, "\(step(359.7, false))")
    check("a step down from 0.3, reading 000, is 355", step(0.3, false) == 355, "\(step(0.3, false))")
    var stepFailures: [String] = []
    for i in 0..<973 {
        let start = Double(i) * 0.37
        for clockwise in [true, false] {
            let next = step(start, clockwise)
            var moved = clockwise ? next - start : start - next
            if moved <= 0 { moved += 360 }
            let onGrid = next.truncatingRemainder(dividingBy: 5) == 0
            if !(next >= 0 && next < 360) || !onGrid || !(moved > 0.5 && moved <= 5.5)
                || DialGeometry.wholeDegrees(next) == DialGeometry.wholeDegrees(start) {
                stepFailures.append("\(start) \(clockwise ? "up" : "down") -> \(next)")
            }
        }
    }
    check("every step lands on the grid in [0, 360), moves the readout, and goes the way asked by at most a step",
          stepFailures.isEmpty, stepFailures.prefix(4).joined(separator: "; "))
    check("a step from a bearing that is not a number leaves it be", step(.nan, true).isNaN)
}
