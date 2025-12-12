//
//  USGSMapView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 12/12/25.
//


import SwiftUI
import MapKit

struct USGSMapView: UIViewRepresentable {
    @Binding var opacity: Double
    @Binding var mapType: MKMapType
    @Binding var searchCoordinate: CLLocationCoordinate2D?
    @Binding var zoomLevel: Double
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.mapType = .standard
        
        // USE THE NEW DYNAMIC OVERLAY
        let overlay = DynamicLidarOverlay(urlTemplate: nil)
        overlay.canReplaceMapContent = false
        overlay.minimumZ = 0
        overlay.maximumZ = 20 // We can now zoom DEEP
        
        mapView.addOverlay(overlay, level: .aboveLabels)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        if mapView.mapType != mapType { mapView.mapType = mapType }
        
        // Update Opacity
        if let overlay = mapView.overlays.first(where: { $0 is DynamicLidarOverlay }), // Check for our custom class
           let renderer = mapView.renderer(for: overlay) as? MKTileOverlayRenderer {
            renderer.alpha = CGFloat(opacity)
        }
        
        // Fly to Search
        if let target = searchCoordinate {
            let region = MKCoordinateRegion(center: target, latitudinalMeters: 2000, longitudinalMeters: 2000)
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.searchCoordinate = nil }
        }
        
        // Zoom Logic (Reverted to allow Deep Zoom)
        let currentSpan = mapView.region.span.latitudeDelta
        let targetSpan = sliderValueToSpan(zoomLevel)
        
        if abs(currentSpan - targetSpan) > (currentSpan * 0.1) {
            var region = mapView.region
            region.span = MKCoordinateSpan(latitudeDelta: targetSpan, longitudeDelta: targetSpan)
            mapView.setRegion(region, animated: true)
        }
    }
    
    // NEW MATH: Allows Deep Zoom (0.002 degrees)
    func sliderValueToSpan(_ value: Double) -> Double {
        // Zoom Out (0.0) -> 90.0 degrees
        // Zoom In (1.0) -> 0.002 degrees (House level)
        return 90.0 * pow(0.002 / 90.0, value)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: USGSMapView
        init(_ parent: USGSMapView) { self.parent = parent }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = CGFloat(parent.opacity)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let span = mapView.region.span.latitudeDelta
            let ratio = 0.002 / 90.0
            let rawValue = log(span / 90.0) / log(ratio)
            
            DispatchQueue.main.async {
                self.parent.zoomLevel = min(max(rawValue, 0), 1)
            }
        }
    }
}