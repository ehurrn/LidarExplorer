//
//  LocationManager.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import Foundation
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var location: CLLocation?
    // Heading Removed: Handled by MKMapView system compass
    @Published var permissionStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        // Set the delegate before accessing authorization status
        self.permissionStatus = manager.authorizationStatus
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5 // Update every 5 meters
    }

    func startLocationServices() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // If we have permission, start updating location.
            manager.startUpdatingLocation()
        case .notDetermined:
            // If we don't have permission, request it.
            // The delegate callback will handle starting updates if permission is granted.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // The user has explicitly denied permission.
            // Do nothing. The app will remain on the placeholder.
            break
        @unknown default:
            // Handle future cases.
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Stop updating to save battery once we have an initial location.
        // The user can tap the location button to get a new update later.
        manager.stopUpdatingLocation()
        self.location = loc
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.permissionStatus = manager.authorizationStatus
        // This delegate method is called when the user responds to the permission prompt.
        // If they granted permission, we can now start updating the location.
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
