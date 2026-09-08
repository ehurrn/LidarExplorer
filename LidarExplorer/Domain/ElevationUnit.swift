//
//  ElevationUnit.swift
//  LidarExplorer
//
//  Display units for elevation readouts.
//

import Foundation

public nonisolated enum ElevationUnit: String, CaseIterable, Sendable {
    case feet
    case meters

    public var title: String {
        switch self {
        case .feet: return "Feet (ft)"
        case .meters: return "Meters (m)"
        }
    }

    public var symbol: String {
        switch self {
        case .feet: return "ft"
        case .meters: return "m"
        }
    }

    public func fromMeters(_ meters: Double) -> Double {
        switch self {
        case .feet: return meters * 3.28083989501312
        case .meters: return meters
        }
    }
}
