//
//  LocationProviding.swift
//  LidarExplorer
//
//  Abstraction over the device location source.
//

import CoreLocation

/// Supplies the device location to the viewer.
///
/// A protocol for the same reason ``ElevationProviding`` is one: it lets the
/// view model be driven without CoreLocation, and keeps the model free of a
/// platform-specific dependency it does not otherwise need.
@MainActor
public protocol LocationProviding: AnyObject {
    /// Called on every authorisation change and location update.
    var onUpdate: ((CLLocationCoordinate2D?, CLAuthorizationStatus) -> Void)? { get set }
    /// Begins observing location, requesting permission if required.
    func start()
    /// The current location, awaiting the first fix if one has not arrived.
    func currentLocation() async -> CLLocationCoordinate2D?
}
