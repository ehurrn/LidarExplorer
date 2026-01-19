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
    @Binding var detectedFeatures: [HistoricalFeature]
    @Binding var analysisEnabled: Bool
    @Binding var currentMapRegion: MKCoordinateRegion?

    var initialCoordinate: CLLocationCoordinate2D

    // Historical overlays
    @Binding var showNativeAmericanTerritories: Bool
    @Binding var showCivilWarSites: Bool
    @Binding var showHistoricalTrails: Bool
    @Binding var showArchaeologicalSites: Bool

    var nativeAmericanTerritories: [HistoricalTerritory]
    var civilWarSites: [HistoricalSite]
    var historicalTrails: [HistoricalTrail]
    var archaeologicalSites: [HistoricalSite]
    
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

        // Update feature annotations
        updateFeatureAnnotations(mapView: mapView, coordinator: context.coordinator)

        // Update historical overlays
        updateHistoricalOverlays(mapView: mapView, coordinator: context.coordinator)
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

        // Track historical overlays
        var territoryOverlays: [UUID: TerritoryOverlay] = [:]
        var trailOverlays: [UUID: TrailOverlay] = [:]
        var siteAnnotations: [UUID: HistoricalSiteAnnotation] = [:]
        var territoryLabels: [UUID: TerritoryLabelAnnotation] = [:]
        var trailLabels: [UUID: TrailLabelAnnotation] = [:]

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

            // Handle territory overlays (polygons)
            if let territoryOverlay = overlay as? TerritoryOverlay {
                let polygon = MKPolygon(
                    coordinates: territoryOverlay.territory.coordinates,
                    count: territoryOverlay.territory.coordinates.count
                )
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = territoryOverlay.territory.type.color.uiColor
                renderer.strokeColor = territoryOverlay.territory.type.strokeColor.uiColor
                renderer.lineWidth = 2
                return renderer
            }

            // Handle trail overlays (polylines)
            if let trailOverlay = overlay as? TrailOverlay {
                let polyline = MKPolyline(
                    coordinates: trailOverlay.trail.coordinates,
                    count: trailOverlay.trail.coordinates.count
                )
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = HistoricalOverlayType.historicalTrail.strokeColor.uiColor
                renderer.lineWidth = 3
                renderer.lineDashPattern = [10, 5] // Dashed line for trails
                return renderer
            }

            // Note: Circle overlays removed due to MKCircle subclassing issues
            // The pin annotations are sufficient for now
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Don't modify user location annotation
            if annotation is MKUserLocation { return nil }

            // Handle territory label annotations
            if let labelAnnotation = annotation as? TerritoryLabelAnnotation {
                let identifier = "TerritoryLabel"
                var annotationView = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView

                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(
                        annotation: labelAnnotation,
                        reuseIdentifier: identifier
                    )
                    annotationView?.canShowCallout = true

                    // Add detail button
                    let detailButton = UIButton(type: .detailDisclosure)
                    annotationView?.rightCalloutAccessoryView = detailButton
                } else {
                    annotationView?.annotation = labelAnnotation
                }

                // Style for territory labels
                annotationView?.markerTintColor = labelAnnotation.territory.type.strokeColor.uiColor
                annotationView?.glyphImage = UIImage(systemName: "map.fill")
                annotationView?.displayPriority = .defaultHigh

                return annotationView
            }

            // Handle trail label annotations
            if let labelAnnotation = annotation as? TrailLabelAnnotation {
                let identifier = "TrailLabel"
                var annotationView = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView

                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(
                        annotation: labelAnnotation,
                        reuseIdentifier: identifier
                    )
                    annotationView?.canShowCallout = true

                    // Add detail button
                    let detailButton = UIButton(type: .detailDisclosure)
                    annotationView?.rightCalloutAccessoryView = detailButton
                } else {
                    annotationView?.annotation = labelAnnotation
                }

                // Style for trail labels
                annotationView?.markerTintColor = .systemOrange
                annotationView?.glyphImage = UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                annotationView?.displayPriority = .defaultHigh

                return annotationView
            }

            // Handle historical site annotations
            if let siteAnnotation = annotation as? HistoricalSiteAnnotation {
                let identifier = "HistoricalSite"
                var annotationView = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView

                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(
                        annotation: siteAnnotation,
                        reuseIdentifier: identifier
                    )
                    annotationView?.canShowCallout = true

                    // Add detail button
                    let detailButton = UIButton(type: .detailDisclosure)
                    annotationView?.rightCalloutAccessoryView = detailButton
                } else {
                    annotationView?.annotation = siteAnnotation
                }

                // Customize marker based on site type
                switch siteAnnotation.site.type {
                case .civilWarSite:
                    annotationView?.markerTintColor = .systemRed
                    annotationView?.glyphImage = UIImage(systemName: "flag.fill")
                case .archaeologicalSite:
                    annotationView?.markerTintColor = .systemBlue
                    annotationView?.glyphImage = UIImage(systemName: "building.columns.fill")
                default:
                    annotationView?.markerTintColor = .systemPurple
                }

                return annotationView
            }

            guard let featureAnnotation = annotation as? HistoricalFeatureAnnotation else {
                return nil
            }

            let identifier = "HistoricalFeature"
            var annotationView = mapView.dequeueReusableAnnotationView(
                withIdentifier: identifier
            ) as? HistoricalFeatureAnnotationView

            if annotationView == nil {
                annotationView = HistoricalFeatureAnnotationView(
                    annotation: featureAnnotation,
                    reuseIdentifier: identifier
                )
                annotationView?.clusteringIdentifier = "HistoricalFeatureCluster"
            } else {
                annotationView?.annotation = featureAnnotation
            }

            return annotationView
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            // Handle info button taps
            if let siteAnnotation = view.annotation as? HistoricalSiteAnnotation {
                showSiteDetailAlert(site: siteAnnotation.site, in: mapView)
            } else if let territoryAnnotation = view.annotation as? TerritoryLabelAnnotation {
                showTerritoryDetailAlert(territory: territoryAnnotation.territory, in: mapView)
            } else if let trailAnnotation = view.annotation as? TrailLabelAnnotation {
                showTrailDetailAlert(trail: trailAnnotation.trail, in: mapView)
            }
        }

        // MARK: - Detail Alert Helpers

        private func showSiteDetailAlert(site: HistoricalSite, in mapView: MKMapView) {
            guard let viewController = mapView.window?.rootViewController else { return }

            let alert = UIAlertController(
                title: site.name,
                message: """
                \(site.description)

                Period: \(site.timePeriod)
                Significance: \(site.significance)
                \(site.dateEstablished.map { "Established: \($0)" } ?? "")
                """,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            viewController.present(alert, animated: true)
        }

        private func showTerritoryDetailAlert(territory: HistoricalTerritory, in mapView: MKMapView) {
            guard let viewController = mapView.window?.rootViewController else { return }

            let culturalInfo = territory.culturalGroup.map { "\n\nCultural Group: \($0)" } ?? ""
            let alert = UIAlertController(
                title: territory.name,
                message: """
                \(territory.description)

                Period: \(territory.timePeriod)\(culturalInfo)
                """,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            viewController.present(alert, animated: true)
        }

        private func showTrailDetailAlert(trail: HistoricalTrail, in mapView: MKMapView) {
            guard let viewController = mapView.window?.rootViewController else { return }

            let lengthInfo = trail.lengthMiles.map { "\n\nLength: ~\(Int($0)) miles" } ?? ""
            let alert = UIAlertController(
                title: trail.name,
                message: """
                \(trail.description)

                Period: \(trail.timePeriod)\(lengthInfo)
                """,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            viewController.present(alert, animated: true)
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
                // Update current region for analysis
                self.parent.currentMapRegion = mapView.region
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

    /// Updates feature annotations on the map based on analysis state
    private func updateFeatureAnnotations(mapView: MKMapView, coordinator: Coordinator) {
        if analysisEnabled && !detectedFeatures.isEmpty {
            print("🗺️ Updating map annotations - analysisEnabled: true, features: \(detectedFeatures.count)")

            // Get current annotations
            let currentAnnotations = mapView.annotations.compactMap { $0 as? HistoricalFeatureAnnotation }
            let currentFeatureIDs = Set(currentAnnotations.map { $0.feature.id })
            let newFeatureIDs = Set(detectedFeatures.map { $0.id })

            // Remove annotations that are no longer in the features list
            let toRemove = currentAnnotations.filter { !newFeatureIDs.contains($0.feature.id) }
            if !toRemove.isEmpty {
                print("  Removing \(toRemove.count) old annotations")
                mapView.removeAnnotations(toRemove)
            }

            // Add new annotations
            let toAdd = detectedFeatures.filter { !currentFeatureIDs.contains($0.id) }
            if !toAdd.isEmpty {
                let newAnnotations = toAdd.map { HistoricalFeatureAnnotation(feature: $0) }
                print("  Adding \(newAnnotations.count) new annotations:")
                for annotation in newAnnotations {
                    print("    - \(annotation.feature.title) at (\(annotation.coordinate.latitude), \(annotation.coordinate.longitude))")
                }
                mapView.addAnnotations(newAnnotations)
            }

            // Note: Circle overlays removed due to MKCircle subclassing issues
            // The annotations with custom pins are sufficient for visualization

        } else {
            print("🗺️ Clearing map annotations - analysisEnabled: \(analysisEnabled), features: \(detectedFeatures.count)")
            // Remove all feature annotations when analysis is disabled
            let featureAnnotations = mapView.annotations.compactMap { $0 as? HistoricalFeatureAnnotation }
            mapView.removeAnnotations(featureAnnotations)
        }
    }

    /// Updates historical context overlays based on toggle states
    private func updateHistoricalOverlays(mapView: MKMapView, coordinator: Coordinator) {
        let currentRegion = mapView.region

        // Update Native American Territories
        if showNativeAmericanTerritories {
            // Filter territories visible in current region
            let visibleTerritories = filterVisibleTerritories(nativeAmericanTerritories, in: currentRegion)
            let currentIDs = Set(coordinator.territoryOverlays.keys)
            let newIDs = Set(visibleTerritories.map { $0.id })

            // Remove territories that are no longer visible
            for id in currentIDs.subtracting(newIDs) {
                if let overlay = coordinator.territoryOverlays[id] {
                    mapView.removeOverlay(overlay)
                    coordinator.territoryOverlays.removeValue(forKey: id)
                }
                if let label = coordinator.territoryLabels[id] {
                    mapView.removeAnnotation(label)
                    coordinator.territoryLabels.removeValue(forKey: id)
                }
            }

            // Add new territories
            for territory in visibleTerritories where !currentIDs.contains(territory.id) {
                let overlay = TerritoryOverlay(territory: territory)
                mapView.addOverlay(overlay, level: .aboveRoads)
                coordinator.territoryOverlays[territory.id] = overlay

                // Add label annotation
                let label = TerritoryLabelAnnotation(territory: territory)
                mapView.addAnnotation(label)
                coordinator.territoryLabels[territory.id] = label
            }
        } else {
            // Remove all territory overlays and labels
            for (id, overlay) in coordinator.territoryOverlays {
                mapView.removeOverlay(overlay)
            }
            for (id, label) in coordinator.territoryLabels {
                mapView.removeAnnotation(label)
            }
            coordinator.territoryOverlays.removeAll()
            coordinator.territoryLabels.removeAll()
        }

        // Update Historical Trails
        if showHistoricalTrails {
            // Filter trails visible in current region
            let visibleTrails = filterVisibleTrails(historicalTrails, in: currentRegion)
            let currentIDs = Set(coordinator.trailOverlays.keys)
            let newIDs = Set(visibleTrails.map { $0.id })

            // Remove trails that are no longer visible
            for id in currentIDs.subtracting(newIDs) {
                if let overlay = coordinator.trailOverlays[id] {
                    mapView.removeOverlay(overlay)
                    coordinator.trailOverlays.removeValue(forKey: id)
                }
                if let label = coordinator.trailLabels[id] {
                    mapView.removeAnnotation(label)
                    coordinator.trailLabels.removeValue(forKey: id)
                }
            }

            // Add new trails
            for trail in visibleTrails where !currentIDs.contains(trail.id) {
                let overlay = TrailOverlay(trail: trail)
                mapView.addOverlay(overlay, level: .aboveRoads)
                coordinator.trailOverlays[trail.id] = overlay

                // Add label annotation
                let label = TrailLabelAnnotation(trail: trail)
                mapView.addAnnotation(label)
                coordinator.trailLabels[trail.id] = label
            }
        } else {
            // Remove all trail overlays and labels
            for (id, overlay) in coordinator.trailOverlays {
                mapView.removeOverlay(overlay)
            }
            for (id, label) in coordinator.trailLabels {
                mapView.removeAnnotation(label)
            }
            coordinator.trailOverlays.removeAll()
            coordinator.trailLabels.removeAll()
        }

        // Update Historical Sites (Civil War + Archaeological)
        let sitesToShow = (showCivilWarSites ? civilWarSites : []) +
                          (showArchaeologicalSites ? archaeologicalSites : [])

        if !sitesToShow.isEmpty {
            // Filter sites visible in current region
            let visibleSites = filterVisibleSites(sitesToShow, in: currentRegion)
            let currentIDs = Set(coordinator.siteAnnotations.keys)
            let newIDs = Set(visibleSites.map { $0.id })

            // Remove sites that are no longer visible
            for id in currentIDs.subtracting(newIDs) {
                if let annotation = coordinator.siteAnnotations[id] {
                    mapView.removeAnnotation(annotation)
                    coordinator.siteAnnotations.removeValue(forKey: id)
                }
            }

            // Add new sites
            for site in visibleSites where !currentIDs.contains(site.id) {
                let annotation = HistoricalSiteAnnotation(site: site)
                mapView.addAnnotation(annotation)
                coordinator.siteAnnotations[site.id] = annotation
            }
        } else {
            // Remove all site annotations
            for (id, annotation) in coordinator.siteAnnotations {
                mapView.removeAnnotation(annotation)
            }
            coordinator.siteAnnotations.removeAll()
        }
    }

    // MARK: - Dynamic Loading Helpers

    /// Filters territories to only those visible in the current map region (with buffer)
    private func filterVisibleTerritories(_ territories: [HistoricalTerritory], in region: MKCoordinateRegion) -> [HistoricalTerritory] {
        let buffer = 2.0 // Degrees of buffer around viewport
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2) - buffer
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2) + buffer
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2) - buffer
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2) + buffer

        return territories.filter { territory in
            // Check if any coordinate of the territory is within the buffered region
            territory.coordinates.contains { coord in
                coord.latitude >= minLat && coord.latitude <= maxLat &&
                coord.longitude >= minLon && coord.longitude <= maxLon
            }
        }
    }

    /// Filters trails to only those visible in the current map region (with buffer)
    private func filterVisibleTrails(_ trails: [HistoricalTrail], in region: MKCoordinateRegion) -> [HistoricalTrail] {
        let buffer = 2.0 // Degrees of buffer around viewport
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2) - buffer
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2) + buffer
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2) - buffer
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2) + buffer

        return trails.filter { trail in
            // Check if any coordinate of the trail is within the buffered region
            trail.coordinates.contains { coord in
                coord.latitude >= minLat && coord.latitude <= maxLat &&
                coord.longitude >= minLon && coord.longitude <= maxLon
            }
        }
    }

    /// Filters sites to only those visible in the current map region (with buffer)
    private func filterVisibleSites(_ sites: [HistoricalSite], in region: MKCoordinateRegion) -> [HistoricalSite] {
        let buffer = 2.0 // Degrees of buffer around viewport
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2) - buffer
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2) + buffer
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2) - buffer
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2) + buffer

        return sites.filter { site in
            site.coordinate.latitude >= minLat && site.coordinate.latitude <= maxLat &&
            site.coordinate.longitude >= minLon && site.coordinate.longitude <= maxLon
        }
    }
}
