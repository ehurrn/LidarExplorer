//
//  TerrainMapView.swift
//  LidarExplorer
//
//  MKMapView bridge carrying the USGS basemap and the streamed terrain layer.
//

import CoreLocation
import MapKit
import SwiftUI
import os

/// Hosts `MKMapView`.
///
/// SwiftUI's `Map` cannot serve here: both layers are `MKTileOverlay`s, and
/// the terrain one needs a custom `loadTile` implementation.
///
/// ## Why the reactive values are explicit inputs
///
/// `updateUIView` reads what it needs to apply — basemap, opacities, the
/// reload token — but reads made *inside* `updateUIView` are not tracked by
/// SwiftUI the way reads in a `body` are. So when only `model.style` (or the
/// basemap, or an opacity) changed, the parent `body` never re-evaluated,
/// `updateUIView` was never called, and the change silently did nothing until
/// some unrelated event forced a refresh. Passing these as stored inputs
/// means the parent `body` reads them to construct this view, which is what
/// establishes the dependency and guarantees `updateUIView` runs on change.
public struct TerrainMapView: UIViewRepresentable {

    let model: TerrainViewerModel
    let basemap: TerrainBasemap
    let showsTerrain: Bool
    let basemapOpacity: Double
    let terrainOpacity: Double
    /// Bumped by the model whenever shading settings change; drives a reload.
    let reloadToken: Int
    let locationAuthorization: CLAuthorizationStatus
    let pendingRecenter: CLLocationCoordinate2D?

    public init(
        model: TerrainViewerModel,
        basemap: TerrainBasemap,
        showsTerrain: Bool,
        basemapOpacity: Double,
        terrainOpacity: Double,
        reloadToken: Int,
        locationAuthorization: CLAuthorizationStatus,
        pendingRecenter: CLLocationCoordinate2D?
    ) {
        self.model = model
        self.basemap = basemap
        self.showsTerrain = showsTerrain
        self.basemapOpacity = basemapOpacity
        self.terrainOpacity = terrainOpacity
        self.reloadToken = reloadToken
        self.locationAuthorization = locationAuthorization
        self.pendingRecenter = pendingRecenter
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Not enabled up front: setting this is itself enough to make MapKit
        // request location permission, which fired the prompt at launch —
        // over the top of the first-run explanation. Enabled in updateUIView
        // once authorisation actually exists.
        map.showsUserLocation = false
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.region = model.visibleRegion

        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)

        context.coordinator.mapView = map
        // Overlays are attached in updateUIView, once the map has a real
        // frame. Adding them here happens before SwiftUI lays the view out.
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Nothing can be drawn until the map has been sized.
        guard map.bounds.width > 0, map.bounds.height > 0 else { return }

        if coordinator.basemap != basemap {
            coordinator.applyBasemap(basemap, to: map)
        }
        if coordinator.terrainEnabled != showsTerrain {
            coordinator.applyTerrain(enabled: showsTerrain, to: map)
        }

        let authorized = locationAuthorization == .authorizedWhenInUse
            || locationAuthorization == .authorizedAlways
        if map.showsUserLocation != authorized {
            map.showsUserLocation = authorized
        }

        coordinator.applyOpacity(
            basemap: basemapOpacity, terrain: terrainOpacity, on: map
        )

        // Shading changed: re-render tiles from cached derivatives.
        if coordinator.reloadToken != reloadToken {
            coordinator.reloadToken = reloadToken
            coordinator.reloadTerrain(on: map)
        }

        coordinator.syncProfile(on: map)

        if let target = pendingRecenter {
            let span = map.region.span
            map.setRegion(MKCoordinateRegion(center: target, span: span), animated: true)
            Task { @MainActor in model.pendingRecenter = nil }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {

        private let model: TerrainViewerModel
        weak var mapView: MKMapView?

        private(set) var basemap: TerrainBasemap?
        private(set) var terrainEnabled = false
        var reloadToken = 0

        private var basemapOverlay: HillshadeTileOverlay?
        private var terrainOverlay: TerrainTileOverlay?
        private var basemapAlpha: Double = -1
        private var terrainAlpha: Double = -1
        private var regionDebounceTask: Task<Void, Never>?
        private var profilePolyline: MKPolyline?
        private var profileAnnotations: [MKPointAnnotation] = []

        init(model: TerrainViewerModel) {
            self.model = model
        }

        // MARK: - Layers

        func applyBasemap(_ basemap: TerrainBasemap, to map: MKMapView) {
            if let existing = basemapOverlay {
                map.removeOverlay(existing)
                existing.invalidate()
            }
            let overlay = HillshadeTileOverlay(basemap: basemap)
            // Level 0 keeps it beneath the terrain layer.
            map.insertOverlay(overlay, at: 0, level: .aboveRoads)
            basemapOverlay = overlay
            self.basemap = basemap
            basemapAlpha = -1
        }

        func applyTerrain(enabled: Bool, to map: MKMapView) {
            if let existing = terrainOverlay {
                map.removeOverlay(existing)
                terrainOverlay = nil
            }
            terrainEnabled = enabled
            guard enabled else { return }

            let overlay = TerrainTileOverlay(provider: model.terrainProvider)
            map.addOverlay(overlay, level: .aboveLabels)
            terrainOverlay = overlay
            terrainAlpha = -1
        }

        /// Pushes opacity onto the live renderers.
        func applyOpacity(basemap: Double, terrain: Double, on map: MKMapView) {
            if abs(basemapAlpha - basemap) > 0.001,
               let overlay = basemapOverlay,
               let renderer = map.renderer(for: overlay) {
                renderer.alpha = basemap
                renderer.setNeedsDisplay()
                basemapAlpha = basemap
            }
            if abs(terrainAlpha - terrain) > 0.001,
               let overlay = terrainOverlay,
               let renderer = map.renderer(for: overlay) {
                renderer.alpha = terrain
                renderer.setNeedsDisplay()
                terrainAlpha = terrain
            }
        }

        /// Re-requests terrain tiles after a shading change.
        ///
        /// Cheap: the provider still holds each tile's derivatives, so this
        /// re-shades from memory rather than refetching elevation.
        func reloadTerrain(on map: MKMapView) {
            guard let overlay = terrainOverlay,
                  let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer
            else { return }
            renderer.reloadData()
        }

        func syncProfile(on map: MKMapView) {
            let needsClear = !model.isProfileModeActive || model.profileStart == nil
            if needsClear {
                if let polyline = profilePolyline {
                    map.removeOverlay(polyline)
                    profilePolyline = nil
                }
                if !profileAnnotations.isEmpty {
                    map.removeAnnotations(profileAnnotations)
                    profileAnnotations.removeAll()
                }
                return
            }

            var desiredAnnotations: [MKPointAnnotation] = []
            if let start = model.profileStart {
                let startAnno = MKPointAnnotation()
                startAnno.coordinate = start
                startAnno.title = "A (Start)"
                desiredAnnotations.append(startAnno)
            }
            if let end = model.profileEnd {
                let endAnno = MKPointAnnotation()
                endAnno.coordinate = end
                endAnno.title = "B (End)"
                desiredAnnotations.append(endAnno)
            }

            let annotationsChanged = profileAnnotations.count != desiredAnnotations.count
                || (profileAnnotations.first?.coordinate.latitude != desiredAnnotations.first?.coordinate.latitude)
                || (profileAnnotations.first?.coordinate.longitude != desiredAnnotations.first?.coordinate.longitude)
                || (profileAnnotations.last?.coordinate.latitude != desiredAnnotations.last?.coordinate.latitude)
                || (profileAnnotations.last?.coordinate.longitude != desiredAnnotations.last?.coordinate.longitude)

            if annotationsChanged {
                map.removeAnnotations(profileAnnotations)
                profileAnnotations = desiredAnnotations
                map.addAnnotations(desiredAnnotations)
            }

            if let start = model.profileStart, let end = model.profileEnd {
                if profilePolyline == nil {
                    var coords = [start, end]
                    let polyline = MKPolyline(coordinates: &coords, count: 2)
                    profilePolyline = polyline
                    map.addOverlay(polyline, level: .aboveLabels)
                }
            } else if let polyline = profilePolyline {
                map.removeOverlay(polyline)
                profilePolyline = nil
            }
        }

        // MARK: - Delegate

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            model.handleMapTap(map.convert(point, toCoordinateFrom: map))
        }

        public func mapView(
            _ mapView: MKMapView, rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 3.5
                return renderer
            }
            guard let tile = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tile)
            renderer.alpha = overlay is TerrainTileOverlay
                ? terrainAlpha < 0 ? model.terrainOpacity : terrainAlpha
                : basemapAlpha < 0 ? model.basemapOpacity : basemapAlpha
            return renderer
        }

        public func mapView(
            _ mapView: MKMapView, regionDidChangeAnimated animated: Bool
        ) {
            model.visibleRegion = mapView.region
            // Tiles for the new view arrive asynchronously; refresh the
            // reported resolution once they have had a moment to land.
            regionDebounceTask?.cancel()
            regionDebounceTask = Task { @MainActor [weak model = self.model] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                model?.refreshResolution()
                model?.refreshElevationRange()
            }
        }
    }
}
