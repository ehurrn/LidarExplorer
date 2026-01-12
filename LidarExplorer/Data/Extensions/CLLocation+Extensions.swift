//
//  CLLocation+Extensions.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import CoreLocation

// Extends CLLocationCoordinate2D to be Hashable and Equatable.
// This allows coordinates to be used as keys in Dictionaries (for caching)
// and Sets, which is critical for the future Bookmarks and Offline Mode features.
extension CLLocationCoordinate2D: @retroactive Hashable, @retroactive Equatable {
    
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        // Standard equality check.
        // Note: Floating point comparisons can be tricky, but for map keys,
        // exact matches are usually what we want.
        return lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}
