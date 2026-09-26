//
//  PencilRollAzimuth.swift
//  LidarExplorer
//
//  When an Apple Pencil Pro barrel roll moves the sun, decided apart from the hover recognizer that reports it.
//
//  Every hover sample carries a roll angle, and no hand holds one still: a pencil at rest trembles by fractions of
//  a degree. Written straight to the azimuth, each sample was a new value, so each one re-shaded every visible
//  tile, a stream of reloads for a sun that had not visibly moved. A deadband measured from the sun was not
//  enough: a move put the sun on the rounded roll, so turning back half a degree to a degree and a half put the
//  roll a whole degree from it again, and a steady one-degree tremor flipped the sun on every sample. The sun now
//  trails the roll by a backlash, which a reversal must take up before the sun moves back. The geometry is
//  testable on any host; the map's hover handler only asks and applies.
//

import Foundation

/// The sun azimuth a pencil's barrel roll asks for.
public nonisolated enum PencilRollAzimuth {
    /// How far, in degrees, the sun trails the roll that moves it.
    ///
    /// One degree, so a reversal travels at least two before the sun moves back, and a flicker of up to 2 degrees
    /// peak to peak about where the sun points never moves it (the old rule moved it on every sample of a 1-degree
    /// flicker). The owner's device test of the old rule, which reversed on half a degree to a degree and a half,
    /// saw no flicker from a pencil held still and found the roll right, so a real hand trembles less than the
    /// heavy-hand model below, and a larger backlash would only add trail to a feel already approved.
    ///
    /// Measured on 1,000-sample windows of Gaussian tremor (500 seeds, centres every 0.05 degree, the sun starting
    /// where the pencil points), as changes per 1,000 samples, the mean at the worst centre (halfway between
    /// degrees) and the worst window; and the trail, how far the sun sits behind a pencil rolling slowly:
    ///
    /// - Old rule: sigma 0.3 mean 48, worst 70; sigma 0.4 mean 111, worst 138; trail 0 to 1, mean 0.5.
    /// - 1.0: sigma 0.3 mean 0.44, worst 4; sigma 0.4 mean 6.3, worst 16; trail 0.5 to 1.5, mean 1.0.
    /// - 1.5: sigma 0.3 none; sigma 0.4 mean 0.1, worst 2; trail 1 to 2, mean 1.5.
    ///
    /// If a device measurement finds tremor near sigma 0.4, 1.5 all but ends it for half a degree more trail.
    public static let backlash = 1.0

    /// The azimuth to set for a hover sample rolled `radians` with the sun at `current`, or `nil` to leave it.
    ///
    /// The roll maps onto the compass (a negative roll wraps). Once it lies more than ``backlash`` from `current`
    /// around the circle, the sun moves to trail it by ``backlash``, to the whole degree, north being 0, never 360.
    /// Rolling one way, the sun follows a backlash behind. Turning back, the roll must first come back past the sun
    /// and a backlash beyond it, at least twice ``backlash`` from where it turned, so a hand trembling by less than
    /// that leaves the sun alone. Measured from the sun as it stands, a sun moved by anything else (the dock
    /// slider, Reset Shading, a landmark flight) is where the next reading starts from. The slider leaves the sun
    /// between whole degrees, where the whole degree a roll trails to can lie a fraction of a degree from it, even
    /// behind it: a move of less than ``minimumMove`` is no move, so the sun never takes a re-shade of every tile for
    /// a change no one sees, and never steps against the roll. A roll of exactly zero is not a reading: a pencil
    /// without a gyroscope and a trackpad pointer both report zero. Neither is a value that is not a number.
    public static func azimuth(forRoll radians: Double, current: Double) -> Double? {
        guard radians != 0, radians.isFinite else { return nil }
        let roll = compass(radians * 180 / .pi)
        let offset = (roll - current).remainder(dividingBy: 360) // which way round, and how far
        guard abs(offset) > backlash else { return nil }
        let whole = compass(roll - (offset > 0 ? backlash : -backlash)).rounded()
        let azimuth = whole == 360 ? 0 : whole
        // Measured around the circle: north is 0.2 from a sun at 359.8, not 359.8.
        return abs((azimuth - current).remainder(dividingBy: 360)) < minimumMove ? nil : azimuth
    }

    /// The least a roll moves the sun, in degrees. The whole degree a roll trails to can lie up to (not quite) half a
    /// degree behind a sun set between degrees, against the roll (a sun at 44.3 rolled to 45.4 would go to 44), so a
    /// shorter move is rounding, not a turn.
    public static let minimumMove = 0.5

    /// `degrees` wrapped onto the compass, [0, 360).
    private static func compass(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        guard wrapped < 0 else { return wrapped }
        return wrapped + 360 < 360 ? wrapped + 360 : 0
    }
}
