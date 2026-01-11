//
//  SeedLocations.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import CoreLocation

struct SeedLocations {
    /// A curated list of National Parks for random startup locations
    static let nationalParks: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.3428, longitude: -105.6836), // Rocky Mountain NP
        CLLocationCoordinate2D(latitude: 37.2982, longitude: -113.0263), // Zion NP
        CLLocationCoordinate2D(latitude: 44.4280, longitude: -110.5885), // Yellowstone NP
        CLLocationCoordinate2D(latitude: 35.6118, longitude: -83.4895)   // Great Smoky Mountains
    ]
    
    /// Returns a random park from the list
    static var randomPark: CLLocationCoordinate2D {
        nationalParks.randomElement()!
    }
}