//
//  LocationService.swift
//  LidarExplorer
//
//  CoreLocation bridge with an awaitable first fix.
//

import CoreLocation
import os

/// Delivers the device location to the main actor.
///
/// `@MainActor` on the class, with the `CLLocationManagerDelegate` callbacks
/// hopping onto it. CoreLocation invokes its delegate on the queue the manager
/// was created on, which here is the main queue, so this is accurate rather
/// than merely convenient.
@MainActor
public final class LocationService: NSObject, LocationProviding {

    /// Called on every authorisation change and location update.
    public var onUpdate: ((CLLocationCoordinate2D?, CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    /// Continuations awaiting the first fix, resumed exactly once each.
    private var pendingFixes: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []
    /// Bounded timeout task for obtaining a GPS fix once authorized.
    private var timeoutTask: Task<Void, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    /// Whether a status permits location updates.
    ///
    /// `authorizedWhenInUse` exists on iOS but not on macOS, so the
    /// difference is isolated here rather than repeated at each use. Keeping
    /// the file compiling for the host also lets the view model be exercised
    /// off-device.
    private nonisolated static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS) || os(watchOS) || os(tvOS)
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        return status == .authorizedAlways
        #endif
    }

    /// Begins observing location if permission already exists.
    ///
    /// Deliberately does not *request* permission. Prompting at launch asks
    /// before the user knows what the app is for, and here it landed on top
    /// of the first-run explanation. The request happens in
    /// ``currentLocation()`` instead — that is, when they tap the location
    /// button and the reason is self-evident.
    public func start() {
        let status = manager.authorizationStatus
        if Self.isAuthorized(status) {
            manager.startUpdatingLocation()
        }
        onUpdate?(manager.location?.coordinate, status)
    }

    /// Returns the current location, awaiting the first fix if necessary.
    ///
    /// This is what makes the "go to my location" button work on the first
    /// tap. Reading a cached value synchronously returns `nil` on first launch
    /// because authorisation is granted before any fix arrives.
    public func currentLocation() async -> CLLocationCoordinate2D? {
        if let existing = manager.location?.coordinate { return existing }

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }

        if status == .notDetermined {
            #if os(iOS) || os(watchOS) || os(tvOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
            // Do not start the 8-second timeout yet: the user may take arbitrary
            // time to read and approve the system permission dialog. The timeout
            // is started when authorization changes to authorized.
            return await withCheckedContinuation { continuation in
                pendingFixes.append(continuation)
            }
        }

        guard Self.isAuthorized(status) else { return nil }

        manager.startUpdatingLocation()

        return await withCheckedContinuation { continuation in
            pendingFixes.append(continuation)
            // Bound the wait so a device that never gets a fix (airplane mode,
            // indoors with location off) resolves instead of hanging the UI.
            startFixTimeout()
        }
    }

    private func startFixTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.resumePendingFixes(with: self?.manager.location?.coordinate)
        }
    }

    private func resumePendingFixes(with coordinate: CLLocationCoordinate2D?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !pendingFixes.isEmpty else { return }
        let waiting = pendingFixes
        pendingFixes.removeAll()
        for continuation in waiting { continuation.resume(returning: coordinate) }
    }
}

extension LocationService: CLLocationManagerDelegate {

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let coordinate = locations.last?.coordinate else { return }
        // Read the Sendable values out here. Capturing `manager` itself would
        // send a non-Sendable reference across the isolation hop.
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.onUpdate?(coordinate, status)
            self.resumePendingFixes(with: coordinate)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let status = manager.authorizationStatus
        let coordinate = manager.location?.coordinate
        MainActor.assumeIsolated {
            if Self.isAuthorized(status) {
                // Use the main-actor-isolated stored manager, not the
                // non-Sendable parameter handed to us by CoreLocation.
                self.manager.startUpdatingLocation()
                if !self.pendingFixes.isEmpty {
                    self.startFixTimeout()
                }
            } else if status == .denied || status == .restricted {
                self.resumePendingFixes(with: nil)
            }
            self.onUpdate?(coordinate, status)
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            Log.ui.error("Location failed: \(error.localizedDescription, privacy: .public)")
            self.resumePendingFixes(with: nil)
        }
    }
}
