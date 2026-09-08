//
//  SpotInspection.swift
//  LidarExplorer
//
//  Spot elevation, slope angle/percentage, and aspect direction for a tapped coordinate.
//

import CoreLocation
import Foundation

public nonisolated struct SpotInspection: Equatable, Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let elevationMeters: Float
    public let slopeDegrees: Float
    public let aspectDegrees: Float

    public init(
        coordinate: CLLocationCoordinate2D,
        elevationMeters: Float,
        slopeDegrees: Float,
        aspectDegrees: Float
    ) {
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
    }

    public static func == (lhs: SpotInspection, rhs: SpotInspection) -> Bool {
        guard lhs.coordinate.latitude == rhs.coordinate.latitude &&
              lhs.coordinate.longitude == rhs.coordinate.longitude else {
            return false
        }
        let elevEqual = (lhs.elevationMeters == rhs.elevationMeters) || (lhs.elevationMeters.isNaN && rhs.elevationMeters.isNaN)
        let slopeEqual = (lhs.slopeDegrees == rhs.slopeDegrees) || (lhs.slopeDegrees.isNaN && rhs.slopeDegrees.isNaN)
        let aspectEqual = (lhs.aspectDegrees == rhs.aspectDegrees) || (lhs.aspectDegrees.isNaN && rhs.aspectDegrees.isNaN)
        return elevEqual && slopeEqual && aspectEqual
    }

    public var compassDirection: String {
        guard !aspectDegrees.isNaN else { return "Flat" }
        var deg = aspectDegrees.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        let val = Int((deg + 22.5) / 45.0) & 7
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return directions[val]
    }

    public var slopePercentFormatted: String {
        guard !slopeDegrees.isNaN, slopeDegrees >= 0 else { return "0%" }
        if slopeDegrees >= 89.9 { return ">1000%" }
        let radians = Double(slopeDegrees) * .pi / 180.0
        let percent = tan(radians) * 100.0
        return String(format: "%.0f%%", percent)
    }

    public func formattedElevation(unit: ElevationUnit) -> String {
        let value = unit.fromMeters(Double(elevationMeters))
        return String(format: "%.1f %@", value, unit.symbol)
    }
}
