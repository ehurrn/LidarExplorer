//
//  DialGeometryChecks.swift
//  ViewerHarness
//
//  The sun dial's touch geometry: a drag around the face, the dead centre under the readout, the wrap through north,
//  and which compass detent a bearing sits near. X1: when a drag writes the map's sun (SunDialCommit).
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

    // A drag: the readout's zone holds for the touch-down (a tap on the number, with a finger's wiggle), and once the drag
    // swings the sun only the centre's 4 pt do, so a finger following the sun that drifts inward keeps it moving.
    func onFace(_ degrees: Double, _ radius: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: 38 + radius * sin(r), y: 38 - radius * cos(r))
    }
    func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs((value - expected).remainder(dividingBy: 360)) < 0.01
    }
    // The sun orbits 23 pt out (diameter / 2 - 15) and is 14 pt across; the readout's zone is 19 pt.
    var following = DialGeometry.Drag()
    let grabbed = following.bearing(at: onFace(315, 23), diameter: d)
    let drifted = following.bearing(at: onFace(330, 18), diameter: d)
    check("a drag that grabbed the sun on its orbit keeps following a finger that drifts 5 pt inside it (18 pt out, in the readout's zone)",
          near(grabbed, 315) && near(drifted, 330), "\(String(describing: grabbed)), \(String(describing: drifted))")
    let closeIn = following.bearing(at: onFace(350, 5), diameter: d)
    let centre = following.bearing(at: onFace(355, 3), diameter: d)
    check("a drag that is swinging the sun follows to 5 pt from the centre; only the centre's 4 pt have no bearing",
          near(closeIn, 350) && centre == nil, "\(String(describing: closeIn)), \(String(describing: centre))")

    var tap = DialGeometry.Drag()
    let tapSamples = [CGPoint(x: 30, y: 38), CGPoint(x: 32, y: 40), CGPoint(x: 27, y: 35)].map { tap.bearing(at: $0, diameter: d) }
    check("a tap on the readout that wiggles 4 pt never has a bearing, so it leaves the sun be",
          tapSamples.allSatisfy { $0 == nil } && !tap.isFollowing, "\(tapSamples)")

    var outward = DialGeometry.Drag()
    let outwardSamples = [CGPoint(x: 38, y: 33), CGPoint(x: 38, y: 31), CGPoint(x: 38, y: 16), CGPoint(x: 40, y: 30)]
        .map { outward.bearing(at: $0, diameter: d) }
    check("a drag that goes down on the readout swings the sun once it reaches the ring, then keeps following back over the readout",
          outwardSamples[0] == nil && outwardSamples[1] == nil && near(outwardSamples[2], 0)
            && near(outwardSamples[3], atan2(2, 8) * 180 / .pi),
          "\(outwardSamples)")

    // Down on the sun's inner edge, 17 pt out, inside the readout's zone: the drag has the sun from the touch-down and
    // follows every step round the orbit. Held to a tap's slop like a touch on the readout, the sun stood still for the
    // first 20 degrees of the drag, then jumped 25 degrees to the finger.
    var innerEdge = DialGeometry.Drag()
    let innerDown = innerEdge.bearing(at: onFace(315, 17), diameter: d, sunAt: 315)
    let innerSmall = innerEdge.bearing(at: onFace(325, 17), diameter: d, sunAt: 315)   // 3 pt along
    let innerAlong = innerEdge.bearing(at: onFace(340, 17), diameter: d, sunAt: 325)   // 7.4 pt along
    check("a drag that goes down on the sun's inner edge (17 pt out, in the readout's zone) has the sun from the touch-down and follows every step round the orbit",
          near(innerDown, 315) && near(innerSmall, 325) && near(innerAlong, 340) && innerEdge.isFollowing,
          "\(String(describing: innerDown)), \(String(describing: innerSmall)), \(String(describing: innerAlong))")
    // The sun is 14 pt across on its orbit 23 pt out, so its whole dot takes the drag, and only its dot.
    var sunDot = DialGeometry.Drag()
    let sunEdge = sunDot.bearing(at: CGPoint(x: 38 + 16, y: 38), diameter: d, sunAt: 90)       // its inner edge, due east
    var besideSun = DialGeometry.Drag()
    let offSun = besideSun.bearing(at: onFace(135, 17), diameter: d, sunAt: 315)              // opposite the sun
    check("a touch-down on the sun's inner edge due east has it; one in the readout's zone away from the sun is still a tap on the readout",
          near(sunEdge, 90) && sunDot.isFollowing && offSun == nil && !besideSun.isFollowing,
          "\(String(describing: sunEdge)), \(String(describing: offSun))")
    // Wherever the sun is, a tap on the readout's digits ("315°" at caption size, about 30 pt across and under 10 pt
    // tall) leaves it be. (The text's frame is 16 pt tall, and at about 60 degrees the drawn sun overlaps its corner:
    // a touch there is on the sun.)
    var readoutTakesTheSun: [String] = []
    for sun in stride(from: 0.0, to: 360, by: 1) {
        for x in stride(from: CGFloat(-15), through: 15, by: 1.5) {
            for y in stride(from: CGFloat(-5), through: 5, by: 1) {
                var touch = DialGeometry.Drag()
                if touch.bearing(at: CGPoint(x: 38 + x, y: 38 + y), diameter: d, sunAt: sun) != nil || touch.isFollowing {
                    readoutTakesTheSun.append("sun \(sun) at (\(x), \(y))")
                }
            }
        }
    }
    check("at every sun bearing, a touch-down on the readout's digits has no bearing (the sun's dot never reaches them)",
          readoutTakesTheSun.isEmpty, readoutTakesTheSun.prefix(3).joined(separator: "; "))
    check("the sun the dial draws is the one a touch takes: 14 pt across, its centre 15 pt inside the rim",
          DialGeometry.sunRadius == 7 && DialGeometry.sunOrbitInset == 15
            && DialGeometry.isOnSun(onFace(315, 23), azimuth: 315, diameter: d)
            && DialGeometry.isOnSun(onFace(315, 16.01), azimuth: 315, diameter: d)
            && !DialGeometry.isOnSun(onFace(315, 15.9), azimuth: 315, diameter: d)
            && !DialGeometry.isOnSun(onFace(315, 23), azimuth: .nan, diameter: d))

    var next = DialGeometry.Drag()
    check("each touch starts afresh: after a drag has swung the sun, the next touch-down on the readout has no bearing",
          following.isFollowing && next.bearing(at: CGPoint(x: 30, y: 38), diameter: d) == nil && !next.isFollowing)
    var bad = DialGeometry.Drag()
    let nanSample = bad.bearing(at: CGPoint(x: CGFloat.nan, y: 38), diameter: d)
    let afterNaN = bad.bearing(at: CGPoint(x: 30, y: 38), diameter: d)
    check("a sample that is not a number has no bearing and does not start the drag",
          nanSample == nil && afterNaN == nil && bad.start == CGPoint(x: 30, y: 38) && !bad.isFollowing,
          "\(String(describing: nanSample)), \(String(describing: afterNaN)), \(String(describing: bad.start))")

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

    checkSunDialCommit()
}

/// Runs (time, bearing) samples through a commit, firing each trailing write at its due time: the writes made.
private func sunWrites(_ samples: [(t: Double, deg: Double)], interval: Double = 0.05) -> [(t: Double, deg: Double)] {
    var commit = SunDialCommit(interval: interval)
    var writes: [(t: Double, deg: Double)] = []
    var due: Double?
    for s in samples {
        if let d = due, d <= s.t { due = nil; if let v = commit.fireTrailing(at: d) { writes.append((d, v)) } }
        switch commit.sample(s.deg, at: s.t) {
        case .write(let v): writes.append((s.t, v))
        case .scheduleTrailing(let d): due = d
        case .none: break
        }
    }
    if let d = due, let v = commit.fireTrailing(at: d) { writes.append((d, v)) }
    return writes
}

@MainActor
private func checkSunDialCommit() {
    print("\n--- X1. the dial's writes to the map's sun ---")
    func drag(hz: Double, degreesPerSecond: Double, seconds: Double = 1.5) -> [(t: Double, deg: Double)] {
        stride(from: 0.0, to: seconds, by: 1 / hz).map { ($0, (100 + degreesPerSecond * $0).truncatingRemainder(dividingBy: 360)) }
    }
    func maxGap(_ w: [(t: Double, deg: Double)]) -> Double { zip(w, w.dropFirst()).map { $1.t - $0.t }.max() ?? .infinity }
    func minGap(_ w: [(t: Double, deg: Double)]) -> Double { zip(w, w.dropFirst()).map { $1.t - $0.t }.min() ?? .infinity }
    // Both ways: often enough to re-light as the dial turns, and never two writes (two re-shades of every tile on
    // screen) closer than the interval, which is the throttle's reason to exist.
    for (hz, speed) in [(120.0, 90.0), (120.0, 360.0), (240.0, 90.0), (60.0, 20.0)] {
        let w = sunWrites(drag(hz: hz, degreesPerSecond: speed))
        check("a drag sampled at \(Int(hz)) Hz turning \(Int(speed))°/s writes the sun at least every 50 ms while it moves, and never sooner",
              w.count >= 25 && maxGap(w) <= 0.05 + 1 / hz + 1e-9 && minGap(w) >= 0.05 - 1e-9,
              "\(w.count) writes, gaps \(minGap(w)) to \(maxGap(w))")
    }
    let first = sunWrites([(0, 200.0)])
    check("the first sample of a drag writes at once", first.count == 1 && first[0].t == 0)
    let wander = sunWrites([(0, 100.2), (0.06, 100.3), (0.12, 99.8), (0.18, 100.4)])
    check("samples wandering within a degree of the bearing last written write nothing more", wander.count == 1, "\(wander)")
    // A touch at rest trembles. On the dial's ring a degree is half a point, so a finger or the Pencil resting near a
    // half degree crosses it on sub-point jitter; a rule of whole degrees wrote each crossing, a re-shade of every tile
    // on screen up to 20 times a second for a sun nobody sees move (the barrel roll met this: PencilRollAzimuth).
    let rest = sunWrites((0..<120).map { (Double($0) / 120, $0 % 2 == 0 ? 100.4 : 100.6) })
    check("a touch resting across a half degree, trembling 100.4° to 100.6° at 120 Hz for a second, writes once",
          rest.count == 1, "\(rest.count) writes")
    let north = sunWrites((0..<120).map { (Double($0) / 120, $0 % 2 == 0 ? 359.6 : 0.4) })
    check("a touch trembling across north, 359.6° to 0.4°, writes once (a degree measured around the circle)",
          north.count == 1, "\(north.count) writes")
    let back = sunWrites([(0, 100.0), (0.01, 101.5), (0.02, 100.2)])
    check("a bearing back within a degree of the one written drops the trailing write of the bearing it left",
          back.count == 1, "\(back)")
    var trailed = SunDialCommit(interval: 0.05)
    _ = trailed.sample(10, at: 0)
    _ = trailed.sample(12, at: 0.01)
    let trailedValue = trailed.fireTrailing(at: 0.05)
    check("a trailing write is the bearing the next ones are measured from: 12.4° 60 ms after writing 12° writes nothing",
          trailedValue == 12 && trailed.sample(12.4, at: 0.11) == .none)
    // A busy main thread can resume the trailing write's timer late. A sample that comes first writes at once; the
    // trailing write it overtook is void (the dock cancels its timer), so the next new bearing waits 50 ms from that
    // write rather than riding the stale timer to a write a few milliseconds after it.
    var late = SunDialCommit(interval: 0.05)
    _ = late.sample(10, at: 0)
    _ = late.sample(12, at: 0.01)
    let overtaking = late.sample(13, at: 0.06)
    let voided = late.trailingDue == nil
    let next = late.sample(15, at: 0.07)
    var nextDue: Double?
    if case .scheduleTrailing(let due) = next { nextDue = due }
    check("a sample overtaking a late trailing write writes, voids it, and the next bearing waits 50 ms from that write",
          overtaking == .write(13) && voided && abs((nextDue ?? -1) - 0.11) < 1e-9, "\(overtaking), voided \(voided), \(next)")
    var c = SunDialCommit(interval: 0.05)
    _ = c.sample(10, at: 0)
    let armed = c.sample(12, at: 0.01)
    _ = c.sample(14, at: 0.02)
    check("newer samples never move the trailing write later", armed == .scheduleTrailing(at: 0.05) && c.trailingDue == 0.05)
    check("the trailing write carries the newest bearing, not the one that armed it", c.fireTrailing(at: 0.05) == 14)
    check("a bearing that is not a number is ignored", c.sample(.nan, at: 1) == SunDialCommit.Step.none)
    c.reset()
    check("after a lift the next drag's first sample writes at once", c.sample(50, at: 1.001) == .write(50))
    // The check above would pass with a reset that does nothing: its sample is a new bearing, long after the last
    // write. A drag begun 9 ms after that write, within a degree of it, must start afresh: a commit carried over from
    // the last drag would hold its first sample back as the bearing already written.
    c.reset()
    check("after a lift a drag begun at once, within a degree of the last one's write, still writes its first sample at once",
          c.sample(50.3, at: 1.01) == .write(50.3))
}
