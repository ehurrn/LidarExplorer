//
//  USGSMapView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import SwiftUI
import MapKit

struct USGSMapView: UIViewRepresentable {
    @Binding var opacity: Double
    @Binding var mapType: MKMapType
    @Binding var searchCoordinate: CLLocationCoordinate2D?
    @Binding var zoomLevel: Double
    @Binding var resetHeading: Bool
    @Binding var lidarSource: LidarSource
    
    var initialCoordinate: CLLocationCoordinate2D
    
    // MARK: - Lifecycle
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Configuration
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        
        // Compass
        mapView.showsCompass = false
        let compass = MKCompassButton(mapView: mapView)
        compass.compassVisibility = .visible
        mapView.addSubview(compass)
        compass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            compass.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -340),
            compass.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])
        
        // Map Configuration
        mapView.showsBuildings = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        
        // Add the initial Lidar overlay and cache it in the coordinator
        addLidarOverlay(to: mapView, source: lidarSource, coordinator: context.coordinator)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // We use the Coordinator to track if we've performed the initial setup.
        // This prevents updateUIView from reading the map's default center
        // during layout and overwriting our intended location.
        if !context.coordinator.hasSetInitialRegion {
            let targetSpan = sliderValueToSpan(zoomLevel)
            let region = MKCoordinateRegion(
                center: initialCoordinate,
                span: MKCoordinateSpan(latitudeDelta: targetSpan, longitudeDelta: targetSpan)
            )
            mapView.setRegion(region, animated: false)
            context.coordinator.hasSetInitialRegion = true
            return // Stop here for this update cycle
        }
        
        // --- Standard Updates ---
        
        // Update map type if it has changed
        if mapView.mapType != mapType {
            mapView.mapType = mapType
        }
        
        // Handle one-shot heading reset
        if resetHeading {
            let currentCamera = mapView.camera
            let newCamera = MKMapCamera(lookingAtCenter: currentCamera.centerCoordinate,
                                      fromDistance: currentCamera.altitude,
                                      pitch: currentCamera.pitch,
                                      heading: 0)
            mapView.setCamera(newCamera, animated: true)
            DispatchQueue.main.async { self.resetHeading = false }
        }
        
        // Update overlay opacity using the cached renderer reference
        if let renderer = context.coordinator.tileRenderer, renderer.alpha != CGFloat(opacity) {
            renderer.alpha = CGFloat(opacity)
        }
        
        // Update Lidar source if it has changed, using the cached overlay reference
        if context.coordinator.dynamicOverlay?.currentSource != lidarSource {
            addLidarOverlay(to: mapView, source: lidarSource, coordinator: context.coordinator)
        }
        
        // Handle one-shot navigation to a search result
        if let target = searchCoordinate {
            let region = MKCoordinateRegion(center: target, latitudinalMeters: 1000, longitudinalMeters: 1000)
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.searchCoordinate = nil }
        }
        
        // Synchronize map zoom with the slider value
        syncZoomLevel(for: mapView)
    }
    
    // MARK: - Coordinator
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: USGSMapView
        var hasSetInitialRegion = false
        
        // Cache references to the overlay and its renderer to avoid expensive lookups.
        // `weak` prevents potential retain cycles with the map view.
        weak var dynamicOverlay: DynamicLidarOverlay?
        weak var tileRenderer: MKTileOverlayRenderer?
        
        init(_ parent: USGSMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let lidarOverlay = overlay as? DynamicLidarOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: lidarOverlay)
                renderer.alpha = CGFloat(parent.opacity)
                self.tileRenderer = renderer // Cache the renderer for direct access
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Only update the slider if we are fully initialized and the map is stable
            guard hasSetInitialRegion, mapView.frame.width > 0 else { return }
            
            // Convert map's current span to a 0-1 slider value
            let span = mapView.region.span.latitudeDelta
            let ratio = 0.002 / 90.0
            let rawValue = log(span / 90.0) / log(ratio)
            
            DispatchQueue.main.async {
                // Clamp the value to the valid 0-1 range
                self.parent.zoomLevel = min(max(rawValue, 0), 1)
            }
        }
    }
    
    // MARK: - Private Helpers

    /// Replaces the existing Lidar overlay with a new one for the given source.
    private func addLidarOverlay(to mapView: MKMapView, source: LidarSource, coordinator: Coordinator) {
        // Remove the old overlay if it exists
        if let oldOverlay = coordinator.dynamicOverlay {
            mapView.removeOverlay(oldOverlay)
        }
        
        // Create and configure the new overlay
        let newOverlay = DynamicLidarOverlay(source: source)
        newOverlay.canReplaceMapContent = false
        newOverlay.minimumZ = 0
        newOverlay.maximumZ = 20
        mapView.addOverlay(newOverlay, level: .aboveLabels)
        
        // Cache the new overlay in the coordinator
        coordinator.dynamicOverlay = newOverlay
    }
    
    /// Updates the map's zoom level based on the slider, preventing feedback loops.
    private func syncZoomLevel(for mapView: MKMapView) {
        // We only run this if the map is stable (has a frame) to avoid jitter
        guard mapView.frame.width > 0 else { return }
        
        let currentSpan = mapView.region.span.latitudeDelta
        let targetSpan = sliderValueToSpan(zoomLevel)
        
        // Only trigger a map update if the desired span differs by more than 10%.
        // This tolerance prevents a feedback loop between the map and the slider.
        if abs(currentSpan - targetSpan) > (currentSpan * 0.1) {
            var region = mapView.region
            region.span = MKCoordinateSpan(latitudeDelta: targetSpan, longitudeDelta: targetSpan)
            mapView.setRegion(region, animated: true)
        }
    }
    
    /// Converts a linear slider value (0-1) to an exponential map span.
    private func sliderValueToSpan(_ value: Double) -> Double {
        // This exponential formula provides a more natural "feel" for a zoom slider.
        return 90.0 * pow(0.002 / 90.0, value)
    }
}
