//
//  TerrainMapView.swift
//  LidarExplorer
//
//  MKMapView bridge carrying the USGS basemap and the streamed terrain layer.
//

import MapKit
import SwiftUI
import os

/// Hosts `MKMapView`.
///
/// SwiftUI's `Map` cannot serve here: both layers are `MKTileOverlay`s, and
/// the terrain one needs a custom `loadTile` implementation.
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
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)

        context.coordinator.mapView = map
        context.coordinator.applyBasemap(model.basemap, to: map)
        context.coordinator.applyTerrain(enabled: model.showsTerrain, to: map)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.basemap != model.basemap {
            coordinator.applyBasemap(model.basemap, to: map)
        }
        if coordinator.terrainEnabled != model.showsTerrain {
            coordinator.applyTerrain(enabled: model.showsTerrain, to: map)
        }

        // Opacity is applied to the live renderers, not just stored. Setting
        // it only on the coordinator did nothing once a renderer already
        // existed, because `rendererFor` is consulted once per overlay — which
        // is why the basemap opacity slider appeared inert.
        coordinator.applyOpacity(
            basemap: model.basemapOpacity, terrain: model.terrainOpacity, on: map
        )

        // Shading changed: re-render tiles from cached derivatives.
        if coordinator.terrainVersion != model.terrainVersion {
            coordinator.terrainVersion = model.terrainVersion
            coordinator.reloadTerrain(on: map)
        }

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
        private(set) var terrainEnabled = false
        var terrainVersion = 0

        private var basemapOverlay: HillshadeTileOverlay?
        private var terrainOverlay: TerrainTileOverlay?
        private var basemapAlpha: Double = -1
        private var terrainAlpha: Double = -1

        init(model: TerrainViewerModel) {
            self.model = model
        }

        // MARK: - Layers

        func applyBasemap(_ basemap: TerrainBasemap, to map: MKMapView) {
            if let existing = basemapOverlay { map.removeOverlay(existing) }
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

        // MARK: - Delegate

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            model.inspect(map.convert(point, toCoordinateFrom: map))
        }

        public func mapView(
            _ mapView: MKMapView, rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            guard let tile = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tile)
            renderer.alpha = overlay is TerrainTileOverlay
                ? model.terrainOpacity : model.basemapOpacity
            return renderer
        }

        public func mapView(
            _ mapView: MKMapView, regionDidChangeAnimated animated: Bool
        ) {
            model.visibleRegion = mapView.region
            // Tiles for the new view arrive asynchronously; refresh the
            // reported resolution once they have had a moment to land.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.model.refreshResolution()
            }
        }
    }
}
