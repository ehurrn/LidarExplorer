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

/// The azimuth changes a stream of roll readings (degrees) produces, starting from `start`.
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

@MainActor
func checkPencilRollAzimuth() {
    print("\n--- W1. roll to azimuth ---")
    // A pencil held at 45 degrees, trembling by up to 0.4 degrees, for a thousand hover samples.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    let tremor = (0..<1000).map { _ -> Double in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return 45 + (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.8
    }
    check("a trembling hand moves the sun once, not on every hover sample",
          applied(tremor, from: 315) == [45], "\(applied(tremor, from: 315).count) changes")

    let sweep = stride(from: 0.0, through: 90.0, by: 0.1).map { $0 }
    let steps = applied(sweep, from: 0)
    check("a slow deliberate roll turns the sun in whole degrees", steps.allSatisfy { $0 == $0.rounded() })
    check("a slow roll changes the sun at most once a degree", steps.count <= 90, "\(steps.count)")
    check("a slow roll ends where the pencil stopped", steps.last == 90)

    check("a negative roll wraps onto the compass",
          PencilRollAzimuth.azimuth(forRoll: -.pi / 2, current: 0) == 270)
    check("a roll rounding up to 360 is north",
          PencilRollAzimuth.azimuth(forRoll: 359.6 * .pi / 180, current: 180) == 0)
    check("tremor across north does not move the sun",
          PencilRollAzimuth.azimuth(forRoll: 359.8 * .pi / 180, current: 0) == nil
            && PencilRollAzimuth.azimuth(forRoll: 0.3 * .pi / 180, current: 359.8) == nil)
    check("a whole degree across north does move it",
          PencilRollAzimuth.azimuth(forRoll: 1.0 * .pi / 180, current: 359.5) == 1)
    check("a roll of exactly zero (no gyroscope, or a trackpad pointer) is not a reading",
          PencilRollAzimuth.azimuth(forRoll: 0, current: 90) == nil)
    check("a roll that is not a number is not a reading",
          PencilRollAzimuth.azimuth(forRoll: .nan, current: 90) == nil
            && PencilRollAzimuth.azimuth(forRoll: .infinity, current: 90) == nil)
}
