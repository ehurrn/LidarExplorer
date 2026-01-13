//
//  USGSMapView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/12/26.
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
            compass.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -357),
            compass.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -27.5)
        ])
        
        // Map Configuration
        mapView.showsBuildings = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        
        // Add the initial Lidar overlay and cache it in the coordinator
        addLidarOverlay(to: mapView, source: lidarSource, coordinator: context.coordinator)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // THE FIX: Update the coordinator's parent to the current struct instance
        context.coordinator.parent = self

        // We use the Coordinator to track if we've performed the initial setup.
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
        
        // Update overlay opacity for ALL renderers (Anchor + Detail)
        for renderer in context.coordinator.renderers {
            if renderer.alpha != CGFloat(opacity) {
                renderer.alpha = CGFloat(opacity)
            }
        }
        
        // Update Lidar source if it has changed.
        // We check the 'mainOverlay' (the detail layer) to see if the source matches.
        if context.coordinator.mainOverlay?.currentSource != lidarSource {
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
        
        // Track both overlays for the Dual-Layer Strategy
        weak var mainOverlay: DynamicLidarOverlay?   // The high-res detail layer
        weak var anchorOverlay: DynamicLidarOverlay? // The background anchor layer
        
        // Track all active renderers to update opacity efficiently
        var renderers: [MKTileOverlayRenderer] = []
        
        init(_ parent: USGSMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let lidarOverlay = overlay as? DynamicLidarOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: lidarOverlay)
                renderer.alpha = CGFloat(parent.opacity)
                // Cache the renderer so we can update its opacity in updateUIView
                self.renderers.append(renderer)
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

    /// Replaces the existing Lidar overlay(s) with new ones based on the source strategy.
    private func addLidarOverlay(to mapView: MKMapView, source: LidarSource, coordinator: Coordinator) {
        // 1. Cleanup: Remove old overlays and clear cached renderers
        if let oldMain = coordinator.mainOverlay { mapView.removeOverlay(oldMain) }
        if let oldAnchor = coordinator.anchorOverlay { mapView.removeOverlay(oldAnchor) }
        coordinator.renderers.removeAll()
        
        // 2. Strategy Selection
        if source.type == .staticTiles {
            // STRATEGY A: Dual Layer (Smooth Loading)
            // Use this for Hillshade/Static types to get the infinite zoom background.
            
            // Layer 1: The Anchor (Background)
            // It stops fetching at Z14, forcing MapKit to stretch these tiles for Z15+.
            // This provides immediate visual context (blurry is better than blank).
            let anchor = DynamicLidarOverlay(source: source)
            anchor.canReplaceMapContent = false
            anchor.maximumZ = 14
            mapView.addOverlay(anchor, level: .aboveLabels)
            coordinator.anchorOverlay = anchor
            
            // Layer 2: The Detail (Foreground)
            // It starts fetching at Z15 using the Dynamic/Hybrid logic.
            // This loads crisp tiles on top of the anchor.
            let detail = DynamicLidarOverlay(source: source)
            detail.canReplaceMapContent = false
            detail.minimumZ = 15
            detail.maximumZ = 20
            mapView.addOverlay(detail, level: .aboveLabels)
            coordinator.mainOverlay = detail
            
        } else {
            // STRATEGY B: Single Layer (Dynamic Only)
            // Multidirectional has no static equivalent, so we use standard single-layer behavior.
            let overlay = DynamicLidarOverlay(source: source)
            overlay.canReplaceMapContent = false
            overlay.minimumZ = 0
            overlay.maximumZ = 20
            mapView.addOverlay(overlay, level: .aboveLabels)
            coordinator.mainOverlay = overlay
        }
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
