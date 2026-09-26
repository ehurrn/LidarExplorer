//
//  PencilRollChecks.swift
//  ViewerHarness
//
//  When an Apple Pencil Pro barrel roll moves the sun. Every hover sample carries a roll angle, and a hand never
//  holds one still, so the rule that turns those samples into azimuth changes decides how often the terrain is
//  re-shaded. Pure logic, so a trembling hand is tested without a pencil.
//

import Foundation

@MainActor
func runPencilRollChecks() {
    print("\n=== Pencil barrel roll ===")
    checkPencilRollAzimuth()
}

/// The azimuth changes a stream of roll readings (degrees) produces, the sun starting at `start`.
private func applied(_ rollsDegrees: [Double], from start: Double) -> [Double] {
    var azimuth = start
    var out: [Double] = []
    for roll in rollsDegrees {
        if let next = PencilRollAzimuth.azimuth(forRoll: roll * .pi / 180, current: azimuth) {
            azimuth = next
            out.append(next)
        }
    }
    return out
}

/// What one reading does to a sun at `sun`.
private func first(_ rollDegrees: Double, sun: Double) -> Double? {
    PencilRollAzimuth.azimuth(forRoll: rollDegrees * .pi / 180, current: sun)
}

/// A hand trembling about `centre` with a Gaussian spread of `sigma` degrees, one reading per hover sample.
///
/// Box-Muller over a fixed linear congruential generator, so every run sees the same hand.
private func gaussianTremor(centre: Double, sigma: Double, count: Int, seed: UInt64) -> [Double] {
    var state = seed
    func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    return (0..<count).map { _ in
        let u1 = 1 - uniform() // in (0, 1], so the logarithm is finite
        let u2 = uniform()
        return centre + sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A hand flicking between two rolls `peakToPeak` apart about `centre`, every sample.
private func squareTremor(centre: Double, peakToPeak: Double, count: Int) -> [Double] {
    (0..<count).map { $0.isMultiple(of: 2) ? centre - peakToPeak / 2 : centre + peakToPeak / 2 }
}

/// The whole-degree azimuth nearest `degrees`, north being 0.
private func wholeAzimuth(_ degrees: Double) -> Double {
    let whole = degrees.rounded()
    return whole == 360 ? 0 : whole
}

/// Whether each azimuth is one degree on from the one before, clockwise (`+1`) or anticlockwise (`-1`), across north.
private func stepsByOneDegree(_ azimuths: [Double], from start: Double, direction: Double) -> Bool {
    var previous = start
    for azimuth in azimuths {
        var step = (azimuth - previous).truncatingRemainder(dividingBy: 360)
        if step > 180 { step -= 360 } else if step < -180 { step += 360 }
        guard step == direction, azimuth >= 0, azimuth < 360 else { return false }
        previous = azimuth
    }
    return true
}

@MainActor
func checkPencilRollAzimuth() {
    print("\n--- W1. roll to azimuth ---")

    // The backlash: the sun sits a degree behind the roll that moved it, so it moves only once the roll is a
    // degree plus the half degree of rounding past it. These pin the backlash to within 0.02 of 1.0.
    check("from a sun at 45, a roll to 46.48 leaves it (a degree of backlash and half a degree of rounding)",
          first(46.48, sun: 45) == nil, "\(String(describing: first(46.48, sun: 45)))")
    check("from a sun at 45, a roll to 46.52 moves it to 46, a degree behind the pencil",
          first(46.52, sun: 45) == 46, "\(String(describing: first(46.52, sun: 45)))")
    check("from a sun at 45, a roll to 43.52 leaves it and one to 43.48 moves it to 44",
          first(43.52, sun: 45) == nil && first(43.48, sun: 45) == 44,
          "\(String(describing: first(43.52, sun: 45))), \(String(describing: first(43.48, sun: 45)))")

    // A reversal must come back past the sun and a backlash beyond it before the sun moves back: after a roll to
    // 50.2 the sun sits at 49 (from 49.2), and it steps back to 48 only below a roll of 47.5.
    let turnBack = applied([50.2, 47.55], from: 45)
    let turnedBack = applied([50.2, 47.45], from: 45)
    check("turning back, the pencil travels at least twice the backlash before the sun follows",
          turnBack == [49] && turnedBack == [49, 48], "\(turnBack), \(turnedBack)")

    // A pencil held at 45 degrees, trembling by up to 0.4 degrees, for two thousand hover samples, entering the
    // hover with the sun far away at 315. It moves the sun on entry, perhaps once more as the tremor finds its
    // edge, then never again.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    let tremor = (0..<2000).map { _ -> Double in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return 45 + (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.8
    }
    let entered = applied(tremor, from: 315)
    check("a trembling hand moves the sun on entry and settles, not on every hover sample",
          (1...2).contains(entered.count) && abs((entered.last ?? 315) - 45) <= 1.5, "\(entered)")

    // Gaussian tremor held where the sun points, at centres on, between and halfway between whole degrees, and
    // either side of north. The old rule re-anchored on the rounded sun and flickered most at x.5: 48 changes per
    // 1,000 samples on average at sigma 0.3, 111 at sigma 0.4. The bounds are the worst a backlash of 1.0 reached
    // in 11,000 simulated windows (500 seeds, centres every 0.05 degree); see PencilRollAzimuth.backlash.
    let centres = [45.0, 45.25, 45.5, 45.75, 0.0, 359.5]
    let seeds: [UInt64] = [0x5EED_0001, 0x5EED_0002, 0x5EED_0003]
    for (sigma, bound) in [(0.3, 4), (0.4, 16)] {
        var worst = (changes: 0, centre: 0.0)
        for centre in centres {
            for seed in seeds {
                let changes = applied(gaussianTremor(centre: centre, sigma: sigma, count: 1000, seed: seed),
                                      from: wholeAzimuth(centre)).count
                if changes > worst.changes { worst = (changes, centre) }
            }
        }
        check("a hand trembling with sigma \(sigma) degrees, held where the sun points, moves it at most \(bound) "
                + "times per 1,000 samples at any centre",
              worst.changes <= bound, "worst \(worst.changes) changes at centre \(worst.centre)")
    }

    // The same heavy hand entering the hover with the sun far away: the entry moves the sun, and after that the
    // tremor moves it no more than it would a sun already where the pencil points.
    var worstSettled = (changes: 0, centre: 0.0)
    var movedOnEntry = true
    for centre in centres {
        for seed in seeds {
            let readings = gaussianTremor(centre: centre, sigma: 0.4, count: 2000, seed: seed)
            movedOnEntry = movedOnEntry && first(readings[0], sun: 315) != nil
            var sun = 315.0
            for roll in readings[..<1000] {
                if let next = PencilRollAzimuth.azimuth(forRoll: roll * .pi / 180, current: sun) { sun = next }
            }
            let settled = applied(Array(readings[1000...]), from: sun).count
            if settled > worstSettled.changes { worstSettled = (settled, centre) }
        }
    }
    check("entering with the sun far away, a hand trembling with sigma 0.4 degrees moves it on entry, then at most "
            + "16 times in the next 1,000 samples",
          movedOnEntry && worstSettled.changes <= 16,
          "moved on entry: \(movedOnEntry); worst \(worstSettled.changes) changes at centre \(worstSettled.centre)")

    // Square-wave tremor: every sample flicks to the other side. Between 45.0 and 46.0 the old rule moved the sun
    // on 999 samples of 1,000.
    for (label, spans) in [("1.0", [1.0]), ("1.4 to 1.5", [1.4, 1.5])] {
        var worst = (changes: 0, centre: 0.0)
        for span in spans {
            for centre in [45.0, 45.25, 45.5, 45.75, 0.0, 359.5] {
                let changes = applied(squareTremor(centre: centre, peakToPeak: span, count: 1000),
                                      from: wholeAzimuth(centre)).count
                if changes > worst.changes { worst = (changes, centre) }
            }
        }
        check("a \(label) degree peak-to-peak flicker, as between 45.0 and 46.0, does not move the sun at any centre",
              worst.changes == 0, "worst \(worst.changes) changes at centre \(worst.centre)")
    }

    let sweep = stride(from: 0.0, through: 90.0, by: 0.1).map { $0 }
    let steps = applied(sweep, from: 0)
    check("a slow deliberate roll turns the sun in whole degrees", steps.allSatisfy { $0 == $0.rounded() })
    check("a slow roll changes the sun at most once a degree, one degree at a time",
          steps.count <= 90 && stepsByOneDegree(steps, from: 0, direction: 1), "\(steps.count) changes")
    check("a slow roll from 0 to 90 ends within a degree of where the pencil stopped",
          abs(90 - (steps.last ?? 0)) <= 1, "\(String(describing: steps.last))")
    let stopped = applied(stride(from: 0.0, through: 37.3, by: 0.1).map { $0 }, from: 0).last ?? 0
    check("a slow roll stopping between degrees ends within the backlash and half a degree of the pencil",
          abs(37.3 - stopped) <= 1.5, "\(stopped)")

    // Across north, both ways: one degree at a time, 359 to 0 and back, never 360 and never a jump.
    let upAcross = applied(stride(from: 355.0, through: 365.0, by: 0.1).map { $0 }, from: 355)
    check("a slow roll clockwise across north steps 358, 359, 0, 1 without a jump or a 360",
          upAcross.contains(0) && stepsByOneDegree(upAcross, from: 355, direction: 1), "\(upAcross)")
    let downAcross = applied(stride(from: 5.0, through: -5.0, by: -0.1).map { $0 }, from: 5)
    check("a slow roll anticlockwise across north steps 1, 0, 359, 358 without a jump",
          downAcross.contains(359) && stepsByOneDegree(downAcross, from: 5, direction: -1), "\(downAcross)")
    check("a flicker across north does not move the sun",
          applied(squareTremor(centre: 0, peakToPeak: 1.4, count: 1000), from: 0).isEmpty
            && applied(squareTremor(centre: 359.6, peakToPeak: 1.4, count: 1000), from: 0).isEmpty)
    check("a negative roll wraps onto the compass, a degree behind the pencil",
          first(-89.3, sun: 0) == 272, "\(String(describing: first(-89.3, sun: 0)))")
    check("an azimuth rounding to 360 is north, reached either way round",
          first(0.7, sun: 270) == 0 && first(358.8, sun: 90) == 0,
          "\(String(describing: first(0.7, sun: 270))), \(String(describing: first(358.8, sun: 90)))")

    check("a roll of exactly zero (no gyroscope, or a trackpad pointer) is not a reading",
          first(0, sun: 90) == nil)
    check("a roll that is not a number is not a reading",
          first(.nan, sun: 90) == nil && first(.infinity, sun: 90) == nil && first(-.infinity, sun: 90) == nil)

    // A sun set by anything else while the pencil hovers (the dock slider, Reset Shading, a landmark fly-to) is
    // where the pencil's next reading is measured from.
    let reset = applied([50.2], from: 45) == [49] ? first(49.3, sun: 315) : nil
    check("a sun set elsewhere while hovering is where the pencil's next reading is measured from",
          reset == 48, "\(String(describing: reset))")
}
