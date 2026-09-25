//
//  PencilRollAzimuth.swift
//  LidarExplorer
//
//  When an Apple Pencil Pro barrel roll moves the sun, decided apart from the hover recognizer that reports it.
//
//  Every hover sample carries a roll angle, and no hand holds one still: a pencil at rest trembles by fractions of
//  a degree. Written straight to the azimuth, each sample was a new value, so each one re-shaded every visible
//  tile, a stream of reloads for a sun that had not visibly moved. A deadband against the current azimuth ends
//  that; the geometry is testable on any host, and the map's hover handler only asks and applies.
//

import Foundation

/// The sun azimuth a pencil's barrel roll asks for.
public nonisolated enum PencilRollAzimuth {
    /// How far, in degrees, the roll must sit from the current azimuth before the sun follows.
    ///
    /// A whole degree: the azimuth dial shows whole degrees, a degree of sun is barely visible in the relief, and
    /// hand tremor stays well inside it.
    public static let deadband = 1.0

    /// The azimuth to set for a roll of `radians`, or `nil` to leave `current` alone.
    ///
    /// The roll maps onto the compass (a negative roll wraps) and is rounded to a whole degree, 360 being north.
    /// It moves the sun only once it lies at least ``deadband`` from `current` around the circle, so tremor, and
    /// tremor across north, change nothing. A roll of exactly zero is not a reading: a pencil without a gyroscope
    /// and a trackpad pointer both report zero. Neither is a value that is not a number.
    public static func azimuth(forRoll radians: Double, current: Double) -> Double? {
        guard radians != 0, radians.isFinite else { return nil }
        var degrees = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        var offset = abs(degrees - current).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset = 360 - offset }
        guard offset >= deadband else { return nil }
        let whole = degrees.rounded()
        return whole == 360 ? 0 : whole
    }
}
