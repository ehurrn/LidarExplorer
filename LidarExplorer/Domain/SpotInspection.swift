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
    /// The value of the micro-topography product being shown, at the spot, when one is: what the map's colour
    /// at the tap stands for (the LRM's residual, the sky-view factor, a curvature...).
    public let productReading: ProductReading?

    /// One product's value at a spot, with how to read it.
    public struct ProductReading: Equatable, Sendable {
        public let product: MicroTopographyProduct
        public let value: Float

        public init(product: MicroTopographyProduct, value: Float) {
            self.product = product
            self.value = value
        }

        /// The row's label.
        public var label: String {
            switch product {
            case .localRelief: "Local relief"
            case .differenceOfGaussians: "Band-pass relief"
            case .skyView: "Sky-view factor"
            case .redRelief, .differentialOpenness: "Openness"
            case .positiveOpenness: "Positive openness"
            case .negativeOpenness: "Negative openness"
            case .rakingLight: "Raking light"
            case .relativeElevation: "Above river"
            case .habitation: "Habitation bench"
            case .curvature: "Curvature"
            case .directionalOcclusion: "Occlusion"
            case .vectorRuggedness: "Ruggedness"
            }
        }

        /// The value in the display unit: metres or feet for the height-like products, degrees, a fraction as a
        /// percentage, a curvature per unit length.
        public func formatted(unit: ElevationUnit) -> String {
            guard value.isFinite else { return "—" }
            let v = Double(value)
            switch product {
            case .localRelief, .differenceOfGaussians, .relativeElevation:
                return String(format: "%+.2f %@", unit.fromMeters(v), unit.symbol)
            case .skyView, .rakingLight, .directionalOcclusion:
                return String(format: "%.0f %%", v * 100)
            case .redRelief, .differentialOpenness:
                return String(format: "%+.1f°", v)
            case .positiveOpenness, .negativeOpenness:
                return String(format: "%.1f°", v)
            case .curvature:
                return unit == .feet ? String(format: "%+.4f/ft", v / 3.28083989501312) : String(format: "%+.3f/m", v)
            case .vectorRuggedness:
                return String(format: "%.4f", v)
            case .habitation:
                return v > 0.5 ? "Yes" : "No"
            }
        }
    }

    public init(
        coordinate: CLLocationCoordinate2D,
        elevationMeters: Float,
        slopeDegrees: Float,
        aspectDegrees: Float,
        productReading: ProductReading? = nil
    ) {
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
        self.productReading = productReading
    }

    /// The same spot with a product's reading attached.
    public func with(_ reading: ProductReading?) -> SpotInspection {
        SpotInspection(coordinate: coordinate, elevationMeters: elevationMeters, slopeDegrees: slopeDegrees,
                       aspectDegrees: aspectDegrees, productReading: reading)
    }

    public static func == (lhs: SpotInspection, rhs: SpotInspection) -> Bool {
        guard lhs.coordinate.latitude == rhs.coordinate.latitude &&
              lhs.coordinate.longitude == rhs.coordinate.longitude else {
            return false
        }
        let elevEqual = (lhs.elevationMeters == rhs.elevationMeters) || (lhs.elevationMeters.isNaN && rhs.elevationMeters.isNaN)
        let slopeEqual = (lhs.slopeDegrees == rhs.slopeDegrees) || (lhs.slopeDegrees.isNaN && rhs.slopeDegrees.isNaN)
        let aspectEqual = (lhs.aspectDegrees == rhs.aspectDegrees) || (lhs.aspectDegrees.isNaN && rhs.aspectDegrees.isNaN)
        return elevEqual && slopeEqual && aspectEqual && lhs.productReading == rhs.productReading
    }

    public var compassDirection: String {
        guard aspectDegrees.isFinite, slopeDegrees >= 0.5 else { return "Flat" }
        var deg = aspectDegrees.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        let val = Int((deg + 22.5) / 45.0) & 7
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return directions[val]
    }

    public var aspectFormatted: String {
        guard aspectDegrees.isFinite, slopeDegrees >= 0.5 else { return "Flat" }
        return String(format: "%.0f° · %@", aspectDegrees, compassDirection)
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
