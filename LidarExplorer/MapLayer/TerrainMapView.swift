//
//  TerrainMapView.swift
//  LidarExplorer
//
//  MKMapView bridge carrying the USGS basemap and the computed terrain layer.
//

import MapKit
import SwiftUI
import os

/// Hosts `MKMapView`.
///
/// SwiftUI's `Map` cannot serve here: the USGS basemaps are XYZ tile services
/// needing `MKTileOverlay`, and the computed terrain layer is a custom
/// `MKOverlay` drawn from a `CGImage`.
public struct TerrainMapView: UIViewRepresentable {

    let model: TerrainViewerModel

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.region = model.visibleRegion

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Must not swallow the map's own gestures.
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        context.coordinator.mapView = map

        context.coordinator.applyBasemap(model.basemap, to: map)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.opacity = model.basemapOpacity
        coordinator.terrainOpacity = model.terrainOpacity

        if coordinator.basemap != model.basemap {
            coordinator.applyBasemap(model.basemap, to: map)
        }

        coordinator.applyTerrain(
            image: model.reliefImage, region: model.reliefRegion, to: map
        )

        // Recentre only on explicit request, then clear it — writing the
        // region back unconditionally would fight the user's pan.
        if let target = model.pendingRecenter {
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
        var opacity: Double = 1
        var terrainOpacity: Double = 0.85

        private var basemapOverlay: HillshadeTileOverlay?
        private var terrainOverlay: ReliefOverlay?
        private var shownImage: CGImage?

        init(model: TerrainViewerModel) {
            self.model = model
        }

        func applyBasemap(_ basemap: TerrainBasemap, to map: MKMapView) {
            if let existing = basemapOverlay { map.removeOverlay(existing) }
            let overlay = HillshadeTileOverlay(basemap: basemap)
            // Below the terrain layer, which is added at a higher level.
            map.insertOverlay(overlay, at: 0, level: .aboveRoads)
            basemapOverlay = overlay
            self.basemap = basemap
        }

        /// Swaps the terrain overlay only when the image itself changed.
        ///
        /// Compared by identity: re-adding an unchanged overlay on every
        /// SwiftUI update would make the layer flicker on each pan.
        func applyTerrain(image: CGImage?, region: GeoRegion?, to map: MKMapView) {
            guard let image, let region else {
                if let existing = terrainOverlay {
                    map.removeOverlay(existing)
                    terrainOverlay = nil
                    shownImage = nil
                }
                return
            }
            guard image !== shownImage else {
                terrainRenderer?.alpha = terrainOpacity
                return
            }
            if let existing = terrainOverlay { map.removeOverlay(existing) }
            let overlay = ReliefOverlay(image: image, region: region)
            map.addOverlay(overlay, level: .aboveLabels)
            terrainOverlay = overlay
            shownImage = image
        }

        private var terrainRenderer: MKOverlayRenderer? {
            guard let terrainOverlay, let mapView else { return nil }
            return mapView.renderer(for: terrainOverlay)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            model.inspect(map.convert(point, toCoordinateFrom: map))
        }

        public func mapView(
            _ mapView: MKMapView, rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            if let relief = overlay as? ReliefOverlay {
                let renderer = ReliefOverlayRenderer(overlay: relief)
                renderer.alpha = terrainOpacity
                return renderer
            }
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = opacity
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(
            _ mapView: MKMapView, regionDidChangeAnimated animated: Bool
        ) {
            model.visibleRegion = mapView.region
        }
    }
}
