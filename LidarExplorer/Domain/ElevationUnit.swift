//
//  ElevationUnit.swift
//  LidarExplorer
//
//  Display units for elevation readouts.
//

import Foundation

public enum ElevationUnit: String, CaseIterable, Sendable {
    case feet
    case meters

    public var title: String {
        switch self {
        case .feet: return "Feet (ft)"
        case .meters: return "Meters (m)"
        }
    }
}
