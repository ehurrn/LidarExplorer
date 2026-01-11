//
//  USGSMapView.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import SwiftUI
import MapKit

struct USGSMapView: UIViewRepresentable {
    @Binding var opacity: Double
    @Binding var mapType: MKMapType
    @Binding var searchCoordinate: CLLocationCoordinate2D?
    @Binding var zoomLevel: Double
    @Binding var resetHeading: Bool
    
    // NEW: Control the source
    @Binding var lidarSource: LidarSource
    
    var initialCoordinate: CLLocationCoordinate2D
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // 1. Set Region (Async fix)
        DispatchQueue.main.async {
            let region = MKCoordinateRegion(center: initialCoordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
            mapView.setRegion(region, animated: false)
        }
        
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.showsCompass = false
        
        let compass = MKCompassButton(mapView: mapView)
        compass.compassVisibility = .visible
        mapView.addSubview(compass)
        
        compass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            compass.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -330),
            compass.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -28)
        ])
        
        mapView.showsBuildings = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        
        // 2. Add Initial Overlay with correct source
        let overlay = DynamicLidarOverlay(urlTemplate: nil)
        overlay.currentSource = lidarSource
        overlay.canReplaceMapContent = false
        overlay.minimumZ = 0
        overlay.maximumZ = 20
        mapView.addOverlay(overlay, level: .aboveLabels)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        if mapView.mapType != mapType { mapView.mapType = mapType }
        
        if resetHeading {
            let currentCamera = mapView.camera
            let newCamera = MKMapCamera(lookingAtCenter: currentCamera.centerCoordinate,
                                      fromDistance: currentCamera.altitude,
                                      pitch: currentCamera.pitch,
                                      heading: 0)
            mapView.setCamera(newCamera, animated: true)
            DispatchQueue.main.async { self.resetHeading = false }
        }
        
        // 3. SOURCE SWITCHING LOGIC
        if let overlay = mapView.overlays.first(where: { $0 is DynamicLidarOverlay }) as? DynamicLidarOverlay {
            
            // If the source selection has changed, we must swap the overlay
            if overlay.currentSource != lidarSource {
                mapView.removeOverlay(overlay)
                
                let newOverlay = DynamicLidarOverlay(urlTemplate: nil)
                newOverlay.currentSource = lidarSource
                newOverlay.canReplaceMapContent = false
                newOverlay.minimumZ = 0
                newOverlay.maximumZ = 20
                mapView.addOverlay(newOverlay, level: .aboveLabels)
            } else {
                // Just update opacity if source hasn't changed
                if let renderer = mapView.renderer(for: overlay) as? MKTileOverlayRenderer {
                    renderer.alpha = CGFloat(opacity)
                }
            }
        }
        
        if let target = searchCoordinate {
            let region = MKCoordinateRegion(center: target, latitudinalMeters: 1000, longitudinalMeters: 1000)
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.searchCoordinate = nil }
        }
        
        let currentSpan = mapView.region.span.latitudeDelta
        let targetSpan = sliderValueToSpan(zoomLevel)
        
        if abs(currentSpan - targetSpan) > (currentSpan * 0.1) {
            var region = mapView.region
            region.span = MKCoordinateSpan(latitudeDelta: targetSpan, longitudeDelta: targetSpan)
            mapView.setRegion(region, animated: true)
        }
    }
    
    func sliderValueToSpan(_ value: Double) -> Double {
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
