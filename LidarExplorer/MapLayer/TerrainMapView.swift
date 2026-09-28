//
//  TerrainMapView.swift
//  LidarExplorer
//
//  MKMapView bridge carrying the USGS basemap and the streamed terrain layer. Which touch on the map does what is
//  MapTouchPolicy's to say; this bridge only asks it (see "Touches" on the type).
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
///
/// ## Touches
///
/// Which recognizer receives a touch, what a tap and a drag do, and whether two fingers rotate and pitch are
/// ``MapTouchPolicy``'s answers for the tool lit (``TerrainViewerModel/mapTool``), asked at the moment of the touch.
/// With no tool lit a tap does nothing and every one-touch drag, finger or Pencil, pans the map. The profile's tap
/// places A, then B, and only a Pencil stroke draws its line; a finger pans. The thalweg's drag traces the channel.
///
/// Two things are absent on purpose, and the harness (R4) reads this file to keep them so. Nothing here switches
/// MapKit's one-finger scrolling: a stroke keeps off the map because MapKit's pans wait for the draw pan to fail
/// (`gestureRecognizer(_:shouldBeRequiredToFailBy:)`), and a touch the draw pan never receives is not waited on. And
/// no gesture changes the tool. A Pencil touch used to turn scrolling off as it landed and its stroke to light the
/// ruler, where one-finger scrolling was kept off, which locked the map against every finger (the pan lock).
public struct TerrainMapView: UIViewRepresentable {

    let model: TerrainViewerModel
    let basemap: BasemapChoice
    let showsTerrain: Bool
    let basemapOpacity: Double
    let terrainOpacity: Double
    /// Bumped by the model whenever shading settings change; drives a reload that keeps tiles drawn until
    /// their re-shade lands.
    let reloadToken: Int
    /// Bumped by the model when the ground itself changes (an elevation file mounted or removed); drives a
    /// reload that discards every drawn tile, since none of them shows the new ground.
    let dataReloadToken: Int
    let locationAuthorization: CLAuthorizationStatus
    let pendingRecenter: CLLocationCoordinate2D?
    let pendingRegion: MKCoordinateRegion?
    let activeSpot: SpotInspection?
    /// Bumped per viewshed result, so the drawn mask is swapped exactly once.
    let viewshedVersion: Int
    let historicalCount: Int
    let historicalOpacity: Double
    let historicalWipeFraction: Double?
    let historicalAboveTerrain: Bool
    let soilVersion: Int
    /// Bumped by the model on every change to the field markup, so it is redrawn exactly once per change.
    let markupVersion: Int
    /// The tool lit, so that picking one re-runs `updateUIView` (a change to a model value read only inside
    /// `updateUIView` is not tracked; see the type's header). Going from the ruler to viewshed changed none of the
    /// other inputs, so the map kept the ruler's settings.
    let mapTool: MapTool
    /// How far below the safe area's top the compass sits: the top bar's measured height and a gap, so it clears the
    /// bar in either layout (the readout beside the buttons, or on a second row under them).
    let compassTopInset: CGFloat

    public init(
        model: TerrainViewerModel,
        basemap: BasemapChoice,
        showsTerrain: Bool,
        basemapOpacity: Double,
        terrainOpacity: Double,
        reloadToken: Int,
        dataReloadToken: Int,
        locationAuthorization: CLAuthorizationStatus,
        pendingRecenter: CLLocationCoordinate2D?,
        pendingRegion: MKCoordinateRegion? = nil,
        activeSpot: SpotInspection? = nil,
        viewshedVersion: Int = 0,
        historicalCount: Int = 0,
        historicalOpacity: Double = 0.8,
        historicalWipeFraction: Double? = nil,
        historicalAboveTerrain: Bool = true,
        soilVersion: Int = 0,
        markupVersion: Int = 0,
        mapTool: MapTool = .navigate,
        compassTopInset: CGFloat = 62
    ) {
        self.model = model
        self.basemap = basemap
        self.showsTerrain = showsTerrain
        self.basemapOpacity = basemapOpacity
        self.terrainOpacity = terrainOpacity
        self.reloadToken = reloadToken
        self.dataReloadToken = dataReloadToken
        self.locationAuthorization = locationAuthorization
        self.pendingRecenter = pendingRecenter
        self.pendingRegion = pendingRegion
        self.activeSpot = activeSpot
        self.viewshedVersion = viewshedVersion
        self.historicalCount = historicalCount
        self.historicalOpacity = historicalOpacity
        self.historicalWipeFraction = historicalWipeFraction
        self.historicalAboveTerrain = historicalAboveTerrain
        self.soilVersion = soilVersion
        self.markupVersion = markupVersion
        self.mapTool = mapTool
        self.compassTopInset = compassTopInset
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Not enabled up front: setting this is itself enough to make MapKit
        // request location permission, which fired the prompt at launch —
        // over the top of the first-run explanation. Enabled in updateUIView
        // once authorisation actually exists.
        map.showsUserLocation = false
        // Hide the default compass: it renders in the top-trailing corner directly
        // beneath the top-bar action buttons (?, settings, etc.).
        map.showsCompass = false
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.region = model.visibleRegion

        // Anchor an explicit compass button below the trailing edge of the top bar. The map ignores the safe area, so its
        // guide's top is the screen's safe-area top, where the bar begins: the compass goes the bar's measured height
        // below it (updateUIView follows the bar). A constant 54 pt fitted the old one-row, 36 pt bar; under the 44 pt
        // bar it touched the More button, and under the two-row bar it lay in the readout's row, whose backing took its taps.
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)
        let compassTop = compass.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: compassTopInset)
        NSLayoutConstraint.activate([
            compass.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            compassTop,
        ])
        context.coordinator.compassTopConstraint = compassTop

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        // Its touches come from MapTouchPolicy: with no tool lit it never sees one (a tap used to inspect).
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        // The profile's Pencil stroke and the thalweg's trace. It receives only the touches that draw
        // (MapTouchPolicy.drawRecognizerReceives), and MapKit's pan waits for it (shouldBeRequiredToFailBy), so a stroke
        // never moves the map and nothing ever switches MapKit's scrolling.
        let drawPan = DrawPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTransectPan(_:)))
        drawPan.maximumNumberOfTouches = 1
        drawPan.delegate = context.coordinator
        map.addGestureRecognizer(drawPan)
        context.coordinator.drawPanRecognizer = drawPan

        let wipe = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleWipe(_:))
        )
        wipe.minimumNumberOfTouches = 2
        wipe.maximumNumberOfTouches = 2
        wipe.delegate = context.coordinator
        map.addGestureRecognizer(wipe)
        context.coordinator.wipePanRecognizer = wipe

        #if !os(macOS)
        let hover = UIHoverGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleHover(_:))
        )
        map.addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        map.addInteraction(pencil)
        #endif

        context.coordinator.mapView = map
        // How a stroke drawn in the window becomes a place on the ground. Handed over on the next turn of the
        // run loop: the model is being observed while this view is built.
        let model = self.model
        Task { @MainActor [weak map] in
            model.markupCoordinateConverter = { window in
                guard let map, map.window != nil else { return nil }
                let local = map.convert(window, from: nil)
                guard map.bounds.contains(local) else { return nil }
                return map.convert(local, toCoordinateFrom: map)
            }
            // And back, for the spot inspection's haptic to play at its pin.
            model.windowPointForCoordinate = { coordinate in
                guard let map, map.window != nil, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return map.convert(map.convert(coordinate, toPointTo: map), to: nil)
            }
            // The window the viewer is in, which every haptic caused by a touch in it is attached to.
            model.viewerWindow = { map?.window }
            // The region on screen at the moment of asking, for View in 3D and a GeoTIFF export tapped while the map
            // still coasts: the region the model keeps is written only when a move ends.
            model.liveVisibleRegion = {
                guard let map, map.window != nil, map.bounds.width > 0, map.bounds.height > 0 else { return nil }
                return map.region
            }
            // The screen's own corners, read with the region: on a rotated map the region is the north-up box around
            // the screen, and what the view covers is measured over the screen, not the box.
            model.liveVisibleCorners = {
                guard let map, map.window != nil, map.bounds.width > 0, map.bounds.height > 0 else { return nil }
                let bounds = map.bounds
                let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                               CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                    .map { map.convert($0, toCoordinateFrom: map) }
                // Pitched far enough, a top corner looks past the horizon and has no ground: the region is used.
                return corners.allSatisfy(CLLocationCoordinate2DIsValid) ? corners : nil
            }
        }
        // Overlays are attached in updateUIView, once the map has a real
        // frame. Adding them here happens before SwiftUI lays the view out.
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Only when the top bar changes height (it takes a second row, or the text size changes), not per frame.
        if let compassTop = coordinator.compassTopConstraint, compassTop.constant != compassTopInset {
            compassTop.constant = compassTopInset
        }

        // Nothing can be drawn until the map has been sized.
        guard map.bounds.width > 0, map.bounds.height > 0 else { return }

        // Two fingers rotate and pitch where the tool leaves them free (MapTouchPolicy). One-finger scrolling is never
        // switched: it is MapKit's in every tool, and a stroke keeps it off the map by MapKit's pan waiting on it.
        let turns = MapTouchPolicy.rotatesAndPitches(in: mapTool)
        if map.isRotateEnabled != turns { map.isRotateEnabled = turns }
        if map.isPitchEnabled != turns { map.isPitchEnabled = turns }

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

        // The ground changed: discard every drawn tile. This also covers any shading change in the same update.
        if coordinator.dataReloadToken != dataReloadToken {
            coordinator.dataReloadToken = dataReloadToken
            coordinator.reloadToken = reloadToken
            coordinator.discardTerrain(on: map)
        } else if coordinator.reloadToken != reloadToken {
            // Shading changed: re-render tiles from cached derivatives.
            coordinator.reloadToken = reloadToken
            coordinator.reloadTerrain(on: map)
        }

        coordinator.syncProfile(on: map)
        coordinator.syncSpotAnnotation(spot: activeSpot, on: map)
        coordinator.syncViewshed(on: map)
        coordinator.syncThalweg(on: map)
        coordinator.syncHistorical(
            on: map,
            count: historicalCount,
            opacity: historicalOpacity,
            aboveTerrain: historicalAboveTerrain
        )
        coordinator.syncSoils(on: map, version: soilVersion)
        coordinator.syncMarkup(on: map, version: markupVersion)

        if let target = pendingRecenter {
            let span = map.region.span
            map.setRegion(MKCoordinateRegion(center: target, span: span), animated: true)
            Task { @MainActor in model.pendingRecenter = nil }
        }

        if let region = pendingRegion {
            map.setRegion(region, animated: true)
            Task { @MainActor in model.pendingRegion = nil }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

        private let model: TerrainViewerModel
        weak var mapView: MKMapView?
        /// The compass's distance below the safe area's top, moved with the top bar's height.
        var compassTopConstraint: NSLayoutConstraint?

        private(set) var basemap: BasemapChoice?
        private(set) var terrainEnabled = false
        var reloadToken = 0
        var dataReloadToken = 0

        private var basemapOverlay: HillshadeTileOverlay?
        private var terrainOverlay: TerrainTileOverlay?
        private var basemapAlpha: Double = -1
        /// Which base layer MapKit is drawing itself, so `preferredConfiguration`
        /// is only reassigned when it genuinely changes.
        private enum MapConfigurationKind { case standard, imagery }
        private var configurationKind: MapConfigurationKind = .standard
        private var terrainAlpha: Double = -1
        private var regionDebounceTask: Task<Void, Never>?
        private var profilePolyline: MKPolyline?
        private var profileAnnotations: [MKPointAnnotation] = []
        private var spotAnnotation: MKPointAnnotation?
        private var viewshedAnnotation: MKPointAnnotation?
        private var viewshedCircle: MKCircle?
        private var viewshedOverlay: ViewshedOverlay?
        private var drawnViewshedVersion = -1
        /// Polls the observer pin while it is dragged; MapKit reports only drag start and end.
        private var observerDragTimer: Timer?
        weak var wipePanRecognizer: UIPanGestureRecognizer?
        weak var tapRecognizer: UITapGestureRecognizer?
        /// The profile's Pencil stroke and the thalweg's trace (`handleTransectPan`).
        weak var drawPanRecognizer: UIPanGestureRecognizer?
        private var historicalOverlays: [HistoricalMapOverlay] = []
        private var historicalAlpha: Double = -1
        private var soilOverlays: [SoilMultiPolygon] = []
        private var drawnSoilVersion = -1
        private var markupOverlays: [MKPolyline] = []
        private var markupAnnotations: [MKPointAnnotation] = []
        private var markupStyles: [String: FieldAnnotationTrace] = [:]
        private var drawnMarkupVersion = -1

        /// Redraws the field markup (traces as polylines, waypoints as pins) when it has changed.
        func syncMarkup(on map: MKMapView, version: Int) {
            guard drawnMarkupVersion != version else { return }
            drawnMarkupVersion = version
            map.removeOverlays(markupOverlays)
            map.removeAnnotations(markupAnnotations)
            markupOverlays = []
            markupAnnotations = []
            markupStyles = [:]

            for trace in model.fieldTraces {
                var coordinates = trace.coordinates
                let polyline = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                polyline.title = "FieldTrace"
                polyline.subtitle = trace.id.uuidString
                markupStyles[trace.id.uuidString] = trace
                markupOverlays.append(polyline)
            }
            map.addOverlays(markupOverlays, level: .aboveLabels)

            for waypoint in model.fieldWaypoints {
                let pin = MKPointAnnotation()
                pin.coordinate = waypoint.coordinate
                pin.title = waypoint.title
                pin.subtitle = "FieldWaypoint:" + waypoint.notes
                markupAnnotations.append(pin)
            }
            map.addAnnotations(markupAnnotations)
        }

        init(model: TerrainViewerModel) {
            self.model = model
        }

        func syncHistorical(on map: MKMapView, count: Int, opacity: Double, aboveTerrain: Bool) {
            let desired = model.historicalMaps
            let identical = historicalOverlays.count == desired.count &&
                zip(historicalOverlays, desired).allSatisfy { $0 === $1 }
            if !identical {
                for overlay in historicalOverlays {
                    map.removeOverlay(overlay)
                }
                historicalOverlays = desired
                for overlay in historicalOverlays {
                    if aboveTerrain {
                        map.addOverlay(overlay, level: .aboveLabels)
                    } else {
                        // Index 1 sits just above the basemap overlay — but an
                        // Apple basemap adds no overlay, so that index need not
                        // exist and insertOverlay would raise NSRangeException.
                        map.insertOverlay(
                            overlay,
                            at: min(1, map.overlays(in: .aboveRoads).count),
                            level: .aboveRoads
                        )
                    }
                }
            }
            if abs(historicalAlpha - opacity) > 0.001 || !identical {
                for overlay in historicalOverlays {
                    if let renderer = map.renderer(for: overlay) {
                        renderer.alpha = opacity
                        renderer.setNeedsDisplay()
                    }
                }
                historicalAlpha = opacity
            }
            applyWipe(on: map)
        }

        func applyWipe(on map: MKMapView) {
            guard let fraction = model.historicalWipeFraction else {
                for overlay in historicalOverlays {
                    (map.renderer(for: overlay) as? HistoricalMapRenderer)?.setWipe(mapX: nil, mapY: nil)
                }
                return
            }
            if model.historicalWipeOrientation == .vertical {
                let mapX = MKMapPoint(map.convert(CGPoint(x: map.bounds.width * fraction, y: map.bounds.midY), toCoordinateFrom: map)).x
                for overlay in historicalOverlays {
                    (map.renderer(for: overlay) as? HistoricalMapRenderer)?.setWipe(mapX: mapX, mapY: nil)
                }
            } else {
                let mapY = MKMapPoint(map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.height * fraction), toCoordinateFrom: map)).y
                for overlay in historicalOverlays {
                    (map.renderer(for: overlay) as? HistoricalMapRenderer)?.setWipe(mapX: nil, mapY: mapY)
                }
            }
        }

        func syncSoils(on mapView: MKMapView, version: Int) {
            guard drawnSoilVersion != version else { return }
            drawnSoilVersion = version
            if !soilOverlays.isEmpty {
                mapView.removeOverlays(soilOverlays)
                soilOverlays = []
            }
            if model.showsSoils, let survey = model.soilSurvey {
                let overlays = SoilOverlayFactory.overlays(from: survey)
                soilOverlays = overlays
                mapView.addOverlays(overlays, level: .aboveRoads)
            }
        }

        // MARK: - Layers

        func applyBasemap(_ basemap: BasemapChoice, to map: MKMapView) {
            if let existing = basemapOverlay {
                map.removeOverlay(existing)
                existing.invalidate()
                // Cleared, not just replaced: an Apple basemap adds no overlay,
                // and a stale handle here would make `applyOpacity` bind a
                // renderer for a removed overlay and silently do nothing.
                basemapOverlay = nil
            }

            if let service = basemap.tileService {
                // Shaded relief sets `canReplaceMapContent = false` and
                // deliberately composites over MapKit's own map, so standard
                // has to be restored or a previous Apple choice would show
                // through beneath it. The same goes for any USGS layer the
                // user has turned down below full opacity.
                setConfiguration(.standard, on: map)
                let overlay = HillshadeTileOverlay(basemap: service)
                // Level 0 keeps it beneath the terrain layer.
                map.insertOverlay(overlay, at: 0, level: .aboveRoads)
                basemapOverlay = overlay
            } else {
                setConfiguration(.imagery, on: map)
            }

            self.basemap = basemap
            basemapAlpha = -1
        }

        /// Assigning `preferredConfiguration` rebuilds MapKit's base layer, so
        /// it is only assigned when the kind actually changes.
        private func setConfiguration(_ kind: MapConfigurationKind, on map: MKMapView) {
            guard kind != configurationKind else { return }
            configurationKind = kind
            switch kind {
            case .standard:
                // `map.pointOfInterestFilter` is the view-level property and
                // stops being the one that counts once a configuration is
                // assigned, so the filter has to be set on the object itself.
                let config = MKStandardMapConfiguration(elevationStyle: .flat)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            case .imagery:
                // `.flat`, because `.realistic` turns on Apple's own 3D terrain,
                // which would fight the relief this app shades itself.
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            }
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
            // Overlays at one level draw in the order they were added, so the terrain just added sits over the
            // field markup. Forget what was drawn so the next `syncMarkup`, later in this same update, puts it back
            // on top; without this saved lines vanish under the terrain until the markup next changes.
            drawnMarkupVersion = -1
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
            Log.ui.debug("Terrain tiles reloaded")
            renderer.reloadData()
        }

        /// Discards every drawn terrain tile and redraws, after the ground itself changed.
        func discardTerrain(on map: MKMapView) {
            guard let overlay = terrainOverlay,
                  let renderer = map.renderer(for: overlay) as? TerrainTileOverlayRenderer
            else { return }
            Log.ui.debug("Terrain tiles discarded for new elevation data")
            renderer.discardAndReload()
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
                if let existing = profilePolyline {
                    map.removeOverlay(existing)
                }
                var coords = [start, end]
                let polyline = MKPolyline(coordinates: &coords, count: 2)
                profilePolyline = polyline
                map.addOverlay(polyline, level: .aboveLabels)
            } else if let polyline = profilePolyline {
                map.removeOverlay(polyline)
                profilePolyline = nil
            }
        }

        func syncSpotAnnotation(spot: SpotInspection?, on map: MKMapView) {
            guard let spot else {
                if let existing = spotAnnotation {
                    map.removeAnnotation(existing)
                    spotAnnotation = nil
                }
                return
            }
            if let existing = spotAnnotation {
                existing.coordinate = spot.coordinate
            } else {
                let ann = MKPointAnnotation()
                ann.coordinate = spot.coordinate
                ann.title = "Spot Inspection"
                map.addAnnotation(ann)
                spotAnnotation = ann
            }
        }

        func syncViewshed(on map: MKMapView) {
            let needsClear = model.interactionMode != .viewshed || model.viewshedObserverCoordinate == nil
            if needsClear {
                if let circle = viewshedCircle {
                    map.removeOverlay(circle)
                    viewshedCircle = nil
                }
                if let ann = viewshedAnnotation {
                    map.removeAnnotation(ann)
                    viewshedAnnotation = nil
                }
                if let overlay = viewshedOverlay {
                    map.removeOverlay(overlay)
                    viewshedOverlay = nil
                }
                drawnViewshedVersion = -1
                observerDragTimer?.invalidate()
                observerDragTimer = nil
                return
            }

            guard let obs = model.viewshedObserverCoordinate else { return }
            if let ann = viewshedAnnotation {
                // Never pull the pin back under the user's finger mid-drag.
                if observerDragTimer == nil,
                   ann.coordinate.latitude != obs.latitude || ann.coordinate.longitude != obs.longitude {
                    ann.coordinate = obs
                }
            } else {
                let ann = MKPointAnnotation()
                ann.coordinate = obs
                ann.title = "Observer"
                map.addAnnotation(ann)
                viewshedAnnotation = ann
            }

            let desiredRadius = Double(model.viewshedRadiusMeters)
            if let circle = viewshedCircle {
                if circle.coordinate.latitude != obs.latitude || circle.coordinate.longitude != obs.longitude || abs(circle.radius - desiredRadius) > 1.0 {
                    map.removeOverlay(circle)
                    let newCircle = MKCircle(center: obs, radius: desiredRadius)
                    map.addOverlay(newCircle, level: .aboveRoads)
                    viewshedCircle = newCircle
                }
            } else {
                let newCircle = MKCircle(center: obs, radius: desiredRadius)
                map.addOverlay(newCircle, level: .aboveRoads)
                viewshedCircle = newCircle
            }

            if model.viewshedVersion != drawnViewshedVersion {
                drawnViewshedVersion = model.viewshedVersion
                if let old = viewshedOverlay {
                    map.removeOverlay(old)
                    viewshedOverlay = nil
                }
                if let snapshot = model.viewshedOverlay {
                    let overlay = ViewshedOverlay(image: snapshot.image, region: snapshot.region)
                    map.addOverlay(overlay, level: .aboveLabels)
                    viewshedOverlay = overlay
                }
            }
        }

        private var thalwegPolyline: MKPolyline?

        func syncThalweg(on map: MKMapView) {
            let coords: [CLLocationCoordinate2D]
            if !model.thalwegDraft.isEmpty {
                coords = model.thalwegDraft
            } else if !model.thalweg.isEmpty {
                coords = model.thalweg.map(\.coordinate)
            } else {
                coords = []
            }

            if coords.count >= 2 {
                if let existing = thalwegPolyline {
                    map.removeOverlay(existing)
                }
                var mutableCoords = coords
                let polyline = MKPolyline(coordinates: &mutableCoords, count: mutableCoords.count)
                polyline.title = "Thalweg"
                thalwegPolyline = polyline
                map.addOverlay(polyline, level: .aboveLabels)
            } else if let polyline = thalwegPolyline {
                map.removeOverlay(polyline)
                thalwegPolyline = nil
            }
        }

        // MARK: - Gestures & Delegate
        //
        // Which recognizer receives a touch is MapTouchPolicy's answer for the tool lit at that moment, and nothing
        // here has a side effect: no answer switches MapKit's scrolling, and no gesture changes the tool. MapKit's own
        // pan takes every drag the draw pan does not receive, and waits for (and loses to) a stroke the draw pan does.

        private func kind(of touch: UITouch) -> MapTouchKind {
            switch touch.type {
            case .direct: .finger
            case .pencil: .pencil
            default: .pointer     // .indirect, .indirectPointer: a trackpad or a mouse, which acts as a finger does
            }
        }

        /// Which recognizer sees a touch, from MapTouchPolicy and nothing else. It has no side effects: it used to turn
        /// MapKit's scrolling off for every Pencil touch as it landed.
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let tool = model.mapTool
            if gestureRecognizer === wipePanRecognizer { return MapTouchPolicy.wipeRecognizerReceives(in: tool) }
            if gestureRecognizer === drawPanRecognizer {
                return MapTouchPolicy.drawRecognizerReceives(in: tool, by: kind(of: touch))
            }
            if gestureRecognizer === tapRecognizer {
                // A tap on a pin is the pin's (its callout, the observer's drag), not a reading or a point beneath it.
                return MapTouchPolicy.tapRecognizerReceives(in: tool, by: kind(of: touch)) && !Self.isOnAnnotation(touch.view)
            }
            return true
        }

        /// MapKit's own pans wait for a stroke the draw pan has taken, and fail once it draws. A touch the draw pan never
        /// receives (every finger in profile mode) is not waited on.
        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === drawPanRecognizer && other is UIPanGestureRecognizer
                && other !== drawPanRecognizer && other !== wipePanRecognizer
        }

        /// In profile mode a tap waits for MapKit's double-tap zoom to fail (D5), so a zoom never places A and B at one point.
        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === tapRecognizer, let double = other as? UITapGestureRecognizer,
                  double.numberOfTapsRequired == 2 else { return false }
            return MapTouchPolicy.tapWaitsForDoubleTap(in: model.mapTool)
        }

        private static func isOnAnnotation(_ view: UIView?) -> Bool {
            var current = view
            while let v = current {
                if v is MKAnnotationView { return true }
                current = v.superview
            }
            return false
        }

        @objc func handleWipe(_ recognizer: UIPanGestureRecognizer) {
            guard model.interactionMode == .historicalWipe, let map = mapView else { return }
            let loc = recognizer.location(in: map)
            if model.historicalWipeOrientation == .vertical {
                model.moveSplitWipe(to: min(max(Double(loc.x / max(map.bounds.width, 1)), 0), 1))
            } else {
                model.moveSplitWipe(to: min(max(Double(loc.y / max(map.bounds.height, 1)), 0), 1))
            }
            applyWipe(on: map)
        }

        /// The draw pan: the thalweg's trace, or the profile's line in one Pencil stroke. It draws for the tool lit and
        /// never lights one.
        @objc func handleTransectPan(_ recognizer: UIPanGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            switch model.interactionMode {
            case .thalweg:
                switch recognizer.state {
                case .began, .changed:
                    model.extendThalwegDraft(coord); syncThalweg(on: map)
                case .ended:
                    model.extendThalwegDraft(coord); model.commitThalwegDraft(); syncThalweg(on: map)
                case .cancelled:
                    model.commitThalwegDraft(); syncThalweg(on: map)
                default: break
                }
            case .transect:
                switch recognizer.state {
                case .began:
                    // A pan begins some points along the stroke; the line starts where the tip landed, which the draw
                    // pan keeps (its translation counts from where it began, not from the landing).
                    let landing = (recognizer as? DrawPanGestureRecognizer)?.landing ?? point
                    model.beginTransectDrag(at: map.convert(landing, toCoordinateFrom: map))
                case .changed:
                    guard model.isTransectDragging else { return }
                    model.updateTransectDrag(to: coord); syncProfile(on: map)
                case .ended, .cancelled:
                    guard model.isTransectDragging else { return }
                    model.endTransectDrag(to: coord); syncProfile(on: map)
                default: break
                }
            default:
                // The tool changed under the stroke (the top bar tapped with another finger): the stroke does nothing,
                // and never lights a tool.
                break
            }
        }

        /// A tap the tap recognizer received, so one where the tool lit acts on a tap (`tapRecognizerReceives`): the model
        /// does what MapTouchPolicy says for that tool (`handleMapTap`), and with no tool lit it would do nothing anyway.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            model.handleMapTap(map.convert(point, toCoordinateFrom: map))
        }

        public func mapView(
            _ mapView: MKMapView, viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            if point.subtitle?.hasPrefix("FieldWaypoint:") == true {
                let reuseId = "FieldWaypointPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "flag.fill")
                view.canShowCallout = true
                view.displayPriority = .required
                return view
            }
            if point.title == "Spot Inspection" {
                let reuseId = "SpotInspectionPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = .systemTeal
                view.glyphImage = UIImage(systemName: "scope")
                view.displayPriority = .required
                return view
            }
            if point.title == "Observer" {
                let reuseId = "ObserverPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = .systemIndigo
                view.glyphImage = UIImage(systemName: "eye.fill")
                view.isDraggable = true
                view.displayPriority = .required
                return view
            }
            if point.title?.starts(with: "A") == true || point.title?.starts(with: "B") == true {
                let reuseId = "ProfilePointPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = .systemOrange
                view.glyphText = point.title?.starts(with: "A") == true ? "A" : "B"
                return view
            }
            return nil
        }

        public func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            guard let ann = view.annotation as? MKPointAnnotation, ann.title == "Observer" else { return }
            switch newState {
            case .starting, .dragging:
                guard observerDragTimer == nil else { return }
                observerDragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let coordinate = self.viewshedAnnotation?.coordinate else { return }
                        self.model.moveViewshedObserver(coordinate)
                    }
                }
            case .ending, .canceling:
                observerDragTimer?.invalidate()
                observerDragTimer = nil
                model.setViewshedObserver(ann.coordinate)
            default:
                break
            }
        }

        public func mapView(
            _ mapView: MKMapView, rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            if let soil = overlay as? SoilMultiPolygon {
                return SoilHatchRenderer(multiPolygon: soil)
            }
            if let historical = overlay as? HistoricalMapOverlay {
                let renderer = HistoricalMapRenderer(overlay: historical)
                renderer.alpha = historicalAlpha < 0 ? model.historicalOpacity : historicalAlpha
                return renderer
            }
            if let viewshed = overlay as? ViewshedOverlay {
                let renderer = ViewshedOverlayRenderer(overlay: viewshed)
                renderer.alpha = 0.85
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                if polyline.title == "FieldTrace", let trace = polyline.subtitle.flatMap({ markupStyles[$0] }) {
                    renderer.strokeColor = UIColor(traceHex: trace.colorHex) ?? .systemRed
                    renderer.lineWidth = max(trace.strokeWidth, 1)
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                } else if polyline.title == "Thalweg" {
                    renderer.strokeColor = UIColor.systemBlue
                    renderer.lineWidth = 3.0
                } else {
                    renderer.strokeColor = UIColor.systemOrange
                    renderer.lineWidth = 3.5
                }
                return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.12)
                renderer.strokeColor = UIColor.systemIndigo.withAlphaComponent(0.6)
                renderer.lineWidth = 1.5
                return renderer
            }
            guard let tile = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            // The terrain layer gets its own renderer, which draws the shared
            // Metal buffer the tile was shaded into. The basemap is ordinary
            // remote imagery and MapKit's own tile renderer suits it.
            let renderer: MKTileOverlayRenderer
            if let terrain = tile as? TerrainTileOverlay {
                renderer = TerrainTileOverlayRenderer(tileOverlay: terrain)
                renderer.alpha = terrainAlpha < 0 ? model.terrainOpacity : terrainAlpha
            } else {
                renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = basemapAlpha < 0 ? model.basemapOpacity : basemapAlpha
            }
            return renderer
        }

        public func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            applyWipe(on: mapView)
            cullStrandedTerrainTiles(on: mapView)
        }

        /// Stops terrain tiles a pan has carried well off-screen.
        ///
        /// Fires continuously through a gesture, which is the point: the
        /// renderer's own generation fence only moves on a shading change, so
        /// without this a flick leaves every tile it swept past still fetching,
        /// decompressing and dispatching GPU work for ground the user has
        /// already left behind.
        private func cullStrandedTerrainTiles(on map: MKMapView) {
            guard let overlay = terrainOverlay,
                  let renderer = map.renderer(for: overlay) as? TerrainTileOverlayRenderer
            else { return }
            renderer.cullTiles(outsideVisible: map.visibleMapRect)
        }

        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Set, not counted: however many will-changes come first, the did-change that ends a move clears it.
            model.isCameraGestureActive = true
        }

        public func mapView(
            _ mapView: MKMapView, regionDidChangeAnimated animated: Bool
        ) {
            model.isCameraGestureActive = false
            model.visibleRegion = mapView.region
            model.mapWidthPoints = Double(mapView.bounds.width)
            // Tiles for the new view arrive asynchronously; refresh the
            // reported resolution once they have had a moment to land.
            regionDebounceTask?.cancel()
            regionDebounceTask = Task { @MainActor [weak model = self.model] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                model?.refreshResolution()
                model?.refreshElevationRange()
                if model?.showsSoils == true {
                    model?.loadSoils()
                }
            }
        }

        #if !os(macOS)
        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            // Only a hover in progress reports a roll to follow; the model decides what it does to the sun and the
            // ring (`handlePencilHover`), so the harness checks the rules a Simulator cannot reach.
            switch recognizer.state {
            case .began, .changed:
                guard let map = mapView else { return }
                var roll = 0.0 // no reading, as from a pencil without a gyroscope
                if #available(iOS 17.5, *) { roll = Double(recognizer.rollAngle) }
                model.handlePencilHover(rollRadians: roll, at: recognizer.location(in: map))
            default:
                model.endPencilHover()
            }
        }

        // A Pencil double-tap or squeeze (D1): the model acts only in profile mode, and names what it did there
        // (`toolNotice`); elsewhere they do nothing and name nothing. The Pencil's own setting for each, in the iPad's
        // Settings > Apple Pencil, is read at the gesture: Off (`.ignore`) means nothing anywhere. A squeeze set to run a
        // shortcut never reaches the app (UIKit sends the app no squeeze then), so only Off needs reading.
        public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            let ignored = UIPencilInteraction.preferredTapAction == .ignore
            Task { @MainActor in model.handlePencilDoubleTap(ignored: ignored) }
        }

        public func pencilInteraction(
            _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            let ignored = UIPencilInteraction.preferredSqueezeAction == .ignore
            Task { @MainActor in model.handlePencilSqueeze(ignored: ignored) }
        }
        #endif
    }
}

/// The draw pan (the profile's Pencil stroke, the thalweg's trace), which keeps where its touch came down. A pan begins
/// some points along a stroke, and its translation then counts from there: in the Simulator a stroke that began 15 pt
/// from where it landed read a translation of 0, so the line started 15 pt short. It changes nothing but that point.
final class DrawPanGestureRecognizer: UIPanGestureRecognizer {
    /// Where the touch this pan follows came down, in its view's coordinates; nil between touches.
    private(set) var landing: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if landing == nil, let touch = touches.first { landing = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        landing = nil
    }
}
